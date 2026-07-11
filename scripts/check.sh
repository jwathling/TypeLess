#!/usr/bin/env bash
# Führt Format-Check, Lint, Typecheck und Tests der Engine aus.
set -euo pipefail

cd "$(dirname "$0")/../engine"

echo "== black (Format-Check) =="
uv run black --check .
echo "== ruff (Lint) =="
uv run ruff check .
echo "== mypy (Typecheck) =="
uv run mypy typeless_engine
echo "== pytest =="
uv run pytest -q

echo "Alle Checks bestanden."
