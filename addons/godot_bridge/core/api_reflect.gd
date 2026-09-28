extends RefCounted
## Ground truth for the API of the exact engine build that is running (ClassDB + Script reflection).

const Codec := preload("res://addons/godot_bridge/core/codec.gd")


static func version() -> Dictionary:
	var v := Engine.get_version_info()
	return {"string": v["string"], "major": v["major"], "minor": v["minor"], "patch": v["patch"], "status": v["status"], "hash": v["hash"]}


static func search(query: String, limit: int = 50) -> Array:
	var out := []
	for c in ClassDB.get_class_list():
		if query == "" or String(c).findn(query) != -1:
			out.append(String(c))
			if out.size() >= limit:
				break
	return out


static func _fmt_method(m: Dictionary) -> Dictionary:
	var args := []
	var defaults: Array = m.get("default_args", [])
	var nargs: int = m.get("args", []).size()
	var i := 0
	for a in m.get("args", []):
		var ad := {"name": a["name"], "type": _type_name(a)}
		var di := i - (nargs - defaults.size())
		if di >= 0:
			ad["default"] = Codec.encode(defaults[di])
		args.append(ad)
		i += 1
	var ret: Dictionary = m.get("return", {})
	var d := {"name": m["name"], "args": args, "returns": _type_name(ret) if not ret.is_empty() else "void"}
	var flags: int = m.get("flags", 0)
	if flags & METHOD_FLAG_STATIC:
		d["static"] = true
	if flags & METHOD_FLAG_VIRTUAL:
		d["virtual"] = true
	if flags & METHOD_FLAG_CONST:
		d["const"] = true
	return d


static func _type_name(p: Dictionary) -> String:
	var t: int = p.get("type", TYPE_NIL)
	if t == TYPE_OBJECT and p.get("class_name", "") != "":
		return String(p["class_name"])
	if t == TYPE_NIL:
		return "Variant" if (p.get("usage", 0) & PROPERTY_USAGE_NIL_IS_VARIANT) else "void"
	if t == TYPE_ARRAY and p.get("hint", 0) == PROPERTY_HINT_ARRAY_TYPE:
		return "Array[%s]" % p.get("hint_string", "")
	if p.get("class_name", "") != "":
		return String(p["class_name"])
	return type_string(t)


## sections: any of methods, properties, signals, constants, enums. inherited=false lists only members declared by the class.
static func klass(cname: String, sections: Array = ["methods", "properties", "signals", "constants", "enums"], inherited: bool = false, member_filter: String = "") -> Dictionary:
	if not ClassDB.class_exists(cname):
		return {"$error": {"code": "NOT_FOUND", "message": "Class '%s' not registered in ClassDB (GDScript class_name classes: use api.script)" % cname}}
	var d := {"class": cname, "parent": String(ClassDB.get_parent_class(cname)), "engine_version": version()["string"], "source": "ClassDB", "instantiable": ClassDB.can_instantiate(cname)}
	var chain := []
	var p := cname
	while p != "":
		chain.append(p)
		p = String(ClassDB.get_parent_class(p))
	d["inheritance"] = chain
	var no_inherit := not inherited
	if sections.has("methods"):
		var ms := []
		for m in ClassDB.class_get_method_list(cname, no_inherit):
			if member_filter == "" or String(m["name"]).findn(member_filter) != -1:
				ms.append(_fmt_method(m))
		d["methods"] = ms
	if sections.has("properties"):
		var ps := []
		for pr in ClassDB.class_get_property_list(cname, no_inherit):
			if pr["usage"] & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
				continue
			if member_filter != "" and String(pr["name"]).findn(member_filter) == -1:
				continue
			var pd := {"name": pr["name"], "type": _type_name(pr), "hint": pr.get("hint_string", "")}
			if ClassDB.can_instantiate(cname):
				pd["default"] = Codec.encode(ClassDB.class_get_property_default_value(cname, pr["name"]))
			ps.append(pd)
		d["properties"] = ps
	if sections.has("signals"):
		var ss := []
		for s in ClassDB.class_get_signal_list(cname, no_inherit):
			if member_filter == "" or String(s["name"]).findn(member_filter) != -1:
				ss.append(_fmt_method(s))
		d["signals"] = ss
	if sections.has("constants"):
		var cs := {}
		for c in ClassDB.class_get_integer_constant_list(cname, no_inherit):
			if member_filter == "" or String(c).findn(member_filter) != -1:
				cs[String(c)] = ClassDB.class_get_integer_constant(cname, c)
		d["constants"] = cs
	if sections.has("enums"):
		var es := {}
		for e in ClassDB.class_get_enum_list(cname, no_inherit):
			var vals := {}
			for c in ClassDB.class_get_enum_constants(cname, e, no_inherit):
				vals[String(c)] = ClassDB.class_get_integer_constant(cname, c)
			es[String(e)] = vals
		d["enums"] = es
	return d


## Reflection of a project script (GDScript/C#): members declared by the script itself.
static func script_info(path: String) -> Dictionary:
	if not ResourceLoader.exists(path):
		return {"$error": {"code": "NOT_FOUND", "message": "No script at " + path}}
	var s = ResourceLoader.load(path)
	if not (s is Script):
		return {"$error": {"code": "INVALID", "message": path + " is not a Script"}}
	var sc: Script = s
	var d := {"path": path, "class_name": String(sc.get_global_name()), "base": String(sc.get_instance_base_type()), "tool": sc.is_tool(), "abstract": sc.is_abstract() if sc.has_method("is_abstract") else false, "source": "Script reflection"}
	var base_script := sc.get_base_script()
	if base_script != null:
		d["base_script"] = base_script.resource_path
	var ms := []
	for m in sc.get_script_method_list():
		ms.append(_fmt_method(m))
	d["methods"] = ms
	var ps := []
	for pr in sc.get_script_property_list():
		if pr["usage"] & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
			continue
		var pd := {"name": pr["name"], "type": _type_name(pr), "hint": pr.get("hint_string", ""), "exported": bool(pr["usage"] & PROPERTY_USAGE_EDITOR)}
		var def = sc.get_property_default_value(pr["name"])
		if def != null:
			pd["default"] = Codec.encode(def)
		ps.append(pd)
	d["properties"] = ps
	var ss := []
	for sg in sc.get_script_signal_list():
		ss.append(_fmt_method(sg))
	d["signals"] = ss
	d["constants"] = Codec.encode(sc.get_script_constant_map())
	if sc is GDScript:
		d["source_length"] = sc.source_code.length()
	return d
