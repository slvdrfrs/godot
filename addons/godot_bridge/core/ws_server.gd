extends RefCounted
## Minimal loopback WebSocket server built on TCPServer + WebSocketPeer.accept_stream().
## Polled from the main thread; never touches the scene tree itself.

signal client_connected(client_id: int)
signal client_disconnected(client_id: int)
signal message_received(client_id: int, text: String)

const MAX_BUFFER := 64 * 1024 * 1024 # PNG captures can be several MB.

var port: int = 0
var _tcp := TCPServer.new()
var _clients: Dictionary = {} # client_id -> WebSocketPeer
var _handshaking: Dictionary = {} # client_id -> true until OPEN
var _next_id: int = 1


func listen(preferred_port: int, attempts: int = 25) -> int:
	for i in attempts:
		var p := preferred_port + i
		if _tcp.listen(p, "127.0.0.1") == OK:
			port = p
			return p
	port = 0
	return 0


func is_listening() -> bool:
	return _tcp.is_listening()


func stop() -> void:
	for ws in _clients.values():
		ws.close()
	_clients.clear()
	_handshaking.clear()
	_tcp.stop()
	port = 0


func client_count() -> int:
	return _clients.size()


func poll() -> void:
	while _tcp.is_connection_available():
		var stream := _tcp.take_connection()
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = MAX_BUFFER
		ws.outbound_buffer_size = MAX_BUFFER
		ws.max_queued_packets = 4096
		if ws.accept_stream(stream) == OK:
			var id := _next_id
			_next_id += 1
			_clients[id] = ws
			_handshaking[id] = true
	for id in _clients.keys():
		var ws: WebSocketPeer = _clients[id]
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			if _handshaking.has(id):
				_handshaking.erase(id)
				client_connected.emit(id)
			while ws.get_available_packet_count() > 0:
				var pkt := ws.get_packet()
				if ws.was_string_packet():
					message_received.emit(id, pkt.get_string_from_utf8())
		elif state == WebSocketPeer.STATE_CLOSED:
			_clients.erase(id)
			var was_open := not _handshaking.has(id)
			_handshaking.erase(id)
			if was_open:
				client_disconnected.emit(id)


func send(client_id: int, text: String) -> bool:
	var ws: WebSocketPeer = _clients.get(client_id)
	if ws == null or ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return ws.send_text(text) == OK


func close_client(client_id: int) -> void:
	var ws: WebSocketPeer = _clients.get(client_id)
	if ws != null:
		ws.close()
