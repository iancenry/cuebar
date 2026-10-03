#!/bin/bash
# Package Cuebar as a proper macOS .app bundle.
#
# `swift run` produces a bare executable: macOS never hands it the menu
# bar (so ⌘K/⌘S/⌘O/⌘N shortcuts don't fire) and TCC prompts (microphone,
# speech recognition) get attributed to the parent terminal instead of
# Cuebar. This script wraps the built binary in a real bundle and
# ad-hoc-signs it so the app owns its menu bar and its own permissions.
#
# Usage: ./Scripts/make-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Cuebar"
APP="dist/Cuebar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp "$BIN" "$MACOS/Cuebar"
# SwiftPM resource bundles (OpenDyslexic fonts) sit next to the binary.
# (.build/$CONFIG is a symlink — the trailing slash is load-bearing,
# find/globs don't descend into it otherwise.)
for bundle in ".build/$CONFIG/"*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$RES/"
done

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Cuebar</string>
    <key>CFBundleDisplayName</key>
    <string>Cuebar</string>
    <key>CFBundleIdentifier</key>
    <string>com.cuebar.app</string>
    <key>CFBundleExecutable</key>
    <string>Cuebar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <!-- No CFBundleDocumentTypes, deliberately. Declaring them makes
         macOS open a *window per file* dropped on the app, and Cuebar is
         single-window by design: one editor, one overlay, one key monitor.
         Files arrive through ⌘O, a drag, or the pasteboard instead, and a
         cuebar:// link (below) is an event rather than a document, so it
         never makes a window. -->
    <!-- The private drag type in ScriptDrag. Exported (not imported):
         only Cuebar produces it, and a drag carrying it is a script being
         moved between Cuebar's own lists rather than a file arriving. -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.cuebar.script</string>
            <key>UTTypeDescription</key>
            <string>Cuebar Script</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.cuebar.app</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>cuebar</string>
            </array>
        </dict>
    </array>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Cuebar uses speech recognition to follow your reading position.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Cuebar uses the microphone to track your voice for scrolling.</string>
    <!-- The phone remote. macOS 15 gates local-network *advertising*
         behind this key, and without it the listener never becomes
         ready, so the address in Settings would simply never appear.
         The wording states the two things a user is actually being asked
         to allow: a server, and the fact that it is not always on. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Cuebar serves the phone remote for your prompter on this network, and only while the prompter is showing.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_cuebar._tcp</string>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc sign so the system attributes permissions and menu ownership to
# this bundle (not the terminal that built it). Unsigned ad-hoc builds
# from local source run without Gatekeeper friction.
#
# Note what this does *not* do: it does not pass `--entitlements`, so the
# app is not sandboxed even though Sources/Cuebar/Cuebar.entitlements
# exists. That file is kept accurate for when it is applied; the drag-and-
# drop path reads files the user handed it, which works either way.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Launch with:  open dist/Cuebar.app"
