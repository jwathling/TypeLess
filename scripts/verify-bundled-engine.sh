#!/usr/bin/env bash
# Startet die INS BÜNDEL eingebettete Engine in einer sauberen Umgebung und prüft /health.
# Simuliert einen frischen Mac: eigener Application-Support-Ort, kein Repo-uv im Spiel.
set -euo pipefail

APP="apps/macos/TypeLess.app"
ENGINE="$PWD/$APP/Contents/Resources/engine"
[ -x "$ENGINE/uv" ] || { echo "FEHLER: $ENGINE/uv fehlt — erst scripts/build-app.sh" >&2; exit 1; }

WORK="$(mktemp -d)"
SOCK="$WORK/typeless.sock"
echo "== Start der gebündelten Engine (frische Umgebung unter $WORK) =="
env -i HOME="$HOME" PATH="/usr/bin:/bin" \
    TYPELESS_SOCKET_PATH="$SOCK" \
    UV_PROJECT_ENVIRONMENT="$WORK/runtime" \
    UV_CACHE_DIR="$WORK/uv-cache" \
    HF_HOME="$WORK/models" \
    "$ENGINE/uv" run --frozen --project "$ENGINE" --extra mlx --extra server \
    python -m typeless_engine.server &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "== auf /health = ready warten (bis 600 s; erster Lauf lädt Umgebung + STT-Modell) =="
for i in $(seq 1 600); do
  RESP="$(curl -s --unix-socket "$SOCK" http://localhost/health 2>/dev/null || true)"
  echo "$RESP" | grep -q '"status":"ready"' && { echo "READY nach ${i}s: $RESP"; exit 0; }
  echo "$RESP" | grep -q '"status":"failed"' && { echo "FAILED: $RESP" >&2; exit 1; }
  sleep 1
done
echo "TIMEOUT: Engine nicht ready" >&2; exit 1
