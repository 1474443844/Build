#!/usr/bin/env bash

# ==============================================================================
# Grok2API 交互式部署与更新脚本 (macOS - 1474443844/Build 专用)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

REPO="1474443844/Build"
DEFAULT_INSTALL_DIR="$HOME/grok2api"
LABEL="com.grok2api.service"
PLIST_FILE="$HOME/Library/LaunchAgents/${LABEL}.plist"

detect_arch() {
    local arch
    arch=$(uname -m)
    if [ "$arch" = "x86_64" ]; then
        PLATFORM="darwin-amd64"
    elif [ "$arch" = "arm64" ]; then
        PLATFORM="darwin-arm64"
    else
        echo -e "${RED}不支持的 Mac 架构: $arch${PLAIN}"
        exit 1
    fi
}

get_current_install_dir() {
    if [ -f "$PLIST_FILE" ]; then
        # Natively parse macOS Plist file using system-provided PlistBuddy
        CURRENT_DIR=$(/usr/libexec/PlistBuddy -c "Print :WorkingDirectory" "$PLIST_FILE" 2>/dev/null)
    fi
    INSTALL_DIR=${CURRENT_DIR:-"$DEFAULT_INSTALL_DIR"}
}

fetch_latest_release() {
    echo -e "${BLUE}正在从 1474443844/Build 获取最新 Mac 版本...${PLAIN}"
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local release_json
    release_json=$(curl -s "$api_url")
    LATEST_TAG=$(echo "$release_json" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    DOWNLOAD_URL=$(echo "$release_json" | grep "browser_download_url" | grep "$PLATFORM" | head -n 1 | cut -d '"' -f 4)
}

install_app() {
    detect_arch
    get_current_install_dir

    # 提示自定义安装路径
    read -p "请输入 Mac 自定义安装目录 [当前/默认: ${INSTALL_DIR}]: " custom_dir
    INSTALL_DIR=${custom_dir:-"$INSTALL_DIR"}

    fetch_latest_release
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1

    local temp_tar="grok2api_mac.tar.gz"
    echo -e "${BLUE}下载中...${PLAIN}"
    curl -L -o "$temp_tar" "$DOWNLOAD_URL"
    tar -xzf "$temp_tar" --overwrite
    rm -f "$temp_tar"

    local config_path="${INSTALL_DIR}/config.yaml"
    if [ ! -f "$config_path" ]; then touch "$config_path"; fi

    read -p "请输入服务监听端口 [默认: 8000]: " listen_port
    listen_port=${listen_port:-"8000"}

    launchctl unload "$PLIST_FILE" &> /dev/null

    cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0//EN">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/grok2api</string>
        <string>--config</string>
        <string>${config_path}</string>
        <string>--listen</string>
        <string>0.0.0.0:${listen_port}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/stderr.log</string>
</dict>
</plist>
EOF

    launchctl load -w "$PLIST_FILE"
    echo -e "${GREEN}安装成功并已在 macOS 后端拉起守护进程！${PLAIN}"
}

update_app() {
    detect_arch
    get_current_install_dir
    if [ ! -f "$PLIST_FILE" ]; then echo -e "${RED}未安装服务。${PLAIN}"; return; fi

    fetch_latest_release
    launchctl unload "$PLIST_FILE" &> /dev/null
    killall grok2api &> /dev/null

    cd "$INSTALL_DIR" || exit 1
    local temp_tar="grok2api_mac.tar.gz"
    if curl -L -o "$temp_tar" "$DOWNLOAD_URL" && tar -xzf "$temp_tar" --overwrite; then
        rm -f "$temp_tar"
        launchctl load -w "$PLIST_FILE"
        echo -e "${GREEN}成功更新至 ${LATEST_TAG}！${PLAIN}"
    else
        launchctl load -w "$PLIST_FILE"
    fi
}

uninstall_app() {
    get_current_install_dir
    read -p "确定彻底卸载 Mac 服务吗？ [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        launchctl unload "$PLIST_FILE" &> /dev/null
        rm -f "$PLIST_FILE"
        read -p "是否同时删除数据目录 (${INSTALL_DIR})？ [y/N]: " delete_data
        if [[ "$delete_data" =~ ^[Yy]$ ]]; then rm -rf "$INSTALL_DIR"; fi
        echo -e "${GREEN}卸载完成。${PLAIN}"
    fi
}

while true; do
    echo -e "
${BLUE}=========================================${PLAIN}
${GREEN}       Grok2API 一键部署/管理 (macOS)     ${PLAIN}
${BLUE}=========================================${PLAIN}
  ${BLUE}1.${PLAIN} 安装 / 重新安装 Grok2API
  ${BLUE}2.${PLAIN} 一键升级至最新版本
  ${BLUE}3.${PLAIN} 启动 Mac 服务
  ${BLUE}4.${PLAIN} 停止 Mac 服务
  ${BLUE}5.${PLAIN} 卸载 Grok2API
  ${BLUE}0.${PLAIN} 退出脚本
${BLUE}=========================================${PLAIN}"
    read -p "请选择操作 [0-5]: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) launchctl load -w "$PLIST_FILE" &> /dev/null; echo "已加载并启动服务" ;;
        4) launchctl unload "$PLIST_FILE" &> /dev/null; killall grok2api &> /dev/null; echo "服务已停止" ;;
        5) uninstall_app ;;
        0) exit 0 ;;
    esac
done