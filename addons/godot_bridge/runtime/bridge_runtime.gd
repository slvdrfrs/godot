extends Node
## GodotBridgeRuntime autoload. Inside a game launched from the editor it connects to the editor hub
## (read from .godot/godot_bridge.json) so agents can inspect and drive the live game.
## Inert in exported builds unless GODOT_BRIDGE=1 (env) or --godot-bridge (user arg) is set.
## With GODOT_BRIDGE_LISTEN=<port> it also listens on its own loopback port (no editor needed).

const WsServer := preload("res://addons/godot_bridge/core/ws_server.gd")
const Dispatcher := preload("res://addons/godot_bridge/core/dispatcher.gd")
const LogSink := preload("res://addons/godot_bridge/core/log_sink.gd")
const RuntimeHandlers := preload("res://addons/godot_bridge/runtime/runtime_handlers.gd")

var run_id: String = ""
var enabled: bool = false
var _hub_url: String = ""
var _token: String = ""
var _peer: WebSocketPeer
var _peer_state: int = WebSocketPeer.STATE_CLOSED
var _retry_at_msec: int = 0
var _server: RefCounted
var _dispatcher: RefCounted
var _log_sink: RefCounted
var _handlers: RefCounted
const HUB_CLIENT_ID := 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var forced := OS.get_environment("GODOT_BRIDGE") == "1" or OS.get_cmdline_user_args().has("--godot-bridge")
	var from_editor := OS.has_feature("editor_runtime") or (OS.has_feature("editor") and not Engine.is_editor_hint())
	if not (forced or from_editor):
		return
	enabled = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	run_id = "run-%d" % OS.get_process_id()
	_log_sink = LogSink.new()
	_log_sink.install()
	_dispatcher = Dispatcher.new(_send)
	_dispatcher.role = "runtime"
	_handlers = RuntimeHandlers.new()
	_handlers.dispatcher = _dispatcher
	_handlers.log_sink = _log_sink
	_handlers.host_node = self
	_handlers.is_editor = false
	_handlers.exec_enabled = bool(ProjectSettings.get_setting("godot_bridge/allow_exec", true))
	_handlers.register_runtime()
	_discover()
	var listen_port := OS.get_environment("GODOT_BRIDGE_LISTEN")
	if listen_port.is_valid_int():
		_server = WsServer.new()
		var p: int = _server.listen(int(listen_port))
		_server.client_connected.connect(_dispatcher.on_client_connected)
		_server.client_disconnected.connect(_dispatcher.on_client_disconnected)
		_server.message_received.connect(func(id, text): _dispatcher.handle_text(id, text))
		_dispatcher.token = _token
		print("[GodotBridge runtime] listening on ws://127.0.0.1:%d" % p)
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


func _process(_delta: float) -> void:
	if _server != null:
		_server.poll()
	if _hub_url == "":
		return
	if _peer == null:
		if Time.get_ticks_msec() < _retry_at_msec:
			return
		_peer = WebSocketPeer.new()
		_peer.inbound_buffer_size = WsServer.MAX_BUFFER
		_peer.outbound_buffer_size = WsServer.MAX_BUFFER
		_peer.max_queued_packets = 4096
		if _peer.connect_to_url(_hub_url) != OK:
			_peer = null
			_retry_at_msec = Time.get_ticks_msec() + 2000
			return
	_peer.poll()
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if _peer_state != WebSocketPeer.STATE_OPEN:
			_peer_state = state
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
