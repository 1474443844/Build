#!/usr/bin/env bash

# ==============================================================================
# Grok2API 统一环境分发引导脚本 (1474443844/Build 专用)
# ==============================================================================

BASE_URL="https://raw.githubusercontent.com/1474443844/Build/main/grok2api"

OS="$(uname -s)"

# 1. 检测是否在 Android 环境下运行 (支持 Termux 及自定义 PTY)
if [ -n "$TERMUX_VERSION" ] || [ "$(uname -o 2>/dev/null)" = "Android" ]; then
    echo "检测到运行环境为: Android"
    bash <(curl -fsSL "${BASE_URL}/deploy-android.sh")
    exit 0
fi

# 2. 根据 Unix 核心分别引导 Linux & macOS
case "$OS" in
    Linux)
        echo "检测到运行环境为: Linux"
        bash <(curl -fsSL "${BASE_URL}/deploy-linux.sh")
        ;;
    Darwin)
        echo "检测到运行环境为: macOS"
        bash <(curl -fsSL "${BASE_URL}/deploy-mac.sh")
        ;;
    *)
        echo "暂不支持您的操作系统: $OS"
        echo "如果是 Windows 用户，请使用 PowerShell 专属指令。"
        exit 1
        ;;
esac