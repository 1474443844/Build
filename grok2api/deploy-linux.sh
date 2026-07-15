#!/usr/bin/env bash

# ==============================================================================
# Grok2API 交互式部署与更新脚本 (Linux - 1474443844/Build 专用)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

REPO="1474443844/Build"
DEFAULT_INSTALL_DIR="/opt/grok2api"
SERVICE_NAME="grok2api"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 用户或通过 sudo 运行此脚本。${PLAIN}"
    exit 1
fi

for cmd in curl tar grep sed; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}错误：系统缺少必要工具 $cmd，请先安装。${PLAIN}"
        exit 1
    fi
done

detect_arch() {
    local arch
    arch=$(uname -m)
    if [ "$arch" = "x86_64" ]; then
        PLATFORM="linux-amd64"
    elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        PLATFORM="linux-arm64"
    else
        echo -e "${RED}错误：暂不支持的系统架构 ($arch)。${PLAIN}"
        exit 1
    fi
}

get_current_install_dir() {
    local service_path="/etc/systemd/system/${SERVICE_NAME}.service"
    if [ -f "$service_path" ]; then
        CURRENT_DIR=$(grep "WorkingDirectory" "$service_path" | cut -d '=' -f 2 | tr -d ' ')
    fi
    INSTALL_DIR=${CURRENT_DIR:-"$DEFAULT_INSTALL_DIR"}
}

get_current_port() {
    local config_path="${INSTALL_DIR}/config.yaml"
    local parsed_port="8000"
    if [ -f "$config_path" ]; then
        parsed_port=$(grep "listen:" "$config_path" | sed -E 's/.*:([0-9]+).*/\1/' | tr -d '\r\n ')
    fi
    LISTEN_PORT=${parsed_port:-"8000"}
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

interactive_configure() {
    local config_path="$1"
    echo -e "\n${BLUE}=================== Grok2API 交互式配置助手 ===================${PLAIN}"

    # 1. 监听端口
    read -p "请输入服务运行端口 [默认: 8000]: " input_port < /dev/tty
    local port=${input_port:-"8000"}

    # 2. 管理员用户
    read -p "请输入管理员用户名 [默认: admin]: " admin_user < /dev/tty
    admin_user=${admin_user:-"admin"}

    # 3. 管理员密码 (调大至 512 字节，消除 broken pipe 警告)
    read -p "请输入管理员初始密码 [直接回车将自动生成随机强密码]: " admin_pass < /dev/tty
    local is_random=false
    if [ -z "$admin_pass" ]; then
        admin_pass=$(head -c 512 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16 2>/dev/null)
        is_random=true
    fi

    # 4. 数据库类型与 DSN 串
    echo -e "\n请选择数据库存储驱动类型："
    echo -e "  1. SQLite (单实例极速部署推荐)"
    echo -e "  2. PostgreSQL (多实例高可用推荐)"
    read -p "请选择驱动类型 [1-2, 默认: 1]: " db_choice < /dev/tty
    local db_driver="sqlite"
    local pg_dsn="postgres://user:password@127.0.0.1:5432/grok2api?sslmode=disable"
    if [ "$db_choice" = "2" ]; then
        db_driver="postgres"
        read -p "请输入 PostgreSQL DSN 连接串: " input_dsn < /dev/tty
        pg_dsn=${input_dsn:-"$pg_dsn"}
    fi

    # 5. 缓存类型与 Redis 连接
    echo -e "\n请选择运行缓存驱动类型："
    echo -e "  1. Memory (单机极速运行)"
    echo -e "  2. Redis (多实例共享状态集群推荐)"
    read -p "请选择驱动类型 [1-2, 默认: 1]: " store_choice < /dev/tty
    local store_driver="memory"
    local redis_addr="127.0.0.1:6379"
    local redis_pass=""
    if [ "$store_choice" = "2" ]; then
        store_driver="redis"
        read -p "请输入 Redis 连接地址 [默认: $redis_addr]: " input_redis_addr < /dev/tty
        redis_addr=${input_redis_addr:-"$redis_addr"}
        read -p "请输入 Redis 访问密码 [默认: 无]: " input_redis_pass < /dev/tty
        redis_pass=${input_redis_pass:-""}
    fi

    # 6. 生成安全随机密钥对 (调大至 2048 字节，消除 broken pipe 并保障长度)
    local jwt_secret enc_key
    jwt_secret=$(openssl rand -hex 32)
    enc_key=$(openssl -base64 32)

    cp "${INSTALL_DIR}/config.example.yaml" "$config_path"

    safe_sed() {
        sed -i "s|$1|$2|g" "$config_path"
    }

    # 执行文本替换
    safe_sed 'listen: "127.0.0.1:8000"' "listen: \"0.0.0.0:${port}\""
    safe_sed 'jwtSecret: "replace-with-at-least-32-characters"' "jwtSecret: \"${jwt_secret}\""
    safe_sed 'credentialEncryptionKey: "replace-with-base64-key"' "credentialEncryptionKey: \"${enc_key}\""
    safe_sed 'username: "admin"' "username: \"${admin_user}\""
    safe_sed 'password: "replace-with-a-strong-password"' "password: \"${admin_pass}\""
    
    safe_sed 'driver: sqlite' "driver: ${db_driver}"
    if [ "$db_driver" = "postgres" ]; then
        safe_sed 'dsn: "postgres://user:password@127.0.0.1:5432/grok2api.*"' "dsn: \"${pg_dsn}\""
    fi

    safe_sed 'driver: memory' "driver: ${store_driver}"
    if [ "$store_driver" = "redis" ]; then
        safe_sed 'address: "127.0.0.1:6379"' "address: \"${redis_addr}\""
        safe_sed 'password: ""' "password: \"${redis_pass}\""
    fi

    echo -e "${GREEN}🎉 config.yaml 交互配置写入成功！${PLAIN}"
    echo -e "${YELLOW}======================================================="
    echo -e " 🚀 初始管理员安全凭证已成功配置："
    echo -e " 初始账户: ${admin_user}"
    echo -e " 初始密码: ${admin_pass}"
    [ "$is_random" = "true" ] && echo -e " (提示: 这是系统为您随机生成的强密码，请妥善保存！)"
    echo -e "=======================================================${PLAIN}"
    
    LISTEN_PORT="$port"
}

configure_nginx() {
    local backend_port=$1
    read -p "请输入您的解析域名 (例如 api.example.com 或 localhost): " domain_name < /dev/tty
    domain_name=${domain_name:-"localhost"}

    echo -e "${BLUE}正在配置 Nginx 反向代理...${PLAIN}"
    
    local nginx_conf_dir=""
    if [ -d "/etc/nginx/sites-available" ]; then
        nginx_conf_dir="/etc/nginx/sites-available"
    elif [ -d "/etc/nginx/conf.d" ]; then
        nginx_conf_dir="/etc/nginx/conf.d"
    else
        echo -e "${YELLOW}警告：未检测到标准 Nginx 配置目录，将尝试创建 /etc/nginx/conf.d${PLAIN}"
        mkdir -p /etc/nginx/conf.d
        nginx_conf_dir="/etc/nginx/conf.d"
    fi

    local conf_file="${nginx_conf_dir}/grok2api.conf"
    
    cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name ${domain_name};

    location / {
        proxy_pass http://127.0.0.1:${backend_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    if [ "$nginx_conf_dir" = "/etc/nginx/sites-available" ]; then
        mkdir -p /etc/nginx/sites-enabled
        ln -sf "$conf_file" "/etc/nginx/sites-enabled/grok2api.conf"
    fi

    if command -v nginx &> /dev/null; then
        if nginx -t &> /dev/null; then
            systemctl reload nginx || systemctl restart nginx
            echo -e "${GREEN}Nginx 反向代理配置成功，已自动重载！${PLAIN}"
            echo -e "${GREEN}您现在可以通过 http://${domain_name} 访问该服务。${PLAIN}"
        else
            echo -e "${RED}错误：Nginx 配置文件验证失败，请手动修复：${conf_file}${PLAIN}"
        fi
    else
        echo -e "${YELLOW}提示：Nginx 配置文件已保存在 ${conf_file}，但未检测到 Nginx 服务，请确保您已安装并启动 Nginx。${PLAIN}"
    fi
}

install_app() {
    detect_arch
    get_current_install_dir

    read -p "请输入自定义安装目录 [当前/默认: ${INSTALL_DIR}]: " custom_dir < /dev/tty
    INSTALL_DIR=${custom_dir:-"$INSTALL_DIR"}

    fetch_latest_release
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1

    local temp_tar="grok2api_latest.tar.gz"
    echo -e "${BLUE}正在下载构建包...${PLAIN}"
    if ! curl -L -o "$temp_tar" "$DOWNLOAD_URL"; then
        echo -e "${RED}下载失败，请检查网络。${PLAIN}"
        exit 1
    fi

    echo -e "${BLUE}正在解压...${PLAIN}"
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
    else
        get_current_port
    fi

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Grok2API Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/grok2api --config ${config_path}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    echo -e "${GREEN}程序安装完成并已启动！${PLAIN}"

    read -p "是否需要自动配置 Nginx 反向代理？ [y/N]: " setup_nginx < /dev/tty
    if [[ "$setup_nginx" =~ ^[Yy]$ ]]; then
        configure_nginx "$LISTEN_PORT"
    fi
}

update_app() {
    detect_arch
    get_current_install_dir

    if [ ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        echo -e "${RED}错误：未检测到已安装服务，请选择安装。${PLAIN}"
        return
    fi

    fetch_latest_release

    if [ -f "${INSTALL_DIR}/grok2api" ]; then
        cp "${INSTALL_DIR}/grok2api" "${INSTALL_DIR}/grok2api.bak"
    fi

    systemctl stop "$SERVICE_NAME"

    cd "$INSTALL_DIR" || exit 1
    local temp_tar="grok2api_update.tar.gz"
    if curl -L -o "$temp_tar" "$DOWNLOAD_URL" && tar -xzf "$temp_tar" --overwrite; then
        rm -f "$temp_tar"
        rm -f "grok2api.bak"
        systemctl start "$SERVICE_NAME"
        echo -e "${GREEN}Grok2API 已成功更新至 ${LATEST_TAG} 并已启动！${PLAIN}"
    else
        echo -e "${RED}更新失败，正在恢复备份...${PLAIN}"
        if [ -f "${INSTALL_DIR}/grok2api.bak" ]; then
            mv "${INSTALL_DIR}/grok2api.bak" "${INSTALL_DIR}/grok2api"
            systemctl start "$SERVICE_NAME"
        fi
        rm -f "$temp_tar"
    fi
}

uninstall_app() {
    get_current_install_dir
    read -p "确定要彻底卸载吗？ [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop "$SERVICE_NAME" &> /dev/null
        systemctl disable "$SERVICE_NAME" &> /dev/null
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        rm -f "/etc/nginx/sites-available/grok2api.conf"
        rm -f "/etc/nginx/sites-enabled/grok2api.conf"
        rm -f "/etc/nginx/conf.d/grok2api.conf"
        systemctl daemon-reload
        if command -v nginx &> /dev/null; then systemctl reload nginx &> /dev/null; fi

        read -p "是否同时删除安装目录及数据 (${INSTALL_DIR})？ [y/N]: " delete_data < /dev/tty
        if [[ "$delete_data" =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
        fi
        echo -e "${GREEN}卸载完成！${PLAIN}"
    fi
}

manage_service() {
    local action=$1
    get_current_install_dir
    if [ ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        echo -e "${RED}错误：服务未安装。${PLAIN}"
        return
    fi
    case $action in
        start) systemctl start "$SERVICE_NAME" ;;
        stop) systemctl stop "$SERVICE_NAME" ;;
        restart) systemctl restart "$SERVICE_NAME" ;;
        status) systemctl status "$SERVICE_NAME" ;;
        logs) journalctl -u "$SERVICE_NAME" -n 50 -f ;;
    esac
}

while true; do
    echo -e "
${BLUE}=========================================${PLAIN}
${GREEN}       Grok2API 一键部署/管理 (Linux)     ${PLAIN}
${BLUE}=========================================${PLAIN}
  ${BLUE}1.${PLAIN} 安装 / 重新安装 Grok2API
  ${BLUE}2.${PLAIN} 一键升级至最新版本 (保留配置)
  ${BLUE}3.${PLAIN} 启动服务
  ${BLUE}4.${PLAIN} 停止服务
  ${BLUE}5.${PLAIN} 重启服务
  ${BLUE}6.${PLAIN} 查看运行状态
  ${BLUE}7.${PLAIN} 查看运行日志
  ${BLUE}8.${PLAIN} 卸载 Grok2API
  ${BLUE}0.${PLAIN} 退出脚本
${BLUE}=========================================${PLAIN}"
    read -p "请选择操作 [0-8]: " choice < /dev/tty
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) manage_service start ;;
        4) manage_service stop ;;
        5) manage_service restart ;;
        6) manage_service status ;;
        7) manage_service logs ;;
        8) uninstall_app ;;
        0) exit 0 ;;
    esac
done