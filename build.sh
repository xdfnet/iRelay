#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="iRelay"
CONFIG="${1:-release}"

if [ "$CONFIG" = "debug" ]; then
    BUILD_FLAG="--configuration debug"
else
    BUILD_FLAG="--configuration release"
fi

echo "==> 编译 $PROJECT ($CONFIG)..."
swift build $BUILD_FLAG --product "$PROJECT"

BINARY_PATH=$(swift build $BUILD_FLAG --show-bin-path)/"$PROJECT"
APP_BUNDLE="./$PROJECT.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

echo "==> 组装 $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

cp "$BINARY_PATH" "$APP_MACOS/$PROJECT"
cp Resources/Info.plist "$APP_CONTENTS/"
cp Resources/AppIcon.icns "$APP_RESOURCES/"

echo "==> 签名..."
codesign --force --sign "4A287668E97BC130AA6D19F4D64799394CAACBAD" "$APP_BUNDLE"

if [ "$CONFIG" = "release" ]; then
    echo "==> 打包 zip..."
    zip -r "${PROJECT}.zip" "$PROJECT.app"
    echo "   ${PROJECT}.zip"
fi

echo "==> 安装..."
rm -rf /Applications/iRelay.app
cp -r "$APP_BUNDLE" /Applications/
xattr -dr com.apple.quarantine /Applications/iRelay.app
echo "   已安装到 /Applications/iRelay.app"
