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
        CURRENT_DIR=$(/usr/libexec/PlistBuddy -c "Print :WorkingDirectory" "$PLIST_FILE" 2>/dev/null)
    fi
    INSTALL_DIR=${CURRENT_DIR:-"$DEFAULT_INSTALL_DIR"}
}

fetch_latest_release() {
    echo -e "${BLUE}正在从 1474443844/Build 检索最新的 grok2api 专属版本...${PLAIN}"
    
    LATEST_TAG=""
    local page=1
    while true; do
        echo -e "${BLUE}正在检索 releases 列表第 ${page} 页...${PLAIN}"
        local releases_json
        releases_json=$(curl -s "https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}")
        
        if [ -z "$releases_json" ] || echo "$releases_json" | grep -q '"message":'; then
            echo -e "${RED}错误：获取 GitHub Release 列表失败，请检查网络。${PLAIN}"
            exit 1
        fi
        
        if ! echo "$releases_json" | grep -q '"tag_name":'; then
            break
        fi
        
        LATEST_TAG=$(echo "$releases_json" | grep '"tag_name":' | grep "grok2api-" | head -n 1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
        
        if [ -n "$LATEST_TAG" ]; then
            break
        fi
        
        page=$((page + 1))
    done

    if [ -z "$LATEST_TAG" ]; then
        echo -e "${RED}错误：遍历了所有 Release 页面，仍未找到任何带有 'grok2api-' 前缀的版本。${PLAIN}"
        exit 1
    fi

    echo -e "${GREEN}已成功匹配到最新 grok2api 版本: ${LATEST_TAG}${PLAIN}"

    local tag_json
    tag_json=$(curl -s "https://api.github.com/repos/${REPO}/releases/tags/${LATEST_TAG}")
    DOWNLOAD_URL=$(echo "$tag_json" | grep "browser_download_url" | grep "$PLATFORM" | head -n 1 | cut -d '"' -f 4)

    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}错误：未能在 Grok2API 版本 (${LATEST_TAG}) 中找到适用于 ${PLATFORM} 的构建包。${PLAIN}"
        exit 1
    fi
}

interactive_configure() {
    local config_path="$1"
    echo -e "\n${BLUE}=================== Grok2API 交互式配置助手 ===================${PLAIN}"

    # 1. 端口
    read -p "请输入服务运行端口 [默认: 8000]: " input_port < /dev/tty
    local port=${input_port:-"8000"}

    # 2. 管理员
    read -p "请输入管理员用户名 [默认: admin]: " admin_user < /dev/tty
    admin_user=${admin_user:-"admin"}

    # 3. 密码
    read -p "请输入管理员初始密码 [直接回车将自动生成随机强密码]: " admin_pass < /dev/tty
    local is_random=false
    if [ -z "$admin_pass" ]; then
        admin_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
        is_random=true
    fi

    # 4. 数据库
    echo -e "\n请选择数据库存储驱动类型："
    echo -e "  1. SQLite (推荐)"
    echo -e "  2. PostgreSQL"
    read -p "请选择驱动 [1-2, 默认: 1]: " db_choice < /dev/tty
    local db_driver="sqlite"
    local pg_dsn="postgres://user:password@127.0.0.1:5432/grok2api?sslmode=disable"
    if [ "$db_choice" = "2" ]; then
        db_driver="postgres"
        read -p "请输入 PostgreSQL DSN 连接串: " input_dsn < /dev/tty
        pg_dsn=${input_dsn:-"$pg_dsn"}
    fi

    # 5. 运行存储
    echo -e "\n请选择缓存驱动类型："
    echo -e "  1. Memory (单机极速)"
    echo -e "  2. Redis (高可用集群)"
    read -p "请选择驱动 [1-2, 默认: 1]: " store_choice < /dev/tty
    local store_driver="memory"
    local redis_addr="127.0.0.1:6379"
    local redis_pass=""
    if [ "$store_choice" = "2" ]; then
        store_driver="redis"
        read -p "请输入 Redis 地址 [默认: $redis_addr]: " input_redis_addr < /dev/tty
        redis_addr=${input_redis_addr:-"$redis_addr"}
        read -p "请输入 Redis 密码 [默认: 无]: " input_redis_pass < /dev/tty
        redis_pass=${input_redis_pass:-""}
    fi

    # 6. 安全密钥
    local jwt_secret enc_key
    if command -v openssl &>/dev/null; then
        jwt_secret=$(openssl rand -hex 32)
        enc_key=$(openssl rand -base64 32)
    else
        jwt_secret=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 64 | head -n 1)
        enc_key=$(head -c 32 /dev/urandom | base64 | tr -d '\r\n')
    fi

    cp "${INSTALL_DIR}/config.example.yaml" "$config_path"

    safe_sed() {
        sed -i "" "s|$1|$2|g" "$config_path"
    }

    safe_sed 'listen: "127.0.0.1:8000"' "listen: \"0.0.0.0:${port}\""
    safe_sed 'jwtSecret: "replace-with-at-least-32-characters"' "jwtSecret: \"${jwt_secret}\""
    safe_sed 'credentialEncryptionKey: "replace-with-base64-key"' "credentialEncryptionKey: \"${enc_key}\""
    safe_sed 'username: "admin"' "username: \"${admin_user}\""
    safe_sed 'password: "replace-with-a-strong-password"' "password: \"${admin_pass}\""
    
    safe_sed 'driver: sqlite # sqlite | postgres' "driver: ${db_driver} # sqlite \| postgres"
    if [ "$db_driver" = "postgres" ]; then
        safe_sed 'dsn: "postgres://user:password@127.0.0.1:5432/grok2api.*"' "dsn: \"${pg_dsn}\""
    fi

    safe_sed 'driver: memory # memory | redis' "driver: ${store_driver} # memory \| redis"
    if [ "$store_driver" = "redis" ]; then
        safe_sed 'address: "127.0.0.1:6379"' "address: \"${redis_addr}\""
        safe_sed 'password: ""' "password: \"${redis_pass}\""
    fi

    echo -e "${GREEN}🎉 config.yaml 写入成功！${PLAIN}"
    echo -e "${YELLOW}======================================================="
    echo -e " 🚀 初始管理员凭证已写入配置文件："
    echo -e " 初始账户: ${admin_user}"
    echo -e " 初始密码: ${admin_pass}"
    [ "$is_random" = "true" ] && echo -e " (提示: 这是随机密码，请尽快登录并保存！)"
    echo -e "=======================================================${PLAIN}"
}

install_app() {
    detect_arch
    get_current_install_dir

    read -p "请输入 Mac 自定义安装目录 [当前/默认: ${INSTALL_DIR}]: " custom_dir < /dev/tty
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
    if [ ! -f "$config_path" ]; then
        if [ -f "${INSTALL_DIR}/config.example.yaml" ]; then
            interactive_configure "$config_path"
        else
            touch "$config_path"
            echo -e "${YELLOW}警告：未能在包中找到 config.example.yaml 模板，已生成空白 config.yaml。${PLAIN}"
        fi
    fi

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
    echo -e "${GREEN}服务配置已重载并已拉起！${PLAIN}"
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
    read -p "确定彻底卸载 Mac 服务吗？ [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        launchctl unload "$PLIST_FILE" &> /dev/null
        rm -f "$PLIST_FILE"
        read -p "是否同时删除数据目录 (${INSTALL_DIR})？ [y/N]: " delete_data < /dev/tty
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
    read -p "请选择操作 [0-5]: " choice < /dev/tty
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) launchctl load -w "$PLIST_FILE" &> /dev/null; echo "已加载并启动服务" ;;
        4) launchctl unload "$PLIST_FILE" &> /dev/null; killall grok2api &> /dev/null; echo "服务已停止" ;;
        5) uninstall_app ;;
        0) exit 0 ;;
    esac
done