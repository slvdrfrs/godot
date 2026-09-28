import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { HubClient, BridgeError } from "./hub.js";

// Descriptions are deliberately terse: every tool is loaded into each agent session. Details live in AGENTS.md.

const Target = z.enum(["editor", "game"]).or(z.string()).default("editor").describe("editor | game | run-<pid>");
const NodeRef = z.union([z.string(), z.object({ id: z.string() })]).describe('path from scene root, "/root/..." or {id}');
const Ev = z.record(z.any());

export type Profile = "full" | "minimal";
/** minimal = the tools needed for the core loop; full adds files/project/selection/history/spatial/metrics/lease/exec/validate. */
const MINIMAL = new Set(["godot_status", "godot_api", "godot_tree", "godot_inspect", "godot_find", "godot_patch", "godot_scene", "godot_run", "godot_step", "godot_input", "godot_observe", "godot_logs"]);

const text = (v: unknown) => ({ type: "text" as const, text: typeof v === "string" ? v : JSON.stringify(v) });

function errorResult(e: any) {
  const err = e instanceof BridgeError ? { code: e.code, message: e.message, data: e.data } : { code: "UNKNOWN", message: String(e?.message ?? e) };
  return { isError: true, content: [text(err)] };
}

function imageResult(r: any, extra: Record<string, any> = {}) {
  const { image, ...rest } = r;
  return { content: [{ type: "image" as const, data: image.base64, mimeType: image.mime }, text({ ...rest, ...extra, image: { w: image.width, h: image.height, bytes: image.bytes } })] };
}

export function registerTools(server: McpServer, hub: HubClient, profile: Profile = "full") {
  const call = async (method: string, params: Record<string, any> = {}, timeoutMs?: number) => {
    try {
      return { content: [text(await hub.request(method, params, timeoutMs))] };
    } catch (e) {
      return errorResult(e);
    }
  };
  const t = (target: string, params: Record<string, any>) => (target === "editor" ? params : { ...params, target });
  const tool: typeof server.registerTool = (name, cfg, cb) => {
    if (profile === "minimal" && !MINIMAL.has(name)) return undefined as any;
    return server.registerTool(name, cfg, cb);
  };

  tool("godot_status", { description: "Editor/game status: version, edited scene, runs, agents, leases. Call first.", inputSchema: { target: Target } }, async ({ target }) => {
    try {
      await hub.connect();
    } catch (e) {
      return errorResult(e);
    }
    return call("bridge.status", t(target, {}));
  });

  tool(
    "godot_api",
    {
      description: "Exact API of this engine build. class_name -> members; query -> class search; script_path -> project script reflection.",
      inputSchema: { class_name: z.string().optional(), query: z.string().optional(), script_path: z.string().optional(), member: z.string().optional().describe("substring filter"), inherited: z.boolean().default(false), sections: z.array(z.enum(["methods", "properties", "signals", "constants", "enums"])).optional(), target: Target },
    },
    async ({ class_name, query, script_path, member, inherited, sections, target }) => {
      if (script_path) return call("api.script", t(target, { path: script_path }));
      if (class_name) return call("api.class", t(target, { class_name, member: member ?? "", inherited, sections }));
      return call("api.search", t(target, { query: query ?? "", limit: 100 }));
    },
  );

  tool(
    "godot_files",
    { description: "Project files via the editor: list/read/dependencies/rescan/reimport.", inputSchema: { action: z.enum(["list", "read", "dependencies", "rescan", "reimport"]), dir: z.string().default("res://"), path: z.string().optional(), paths: z.array(z.string()).optional(), exts: z.array(z.string()).optional(), recursive: z.boolean().default(true), limit: z.number().int().default(300) } },
    async ({ action, dir, path, paths, exts, recursive, limit }) => {
      if (action === "list") return call("fs.list", { dir, exts: exts ?? [], recursive, limit });
      if (action === "read") return call("fs.read", { path });
      if (action === "dependencies") return call("fs.dependencies", { path });
      if (action === "rescan") return call("fs.rescan");
      return call("fs.reimport", { paths: paths ?? [] });
    },
  );

  tool(
    "godot_tree",
    {
      description: "Scene tree (ids, classes, scripts). Capped by depth/max_nodes; class_counts shows the rest. exclude_classes hides noisy subtrees (e.g. CollisionShape3D, Light3D).",
      inputSchema: { target: Target, root: NodeRef.optional(), depth: z.number().int().min(0).max(32).default(3), max_nodes: z.number().int().default(150), exclude_classes: z.array(z.string()).default([]), props: z.array(z.string()).default([]).describe("extra properties per node"), filters: z.object({ class_name: z.string().optional(), name_contains: z.string().optional(), group: z.string().optional(), script: z.string().optional() }).optional() },
    },
    async ({ target, root, depth, max_nodes, exclude_classes, props, filters }) => call("scene.tree", t(target, { root, depth, max_nodes, exclude_classes, props, filters: filters ?? {} })),
  );

  tool(
    "godot_inspect",
    { description: "Node properties (non-default by default), script members, signal connections.", inputSchema: { target: Target, refs: z.array(NodeRef).min(1), properties: z.array(z.string()).optional().describe("only these"), changed_only: z.boolean().default(true), methods: z.boolean().default(false), signals: z.boolean().default(false), connections: z.boolean().default(true), meta: z.boolean().default(false) } },
    async ({ target, refs, ...rest }) => call("scene.inspect", t(target, { refs, ...rest })),
  );

  tool("godot_find", { description: "Find nodes by class (subclasses match), name substring, group or script.", inputSchema: { target: Target, class_name: z.string().optional(), name_contains: z.string().optional(), group: z.string().optional(), script: z.string().optional(), root: NodeRef.optional(), limit: z.number().int().default(50) } }, async ({ target, ...rest }) => call("scene.find", t(target, rest)));

  tool("godot_cameras", { description: "List Camera3D/Camera2D nodes and their state.", inputSchema: { target: Target } }, async ({ target }) => call("scene.cameras", t(target, {})));

  tool(
    "godot_observe",
    {
      description: "Render + provenance. viewport = editor/game viewport pixels; camera_preview = from any camera (no UI layers); camera_takeover = exact, mutates current camera 1 frame. Default 640x360 jpeg; use 320x180 to save tokens. UNSUPPORTED when headless.",
      inputSchema: { target: Target, mode: z.enum(["viewport", "camera_preview", "camera_takeover"]).default("viewport"), camera: NodeRef.optional(), viewport: z.enum(["3d", "3d_1", "3d_2", "3d_3", "2d"]).default("3d"), width: z.number().int().default(640), height: z.number().int().default(360), format: z.enum(["jpeg", "png"]).default("jpeg"), quality: z.number().min(0.05).max(1).default(0.7), tree: z.object({ depth: z.number().int().default(2), props: z.array(z.string()).default([]) }).optional() },
    },
    async ({ target, ...rest }) => {
      try {
        return imageResult(await hub.request("capture.observe", t(target, rest), 60000));
      } catch (e) {
        return errorResult(e);
      }
    },
  );

  tool(
    "godot_spatial",
    { description: "bounds of a node; project/unproject via a Camera3D; physics raycast from a camera pixel (0..1 or px).", inputSchema: { target: Target, op: z.enum(["bounds", "project", "unproject", "raycast"]), ref: NodeRef.optional(), camera: NodeRef.optional(), pixel: z.array(z.number()).length(2).optional(), point: z.array(z.number()).length(3).optional(), length: z.number().default(1000), mask: z.number().int().optional(), areas: z.boolean().default(false) } },
    async ({ target, ...rest }) => call("spatial.query", t(target, rest)),
  );

  const Op = z
    .object({ op: z.enum(["set_property", "create_node", "instantiate_scene", "remove_node", "rename_node", "reparent_node", "attach_script", "connect_signal", "disconnect_signal", "add_to_group", "remove_from_group"]) })
    .passthrough()
    .describe("set_property{ref,property,value,expected_old?} create_node{parent,class_name,name?,properties?,script?} instantiate_scene{parent,scene_path,name?} remove_node{ref} rename_node{ref,name} reparent_node{ref,parent,index?,keep_global_transform?} attach_script{ref,script_path|null} connect_signal{ref,signal,target,method,flags?,binds?} disconnect_signal{ref,signal,target,method} add_to_group/remove_from_group{ref,group}");

  tool(
    "godot_patch",
    { description: 'Batch scene edits; in the editor one undoable action. Values: JSON, "Vector3(1,2,3)" or {"$t":..}. dry_run validates. Save with godot_scene.', inputSchema: { target: Target, operations: z.array(Op).min(1), label: z.string().optional(), dry_run: z.boolean().default(false) } },
    async ({ target, operations, label, dry_run }) => call("scene.patch", t(target, { operations, label, dry_run })),
  );

  tool(
    "godot_scene",
    { description: "Scene files: list/open/save/save_all/reload/close/new.", inputSchema: { action: z.enum(["list", "open", "save", "save_all", "reload", "close", "new"]), path: z.string().optional(), root_class: z.string().optional(), name: z.string().optional() } },
    async ({ action, path, root_class, name }) => {
      if (action === "list") return call("scene.list_open");
      if (action === "save_all") return call("scene.save", { all: true });
      if (action === "new") return call("scene.new", { path, root_class: root_class ?? "Node", name: name ?? root_class ?? "Node" });
      return call(`scene.${action}`, path ? { path } : {});
    },
  );

  tool("godot_selection", { description: "Get/set editor selection.", inputSchema: { action: z.enum(["get", "set"]).default("get"), refs: z.array(NodeRef).optional() } }, async ({ action, refs }) => call("scene.selection", { action, refs: refs ?? [] }));

  tool("godot_history", { description: "Undo/redo the edited scene; mutations = bridge edits with author.", inputSchema: { action: z.enum(["get", "undo", "redo", "mutations"]).default("get") } }, async ({ action }) => (action === "mutations" ? call("bridge.history") : call("scene.history", { action })));

  tool("godot_project", { description: "ProjectSettings get/set, or input_map.", inputSchema: { action: z.enum(["get", "set", "input_map"]), keys: z.array(z.string()).optional(), values: z.record(z.any()).optional(), persist: z.boolean().default(true) } }, async ({ action, keys, values, persist }) => (action === "input_map" ? call("project.input_map") : call("project.settings", { action, keys: keys ?? [], values: values ?? {}, persist })));

  tool("godot_validate", { description: "Compile .gd files in the editor; returns diagnostics with file:line.", inputSchema: { paths: z.array(z.string()).default([]) } }, async ({ paths }) => call("validate.scripts", { paths }, 120000));

  tool(
    "godot_run",
    { description: "start/stop/list game runs; pause/resume/time_scale/change_scene a run.", inputSchema: { action: z.enum(["start", "stop", "list", "pause", "resume", "time_scale", "change_scene"]), scene: z.enum(["main", "current"]).default("main"), path: z.string().optional(), run_id: z.string().optional(), scale: z.number().optional(), wait_ms: z.number().int().default(8000) } },
    async ({ action, scene, path, run_id, scale, wait_ms }) => {
      const g = run_id ?? "game";
      if (action === "start") return call("run.start", { scene: path ?? scene, path, wait_ms }, wait_ms + 5000);
      if (action === "stop") return call("run.stop");
      if (action === "list") return call("run.list");
      if (action === "pause" || action === "resume") return call("run.pause", { target: g, paused: action === "pause" });
      if (action === "time_scale") return call("run.time_scale", { target: g, scale: scale ?? 1 });
      return call("run.change_scene", { target: g, path });
    },
  );

  tool(
    "godot_step",
    { description: "Run N frames then pause; reports observed frames. events are delivered in the first frame (use instead of godot_input while paused).", inputSchema: { run_id: z.string().optional(), count: z.number().int().min(1).max(100000).default(1), clock: z.enum(["process", "physics"]).default("physics"), events: z.array(Ev).default([]), capture: z.object({ mode: z.enum(["viewport", "camera_preview", "camera_takeover"]).default("viewport"), camera: NodeRef.optional(), width: z.number().int().default(640), height: z.number().int().default(360), format: z.enum(["jpeg", "png"]).default("jpeg") }).optional() } },
    async ({ run_id, ...rest }) => {
      try {
        const r = await hub.request("run.step", { target: run_id ?? "game", ...rest }, 120000);
        if (r.observation?.image) {
          const { observation, ...others } = r;
          return imageResult(observation, others);
        }
        return { content: [text(r)] };
      } catch (e) {
        return errorResult(e);
      }
    },
  );

  tool(
    "godot_input",
    { description: 'Inject input into the running game. events: {type:action,action,pressed?,hold_ms?} {type:key,key:"Space",pressed?} {type:mouse_button,button,position:[x,y]} {type:mouse_motion,position,relative}.', inputSchema: { run_id: z.string().optional(), events: z.array(Ev).default([]), release_all: z.boolean().default(false) } },
    async ({ run_id, events, release_all }) => (release_all ? call("input.release_all", { target: run_id ?? "game" }) : call("input.send", { target: run_id ?? "game", events }, 60000)),
  );

  tool("godot_call", { description: "Call a node method with JSON args.", inputSchema: { target: Target, ref: NodeRef, method: z.string(), args: z.array(z.any()).default([]) } }, async ({ target, ref, method, args }) => call("scene.call", t(target, { ref, method, args })));

  tool("godot_exec", { description: "Run GDScript in-process (body of run(ctx,args)). Off unless project setting godot_bridge/allow_exec; no sandbox/timeout.", inputSchema: { target: Target, source: z.string(), args: z.record(z.any()).default({}) } }, async ({ target, source, args }) => call("exec.gdscript", t(target, { source, args }), 120000));

  tool(
    "godot_logs",
    { description: "Engine output/errors with file:line. after=last_seq for new entries only.", inputSchema: { target: Target, after: z.number().int().default(0), levels: z.array(z.enum(["info", "warning", "error", "script_error", "shader_error"])).default([]), text: z.string().default(""), limit: z.number().int().default(100), clear: z.boolean().default(false) } },
    async ({ target, after, levels, text: q, limit, clear }) => (clear ? call("logs.clear", t(target, {})) : call("logs.get", t(target, { after, levels, text: q, limit }))),
  );

  tool("godot_metrics", { description: "Performance monitors of the running game.", inputSchema: { run_id: z.string().optional(), monitors: z.array(z.string()).default([]) } }, async ({ run_id, monitors }) => call("metrics.get", { target: run_id ?? "game", monitors }));

  tool("godot_lease", { description: "Write lease per target for multi-agent use: get/acquire/renew/release/steal.", inputSchema: { action: z.enum(["get", "acquire", "renew", "release", "steal"]).default("get"), target: z.string().default("editor"), ttl_ms: z.number().int().default(30000) } }, async ({ action, target, ttl_ms }) => call("bridge.lease", { action, target, ttl_ms }));
}
