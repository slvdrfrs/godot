extends RefCounted
## JSON-RPC 2.0 dispatcher with client identity, authentication token and write leases.
## Handlers: Callable(params: Dictionary, ctx: Dictionary) -> Variant (may be a coroutine).
## A handler returns {"$error": {code, message, data?}} to signal an application error.

const PROTOCOL_VERSION := 1
const DEFAULT_LEASE_MS := 30_000

var token: String = ""
var role: String = "editor"
var clients: Dictionary = {} # client_id -> {name, role, authed, connected_at, requests, run_id}
var leases: Dictionary = {} # target -> {client_id, name, expires_msec}
var _handlers: Dictionary = {}
var _mutating: Dictionary = {}
var history: Array = [] # last mutations: {client, method, t_msec, summary}
var _send: Callable


func _init(send: Callable) -> void:
	_send = send


func register(method: String, handler: Callable, mutates: bool = false) -> void:
	_handlers[method] = handler
	if mutates:
		_mutating[method] = true


func methods() -> Array:
	var out := _handlers.keys()
	out.sort()
	return out


func on_client_connected(client_id: int) -> void:
	clients[client_id] = {"name": "anonymous", "role": "agent", "authed": false, "connected_at": Time.get_ticks_msec(), "requests": 0, "run_id": ""}


func on_client_disconnected(client_id: int) -> void:
	clients.erase(client_id)
	for t in leases.keys():
		if leases[t]["client_id"] == client_id:
			leases.erase(t)


static func err(code: String, message: String, data: Variant = null) -> Dictionary:
	var e := {"code": code, "message": message}
	if data != null:
		e["data"] = data
	return {"$error": e}


func _rpc_error(id: Variant, code: int, message: String, data: Variant = null) -> String:
	var e := {"code": code, "message": message}
	if data != null:
		e["data"] = data
	return JSON.stringify({"jsonrpc": "2.0", "id": id, "error": e})


## Lease policy: mutations on `target` need a lease. A free (or expired) lease is auto-acquired by the
## caller and renewed on every mutation, so single-agent use needs no ceremony. If another live client
## holds it, the mutation fails with CONFLICT naming the holder.
func check_lease(client_id: int, target: String) -> Dictionary:
	var now := Time.get_ticks_msec()
	var l: Dictionary = leases.get(target, {})
	if not l.is_empty() and l["client_id"] != client_id and l["expires_msec"] > now and clients.has(l["client_id"]):
		return err("CONFLICT", "Write lease for '%s' is held by client '%s' (%d ms left). Use bridge.lease release/steal or wait." % [target, l["name"], l["expires_msec"] - now], {"holder": l["name"], "expires_in_ms": l["expires_msec"] - now})
	leases[target] = {"client_id": client_id, "name": clients.get(client_id, {}).get("name", "?"), "expires_msec": now + DEFAULT_LEASE_MS}
	return {}


func lease_action(p: Dictionary, ctx: Dictionary) -> Variant:
	var target: String = str(p.get("target", "editor"))
	var action: String = str(p.get("action", "acquire"))
	var now := Time.get_ticks_msec()
	var l: Dictionary = leases.get(target, {})
	match action:
		"acquire", "renew":
			var r := check_lease(ctx["client_id"], target)
			if r.has("$error"):
				return r
			var ttl := int(p.get("ttl_ms", DEFAULT_LEASE_MS))
			leases[target]["expires_msec"] = now + ttl
		"release":
			if not l.is_empty() and l["client_id"] == ctx["client_id"]:
				leases.erase(target)
		"steal":
			leases[target] = {"client_id": ctx["client_id"], "name": ctx["client_name"], "expires_msec": now + int(p.get("ttl_ms", DEFAULT_LEASE_MS))}
		"get":
			pass
		_:
			return err("INVALID", "Unknown lease action " + action)
	return lease_state()


func lease_state() -> Dictionary:
	var now := Time.get_ticks_msec()
	var out := {}
	for t in leases.keys():
		var l: Dictionary = leases[t]
		out[t] = {"holder": l["name"], "client_id": l["client_id"], "expires_in_ms": max(0, l["expires_msec"] - now), "live": clients.has(l["client_id"])}
	return {"leases": out}


func handle_text(client_id: int, text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		_send.call(client_id, _rpc_error(null, -32700, "Parse error: " + json.get_error_message()))
		return
	var msg = json.data
	if typeof(msg) != TYPE_DICTIONARY or not msg.has("method"):
		_send.call(client_id, _rpc_error(msg.get("id") if typeof(msg) == TYPE_DICTIONARY else null, -32600, "Invalid request"))
		return
	var id = msg.get("id")
	var method: String = str(msg["method"])
	var params = msg.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}
	var c: Dictionary = clients.get(client_id, {})
	if c.is_empty():
		on_client_connected(client_id)
		c = clients[client_id]
	c["requests"] += 1
	if method == "bridge.hello":
		# An empty server token is a misconfiguration: refuse everyone rather than trust everyone.
		if token == "" or str(params.get("token", "")) != token:
			_send.call(client_id, _rpc_error(id, -32001, "UNAUTHORIZED: bad or missing token (read it from .godot/godot_bridge.json, or GODOT_BRIDGE_TOKEN / user://godot_bridge_runtime.json for a listening game)"))
			return
		c["authed"] = true
		c["name"] = str(params.get("client", "anonymous"))
		c["role"] = str(params.get("role", "agent"))
		c["run_id"] = str(params.get("run_id", ""))
	elif not c["authed"]:
		_send.call(client_id, _rpc_error(id, -32001, "UNAUTHORIZED: call bridge.hello with the token first"))
		return
	var handler: Callable = _handlers.get(method, Callable())
	if not handler.is_valid():
		_send.call(client_id, _rpc_error(id, -32601, "Method not found: " + method, {"methods": methods()}))
		return
	var ctx := {"client_id": client_id, "client_name": c["name"], "id": id}
	if _mutating.has(method):
		var target := str(params.get("target", "editor" if role == "editor" else "game"))
		var lease := check_lease(client_id, target)
		if lease.has("$error"):
			_send.call(client_id, _rpc_error(id, -32000, lease["$error"]["message"], lease["$error"]))
			return
		history.append({"client": c["name"], "method": method, "t_msec": Time.get_ticks_msec(), "params": _short(params)})
		if history.size() > 200:
			history.pop_front()
	var result = await handler.call(params, ctx)
	if id == null:
		return
	if typeof(result) == TYPE_DICTIONARY and result.has("$error"):
		var e: Dictionary = result["$error"]
		_send.call(client_id, _rpc_error(id, -32000, e["message"], e))
		return
	_send.call(client_id, JSON.stringify({"jsonrpc": "2.0", "id": id, "result": result}))


static func _short(p: Dictionary) -> String:
	var s := JSON.stringify(p)
	return s.substr(0, 200) + ("…" if s.length() > 200 else "")
