#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DELIVERY_ROOT="$SOURCE_ROOT/artifacts"
OUTPUT_APP="${SOTTO_APP_OUTPUT:-$DELIVERY_ROOT/Sotto.app}"
python3 "$SOURCE_ROOT/scripts/local-signing.py" preflight
# Native SwiftPM works with this CLT-only installation. Explicit UIState typealias avoids SDK27 macro packaging bug.
swift build --build-system native -c release --package-path "$SOURCE_ROOT" --product Sotto
BINARY_DIR="$(swift build --build-system native -c release --package-path "$SOURCE_ROOT" --show-bin-path)"
mkdir -p "$(dirname "$OUTPUT_APP")"
STAGING_ROOT="$(mktemp -d "$(dirname "$OUTPUT_APP")/.sotto-build.XXXXXX")"
BACKUP_APP=""
cleanup() {
  local result=$?
  trap - EXIT
  if [ -n "${BACKUP_APP:-}" ] && [ ! -e "$OUTPUT_APP" ] && [ ! -L "$OUTPUT_APP" ] && [ -e "$BACKUP_APP" ]; then
    if ! mv "$BACKUP_APP" "$OUTPUT_APP"; then
      echo "Could not restore previous app; backup retained at: $BACKUP_APP" >&2
      result=1
    fi
  fi
  rm -rf "$STAGING_ROOT"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
APP="$STAGING_ROOT/Sotto.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Backend" "$APP/Contents/Resources/Frameworks" "$APP/Contents/Resources/ThirdParty"
if [ ! -f "$SOURCE_ROOT/Resources/AppIcon.icns" ]; then python3 "$SOURCE_ROOT/scripts/make-icon.py"; fi
cp "$SOURCE_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BINARY_DIR/Sotto" "$APP/Contents/MacOS/Sotto"
for name in bootstrap.py capture_keys.py reader.py sqlcipher_probe.py media.py; do cp "$SOURCE_ROOT/Backend/$name" "$APP/Contents/Resources/Backend/$name"; done
cp "$SOURCE_ROOT/ThirdParty/"*.txt "$APP/Contents/Resources/ThirdParty/"
SQLCIPHER_PREFIX="$(brew --prefix sqlcipher)"
ZSTD_PREFIX="$(brew --prefix zstd)"
CRYPTO_PREFIX="$(brew --prefix openssl@4)"
cp -L "$SQLCIPHER_PREFIX/lib/libsqlcipher.dylib" "$APP/Contents/Resources/Frameworks/libsqlcipher.dylib"
cp -L "$ZSTD_PREFIX/lib/libzstd.dylib" "$APP/Contents/Resources/Frameworks/libzstd.dylib"
cp -L "$CRYPTO_PREFIX/lib/libcrypto.4.dylib" "$APP/Contents/Resources/Frameworks/libcrypto.4.dylib"
chmod u+w "$APP/Contents/Resources/Frameworks/"*.dylib
install_name_tool -id '@loader_path/libsqlcipher.dylib' "$APP/Contents/Resources/Frameworks/libsqlcipher.dylib"
install_name_tool -change "$CRYPTO_PREFIX/lib/libcrypto.4.dylib" '@loader_path/libcrypto.4.dylib' "$APP/Contents/Resources/Frameworks/libsqlcipher.dylib"
install_name_tool -id '@loader_path/libzstd.dylib' "$APP/Contents/Resources/Frameworks/libzstd.dylib"
install_name_tool -id '@loader_path/libcrypto.4.dylib' "$APP/Contents/Resources/Frameworks/libcrypto.4.dylib"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Sotto</string>
<key>CFBundleDisplayName</key><string>Sotto</string>
<key>CFBundleIdentifier</key><string>moe.tachyon.sotto</string>
<key>CFBundleExecutable</key><string>Sotto</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
<key>LSMultipleInstancesProhibited</key><true/>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Sotto · 本机微信阅读助手</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
python3 "$SOURCE_ROOT/scripts/local-signing.py" sign-app "$APP"
# Keep the previous output intact until the entire candidate has been signed
# and verified. A failed replacement keeps its recoverable backup beside it.
BACKUP_APP="${OUTPUT_APP}.previous.$$"
if [ -e "$BACKUP_APP" ] || [ -L "$BACKUP_APP" ]; then
  echo "Previous app backup already exists; refusing to overwrite it." >&2
  exit 1
fi
if [ -e "$OUTPUT_APP" ]; then mv "$OUTPUT_APP" "$BACKUP_APP"; fi
if ! mv "$APP" "$OUTPUT_APP"; then
  if [ -e "$BACKUP_APP" ]; then mv "$BACKUP_APP" "$OUTPUT_APP"; fi
  exit 1
fi
if [ -e "$BACKUP_APP" ]; then rm -rf "$BACKUP_APP"; fi
echo "Built: $OUTPUT_APP"
