@tool
extends EditorPlugin
## Godot Bridge hub. Runs a loopback WebSocket JSON-RPC server inside the editor.
## Agents (Claude Code / Codex CLI via the MCP adapter) and running game instances connect here.
## Requests with params.target == "game" | "<run_id>" are forwarded to that game instance.

const WsServer := preload("res://addons/godot_bridge/core/ws_server.gd")
const Dispatcher := preload("res://addons/godot_bridge/core/dispatcher.gd")
const LogSink := preload("res://addons/godot_bridge/core/log_sink.gd")
const EditorHandlers := preload("res://addons/godot_bridge/editor/editor_handlers.gd")

const SETTING_PORT := "godot_bridge/editor_port"
const SETTING_EXEC := "godot_bridge/allow_exec"
const SETTING_RUNTIME := "godot_bridge/runtime_enabled"
const DISCOVERY_FILE := "res://.godot/godot_bridge.json"
const AUTOLOAD_NAME := "GodotBridgeRuntime"
const AUTOLOAD_PATH := "res://addons/godot_bridge/runtime/bridge_runtime.gd"

var port: int = 0
var token: String = ""
var runs: Dictionary = {} # client_id -> {run_id, pid, scene, connected_at}
var _server: RefCounted
var _dispatcher: RefCounted
var _log_sink: RefCounted
var _handlers: RefCounted
var _forward: Dictionary = {} # fwd_id -> {client_id, id}
var _next_fwd: int = 1
var _panel: VBoxContainer
var _status_label: Label
var _log: RichTextLabel


func _enter_tree() -> void:
	_ensure_settings()
	_log_sink = LogSink.new()
	_log_sink.install()
	_server = WsServer.new()
	_dispatcher = Dispatcher.new(_send)
	_dispatcher.role = "editor"
	_handlers = EditorHandlers.new()
	_handlers.plugin = self
	_handlers.dispatcher = _dispatcher
	_handlers.log_sink = _log_sink
	_handlers.host_node = self
	_handlers.is_editor = true
	_handlers.exec_enabled = bool(ProjectSettings.get_setting(SETTING_EXEC, false))
	_handlers.register_editor()
	_server.client_connected.connect(_on_client_connected)
	_server.client_disconnected.connect(_on_client_disconnected)
	_server.message_received.connect(_on_message)
	if bool(ProjectSettings.get_setting(SETTING_RUNTIME, true)):
		if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
			add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_build_panel()
	_start()
	set_process(true)


func _exit_tree() -> void:
	_stop()
	if _log_sink != null:
		_log_sink.uninstall()
	if _panel != null:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()


func _ensure_settings() -> void:
	_ensure_setting(SETTING_PORT, 6505, TYPE_INT, "Preferred loopback port for the bridge hub (falls back to the next free port)")
	_ensure_setting(SETTING_EXEC, false, TYPE_BOOL, "Allow exec.gdscript (arbitrary GDScript from agents; no sandbox, no timeout). Off by default.")
	_ensure_setting(SETTING_RUNTIME, true, TYPE_BOOL, "Register the GodotBridgeRuntime autoload so F5 runs connect to the hub")


func _ensure_setting(name: String, default: Variant, type: int, doc: String) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	ProjectSettings.set_initial_value(name, default)
	ProjectSettings.add_property_info({"name": name, "type": type, "hint": PROPERTY_HINT_NONE, "hint_string": doc})
	ProjectSettings.set_as_basic(name, true)


func _start() -> void:
	var preferred := int(ProjectSettings.get_setting(SETTING_PORT, 6505))
	port = _server.listen(preferred)
	if port == 0:
		push_error("[GodotBridge] could not bind any port from %d" % preferred)
		_set_status("ERROR: no free port")
		return
	token = Crypto.new().generate_random_bytes(16).hex_encode()
	_dispatcher.token = token
	_write_discovery()
	_set_status("listening on ws://127.0.0.1:%d" % port)
	log_line("hub started on port %d (token in %s)" % [port, DISCOVERY_FILE])


func _stop() -> void:
	if _server != null:
		_server.stop()
	var abs := ProjectSettings.globalize_path(DISCOVERY_FILE)
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)
	runs.clear()
	port = 0


func _write_discovery() -> void:
	var d := {
		"protocol": Dispatcher.PROTOCOL_VERSION,
		"url": "ws://127.0.0.1:%d" % port,
		"port": port,
		"token": token,
		"pid": OS.get_process_id(),
		"godot": Engine.get_version_info()["string"],
		"project": ProjectSettings.get_setting("application/config/name", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
		"started_at": Time.get_datetime_string_from_system(true),
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot"))
	var f := FileAccess.open(DISCOVERY_FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d, "  "))


func _process(_delta: float) -> void:
	if _server != null and _server.is_listening():
		_server.poll()
	_reap_runs()


func _send(client_id: int, text: String) -> void:
	_server.send(client_id, text)


func _on_client_connected(client_id: int) -> void:
	_dispatcher.on_client_connected(client_id)
	_refresh_status()


func _on_client_disconnected(client_id: int) -> void:
	var c: Dictionary = _dispatcher.clients.get(client_id, {})
	if runs.has(client_id):
		log_line("game run %s disconnected" % runs[client_id]["run_id"])
		runs.erase(client_id)
	elif not c.is_empty():
		log_line("client '%s' disconnected" % c["name"])
	_dispatcher.on_client_disconnected(client_id)
	_refresh_status()


func _on_message(client_id: int, text: String) -> void:
	# Responses coming back from a game instance for a forwarded request.
	if runs.has(client_id):
		var json := JSON.new()
		if json.parse(text) == OK and typeof(json.data) == TYPE_DICTIONARY and not json.data.has("method"):
			var msg: Dictionary = json.data
			var fwd: Dictionary = _forward.get(msg.get("id"), {})
			if not fwd.is_empty():
				_forward.erase(msg["id"])
				msg["id"] = fwd["id"]
				_server.send(fwd["client_id"], JSON.stringify(msg))
				return
	# Forward agent requests that target a game instance.
	var target := _target_of(text)
	if target != "" and target != "editor":
		_forward_to_run(client_id, text, target)
		return
	_dispatcher.handle_text(client_id, text)
	if text.find("bridge.hello") != -1:
		_refresh_status.call_deferred()


func _target_of(text: String) -> String:
	var i := text.find("\"target\"")
	if i == -1:
		return ""
	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return ""
	var params = json.data.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		return ""
	return str(params.get("target", ""))


func _forward_to_run(client_id: int, text: String, target: String) -> void:
	var c: Dictionary = _dispatcher.clients.get(client_id, {})
	var json := JSON.new()
	json.parse(text)
	var msg: Dictionary = json.data
	if not c.get("authed", false) and _dispatcher.token != "":
		_server.send(client_id, JSON.stringify({"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32001, "message": "UNAUTHORIZED: call bridge.hello first"}}))
		return
	var run_client := -1
	var matches := 0
	for id in runs.keys():
		if target == "game" or target == "runtime" or runs[id]["run_id"] == target:
			run_client = id
			matches += 1
	if matches > 1:
		_server.send(client_id, JSON.stringify({"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32000, "message": "AMBIGUOUS: %d game instances are connected; pass target=<run_id> (see runs)." % matches, "data": {"code": "AMBIGUOUS", "runs": runs_summary()}}}))
		return
	if run_client == -1:
		_server.send(client_id, JSON.stringify({"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32000, "message": "NO_RUN: no game instance connected (target=%s). Use run.start, then target 'game'." % target, "data": {"code": "NO_RUN", "runs": runs_summary()}}}))
		return
	var method := str(msg.get("method", ""))
	if _dispatcher._mutating.has(method) or method.begins_with("run.") or method.begins_with("input.") or method == "exec.gdscript":
		var lease: Dictionary = _dispatcher.check_lease(client_id, runs[run_client]["run_id"])
		if lease.has("$error"):
			_server.send(client_id, JSON.stringify({"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32000, "message": lease["$error"]["message"], "data": lease["$error"]}}))
			return
	var fwd_id := "f%d" % _next_fwd
	_next_fwd += 1
	_forward[fwd_id] = {"client_id": client_id, "id": msg.get("id")}
	msg["id"] = fwd_id
	msg["params"] = msg.get("params", {})
	msg["params"]["client_name"] = c.get("name", "?")
	_server.send(run_client, JSON.stringify(msg))


func register_run(client_id: int, hello: Dictionary) -> void:
	runs[client_id] = {"run_id": str(hello.get("run_id", "run-%d" % client_id)), "pid": int(hello.get("pid", 0)), "scene": str(hello.get("scene", "")), "connected_at": Time.get_ticks_msec(), "client_id": client_id}
	_dispatcher.clients[client_id]["role"] = "runtime"
	log_line("game run %s connected (pid %d, scene %s)" % [runs[client_id]["run_id"], runs[client_id]["pid"], runs[client_id]["scene"]])
	_refresh_status()


func runs_summary() -> Array:
	var out := []
	for id in runs.keys():
		out.append(runs[id])
	out.sort_custom(func(a, b): return a["connected_at"] < b["connected_at"])
	return out


func _reap_runs() -> void:
	# Drop runs whose socket is gone (server already removed them) - handled by disconnect signal.
	pass


## ---- panel ------------------------------------------------------------------------------------

func _build_panel() -> void:
	_panel = VBoxContainer.new()
	_panel.name = "Bridge"
	_panel.custom_minimum_size = Vector2(0, 120)
	var top := HBoxContainer.new()
	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_status_label)
	var restart := Button.new()
	restart.text = "Restart hub"
	restart.pressed.connect(func(): _stop(); _start(); _refresh_status())
	top.add_child(restart)
	var copy := Button.new()
	copy.text = "Copy MCP config"
	copy.pressed.connect(func(): DisplayServer.clipboard_set(JSON.stringify({"mcpServers": {"godot": {"command": "npx", "args": ["-y", "godot-bridge-mcp", "mcp", "--project", ProjectSettings.globalize_path("res://")]}}}, "  ")))
	top.add_child(copy)
	_panel.add_child(top)
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_log.selection_enabled = true
	_panel.add_child(_log)
	add_control_to_bottom_panel(_panel, "Bridge")


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = "Godot Bridge: " + text


func _refresh_status() -> void:
	if port == 0:
		return
	var agents := 0
	for c in _dispatcher.clients.values():
		if c["role"] != "runtime":
			agents += 1
	var names := []
	for c in _dispatcher.clients.values():
		if c["role"] != "runtime":
			names.append(c["name"])
	_set_status("ws://127.0.0.1:%d | agents: %d %s | game runs: %d" % [port, agents, ("(" + ", ".join(names) + ")") if not names.is_empty() else "", runs.size()])


func log_line(text: String) -> void:
	if _log != null:
		_log.append_text("[%s] %s\n" % [Time.get_time_string_from_system(), text])
	print("[GodotBridge] " + text)
