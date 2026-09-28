extends RefCounted
## Structured "seeing": scene tree, node inspection, search, cameras. Shared by editor and runtime.

const Codec := preload("res://addons/godot_bridge/core/codec.gd")

const SKIP_USAGE := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP


## Resolve a node reference: absolute path, path relative to `root`, "." for root, or a handle dict {"id": ...}.
static func resolve(ref: Variant, root: Node) -> Node:
	if ref == null:
		return root
	if typeof(ref) == TYPE_DICTIONARY:
		if ref.has("id"):
			var obj := instance_from_id(int(ref["id"]))
			if obj is Node and is_instance_valid(obj):
				return obj
		if ref.has("path"):
			return resolve(String(ref["path"]), root)
		return null
	var s := String(ref)
	if s == "" or s == ".":
		return root
	if s.is_valid_int():
		var obj := instance_from_id(int(s))
		return obj if obj is Node else null
	if root == null:
		return null
	if s.begins_with("/"):
		var tree := root.get_tree()
		if tree != null:
			return tree.root.get_node_or_null(s)
		return null
	return root.get_node_or_null(s)


static func summary(n: Node, root: Node, props: Array = []) -> Dictionary:
	var d := {
		"id": str(n.get_instance_id()),
		"name": String(n.name),
		"class": n.get_class(),
		"path": String(root.get_path_to(n)) if root != null and n.is_inside_tree() and root.is_inside_tree() else String(n.name),
		"children": n.get_child_count(),
	}
	if n.is_inside_tree():
		var abs := String(n.get_path())
		if abs.find("@EditorNode@") == -1:
			d["abs_path"] = abs
	var script := n.get_script()
	if script != null:
		d["script"] = script.resource_path
		if script is Script and script.get_global_name() != &"":
			d["script_class"] = String(script.get_global_name())
	if n.scene_file_path != "":
		d["scene"] = n.scene_file_path
	var groups := []
	for g in n.get_groups():
		if not String(g).begins_with("_"):
			groups.append(String(g))
	if not groups.is_empty():
		d["groups"] = groups
	if (n is CanvasItem or n is Node3D) and not n.visible:
		d["visible"] = false
	if n.process_mode != Node.PROCESS_MODE_INHERIT:
		d["process_mode"] = n.process_mode
	for p in props:
		if p in n:
			d[p] = Codec.encode(n.get(p))
	return d


## Depth-limited tree. filters: {class_name, name_contains, group, script} mark matches.
## exclude_classes: nodes of these classes (is_class) are omitted from the output, along with their subtrees, but counted.
## Returns {root, count, truncated, total_nodes, class_counts, excluded}.
static func tree(root: Node, depth: int = 3, props: Array = [], filters: Dictionary = {}, max_nodes: int = 150, exclude_classes: Array = []) -> Dictionary:
	if root == null:
		return {"root": null, "count": 0}
	var state := {"count": 0, "truncated": false, "excluded": 0, "exclude": exclude_classes}
	var out := _tree_rec(root, root, depth, props, filters, max_nodes, state)
	var counts := {}
	var total := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		total += 1
		counts[n.get_class()] = counts.get(n.get_class(), 0) + 1
		for c in n.get_children():
			stack.append(c)
	var result := {"root": out, "count": state["count"], "truncated": state["truncated"], "total_nodes": total, "class_counts": counts, "excluded": state["excluded"]}
	if state["truncated"]:
		result["hint"] = "output capped at max_nodes; narrow with root, depth, exclude_classes (see class_counts) or scene.find"
	return result


static func _excluded(n: Node, state: Dictionary) -> bool:
	for c in state["exclude"]:
		if n.is_class(c):
			return true
	return false


static func _matches(n: Node, filters: Dictionary) -> bool:
	if filters.is_empty():
		return true
	if filters.has("class_name") and not n.is_class(filters["class_name"]):
		return false
	if filters.has("name_contains") and String(n.name).findn(filters["name_contains"]) == -1:
		return false
	if filters.has("group") and not n.is_in_group(filters["group"]):
		return false
	if filters.has("script"):
		var s := n.get_script()
		if s == null or (s.resource_path != filters["script"] and String(s.get_global_name()) != filters["script"]):
			return false
	return true


static func _tree_rec(n: Node, root: Node, depth: int, props: Array, filters: Dictionary, max_nodes: int, state: Dictionary) -> Variant:
	if state["count"] >= max_nodes:
		state["truncated"] = true
		return null
	var d := summary(n, root, props)
	state["count"] += 1
	if not filters.is_empty():
		d["matches"] = _matches(n, filters)
	if depth > 0 and n.get_child_count() > 0:
		var kids := []
		var excluded_here := 0
		for c in n.get_children():
			if _excluded(c, state):
				excluded_here += 1
				state["excluded"] += 1
				continue
			var cd = _tree_rec(c, root, depth - 1, props, filters, max_nodes, state)
			if cd != null:
				kids.append(cd)
		d["children_nodes"] = kids
		if excluded_here > 0:
			d["children_excluded"] = excluded_here
	elif n.get_child_count() > 0:
		d["children_omitted"] = true
	return d


## Flatten filter matches (used by scene.find).
static func find(root: Node, filters: Dictionary, limit: int = 100) -> Array:
	var out := []
	var stack: Array = [root]
	while not stack.is_empty() and out.size() < limit:
		var n: Node = stack.pop_front()
		if _matches(n, filters) and (n != root or filters.is_empty()):
			out.append(summary(n, root))
		for c in n.get_children():
			stack.append(c)
	return out


static func _property_default(n: Node, pname: StringName) -> Variant:
	var script := n.get_script()
	if script is Script:
		var sc: Script = script
		if sc.get_property_default_value(pname) != null:
			return sc.get_property_default_value(pname)
	if ClassDB.class_exists(n.get_class()):
		return ClassDB.class_get_property_default_value(n.get_class(), pname)
	return null


## Inspect one node. opts: {properties: [names] | null, changed_only: bool, methods: bool, signals: bool, connections: bool, all_usage: bool}
static func inspect(n: Node, root: Node, opts: Dictionary = {}) -> Dictionary:
	var d := summary(n, root)
	var wanted: Variant = opts.get("properties", null)
	var changed_only: bool = opts.get("changed_only", true)
	var all_usage: bool = opts.get("all_usage", false)
	var props := {}
	var meta := {}
	for p in n.get_property_list():
		var pname: String = p["name"]
		var usage: int = p["usage"]
		if usage & SKIP_USAGE:
			continue
		if wanted != null:
			if not (wanted as Array).has(pname):
				continue
		elif not all_usage and not (usage & (PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_SCRIPT_VARIABLE)):
			continue
		var value = n.get(pname)
		if changed_only and wanted == null:
			var def = _property_default(n, pname)
			if def != null and def == value:
				continue
		props[pname] = Codec.encode(value)
		meta[pname] = {"type": type_string(p["type"]), "class": p.get("class_name", ""), "hint": p.get("hint_string", ""), "usage": usage}
	d["properties"] = props
	if opts.get("meta", false):
		d["property_meta"] = meta
	if n is Node3D and n.is_inside_tree():
		d["global_transform"] = Codec.encode(n.global_transform)
	if n is Node2D and n.is_inside_tree():
		d["global_position"] = Codec.encode(n.global_position)
	if n is Control:
		d["global_rect"] = Codec.encode(n.get_global_rect())
	if opts.get("methods", false):
		var methods := []
		var script := n.get_script()
		var only_script: bool = opts.get("script_methods_only", true) and script != null
		var list: Array = script.get_script_method_list() if only_script and script is Script else n.get_method_list()
		for m in list:
			methods.append(_method_sig(m))
		d["methods"] = methods
	if opts.get("signals", true):
		var sigs := []
		var script := n.get_script()
		var list: Array = script.get_script_signal_list() if (script is Script and opts.get("script_signals_only", true)) else n.get_signal_list()
		for s in list:
			sigs.append(_method_sig(s))
		d["signals"] = sigs
	if opts.get("connections", true):
		var conns := []
		for s in n.get_signal_list():
			for c in n.get_signal_connection_list(s["name"]):
				var cal: Callable = c["callable"]
				conns.append({
					"signal": String(s["name"]),
					"target": Codec.encode(cal.get_object()),
					"method": String(cal.get_method()),
					"flags": c["flags"],
					"persistent": bool(c["flags"] & Object.CONNECT_PERSIST),
				})
		d["outgoing_connections"] = conns
	return d


static func _method_sig(m: Dictionary) -> Dictionary:
	var args := []
	for a in m.get("args", []):
		args.append({"name": a["name"], "type": type_string(a["type"]) if a["type"] != TYPE_NIL else "Variant", "class": a.get("class_name", "")})
	var ret: Dictionary = m.get("return", {})
	var returns := ""
	if not ret.is_empty():
		var rt: int = ret.get("type", TYPE_NIL)
		if rt != TYPE_NIL:
			returns = String(ret.get("class_name", "")) if ret.get("class_name", "") != "" else type_string(rt)
		else:
			returns = "Variant" if (ret.get("usage", 0) & PROPERTY_USAGE_NIL_IS_VARIANT) else "void"
	return {"name": m["name"], "args": args, "returns": returns, "flags": m.get("flags", 0)}


static func cameras(root: Node) -> Array:
	var out := []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		if n is Camera3D:
			var c := n as Camera3D
			out.append({"node": summary(c, root), "kind": "3d", "current": c.current, "fov": c.fov, "size": c.size, "near": c.near, "far": c.far, "projection": c.projection, "global_transform": Codec.encode(c.global_transform) if c.is_inside_tree() else null, "viewport": Codec.encode(c.get_viewport()), "modes": ["camera_preview", "camera_takeover"]})
		elif n is Camera2D:
			var c := n as Camera2D
			out.append({"node": summary(c, root), "kind": "2d", "current": c.is_current(), "enabled": c.enabled, "zoom": Codec.encode(c.zoom), "screen_center": Codec.encode(c.get_screen_center_position()) if c.is_inside_tree() else null, "viewport": Codec.encode(c.get_viewport()), "modes": ["camera_preview", "camera_takeover"]})
		for ch in n.get_children():
			stack.append(ch)
	return out
