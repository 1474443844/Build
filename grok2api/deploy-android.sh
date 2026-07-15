#!/usr/bin/env bash

# ==============================================================================
# Grok2API 一键部署与更新脚本 (Android / Termux & 自定义 PTY 通用 - 1474443844/Build)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

REPO="1474443844/Build"
PLATFORM="android-arm64"

IS_TERMUX=false
if [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ]; then
    IS_TERMUX=true
    echo -e "${GREEN}环境检测：检测到官方 Termux 运行环境。${PLAIN}"
else
    echo -e "${YELLOW}环境检测：未检测到官方 Termux (可能运行在自定义 PTY 或其它安卓终端中)。${PLAIN}"
fi

PATH_CACHE_FILE=""
if [ "$IS_TERMUX" = true ]; then
    PATH_CACHE_FILE="$HOME/.grok2api_path"
else
    if [ -n "$HOME" ] && [ -w "$HOME" ]; then
        PATH_CACHE_FILE="$HOME/.grok2api_path"
    else
        PATH_CACHE_FILE="$(pwd)/.grok2api_path"
    fi
fi

get_default_dir() {
    if [ -f "$PATH_CACHE_FILE" ]; then
        DEFAULT_DIR=$(cat "$PATH_CACHE_FILE")
    else
        if [ "$IS_TERMUX" = true ]; then
            DEFAULT_DIR="$HOME/grok2api"
        else
            if [ -n "$HOME" ] && [ -w "$HOME" ]; then
                DEFAULT_DIR="$HOME/grok2api"
            else
                DEFAULT_DIR="$(pwd)/grok2api"
            fi
        fi
    fi
}

save_dir_to_cache() {
    echo "$INSTALL_DIR" > "$PATH_CACHE_FILE"
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
            echo -e "${RED}错误：获取 GitHub Release 列表失败或已被 API 限流。${PLAIN}"
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

start_service() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "${BLUE}服务已在后台运行中 (PID: $(cat "$PID_FILE"))。${PLAIN}"
        return
    fi
    
    local port
    read -p "请输入服务运行端口 [默认: 8000]: " port < /dev/tty
    port=${port:-"8000"}

    nohup "${INSTALL_DIR}/grok2api" --config "${INSTALL_DIR}/config.yaml" --listen "0.0.0.0:${port}" > "${INSTALL_DIR}/output.log" 2>&1 &
    echo $! > "$PID_FILE"
    echo -e "${GREEN}服务已成功在后台启动！当前 PID: $!${PLAIN}"
    echo -e "${GREEN}控制台日志已重定向至: ${INSTALL_DIR}/output.log${PLAIN}"
}

stop_service() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" &>/dev/null
            echo -e "${GREEN}已成功终止后台服务 (PID: $pid)。${PLAIN}"
        else
            echo -e "${YELLOW}提示：PID 文件存在，但对应进程已不存在，已自动清理缓存。${PLAIN}"
        fi
        rm -f "$PID_FILE"
    else
        if command -v pkill &> /dev/null; then
            pkill -f "grok2api" &>/dev/null
        elif command -v killall &> /dev/null; then
            killall grok2api &>/dev/null
        fi
        echo -e "${BLUE}已尝试清理所有可能残留的后台程序。${PLAIN}"
    fi
}

install_app() {
    get_default_dir
    
    read -p "请输入自定义安装目录 [当前/默认: ${DEFAULT_DIR}]: " custom_dir < /dev/tty
    INSTALL_DIR=${custom_dir:-"$DEFAULT_DIR"}
    save_dir_to_cache
    PID_FILE="${INSTALL_DIR}/grok2api.pid"

    fetch_latest_release
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1

    local temp_tar="grok2api_android.tar.gz"
    echo -e "${BLUE}正在下载安卓包 (${LATEST_TAG})...${PLAIN}"
    if ! curl -L -o "$temp_tar" "$DOWNLOAD_URL"; then
        echo -e "${RED}下载失败，请检查网络。${PLAIN}"
        exit 1
    fi

    echo -e "${BLUE}正在解压...${PLAIN}"
    tar -xzf "$temp_tar" --overwrite
    rm -f "$temp_tar"

    # ==================== 配置文件安全初始化 ====================
    local config_path="${INSTALL_DIR}/config.yaml"
    local generated_pass=""
    if [ ! -f "$config_path" ]; then
        if [ -f "${INSTALL_DIR}/config.example.yaml" ]; then
            echo -e "${BLUE}正在根据模板安全初始化并生成随机密钥...${PLAIN}"
            cp "${INSTALL_DIR}/config.example.yaml" "$config_path"
            
            local jwt_secret enc_key
            if command -v openssl &>/dev/null; then
                jwt_secret=$(openssl rand -hex 32)
                enc_key=$(openssl rand -base64 32)
            else
                jwt_secret=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 64 | head -n 1)
                enc_key=$(head -c 32 /dev/urandom | base64 | tr -d '\r\n')
            fi
            generated_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)

            safe_sed() {
                sed -i "s|$1|$2|g" "$config_path"
            }

            safe_sed 'jwtSecret: "replace-with-at-least-32-characters"' "jwtSecret: \"${jwt_secret}\""
            safe_sed 'credentialEncryptionKey: "replace-with-base64-key"' "credentialEncryptionKey: \"${enc_key}\""
            safe_sed 'password: "replace-with-a-strong-password"' "password: \"${generated_pass}\""
        else
            touch "$config_path"
            echo -e "${YELLOW}警告：未能在包中找到 config.example.yaml 模板，已生成空白 config.yaml。${PLAIN}"
        fi
    fi
    # ============================================================
    
    echo -e "${GREEN}程序安装完成！${PLAIN}"
    if [ -n "$generated_pass" ]; then
        echo -e "${YELLOW}======================================================="
        echo -e " 🎉 初始管理员安全凭证已成功写入 config.yaml！"
        echo -e " 初始账户: admin"
        echo -e " 初始密码: ${generated_pass}"
        echo -e " 请妥善保存以上账号密码！"
        echo -e "=======================================================${PLAIN}"
    fi
    start_service
}

update_app() {
    get_default_dir
    
    read -p "请确认当前运行程序的安装目录 [默认: ${DEFAULT_DIR}]: " custom_dir < /dev/tty
    INSTALL_DIR=${custom_dir:-"$DEFAULT_DIR"}
    save_dir_to_cache
    PID_FILE="${INSTALL_DIR}/grok2api.pid"

    if [ ! -f "${INSTALL_DIR}/grok2api" ]; then
        echo -e "${RED}错误：在 ${INSTALL_DIR} 下未找到已有程序，请确认您的安装路径是否正确。${PLAIN}"
        return
    fi

    fetch_latest_release
    stop_service

    cd "$INSTALL_DIR" || exit 1
    local temp_tar="grok2api_android.tar.gz"
    echo -e "${BLUE}正在下载并更新覆盖...${PLAIN}"
    if curl -L -o "$temp_tar" "$DOWNLOAD_URL" && tar -xzf "$temp_tar" --overwrite; then
        rm -f "$temp_tar"
        echo -e "${GREEN}程序已成功升级至最新版本！${PLAIN}"
        start_service
    else
        echo -e "${RED}更新下载失败，请检查网络连接。${PLAIN}"
    fi
}

while true; do
    echo -e "
${BLUE}=========================================${PLAIN}
${GREEN}       Grok2API 一键部署/管理 (Android)   ${PLAIN}
${BLUE}=========================================${PLAIN}
  ${BLUE}1.${PLAIN} 安装 / 重新安装 Grok2API
  ${BLUE}2.${PLAIN} 一键升级至最新版本
  ${BLUE}3.${PLAIN} 启动后台服务
  ${BLUE}4.${PLAIN} 关闭后台服务
  ${BLUE}5.${PLAIN} 退出脚本
${BLUE}=========================================${PLAIN}"
    read -p "请选择操作 [1-5]: " choice < /dev/tty
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) 
            get_default_dir
            read -p "请确认程序安装目录 [默认: ${DEFAULT_DIR}]: " custom_dir < /dev/tty
            INSTALL_DIR=${custom_dir:-"$DEFAULT_DIR"}
            save_dir_to_cache
            PID_FILE="${INSTALL_DIR}/grok2api.pid"
            start_service 
            ;;
        4) 
            get_default_dir
            read -p "请确认程序安装目录 [默认: ${DEFAULT_DIR}]: " custom_dir < /dev/tty
            INSTALL_DIR=${custom_dir:-"$DEFAULT_DIR"}
            save_dir_to_cache
            PID_FILE="${INSTALL_DIR}/grok2api.pid"
            stop_service 
            ;;
        5) exit 0 ;;
    esac
done