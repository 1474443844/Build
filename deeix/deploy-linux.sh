#!/usr/bin/env bash
# DEEIX-Chat Linux 部署脚本
# 也可单独执行：
#   curl -fsSL https://raw.githubusercontent.com/1474443844/Build/main/deeix/deploy-linux.sh | bash
# 指定版本：
#   VERSION=deeix-chat-0.3.3 curl -fsSL ... | bash

set -euo pipefail

REPO="1474443844/Build"
APP_NAME="deeix-chat"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/share/deeix-chat}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
VERSION="${VERSION:-}"   # 空 = latest；可填 tag，如 deeix-chat-0.3.3

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ 缺少命令: $1"
    exit 1
  }
}

need_cmd curl
need_cmd tar
need_cmd uname

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "❌ 不支持的架构: $arch"
    exit 1
    ;;
esac

ASSET="${APP_NAME}-linux-${ARCH}.tar.gz"

if [ -z "$VERSION" ]; then
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
  URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
fi

echo "==> DEEIX-Chat Linux 部署"
echo "    架构: ${ARCH}"
echo "    安装目录: ${INSTALL_DIR}"
echo "    下载: ${URL}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fL --progress-bar -o "${TMP_DIR}/${ASSET}" "$URL"

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
tar -xzf "${TMP_DIR}/${ASSET}" -C "$INSTALL_DIR"

# 兼容资产内有无顶层目录的情况
if [ ! -x "${INSTALL_DIR}/${APP_NAME}" ]; then
  FOUND="$(find "$INSTALL_DIR" -type f -name "${APP_NAME}" | head -n 1 || true)"
  if [ -n "$FOUND" ]; then
    # 若在子目录，整包上移一层更清晰
    PARENT="$(dirname "$FOUND")"
    if [ "$PARENT" != "$INSTALL_DIR" ]; then
      shopt -s dotglob
      mv "$PARENT"/* "$INSTALL_DIR"/ 2>/dev/null || true
      shopt -u dotglob
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

# 启动包装脚本
WRAPPER="${BIN_DIR}/${APP_NAME}"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${INSTALL_DIR}"
export FRONTEND_DIST_DIR="\${FRONTEND_DIST_DIR:-./frontend/out}"
exec "${INSTALL_DIR}/${APP_NAME}" "\$@"
EOF
chmod +x "$WRAPPER"

# 写入 PATH 提示
ensure_path_line() {
  local rc="$1"
  local line="export PATH=\"${BIN_DIR}:\$PATH\""
  [ -f "$rc" ] || return 0
  if ! grep -Fqs "$BIN_DIR" "$rc"; then
    echo "$line" >> "$rc"
    echo "    已写入 PATH 到: $rc"
  fi
}

ensure_path_line "$HOME/.bashrc"
ensure_path_line "$HOME/.zshrc"
ensure_path_line "$HOME/.profile"

echo ""
echo "✅ Linux 部署完成"
echo "   安装目录: ${INSTALL_DIR}"
echo "   启动命令: ${APP_NAME}"
echo ""
echo "立即运行:"
echo "  export PATH=\"${BIN_DIR}:\$PATH\""
echo "  ${APP_NAME}"
echo ""
echo "后台运行示例:"
echo "  nohup ${APP_NAME} > ${INSTALL_DIR}/deeix.log 2>&1 &"
echo ""
echo "卸载:"
echo "  rm -rf \"${INSTALL_DIR}\" \"${BIN_DIR}/${APP_NAME}\""