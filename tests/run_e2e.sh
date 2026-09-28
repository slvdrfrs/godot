#!/usr/bin/env bash
# Builds the bridge and runs the end-to-end test with a headless Godot 4.5 editor.
# Usage: GODOT=/path/to/godot tests/run_e2e.sh   (downloads Godot 4.5 to .cache if GODOT is unset)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${GODOT:-}" ]]; then
  mkdir -p "$ROOT/.cache"
  GODOT="$ROOT/.cache/Godot_v4.5-stable_linux.x86_64"
  if [[ ! -x "$GODOT" ]]; then
    curl -sSL -o "$ROOT/.cache/godot.zip" https://github.com/godotengine/godot/releases/download/4.5-stable/Godot_v4.5-stable_linux.x86_64.zip
    (cd "$ROOT/.cache" && unzip -o -q godot.zip && chmod +x Godot_v4.5-stable_linux.x86_64)
  fi
fi
(cd "$ROOT/bridge" && npm ci --no-audit --no-fund && npm run build)
GODOT="$GODOT" node "$ROOT/tests/e2e.mjs"
