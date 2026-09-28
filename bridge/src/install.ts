import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** The addon ships next to the package (repo layout: <root>/addons/godot_bridge, <root>/bridge/dist). */
export function addonSourceDir(): string {
  const candidates = [path.resolve(here, "..", "addon", "godot_bridge"), path.resolve(here, "..", "..", "addons", "godot_bridge")];
  for (const c of candidates) if (fs.existsSync(path.join(c, "plugin.cfg"))) return c;
  throw new Error("Cannot find the godot_bridge addon next to this package");
}

function copyDir(src: string, dst: string) {
  fs.mkdirSync(dst, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dst, entry.name);
    if (entry.isDirectory()) copyDir(s, d);
    else if (!entry.name.endsWith(".uid")) fs.copyFileSync(s, d);
  }
}

/** Enable the plugin in project.godot ([editor_plugins] enabled=PackedStringArray(...)). */
export function enablePlugin(projectDir: string): boolean {
  const file = path.join(projectDir, "project.godot");
  let text = fs.readFileSync(file, "utf8");
  const cfg = "res://addons/godot_bridge/plugin.cfg";
  if (text.includes(cfg)) return false;
  const m = text.match(/\[editor_plugins\]\s*\n\s*enabled=PackedStringArray\(([^)]*)\)/);
  if (m) {
    const list = m[1].trim();
    const newList = list ? `${list}, "${cfg}"` : `"${cfg}"`;
    text = text.replace(m[0], m[0].replace(`PackedStringArray(${m[1]})`, `PackedStringArray(${newList})`));
  } else if (/\[editor_plugins\]/.test(text)) {
    text = text.replace(/\[editor_plugins\]\s*\n/, `[editor_plugins]\n\nenabled=PackedStringArray("${cfg}")\n`);
  } else {
    text = text.trimEnd() + `\n\n[editor_plugins]\n\nenabled=PackedStringArray("${cfg}")\n`;
  }
  fs.writeFileSync(file, text);
  return true;
}

export function mcpServerEntry(projectDir: string, clientName: string) {
  return { command: "node", args: [path.resolve(here, "cli.js"), "mcp", "--project", projectDir, "--client", clientName] };
}

export function writeClaudeConfig(projectDir: string): string {
  const file = path.join(projectDir, ".mcp.json");
  let json: any = {};
  if (fs.existsSync(file)) {
    try {
      json = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch {}
  }
  json.mcpServers ??= {};
  json.mcpServers.godot = mcpServerEntry(projectDir, "claude");
  fs.writeFileSync(file, JSON.stringify(json, null, 2) + "\n");
  return file;
}

export function codexToml(projectDir: string): string {
  const e = mcpServerEntry(projectDir, "codex");
  return `[mcp_servers.godot]\ncommand = ${JSON.stringify(e.command)}\nargs = ${JSON.stringify(e.args)}\nstartup_timeout_sec = 20\n`;
}

export function writeCodexConfig(projectDir: string): string {
  const dir = path.join(os.homedir(), ".codex");
  const file = path.join(dir, "config.toml");
  fs.mkdirSync(dir, { recursive: true });
  let text = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  if (/\[mcp_servers\.godot\]/.test(text)) {
    text = text.replace(/\[mcp_servers\.godot\][\s\S]*?(?=\n\[|$)/, codexToml(projectDir).trimEnd());
  } else {
    text = text.trimEnd() + (text ? "\n\n" : "") + codexToml(projectDir);
  }
  fs.writeFileSync(file, text);
  return file;
}

export function install(projectDir: string, opts: { claude: boolean; codex: boolean; writeCodex: boolean }): string[] {
  const out: string[] = [];
  if (!fs.existsSync(path.join(projectDir, "project.godot"))) throw new Error(`${projectDir} has no project.godot`);
  const dst = path.join(projectDir, "addons", "godot_bridge");
  copyDir(addonSourceDir(), dst);
  out.push(`addon copied to ${dst}`);
  out.push(enablePlugin(projectDir) ? "plugin enabled in project.godot" : "plugin already enabled in project.godot");
  if (opts.claude) out.push(`Claude Code config written: ${writeClaudeConfig(projectDir)} (server name "godot")`);
  if (opts.codex) {
    if (opts.writeCodex) out.push(`Codex config updated: ${writeCodexConfig(projectDir)}`);
    else out.push(`Codex: add this to ~/.codex/config.toml (or rerun with --write-codex):\n${codexToml(projectDir)}`);
  }
  out.push("Next: open the project in Godot 4.3+ (4.5 recommended). The Bridge panel at the bottom shows the port; agents connect automatically.");
  return out;
}
