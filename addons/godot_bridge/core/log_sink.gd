extends RefCounted
## Captures engine output (prints, push_error, script errors) into a thread-safe ring buffer.
## Uses OS.add_logger(Logger) on Godot 4.5+. Logger callbacks may run on any thread, so the
## sink only touches a mutex-protected array; readers run on the main thread.

const MAX_ENTRIES := 3000

var available: bool = false
var _mutex := Mutex.new()
var _entries: Array = []
var _seq: int = 0
var _logger: Object = null
var _install_error: String = ""

const LOGGER_SOURCE := """
extends Logger

var sink

func _log_message(message: String, error: bool) -> void:
	if sink != null:
		sink.push({"kind": "message", "level": "error" if error else "info", "text": message.strip_edges(false, true)})

func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	if sink == null:
		return
	var level := "error"
	if error_type == 1:
		level = "warning"
	elif error_type == 2:
		level = "script_error"
	elif error_type == 3:
		level = "shader_error"
	var traces := []
	for bt in script_backtraces:
		traces.append(bt.format(0) if bt.has_method("format") else str(bt))
	var text := code if rationale == "" else (rationale if code == "" else code + ": " + rationale)
	sink.push({"kind": "error", "level": level, "text": text, "function": function, "file": file, "line": line, "code": code, "rationale": rationale, "backtraces": traces})
"""


func install() -> void:
	if not ClassDB.class_exists("Logger"):
		_install_error = "Logger class not available (needs Godot 4.5+); logs.get will be empty"
		return
	var script := GDScript.new()
	script.source_code = LOGGER_SOURCE
	var err := script.reload()
	if err != OK:
		_install_error = "Logger subclass failed to compile (error %d)" % err
		return
	_logger = script.new()
	_logger.sink = self
	OS.add_logger(_logger)
	available = true


func uninstall() -> void:
	if _logger != null:
		OS.remove_logger(_logger)
		_logger = null
	available = false


func status() -> Dictionary:
	return {"available": available, "error": _install_error, "entries": _entries.size(), "last_seq": _seq}


func push(entry: Dictionary) -> void:
	_mutex.lock()
	_seq += 1
	entry["seq"] = _seq
	entry["t_msec"] = Time.get_ticks_msec()
	_entries.append(entry)
	if _entries.size() > MAX_ENTRIES:
		_entries = _entries.slice(_entries.size() - MAX_ENTRIES)
	_mutex.unlock()


## Returns entries with seq > after, filtered. levels: subset of info/warning/error/script_error/shader_error.
func query(after: int = 0, levels: Array = [], text_filter: String = "", limit: int = 200) -> Dictionary:
	_mutex.lock()
	var snapshot := _entries.duplicate()
	var last := _seq
	_mutex.unlock()
	var out := []
	var dropped := 0
	if not snapshot.is_empty() and after > 0 and snapshot[0]["seq"] > after + 1:
		dropped = snapshot[0]["seq"] - after - 1
	for e in snapshot:
		if e["seq"] <= after:
			continue
		if not levels.is_empty() and not levels.has(e["level"]):
			continue
		if text_filter != "":
			var hay: String = str(e.get("text", "")) + " " + str(e.get("rationale", "")) + " " + str(e.get("code", ""))
			if hay.findn(text_filter) == -1:
				continue
		out.append(e)
		if out.size() >= limit:
			break
	return {"entries": out, "last_seq": last, "dropped_before_cursor": dropped, "truncated": out.size() >= limit, "capture": status()}


func clear() -> void:
	_mutex.lock()
	_entries.clear()
	_mutex.unlock()
