#!/usr/bin/env bash
# Baut, signiert, packt und veröffentlicht eine TypeLess-Version als GitHub-Release + Appcast.
#
# Version kommt aus EINER Quelle (VERSION). --dry-run läuft ohne Upload/Push (baut, packt,
# EdDSA-signiert, zeigt den Appcast-Eintrag) — der testbare Kern.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

VERSION="$(tr -d ' \t\n\r' < "$REPO/VERSION")"
[ -n "$VERSION" ] || { echo "FEHLER: VERSION leer" >&2; exit 1; }
APP="$REPO/apps/macos/TypeLess.app"
ZIP="$REPO/TypeLess-$VERSION.zip"
APPCAST="$REPO/appcast.xml"
GH_USER="${TYPELESS_GH_USER:-PLACEHOLDER_GH_USER}"
ASSET_URL="https://github.com/$GH_USER/TypeLess/releases/download/$VERSION/TypeLess-$VERSION.zip"

echo "== 1/6 bauen + signieren (Release) =="
bash "$SCRIPT_DIR/build-app.sh" release

echo "== 2/6 Signatur verifizieren =="
codesign --verify --deep --strict "$APP"

echo "== 3/6 packen: $ZIP =="
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"   # ditto erhält Signatur + Symlinks des Frameworks
LENGTH="$(stat -f%z "$ZIP")"

echo "== 4/6 EdDSA-Signatur des Zips =="
SIGN_UPDATE="$(find "$REPO/apps/macos/.build" -name sign_update -type f -perm -u+x | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "FEHLER: sign_update nicht gefunden (swift build in apps/macos?)" >&2; exit 1; }
# sign_update gibt eine Zeile wie: sparkle:edSignature="…" length="…"  — wir brauchen die Signatur.
SIGN_OUT="$("$SIGN_UPDATE" "$ZIP")"
ED_SIG="$(printf '%s' "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] || { echo "FEHLER: EdDSA-Signatur nicht aus sign_update-Ausgabe gelesen: $SIGN_OUT" >&2; exit 1; }
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

echo "== 5/6 Appcast-Eintrag (idempotent) =="
APPCAST_ARGS=("$APPCAST" --version "$VERSION" --url "$ASSET_URL" --length "$LENGTH"
              --ed-signature "$ED_SIG" --pub-date "$PUB_DATE")
if [ "$DRY_RUN" = "1" ]; then
  echo "-- DRY-RUN: neuer Appcast-Eintrag (nicht geschrieben, nicht veröffentlicht) --"
  uv run --project "$REPO/engine" python "$SCRIPT_DIR/release_appcast.py" "${APPCAST_ARGS[@]}" --stdout
  echo "-- DRY-RUN Ende: Zip liegt unter $ZIP ($LENGTH Bytes) --"
  exit 0
fi
uv run --project "$REPO/engine" python "$SCRIPT_DIR/release_appcast.py" "${APPCAST_ARGS[@]}"

echo "== 6/6 veröffentlichen: gh release create $VERSION =="
gh release create "$VERSION" "$ZIP" --title "TypeLess $VERSION" --notes "TypeLess $VERSION"
git add "$APPCAST"
git commit -m "Release $VERSION: appcast.xml"
git push
echo "Fertig: $VERSION veröffentlicht."
