#!/usr/bin/env bash
# Ask Codex CLI (high reasoning, read-only) for a plan/review with a live Godot Bridge snapshot attached.
# Usage: scripts/codex-consult.sh "<brief for codex>" [--project <godot project dir>] [--game] [--model <model>]
set -euo pipefail
BRIEF="${1:-}"; shift || true
PROJECT=""; GAME=""; MODEL="${CODEX_MODEL:-gpt-5}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2;;
    --game) GAME="--game"; shift;;
    --model) MODEL="$2"; shift 2;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done
[[ -n "$BRIEF" ]] || { echo "usage: $0 \"<brief>\" [--project dir] [--game] [--model m]" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bridge/dist/cli.js"
[[ -f "$CLI" ]] || { echo "build the bridge first: (cd $ROOT/bridge && npm ci && npm run build)" >&2; exit 1; }
PROJ_ARGS=(); [[ -n "$PROJECT" ]] && PROJ_ARGS=(--project "$PROJECT")

SNAPSHOT="$(node "$CLI" snapshot "${PROJ_ARGS[@]}" $GAME --client codex-consult 2>/dev/null || echo '{"error":"editor not reachable; snapshot unavailable"}')"
PROMPT_FILE="$(mktemp -t codex-brief.XXXXXX.md)"
cat > "$PROMPT_FILE" <<PROMPT
You are Codex, consulted by Claude Code on a Godot 4 project. Both of you can use the same Godot Bridge (MCP server "godot",
tools godot_*) to see inside the editor and the running game. Read AGENTS.md for the workflow.

## Brief from Claude
$BRIEF

## Live snapshot from the editor (Godot Bridge, JSON)
\`\`\`json
$SNAPSHOT
\`\`\`

Answer in structured sections (Verdict / Plan / Risks / Concrete changes) so Claude can merge it. Be concrete and opinionated;
verify API names with the godot_api tool if you have it, never from memory.
PROMPT

if ! command -v codex >/dev/null 2>&1; then
  echo "codex CLI not found. Paste this prompt into Codex manually:" >&2
  echo "----- $PROMPT_FILE -----" >&2
  cat "$PROMPT_FILE"
  exit 3
fi
exec codex exec --model "$MODEL" -c model_reasoning_effort=high --sandbox read-only --skip-git-repo-check -C "$ROOT" - < "$PROMPT_FILE"
