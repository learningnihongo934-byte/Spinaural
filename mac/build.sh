#!/bin/bash
# Build Spinaural.app (menu bar app that spins your Mac's live audio into 8D/16D).
#   ./build.sh            -> build.noindex/Spinaural.app
#   ./build.sh install    -> also copy to /Applications and open it
#   ./build.sh dmg        -> universal build + build.noindex/Spinaural.dmg
#   ./build.sh selftest   -> run the offline DSP test (no audio devices needed)
set -euo pipefail
cd "$(dirname "$0")"
APP=build.noindex/Spinaural.app  # .noindex keeps Spotlight from listing a second copy
MIN=14.4
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${1:-}" == "dmg" ]]; then
  swiftc -O -swift-version 5 -target arm64-apple-macos$MIN Sources/main.swift -o build.noindex/sp-arm64
  swiftc -O -swift-version 5 -target x86_64-apple-macos$MIN Sources/main.swift -o build.noindex/sp-x86_64
  lipo -create build.noindex/sp-arm64 build.noindex/sp-x86_64 -output "$APP/Contents/MacOS/Spinaural"
else
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos$MIN" Sources/main.swift -o "$APP/Contents/MacOS/Spinaural"
fi

rm -rf build.noindex/Spinaural.iconset
swift tools/make-icon.swift build.noindex/Spinaural.iconset
iconutil -c icns build.noindex/Spinaural.iconset -o "$APP/Contents/Resources/Spinaural.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Spinaural</string>
  <key>CFBundleDisplayName</key><string>Spinaural</string>
  <key>CFBundleIdentifier</key><string>tech.rennko.spinaural</string>
  <key>CFBundleExecutable</key><string>Spinaural</string>
  <key>CFBundleIconFile</key><string>Spinaural</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Spinaural listens to what your Mac is playing so it can spin it around your head.</string>
</dict></plist>
PLIST

# Local builds: sign with an Apple Development cert if there is one, so macOS keeps the
# system-audio permission across rebuilds. The public DMG stays ad-hoc signed.
ID=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
if [[ -n "$ID" && "${1:-}" != "dmg" ]]; then codesign --force --deep --sign "$ID" "$APP"; else codesign --force --deep --sign - "$APP"; fi
echo "Built $APP"

case "${1:-}" in
  install)
    pkill -x Spinaural 2>/dev/null || true
    rm -rf /Applications/Spinaural.app && cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
    open /Applications/Spinaural.app
    echo "Installed to /Applications/Spinaural.app" ;;
  dmg)
    rm -f build.noindex/Spinaural.dmg
    hdiutil create -volname Spinaural -srcfolder "$APP" -ov -format UDZO build.noindex/Spinaural.dmg >/dev/null
    echo "Made build.noindex/Spinaural.dmg" ;;
  selftest)
    SPINAURAL_SELFTEST=1 "$APP/Contents/MacOS/Spinaural" ;;
esac
