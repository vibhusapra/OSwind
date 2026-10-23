#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
app="$PWD/dist/OSwind.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$configuration/OSwind" "$app/Contents/MacOS/OSwind"
cp ".build/$configuration/oswindctl" "$app/Contents/MacOS/oswindctl"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.oswind.desktop</string>
<key>CFBundleName</key><string>OSwind</string>
<key>CFBundleDisplayName</key><string>OSwind</string>
<key>CFBundleExecutable</key><string>OSwind</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticTermination</key><false/>
<key>NSMicrophoneUsageDescription</key><string>OSwind optionally transcribes your microphone locally to help you recall conversations.</string>
<key>NSScreenCaptureUsageDescription</key><string>OSwind captures your chosen windows to build a private, searchable memory on this Mac.</string>
<key>NSAppleEventsUsageDescription</key><string>OSwind uses application context to apply your privacy rules.</string>
<key>CFBundleIconFile</key><string>OSwind.icns</string>
</dict></plist>
PLIST
if [ -f assets/OSwind.icns ]; then cp assets/OSwind.icns "$app/Contents/Resources/"; fi
mkdir -p "$app/Contents/Resources/ThirdParty"
install -m 644 ThirdParty/NOTICES.txt "$app/Contents/Resources/ThirdParty/NOTICES.txt"
install -m 644 ThirdParty/Apache-2.0.txt "$app/Contents/Resources/ThirdParty/Apache-2.0.txt"
codesign --force --deep --sign - --identifier com.oswind.desktop "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
