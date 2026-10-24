#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
app="${OSWIND_APP_OUTPUT:-$PWD/dist/OSwind.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$configuration/OSwind" "$app/Contents/MacOS/OSwind"
cp ".build/$configuration/oswindctl" "$app/Contents/MacOS/oswindctl"
cp ".build/$configuration/oswind-preparation-guardian" "$app/Contents/MacOS/oswind-preparation-guardian"
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
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.oswind.backup</string>
<key>UTTypeDescription</key><string>OSwind Library Backup</string>
<key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>oswindbackup</string></array></dict>
</dict><dict>
<key>UTTypeIdentifier</key><string>com.oswind.vault</string>
<key>UTTypeDescription</key><string>OSwind Encrypted Library</string>
<key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>oswindvault</string></array></dict>
</dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>OSwind Library Backup</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Owner</string>
<key>LSItemContentTypes</key><array><string>com.oswind.backup</string></array>
<key>LSTypeIsPackage</key><true/>
</dict><dict>
<key>CFBundleTypeName</key><string>OSwind Encrypted Library</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Owner</string>
<key>LSItemContentTypes</key><array><string>com.oswind.vault</string></array>
<key>LSTypeIsPackage</key><true/>
</dict></array>
<key>CFBundleIconFile</key><string>OSwind.icns</string>
</dict></plist>
PLIST
if [ -f assets/OSwind.icns ]; then cp assets/OSwind.icns "$app/Contents/Resources/"; fi
mkdir -p "$app/Contents/Resources/ThirdParty"
install -m 644 ThirdParty/NOTICES.txt "$app/Contents/Resources/ThirdParty/NOTICES.txt"
install -m 644 ThirdParty/Apache-2.0.txt "$app/Contents/Resources/ThirdParty/Apache-2.0.txt"
mkdir -p "$app/Contents/Resources/ThirdParty/FluidAudio"
ditto ThirdParty/FluidAudio "$app/Contents/Resources/ThirdParty/FluidAudio"
ditto ThirdParty/VisualRuntime "$app/Contents/Resources/ThirdParty/VisualRuntime"
# Public preparation tools are copied into an isolated model-cache workspace
# only after their embedded hashes pass. Weights and Python are separate downloads.
mkdir -p "$app/Contents/Resources/scripts" "$app/Contents/Resources/models"
install -m 644 scripts/convert-visual-model.py scripts/convert-visual-model.py.lock "$app/Contents/Resources/scripts/"
install -m 644 models/siglip2-source.json "$app/Contents/Resources/models/"
ditto ThirdParty/VisualPreparation "$app/Contents/Resources/ThirdParty/VisualPreparation"
# Preserve dependency resources in the signed resource area. VisualTokenizer
# constructs explicit local Config values and never uses Hub's fallback bundle.
for resource in swift-transformers_Hub.bundle swift-crypto_Crypto.bundle; do
    ditto ".build/$configuration/$resource" "$app/Contents/Resources/$resource"
done
codesign --force --deep --sign - --identifier com.oswind.desktop "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
