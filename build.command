#!/bin/zsh
set -eu
cd "${0:A:h}"
WORLDWATCH_XCODE=/Applications/Xcode.app/Contents/Developer
if [[ ! -x "$WORLDWATCH_XCODE/usr/bin/xcodebuild" ]]; then
  print -u2 '请先安装 Xcode，并在工程中选择你的 Apple 开发团队。'
  exit 1
fi
mkdir -p "$PWD/.build"
DEVELOPER_DIR="$WORLDWATCH_XCODE" "$WORLDWATCH_XCODE/usr/bin/xcodebuild" -quiet \
  -project WorldWatch.xcodeproj -scheme WorldWatch -configuration Release \
  -derivedDataPath "$PWD/.build/NativeSigned" \
  -destination "platform=macOS,arch=$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  -allowProvisioningUpdates build
WORLDWATCH_PRODUCT="$PWD/.build/NativeSigned/Build/Products/Release/世界动态.app"
codesign --verify --deep --strict "$WORLDWATCH_PRODUCT"
mkdir -p "$PWD/dist"
if [[ -d "$PWD/dist/世界动态.app" ]]; then
  WORLDWATCH_PREVIOUS=$(mktemp -d "$PWD/.build/previous-distribution.XXXXXX")
  mv "$PWD/dist/世界动态.app" "$WORLDWATCH_PREVIOUS/世界动态.app"
fi
ditto "$WORLDWATCH_PRODUCT" "$PWD/dist/世界动态.app"
codesign --verify --deep --strict "$PWD/dist/世界动态.app"
print "已生成开发签名版本：$PWD/dist/世界动态.app"
