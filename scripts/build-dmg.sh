#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${SOTTO_APP_OUTPUT:-$SOURCE_ROOT/artifacts/Sotto.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="${SOTTO_DMG_OUTPUT:-$SOURCE_ROOT/artifacts/Sotto-${VERSION}-arm64.dmg}"
STAGING="$(mktemp -d "$SOURCE_ROOT/artifacts/.sotto-dmg.XXXXXX")"
cleanup() {
  local result=$?
  rm -rf "$STAGING"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ ! -d "$APP" ]; then
  echo "App not found: $APP" >&2
  exit 1
fi
if [ -e "$DMG" ]; then
  echo "DMG already exists; refusing to overwrite: $DMG" >&2
  exit 1
fi

# Standard drag-to-Applications layout. The readme explains the local signing
# limitation because this build has no Developer ID or notarization.
cp -R "$APP" "$STAGING/Sotto.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<'TEXT'
Sotto · 安装说明

1. 将左侧的「Sotto.app」拖入右侧的「Applications」文件夹。
2. 从「应用程序」或 Launchpad 打开 Sotto。
3. 首次连接微信时，按应用内提示授予“完全磁盘访问”和“辅助功能”权限。

本构建使用本机自签名身份，没有 Apple Developer ID，也没有公证。
如果系统提示“无法验证开发者”，请在 Finder 中右键应用选择“打开”，
或到“系统设置 → 隐私与安全性”中允许打开；不要关闭 Gatekeeper 或 SIP。

当前构建为 arm64、macOS 27。更新应用后，如系统重新询问权限，
请在系统设置中移除旧条目，再重新添加当前「Sotto.app」并授权。
TEXT
chmod 644 "$STAGING/安装说明.txt"

hdiutil create -volname "Sotto" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"

# Sign the disk image with the same local identity used for the app, when the
# local signing state is available. This is not notarization.
SIGNING_STATE="$HOME/Library/Application Support/moe.tachyon.sotto.build-signing"
if [ -f "$SIGNING_STATE/signing.keychain-db" ]; then
  IDENTITY="$(python3 "$SOURCE_ROOT/scripts/local-signing.py" preflight | python3 -c 'import json,sys; print(json.load(sys.stdin)["certificateSHA1"])')"
  /usr/bin/codesign --force --sign "$IDENTITY" --keychain "$SIGNING_STATE/signing.keychain-db" --timestamp=none "$DMG"
  /usr/bin/codesign --verify "$DMG"
fi

shasum -a 256 "$DMG"
echo "Built: $DMG"
