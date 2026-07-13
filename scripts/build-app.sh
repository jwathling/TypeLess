#!/usr/bin/env bash
# Baut TypeLess.app aus dem Swift-Package.
#
# Ein echtes .app-Bundle ist nicht Kosmetik: macOS vergibt Mikrofon- und
# Accessibility-Rechte an eine Bundle-Identität, nicht an ein nacktes Binary. Ohne Bundle
# würden die Rechte dem Terminal erteilt statt TypeLess.
set -euo pipefail

cd "$(dirname "$0")/../apps/macos"

CONFIG="${1:-debug}"
APP="TypeLess.app"
BUNDLE_ID="de.typeless.TypeLess"

echo "== swift build ($CONFIG) =="
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TypeLess"

echo "== Bundle zusammensetzen =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TypeLess"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TypeLess</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>TypeLess</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Kein Dock-Icon, kein Fenster: TypeLess ist ein Hintergrundwerkzeug. -->
    <key>LSUIElement</key><true/>
    <!-- Wird ab M4 gebraucht; muss beim ERSTEN Mikrofonzugriff bereits im Bundle stehen. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>TypeLess nimmt dein Diktat auf und verarbeitet es vollständig lokal auf diesem Mac.</string>
</dict>
</plist>
PLIST

echo "== ad-hoc signieren =="
# Ad-hoc-Signatur (-) reicht für den persönlichen Gebrauch. Achtung: Die Identität ändert
# sich bei jedem Neubau, macOS kann deshalb erneut nach Berechtigungen fragen.
# Ein echtes Zertifikat gibt es erst in M8.
codesign --force --deep --sign - "$APP"

echo "Fertig: apps/macos/$APP"
