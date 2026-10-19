#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DELIVERY_ROOT="$SOURCE_ROOT/artifacts"
OUTPUT_APP="${SOTTO_APP_OUTPUT:-$DELIVERY_ROOT/Sotto.app}"
export MACOSX_DEPLOYMENT_TARGET=26.0
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export SOTTO_DEPENDENCY_ROOT="${SOTTO_DEPENDENCY_ROOT:-$SOURCE_ROOT/.build/macos26-dependencies}"
BUILD_DIR="$SOURCE_ROOT/.build/macos26"
python3 "$SOURCE_ROOT/scripts/local-signing.py" preflight
# Build bundled libraries for the same minimum OS instead of copying bottles
# whose deployment target follows the build machine's current macOS version.
bash "$SOURCE_ROOT/scripts/build-dependencies.sh"
swift build --build-system native -c release --package-path "$SOURCE_ROOT" --scratch-path "$BUILD_DIR" --sdk "$SDKROOT" --triple arm64-apple-macosx26.0 --product Sotto
BINARY_DIR="$(swift build --build-system native -c release --package-path "$SOURCE_ROOT" --scratch-path "$BUILD_DIR" --sdk "$SDKROOT" --triple arm64-apple-macosx26.0 --show-bin-path)"
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
python3 "$SOURCE_ROOT/scripts/embed-sparkle.py" "$BUILD_DIR/artifacts" "$APP"
for name in bootstrap.py capture_keys.py reader.py sqlcipher_probe.py media.py; do cp "$SOURCE_ROOT/Backend/$name" "$APP/Contents/Resources/Backend/$name"; done
cp "$SOURCE_ROOT/ThirdParty/"*.txt "$SOURCE_ROOT/ThirdParty/"*.md "$APP/Contents/Resources/ThirdParty/"
cp "$SOURCE_ROOT/LICENSE" "$SOURCE_ROOT/NOTICE" "$APP/Contents/Resources/"
SQLCIPHER_PREFIX="$SOTTO_DEPENDENCY_ROOT/prefix/sqlcipher"
ZSTD_PREFIX="$SOTTO_DEPENDENCY_ROOT/prefix/zstd"
CRYPTO_PREFIX="$SOTTO_DEPENDENCY_ROOT/prefix/openssl@4"
cp -L "$SQLCIPHER_PREFIX/lib/libsqlcipher.dylib" "$APP/Contents/Resources/Frameworks/libsqlcipher.dylib"
cp -L "$ZSTD_PREFIX/lib/libzstd.dylib" "$APP/Contents/Resources/Frameworks/libzstd.dylib"
cp -L "$CRYPTO_PREFIX/lib/libcrypto.4.dylib" "$APP/Contents/Resources/Frameworks/libcrypto.4.dylib"
chmod u+w "$APP/Contents/Resources/Frameworks/"*.dylib
install_name_tool -id '@loader_path/libsqlcipher.dylib' "$APP/Contents/Resources/Frameworks/libsqlcipher.dylib"
python3 - "$APP/Contents/Resources/Frameworks/libsqlcipher.dylib" <<'PY'
import re, subprocess, sys
library = sys.argv[1]
linked = subprocess.check_output(["otool", "-L", library], text=True)
crypto = [match[1] for line in linked.splitlines()
          if (match := re.match(r"\s+(.+) \(compatibility version", line))
          and match[1].endswith("/libcrypto.4.dylib")]
if len(crypto) != 1:
    raise SystemExit("Expected exactly one libcrypto.4 dependency in SQLCipher")
subprocess.run(["install_name_tool", "-change", crypto[0],
                "@loader_path/libcrypto.4.dylib", library], check=True)
PY
install_name_tool -id '@loader_path/libzstd.dylib' "$APP/Contents/Resources/Frameworks/libzstd.dylib"
install_name_tool -id '@loader_path/libcrypto.4.dylib' "$APP/Contents/Resources/Frameworks/libcrypto.4.dylib"
# These libraries now use only explicit system/@loader_path dependencies.
# Drop build-prefix search paths so no packaged image searches outside the app.
python3 - "$APP/Contents/Resources/Frameworks" <<'PYRPATH'
import pathlib, re, subprocess, sys
for library in sorted(pathlib.Path(sys.argv[1]).glob("*.dylib")):
    commands = subprocess.check_output(["otool", "-l", str(library)], text=True)
    for block in re.split(r"(?m)^Load command \d+\s*$", commands)[1:]:
        if not re.search(r"(?m)^\s*cmd LC_RPATH\s*$", block):
            continue
        match = re.search(r"(?m)^\s*path (.+) \(offset \d+\)\s*$", block)
        if not match:
            raise SystemExit("Could not inspect library runpath")
        subprocess.run(["install_name_tool", "-delete_rpath", match[1], str(library)], check=True)
PYRPATH
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
<key>CFBundleShortVersionString</key><string>0.0.4</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
<key>LSMultipleInstancesProhibited</key><true/>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 CyanTachyon</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
python3 - "$APP/Contents/Info.plist" "$SOURCE_ROOT/Resources/UpdatePublicKey.txt" <<'PYKEY'
import base64, pathlib, plistlib, sys
key = pathlib.Path(sys.argv[2]).read_text(encoding="ascii").strip()
try:
    decoded = base64.b64decode(key, validate=True)
except ValueError:
    raise SystemExit("UpdatePublicKey.txt must contain a valid Ed25519 public key")
if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != key:
    raise SystemExit("UpdatePublicKey.txt must contain one canonical 32-byte Ed25519 public key")
path = pathlib.Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info.update(SUPublicEDKey=key,
            SUFeedURL="https://github.com/CyanTachyon/Sotto/releases/latest/download/appcast.xml",
            SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
            SUSendProfileInfo=False,
            SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
path.write_bytes(plistlib.dumps(info))
PYKEY
python3 "$SOURCE_ROOT/scripts/check-compatibility.py" "$APP"
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
