extends RefCounted
## Explicit Variant <-> JSON codec. Anything JSON cannot carry is tagged: {"$t": "<Type>", ...}.
## Object references become handles: {"$t": "Node", "id": "<instance_id as string>", "path": "...", "class": "..."}.

const MAX_DEPTH := 24


static func encode(v: Variant, depth: int = 0) -> Variant:
	if depth > MAX_DEPTH:
		return {"$t": "truncated"}
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return v
		TYPE_FLOAT:
			if is_nan(v):
				return {"$t": "float", "v": "nan"}
			if is_inf(v):
				return {"$t": "float", "v": "inf" if v > 0 else "-inf"}
			return v
		TYPE_STRING_NAME:
			return String(v)
		TYPE_NODE_PATH:
			return {"$t": "NodePath", "v": String(v)}
		TYPE_VECTOR2:
			return {"$t": "Vector2", "v": [v.x, v.y]}
		TYPE_VECTOR2I:
			return {"$t": "Vector2i", "v": [v.x, v.y]}
		TYPE_VECTOR3:
			return {"$t": "Vector3", "v": [v.x, v.y, v.z]}
		TYPE_VECTOR3I:
			return {"$t": "Vector3i", "v": [v.x, v.y, v.z]}
		TYPE_VECTOR4:
			return {"$t": "Vector4", "v": [v.x, v.y, v.z, v.w]}
		TYPE_VECTOR4I:
			return {"$t": "Vector4i", "v": [v.x, v.y, v.z, v.w]}
		TYPE_RECT2:
			return {"$t": "Rect2", "v": [v.position.x, v.position.y, v.size.x, v.size.y]}
		TYPE_RECT2I:
			return {"$t": "Rect2i", "v": [v.position.x, v.position.y, v.size.x, v.size.y]}
		TYPE_QUATERNION:
			return {"$t": "Quaternion", "v": [v.x, v.y, v.z, v.w]}
		TYPE_PLANE:
			return {"$t": "Plane", "v": [v.normal.x, v.normal.y, v.normal.z, v.d]}
		TYPE_AABB:
			return {"$t": "AABB", "v": [v.position.x, v.position.y, v.position.z, v.size.x, v.size.y, v.size.z]}
		TYPE_BASIS:
			return {"$t": "Basis", "v": [encode(v.x).v, encode(v.y).v, encode(v.z).v], "euler_deg": encode(Vector3(rad_to_deg(v.get_euler().x), rad_to_deg(v.get_euler().y), rad_to_deg(v.get_euler().z))).v}
		TYPE_TRANSFORM2D:
			return {"$t": "Transform2D", "v": [[v.x.x, v.x.y], [v.y.x, v.y.y], [v.origin.x, v.origin.y]], "rotation_deg": rad_to_deg(v.get_rotation()), "scale": [v.get_scale().x, v.get_scale().y]}
		TYPE_TRANSFORM3D:
			return {"$t": "Transform3D", "basis": encode(v.basis).v, "origin": [v.origin.x, v.origin.y, v.origin.z], "euler_deg": encode(v.basis).euler_deg, "scale": encode(v.basis.get_scale()).v}
		TYPE_PROJECTION:
			return {"$t": "Projection", "v": [encode(v.x).v, encode(v.y).v, encode(v.z).v, encode(v.w).v]}
		TYPE_COLOR:
			return {"$t": "Color", "v": [v.r, v.g, v.b, v.a], "html": v.to_html(true)}
		TYPE_RID:
			return {"$t": "RID", "v": v.get_id()}
		TYPE_CALLABLE, TYPE_SIGNAL:
			return {"$t": type_string(typeof(v)), "v": str(v)}
		TYPE_OBJECT:
			return encode_object(v)
		TYPE_DICTIONARY:
			var all_string := true
			for k in v.keys():
				if typeof(k) != TYPE_STRING and typeof(k) != TYPE_STRING_NAME:
					all_string = false
					break
			if all_string:
				var out := {}
				for k in v.keys():
					out[String(k)] = encode(v[k], depth + 1)
				return out
			var entries := []
			for k in v.keys():
				entries.append([encode(k, depth + 1), encode(v[k], depth + 1)])
			return {"$t": "Dictionary", "entries": entries}
		TYPE_ARRAY:
			var arr := []
			for item in v:
				arr.append(encode(item, depth + 1))
			return arr
		TYPE_PACKED_BYTE_ARRAY:
			return {"$t": "PackedByteArray", "size": v.size(), "base64": Marshalls.raw_to_base64(v) if v.size() <= 1_000_000 else null}
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY:
			return {"$t": type_string(typeof(v)), "v": Array(v)}
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			var items := []
			for item in v:
				items.append(encode(item, depth + 1).v)
			return {"$t": type_string(typeof(v)), "v": items}
	return {"$t": "unknown", "v": str(v)}


static func encode_object(o: Object) -> Variant:
	if o == null or not is_instance_valid(o):
		return null
	if o is Node:
		var n := o as Node
		var d := {"$t": "Node", "id": str(n.get_instance_id()), "class": n.get_class(), "name": String(n.name)}
		if n.is_inside_tree():
			var abs := String(n.get_path())
			if abs.find("@EditorNode@") == -1:
				d["path"] = abs
			else:
				d["path"] = abs.substr(abs.find("@SubViewport@")).get_slice("/", 1) if abs.find("@SubViewport@") != -1 else ""
		if n.get_script() != null:
			d["script"] = n.get_script().resource_path
		return d
	if o is Resource:
		var r := o as Resource
		var d := {"$t": "Resource", "id": str(r.get_instance_id()), "class": r.get_class(), "path": r.resource_path}
		if r.get_script() != null:
			d["script"] = r.get_script().resource_path
		return d
	return {"$t": "Object", "id": str(o.get_instance_id()), "class": o.get_class()}


## Decode a JSON value into a Variant. `hint` is the Variant type of the destination property
## (TYPE_NIL when unknown) so plain JSON numbers/arrays/strings can be coerced.
static func decode(v: Variant, hint: int = TYPE_NIL) -> Variant:
	match typeof(v):
		TYPE_DICTIONARY:
			if v.has("$t"):
				return _decode_tagged(v)
			var out := {}
			for k in v.keys():
				out[k] = decode(v[k])
			return out
		TYPE_ARRAY:
			if hint != TYPE_NIL and hint != TYPE_ARRAY:
				var coerced := _array_to_type(v, hint)
				if coerced != null:
					return coerced
			var arr := []
			for item in v:
				arr.append(decode(item))
			return arr
		TYPE_STRING:
			if hint != TYPE_NIL and hint != TYPE_STRING and hint != TYPE_STRING_NAME:
				var parsed = str_to_var(v)
				if parsed != null and (hint == TYPE_NIL or typeof(parsed) == hint):
					return parsed
				if hint == TYPE_NODE_PATH:
					return NodePath(v)
				if hint == TYPE_COLOR and Color.html_is_valid(v):
					return Color.html(v)
				if hint == TYPE_OBJECT and v.begins_with("res://"):
					return load(v)
			if hint == TYPE_STRING_NAME:
				return StringName(v)
			return v
		TYPE_FLOAT:
			if hint == TYPE_INT:
				return int(v)
			return v
		TYPE_INT:
			if hint == TYPE_FLOAT:
				return float(v)
			return v
	return v


static func _array_to_type(a: Array, hint: int) -> Variant:
	var n := a.size()
	match hint:
		TYPE_VECTOR2: return Vector2(a[0], a[1]) if n >= 2 else null
		TYPE_VECTOR2I: return Vector2i(a[0], a[1]) if n >= 2 else null
		TYPE_VECTOR3: return Vector3(a[0], a[1], a[2]) if n >= 3 else null
		TYPE_VECTOR3I: return Vector3i(a[0], a[1], a[2]) if n >= 3 else null
		TYPE_VECTOR4: return Vector4(a[0], a[1], a[2], a[3]) if n >= 4 else null
		TYPE_VECTOR4I: return Vector4i(a[0], a[1], a[2], a[3]) if n >= 4 else null
		TYPE_COLOR: return Color(a[0], a[1], a[2], a[3] if n >= 4 else 1.0) if n >= 3 else null
		TYPE_QUATERNION: return Quaternion(a[0], a[1], a[2], a[3]) if n >= 4 else null
		TYPE_RECT2: return Rect2(a[0], a[1], a[2], a[3]) if n >= 4 else null
		TYPE_RECT2I: return Rect2i(a[0], a[1], a[2], a[3]) if n >= 4 else null
		TYPE_PACKED_STRING_ARRAY: return PackedStringArray(a)
		TYPE_PACKED_INT32_ARRAY: return PackedInt32Array(a)
		TYPE_PACKED_INT64_ARRAY: return PackedInt64Array(a)
		TYPE_PACKED_FLOAT32_ARRAY: return PackedFloat32Array(a)
		TYPE_PACKED_FLOAT64_ARRAY: return PackedFloat64Array(a)
		TYPE_PACKED_VECTOR2_ARRAY:
			var p := PackedVector2Array()
			for item in a: p.append(decode(item, TYPE_VECTOR2))
			return p
		TYPE_PACKED_VECTOR3_ARRAY:
			var p := PackedVector3Array()
			for item in a: p.append(decode(item, TYPE_VECTOR3))
			return p
	return null


static func _decode_tagged(d: Dictionary) -> Variant:
	var t: String = d["$t"]
	var v = d.get("v")
	match t:
		"float":
			match v:
				"nan": return NAN
				"inf": return INF
				"-inf": return -INF
			return float(v)
		"NodePath": return NodePath(v)
		"StringName": return StringName(v)
		"Vector2": return Vector2(v[0], v[1])
		"Vector2i": return Vector2i(v[0], v[1])
		"Vector3": return Vector3(v[0], v[1], v[2])
		"Vector3i": return Vector3i(v[0], v[1], v[2])
		"Vector4": return Vector4(v[0], v[1], v[2], v[3])
		"Vector4i": return Vector4i(v[0], v[1], v[2], v[3])
		"Rect2": return Rect2(v[0], v[1], v[2], v[3])
		"Rect2i": return Rect2i(v[0], v[1], v[2], v[3])
		"Quaternion": return Quaternion(v[0], v[1], v[2], v[3])
		"Plane": return Plane(v[0], v[1], v[2], v[3])
		"AABB": return AABB(Vector3(v[0], v[1], v[2]), Vector3(v[3], v[4], v[5]))
		"Basis": return Basis(Vector3(v[0][0], v[0][1], v[0][2]), Vector3(v[1][0], v[1][1], v[1][2]), Vector3(v[2][0], v[2][1], v[2][2]))
		"Transform2D": return Transform2D(Vector2(v[0][0], v[0][1]), Vector2(v[1][0], v[1][1]), Vector2(v[2][0], v[2][1]))
		"Transform3D":
			var b = d.get("basis", [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
			var o = d.get("origin", [0, 0, 0])
			return Transform3D(_decode_tagged({"$t": "Basis", "v": b}), Vector3(o[0], o[1], o[2]))
		"Color":
			if d.has("html"): return Color.html(d["html"])
			return Color(v[0], v[1], v[2], v[3] if v.size() > 3 else 1.0)
		"Node", "Object", "Resource":
			if d.has("id"):
				var obj := instance_from_id(int(d["id"]))
				if obj != null:
					return obj
			if t == "Resource" and d.has("path") and String(d["path"]) != "":
				return load(d["path"])
			return null
		"Dictionary":
			var out := {}
			for e in d.get("entries", []):
				out[decode(e[0])] = decode(e[1])
			return out
		"PackedByteArray":
			return Marshalls.base64_to_raw(d.get("base64", ""))
		"PackedStringArray": return PackedStringArray(v)
		"PackedInt32Array": return PackedInt32Array(v)
		"PackedInt64Array": return PackedInt64Array(v)
		"PackedFloat32Array": return PackedFloat32Array(v)
		"PackedFloat64Array": return PackedFloat64Array(v)
		"PackedVector2Array": return _array_to_type(v, TYPE_PACKED_VECTOR2_ARRAY)
		"PackedVector3Array": return _array_to_type(v, TYPE_PACKED_VECTOR3_ARRAY)
	return v
