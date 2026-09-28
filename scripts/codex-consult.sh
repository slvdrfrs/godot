#!/usr/bin/env bash
# Thin wrapper (Linux/macOS/Git Bash). On Windows you can call node directly:
#   node bridge\dist\cli.js consult "<brief>" --project C:\ruta\al\proyecto [--game] [--print]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec node "$ROOT/bridge/dist/cli.js" consult "$@"
