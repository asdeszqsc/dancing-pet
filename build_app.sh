#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "▶︎ 컴파일..."
swiftc main.swift -o dancing-pet -framework Cocoa -framework CoreAudio

APP="DancingPet.app"
echo "▶︎ .app 번들 구성: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp dancing-pet "$APP/Contents/MacOS/DancingPet"
cp -R assets "$APP/Contents/Resources/assets"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>DancingPet</string>
  <key>CFBundleDisplayName</key>     <string>DancingPet</string>
  <key>CFBundleIdentifier</key>      <string>com.example.dancingpet</string>
  <key>CFBundleExecutable</key>      <string>DancingPet</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>12.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

IDENTITY="DancingPet Self-Signed"
KCPASS="dancingpet"
SIGN_KEYCHAIN="$HOME/Library/Keychains/dancingpet-signing.keychain-db"

if [ -f "$SIGN_KEYCHAIN" ]; then
    echo "▶︎ 고정 인증서로 서명 (권한 유지됨)..."
    security unlock-keychain -p "$KCPASS" "$SIGN_KEYCHAIN" 2>/dev/null || true
    if ! security list-keychains -d user | grep -q "dancingpet-signing"; then
        EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')
        security list-keychains -d user -s "$SIGN_KEYCHAIN" $EXISTING
    fi
    codesign --force --deep --sign "$IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP"
else
    echo "▶︎ ad-hoc 서명 (권한이 재빌드마다 풀림 — ./setup_signing.sh 1회 실행 권장)..."
    codesign --force --deep --sign - "$APP"
fi

echo "✅ 완료: $(pwd)/$APP"
echo "   실행: open $APP"
