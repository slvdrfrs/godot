# Godot Bridge protocol (v1)

Transport: WebSocket on `127.0.0.1` (text frames), JSON-RPC 2.0. The editor plugin is the **hub**; MCP adapters and game
instances are clients. Discovery: `<project>/.godot/godot_bridge.json` = `{protocol, url, port, token, pid, godot, project, project_path}`.
Written when the hub starts, deleted on exit; a stale file (dead pid) is ignored.

## Handshake

```json
{"jsonrpc":"2.0","id":1,"method":"bridge.hello","params":{"client":"claude","role":"agent","token":"<from discovery>"}}
```
Game instances send `role: "runtime"` plus `run_id`, `pid`, `scene`. Until `bridge.hello` succeeds every other call is
`UNAUTHORIZED`. The hub answers with `godot` version, `capabilities` and the list of `methods`.

## Routing

Any request whose `params.target` is `"game"`, `"runtime"` or a `run-<pid>` id is forwarded verbatim to that game instance
(latest connected wins for `"game"`); the response is relayed back with the original id. Without `target` (or `"editor"`) the
hub handles it.

## Errors

JSON-RPC `error.data.code` is a stable string: `UNAUTHORIZED`, `NOT_FOUND`, `INVALID`, `NO_SCENE`, `NO_RUN`, `CONFLICT`
(write lease held by another live client; `data.holder`), `BUSY`, `UNSUPPORTED` (e.g. capture without rendering),
`COMPILE_ERROR`, `DISABLED`, `SAVE_FAILED`, `TIMEOUT`/`DISCONNECTED` (adapter side).

## Leases

Methods marked mutating (`scene.patch`, `scene.call`, `exec.gdscript`, `scene.open/save/reload/new/close`, `scene.selection`,
`scene.history`, `project.settings`, `fs.reimport`, `run.*`, `input.*`) auto-acquire a 30 s lease on their target
(`editor` or the run id) for the calling client and renew it on every mutation. `bridge.lease {action: get|acquire|renew|release|steal, target, ttl_ms}`.
Leases die with the connection. `bridge.history` lists the last 200 mutations with the author's client name.

## Node references and values

A node ref is a path relative to the scene root (`"Player/Mesh"`), an absolute path (`"/root/Main/Player"`), `"."`, or
`{"id": "<instance id>"}`. Every node in a response carries `id`, `name`, `class`, `path`, `script`, `groups`.

Variant codec (`core/codec.gd`): JSON scalars/arrays/objects pass through; everything else is tagged
`{"$t": "Vector3", "v": [x,y,z]}`, `{"$t":"Color","v":[r,g,b,a],"html":"#rrggbbaa"}`, `{"$t":"Transform3D","basis":[[..],[..],[..]],"origin":[..]}`,
`{"$t":"Node","id":"...","path":"...","class":"..."}`, `{"$t":"Resource","path":"res://..."}`, packed arrays, non-string-key dictionaries.
Inputs are decoded with the destination property's type as a hint: `[1,2,3]` -> Vector3, `"Vector3(1,2,3)"` -> Vector3, `"#ff0000"` -> Color.

## Methods

Shared (editor and runtime): `bridge.lease`, `bridge.methods`, `api.search`, `api.class`, `api.script`, `scene.tree`,
`scene.inspect`, `scene.find`, `scene.cameras`, `scene.patch`, `scene.call`, `capture.observe`, `exec.gdscript`, `logs.get`,
`logs.clear`, `spatial.query`.

Editor only: `bridge.hello`, `bridge.status`, `bridge.history`, `fs.list|read|rescan|reimport|dependencies`,
`scene.list_open|open|save|reload|new|close|selection|history`, `project.settings`, `project.input_map`, `validate.scripts`,
`run.start|stop|list`.

Runtime only: `bridge.hello`, `bridge.status`, `run.pause`, `run.step`, `run.time_scale`, `run.quit`, `run.change_scene`,
`input.send`, `input.release_all`, `metrics.get`.

`scene.patch.operations[]`: `set_property {ref, property, value, expected_old?}`, `create_node {parent, class_name, name?, properties?, script?}`,
`instantiate_scene {parent, scene_path, name?}`, `remove_node {ref}`, `rename_node {ref, name}`, `reparent_node {ref, parent, index?, keep_global_transform?}`,
`attach_script {ref, script_path|null}`, `connect_signal {ref, signal, target, method, flags?, binds?}`, `disconnect_signal {...}`,
`add_to_group {ref, group}`, `remove_from_group {ref, group}`. In the editor the whole batch is one `EditorUndoRedoManager` action.

`capture.observe {mode, camera?, viewport?, width?, height?, tree?}` returns `{image: {mime, base64, width, height}, meta: {mode, guarantee, limitations[], camera_transform, projection, process_frame, physics_frame, consistency}, tree?}`.

`run.step {count, clock: process|physics, events?[], capture?}` returns requested vs `observed_process_frames` / `observed_physics_frames` and a `guarantee` string.
