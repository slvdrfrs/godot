import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { HubClient, BridgeError } from "./hub.js";

const Target = z
  .enum(["editor", "game"])
  .or(z.string().regex(/^run-\d+$/))
  .default("editor")
  .describe('"editor" = the scene open in the editor; "game" = the most recent running game instance (F5); or a run id like "run-1234" from godot_status.');

const NodeRef = z
  .union([z.string(), z.object({ id: z.string() })])
  .describe('Node reference: path relative to the scene root ("Player/Mesh"), absolute path ("/root/Main/Player"), "." for the root, or {"id": "<instance id>"} from a previous result (stable across renames).');

const text = (v: unknown) => ({ type: "text" as const, text: typeof v === "string" ? v : JSON.stringify(v, null, 1) });

function errorResult(e: any) {
  const err = e instanceof BridgeError ? { code: e.code, message: e.message, data: e.data } : { code: "UNKNOWN", message: String(e?.message ?? e) };
  return { isError: true, content: [text(err)] };
}

export function registerTools(server: McpServer, hub: HubClient) {
  const call = async (method: string, params: Record<string, any> = {}, timeoutMs?: number) => {
    try {
      const result = await hub.request(method, params, timeoutMs);
      return { content: [text(result)] };
    } catch (e) {
      return errorResult(e);
    }
  };
  const withTarget = (target: string, params: Record<string, any>) => (target === "editor" ? params : { ...params, target });

  server.registerTool(
    "godot_status",
    {
      title: "Godot status",
      description:
        "Connection + editor + running-game status: Godot version, renderer, edited scene, open scenes, connected agents, write leases, game runs, log capture availability. Call this first. target=game gives the runtime status (paused, frame counters, fps, window size).",
      inputSchema: { target: Target },
    },
    async ({ target }) => {
      try {
        await hub.connect();
      } catch (e) {
        return errorResult(e);
      }
      const r = await call("bridge.status", withTarget(target, {}));
      if ("isError" in r && r.isError) return r;
      const parsed = JSON.parse((r.content[0] as any).text);
      parsed.hub = { url: hub.discovery?.url, project_dir: hub.projectDir, client: hub.opts.clientName };
      return { content: [text(parsed)] };
    },
  );

  server.registerTool(
    "godot_api",
    {
      title: "Godot API ground truth",
      description:
        "Reflection of the exact engine build running in the editor (ClassDB) or of a project script. Use instead of guessing method names/signatures. Give class_name for a native class (methods, properties with defaults, signals, constants, enums), query to search class names, or script_path for a project GDScript/C# script (exports, methods, signals, class_name).",
      inputSchema: {
        class_name: z.string().optional().describe("Native class, e.g. CharacterBody3D"),
        query: z.string().optional().describe("Substring to search class names"),
        script_path: z.string().optional().describe("res://path/to/script.gd"),
        member: z.string().optional().describe("Filter members by substring"),
        inherited: z.boolean().default(false).describe("Include inherited members (can be large)"),
        sections: z.array(z.enum(["methods", "properties", "signals", "constants", "enums"])).optional(),
        target: Target,
      },
    },
    async ({ class_name, query, script_path, member, inherited, sections, target }) => {
      if (script_path) return call("api.script", withTarget(target, { path: script_path }));
      if (class_name) return call("api.class", withTarget(target, { class_name, member: member ?? "", inherited, sections }));
      return call("api.search", withTarget(target, { query: query ?? "", limit: 100 }));
    },
  );

  server.registerTool(
    "godot_files",
    {
      title: "Project files (through the editor)",
      description:
        "list / read project files as the editor sees them (res:// paths), get resource dependencies, rescan the filesystem after editing files externally, or reimport assets. Prefer your own file tools for editing source; use rescan after external edits so the editor picks them up.",
      inputSchema: {
        action: z.enum(["list", "read", "dependencies", "rescan", "reimport"]),
        dir: z.string().default("res://"),
        path: z.string().optional(),
        paths: z.array(z.string()).optional(),
        exts: z.array(z.string()).optional().describe('e.g. ["tscn","gd"]'),
        recursive: z.boolean().default(true),
        limit: z.number().int().default(500),
      },
    },
    async ({ action, dir, path, paths, exts, recursive, limit }) => {
      switch (action) {
        case "list":
          return call("fs.list", { dir, exts: exts ?? [], recursive, limit });
        case "read":
          return call("fs.read", { path });
        case "dependencies":
          return call("fs.dependencies", { path });
        case "rescan":
          return call("fs.rescan");
        case "reimport":
          return call("fs.reimport", { paths: paths ?? [] });
      }
    },
  );

  server.registerTool(
    "godot_tree",
    {
      title: "Scene tree",
      description:
        "Structured scene tree (ids, names, classes, scripts, groups, visibility, child counts) of the edited scene or of the running game. Depth-limited; pass props to include specific property values per node (e.g. [\"position\",\"visible\"]). filters mark matching nodes.",
      inputSchema: {
        target: Target,
        root: NodeRef.optional().describe("Start from this node instead of the scene root"),
        depth: z.number().int().min(0).max(32).default(4),
        props: z.array(z.string()).default([]),
        filters: z.object({ class_name: z.string().optional(), name_contains: z.string().optional(), group: z.string().optional(), script: z.string().optional() }).optional(),
        max_nodes: z.number().int().default(500),
      },
    },
    async ({ target, root, depth, props, filters, max_nodes }) => call("scene.tree", withTarget(target, { root, depth, props, filters: filters ?? {}, max_nodes })),
  );

  server.registerTool(
    "godot_inspect",
    {
      title: "Inspect nodes",
      description:
        "Full inspection of one or more nodes: all editor/storage properties with types (or only the ones you name), global transform, script methods, signals and live signal connections. changed_only=true returns only properties that differ from the class default.",
      inputSchema: {
        target: Target,
        refs: z.array(NodeRef).min(1),
        properties: z.array(z.string()).optional().describe("Only these properties"),
        changed_only: z.boolean().default(false),
        methods: z.boolean().default(false),
        signals: z.boolean().default(true),
        connections: z.boolean().default(true),
        meta: z.boolean().default(false).describe("Include type/hint/usage metadata per property"),
      },
    },
    async ({ target, refs, properties, changed_only, methods, signals, connections, meta }) =>
      call("scene.inspect", withTarget(target, { refs, properties, changed_only, methods, signals, connections, meta })),
  );

  server.registerTool(
    "godot_find",
    {
      title: "Find nodes",
      description: "Search nodes by class (is_class, so subclasses match), name substring, group or script path/class_name.",
      inputSchema: {
        target: Target,
        class_name: z.string().optional(),
        name_contains: z.string().optional(),
        group: z.string().optional(),
        script: z.string().optional(),
        root: NodeRef.optional(),
        limit: z.number().int().default(100),
      },
    },
    async ({ target, ...rest }) => call("scene.find", withTarget(target, rest)),
  );

  server.registerTool(
    "godot_cameras",
    {
      title: "List cameras",
      description: "All Camera3D/Camera2D nodes with current/enabled state, projection, effective 2D screen center, and which observe modes each supports.",
      inputSchema: { target: Target },
    },
    async ({ target }) => call("scene.cameras", withTarget(target, {})),
  );

  server.registerTool(
    "godot_observe",
    {
      title: "Observe (render + state)",
      description:
        "SEE the scene: returns a PNG plus provenance metadata (camera transform/projection, frame counters, guarantee and limitations) and optionally the tree in the same iteration. Modes: viewport (exact pixels of the editor 3D/2D viewport or the game's main window), camera_preview (render from ANY Camera3D/Camera2D through an auxiliary viewport sharing the world; no CanvasLayers/UI), camera_takeover (make that camera current for one frame in its real viewport: exact composition, but a temporary mutation of the game). Fails with UNSUPPORTED when the editor runs headless.",
      inputSchema: {
        target: Target,
        mode: z.enum(["viewport", "camera_preview", "camera_takeover"]).default("viewport"),
        camera: NodeRef.optional().describe("Required for camera_* modes"),
        viewport: z.enum(["3d", "3d_1", "3d_2", "3d_3", "2d"]).default("3d").describe("Editor only: which editor viewport"),
        width: z.number().int().default(960),
        height: z.number().int().default(540),
        tree: z.object({ depth: z.number().int().default(3), props: z.array(z.string()).default([]) }).optional().describe("Also return the scene tree captured in the same iteration"),
      },
    },
    async ({ target, mode, camera, viewport, width, height, tree }) => {
      try {
        const r = await hub.request("capture.observe", withTarget(target, { mode, camera, viewport, width, height, tree }), 60000);
        const { image, ...rest } = r;
        return {
          content: [
            { type: "image" as const, data: image.base64, mimeType: image.mime },
            text({ ...rest, image: { width: image.width, height: image.height } }),
          ],
        };
      } catch (e) {
        return errorResult(e);
      }
    },
  );

  server.registerTool(
    "godot_spatial",
    {
      title: "Spatial queries",
      description:
        "Geometry helpers: bounds of a node (AABB / rect), project a world point to a camera pixel, unproject a pixel to a ray, or physics raycast from a camera pixel (hits CollisionObject3D shapes only, not visual geometry). pixel may be normalized 0..1 or absolute px.",
      inputSchema: {
        target: Target,
        op: z.enum(["bounds", "project", "unproject", "raycast"]),
        ref: NodeRef.optional(),
        camera: NodeRef.optional(),
        pixel: z.array(z.number()).length(2).optional(),
        point: z.array(z.number()).length(3).optional(),
        length: z.number().default(1000),
        mask: z.number().int().optional(),
        areas: z.boolean().default(false),
      },
    },
    async ({ target, ...rest }) => call("spatial.query", withTarget(target, rest)),
  );

  const Op = z.discriminatedUnion("op", [
    z.object({ op: z.literal("set_property"), ref: NodeRef, property: z.string(), value: z.any(), expected_old: z.any().optional() }),
    z.object({ op: z.literal("create_node"), parent: NodeRef.default("."), class_name: z.string(), name: z.string().optional(), properties: z.record(z.any()).optional(), script: z.string().optional() }),
    z.object({ op: z.literal("instantiate_scene"), parent: NodeRef.default("."), scene_path: z.string(), name: z.string().optional() }),
    z.object({ op: z.literal("remove_node"), ref: NodeRef }),
    z.object({ op: z.literal("rename_node"), ref: NodeRef, name: z.string() }),
    z.object({ op: z.literal("reparent_node"), ref: NodeRef, parent: NodeRef, index: z.number().int().optional(), keep_global_transform: z.boolean().default(true) }),
    z.object({ op: z.literal("attach_script"), ref: NodeRef, script_path: z.string().nullable() }),
    z.object({ op: z.literal("connect_signal"), ref: NodeRef, signal: z.string(), target: NodeRef, method: z.string(), flags: z.number().int().optional(), binds: z.array(z.any()).optional() }),
    z.object({ op: z.literal("disconnect_signal"), ref: NodeRef, signal: z.string(), target: NodeRef, method: z.string() }),
    z.object({ op: z.literal("add_to_group"), ref: NodeRef, group: z.string() }),
    z.object({ op: z.literal("remove_from_group"), ref: NodeRef, group: z.string() }),
  ]);

  server.registerTool(
    "godot_patch",
    {
      title: "Patch scene (undoable)",
      description:
        'Apply structured edits to the edited scene (or to the live game with target=game). Editor patches are a single undoable action labelled with your client name. Values: plain JSON, "Vector3(1,2,3)"-style strings, or tagged {"$t":"Vector3","v":[1,2,3]}; numbers/arrays are coerced to the property type. Use dry_run to validate refs/classes first. Remember godot_scene save afterwards.',
      inputSchema: {
        target: Target,
        operations: z.array(Op).min(1),
        label: z.string().optional().describe("Undo history label"),
        dry_run: z.boolean().default(false),
      },
    },
    async ({ target, operations, label, dry_run }) => call("scene.patch", withTarget(target, { operations, label, dry_run })),
  );

  server.registerTool(
    "godot_scene",
    {
      title: "Scene files",
      description: "list open scenes, open a scene in the editor, save (current or all, or save_as with path), reload a scene after external edits, close the edited scene, or create a new scene file with a root class.",
      inputSchema: {
        action: z.enum(["list", "open", "save", "save_all", "reload", "new", "close"]),
        path: z.string().optional(),
        root_class: z.string().optional(),
        name: z.string().optional(),
      },
    },
    async ({ action, path, root_class, name }) => {
      switch (action) {
        case "list":
          return call("scene.list_open");
        case "open":
          return call("scene.open", { path });
        case "save":
          return call("scene.save", path ? { path } : {});
        case "save_all":
          return call("scene.save", { all: true });
        case "reload":
          return call("scene.reload", path ? { path } : {});
        case "close":
          return call("scene.close", path ? { path } : {});
        case "new":
          return call("scene.new", { path, root_class: root_class ?? "Node", name: name ?? root_class ?? "Node" });
      }
    },
  );

  server.registerTool(
    "godot_selection",
    {
      title: "Editor selection",
      description: "Get or set the editor's selected nodes (set also shows the first in the Inspector). Useful to point the human at what you changed.",
      inputSchema: { action: z.enum(["get", "set"]).default("get"), refs: z.array(NodeRef).optional() },
    },
    async ({ action, refs }) => call("scene.selection", { action, refs: refs ?? [] }),
  );

  server.registerTool(
    "godot_history",
    {
      title: "Undo / redo",
      description: "Inspect the edited scene's undo history, undo or redo the last action (including your own patches and the human's edits), and list recent mutations made through the bridge with their author.",
      inputSchema: { action: z.enum(["get", "undo", "redo", "mutations"]).default("get") },
    },
    async ({ action }) => (action === "mutations" ? call("bridge.history") : call("scene.history", { action })),
  );

  server.registerTool(
    "godot_project",
    {
      title: "Project settings",
      description: "Read/write ProjectSettings keys (e.g. application/run/main_scene, physics/common/physics_ticks_per_second) or list the InputMap actions with their events.",
      inputSchema: {
        action: z.enum(["get", "set", "input_map"]),
        keys: z.array(z.string()).optional(),
        values: z.record(z.any()).optional(),
        persist: z.boolean().default(true),
      },
    },
    async ({ action, keys, values, persist }) => {
      if (action === "input_map") return call("project.input_map");
      return call("project.settings", { action, keys: keys ?? [], values: values ?? {}, persist });
    },
  );

  server.registerTool(
    "godot_validate",
    {
      title: "Validate scripts",
      description: "Compile GDScript files fresh inside the editor and return parser/analyzer diagnostics captured from the engine log (all .gd files when paths is empty). Run after editing scripts.",
      inputSchema: { paths: z.array(z.string()).default([]) },
    },
    async ({ paths }) => call("validate.scripts", { paths }, 120000),
  );

  server.registerTool(
    "godot_run",
    {
      title: "Run / stop / pause the game",
      description:
        "start the main, current or a specific scene from the editor (waits for the game to connect to the hub and returns its run id), stop it, list runs, pause/resume the SceneTree, set Engine.time_scale, or change_scene inside the running game.",
      inputSchema: {
        action: z.enum(["start", "stop", "list", "pause", "resume", "time_scale", "change_scene"]),
        scene: z.enum(["main", "current"]).default("main"),
        path: z.string().optional().describe("res://... scene for start (overrides scene) or change_scene"),
        run_id: z.string().optional(),
        scale: z.number().optional(),
        wait_ms: z.number().int().default(8000),
      },
    },
    async ({ action, scene, path, run_id, scale, wait_ms }) => {
      const game = run_id ?? "game";
      switch (action) {
        case "start":
          return call("run.start", { scene: path ?? scene, path, wait_ms }, wait_ms + 5000);
        case "stop":
          return call("run.stop");
        case "list":
          return call("run.list");
        case "pause":
          return call("run.pause", { target: game, paused: true });
        case "resume":
          return call("run.pause", { target: game, paused: false });
        case "time_scale":
          return call("run.time_scale", { target: game, scale: scale ?? 1 });
        case "change_scene":
          return call("run.change_scene", { target: game, path });
      }
    },
  );

  server.registerTool(
    "godot_step",
    {
      title: "Step the running game",
      description:
        "Cooperative frame stepping: (deliver events) unpause, run N process or physics frames, pause again. Reports requested vs observed process/physics frames (honest: physics may tick 0..n per frame; process_mode ALWAYS nodes keep running while paused). Optionally capture an observation right after.",
      inputSchema: {
        run_id: z.string().optional(),
        count: z.number().int().min(1).max(100000).default(1),
        clock: z.enum(["process", "physics"]).default("physics"),
        events: z.array(z.record(z.any())).default([]).describe("Input events (same format as godot_input) delivered in the first stepped frame; use this instead of godot_input while paused"),
        capture: z.object({ mode: z.enum(["viewport", "camera_preview", "camera_takeover"]).default("viewport"), camera: NodeRef.optional(), width: z.number().int().default(960), height: z.number().int().default(540) }).optional(),
      },
    },
    async ({ run_id, count, clock, events, capture }) => {
      try {
        const r = await hub.request("run.step", { target: run_id ?? "game", count, clock, events, capture }, 120000);
        const content: any[] = [];
        if (r.observation?.image) {
          content.push({ type: "image", data: r.observation.image.base64, mimeType: r.observation.image.mime });
          r.observation.image = { width: r.observation.image.width, height: r.observation.image.height };
        }
        content.push(text(r));
        return { content };
      } catch (e) {
        return errorResult(e);
      }
    },
  );

  server.registerTool(
    "godot_input",
    {
      title: "Inject input into the game",
      description:
        'Send input events to the running game through Input.parse_input_event (reach _input/_unhandled_input and action state). Event types: {type:"action", action, pressed?, strength?, hold_ms?}, {type:"key", key:"Space"|"A"|"Escape", pressed?, hold_ms?, shift?, ctrl?}, {type:"mouse_button", button:1, position:[x,y], pressed?, hold_ms?}, {type:"mouse_motion", position:[x,y], relative:[dx,dy]}. hold_ms presses then releases. release_all releases everything the bridge pressed. While the game is paused use godot_step with events instead.',
      inputSchema: {
        run_id: z.string().optional(),
        events: z.array(z.record(z.any())).default([]),
        release_all: z.boolean().default(false),
      },
    },
    async ({ run_id, events, release_all }) => {
      const target = run_id ?? "game";
      if (release_all) return call("input.release_all", { target });
      return call("input.send", { target, events }, 60000);
    },
  );

  server.registerTool(
    "godot_call",
    {
      title: "Call a node method",
      description: "Call any method on a node (editor scene or running game) with JSON args and get the encoded return value. Not undoable.",
      inputSchema: { target: Target, ref: NodeRef, method: z.string(), args: z.array(z.any()).default([]) },
    },
    async ({ target, ref, method, args }) => call("scene.call", withTarget(target, { ref, method, args })),
  );

  server.registerTool(
    "godot_exec",
    {
      title: "Execute GDScript",
      description:
        "Escape hatch: hot-compile and run GDScript inside the editor or the running game. source is the body of `func run(ctx, args)` (ctx.root = scene root, ctx.tree = SceneTree, ctx.editor = bool) or a full script defining run(). No sandbox and no timeout on infinite loops: prefer structured tools. Compile errors show up in godot_logs.",
      inputSchema: { target: Target, source: z.string(), args: z.record(z.any()).default({}) },
    },
    async ({ target, source, args }) => call("exec.gdscript", withTarget(target, { source, args }), 120000),
  );

  server.registerTool(
    "godot_logs",
    {
      title: "Engine logs & errors",
      description:
        "Output, warnings, errors and script errors (with file/line/backtrace) captured by an OS Logger in the editor or the game. Use after (cursor = last_seq) to read only new entries; levels filters (info, warning, error, script_error, shader_error).",
      inputSchema: {
        target: Target,
        after: z.number().int().default(0),
        levels: z.array(z.enum(["info", "warning", "error", "script_error", "shader_error"])).default([]),
        text: z.string().default(""),
        limit: z.number().int().default(200),
        clear: z.boolean().default(false),
      },
    },
    async ({ target, after, levels, text: t, limit, clear }) => (clear ? call("logs.clear", withTarget(target, {})) : call("logs.get", withTarget(target, { after, levels, text: t, limit }))),
  );

  server.registerTool(
    "godot_metrics",
    {
      title: "Performance monitors",
      description: "Engine counters from the running game (fps, process/physics time, draw calls, primitives, video memory, object/node counts, physics active objects) plus custom monitors. Not a per-function profiler.",
      inputSchema: { run_id: z.string().optional(), monitors: z.array(z.string()).default([]) },
    },
    async ({ run_id, monitors }) => call("metrics.get", { target: run_id ?? "game", monitors }),
  );

  server.registerTool(
    "godot_lease",
    {
      title: "Write lease (multi-agent)",
      description:
        "Coordination when several agents (e.g. Claude and Codex) share one editor: mutations auto-acquire a 30 s write lease per target; another live holder causes CONFLICT. acquire/renew, release when done with a batch, steal only if the holder is stuck, get to see holders.",
      inputSchema: { action: z.enum(["get", "acquire", "renew", "release", "steal"]).default("get"), target: z.string().default("editor"), ttl_ms: z.number().int().default(30000) },
    },
    async ({ action, target, ttl_ms }) => call("bridge.lease", { action, target, ttl_ms }),
  );
}
