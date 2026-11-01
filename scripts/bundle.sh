#!/bin/bash
# Builds build/AgentMaster.app: the app binary in MacOS/, the hook helper in Helpers/, ad-hoc signed.
# VERSION and BUILD_NUMBER set the bundle's version (the release workflow passes the tag and run number).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release --product AgentMaster
swift build -c release --product agentmaster-hook
BIN="$(swift build -c release --show-bin-path)"

APP="build/AgentMaster.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/AgentMaster" "$APP/Contents/MacOS/AgentMaster"
cp "$BIN/agentmaster-hook" "$APP/Contents/Helpers/agentmaster-hook"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate with scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.agentmaster.app</string>
    <key>CFBundleName</key><string>AgentMaster</string>
    <key>CFBundleExecutable</key><string>AgentMaster</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Folders dropped on the Dock icon; Alternate keeps Finder the default for opening them. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
    <!-- Finder's right-click "Open in AgentMaster" on folders; an NSRequiredContext enables it by default. -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Open in AgentMaster</string></dict>
            <key>NSMessage</key><string>openInAgentMaster</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Helpers/agentmaster-hook"
codesign --force --sign - "$APP"
echo "Built $APP"
