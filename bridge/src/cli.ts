#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { HubClient, BridgeError } from "./hub.js";
import { runMcp } from "./mcp.js";
import { install, uninstall, codexToml } from "./install.js";
import { findProjectDir, readDiscovery, pidAlive, DISCOVERY_REL } from "./discovery.js";
import { buildConsultPrompt, runCodex } from "./consult.js";

const USAGE = `godot-bridge <command> [options]

Commands:
  mcp                         Run the MCP server on stdio (what Claude Code / Codex launch)
  install                     Copy the addon into a project, enable it, write .mcp.json (and Codex config with --write-codex)
  uninstall                   Revert install exactly: addon dir, plugin + autoload + settings in project.godot, .mcp.json entry, Codex section
  status                      Print hub/editor status
  doctor                      Diagnose discovery, connection, capabilities
  call <method> [json]        Raw JSON-RPC call, e.g. call scene.tree '{"depth":2}'
  methods                     List hub methods
  snapshot [--game]           Tree + cameras + recent errors as JSON (context bundle for another agent)
  observe [--out f.png] [--camera ref] [--mode m] [--game]   Save a render to a file
  consult "<brief>" [--game] [--model m] [--print]           Ask Codex (codex exec, high reasoning) with a live snapshot attached

Options:
  --project <dir>   Godot project directory (default: GODOT_PROJECT or walk up from cwd)
  --url <ws://...>  Connect to an explicit hub url (with --token)
  --client <name>   Client name shown in the editor (default: cli)
  --no-claude / --no-codex / --write-codex   (install / uninstall)
  --dry-run                   Show the diff instead of writing (install / uninstall)
  --profile full|minimal      Tool set exposed by mcp (minimal = 12 core tools, fewer context tokens)
`;

function parseArgs(argv: string[]) {
  const args: Record<string, string | boolean> = {};
  const positional: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        args[key] = next;
        i++;
      } else args[key] = true;
    } else positional.push(a);
  }
  return { args, positional };
}

async function main() {
  const { args, positional } = parseArgs(process.argv.slice(2));
  const cmd = positional[0];
  const projectDir = typeof args.project === "string" ? path.resolve(args.project) : undefined;
  const clientName = typeof args.client === "string" ? args.client : cmd === "mcp" ? "agent" : "cli";
  const hubOpts = { projectDir, url: typeof args.url === "string" ? args.url : undefined, token: typeof args.token === "string" ? args.token : undefined, clientName };

  switch (cmd) {
    case "mcp":
      await runMcp({ ...hubOpts, profile: args.profile === "minimal" ? "minimal" : "full" });
      return;
    case "install":
    case "uninstall": {
      const dir = findProjectDir(projectDir ?? positional[1] ?? ".");
      if (!dir) throw new Error("No project.godot found; pass --project <dir>");
      const o = { claude: args["no-claude"] !== true, codex: args["no-codex"] !== true, writeCodex: args["write-codex"] === true || cmd === "uninstall", dryRun: args["dry-run"] === true, profile: typeof args.profile === "string" ? args.profile : undefined, codexConfig: typeof args["codex-config"] === "string" ? args["codex-config"] : undefined };
      console.log(cmd === "install" ? install(dir, o) : uninstall(dir, o));
      return;
    }
    case "codex-config": {
      const dir = findProjectDir(projectDir ?? ".");
      console.log(codexToml(dir ?? process.cwd()));
      return;
    }
    case "doctor":
      await doctor(hubOpts);
      return;
    case "consult": {
      const brief = positional.slice(1).join(" ");
      if (!brief) throw new Error('usage: godot-bridge consult "<brief for codex>" [--game] [--model m] [--print]');
      const prompt = await buildConsultPrompt(brief, { projectDir, game: args.game === true });
      if (args.print === true) {
        console.log(prompt);
        return;
      }
      const dir = findProjectDir(projectDir) ?? process.cwd();
      process.exit(await runCodex(prompt, { model: typeof args.model === "string" ? args.model : process.env.CODEX_MODEL ?? "gpt-5", cwd: dir }));
    }
    case "status":
    case "methods":
    case "call":
    case "snapshot":
    case "observe": {
      const hub = new HubClient({ ...hubOpts, connectTimeoutMs: 3000 });
      try {
        await hub.connect();
        if (cmd === "status") console.log(JSON.stringify(await hub.request("bridge.status"), null, 2));
        else if (cmd === "methods") console.log((await hub.request("bridge.methods")).methods.join("\n"));
        else if (cmd === "call") {
          const params = positional[2] ? JSON.parse(positional[2]) : {};
          console.log(JSON.stringify(await hub.request(positional[1], params, 120000), null, 2));
        } else if (cmd === "snapshot") {
          const target = args.game ? { target: "game" } : {};
          const [status, tree, cameras, logs] = await Promise.all([
            hub.request("bridge.status", target),
            hub.request("scene.tree", { ...target, depth: Number(args.depth ?? 6), props: ["position", "visible"] }),
            hub.request("scene.cameras", target),
            hub.request("logs.get", { ...target, levels: ["error", "script_error", "warning", "shader_error"], limit: 50 }),
          ]);
          console.log(JSON.stringify({ status, tree, cameras, diagnostics: logs.entries }, null, 2));
        } else if (cmd === "observe") {
          const target = args.game ? { target: "game" } : {};
          const r = await hub.request("capture.observe", { ...target, mode: args.mode ?? (args.camera ? "camera_preview" : "viewport"), camera: args.camera, width: Number(args.width ?? 960), height: Number(args.height ?? 540) }, 60000);
          const out = typeof args.out === "string" ? args.out : "observe.png";
          fs.writeFileSync(out, Buffer.from(r.image.base64, "base64"));
          console.log(JSON.stringify({ saved: out, meta: r.meta }, null, 2));
        }
      } finally {
        hub.close();
      }
      return;
    }
    default:
      console.log(USAGE);
      process.exit(cmd ? 1 : 0);
  }
}

async function doctor(hubOpts: any) {
  const lines: string[] = [];
  const ok = (s: string) => lines.push("  OK   " + s);
  const bad = (s: string) => lines.push("  FAIL " + s);
  const dir = findProjectDir(hubOpts.projectDir);
  if (dir) ok(`project dir: ${dir}`);
  else bad("no project.godot found (pass --project)");
  if (dir) {
    const addon = path.join(dir, "addons", "godot_bridge", "plugin.cfg");
    fs.existsSync(addon) ? ok("addon present: " + addon) : bad("addon missing: run `godot-bridge install --project " + dir + "`");
    const pg = fs.readFileSync(path.join(dir, "project.godot"), "utf8");
    pg.includes("godot_bridge/plugin.cfg") ? ok("plugin enabled in project.godot") : bad("plugin not enabled in project.godot");
    pg.includes("GodotBridgeRuntime") ? ok("GodotBridgeRuntime autoload registered") : lines.push("  WARN autoload not yet in project.godot (added when the editor first loads the plugin)");
    const d = readDiscovery(dir);
    if (!d) bad(`no ${DISCOVERY_REL}: the editor is not running with the plugin (or crashed)`);
    else if (!pidAlive(d.pid)) bad(`discovery file is stale (pid ${d.pid} not alive)`);
    else ok(`hub discovered: ${d.url} (Godot ${d.godot}, pid ${d.pid})`);
    fs.existsSync(path.join(dir, ".mcp.json")) ? ok(".mcp.json present (Claude Code)") : lines.push("  WARN no .mcp.json (Claude Code): run install");
  }
  const hub = new HubClient({ ...hubOpts, connectTimeoutMs: 3000 });
  try {
    await hub.connect();
    ok(`connected + authenticated; editor capabilities: ${JSON.stringify(hub.hello.capabilities)}`);
    const st = await hub.request("bridge.status");
    ok(`edited scene: ${st.edited_scene?.path || "<none>"}; open: ${st.open_scenes.length}; game runs: ${st.runs.length}; agents: ${st.clients.length}`);
    if (!hub.hello.capabilities.rendering) lines.push("  WARN editor is headless: godot_observe will fail with UNSUPPORTED");
    if (!hub.hello.capabilities.logger) lines.push("  WARN Logger unavailable (Godot < 4.5): godot_logs will be empty");
    try {
      await hub.request("capture.observe", { mode: "viewport", width: 64, height: 64 }, 10000);
      ok("capture works");
    } catch (e: any) {
      lines.push(`  WARN capture: ${e.code} ${e.message}`);
    }
  } catch (e: any) {
    bad(`${e.code ?? "ERROR"}: ${e.message}`);
  } finally {
    hub.close();
  }
  console.log(lines.join("\n"));
  process.exit(lines.some((l) => l.startsWith("  FAIL")) ? 1 : 0);
}

main().catch((e) => {
  if (e instanceof BridgeError) console.error(`${e.code}: ${e.message}` + (e.data ? "\n" + JSON.stringify(e.data, null, 2) : ""));
  else console.error(e);
  process.exit(1);
});
