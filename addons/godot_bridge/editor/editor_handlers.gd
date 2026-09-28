extends "res://addons/godot_bridge/core/common_handlers.gd"
## Editor-only methods. `plugin` is the EditorPlugin (hub).

var plugin: EditorPlugin


func root() -> Node:
	return EditorInterface.get_edited_scene_root()


func register_editor() -> void:
	register_common()
	dispatcher.register("bridge.hello", bridge_hello)
	dispatcher.register("bridge.status", bridge_status)
	dispatcher.register("bridge.history", func(_p, _c): return {"mutations": dispatcher.history})
	dispatcher.register("fs.list", fs_list)
	dispatcher.register("fs.read", fs_read)
	dispatcher.register("fs.rescan", func(_p, _c): EditorInterface.get_resource_filesystem().scan(); return {"ok": true, "scanning": EditorInterface.get_resource_filesystem().is_scanning()})
	dispatcher.register("fs.reimport", fs_reimport, true)
	dispatcher.register("fs.dependencies", fs_dependencies)
	dispatcher.register("scene.list_open", scene_list_open)
	dispatcher.register("scene.open", scene_open, true)
	dispatcher.register("scene.save", scene_save, true)
	dispatcher.register("scene.reload", scene_reload, true)
	dispatcher.register("scene.new", scene_new, true)
	dispatcher.register("scene.close", scene_close, true)
	dispatcher.register("scene.selection", scene_selection, true)
	dispatcher.register("scene.history", scene_history, true)
	dispatcher.register("project.settings", project_settings, true)
	dispatcher.register("project.input_map", project_input_map)
	dispatcher.register("validate.scripts", validate_scripts)
	dispatcher.register("run.start", run_start, true)
	dispatcher.register("run.stop", run_stop, true)
	dispatcher.register("run.list", func(_p, _c): return {"runs": plugin.runs_summary(), "editor_playing": EditorInterface.is_playing_scene()})


func bridge_hello(p: Dictionary, c: Dictionary) -> Variant:
	if str(p.get("role", "")) == "runtime":
		plugin.register_run(c["client_id"], p)
	return {
		"role": "editor", "protocol": dispatcher.PROTOCOL_VERSION, "client_id": c["client_id"],
		"godot": ApiReflect.version(), "project": ProjectSettings.get_setting("application/config/name", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
		"renderer": {"method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")), "driver": RenderingServer.get_current_rendering_driver_name(), "adapter": RenderingServer.get_video_adapter_name(), "headless": DisplayServer.get_name() == "headless"},
		"capabilities": capabilities(),
		"methods": dispatcher.methods(),
	}


func capabilities() -> Dictionary:
	return {
		"rendering": DisplayServer.get_name() != "headless",
		"logger": log_sink.available,
		"exec": exec_enabled,
		"undo": true,
		"runtime_bridge": true,
	}


func bridge_status(_p: Dictionary, _c: Dictionary) -> Variant:
	var r := root()
	var open := []
	for s in EditorInterface.get_open_scenes():
		open.append(s)
	var clients := []
	for id in dispatcher.clients.keys():
		var c: Dictionary = dispatcher.clients[id]
		clients.append({"client_id": id, "name": c["name"], "role": c["role"], "requests": c["requests"], "run_id": c["run_id"]})
	return {
		"role": "editor",
		"godot": ApiReflect.version(),
		"project": ProjectSettings.get_setting("application/config/name", ""),
		"edited_scene": {"root": Codec.encode(r), "path": r.scene_file_path if r else "", "unsaved": _scene_is_dirty()} if r else null,
		"open_scenes": open,
		"playing": EditorInterface.is_playing_scene(),
		"playing_scene": EditorInterface.get_playing_scene(),
		"runs": plugin.runs_summary(),
		"clients": clients,
		"leases": dispatcher.lease_state()["leases"],
		"capabilities": capabilities(),
		"logs": log_sink.status(),
		"port": plugin.port,
		"selection": Codec.encode(EditorInterface.get_selection().get_selected_nodes()),
	}


func _scene_is_dirty() -> bool:
	var r := root()
	if r == null:
		return false
	var ur := plugin.get_undo_redo()
	var hid: int = ur.get_object_history_id(r)
	var h := ur.get_history_undo_redo(hid)
	return h.has_undo() if h != null else false


func fs_list(p: Dictionary, _c: Dictionary) -> Variant:
	var dir := str(p.get("dir", "res://"))
	var exts: Array = p.get("exts", [])
	var recursive := bool(p.get("recursive", true))
	var limit := int(p.get("limit", 500))
	var out := []
	var stack := [dir]
	while not stack.is_empty() and out.size() < limit:
		var d: String = stack.pop_front()
		var da := DirAccess.open(d)
		if da == null:
			return err("NOT_FOUND", "Cannot open " + d)
		da.include_hidden = false
		da.list_dir_begin()
		var name := da.get_next()
		while name != "" and out.size() < limit:
			var full := d.path_join(name)
			if da.current_is_dir():
				if name != ".godot" and name != ".git" and recursive:
					stack.append(full)
			else:
				if not name.ends_with(".import") and not name.ends_with(".uid") and (exts.is_empty() or exts.has(name.get_extension())):
					out.append(full)
			name = da.get_next()
		da.list_dir_end()
	return {"files": out, "truncated": out.size() >= limit}


func fs_read(p: Dictionary, _c: Dictionary) -> Variant:
	var path := str(p.get("path", ""))
	if not FileAccess.file_exists(path):
		return err("NOT_FOUND", "No file " + path)
	var f := FileAccess.open(path, FileAccess.READ)
	var text := f.get_as_text()
	var max_len := int(p.get("max_chars", 200_000))
	return {"path": path, "text": text.substr(0, max_len), "truncated": text.length() > max_len, "length": text.length()}


func fs_reimport(p: Dictionary, _c: Dictionary) -> Variant:
	var paths := PackedStringArray(p.get("paths", []))
	EditorInterface.get_resource_filesystem().reimport_files(paths)
	return {"ok": true, "paths": paths}


func fs_dependencies(p: Dictionary, _c: Dictionary) -> Variant:
	var path := str(p.get("path", ""))
	return {"path": path, "dependencies": Array(ResourceLoader.get_dependencies(path)), "uid": ResourceUID.id_to_text(ResourceLoader.get_resource_uid(path))}


func scene_list_open(_p: Dictionary, _c: Dictionary) -> Variant:
	var r := root()
	return {"open": Array(EditorInterface.get_open_scenes()), "edited": r.scene_file_path if r else ""}


func scene_open(p: Dictionary, _c: Dictionary) -> Variant:
	var path := str(p.get("path", ""))
	if not ResourceLoader.exists(path):
		return err("NOT_FOUND", "Scene not found: " + path)
	EditorInterface.open_scene_from_path(path)
	await plugin.get_tree().process_frame
	var r := root()
	return {"edited": Codec.encode(r), "path": r.scene_file_path if r else ""}


func scene_save(p: Dictionary, _c: Dictionary) -> Variant:
	var r := root()
	if r == null:
		return err("NO_SCENE", "No scene open")
	var e: int = OK
	if p.has("path"):
		EditorInterface.save_scene_as(str(p["path"]), bool(p.get("with_preview", false)))
	elif bool(p.get("all", false)):
		EditorInterface.save_all_scenes()
		e = OK
	else:
		e = EditorInterface.save_scene()
	if e != OK:
		return err("SAVE_FAILED", "save_scene returned error %d" % e)
	return {"ok": true, "path": root().scene_file_path}


func scene_reload(p: Dictionary, _c: Dictionary) -> Variant:
	var r := root()
	var path := str(p.get("path", r.scene_file_path if r else ""))
	if path == "":
		return err("INVALID", "No path")
	EditorInterface.reload_scene_from_path(path)
	await plugin.get_tree().process_frame
	return {"reloaded": path, "edited": Codec.encode(root())}


func scene_close(p: Dictionary, _c: Dictionary) -> Variant:
	var r := root()
	var path := str(p.get("path", r.scene_file_path if r else ""))
	if path == "":
		return err("INVALID", "No path")
	EditorInterface.close_scene()
	await plugin.get_tree().process_frame
	return {"closed": path, "edited": Codec.encode(root())}


func scene_new(p: Dictionary, _c: Dictionary) -> Variant:
	var cls := str(p.get("root_class", "Node"))
	if not ClassDB.class_exists(cls) or not ClassDB.is_parent_class(cls, "Node"):
		return err("INVALID", "root_class must be a Node class")
	var n: Node = ClassDB.instantiate(cls)
	n.name = str(p.get("name", cls))
	var packed := PackedScene.new()
	packed.pack(n)
	var path := str(p.get("path", ""))
	if path == "":
		return err("INVALID", "path required (res://...tscn)")
	var e := ResourceSaver.save(packed, path)
	n.free()
	if e != OK:
		return err("SAVE_FAILED", "ResourceSaver error %d" % e)
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)
	await plugin.get_tree().process_frame
	return {"path": path, "edited": Codec.encode(root())}


func scene_selection(p: Dictionary, _c: Dictionary) -> Variant:
	var sel := EditorInterface.get_selection()
	if str(p.get("action", "get")) == "set":
		sel.clear()
		for ref in p.get("refs", []):
			var n = node_or_error(ref)
			if typeof(n) == TYPE_DICTIONARY:
				return n
			sel.add_node(n)
		if bool(p.get("inspect", true)) and sel.get_selected_nodes().size() > 0:
			EditorInterface.edit_node(sel.get_selected_nodes()[0])
	return {"selected": Codec.encode(sel.get_selected_nodes())}


func scene_history(p: Dictionary, _c: Dictionary) -> Variant:
	var r := root()
	if r == null:
		return err("NO_SCENE", "No scene open")
	var ur := plugin.get_undo_redo()
	var h := ur.get_history_undo_redo(ur.get_object_history_id(r))
	match str(p.get("action", "get")):
		"undo":
			if not h.has_undo():
				return err("INVALID", "Nothing to undo")
			var name := h.get_current_action_name()
			h.undo()
			return {"undone": name, "has_undo": h.has_undo(), "has_redo": h.has_redo()}
		"redo":
			if not h.has_redo():
				return err("INVALID", "Nothing to redo")
			h.redo()
			return {"redone": h.get_current_action_name(), "has_undo": h.has_undo(), "has_redo": h.has_redo()}
	return {"current_action": h.get_current_action_name(), "has_undo": h.has_undo(), "has_redo": h.has_redo(), "version": h.get_version()}


## Undoable patch: every op registers its inverse on the editor's UndoRedo, labelled with the client name.
func _apply_plan(plan: Array, label: String, c: Dictionary) -> Dictionary:
	var r := root()
	var ur := plugin.get_undo_redo()
	ur.create_action(label, UndoRedo.MERGE_DISABLE, r)
	for pl in plan:
		var n: Node = pl["node"]
		match pl["kind"]:
			"set_property", "rename_node", "attach_script":
				ur.add_do_property(n, pl["property"], pl["value"])
				ur.add_undo_property(n, pl["property"], pl["old"])
			"create_node", "instantiate_scene":
				var parent: Node = pl["parent"]
				ur.add_do_method(parent, "add_child", n, true)
				ur.add_do_method(self, "_set_owner_rec" if pl["kind"] == "create_node" else "_set_owner_single", n, r)
				ur.add_do_reference(n)
				ur.add_undo_method(parent, "remove_child", n)
			"remove_node":
				var parent: Node = pl["parent"]
				var owners := _collect_owners(n)
				ur.add_do_method(parent, "remove_child", n)
				ur.add_undo_method(parent, "add_child", n, true)
				ur.add_undo_method(parent, "move_child", n, pl["index"])
				ur.add_undo_method(self, "_restore_owners", owners)
				ur.add_undo_reference(n)
			"reparent_node":
				ur.add_do_method(self, "_do_reparent", n, pl["parent"], pl["keep"], r, -1)
				ur.add_undo_method(self, "_do_reparent", n, pl["old_parent"], pl["keep"], r, pl["index"])
			"connect_signal", "disconnect_signal":
				ur.add_do_method(self, "_do_signal", n, pl["signal"], pl["callable"], pl["flags"], pl["connecting"])
				ur.add_undo_method(self, "_do_signal", n, pl["signal"], pl["callable"], pl["flags"], not pl["connecting"])
			"add_to_group", "remove_from_group":
				ur.add_do_method(self, "_do_group", n, pl["group"], pl["adding"])
				ur.add_undo_method(self, "_do_group", n, pl["group"], not pl["adding"])
	ur.commit_action()
	var results := []
	for pl in plan:
		results.append(pl["describe"].call())
	plugin.log_line("%s: %s (%d ops)" % [c["client_name"], label, plan.size()])
	return {"applied": results.size(), "operations": results, "undoable": true, "action": label}


static func _set_owner_single(n: Node, owner: Node) -> void:
	n.owner = owner


static func _collect_owners(n: Node) -> Array:
	var out := []
	var stack := [n]
	while not stack.is_empty():
		var x: Node = stack.pop_front()
		if x.owner != null:
			out.append([x, x.owner])
		for ch in x.get_children():
			stack.append(ch)
	return out


static func _restore_owners(pairs: Array) -> void:
	for pr in pairs:
		if is_instance_valid(pr[0]) and is_instance_valid(pr[1]):
			pr[0].owner = pr[1]


func project_settings(p: Dictionary, _c: Dictionary) -> Variant:
	match str(p.get("action", "get")):
		"get":
			var out := {}
			for k in p.get("keys", []):
				out[k] = Codec.encode(ProjectSettings.get_setting(k)) if ProjectSettings.has_setting(k) else null
			return {"settings": out}
		"set":
			var values: Dictionary = p.get("values", {})
			for k in values.keys():
				var cur = ProjectSettings.get_setting(k) if ProjectSettings.has_setting(k) else null
				ProjectSettings.set_setting(k, Codec.decode(values[k], typeof(cur) if cur != null else TYPE_NIL))
			var saved := OK
			if bool(p.get("persist", true)):
				saved = ProjectSettings.save()
			return {"ok": saved == OK, "changed": values.keys(), "note": "some settings need an editor restart"}
	return err("INVALID", "action must be get|set")


func project_input_map(_p: Dictionary, _c: Dictionary) -> Variant:
	var actions := {}
	for a in InputMap.get_actions():
		var evs := []
		for e in InputMap.action_get_events(a):
			evs.append(e.as_text())
		actions[String(a)] = {"events": evs, "deadzone": InputMap.action_get_deadzone(a)}
	return {"actions": actions}


## Compile scripts fresh and report errors captured by the logger in that window.
func validate_scripts(p: Dictionary, _c: Dictionary) -> Variant:
	var paths: Array = p.get("paths", [])
	if paths.is_empty():
		paths = fs_list({"exts": ["gd"]}, {})["files"]
	var results := []
	for path in paths:
		var before: int = log_sink.query(0, [], "", 1)["last_seq"]
		var res = ResourceLoader.load(path, "Script", ResourceLoader.CACHE_MODE_IGNORE)
		# can_instantiate() is false for non-@tool scripts inside the editor, so validity = loaded + resolved base type.
		var ok := res is Script and String((res as Script).get_instance_base_type()) != ""
		var errs: Array = log_sink.query(before, ["error", "script_error", "warning"], "", 50)["entries"]
		results.append({"path": path, "ok": ok and errs.is_empty(), "diagnostics": errs})
	return {"results": results, "logger_available": log_sink.available}


func run_start(p: Dictionary, _c: Dictionary) -> Variant:
	if EditorInterface.is_playing_scene():
		return err("BUSY", "A scene is already playing (%s); run.stop first" % EditorInterface.get_playing_scene())
	var scene := str(p.get("scene", "main"))
	match scene:
		"main":
			EditorInterface.play_main_scene()
		"current":
			EditorInterface.play_current_scene()
		_:
			var path := str(p.get("path", scene))
			if not ResourceLoader.exists(path):
				return err("NOT_FOUND", "Scene not found: " + path)
			EditorInterface.play_custom_scene(path)
	var wait_ms := int(p.get("wait_ms", 8000))
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < wait_ms:
		await plugin.get_tree().process_frame
		if not plugin.runs.is_empty():
			var latest: Dictionary = plugin.runs_summary()[-1]
			if latest["connected_at"] >= t0:
				return {"started": true, "run": latest, "playing_scene": EditorInterface.get_playing_scene()}
	return {"started": EditorInterface.is_playing_scene(), "run": null, "playing_scene": EditorInterface.get_playing_scene(), "warning": "game did not connect to the hub within wait_ms; is the GodotBridgeRuntime autoload enabled?"}


func run_stop(_p: Dictionary, _c: Dictionary) -> Variant:
	EditorInterface.stop_playing_scene()
	await plugin.get_tree().process_frame
	return {"playing": EditorInterface.is_playing_scene()}


func default_viewport(p: Dictionary) -> Viewport:
	match str(p.get("viewport", "3d")):
		"2d":
			return EditorInterface.get_editor_viewport_2d()
		"3d", "3d_0":
			return EditorInterface.get_editor_viewport_3d(0)
		"3d_1":
			return EditorInterface.get_editor_viewport_3d(1)
		"3d_2":
			return EditorInterface.get_editor_viewport_3d(2)
		"3d_3":
			return EditorInterface.get_editor_viewport_3d(3)
	return EditorInterface.get_editor_viewport_3d(0)
