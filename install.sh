#!/bin/bash
set -euo pipefail

VERSION="${1:-latest}"
REPO="xdfnet/iRelay"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

echo "==> 下载 iRelay $VERSION..."

# 确定下载 URL
if [ "$VERSION" = "latest" ]; then
    URL="https://github.com/$REPO/releases/latest/download/iRelay.zip"
else
    URL="https://github.com/$REPO/releases/download/v$VERSION/iRelay.zip"
fi

# 下载到临时目录
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

echo "   从 $URL 下载..."
curl -sL -o "$TMPDIR/iRelay.zip" "$URL"

echo "==> 安装到 $INSTALL_DIR..."
unzip -qo "$TMPDIR/iRelay.zip" -d "$TMPDIR"
if [ -d "$INSTALL_DIR/iRelay.app" ]; then
    rm -rf "$INSTALL_DIR/iRelay.app"
fi
mv "$TMPDIR/iRelay.app" "$INSTALL_DIR/"

echo ""
echo "✅ iRelay 已安装到 $INSTALL_DIR/iRelay.app"
echo ""
echo "运行: open $INSTALL_DIR/iRelay.app"
echo ""
echo "首次运行请右键 -> 打开（未签名应用需要确认）"
