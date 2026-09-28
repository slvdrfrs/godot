extends RefCounted
## Hot-compile and run a GDScript snippet in-process. Powerful escape hatch, no sandbox:
## a runaway loop blocks the process, so it is gated by a project setting and off by default in exports.

const Codec := preload("res://addons/godot_bridge/core/codec.gd")


## `source` is the body of a function `run(ctx, args)`; or a full script if it starts with "extends".
## ctx = {"root": Node, "tree": SceneTree, "editor": bool}
static func run(source: String, args: Dictionary, ctx: Dictionary) -> Dictionary:
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
	return {"result": Codec.encode(result), "elapsed_usec": Time.get_ticks_usec() - t0}
