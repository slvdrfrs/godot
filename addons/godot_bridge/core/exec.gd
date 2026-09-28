extends RefCounted
## Hot-compile and run a GDScript snippet in-process. Escape hatch with NO sandbox and NO preemption:
## GDScript cannot be interrupted from inside the same process, so a runaway loop freezes the editor/game.
## Gated by project setting godot_bridge/allow_exec (default false). Every response carries elapsed time
## and a `warning` when the call exceeded `soft_limit_ms` (default 2000).

const Codec := preload("res://addons/godot_bridge/core/codec.gd")


## `source` is the body of a function `run(ctx, args)`; or a full script if it starts with "extends".
## ctx = {"root": Node, "tree": SceneTree, "editor": bool}
static func run(source: String, args: Dictionary, ctx: Dictionary, soft_limit_ms: int = 2000) -> Dictionary:
	var script := GDScript.new()
	var full := source
	if not source.strip_edges().begins_with("extends") and not source.strip_edges().begins_with("@tool"):
		var body := ""
		for line in source.split("\n"):
			body += "\t" + line + "\n"
		full = "@tool\nextends RefCounted\nfunc run(ctx: Dictionary, args: Dictionary) -> Variant:\n" + body + "\treturn null\n"
	script.source_code = full
	var err := script.reload()
	if err != OK:
		return {"$error": {"code": "COMPILE_ERROR", "message": "GDScript failed to compile (error %d); check logs.get for the parser message" % err, "data": {"source": full}}}
	var inst = script.new()
	if inst == null:
		return {"$error": {"code": "INSTANTIATE_ERROR", "message": "Could not instantiate script"}}
	if not inst.has_method("run"):
		return {"$error": {"code": "INVALID", "message": "Script must define func run(ctx, args)"}}
	var t0 := Time.get_ticks_usec()
	var result = await inst.run(ctx, args)
	var elapsed := Time.get_ticks_usec() - t0
	var out := {"result": Codec.encode(result), "elapsed_usec": elapsed, "sandbox": "none"}
	if elapsed > soft_limit_ms * 1000:
		out["warning"] = "exec took %d ms (> soft limit %d ms). The process was blocked for that long; there is no way to preempt GDScript. Move long work to run.step/scene.call or shorten the snippet." % [elapsed / 1000, soft_limit_ms]
	return out
