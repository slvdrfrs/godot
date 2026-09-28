@AGENTS.md

## Claude Code specifics

- The `godot` MCP server is declared in `.mcp.json` (project scope). For a real project run `node bridge/dist/cli.js install --project <dir>`; it writes that project's `.mcp.json`.
- Build the MCP server before use: `cd bridge && npm ci && npm run build`.
- Test everything end to end with `GODOT=<path to godot 4.5 binary> node tests/e2e.mjs` (starts a headless editor on `tests/project`, launches the game, drives both).
- Use the `/godot-pair` skill when the user wants Codex's plan or review merged with yours.
