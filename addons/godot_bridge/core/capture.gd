extends RefCounted
## Visual "seeing" with declared guarantees. Every result carries provenance + limitations.
## Modes:
##   viewport         - read the texture of an existing Viewport (exact composition of that viewport).
##   camera_preview   - auxiliary SubViewport sharing the camera's World3D/World2D with an auxiliary
##                      camera copying the real camera's parameters. Does not include CanvasLayers,
##                      per-viewport effects history (TAA/exposure) or viewport-specific settings.
##   camera_takeover  - make the real camera current in its own viewport, render, restore. Exact,
##                      but it is a (temporary) mutation of the running scene.

const Codec := preload("res://addons/godot_bridge/core/codec.gd")


## In headless / dummy-renderer processes RenderingServer never emits frame_post_draw, so awaiting it would hang forever.
static func rendering_unavailable() -> Dictionary:
	if DisplayServer.get_name() == "headless" or RenderingServer.get_current_rendering_driver_name() == "dummy":
		return {"$error": {"code": "UNSUPPORTED", "message": "No rendering in this process (headless editor or dummy renderer): captures are impossible here. Structured tools (scene.tree/inspect, spatial.query) still work.", "data": {"display_server": DisplayServer.get_name(), "rendering_driver": RenderingServer.get_current_rendering_driver_name()}}}
	return {}


static func _image_result(img: Image, meta: Dictionary) -> Dictionary:
	if img == null or img.is_empty():
		return {"$error": {"code": "UNSUPPORTED", "message": "Viewport produced an empty image. Rendering is unavailable (headless / dummy renderer) or the viewport has not drawn yet.", "data": meta}}
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBA8)
	meta["width"] = img.get_width()
	meta["height"] = img.get_height()
	meta["process_frame"] = Engine.get_process_frames()
	meta["physics_frame"] = Engine.get_physics_frames()
	meta["t_msec"] = Time.get_ticks_msec()
	return {"_image": img, "meta": meta}


## Downscale a viewport capture (viewport mode cannot pick the render size).
static func resize_result(result: Dictionary, size: Vector2i) -> Dictionary:
	var img: Image = result.get("_image")
	if img != null and size.x > 0 and size.y > 0 and (img.get_width() > size.x or img.get_height() > size.y):
		var scale := minf(float(size.x) / img.get_width(), float(size.y) / img.get_height())
		img.resize(maxi(1, int(img.get_width() * scale)), maxi(1, int(img.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
		result["meta"]["resized_to"] = [img.get_width(), img.get_height()]
	return result


## Encode the captured Image as jpeg (default; ~5-10x smaller than png) or png.
static func encode_result(result: Dictionary, fmt: String = "jpeg", quality: float = 0.7) -> Dictionary:
	var img: Image = result.get("_image")
	result.erase("_image")
	if img == null:
		return result
	var bytes: PackedByteArray
	var mime := "image/jpeg"
	if fmt == "png":
		bytes = img.save_png_to_buffer()
		mime = "image/png"
	else:
		if img.get_format() != Image.FORMAT_RGB8:
			img.convert(Image.FORMAT_RGB8)
		bytes = img.save_jpg_to_buffer(quality)
	result["image"] = {"mime": mime, "base64": Marshalls.raw_to_base64(bytes), "width": img.get_width(), "height": img.get_height(), "bytes": bytes.size()}
	result["meta"]["format"] = fmt
	return result


static func viewport(vp: Viewport, extra: Dictionary = {}) -> Dictionary:
	if vp == null:
		return {"$error": {"code": "NOT_FOUND", "message": "Viewport not found"}}
	var unavailable := rendering_unavailable()
	if not unavailable.is_empty():
		return unavailable
	await RenderingServer.frame_post_draw
	var tex := vp.get_texture()
	var img: Image = tex.get_image() if tex != null else null
	var meta := {"mode": "viewport", "viewport": Codec.encode(vp), "size": Codec.encode(vp.get_visible_rect().size), "guarantee": "exact pixels of this viewport as last drawn", "limitations": []}
	if vp is SubViewport and vp.render_target_update_mode == SubViewport.UPDATE_DISABLED:
		meta["limitations"].append("SubViewport update mode is DISABLED; image may be stale")
	meta.merge(extra)
	return _image_result(img, meta)


static func camera3d_preview(host: Node, cam: Camera3D, size: Vector2i, tree_hint: Dictionary = {}) -> Dictionary:
	if not cam.is_inside_tree():
		return {"$error": {"code": "INVALID", "message": "Camera3D is not inside the tree"}}
	var unavailable := rendering_unavailable()
	if not unavailable.is_empty():
		return unavailable
	var sub := SubViewport.new()
	sub.size = size
	sub.own_world_3d = false
	sub.world_3d = cam.get_world_3d()
	sub.render_target_update_mode = SubViewport.UPDATE_ONCE
	sub.transparent_bg = false
	sub.msaa_3d = cam.get_viewport().msaa_3d
	sub.screen_space_aa = cam.get_viewport().screen_space_aa
	sub.use_debanding = cam.get_viewport().use_debanding
	host.add_child(sub)
	var aux := Camera3D.new()
	aux.projection = cam.projection
	aux.fov = cam.fov
	aux.size = cam.size
	aux.near = cam.near
	aux.far = cam.far
	aux.keep_aspect = cam.keep_aspect
	aux.cull_mask = cam.cull_mask
	aux.environment = cam.environment
	aux.attributes = cam.attributes
	aux.compositor = cam.compositor
	aux.h_offset = cam.h_offset
	aux.v_offset = cam.v_offset
	aux.frustum_offset = cam.frustum_offset
	sub.add_child(aux)
	aux.global_transform = cam.global_transform
	aux.current = true
	await host.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := sub.get_texture().get_image()
	var meta := {
		"mode": "camera_preview",
		"camera": Codec.encode(cam),
		"camera_transform": Codec.encode(cam.get_camera_transform()),
		"projection": {"type": cam.projection, "fov": cam.fov, "size": cam.size, "near": cam.near, "far": cam.far, "keep_aspect": cam.keep_aspect},
		"world": Codec.encode(cam.get_world_3d()),
		"guarantee": "render from an auxiliary camera with the same transform/projection in the same World3D",
		"limitations": ["CanvasLayers/UI of the original viewport are not included", "temporal effects (TAA, auto-exposure, SSR/SSIL history) start from scratch", "viewport-level settings (scaling, debug draw, VRS) come from defaults"],
	}
	meta.merge(tree_hint)
	sub.queue_free()
	return _image_result(img, meta)


static func camera2d_preview(host: Node, cam: Camera2D, size: Vector2i) -> Dictionary:
	if not cam.is_inside_tree():
		return {"$error": {"code": "INVALID", "message": "Camera2D is not inside the tree"}}
	var unavailable := rendering_unavailable()
	if not unavailable.is_empty():
		return unavailable
	var sub := SubViewport.new()
	sub.size = size
	sub.world_2d = cam.get_world_2d()
	sub.render_target_update_mode = SubViewport.UPDATE_ONCE
	sub.transparent_bg = false
	sub.canvas_item_default_texture_filter = cam.get_viewport().canvas_item_default_texture_filter
	host.add_child(sub)
	var aux := Camera2D.new()
	aux.anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER
	aux.zoom = cam.zoom
	aux.ignore_rotation = cam.ignore_rotation
	sub.add_child(aux)
	# get_screen_center_position() is the *effective* view center: includes offset, limits and smoothing state.
	var center := cam.get_screen_center_position()
	aux.global_position = center
	if not cam.ignore_rotation:
		aux.global_rotation = cam.global_rotation
	aux.enabled = true
	aux.make_current()
	aux.force_update_scroll()
	await host.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := sub.get_texture().get_image()
	var meta := {
		"mode": "camera_preview",
		"camera": Codec.encode(cam),
		"screen_center": Codec.encode(center),
		"zoom": Codec.encode(cam.zoom),
		"guarantee": "render of the shared World2D from the camera's effective center/zoom",
		"limitations": ["CanvasLayers (HUD, parallax backgrounds) belong to the original viewport and are not included", "the requested size defines the visible area; the original viewport size may differ", "position smoothing history is what the real camera has right now, not replayed"],
	}
	sub.queue_free()
	return _image_result(img, meta)


static func camera_takeover(cam: Node, extra: Dictionary = {}) -> Dictionary:
	if not cam.is_inside_tree():
		return {"$error": {"code": "INVALID", "message": "Camera is not inside the tree"}}
	var unavailable := rendering_unavailable()
	if not unavailable.is_empty():
		return unavailable
	var vp := cam.get_viewport()
	var restore: Variant = null
	if cam is Camera3D:
		restore = vp.get_camera_3d()
		(cam as Camera3D).make_current()
	elif cam is Camera2D:
		restore = vp.get_camera_2d()
		(cam as Camera2D).enabled = true
		(cam as Camera2D).make_current()
		(cam as Camera2D).force_update_scroll()
	else:
		return {"$error": {"code": "INVALID", "message": "Node is not a Camera2D/Camera3D"}}
	await cam.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if restore != null and is_instance_valid(restore) and restore != cam:
		restore.make_current()
	var meta := {"mode": "camera_takeover", "camera": Codec.encode(cam), "viewport": Codec.encode(vp), "guarantee": "exact composition of the real viewport with this camera current", "limitations": ["this temporarily changed the current camera (one frame); scripts reacting to camera changes may have run"], "restored_camera": Codec.encode(restore)}
	meta.merge(extra)
	return _image_result(img, meta)
