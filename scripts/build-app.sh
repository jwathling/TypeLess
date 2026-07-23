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

# Version aus EINER Quelle (Repo-Root/VERSION) — App-Info.plist, Zip-Name (release.sh) und
# Appcast dürfen nie auseinanderlaufen. Das Anheben der Version ist ein bewusster Edit von VERSION.
VERSION="$(tr -d ' \t\n\r' < "$SCRIPT_DIR/../VERSION")"
[ -n "$VERSION" ] || { echo "FEHLER: VERSION-Datei leer oder fehlt ($SCRIPT_DIR/../VERSION)" >&2; exit 1; }
echo "== Version aus VERSION-Datei: $VERSION =="

echo "== swift build ($CONFIG) =="
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TypeLess"

echo "== Bundle zusammensetzen =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TypeLess"

# Öffentlicher EdDSA-Schlüssel (nicht geheim) für Sparkles Update-Verifikation.
ED_PUBLIC_KEY="$(tr -d ' \t\n\r' < "$SCRIPT_DIR/../apps/macos/sparkle_public_key.txt" 2>/dev/null || true)"
[ -n "$ED_PUBLIC_KEY" ] || echo "WARNUNG: kein Sparkle-Public-Key (sparkle_public_key.txt) — Updates nicht verifizierbar" >&2
# Feed-URL: Roh-URL der appcast.xml im GitHub-Repo. Der Benutzername wird in Task 6 gesetzt.
SU_FEED_URL="${TYPELESS_FEED_URL:-https://raw.githubusercontent.com/PLACEHOLDER_GH_USER/TypeLess/main/appcast.xml}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TypeLess</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>TypeLess</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Kein Dock-Icon, kein Fenster: TypeLess ist ein Hintergrundwerkzeug. -->
    <key>LSUIElement</key><true/>
    <!-- Wird ab M4 gebraucht; muss beim ERSTEN Mikrofonzugriff bereits im Bundle stehen. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>TypeLess nimmt dein Diktat auf und verarbeitet es vollständig lokal auf diesem Mac.</string>
    <!-- Selbst-Update (M8-Verteilung Teil 3): automatisch prüfen, aber VOR Download/Installation
         fragen. Kein automatisches Herunterladen/Installieren. -->
    <key>SUFeedURL</key><string>$SU_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$ED_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
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

# --- Sparkle.framework einbetten (Selbst-Update) ---
# Reines `swift build` hat keine Xcode-Copy-Phase; das Framework wird von Hand ins Bundle gelegt.
# Sparkle bringt verschachtelte Helfer mit (XPCServices, Autoupdate, Updater.app), die einzeln und
# VON INNEN NACH AUSSEN signiert werden müssen — `--deep` allein signiert sie nicht zuverlässig.
SPARKLE_FW="$(find "$(swift build -c "$CONFIG" --show-bin-path)" -maxdepth 1 -name 'Sparkle.framework' -type d | head -1)"
[ -n "$SPARKLE_FW" ] || { echo "FEHLER: Sparkle.framework im Build-Output nicht gefunden" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
echo "== Sparkle.framework eingebettet aus $SPARKLE_FW =="

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
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  echo "== signieren mit stabiler Identität: $SIGN_IDENTITY =="
else
  SIGN_ARGS=(--force --sign -)
  echo "== stabile Identität '$SIGN_IDENTITY' nicht gefunden — ad-hoc (Rechte gehen bei jedem Neubau verloren) =="
  echo "   Einmalig einrichten: bash scripts/setup-signing-identity.sh"
fi

# Von innen nach außen: erst die verschachtelten Sparkle-Helfer, dann das Framework, zuletzt die App.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  while IFS= read -r -d '' nested; do
    codesign "${SIGN_ARGS[@]}" "$nested"
  done < <(find "$FW/Versions/Current" \( -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' \) -print0)
  codesign "${SIGN_ARGS[@]}" "$FW"
fi
codesign "${SIGN_ARGS[@]}" "$APP"

echo "Fertig: apps/macos/$APP"
