import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { HubClient } from "./hub.js";

/** Build the brief for Codex: the caller's question + a live snapshot of the editor (and the game when --game). */
export async function buildConsultPrompt(brief: string, opts: { projectDir?: string; game: boolean }): Promise<string> {
  const hub = new HubClient({ projectDir: opts.projectDir, clientName: "codex-consult", connectTimeoutMs: 3000 });
  let snapshot: any;
  try {
    await hub.connect();
    const t = opts.game ? { target: "game" } : {};
    const [status, tree, cameras, logs] = await Promise.all([
      hub.request("bridge.status", t),
      hub.request("scene.tree", { ...t, depth: 6, props: ["position", "visible"] }),
      hub.request("scene.cameras", t),
      hub.request("logs.get", { ...t, levels: ["error", "script_error", "warning", "shader_error"], limit: 50 }),
    ]);
    snapshot = { status, tree, cameras, diagnostics: logs.entries };
  } catch (e: any) {
    snapshot = { error: `editor not reachable (${e.code ?? ""} ${e.message}); snapshot unavailable` };
  } finally {
    hub.close();
  }
  return `You are Codex, consulted by Claude Code on a Godot 4 project. Both of you can use the same Godot Bridge (MCP server "godot",
tools godot_*) to see inside the editor and the running game. Read AGENTS.md for the workflow.

## Brief from Claude
${brief}

## Live snapshot from the editor (Godot Bridge, JSON)
\`\`\`json
${JSON.stringify(snapshot, null, 1)}
\`\`\`

Answer in structured sections (Verdict / Plan / Risks / Concrete changes) so Claude can merge it. Be concrete and opinionated;
verify API names with the godot_api tool if you have it, never from memory.
`;
}

/** Run `codex exec` (high reasoning, read-only sandbox) with the prompt on stdin. Returns the exit code, or 3 when codex is missing. */
export function runCodex(prompt: string, opts: { model: string; cwd: string }): Promise<number> {
  return new Promise((resolve) => {
    const exe = process.platform === "win32" ? "codex.cmd" : "codex";
    const child = spawn(exe, ["exec", "--model", opts.model, "-c", "model_reasoning_effort=high", "--sandbox", "read-only", "--skip-git-repo-check", "-C", opts.cwd, "-"], {
      stdio: ["pipe", "inherit", "inherit"],
      shell: process.platform === "win32",
    });
    child.on("error", () => {
      const file = path.join(os.tmpdir(), `codex-brief-${Date.now()}.md`);
      fs.writeFileSync(file, prompt);
      console.error(`codex CLI not found. Paste this prompt into Codex manually (saved at ${file}):\n`);
      console.log(prompt);
      resolve(3);
    });
    child.on("exit", (code) => resolve(code ?? 1));
    child.stdin.end(prompt);
  });
}
