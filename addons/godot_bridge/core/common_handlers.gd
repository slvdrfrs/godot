extends RefCounted
## Methods shared by the editor hub and the game runtime. Subclasses supply root()/host() and register extras.

const Codec := preload("res://addons/godot_bridge/core/codec.gd")
const Inspector := preload("res://addons/godot_bridge/core/inspector.gd")
const ApiReflect := preload("res://addons/godot_bridge/core/api_reflect.gd")
const Capture := preload("res://addons/godot_bridge/core/capture.gd")
const Exec := preload("res://addons/godot_bridge/core/exec.gd")
const Dispatcher := preload("res://addons/godot_bridge/core/dispatcher.gd")

var dispatcher: RefCounted
var log_sink: RefCounted
var host_node: Node
var is_editor: bool = false
var exec_enabled: bool = true


func root() -> Node:
	return null


func err(code: String, message: String, data: Variant = null) -> Dictionary:
	return Dispatcher.err(code, message, data)


func register_common() -> void:
	dispatcher.register("bridge.lease", dispatcher.lease_action)
	dispatcher.register("bridge.methods", func(_p, _c): return {"methods": dispatcher.methods()})
	dispatcher.register("api.search", api_search)
	dispatcher.register("api.class", api_class)
	dispatcher.register("api.script", api_script)
	dispatcher.register("scene.tree", scene_tree)
	dispatcher.register("scene.inspect", scene_inspect)
	dispatcher.register("scene.find", scene_find)
	dispatcher.register("scene.cameras", scene_cameras)
	dispatcher.register("scene.patch", scene_patch, true)
	dispatcher.register("scene.call", scene_call, true)
	dispatcher.register("capture.observe", capture_observe)
	dispatcher.register("exec.gdscript", exec_gdscript, true)
	dispatcher.register("logs.get", logs_get)
	dispatcher.register("logs.clear", func(_p, _c): log_sink.clear(); return {"ok": true})
	dispatcher.register("spatial.query", spatial_query)


func node_or_error(ref: Variant) -> Variant:
	var n := Inspector.resolve(ref, root())
	if n == null:
		return err("NOT_FOUND", "Node not found: %s" % JSON.stringify(ref), {"hint": "Use scene.tree or scene.find; refs accept a path relative to the scene root, an absolute /root/... path or {\"id\": \"<instance id>\"}"})
	return n


func api_search(p: Dictionary, _c: Dictionary) -> Variant:
	return {"classes": ApiReflect.search(str(p.get("query", "")), int(p.get("limit", 50))), "engine_version": ApiReflect.version()}


func api_class(p: Dictionary, _c: Dictionary) -> Variant:
	var sections: Array = p.get("sections", ["methods", "properties", "signals", "constants", "enums"])
	return ApiReflect.klass(str(p.get("class_name", "")), sections, bool(p.get("inherited", false)), str(p.get("member", "")))


func api_script(p: Dictionary, _c: Dictionary) -> Variant:
	return ApiReflect.script_info(str(p.get("path", "")))


func scene_tree(p: Dictionary, _c: Dictionary) -> Variant:
	var r := root()
	if r == null:
		return err("NO_SCENE", "No scene root available" + (" (no scene open in the editor)" if is_editor else ""))
	var start: Node = r
	if p.has("root"):
		var n = node_or_error(p["root"])
		if typeof(n) == TYPE_DICTIONARY:
			return n
		start = n
	var t := Inspector.tree(start, int(p.get("depth", 3)), p.get("props", []), p.get("filters", {}), int(p.get("max_nodes", 150)), p.get("exclude_classes", []))
	t["scene_root"] = Codec.encode(r)
	return t


func scene_inspect(p: Dictionary, _c: Dictionary) -> Variant:
	var refs: Array = p.get("refs", [p.get("ref", ".")])
	var out := []
	for ref in refs:
		var n = node_or_error(ref)
		if typeof(n) == TYPE_DICTIONARY:
			out.append({"ref": ref, "error": n["$error"]})
		else:
			out.append(Inspector.inspect(n, root(), p))
	return {"nodes": out}


func scene_find(p: Dictionary, _c: Dictionary) -> Variant:
	var r := root()
	if r == null:
		return err("NO_SCENE", "No scene root available")
	var start: Node = r
	if p.has("root"):
		var n = node_or_error(p["root"])
		if typeof(n) == TYPE_DICTIONARY:
			return n
		start = n
	var filters := {}
	for k in ["class_name", "name_contains", "group", "script"]:
		if p.has(k):
			filters[k] = p[k]
	return {"nodes": Inspector.find(start, filters, int(p.get("limit", 100)))}


func scene_cameras(p: Dictionary, _c: Dictionary) -> Variant:
	var r := root()
	if r == null:
		return err("NO_SCENE", "No scene root available")
	return {"cameras": Inspector.cameras(r)}


func scene_call(p: Dictionary, _c: Dictionary) -> Variant:
	var n = node_or_error(p.get("ref"))
	if typeof(n) == TYPE_DICTIONARY:
		return n
	var method := str(p.get("method", ""))
	if not n.has_method(method):
		return err("NOT_FOUND", "Node %s has no method %s" % [n.name, method])
	var args := []
	for a in p.get("args", []):
		args.append(Codec.decode(a))
	var result = await n.callv(method, args)
	return {"result": Codec.encode(result), "node": Codec.encode(n)}


func exec_gdscript(p: Dictionary, _c: Dictionary) -> Variant:
	if not exec_enabled:
		return err("DISABLED", "exec.gdscript is disabled (default). Enable it per project: Project Settings > Godot Bridge > Allow Exec (godot_bridge/allow_exec = true), then restart the editor/game. It runs unsandboxed GDScript in-process.")
	var ctx := {"root": root(), "tree": host_node.get_tree(), "editor": is_editor, "host": host_node}
	return await Exec.run(str(p.get("source", "")), p.get("args", {}), ctx, int(p.get("soft_limit_ms", 2000)))


func logs_get(p: Dictionary, _c: Dictionary) -> Variant:
	return log_sink.query(int(p.get("after", 0)), p.get("levels", []), str(p.get("text", "")), int(p.get("limit", 200)))


## ---- patch -------------------------------------------------------------------------------------

## operations: array of {op: set_property|create_node|instantiate_scene|remove_node|rename_node|reparent_node|
##   attach_script|connect_signal|disconnect_signal|add_to_group|remove_from_group, ...}
## Editor subclass wraps it in an undoable action. Runtime applies directly.
func scene_patch(p: Dictionary, c: Dictionary) -> Variant:
	var r := root()
	if r == null:
		return err("NO_SCENE", "No scene root available")
	var ops: Array = p.get("operations", [])
	var dry := bool(p.get("dry_run", false))
	var plan := []
	for i in ops.size():
		var op: Dictionary = ops[i]
		var prepared = _prepare_op(op, r)
		if prepared.has("$error"):
			prepared["$error"]["data"] = {"operation_index": i, "operation": op}
			return prepared
		plan.append(prepared)
	if dry:
		var preview := []
		for pl in plan:
			var d: Dictionary = pl["describe"].call()
			d.erase("value")
			preview.append(d)
			if (pl["kind"] == "create_node" or pl["kind"] == "instantiate_scene") and is_instance_valid(pl["node"]):
				pl["node"].free() # created for validation only
		return {"dry_run": true, "valid": true, "operations": preview}
	return _apply_plan(plan, str(p.get("label", "Bridge patch by " + c["client_name"])), c)


func _apply_plan(plan: Array, _label: String, _c: Dictionary) -> Dictionary:
	var results := []
	for pl in plan:
		pl["do"].call()
		results.append(pl["describe"].call() if pl["describe"] is Callable else pl["describe"])
	return {"applied": results.size(), "operations": results, "undoable": false}


func _prepare_op(op: Dictionary, r: Node) -> Dictionary:
	var kind := str(op.get("op", ""))
	match kind:
		"set_property":
			var n = node_or_error(op.get("ref"))
			if typeof(n) == TYPE_DICTIONARY:
				return n
			var prop := str(op.get("property", ""))
			if not (prop in n):
				return err("NOT_FOUND", "Node %s has no property '%s'" % [n.name, prop], {"hint": "scene.inspect lists properties; api.class %s gives the full list" % n.get_class()})
			var current = n.get(prop)
			var value = Codec.decode(op.get("value"), typeof(current))
			if op.has("expected_old") and Codec.decode(op["expected_old"], typeof(current)) != current:
				return err("CONFLICT", "Precondition failed: %s.%s is %s, expected %s" % [n.name, prop, var_to_str(current), var_to_str(op["expected_old"])])
			return {"kind": kind, "node": n, "property": prop, "value": value, "old": current,
				"do": func(): n.set(prop, value),
				"describe": func(): return {"op": kind, "node": Codec.encode(n), "property": prop, "value": Codec.encode(n.get(prop)), "previous": Codec.encode(current)}}
		"create_node":
			var parent = node_or_error(op.get("parent", "."))
			if typeof(parent) == TYPE_DICTIONARY:
				return parent
			var cls := str(op.get("class_name", "Node"))
			var n: Node = null
			if ClassDB.class_exists(cls):
				if not ClassDB.can_instantiate(cls) or not ClassDB.is_parent_class(cls, "Node"):
					return err("INVALID", "%s is not an instantiable Node class" % cls)
				n = ClassDB.instantiate(cls)
			else:
				var script = _find_script_class(cls)
				if script == null:
					return err("NOT_FOUND", "Unknown class %s (not in ClassDB nor a project class_name)" % cls)
				n = script.new()
			n.name = str(op.get("name", cls))
			var props: Dictionary = op.get("properties", {})
			for k in props.keys():
				if k in n:
					n.set(k, Codec.decode(props[k], typeof(n.get(k))))
			if op.has("script"):
				n.set_script(load(str(op["script"])))
			return {"kind": kind, "node": n, "parent": parent,
				"do": func(): _do_add(parent, n, r),
				"describe": func(): return {"op": kind, "node": Codec.encode(n), "parent": Codec.encode(parent)}}
		"instantiate_scene":
			var parent = node_or_error(op.get("parent", "."))
			if typeof(parent) == TYPE_DICTIONARY:
				return parent
			var path := str(op.get("scene_path", ""))
			if not ResourceLoader.exists(path):
				return err("NOT_FOUND", "Scene not found: " + path)
			var packed = load(path)
			if not (packed is PackedScene):
				return err("INVALID", path + " is not a PackedScene")
			var n: Node = packed.instantiate()
			if op.has("name"):
				n.name = str(op["name"])
			return {"kind": kind, "node": n, "parent": parent,
				"do": func(): _do_add_instance(parent, n, r),
				"describe": func(): return {"op": kind, "node": Codec.encode(n), "parent": Codec.encode(parent), "scene": path}}
		"remove_node":
			var n = node_or_error(op.get("ref"))
			if typeof(n) == TYPE_DICTIONARY:
				return n
			if n == r:
				return err("INVALID", "Cannot remove the scene root")
			var parent: Node = n.get_parent()
			var idx: int = n.get_index()
			return {"kind": kind, "node": n, "parent": parent, "index": idx,
				"do": func(): parent.remove_child(n),
				"describe": func(): return {"op": kind, "removed": Codec.encode(n), "parent": Codec.encode(parent), "index": idx}}
		"rename_node":
			var n = node_or_error(op.get("ref"))
			if typeof(n) == TYPE_DICTIONARY:
				return n
			var new_name := str(op.get("name", ""))
			var old := String(n.name)
			return {"kind": kind, "node": n, "property": "name", "value": new_name, "old": old,
				"do": func(): n.name = new_name,
				"describe": func(): return {"op": kind, "node": Codec.encode(n), "previous": old}}
		"reparent_node":
			var n = node_or_error(op.get("ref"))
			if typeof(n) == TYPE_DICTIONARY:
				return n
			var np = node_or_error(op.get("parent"))
			if typeof(np) == TYPE_DICTIONARY:
				return np
			if n == r or np == n or n.is_ancestor_of(np):
				return err("INVALID", "Invalid reparent (root, self or own descendant)")
			var keep := bool(op.get("keep_global_transform", true))
			var old_parent: Node = n.get_parent()
			var old_idx: int = n.get_index()
			return {"kind": kind, "node": n, "parent": np, "old_parent": old_parent, "index": old_idx, "keep": keep,
				"do": func(): _do_reparent(n, np, keep, r, int(op.get("index", -1))),
				"describe": func(): return {"op": kind, "node": Codec.encode(n), "parent": Codec.encode(np)}}
		"attach_script":
			var n = node_or_error(op.get("ref"))
			if typeof(n) == TYPE_DICTIONARY:
				return n
			var path = op.get("script_path")
			var script: Variant = null
			if path != null and str(path) != "":
				if not ResourceLoader.exists(str(path)):
					return err("NOT_FOUND", "Script not found: " + str(path))
				script = load(str(path))
			var old = n.get_script()
			return {"kind": kind, "node": n, "property": "script", "value": script, "old": old,
				"do": func(): n.set_script(script),
				"describe": func(): return {"op": kind, "node": Codec.encode(n), "script": path}}
		"connect_signal", "disconnect_signal":
			var src = node_or_error(op.get("ref", op.get("source")))
			if typeof(src) == TYPE_DICTIONARY:
				return src
			var tgt = node_or_error(op.get("target"))
			if typeof(tgt) == TYPE_DICTIONARY:
				return tgt
			var sig := str(op.get("signal", ""))
			var method := str(op.get("method", ""))
			if not src.has_signal(sig):
				return err("NOT_FOUND", "%s has no signal %s" % [src.name, sig])
			var flags := int(op.get("flags", Object.CONNECT_PERSIST if is_editor else 0))
			var binds := []
			for b in op.get("binds", []):
				binds.append(Codec.decode(b))
			var cal := Callable(tgt, method)
			if not binds.is_empty():
				cal = cal.bindv(binds)
			var connecting := kind == "connect_signal"
			return {"kind": kind, "node": src, "signal": sig, "callable": cal, "flags": flags, "connecting": connecting,
				"do": func(): _do_signal(src, sig, cal, flags, connecting),
				"describe": func(): return {"op": kind, "source": Codec.encode(src), "signal": sig, "target": Codec.encode(tgt), "method": method, "connected": src.is_connected(sig, cal)}}
		"add_to_group", "remove_from_group":
			var n = node_or_error(op.get("ref"))
			if typeof(n) == TYPE_DICTIONARY:
				return n
			var g := str(op.get("group", ""))
			var adding := kind == "add_to_group"
			return {"kind": kind, "node": n, "group": g, "adding": adding,
				"do": func(): _do_group(n, g, adding),
				"describe": func(): return {"op": kind, "node": Codec.encode(n), "group": g, "in_group": n.is_in_group(g)}}
	return err("INVALID", "Unknown patch op '%s'" % kind, {"ops": ["set_property", "create_node", "instantiate_scene", "remove_node", "rename_node", "reparent_node", "attach_script", "connect_signal", "disconnect_signal", "add_to_group", "remove_from_group"]})


static func _do_add(parent: Node, n: Node, owner: Node) -> void:
	parent.add_child(n, true)
	_set_owner_rec(n, owner)


static func _do_add_instance(parent: Node, n: Node, owner: Node) -> void:
	parent.add_child(n, true)
	n.owner = owner


static func _do_reparent(n: Node, np: Node, keep: bool, owner: Node, index: int) -> void:
	n.reparent(np, keep)
	_set_owner_rec(n, owner)
	if index >= 0:
		np.move_child(n, index)


static func _do_signal(src: Object, sig: String, cal: Callable, flags: int, connecting: bool) -> void:
	if connecting:
		if not src.is_connected(sig, cal):
			src.connect(sig, cal, flags)
	elif src.is_connected(sig, cal):
		src.disconnect(sig, cal)


static func _do_group(n: Node, g: String, adding: bool) -> void:
	if adding:
		n.add_to_group(g, true)
	else:
		n.remove_from_group(g)


static func _set_owner_rec(n: Node, owner: Node) -> void:
	if n == owner:
		return
	n.owner = owner
	for c in n.get_children():
		if c.scene_file_path == "":
			_set_owner_rec(c, owner)
		else:
			c.owner = owner


static func _find_script_class(cls: String) -> Script:
	for entry in ProjectSettings.get_global_class_list():
		if String(entry["class"]) == cls:
			return load(entry["path"])
	return null


## ---- observe -----------------------------------------------------------------------------------

## p: {mode: viewport|camera_preview|camera_takeover, camera?: ref, viewport?: ref, width?, height?, tree?: {depth, props}}
func capture_observe(p: Dictionary, _c: Dictionary) -> Variant:
	var mode := str(p.get("mode", "camera_preview" if p.has("camera") else "viewport"))
	var size := Vector2i(int(p.get("width", 640)), int(p.get("height", 360)))
	var fmt := str(p.get("format", "jpeg"))
	var quality := clampf(float(p.get("quality", 0.7)), 0.05, 1.0)
	var result: Dictionary
	match mode:
		"viewport":
			var vp := default_viewport(p)
			if vp == null:
				return err("NOT_FOUND", "Viewport not found")
			result = await Capture.viewport(vp)
		"camera_preview", "camera_takeover":
			var cam = node_or_error(p.get("camera"))
			if typeof(cam) == TYPE_DICTIONARY:
				return cam
			if mode == "camera_takeover":
				result = await Capture.camera_takeover(cam)
			elif cam is Camera3D:
				result = await Capture.camera3d_preview(host_node, cam, size)
			elif cam is Camera2D:
				result = await Capture.camera2d_preview(host_node, cam, size)
			else:
				return err("INVALID", "%s is not a Camera2D/Camera3D" % cam.name)
		_:
			return err("INVALID", "Unknown mode " + mode)
	if result.has("$error"):
		return result
	if mode == "viewport" and (p.has("width") or p.has("height")):
		result = Capture.resize_result(result, size)
	result = Capture.encode_result(result, fmt, quality)
	if p.has("tree"):
		var tp: Dictionary = p["tree"]
		result["tree"] = Inspector.tree(root(), int(tp.get("depth", 3)), tp.get("props", []), tp.get("filters", {}), int(tp.get("max_nodes", 300)))
	result["meta"]["consistency"] = "image and tree taken in the same main-loop iteration after frame_post_draw; not a global atomic snapshot"
	return result


func default_viewport(_p: Dictionary) -> Viewport:
	return host_node.get_viewport()


## ---- spatial -----------------------------------------------------------------------------------

## op: raycast (camera + pixel [x,y] normalized 0..1 or px) | project (camera + world point) | unproject (camera + pixel) | bounds (ref)
func spatial_query(p: Dictionary, _c: Dictionary) -> Variant:
	var op := str(p.get("op", "bounds"))
	match op:
		"bounds":
			var n = node_or_error(p.get("ref"))
			if typeof(n) == TYPE_DICTIONARY:
				return n
			if n is VisualInstance3D:
				var aabb: AABB = n.get_aabb()
				return {"node": Codec.encode(n), "local_aabb": Codec.encode(aabb), "global_aabb": Codec.encode(n.global_transform * aabb), "source": "VisualInstance3D.get_aabb"}
			if n is Control:
				return {"node": Codec.encode(n), "global_rect": Codec.encode(n.get_global_rect()), "source": "Control.get_global_rect"}
			if n is Sprite2D:
				return {"node": Codec.encode(n), "global_rect": Codec.encode(n.get_global_transform() * n.get_rect()), "source": "Sprite2D.get_rect"}
			if n is Node3D:
				return {"node": Codec.encode(n), "global_position": Codec.encode(n.global_position), "source": "Node3D.global_position (no renderable bounds)"}
			if n is Node2D:
				return {"node": Codec.encode(n), "global_position": Codec.encode(n.global_position), "source": "Node2D.global_position (no renderable bounds)"}
			return err("UNSUPPORTED", "No bounds for " + n.get_class())
		"project", "unproject", "raycast":
			var cam = node_or_error(p.get("camera"))
			if typeof(cam) == TYPE_DICTIONARY:
				return cam
			if not (cam is Camera3D):
				return err("UNSUPPORTED", "spatial.query %s currently supports Camera3D only" % op)
			var c3 := cam as Camera3D
			if op == "project":
				var wp: Vector3 = Codec.decode(p.get("point"), TYPE_VECTOR3)
				return {"pixel": Codec.encode(c3.unproject_position(wp)), "behind": c3.is_position_behind(wp), "viewport_size": Codec.encode(c3.get_viewport().get_visible_rect().size)}
			var px: Vector2 = Codec.decode(p.get("pixel", [0.5, 0.5]), TYPE_VECTOR2)
			var vs := c3.get_viewport().get_visible_rect().size
			if px.x <= 1.0 and px.y <= 1.0:
				px = Vector2(px.x * vs.x, px.y * vs.y)
			var origin := c3.project_ray_origin(px)
			var dir := c3.project_ray_normal(px)
			if op == "unproject":
				return {"origin": Codec.encode(origin), "direction": Codec.encode(dir), "pixel": Codec.encode(px)}
			var length := float(p.get("length", 1000.0))
			var space := c3.get_world_3d().direct_space_state
			await host_node.get_tree().physics_frame
			var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * length, int(p.get("mask", 0xFFFFFFFF)))
			q.collide_with_areas = bool(p.get("areas", false))
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				return {"hit": false, "origin": Codec.encode(origin), "direction": Codec.encode(dir), "note": "physics raycast: only CollisionObject3D shapes are hit, not visual geometry"}
			return {"hit": true, "collider": Codec.encode(hit["collider"]), "position": Codec.encode(hit["position"]), "normal": Codec.encode(hit["normal"]), "shape": hit.get("shape", -1), "note": "physics raycast: only CollisionObject3D shapes are hit, not visual geometry"}
	return err("INVALID", "Unknown spatial op " + op)
