#!/bin/bash
# 릴리스 빌드 → .app 번들 조립 → ~/Applications 에 설치.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Claude Account Switcher"
BUNDLE_ID="io.github.claudeaccountswitcher"
BIN="ClaudeSwitcher"

echo "==> swift build -c release"
swift build -c release
BUILT=".build/release/$BIN"
[ -f "$BUILT" ] || { echo "빌드 산출물 없음: $BUILT"; exit 1; }

APP="$HOME/Applications/$APP_NAME.app"
echo "==> .app 조립: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal tool</string>
</dict>
</plist>
PLIST

# 애드혹 서명 (Keychain ACL 안정성 위해). 실패해도 계속.
codesign --force --sign - "$APP/Contents/MacOS/$BIN" 2>/dev/null || true
codesign --force --sign - "$APP" 2>/dev/null || true

echo "==> 완료: $APP"
echo "실행: open \"$APP\""
