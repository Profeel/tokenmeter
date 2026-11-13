#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

"${SCRIPT_DIR}/build.sh"

BIN_DIR="${ROOT_DIR}/.build/release"
TARGET_BIN_DIR="${HOME}/.local/bin"

echo "==> Installing CLI to ${TARGET_BIN_DIR}/tokenmeter..."
mkdir -p "${TARGET_BIN_DIR}"
cp -f "${BIN_DIR}/tokenmeter" "${TARGET_BIN_DIR}/tokenmeter"
chmod +x "${TARGET_BIN_DIR}/tokenmeter"

echo "==> Installing App to /Applications/TokenMeter.app and ~/Applications/TokenMeter.app..."
mkdir -p "${HOME}/Applications"

if [ -w "/Applications" ]; then
    rm -rf "/Applications/TokenMeter.app"
    cp -R "${ROOT_DIR}/TokenMeter.app" "/Applications/TokenMeter.app"
    echo "    ✓ Installed to /Applications/TokenMeter.app"
fi

rm -rf "${HOME}/Applications/TokenMeter.app"
cp -R "${ROOT_DIR}/TokenMeter.app" "${HOME}/Applications/TokenMeter.app"
echo "    ✓ Installed to ~/Applications/TokenMeter.app"

mkdir -p "${HOME}/.tokenmeter"
echo ""
echo "🎉 TokenMeter 安装完成！"
echo "  • 菜单栏应用: open /Applications/TokenMeter.app"
echo "  • 终端 CLI:   tokenmeter status"
echo ""
