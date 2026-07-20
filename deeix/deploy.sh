#!/usr/bin/env bash
# DEEIX-Chat 一键部署脚本
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/DEEIX-AI/DEEIX-Chat/main/install.sh | bash
#   或者指定版本：
#   VERSION=0.3.3 curl -fsSL ... | bash

set -euo pipefail

REPO="DEEIX-AI/DEEIX-Chat"
DEFAULT_INSTALL_DIR="$HOME/.local/share/deeix-chat"
DEFAULT_BIN_DIR="$HOME/.local/bin"

# 可通过环境变量覆盖
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
BIN_DIR="${BIN_DIR:-$DEFAULT_BIN_DIR}"
VERSION="${VERSION:-}"

echo "==> DEEIX-Chat 一键部署"
echo "    仓库: $REPO"

# ==================== 平台检测 ====================
detect_platform() {
  local os arch

  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)

  # Termux / Android 优先识别
  if [[ -n "${TERMUX_VERSION:-}" ]] || [[ "$PREFIX" == *"termux"* ]] || [[ -d /data/data/com.termux/files ]]; then
    os="android"
    arch="arm64"
  fi

  # Windows (Git Bash / MSYS / Cygwin / MinGW)
  if [[ "$os" == msys* || "$os" == mingw* || "$os" == cygwin* ]]; then
    os="windows"
  fi

  case "$os" in
    linux)   os="linux" ;;
    darwin)  os="darwin" ;;
    android) os="android" ;;
    windows) os="windows" ;;
    *) echo "❌ 不支持的系统: $os"; exit 1 ;;
  esac

  case "$arch" in
    x86_64 | amd64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    armv7l | armv7) arch="arm" ;;   # 预留，当前 workflow 仅提供 arm64
    *) echo "❌ 不支持的架构: $arch"; exit 1 ;;
  esac

  # 仅 Android arm64（与 workflow 一致）
  if [[ "$os" == "android" && "$arch" != "arm64" ]]; then
    echo "⚠️ Android 当前仅支持 arm64"
    arch="arm64"
  fi

  # Windows 当前仅 amd64
  if [[ "$os" == "windows" && "$arch" != "amd64" ]]; then
    arch="amd64"
  fi

  echo "检测到平台: $os / $arch"
  OS="$os"
  ARCH="$arch"
}

detect_platform

# ==================== 选择下载文件 ====================
case "$OS-$ARCH" in
  linux-amd64|linux-arm64|darwin-amd64|darwin-arm64|android-arm64)
    EXT="tar.gz"
    ;;
  windows-amd64)
    EXT="zip"
    ;;
  *)
    echo "❌ 当前版本暂不支持 $OS-$ARCH"
    exit 1
    ;;
esac

ASSET="deeix-chat-${OS}-${ARCH}.${EXT}"

if [[ -z "$VERSION" ]]; then
  DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
  DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
fi

echo "==> 下载: $ASSET"
echo "    URL: $DOWNLOAD_URL"

# ==================== 下载与解压 ====================
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$TMP_DIR"
curl -fL --progress-bar -o "$ASSET" "$DOWNLOAD_URL" || {
  echo "❌ 下载失败，请检查版本是否存在或网络"
  exit 1
}

mkdir -p "$INSTALL_DIR"

if [[ "$EXT" == "tar.gz" ]]; then
  tar -xzf "$ASSET" -C "$INSTALL_DIR"
else
  # Windows zip
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$ASSET" -d "$INSTALL_DIR"
  else
    # Git Bash 兜底
    powershell.exe -NoProfile -Command "Expand-Archive -Path '$ASSET' -DestinationPath '$INSTALL_DIR' -Force"
  fi
fi

# 找到可执行文件
if [[ "$OS" == "windows" ]]; then
  BIN_NAME="deeix-chat.exe"
else
  BIN_NAME="deeix-chat"
fi

if [[ ! -f "$INSTALL_DIR/$BIN_NAME" ]]; then
  # 有些打包方式会在子目录
  FOUND_BIN=$(find "$INSTALL_DIR" -name "$BIN_NAME" -type f | head -n 1 || true)
  if [[ -n "$FOUND_BIN" ]]; then
    mv "$FOUND_BIN" "$INSTALL_DIR/$BIN_NAME"
  fi
fi

if [[ ! -f "$INSTALL_DIR/$BIN_NAME" ]]; then
  echo "❌ 安装目录中未找到 $BIN_NAME"
  ls -la "$INSTALL_DIR"
  exit 1
fi

chmod +x "$INSTALL_DIR/$BIN_NAME" 2>/dev/null || true

echo "==> 安装到: $INSTALL_DIR"

# ==================== 创建启动器（自动设置前端路径） ====================
mkdir -p "$BIN_DIR"

WRAPPER="$BIN_DIR/deeix-chat"
cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
INSTALL_DIR="__INSTALL_DIR__"
BIN_NAME="__BIN_NAME__"

cd "$INSTALL_DIR" || exit 1
export FRONTEND_DIST_DIR="./frontend/out"
exec "$INSTALL_DIR/$BIN_NAME" "$@"
EOF

# 替换占位符
sed -i "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$WRAPPER"
sed -i "s|__BIN_NAME__|$BIN_NAME|g" "$WRAPPER"

chmod +x "$WRAPPER"

# Windows 额外提供 .bat
if [[ "$OS" == "windows" ]]; then
  cat > "$BIN_DIR/deeix-chat.bat" <<EOF
@echo off
cd /d "$INSTALL_DIR"
set FRONTEND_DIST_DIR=./frontend/out
"$INSTALL_DIR\\$BIN_NAME" %*
EOF
fi

echo "==> 创建启动命令: $WRAPPER"

# ==================== PATH 处理 ====================
add_to_path() {
  local rc_file="$1"
  if [[ -f "$rc_file" ]]; then
    if ! grep -q "$BIN_DIR" "$rc_file" 2>/dev/null; then
      echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$rc_file"
      echo "    已添加到 $rc_file，请执行: source $rc_file"
    fi
  fi
}

if [[ "$OS" != "windows" ]]; then
  add_to_path "$HOME/.bashrc"
  add_to_path "$HOME/.zshrc"
  add_to_path "$HOME/.profile"

  # Termux
  if [[ "$OS" == "android" ]]; then
    add_to_path "$PREFIX/etc/bash.bashrc" || true
  fi
fi

# ==================== 完成提示 ====================
echo ""
echo "✅ 部署完成！"
echo ""
echo "安装位置: $INSTALL_DIR"
echo "启动命令: deeix-chat"
echo ""
echo "手动运行方式:"
echo "  cd $INSTALL_DIR"
echo "  FRONTEND_DIST_DIR=./frontend/out ./$BIN_NAME"
echo ""
echo "常用参数示例:"
echo "  deeix-chat --help"
echo ""
echo "数据目录（建议保留）:"
echo "  $INSTALL_DIR/storage"
echo "  $INSTALL_DIR/data"
echo ""

if [[ "$OS" == "linux" ]]; then
  echo "Linux 后台运行建议:"
  echo "  nohup deeix-chat > deeix.log 2>&1 &"
  echo "  或使用 systemd 用户服务"
fi

if [[ "$OS" == "android" ]]; then
  echo "Termux 使用提示:"
  echo "  termux-wake-lock"
  echo "  deeix-chat"
fi

if [[ "$OS" == "windows" ]]; then
  echo "Windows 使用提示:"
  echo "  在 Git Bash 或 PowerShell 中运行: deeix-chat"
  echo "  或双击 $BIN_DIR/deeix-chat.bat"
fi

echo ""
echo "如需卸载： rm -rf $INSTALL_DIR $BIN_DIR/deeix-chat*"