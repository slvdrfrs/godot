extends "res://addons/godot_bridge/core/common_handlers.gd"
## Methods available inside the running game (F5). host_node is the GodotBridgeRuntime autoload.

var _pressed_actions: Dictionary = {}
var _pressed_keys: Dictionary = {}
var _pressed_buttons: Dictionary = {}
var _step_lock: bool = false


func root() -> Node:
	var tree := host_node.get_tree()
	return tree.current_scene if tree.current_scene != null else tree.root


func register_runtime() -> void:
	register_common()
	dispatcher.register("bridge.hello", bridge_hello)
	dispatcher.register("bridge.status", bridge_status)
	dispatcher.register("run.pause", run_pause, true)
	dispatcher.register("run.step", run_step, true)
	dispatcher.register("run.time_scale", run_time_scale, true)
	dispatcher.register("run.quit", func(_p, _c): host_node.get_tree().quit(); return {"ok": true}, true)
	dispatcher.register("run.change_scene", run_change_scene, true)
	dispatcher.register("input.send", input_send, true)
	dispatcher.register("input.release_all", input_release_all, true)
	dispatcher.register("metrics.get", metrics_get)


func bridge_hello(_p: Dictionary, _c: Dictionary) -> Variant:
	return {"role": "runtime", "protocol": dispatcher.PROTOCOL_VERSION, "godot": ApiReflect.version(), "run_id": host_node.run_id}


func bridge_status(_p: Dictionary, _c: Dictionary) -> Variant:
	var tree := host_node.get_tree()
	return {
		"role": "runtime",
		"run_id": host_node.run_id,
		"pid": OS.get_process_id(),
		"godot": ApiReflect.version(),
		"current_scene": Codec.encode(tree.current_scene),
		"paused": tree.paused,
		"time_scale": Engine.time_scale,
		"process_frame": Engine.get_process_frames(),
		"physics_frame": Engine.get_physics_frames(),
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"fps": Engine.get_frames_per_second(),
		"window_size": Codec.encode(tree.root.get_visible_rect().size),
		"headless": DisplayServer.get_name() == "headless",
		"node_count": tree.get_node_count(),
		"pressed_by_bridge": {"actions": _pressed_actions.keys(), "keys": _pressed_keys.keys(), "mouse_buttons": _pressed_buttons.keys()},
		"logs": log_sink.status(),
		"capabilities": {"rendering": DisplayServer.get_name() != "headless", "logger": log_sink.available, "exec": exec_enabled},
	}


func run_pause(p: Dictionary, _c: Dictionary) -> Variant:
	var tree := host_node.get_tree()
	tree.paused = bool(p.get("paused", true))
	return {"paused": tree.paused, "note": "SceneTree.paused: nodes with process_mode ALWAYS keep processing; this is not a global freeze"}


func run_time_scale(p: Dictionary, _c: Dictionary) -> Variant:
	Engine.time_scale = float(p.get("scale", 1.0))
	return {"time_scale": Engine.time_scale}


## Cooperative stepping: unpause, wait N process or physics frames, pause again; report what was observed.
func run_step(p: Dictionary, _c: Dictionary) -> Variant:
	if _step_lock:
		return err("BUSY", "A step is already in progress")
	_step_lock = true
	var tree := host_node.get_tree()
	var count := int(p.get("count", 1))
	var clock := str(p.get("clock", "process"))
	var p0 := Engine.get_process_frames()
	var f0 := Engine.get_physics_frames()
	var t0 := Time.get_ticks_usec()
	# Events passed here are delivered in the same iteration the tree is unpaused, so
	# is_action_just_pressed()/_input() see them on the first stepped frame (sending them while
	# paused and stepping later would make "just pressed" stale).
	var delivered := []
	for e in p.get("events", []):
		delivered.append(await _apply_input(e))
	tree.paused = false
	for i in count:
		if clock == "physics":
			await tree.physics_frame
		else:
			await tree.process_frame
	tree.paused = true
	_step_lock = false
	var result := {
		"requested": count, "clock": clock,
		"observed_process_frames": Engine.get_process_frames() - p0,
		"observed_physics_frames": Engine.get_physics_frames() - f0,
		"elapsed_usec": Time.get_ticks_usec() - t0,
		"paused": tree.paused,
		"events_delivered": delivered,
		"guarantee": "cooperative: the tree ran unpaused for the awaited frames; physics may tick 0..n times per process frame; nodes with process_mode ALWAYS also ran while paused",
	}
	if p.has("capture"):
		result["observation"] = await capture_observe(p["capture"], _c)
	return result


func run_change_scene(p: Dictionary, _c: Dictionary) -> Variant:
	var path := str(p.get("path", ""))
	if not ResourceLoader.exists(path):
		return err("NOT_FOUND", "Scene not found: " + path)
	var e := host_node.get_tree().change_scene_to_file(path)
	await host_node.get_tree().process_frame
	return {"ok": e == OK, "current_scene": Codec.encode(host_node.get_tree().current_scene)}


## events: [{type: action|key|mouse_button|mouse_motion, ...}] with optional hold_ms for a tap.
func input_send(p: Dictionary, _c: Dictionary) -> Variant:
	var applied := []
	for e in p.get("events", []):
		var r = await _apply_input(e)
		applied.append(r)
	var note := "events go through Input.parse_input_event (reach _input/_unhandled_input and action state)"
	if host_node.get_tree().paused:
		note += "; the tree is PAUSED: just_pressed semantics need the event and the frame together, use run.step with events instead"
	return {"applied": applied, "process_frame": Engine.get_process_frames(), "paused": host_node.get_tree().paused, "note": note}


func _apply_input(e: Dictionary) -> Dictionary:
	var type := str(e.get("type", "action"))
	var hold := int(e.get("hold_ms", 0))
	match type:
		"action":
			var action := StringName(str(e.get("action", "")))
			if not InputMap.has_action(action):
				return {"error": "unknown action %s" % action, "actions": Array(InputMap.get_actions())}
			var pressed := bool(e.get("pressed", true))
			var ev := InputEventAction.new()
			ev.action = action
			ev.pressed = pressed
			ev.strength = float(e.get("strength", 1.0))
			Input.parse_input_event(ev)
			if pressed:
				_pressed_actions[String(action)] = true
			else:
				_pressed_actions.erase(String(action))
			if hold > 0 and pressed:
				await host_node.get_tree().create_timer(hold / 1000.0, true, false, true).timeout
				var up := InputEventAction.new()
				up.action = action
				up.pressed = false
				Input.parse_input_event(up)
				_pressed_actions.erase(String(action))
			return {"type": type, "action": String(action), "pressed": pressed, "held_ms": hold}
		"key":
			var keyname := str(e.get("key", ""))
			var keycode := OS.find_keycode_from_string(keyname)
			if keycode == KEY_NONE:
				return {"error": "unknown key '%s' (use names like A, Space, Escape, Left)" % keyname}
			var pressed := bool(e.get("pressed", true))
			var ev := InputEventKey.new()
			ev.keycode = keycode
			ev.physical_keycode = keycode
			ev.unicode = keycode if keycode < 128 else 0
			ev.pressed = pressed
			ev.echo = false
			ev.shift_pressed = bool(e.get("shift", false))
			ev.ctrl_pressed = bool(e.get("ctrl", false))
			ev.alt_pressed = bool(e.get("alt", false))
			Input.parse_input_event(ev)
			if pressed:
				_pressed_keys[keyname] = true
			else:
				_pressed_keys.erase(keyname)
			if hold > 0 and pressed:
				await host_node.get_tree().create_timer(hold / 1000.0, true, false, true).timeout
				var up := ev.duplicate()
				up.pressed = false
				Input.parse_input_event(up)
				_pressed_keys.erase(keyname)
			return {"type": type, "key": keyname, "pressed": pressed, "held_ms": hold}
		"mouse_button":
			var pos: Vector2 = Codec.decode(e.get("position", [0, 0]), TYPE_VECTOR2)
			var button := int(e.get("button", MOUSE_BUTTON_LEFT))
			var pressed := bool(e.get("pressed", true))
			var ev := InputEventMouseButton.new()
			ev.position = pos
			ev.global_position = pos
			ev.button_index = button
			ev.pressed = pressed
			ev.double_click = bool(e.get("double_click", false))
			Input.parse_input_event(ev)
			if pressed:
				_pressed_buttons[str(button)] = true
			else:
				_pressed_buttons.erase(str(button))
			if hold > 0 and pressed:
				await host_node.get_tree().create_timer(hold / 1000.0, true, false, true).timeout
				var up := ev.duplicate()
				up.pressed = false
				Input.parse_input_event(up)
				_pressed_buttons.erase(str(button))
			return {"type": type, "button": button, "position": Codec.encode(pos), "pressed": pressed, "held_ms": hold}
		"mouse_motion":
			var pos: Vector2 = Codec.decode(e.get("position", [0, 0]), TYPE_VECTOR2)
			var ev := InputEventMouseMotion.new()
			ev.position = pos
			ev.global_position = pos
			ev.relative = Codec.decode(e.get("relative", [0, 0]), TYPE_VECTOR2)
			Input.warp_mouse(pos)
			Input.parse_input_event(ev)
			return {"type": type, "position": Codec.encode(pos)}
	return {"error": "unknown input type " + type, "types": ["action", "key", "mouse_button", "mouse_motion"]}


func input_release_all(_p: Dictionary, _c: Dictionary) -> Variant:
	var released := []
	for a in _pressed_actions.keys():
		var ev := InputEventAction.new()
		ev.action = a
		ev.pressed = false
		Input.parse_input_event(ev)
		released.append(a)
	for k in _pressed_keys.keys():
		var ev := InputEventKey.new()
		ev.keycode = OS.find_keycode_from_string(k)
		ev.physical_keycode = ev.keycode
		ev.pressed = false
		Input.parse_input_event(ev)
		released.append(k)
	for b in _pressed_buttons.keys():
		var ev := InputEventMouseButton.new()
		ev.button_index = int(b)
		ev.pressed = false
		Input.parse_input_event(ev)
		released.append("mouse_" + b)
	_pressed_actions.clear()
	_pressed_keys.clear()
	_pressed_buttons.clear()
	return {"released": released}


func metrics_get(p: Dictionary, _c: Dictionary) -> Variant:
	var wanted: Array = p.get("monitors", [])
	var out := {}
	for c in ClassDB.class_get_integer_constant_list("Performance"):
		var name := String(c)
		if name == "MONITOR_MAX":
			continue
		if not wanted.is_empty() and not wanted.has(name):
			continue
		var idx := ClassDB.class_get_integer_constant("Performance", c)
		out[name] = Performance.get_monitor(idx)
	var custom := {}
	for m in Performance.get_custom_monitor_names():
		custom[String(m)] = Performance.get_custom_monitor(m)
	return {"monitors": out, "custom": custom, "fps": Engine.get_frames_per_second(), "process_frame": Engine.get_process_frames(), "physics_frame": Engine.get_physics_frames(), "source": "Performance.get_monitor (engine counters; not a per-function profiler)"}


func default_viewport(_p: Dictionary) -> Viewport:
	return host_node.get_tree().root
