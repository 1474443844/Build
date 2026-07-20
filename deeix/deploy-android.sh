#!/usr/bin/env bash
# DEEIX-Chat Android (Termux) 部署脚本
# curl -fsSL https://raw.githubusercontent.com/1474443844/Build/main/deeix/deploy-android.sh | bash

set -euo pipefail

REPO="1474443844/Build"
APP_NAME="deeix-chat"
# Termux 下用 home 目录更稳
INSTALL_DIR="${INSTALL_DIR:-$HOME/deeix-chat}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
VERSION="${VERSION:-}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ 缺少命令: $1"
    echo "   可尝试: pkg install $1"
    exit 1
  }
}

# 基础检查
if [ -z "${PREFIX:-}" ] && [ -z "${TERMUX_VERSION:-}" ]; then
  echo "⚠️ 未检测到典型 Termux 环境，仍继续尝试安装..."
fi

need_cmd curl
need_cmd tar
need_cmd uname

arch="$(uname -m)"
case "$arch" in
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "❌ Android 当前仅支持 arm64，检测到: $arch"
    exit 1
    ;;
esac

ASSET="${APP_NAME}-android-${ARCH}.tar.gz"

if [ -z "$VERSION" ]; then
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
  URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
fi

echo "==> DEEIX-Chat Android 部署"
echo "    架构: ${ARCH}"
echo "    安装目录: ${INSTALL_DIR}"
echo "    下载: ${URL}"

# 可选依赖
if ! command -v curl >/dev/null 2>&1; then
  pkg install -y curl
fi
if ! command -v tar >/dev/null 2>&1; then
  pkg install -y tar
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fL --progress-bar -o "${TMP_DIR}/${ASSET}" "$URL"

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
tar -xzf "${TMP_DIR}/${ASSET}" -C "$INSTALL_DIR"

if [ ! -f "${INSTALL_DIR}/${APP_NAME}" ]; then
  FOUND="$(find "$INSTALL_DIR" -type f -name "${APP_NAME}" | head -n 1 || true)"
  if [ -n "$FOUND" ]; then
    PARENT="$(dirname "$FOUND")"
    if [ "$PARENT" != "$INSTALL_DIR" ]; then
      mv "$PARENT"/* "$INSTALL_DIR"/ 2>/dev/null || true
    fi
  fi
fi

if [ ! -f "${INSTALL_DIR}/${APP_NAME}" ]; then
  echo "❌ 未找到可执行文件 ${APP_NAME}"
  ls -la "$INSTALL_DIR"
  exit 1
fi

chmod +x "${INSTALL_DIR}/${APP_NAME}"
mkdir -p "${INSTALL_DIR}/storage" "${INSTALL_DIR}/data"

WRAPPER="${BIN_DIR}/${APP_NAME}"
cat > "$WRAPPER" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
cd "${INSTALL_DIR}"
export FRONTEND_DIST_DIR="\${FRONTEND_DIST_DIR:-./frontend/out}"
exec "${INSTALL_DIR}/${APP_NAME}" "\$@"
EOF
# 若 shebang 路径不对，退回 env
if [ ! -x /data/data/com.termux/files/usr/bin/bash ]; then
  cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${INSTALL_DIR}"
export FRONTEND_DIST_DIR="\${FRONTEND_DIST_DIR:-./frontend/out}"
exec "${INSTALL_DIR}/${APP_NAME}" "\$@"
EOF
fi
chmod +x "$WRAPPER"

echo ""
echo "✅ Android 部署完成"
echo "   安装目录: ${INSTALL_DIR}"
echo "   启动命令: ${APP_NAME}"
echo ""
echo "建议:"
echo "  termux-wake-lock"
echo "  ${APP_NAME}"
echo ""
echo "后台示例:"
echo "  nohup ${APP_NAME} > ${INSTALL_DIR}/deeix.log 2>&1 &"
echo ""
echo "卸载:"
echo "  rm -rf \"${INSTALL_DIR}\" \"${BIN_DIR}/${APP_NAME}\""