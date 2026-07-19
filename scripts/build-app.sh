#!/usr/bin/env bash
# Baut TypeLess.app aus dem Swift-Package.
#
# Ein echtes .app-Bundle ist nicht Kosmetik: macOS vergibt Mikrofon- und
# Accessibility-Rechte an eine Bundle-Identität, nicht an ein nacktes Binary. Ohne Bundle
# würden die Rechte dem Terminal erteilt statt TypeLess.
set -euo pipefail

# Einmal absolut auflösen, BEVOR wir wegcd'en — spätere Schritte (z. B. die Engine-Einbettung)
# brauchen den Repo-Pfad, laufen aber mit cwd=apps/macos; ein $(dirname "$0") an dieser Stelle
# wäre nach dem cd relativ zum FALSCHEN Verzeichnis.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR/../apps/macos"

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

# --- Engine ins Bündel einbetten (ausgelieferter Betrieb ohne Entwickler-Setup) ---
# uv baut daraus beim ersten Start die Python-Umgebung EXTERN unter Application Support auf
# (UV_PROJECT_ENVIRONMENT) — dieses Verzeichnis hier bleibt schreibgeschützt und signiert.
ENGINE_SRC="$(cd "$SCRIPT_DIR/../engine" && pwd)"
ENGINE_DST="$APP/Contents/Resources/engine"
echo "== Engine einbetten aus $ENGINE_SRC =="
rm -rf "$ENGINE_DST"
mkdir -p "$ENGINE_DST"
# Nur die zur Laufzeit nötigen Teile — keine .venv, kein __pycache__, keine Tests.
cp -R "$ENGINE_SRC/typeless_engine" "$ENGINE_DST/typeless_engine"
cp "$ENGINE_SRC/pyproject.toml" "$ENGINE_SRC/uv.lock" "$ENGINE_SRC/README.md" "$ENGINE_DST/"
find "$ENGINE_DST" -name "__pycache__" -type d -prune -exec rm -rf {} +

UV_BIN="$(command -v uv || true)"
if [ -z "$UV_BIN" ]; then
  echo "FEHLER: uv nicht gefunden (command -v uv leer). uv installieren und erneut bauen." >&2
  exit 1
fi
cp "$UV_BIN" "$ENGINE_DST/uv"
chmod +x "$ENGINE_DST/uv"
echo "   eingebettet: uv ($("$ENGINE_DST/uv" --version)) + typeless_engine + uv.lock"

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
