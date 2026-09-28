// End-to-end test: starts a headless Godot editor on tests/project, drives the hub through the
// same HubClient the MCP server uses, launches the game (headless) and drives the runtime.
// Usage: GODOT=/path/to/godot node tests/e2e.mjs
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { HubClient } from "../bridge/dist/hub.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.join(here, "project");
const godot = process.env.GODOT ?? "godot";
const discovery = path.join(project, ".godot", "godot_bridge.json");
if (fs.existsSync(discovery)) fs.rmSync(discovery);

const editor = spawn(godot, ["--headless", "--editor", "--path", project], { stdio: ["ignore", "pipe", "pipe"] });
let editorLog = "";
editor.stdout.on("data", (d) => (editorLog += d));
editor.stderr.on("data", (d) => (editorLog += d));
const cleanup = () => {
  try {
    editor.kill("SIGTERM");
  } catch {}
};
process.on("exit", cleanup);

let passed = 0;
const step = async (name, fn) => {
  try {
    await fn();
    passed++;
    console.log("  ok   " + name);
  } catch (e) {
    console.log("  FAIL " + name + "\n       " + (e.stack ?? e));
    console.log("---- editor log tail ----\n" + editorLog.split("\n").slice(-40).join("\n"));
    cleanup();
    process.exit(1);
  }
};

const a = new HubClient({ projectDir: project, clientName: "claude-test", connectTimeoutMs: 60000 });
const b = new HubClient({ projectDir: project, clientName: "codex-test", connectTimeoutMs: 60000 });

await step("agent A connects + hello", async () => {
  await a.connect();
  assert.equal(a.hello.role, "editor");
  assert.equal(a.hello.godot.major, 4);
  assert.ok(a.hello.methods.includes("scene.patch"));
});
await step("agent B connects (two agents at once)", async () => {
  await b.connect();
  const st = await a.request("bridge.status");
  assert.equal(st.clients.length, 2);
});
await step("status shows edited scene", async () => {
  const st = await a.request("bridge.status");
  assert.equal(st.edited_scene.path, "res://main.tscn");
  assert.equal(st.capabilities.logger, true);
});
await step("api.class ground truth", async () => {
  const r = await a.request("api.class", { class_name: "CharacterBody3D", sections: ["methods", "properties"] });
  assert.ok(r.methods.some((m) => m.name === "move_and_slide"));
  assert.ok(r.inheritance.includes("Node3D"));
  const s = await a.request("api.search", { query: "Camera" });
  assert.ok(s.classes.includes("Camera3D"));
});
await step("api.script reflects project script", async () => {
  const r = await a.request("api.script", { path: "res://player.gd" });
  assert.equal(r.base, "CharacterBody3D");
  assert.ok(r.methods.some((m) => m.name === "greet" && m.args.length === 2 && m.args[1].default === 1));
  assert.ok(r.signals.some((s) => s.name === "jumped"));
  assert.ok(r.properties.some((p) => p.name === "speed" && p.exported));
});
let playerId;
await step("scene.tree / find / inspect / cameras", async () => {
  const t = await a.request("scene.tree", { depth: 3, props: ["position"] });
  assert.equal(t.root.name, "Main");
  assert.ok(!("abs_path" in t.root), "editor-internal abs paths must be hidden");
  const player = t.root.children_nodes.find((n) => n.name === "Player");
  assert.equal(player.script, "res://player.gd");
  playerId = player.id;
  const f = await a.request("scene.find", { class_name: "Camera3D" });
  assert.equal(f.nodes.length, 2);
  const i = await a.request("scene.inspect", { refs: [{ id: playerId }], methods: true });
  const node = i.nodes[0];
  assert.equal(node.properties.speed, 4.5);
  assert.ok(node.methods.some((m) => m.name === "greet"));
  assert.ok(node.signals.some((s) => s.name === "jumped"));
  const c = await a.request("scene.cameras");
  assert.equal(c.cameras.length, 3);
  assert.ok(c.cameras.some((cam) => cam.kind === "2d"));
});
await step("scene.patch is validated (dry_run) and rejects bad refs", async () => {
  const r = await a.request("scene.patch", { dry_run: true, operations: [{ op: "set_property", ref: "Player", property: "speed", value: 9 }] });
  assert.equal(r.valid, true);
  await assert.rejects(a.request("scene.patch", { operations: [{ op: "set_property", ref: "Nope", property: "speed", value: 9 }] }), (e) => e.code === "NOT_FOUND");
});
await step("scene.patch applies, undo/redo works", async () => {
  const r = await a.request("scene.patch", {
    label: "test patch",
    operations: [
      { op: "set_property", ref: "Player", property: "speed", value: 9.5, expected_old: 4.5 },
      { op: "set_property", ref: "Player", property: "position", value: [1, 2, 3] },
      { op: "create_node", parent: "Player", class_name: "Node3D", name: "Marker", properties: { position: "Vector3(0, 1, 0)" } },
      { op: "connect_signal", ref: "Player", signal: "jumped", target: ".", method: "set_name" },
      { op: "add_to_group", ref: "Player/Mesh", group: "meshes" },
    ],
  });
  assert.equal(r.applied, 5);
  assert.equal(r.undoable, true);
  let i = await a.request("scene.inspect", { refs: ["Player"], properties: ["speed", "position"] });
  assert.equal(i.nodes[0].properties.speed, 9.5);
  assert.deepEqual(i.nodes[0].properties.position.v, [1, 2, 3]);
  assert.ok(i.nodes[0].outgoing_connections.some((c) => c.signal === "jumped" && c.method === "set_name"));
  const m = await a.request("scene.inspect", { refs: ["Player/Marker"], properties: ["position"] });
  assert.deepEqual(m.nodes[0].properties.position.v, [0, 1, 0]);
  const h = await a.request("scene.history", { action: "undo" });
  assert.equal(h.undone, "test patch");
  i = await a.request("scene.inspect", { refs: ["Player"], properties: ["speed"] });
  assert.equal(i.nodes[0].properties.speed, 4.5);
  await assert.rejects(a.request("scene.inspect", { refs: ["Player/Marker"] }).then((r) => { if (r.nodes[0].error) throw Object.assign(new Error(), { code: "NOT_FOUND" }); }), (e) => e.code === "NOT_FOUND");
  await a.request("scene.history", { action: "redo" });
  i = await a.request("scene.inspect", { refs: ["Player"], properties: ["speed"] });
  assert.equal(i.nodes[0].properties.speed, 9.5);
  const hist = await a.request("bridge.history");
  assert.ok(hist.mutations.some((m) => m.client === "claude-test" && m.method === "scene.patch"));
});
await step("lease: B is blocked while A holds the write lease", async () => {
  await assert.rejects(b.request("scene.patch", { operations: [{ op: "set_property", ref: "Player", property: "speed", value: 1 }] }), (e) => e.code === "CONFLICT" && e.data.holder === "claude-test");
  await a.request("bridge.lease", { action: "release", target: "editor" });
  const r = await b.request("scene.patch", { operations: [{ op: "set_property", ref: "Player", property: "speed", value: 7 }] });
  assert.equal(r.applied, 1);
  await b.request("bridge.lease", { action: "release", target: "editor" });
});
await step("scene.save writes the .tscn and remove_node undo restores it", async () => {
  await a.request("scene.save", { path: "res://main_saved.tscn" });
  const txt = fs.readFileSync(path.join(project, "main_saved.tscn"), "utf8");
  assert.ok(txt.includes('name="Marker"'), "Marker persisted");
  assert.ok(txt.includes("speed = 7"), "speed persisted");
  assert.ok(txt.includes('[connection signal="jumped"'), "connection persisted");
  const r = await a.request("scene.patch", { operations: [{ op: "remove_node", ref: "Player/Marker" }] });
  assert.equal(r.applied, 1);
  await a.request("scene.history", { action: "undo" });
  const m = await a.request("scene.inspect", { refs: ["Player/Marker"], properties: ["position"] });
  assert.ok(!m.nodes[0].error);
  await a.request("scene.open", { path: "res://main.tscn" });
});
await step("exec.gdscript runs in the editor and errors are captured by the logger", async () => {
  const r = await a.request("exec.gdscript", { source: "return ctx.root.get_child_count() + args.n", args: { n: 10 } });
  assert.equal(r.result, 16);
  const before = (await a.request("logs.get", { limit: 1 })).last_seq;
  await a.request("exec.gdscript", { source: 'push_error("bridge-test-error"); print("bridge-test-print"); return 1' });
  const logs = await a.request("logs.get", { after: before });
  assert.ok(logs.entries.some((e) => e.kind === "error" && e.text.includes("bridge-test-error")), JSON.stringify(logs.entries));
  assert.ok(logs.entries.some((e) => e.kind === "message" && e.text.includes("bridge-test-print")));
});
await step("validate.scripts reports a broken script", async () => {
  fs.writeFileSync(path.join(project, "broken.gd"), "extends Node\nfunc _ready():\n\tvar x = \n");
  await a.request("fs.rescan");
  const r = await a.request("validate.scripts", { paths: ["res://broken.gd", "res://player.gd"] });
  const broken = r.results.find((x) => x.path === "res://broken.gd");
  assert.equal(broken.ok, false);
  assert.ok(broken.diagnostics.length > 0);
  assert.equal(r.results.find((x) => x.path === "res://player.gd").ok, true);
  fs.rmSync(path.join(project, "broken.gd"));
  await a.request("fs.rescan");
});
await step("capture is refused honestly when headless", async () => {
  await assert.rejects(a.request("capture.observe", { mode: "viewport" }), (e) => e.code === "UNSUPPORTED");
});
let run;
await step("run.start launches the game and it connects to the hub", async () => {
  await assert.rejects(a.request("scene.tree", { target: "game" }), (e) => e.code === "NO_RUN");
  const r = await a.request("run.start", { scene: "main", wait_ms: 30000 }, 40000);
  assert.equal(r.started, true, JSON.stringify(r));
  run = r.run;
  assert.match(run.run_id, /^run-\d+$/);
});
await step("runtime: status / tree / inspect / call", async () => {
  const st = await a.request("bridge.status", { target: "game" });
  assert.equal(st.role, "runtime");
  assert.equal(st.current_scene.name, "Main");
  const t = await a.request("scene.tree", { target: run.run_id, depth: 2 });
  assert.equal(t.root.name, "Main");
  assert.ok(t.root.abs_path === "/root/Main");
  const c = await a.request("scene.call", { target: "game", ref: "Player", method: "greet", args: ["bridge", 2] });
  assert.equal(c.result, "hi bridge hi bridge");
  const i = await a.request("scene.inspect", { target: "game", refs: ["/root/Main/Player"], properties: ["ticks"] });
  assert.ok(i.nodes[0].properties.ticks >= 0);
});
await step("runtime: pause + step reports observed frames", async () => {
  await a.request("run.pause", { target: "game", paused: true });
  const before = (await a.request("scene.inspect", { target: "game", refs: ["Player"], properties: ["ticks"] })).nodes[0].properties.ticks;
  const s = await a.request("run.step", { target: "game", count: 5, clock: "physics" });
  assert.equal(s.requested, 5);
  assert.ok(s.observed_physics_frames >= 5, JSON.stringify(s));
  assert.equal(s.paused, true);
  const after = (await a.request("scene.inspect", { target: "game", refs: ["Player"], properties: ["ticks"] })).nodes[0].properties.ticks;
  assert.ok(after > before, `ticks ${before} -> ${after}`);
});
await step("runtime: input action reaches the script, logs captured, signals fire", async () => {
  const before = (await a.request("logs.get", { target: "game", limit: 1 })).last_seq;
  const s1 = await a.request("run.step", { target: "game", count: 2, clock: "physics", events: [{ type: "action", action: "jump", pressed: true }] });
  assert.equal(s1.events_delivered.length, 1);
  await a.request("run.step", { target: "game", count: 2, clock: "physics", events: [{ type: "action", action: "jump", pressed: false }] });
  const i = await a.request("scene.inspect", { target: "game", refs: ["Player"], properties: ["jumps"] });
  assert.equal(i.nodes[0].properties.jumps, 1);
  const logs = await a.request("logs.get", { target: "game", after: before });
  assert.ok(logs.entries.some((e) => (e.text ?? "").includes("Player jumped #1")), JSON.stringify(logs.entries));
  await a.request("run.step", { target: "game", count: 2, clock: "process", events: [{ type: "key", key: "E", pressed: true }, { type: "key", key: "E", pressed: false }] });
  const warn = await a.request("logs.get", { target: "game", after: before, levels: ["warning"] });
  assert.ok(warn.entries.some((e) => e.text.includes("E pressed")), JSON.stringify(warn.entries));
});
await step("runtime: input.send while running (unpaused) also works", async () => {
  await a.request("run.pause", { target: "game", paused: false });
  await a.request("input.send", { target: "game", events: [{ type: "action", action: "jump", pressed: true, hold_ms: 60 }] });
  await new Promise((r) => setTimeout(r, 300));
  const i = await a.request("scene.inspect", { target: "game", refs: ["Player"], properties: ["jumps"] });
  assert.equal(i.nodes[0].properties.jumps, 2);
  await a.request("run.pause", { target: "game", paused: true });
});
await step("runtime: patch (no undo) + metrics + spatial bounds + exec", async () => {
  const r = await a.request("scene.patch", { target: "game", operations: [{ op: "set_property", ref: "Player", property: "speed", value: 42 }] });
  assert.equal(r.undoable, false);
  const i = await a.request("scene.inspect", { target: "game", refs: ["Player"], properties: ["speed"] });
  assert.equal(i.nodes[0].properties.speed, 42);
  const m = await a.request("metrics.get", { target: "game" });
  assert.ok("OBJECT_NODE_COUNT" in m.monitors);
  const bnd = await a.request("spatial.query", { target: "game", op: "bounds", ref: "Player/Mesh" });
  assert.equal(bnd.global_aabb.$t, "AABB");
  const ex = await a.request("exec.gdscript", { target: "game", source: "return Engine.get_physics_frames() > 0" });
  assert.equal(ex.result, true);
});
await step("runtime: lease conflict is enforced through the hub for game targets", async () => {
  await assert.rejects(b.request("run.step", { target: "game", count: 1 }), (e) => e.code === "CONFLICT");
});
await step("run.stop ends the game and the run disappears", async () => {
  await a.request("run.stop");
  for (let i = 0; i < 40; i++) {
    const st = await a.request("bridge.status");
    if (st.runs.length === 0) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  const st = await a.request("bridge.status");
  assert.equal(st.runs.length, 0);
});

console.log(`\n${passed} steps passed`);
a.close();
b.close();
cleanup();
fs.rmSync(path.join(project, "main_saved.tscn"), { force: true });
process.exit(0);
