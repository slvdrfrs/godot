import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN_CFG = "res://addons/godot_bridge/plugin.cfg";
const AUTOLOAD_LINE = /^GodotBridgeRuntime=.*\n/m;

/** The addon ships next to the package (repo layout: <root>/addons/godot_bridge, <root>/bridge/dist). */
export function addonSourceDir(): string {
  const candidates = [path.resolve(here, "..", "addon", "godot_bridge"), path.resolve(here, "..", "..", "addons", "godot_bridge")];
  for (const c of candidates) if (fs.existsSync(path.join(c, "plugin.cfg"))) return c;
  throw new Error("Cannot find the godot_bridge addon next to this package");
}

function listFiles(src: string, rel = ""): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(path.join(src, rel), { withFileTypes: true })) {
    const r = path.join(rel, entry.name);
    if (entry.isDirectory()) out.push(...listFiles(src, r));
    else if (!entry.name.endsWith(".uid")) out.push(r);
  }
  return out;
}

/** Minimal line diff (unified-ish) for --dry-run output. */
export function lineDiff(file: string, before: string, after: string): string {
  if (before === after) return "";
  const a = before.split("\n");
  const b = after.split("\n");
  // LCS table (files are small: project.godot, .mcp.json, config.toml)
  const m = a.length, n = b.length;
  const dp: number[][] = Array.from({ length: m + 1 }, () => new Array(n + 1).fill(0));
  for (let i = m - 1; i >= 0; i--) for (let j = n - 1; j >= 0; j--) dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const lines: string[] = [`--- ${file}`, `+++ ${file}`];
  let i = 0, j = 0;
  while (i < m || j < n) {
    if (i < m && j < n && a[i] === b[j]) { i++; j++; }
    else if (j < n && (i >= m || dp[i][j + 1] >= dp[i + 1][j])) lines.push("+ " + b[j++]);
    else lines.push("- " + a[i++]);
  }
  return lines.join("\n");
}

type Change = { file: string; before: string; after: string | null };

class Plan {
  changes: Change[] = [];
  copies: { from: string; to: string }[] = [];
  removals: string[] = [];
  notes: string[] = [];
  edit(file: string, after: string | null) {
    const before = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
    if (before === (after ?? "") && after !== null) return;
    this.changes.push({ file, before, after });
  }
  render(): string {
    const out: string[] = [];
    for (const c of this.copies) out.push(`copy ${c.from} -> ${c.to}`);
    for (const r of this.removals) out.push(`remove ${r}`);
    for (const c of this.changes) out.push(c.after === null ? `delete ${c.file}` : lineDiff(c.file, c.before, c.after));
    out.push(...this.notes);
    return out.join("\n");
  }
  apply(): string[] {
    const done: string[] = [];
    for (const c of this.copies) {
      fs.mkdirSync(path.dirname(c.to), { recursive: true });
      fs.copyFileSync(c.from, c.to);
    }
    if (this.copies.length) done.push(`${this.copies.length} addon files copied`);
    for (const r of this.removals) {
      fs.rmSync(r, { recursive: true, force: true });
      done.push(`removed ${r}`);
      const parent = path.dirname(r);
      if (fs.existsSync(parent) && fs.readdirSync(parent).length === 0) fs.rmdirSync(parent);
    }
    for (const c of this.changes) {
      if (c.after === null) fs.rmSync(c.file, { force: true });
      else fs.writeFileSync(c.file, c.after);
      done.push(`${c.after === null ? "deleted" : "wrote"} ${c.file}`);
    }
    done.push(...this.notes);
    return done;
  }
}

function enablePluginText(text: string): string {
  if (text.includes(PLUGIN_CFG)) return text;
  const m = text.match(/\[editor_plugins\]\s*\n\s*enabled=PackedStringArray\(([^)]*)\)/);
  if (m) {
    const list = m[1].trim();
    return text.replace(m[0], m[0].replace(`PackedStringArray(${m[1]})`, `PackedStringArray(${list ? `${list}, "${PLUGIN_CFG}"` : `"${PLUGIN_CFG}"`})`));
  }
  if (/\[editor_plugins\]/.test(text)) return text.replace(/\[editor_plugins\]\s*\n/, `[editor_plugins]\n\nenabled=PackedStringArray("${PLUGIN_CFG}")\n`);
  return text.trimEnd() + `\n\n[editor_plugins]\n\nenabled=PackedStringArray("${PLUGIN_CFG}")\n`;
}

/** Reverse of enablePluginText + the autoload the plugin registers + the godot_bridge/* settings it may have persisted. */
function disablePluginText(text: string): string {
  let t = text
    .replace(new RegExp(`,\\s*"${PLUGIN_CFG.replace(/[/.]/g, "\\$&")}"`), "")
    .replace(new RegExp(`"${PLUGIN_CFG.replace(/[/.]/g, "\\$&")}",\\s*`), "")
    .replace(new RegExp(`"${PLUGIN_CFG.replace(/[/.]/g, "\\$&")}"`), "");
  t = t.replace(/\[editor_plugins\]\s*\n\s*enabled=PackedStringArray\(\s*\)\s*\n?/m, "");
  t = t.replace(AUTOLOAD_LINE, "");
  t = t.replace(/\[autoload\]\s*\n(?=\s*(\[|$))/m, "");
  t = t.replace(/\[godot_bridge\]\s*\n(?:\s*\S+=.*\n)*\n?/m, "");
  return t.replace(/\n{3,}/g, "\n\n");
}

export function mcpServerEntry(projectDir: string, clientName: string, profile?: string) {
  const args = [path.resolve(here, "cli.js"), "mcp", "--project", projectDir, "--client", clientName];
  if (profile) args.push("--profile", profile);
  return { command: "node", args };
}

export function codexToml(projectDir: string, profile?: string): string {
  const e = mcpServerEntry(projectDir, "codex", profile);
  return `[mcp_servers.godot]\ncommand = ${JSON.stringify(e.command)}\nargs = ${JSON.stringify(e.args)}\nstartup_timeout_sec = 20\n`;
}

export interface InstallOpts { claude: boolean; codex: boolean; writeCodex: boolean; dryRun: boolean; profile?: string; codexConfig?: string }

function codexConfigPath(opts: InstallOpts) {
  return opts.codexConfig ?? path.join(os.homedir(), ".codex", "config.toml");
}

export function install(projectDir: string, opts: InstallOpts): string {
  if (!fs.existsSync(path.join(projectDir, "project.godot"))) throw new Error(`${projectDir} has no project.godot`);
  const plan = new Plan();
  const src = addonSourceDir();
  const dst = path.join(projectDir, "addons", "godot_bridge");
  for (const rel of listFiles(src)) plan.copies.push({ from: path.join(src, rel), to: path.join(dst, rel) });
  const pg = path.join(projectDir, "project.godot");
  plan.edit(pg, enablePluginText(fs.readFileSync(pg, "utf8")));
  if (opts.claude) {
    const file = path.join(projectDir, ".mcp.json");
    let json: any = {};
    if (fs.existsSync(file)) try { json = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
    json.mcpServers ??= {};
    json.mcpServers.godot = mcpServerEntry(projectDir, "claude", opts.profile);
    plan.edit(file, JSON.stringify(json, null, 2) + "\n");
  }
  if (opts.codex) {
    if (opts.writeCodex) {
      const file = codexConfigPath(opts);
      const text = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
      const toml = codexToml(projectDir, opts.profile);
      const next = /\[mcp_servers\.godot\]/.test(text) ? text.replace(/\[mcp_servers\.godot\][\s\S]*?(?=\n\[|$)/, toml.trimEnd()) : text.trimEnd() + (text ? "\n\n" : "") + toml;
      plan.edit(file, next);
    } else plan.notes.push(`Codex: add to ~/.codex/config.toml (or use --write-codex):\n${codexToml(projectDir, opts.profile)}`);
  }
  plan.notes.push("Open the project in Godot 4.5+; the Bridge panel shows the port. The plugin adds the GodotBridgeRuntime autoload to project.godot on first load (uninstall removes it).");
  if (opts.dryRun) return "DRY RUN (nothing written)\n" + plan.render();
  return plan.apply().join("\n");
}

export function uninstall(projectDir: string, opts: InstallOpts): string {
  const plan = new Plan();
  const dst = path.join(projectDir, "addons", "godot_bridge");
  if (fs.existsSync(dst)) plan.removals.push(dst);
  const pg = path.join(projectDir, "project.godot");
  if (fs.existsSync(pg)) plan.edit(pg, disablePluginText(fs.readFileSync(pg, "utf8")));
  for (const f of ["godot_bridge.json"]) {
    const p = path.join(projectDir, ".godot", f);
    if (fs.existsSync(p)) plan.edit(p, null);
  }
  if (opts.claude) {
    const file = path.join(projectDir, ".mcp.json");
    if (fs.existsSync(file)) {
      try {
        const json = JSON.parse(fs.readFileSync(file, "utf8"));
        if (json.mcpServers?.godot) {
          delete json.mcpServers.godot;
          const empty = Object.keys(json.mcpServers).length === 0 && Object.keys(json).length === 1;
          plan.edit(file, empty ? null : JSON.stringify(json, null, 2) + "\n");
        }
      } catch {}
    }
  }
  if (opts.codex) {
    const file = codexConfigPath(opts);
    if (fs.existsSync(file)) {
      const text = fs.readFileSync(file, "utf8");
      if (/\[mcp_servers\.godot\]/.test(text)) plan.edit(file, text.replace(/\n*\[mcp_servers\.godot\][\s\S]*?(?=\n\[|$)/, "").replace(/^\n+/, ""));
    }
  }
  if (opts.dryRun) return "DRY RUN (nothing written)\n" + plan.render();
  return plan.apply().join("\n");
}
