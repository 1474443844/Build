#!/usr/bin/env bash
# ============================================================
#  Resin 一键部署 & 更新脚本
#  用法:
#    ./resin-deploy.sh              # 首次部署（交互式配置）
#    ./resin-deploy.sh --update     # 更新到最新版本
#    ./resin-deploy.sh --update --from-source  # 源码编译更新
#    ./resin-deploy.sh --uninstall  # 卸载（保留数据）
# ============================================================
set -euo pipefail

# ── 颜色 ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✘]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

# ── 配置路径 ──────────────────────────────────────────────────
INSTALL_DIR="${RESIN_INSTALL_DIR:-/opt/resin}"
DATA_DIR="${INSTALL_DIR}/data"
ENV_FILE="${INSTALL_DIR}/.env"
SERVICE_FILE="/etc/systemd/system/resin.service"
BINARY_PATH="${INSTALL_DIR}/resin"
GITHUB_REPO="Resinat/Resin"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"

# ── 依赖检查 ──────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in curl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "缺少依赖: ${missing[*]}，尝试自动安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq "${missing[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y -q "${missing[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y -q "${missing[@]}"
        elif command -v apk &>/dev/null; then
            apk add --no-cache "${missing[@]}"
        else
            err "无法自动安装，请手动安装: ${missing[*]}"
            exit 1
        fi
    fi
}

# ── 系统架构检测 ──────────────────────────────────────────────
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)   echo "arm64" ;;
        armv7l|armhf)    echo "armv7" ;;
        *)               err "不支持的架构: $arch"; exit 1 ;;
    esac
}

detect_os() {
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux)  echo "linux" ;;
        darwin) echo "darwin" ;;
        *)      err "不支持的操作系统: $os"; exit 1 ;;
    esac
}

# ── 获取最新版本 ──────────────────────────────────────────────
get_latest_version() {
    local version
    version=$(curl -sL "${GITHUB_API}/releases/latest" | jq -r '.tag_name // empty')
    if [[ -z "$version" ]]; then
        err "无法获取最新版本，请检查网络或 GitHub API 限制"
        exit 1
    fi
    echo "$version"
}

get_current_version() {
    if [[ -x "$BINARY_PATH" ]]; then
        "$BINARY_PATH" --version 2>/dev/null | head -1 || echo "unknown"
    else
        echo "未安装"
    fi
}

# ── 下载二进制 ────────────────────────────────────────────────
download_binary() {
    local version="$1" os="$2" arch="$3"
    local filename="resin-${os}-${arch}.tar.gz"
    local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${filename}"

    step "下载 Resin ${version} (${os}/${arch})"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" EXIT

    if ! curl -fSL --progress-bar -o "${tmp_dir}/${filename}" "$url"; then
        # 尝试不带架构后缀的文件名
        filename="resin_${os}_${arch}.tar.gz"
        url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${filename}"
        if ! curl -fSL --progress-bar -o "${tmp_dir}/${filename}" "$url"; then
            err "下载失败，请检查版本和架构是否正确"
            err "尝试的 URL: $url"
            exit 1
        fi
    fi

    tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir"

    # 查找 resin 二进制文件
    local bin
    bin=$(find "$tmp_dir" -name "resin" -type f -executable | head -1)
    if [[ -z "$bin" ]]; then
        bin=$(find "$tmp_dir" -name "resin*" -type f | head -1)
    fi
    if [[ -z "$bin" ]]; then
        err "压缩包中未找到 resin 可执行文件"
        exit 1
    fi

    cp "$bin" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    info "二进制文件已安装到 ${BINARY_PATH}"
    trap - EXIT
    rm -rf "$tmp_dir"
}

# ── 源码编译 ──────────────────────────────────────────────────
build_from_source() {
    step "从源码编译 Resin"

    # 检查 Go 和 Node.js
    if ! command -v go &>/dev/null; then
        err "源码编译需要 Go 1.25+，请先安装"
        exit 1
    fi
    if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
        err "源码编译需要 Node.js 和 npm，请先安装"
        exit 1
    fi
    if ! command -v git &>/dev/null; then
        err "需要 git，请先安装"
        exit 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    info "克隆仓库..."
    git clone --depth 1 "https://github.com/${GITHUB_REPO}.git" "${tmp_dir}/Resin"

    info "编译 WebUI..."
    (cd "${tmp_dir}/Resin/webui" && npm install && npm run build)

    info "编译 resin 核心..."
    (cd "${tmp_dir}/Resin" && go build -tags "with_quic with_wireguard with_grpc with_utls" -o "${tmp_dir}/resin" ./cmd/resin)

    cp "${tmp_dir}/resin" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf "$tmp_dir"
    info "源码编译完成，已安装到 ${BINARY_PATH}"
}

# ── 交互式配置 ────────────────────────────────────────────────
configure_env() {
    step "配置 Resin"

    local admin_token proxy_token auth_version port listen_addr proxy_bypass

    if [[ -f "$ENV_FILE" ]]; then
        info "检测到已有配置: ${ENV_FILE}"
        read -rp "是否保留现有配置？[Y/n] " keep_conf
        if [[ "${keep_conf,,}" != "n" ]]; then
            info "保留现有配置"
            return
        fi
    fi

    # 管理密码
    read -rp "设置管理面板密码 (默认: admin123): " admin_token
    admin_token="${admin_token:-admin123}"

    # 代理密码
    read -rp "设置代理密码 (默认: my-token，留空则无密码): " proxy_token
    proxy_token="${proxy_token:-my-token}"

    # 认证版本
    echo ""
    echo "认证版本选择:"
    echo "  V1         - 新版，支持 HTTP + SOCKS5 (推荐)"
    echo "  LEGACY_V0  - 旧版，仅支持 HTTP"
    read -rp "认证版本 [V1/LEGACY_V0] (默认: V1): " auth_version
    auth_version="${auth_version:-V1}"

    # 端口
    read -rp "监听端口 (默认: 2260): " port
    port="${port:-2260}"

    # 监听地址
    read -rp "监听地址 (默认: 0.0.0.0): " listen_addr
    listen_addr="${listen_addr:-0.0.0.0}"

    # 内网绕过
    read -rp "内网地址是否绕过代理？[Y/n] (默认: Y): " bypass_choice
    if [[ "${bypass_choice,,}" != "n" ]]; then
        proxy_bypass="localhost;127.*;10.*;172.16.0.0/12;192.168.*;"
    else
        proxy_bypass=""
    fi

    cat > "$ENV_FILE" <<EOF
# Resin 配置 - $(date '+%Y-%m-%d %H:%M:%S')
RESIN_AUTH_VERSION=${auth_version}
RESIN_ADMIN_TOKEN=${admin_token}
RESIN_PROXY_TOKEN=${proxy_token}
RESIN_LISTEN_ADDRESS=${listen_addr}
RESIN_PORT=${port}
RESIN_STATE_DIR=${DATA_DIR}/state
RESIN_CACHE_DIR=${DATA_DIR}/cache
RESIN_LOG_DIR=${DATA_DIR}/log
RESIN_PROXY_BYPASS=${proxy_bypass}
EOF

    info "配置已写入 ${ENV_FILE}"
}

# ── 创建 systemd 服务 ────────────────────────────────────────
setup_systemd() {
    step "配置 systemd 服务"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Resin Proxy Gateway
After=network.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${BINARY_PATH}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable resin
    info "systemd 服务已创建并启用"
}

# ── 启动/重启服务 ─────────────────────────────────────────────
start_service() {
    step "启动 Resin"

    mkdir -p "${DATA_DIR}/state" "${DATA_DIR}/cache" "${DATA_DIR}/log"

    if systemctl is-active --quiet resin 2>/dev/null; then
        systemctl restart resin
        info "Resin 已重启"
    else
        systemctl start resin
        info "Resin 已启动"
    fi

    sleep 2
    if systemctl is-active --quiet resin; then
        local port
        port=$(grep RESIN_PORT "$ENV_FILE" | cut -d= -f2)
        port="${port:-2260}"
        info "服务运行正常"
        echo ""
        echo -e "  ${BOLD}管理后台:${NC} http://<你的IP>:${port}"
        echo -e "  ${BOLD}HTTP 代理:${NC} http://<你的IP>:${port}"
        echo -e "  ${BOLD}SOCKS5 代理:${NC} socks5://<你的IP>:${port}"
        echo ""
    else
        err "服务启动失败，查看日志:"
        journalctl -u resin --no-pager -n 20
        exit 1
    fi
}

# ── 更新流程 ──────────────────────────────────────────────────
do_update() {
    local from_source="${1:-false}"

    if [[ ! -f "$ENV_FILE" ]]; then
        err "未找到配置文件 ${ENV_FILE}，请先运行部署"
        exit 1
    fi

    local current_version latest_version
    current_version=$(get_current_version)
    latest_version=$(get_latest_version)

    echo -e "  当前版本: ${BOLD}${current_version}${NC}"
    echo -e "  最新版本: ${BOLD}${latest_version}${NC}"

    if [[ "$current_version" == "$latest_version" ]]; then
        info "已是最新版本，无需更新"
        exit 0
    fi

    read -rp "确认更新到 ${latest_version}？[Y/n] " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        warn "已取消更新"
        exit 0
    fi

    local os arch
    os=$(detect_os)
    arch=$(detect_arch)

    # 备份当前版本
    if [[ -f "$BINARY_PATH" ]]; then
        cp "$BINARY_PATH" "${BINARY_PATH}.bak"
        info "已备份当前版本到 ${BINARY_PATH}.bak"
    fi

    if [[ "$from_source" == "true" ]]; then
        build_from_source
    else
        download_binary "$latest_version" "$os" "$arch"
    fi

    start_service
    info "更新完成! ${current_version} → ${latest_version}"
}

# ── 首次部署 ──────────────────────────────────────────────────
do_install() {
    local from_source="${1:-false}"

    step "Resin 一键部署"
    echo "  安装目录: ${INSTALL_DIR}"

    if [[ -f "$BINARY_PATH" ]]; then
        warn "检测到已安装 Resin"
        read -rp "是否覆盖安装？[y/N] " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            warn "已取消"
            exit 0
        fi
    fi

    mkdir -p "$INSTALL_DIR" "${DATA_DIR}/state" "${DATA_DIR}/cache" "${DATA_DIR}/log"

    local os arch
    os=$(detect_os)
    arch=$(detect_arch)

    if [[ "$from_source" == "true" ]]; then
        build_from_source
    else
        local version
        version=$(get_latest_version)
        download_binary "$version" "$os" "$arch"
    fi

    configure_env
    setup_systemd
    start_service

    echo ""
    info "部署完成！"
    echo ""
    echo -e "  ${BOLD}常用命令:${NC}"
    echo "    systemctl status resin    # 查看状态"
    echo "    systemctl restart resin   # 重启服务"
    echo "    journalctl -u resin -f    # 查看日志"
    echo "    $0 --update               # 更新到最新版"
    echo ""
}

# ── 卸载 ──────────────────────────────────────────────────────
do_uninstall() {
    step "卸载 Resin"

    if systemctl is-active --quiet resin 2>/dev/null; then
        systemctl stop resin
        info "已停止服务"
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        systemctl disable resin 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        info "已移除 systemd 服务"
    fi

    if [[ -f "$BINARY_PATH" ]]; then
        rm -f "$BINARY_PATH" "${BINARY_PATH}.bak"
        info "已删除二进制文件"
    fi

    echo ""
    info "卸载完成！数据保留在: ${DATA_DIR}"
    warn "如需彻底清理数据，请手动执行: rm -rf ${INSTALL_DIR}"
    echo ""
}

# ── 主入口 ────────────────────────────────────────────────────
main() {
    check_deps

    local action="install"
    local from_source=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --update|-u)      action="update"; shift ;;
            --uninstall)      action="uninstall"; shift ;;
            --from-source|-s) from_source=true; shift ;;
            --help|-h)
                echo "用法: $0 [选项]"
                echo "  (无参数)        首次部署"
                echo "  --update, -u    更新到最新版本"
                echo "  --uninstall     卸载（保留数据）"
                echo "  --from-source   使用源码编译（配合 --update 或首次部署）"
                echo ""
                echo "环境变量:"
                echo "  RESIN_INSTALL_DIR  安装目录 (默认: /opt/resin)"
                exit 0
                ;;
            *)
                err "未知参数: $1"
                exit 1
                ;;
        esac
    done

    case "$action" in
        install)   do_install "$from_source" ;;
        update)    do_update "$from_source" ;;
        uninstall) do_uninstall ;;
    esac
}

main "$@"