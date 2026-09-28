# Working on a Godot project with Godot Bridge (Claude Code + Codex CLI)

This file is read by Codex CLI (`AGENTS.md`) and imported by Claude Code (`CLAUDE.md`). Both agents follow the same rules.

## What you have

An MCP server named `godot` (tools `godot_*`) connected to a hub running **inside the Godot editor**. It gives you
structured truth (scene tree, node properties, signals, exact API of the running engine build), renders from any
camera, undoable edits, and control of the running game (F5): pause, step frames, inject input, read errors and metrics.
If the tools are missing, run `node bridge/dist/cli.js doctor --project <dir>`.

## Workflow (do this, in this order)

1. `godot_status` first. It tells you the Godot version, the edited scene, whether a game is running, and who else is connected.
2. Look before you touch: `godot_tree` (depth 3-4), then `godot_inspect` on the nodes you care about (`changed_only: true` is compact).
3. Never guess engine API. `godot_api` with `class_name` gives the exact methods/properties/signals of this build; with `script_path` it reflects project scripts.
4. Scene edits go through `godot_patch` (one undoable action, labelled with your name). Use `dry_run: true` when unsure about refs. Then `godot_scene action=save`.
5. Script edits: edit `.gd` files with your normal file tools, then `godot_validate` (parser errors with file:line), then `godot_files action=rescan` and, if a scene uses that script, `godot_scene action=reload`.
6. To verify behaviour, run it: `godot_run action=start` -> `godot_step` (with `events` to inject input in the same frame) -> `godot_inspect target=game` / `godot_logs target=game` -> `godot_run action=stop`.
7. To *see*: `godot_observe`. `mode=camera_preview` with `camera=<ref>` renders from that camera (not the editor viewport). `camera_takeover` is exact but changes the current camera for a frame. Read the `limitations` field of every observation. Captures fail with `UNSUPPORTED` in a headless editor; that is expected, use structured tools there.
8. Finish with `godot_logs levels=[error,script_error,warning]` on both targets. Zero new errors is the bar.

## Rules

- Node refs: prefer the `id` handles returned by the bridge (stable across renames); paths are relative to the scene root.
- Values for properties: JSON numbers/arrays are coerced to the property type; `"Vector3(1, 2, 3)"` strings work too.
- `godot_exec` (arbitrary GDScript) is an escape hatch, off by default (`godot_bridge/allow_exec`). No sandbox, no timeout. Use structured tools when they exist.
- With several game instances running, `target: "game"` returns `AMBIGUOUS`; pass the run id from `godot_status`.
- Keep context small: `godot_tree` defaults (depth 3, 150 nodes) plus `exclude_classes`; `godot_observe` at 320x180 when a rough view is enough.
- Two agents can share the editor. Mutations take a 30 s write lease per target; on `CONFLICT` wait for the holder or coordinate, do not `steal` unless the holder is clearly dead. Release your lease (`godot_lease action=release`) after a batch so the other agent can work.
- Do not edit a `.tscn` on disk while it is open in the editor unless you `godot_scene action=reload` right after; the editor's copy wins on save.
- Report honestly what you observed vs. what you inferred. The bridge labels every capture with a `guarantee`; keep that distinction in your own summaries.

## Pair mode (Claude + Codex)

Claude Code usually drives (plans, edits through the bridge, runs the game) and asks Codex for an independent review or a
second implementation attempt with `node bridge/dist/cli.js consult "<brief>"`, which bundles a live snapshot (tree, cameras, diagnostics)
into the prompt. Codex can do the same in reverse: it has the same tools. Whoever holds the write lease is the driver.
