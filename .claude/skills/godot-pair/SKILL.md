---
name: godot-pair
description: Pair with Codex CLI on a Godot task through the Godot Bridge. Use when the user asks to "discuss with Codex", "get Codex's plan/review", or to merge Claude's and Codex's ideas on a Godot scene, script or bug. Claude drives the editor through the godot_* MCP tools, ships a live scene snapshot to Codex, and merges the answers.
---

# Godot pair mode (Claude drives, Codex consults)

1. Establish ground truth first, through the bridge, not from memory: `godot_status`, `godot_tree`, `godot_inspect` on the
   relevant nodes, `godot_logs` for current errors. If a running game matters, `godot_run start` and observe it.
2. Write the question for Codex as a self-contained brief: the goal, the constraints, what you already verified, and what you
   want back (a plan, a critique of your plan, or an alternative implementation). Ask for structured headings so the answer
   can be merged.
3. Run `scripts/codex-consult.sh "<brief>"` from the repo root. It appends a live snapshot (`godot-bridge snapshot`: tree, cameras,
   diagnostics, and `--game` runtime state when a run is active) and calls `codex exec` with high reasoning in read-only sandbox.
   If `codex` is not installed or not logged in, the script prints the exact prompt so the user can paste it into Codex
   themselves; say so and continue with your own plan in the meantime.
4. Merge: adopt what is verifiably better (check claims against `godot_api` and a quick `godot_exec`/`godot_step` experiment when
   cheap), reject what is wrong, and say explicitly which ideas came from Codex and which from you.
5. Implement through the bridge (`godot_patch`, file edits + `godot_validate`), verify by running (`godot_run`, `godot_step`,
   `godot_logs`), and hold the write lease only while editing so Codex can take over if the user asks it to implement instead.
