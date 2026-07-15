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

# macOS bindet Mikrofon-/Bedienungshilfen-/Eingabeüberwachungs-Rechte an die SIGNATUR-Identität.
# Eine Ad-hoc-Signatur (`--sign -`) erzeugt bei JEDEM Neubau eine neue Identität — die Rechte
# gehen dann jedes Mal verloren, obwohl der Schalter in den Einstellungen noch „an" aussieht (er
# zeigt auf die alte Identität). Das kostet bei jedem Testlauf denselben Rechte-Tanz.
#
# Deshalb signieren wir mit einer STABILEN, selbst-signierten Entwickler-Identität, wenn sie im
# Schlüsselbund liegt. Anlegen (einmalig): siehe scripts/setup-signing-identity.sh. Damit bleibt
# die Identität über alle Neubauten gleich, und die Rechte werden nur ein einziges Mal erteilt.
# Ein echtes Apple-Zertifikat (für die Weitergabe an andere) gibt es erst in M8.
SIGN_IDENTITY="${TYPELESS_SIGN_IDENTITY:-TypeLess Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "== signieren mit stabiler Identität: $SIGN_IDENTITY =="
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
  echo "== stabile Identität '$SIGN_IDENTITY' nicht gefunden — ad-hoc (Rechte gehen bei jedem Neubau verloren) =="
  echo "   Einmalig einrichten: bash scripts/setup-signing-identity.sh"
  codesign --force --deep --sign - "$APP"
fi

echo "Fertig: apps/macos/$APP"
