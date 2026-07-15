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

IS_TERMUX=false
if [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ]; then
    IS_TERMUX=true
    echo -e "${GREEN}环境检测：检测到官方 Termux 运行环境。${PLAIN}"
else
    echo -e "${YELLOW}环境检测：未检测到官方 Termux (可能运行在自定义 PTY 或其它安卓终端中)。${PLAIN}"
fi

# 基于运行环境建立并管理本地路径缓存文件，实现自定义位置的无感记忆
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
    # 优先从缓存文件中读取曾设定过的自定义路径
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
    # 保存当前的自定义位置到缓存，以便升级、启停时自动获取
    echo "$INSTALL_DIR" > "$PATH_CACHE_FILE"
}

fetch_latest_release() {
    echo -e "${BLUE}正在从 1474443844/Build 获取最新版本...${PLAIN}"
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local release_json
    release_json=$(curl -s "$api_url")
    
    if [ -z "$release_json" ] || echo "$release_json" | grep -q "message.*Not Found"; then
        echo -e "${RED}错误：无法获取 GitHub Release 信息，请检查网络。${PLAIN}"
        exit 1
    fi

    LATEST_TAG=$(echo "$release_json" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    DOWNLOAD_URL=$(echo "$release_json" | grep "browser_download_url" | grep "android-arm64" | head -n 1 | cut -d '"' -f 4)

    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}错误：未能在最新 Release 中找到安卓 arm64 构建包。${PLAIN}"
        exit 1
    fi
}

start_service() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "${BLUE}服务已在后台运行中 (PID: $(cat "$PID_FILE"))。${PLAIN}"
        return
    fi
    
    local port
    read -p "请输入服务运行端口 [默认: 8000]: " port
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
    
    # 提示并支持用户自定义安装路径
    read -p "请输入自定义安装目录 [当前/默认: ${DEFAULT_DIR}]: " custom_dir
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

    if [ ! -f "config.yaml" ]; then 
        touch config.yaml
        echo -e "${YELLOW}提示：已生成空的 config.yaml，运行前请记得编辑配置。${PLAIN}"
    fi
    
    echo -e "${GREEN}程序安装完成！${PLAIN}"
    start_service
}

update_app() {
    get_default_dir
    
    # 调取并提示用户确认之前的自定义目录
    read -p "请确认当前运行程序的安装目录 [默认: ${DEFAULT_DIR}]: " custom_dir
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
    read -p "请选择操作 [1-5]: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) 
            get_default_dir
            read -p "请确认程序安装目录 [默认: ${DEFAULT_DIR}]: " custom_dir
            INSTALL_DIR=${custom_dir:-"$DEFAULT_DIR"}
            save_dir_to_cache
            PID_FILE="${INSTALL_DIR}/grok2api.pid"
            start_service 
            ;;
        4) 
            get_default_dir
            read -p "请确认程序安装目录 [默认: ${DEFAULT_DIR}]: " custom_dir
            INSTALL_DIR=${custom_dir:-"$DEFAULT_DIR"}
            save_dir_to_cache
            PID_FILE="${INSTALL_DIR}/grok2api.pid"
            stop_service 
            ;;
        5) exit 0 ;;
    esac
done