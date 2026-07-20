#!/usr/bin/env bash
# DEEIX 统一环境分发引导脚本
# curl -fsSL https://raw.githubusercontent.com/1474443844/Build/main/deeix/deploy.sh | bash

set -euo pipefail

BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/1474443844/Build/main/deeix}"

OS="$(uname -s)"

# Android (Termux / 自定义 PTY)
if [ -n "${TERMUX_VERSION:-}" ] || [ "$(uname -o 2>/dev/null || true)" = "Android" ]; then
  echo "检测到运行环境为: Android"
  bash <(curl -fsSL "${BASE_URL}/deploy-android.sh")
  exit 0
fi

# Windows (Git Bash / MSYS / Cygwin) → 提示用 PowerShell
case "$OS" in
  MINGW*|MSYS*|CYGWIN*)
    echo "检测到 Windows (Git Bash/MSYS)。"
    echo "请在 PowerShell 中执行："
    echo "  irm https://raw.githubusercontent.com/1474443844/Build/main/deeix/deploy-windows.ps1 | iex"
    exit 1
    ;;
esac

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
    echo "Windows 用户请使用 PowerShell："
    echo "  irm https://raw.githubusercontent.com/1474443844/Build/main/deeix/deploy.ps1 | iex"
    exit 1
    ;;
esac