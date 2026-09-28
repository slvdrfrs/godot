extends Node
## GodotBridgeRuntime autoload.
##
## When the game is launched FROM THE EDITOR (F5/F6: editor build + the editor's launch markers) it connects to the
## editor hub (url/token from .godot/godot_bridge.json) so agents can inspect and drive the live game.
## In every other process (exported builds, `godot --path ... --headless`, `--script` runs, tests) this node
## does nothing: no scripts loaded, no processing, no output. The only way to enable it outside the editor
## is the custom feature tag "godot_bridge" in an export preset; command-line flags and environment
## variables cannot switch it on.
##
## Env vars only apply once enabled:
##   GODOT_BRIDGE_HUB / GODOT_BRIDGE_TOKEN  override the hub url/token
##   GODOT_BRIDGE_LISTEN=<port>            also listen on 127.0.0.1:<port> (no editor needed); the token is
##                                         GODOT_BRIDGE_TOKEN or a random one written to user://godot_bridge_runtime.json

const RUNTIME_DISCOVERY := "user://godot_bridge_runtime.json"
const MAX_HUB_RETRIES := 5

var run_id: String = ""
var enabled: bool = false
var _hub_url: String = ""
var _token: String = ""
var _peer: WebSocketPeer
var _peer_state: int = WebSocketPeer.STATE_CLOSED
var _retry_at_msec: int = 0
var _retries: int = 0
var _server: RefCounted
var _dispatcher: RefCounted
var _log_sink: RefCounted
var _handlers: RefCounted
var _max_buffer: int = 64 * 1024 * 1024
const HUB_CLIENT_ID := 0


func _ready() -> void:
	set_process(false)
	if Engine.is_editor_hint():
		return
	if not (_launched_from_editor() or OS.has_feature("godot_bridge")):
		return # inert: exported builds, `godot --path ...` test runs, --script, etc.
	_enable()


## True only for a game the editor itself launched (F5/F6): editor build, not the editor process, and the
## editor's own launch markers (remote debugger session or --editor-pid). `godot --headless --path proj`
## from a terminal has none of these, even with the editor binary.
static func _launched_from_editor() -> bool:
	if not OS.has_feature("editor") or Engine.is_editor_hint():
		return false
	if EngineDebugger.is_active():
		return true
	return OS.get_cmdline_args().has("--editor-pid")


func _enable() -> void:
	# Lazy loads so the rest of the addon can be excluded from exports (only this file must ship).
	var WsServer = load("res://addons/godot_bridge/core/ws_server.gd")
	var Dispatcher = load("res://addons/godot_bridge/core/dispatcher.gd")
	var LogSink = load("res://addons/godot_bridge/core/log_sink.gd")
	var RuntimeHandlers = load("res://addons/godot_bridge/runtime/runtime_handlers.gd")
	if WsServer == null or Dispatcher == null or LogSink == null or RuntimeHandlers == null:
		return # addon files not present in this build
	enabled = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	run_id = "run-%d" % OS.get_process_id()
	_max_buffer = WsServer.MAX_BUFFER
	_log_sink = LogSink.new()
	_log_sink.install()
	_dispatcher = Dispatcher.new(_send)
	_dispatcher.role = "runtime"
	_handlers = RuntimeHandlers.new()
	_handlers.dispatcher = _dispatcher
	_handlers.log_sink = _log_sink
	_handlers.host_node = self
	_handlers.is_editor = false
	_handlers.exec_enabled = bool(ProjectSettings.get_setting("godot_bridge/allow_exec", false))
	_handlers.register_runtime()
	_discover()
	var listen_port := OS.get_environment("GODOT_BRIDGE_LISTEN")
	if listen_port.is_valid_int():
		var listen_token := OS.get_environment("GODOT_BRIDGE_TOKEN")
		if listen_token == "":
			listen_token = Crypto.new().generate_random_bytes(16).hex_encode()
		_server = WsServer.new()
		var p: int = _server.listen(int(listen_port))
		if p > 0:
			_server.client_connected.connect(_dispatcher.on_client_connected)
			_server.client_disconnected.connect(_dispatcher.on_client_disconnected)
			_server.message_received.connect(func(id, text): _dispatcher.handle_text(id, text))
			_dispatcher.token = listen_token
			var f := FileAccess.open(RUNTIME_DISCOVERY, FileAccess.WRITE)
			if f != null:
				f.store_string(JSON.stringify({"protocol": Dispatcher.PROTOCOL_VERSION, "url": "ws://127.0.0.1:%d" % p, "port": p, "token": listen_token, "pid": OS.get_process_id(), "run_id": run_id}, "  "))
			print("[GodotBridge runtime] listening on ws://127.0.0.1:%d (token in %s)" % [p, ProjectSettings.globalize_path(RUNTIME_DISCOVERY)])
		else:
			_server = null
	if _hub_url == "" and _server == null:
		enabled = false
		_log_sink.uninstall()
		_log_sink = null
		_dispatcher = null
		_handlers = null
		return # nothing to talk to
	set_process(true)


func _discover() -> void:
	_hub_url = OS.get_environment("GODOT_BRIDGE_HUB")
	_token = OS.get_environment("GODOT_BRIDGE_TOKEN")
	if _hub_url == "":
		var path := "res://.godot/godot_bridge.json"
		if FileAccess.file_exists(path):
			var f := FileAccess.open(path, FileAccess.READ)
			var json := JSON.new()
			if json.parse(f.get_as_text()) == OK and typeof(json.data) == TYPE_DICTIONARY:
				_hub_url = str(json.data.get("url", ""))
				_token = str(json.data.get("token", ""))
	if _hub_url != "" and _token == "":
		_hub_url = "" # never talk to a hub without a token


func _process(_delta: float) -> void:
	if _server != null:
		_server.poll()
	if _hub_url == "":
		return
	if _peer == null:
		if _retries >= MAX_HUB_RETRIES:
			_hub_url = ""
			if _server == null:
				set_process(false) # give up silently: no hub, nothing to do
			return
		if Time.get_ticks_msec() < _retry_at_msec:
			return
		_peer = WebSocketPeer.new()
		_peer.inbound_buffer_size = _max_buffer
		_peer.outbound_buffer_size = _max_buffer
		_peer.max_queued_packets = 4096
		_retries += 1
		if _peer.connect_to_url(_hub_url) != OK:
			_peer = null
			_retry_at_msec = Time.get_ticks_msec() + 2000
			return
	_peer.poll()
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if _peer_state != WebSocketPeer.STATE_OPEN:
			_peer_state = state
			_retries = 0
			_dispatcher.on_client_connected(HUB_CLIENT_ID)
			_dispatcher.clients[HUB_CLIENT_ID]["authed"] = true
			_dispatcher.clients[HUB_CLIENT_ID]["name"] = "editor-hub"
			var scene := get_tree().current_scene.scene_file_path if get_tree().current_scene else ""
			_peer.send_text(JSON.stringify({"jsonrpc": "2.0", "id": "hello", "method": "bridge.hello", "params": {"client": run_id, "role": "runtime", "token": _token, "run_id": run_id, "pid": OS.get_process_id(), "scene": scene}}))
			print("[GodotBridge runtime] connected to hub %s as %s" % [_hub_url, run_id])
		while _peer.get_available_packet_count() > 0:
			var pkt := _peer.get_packet()
			if _peer.was_string_packet():
				var text := pkt.get_string_from_utf8()
				if text.find("\"method\"") != -1:
					_dispatcher.handle_text(HUB_CLIENT_ID, text)
	elif state == WebSocketPeer.STATE_CLOSED:
		if _peer_state == WebSocketPeer.STATE_OPEN:
			_dispatcher.on_client_disconnected(HUB_CLIENT_ID)
		_peer_state = state
		_peer = null
		_retry_at_msec = Time.get_ticks_msec() + 2000


func _send(client_id: int, text: String) -> void:
	if client_id == HUB_CLIENT_ID:
		if _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_peer.send_text(text)
	elif _server != null:
		_server.send(client_id, text)


func _exit_tree() -> void:
	if _log_sink != null:
		_log_sink.uninstall()
	if _peer != null:
		_peer.close()
	if _server != null:
		_server.stop()
		var abs := ProjectSettings.globalize_path(RUNTIME_DISCOVERY)
		if FileAccess.file_exists(abs):
			DirAccess.remove_absolute(abs)
