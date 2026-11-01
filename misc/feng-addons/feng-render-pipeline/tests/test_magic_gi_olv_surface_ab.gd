extends SceneTree

## One-shot GPU acceptance check for the OLV screen-surface debug route and the
## final prepared-CLV consumer. The scene and manifest are changed in memory
## only; this script never packs or saves the scene/resource.

const SCENE_PATH := "res://box_test.tscn"
const ProjectPipeline = preload("res://addons/feng-render-pipeline/project_pipeline.gd")
const OLV_DEBUG_VIEW := 6
const MAGIC_GI_BUFFER := 6
const WAIT_FOR_READY_FRAMES := 120
const WAIT_FOR_SWITCH_FRAMES := 90
# Captures are separate from the authored project and never save its scene.
const OUTPUT_DIR := "C:/Users/QianHua/.codex/visualizations/2026/10/18/01a14f25-2ebd-7e11-8e7b-38acbcb28fce/olv_surface_ab_20261028"

var _magic: Resource
var _debug: Resource
var _volume: Node
var _manifest: Resource
var _baseline_olv_enabled := false
var _report: Dictionary = {}
var _capture_dir := OUTPUT_DIR

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var packed := ResourceLoader.load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("scene_load_failed")
		return
	var scene := packed.instantiate()
	if scene == null:
		_fail("scene_instantiate_failed")
		return
	get_root().add_child(scene)
	current_scene = scene
	await _wait_frames(12)
	if RenderingServer.get_current_rendering_method() != "frp":
		_fail("project_is_not_using_frp:%s" % RenderingServer.get_current_rendering_method())
		return
	var compositor := ProjectPipeline.resolve()
	var renderer: Resource = compositor.get("renderer") if compositor != null else null
	if renderer == null:
		_fail("renderer_missing")
		return
	for pass_value in renderer.get("passes"):
		if not pass_value is Resource:
			continue
		match String(pass_value.get("stable_id")):
			"library:magic_gi": _magic = pass_value
			"library:debug_buffers": _debug = pass_value
	if _magic == null or _debug == null:
		_fail("magic_gi_or_debug_pass_missing")
		return
	_volume = scene.get_node_or_null("MagicGIVolume")
	var camera := scene.get_node_or_null("Camera3D") as Camera3D
	if _volume == null or camera == null or not camera.current:
		_fail("authored_camera_or_volume_missing")
		return
	var args := OS.get_cmdline_user_args()
	if args.has("--oblique-left") or args.has("--oblique-right"):
		var left := args.has("--oblique-left")
		camera.global_position = Vector3(1.25 if left else -1.25, 1.8, 6.3)
		camera.look_at(Vector3(0.0, 1.5, -0.5), Vector3.UP)
		_capture_dir = OUTPUT_DIR.path_join("oblique_left" if left else "oblique_right")
	_manifest = _volume.get("bake_manifest") as Resource
	if _manifest == null:
		_fail("manifest_missing")
		return
	_baseline_olv_enabled = bool(_manifest.get("prepared_olv_filter_enabled"))
	_report = {"scene": SCENE_PATH, "camera": camera.global_transform,
		"camera_fov": camera.fov, "baseline_olv_enabled": _baseline_olv_enabled,
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_video_adapter_name()}
	print("OLV_SURFACE_SETUP ", JSON.stringify(_report, "", true, true))
	if not _baseline_olv_enabled:
		_fail("baseline_manifest_olv_disabled")
		return

	# First prove the screen path is drawing receiver pixels from the GBuffer.
	_magic.set("enabled", true)
	_debug.set("buffer", MAGIC_GI_BUFFER)
	_debug.set("gi_exposure", 0.0)
	_debug.set("gi_display_mode", 0)
	_debug.set("enabled", true)
	_magic.set("clv_debug_view", OLV_DEBUG_VIEW)
	await _wait_frames(WAIT_FOR_READY_FRAMES)
	var mode6_state: Dictionary = _magic.call("get_magicdawn_runtime_state")
	var mode6_image := _capture("mode6_surface.png")
	var mode6_summary := _image_summary(mode6_image, true)
	_report["mode6_state"] = mode6_state
	_report["mode6_image"] = mode6_summary
	print("OLV_SURFACE_MODE6 state=", mode6_state)
	print("OLV_SURFACE_MODE6 image=", mode6_summary)

	# Switch back to the production GI output before the A/B. This is the final
	# Magic GI contribution shown by Debug Buffers, not the domain-label view.
	_magic.set("clv_debug_view", 0)
	await _wait_for_state(true, WAIT_FOR_SWITCH_FRAMES)
	var on_state: Dictionary = _magic.call("get_magicdawn_runtime_state")
	var on_dynamic := _dynamic_state(on_state)
	var on_image := _capture("gi_olv_on.png")
	var on_summary := _image_summary(on_image, false)
	_report["olv_on_state"] = on_state
	_report["olv_on_dynamic_state"] = on_dynamic
	_report["olv_on_image"] = on_summary
	print("OLV_SURFACE_ON state=", on_state)
	print("OLV_SURFACE_ON image=", on_summary)

	# Toggle only the in-memory manifest bit. The volume's manifest changed signal
	# republishes the immutable snapshot, causing the prepared cache identity to
	# drop the OLV bindings. No scene/resource is saved.
	_manifest.set("prepared_olv_filter_enabled", false)
	_manifest.emit_changed()
	await _wait_for_state(false, WAIT_FOR_SWITCH_FRAMES)
	var off_state: Dictionary = _magic.call("get_magicdawn_runtime_state")
	var off_dynamic := _dynamic_state(off_state)
	var off_image := _capture("gi_olv_off.png")
	var off_summary := _image_summary(off_image, false)
	var delta := _image_delta(on_image, off_image)
	var diff_image := _image_difference(on_image, off_image)
	_report["olv_off_state"] = off_state
	_report["olv_off_dynamic_state"] = off_dynamic
	_report["olv_off_image"] = off_summary
	_report["on_off_delta"] = delta
	_report["on_off_diff_image"] = _save_image(diff_image, "gi_olv_on_off_diff.png")
	print("OLV_SURFACE_OFF state=", off_state)
	print("OLV_SURFACE_OFF image=", off_summary)
	print("OLV_SURFACE_ON_OFF delta=", delta)

	# The process owns a loaded copy of the manifest, but restore the bit before
	# exiting so any in-process observers see the authored state during teardown.
	_manifest.set("prepared_olv_filter_enabled", _baseline_olv_enabled)
	_manifest.emit_changed()
	_debug.set("enabled", false)
	_magic.set("clv_debug_view", 0)
	_save_report()
	var mode6_visible := bool(mode6_summary.get("visible", false))
	var mode6_colored := int(mode6_summary.get("domain_colored_pixels", 0)) > 0
	var active_on := bool(on_dynamic.get("olv_renderer_active", false)) \
			and bool(on_dynamic.get("olv_input_present", false))
	var inactive_off := not bool(off_dynamic.get("olv_renderer_active", true)) \
			and not bool(off_dynamic.get("olv_input_present", true))
	var diff_visible := float(delta.get("mean_abs_rgb", 0.0)) > 0.0001
	_report["assertions"] = {"mode6_visible": mode6_visible,
		"mode6_domain_colored": mode6_colored, "on_olv_renderer_active": active_on,
		"off_olv_renderer_inactive": inactive_off, "on_off_gi_pixel_delta": diff_visible}
	print("OLV_SURFACE_ASSERT ", _report["assertions"])
	_save_report()
	quit(0 if mode6_visible and mode6_colored and active_on and inactive_off and diff_visible else 1)

func _wait_for_state(want_olv: bool, max_frames: int) -> void:
	for _frame in max_frames:
		await process_frame
		var state: Dictionary = _magic.call("get_magicdawn_runtime_state")
		var dynamic := _dynamic_state(state)
		var current := bool(dynamic.get("olv_renderer_active", false))
		var binding := bool(dynamic.get("olv_input_present", false))
		if current == want_olv and binding == want_olv:
			await RenderingServer.frame_post_draw
			return
	await RenderingServer.frame_post_draw

func _dynamic_state(state: Dictionary) -> Dictionary:
	var dynamic_value: Variant = state.get("dynamic_volume", {})
	return dynamic_value if dynamic_value is Dictionary else {}

func _capture(name: String) -> Image:
	var image := get_root().get_viewport().get_texture().get_image()
	_emit_thumbnail(image, name)
	_save_image(image, name)
	return image

func _emit_thumbnail(image: Image, name: String) -> void:
	if image == null or image.is_empty():
		return
	var thumbnail := image.duplicate()
	thumbnail.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	var encoded := Marshalls.raw_to_base64(thumbnail.save_png_to_buffer())
	var marker := name.to_upper().replace(".", "_")
	print("OLV_SURFACE_THUMB_" + marker + "=" + encoded)

func _save_image(image: Image, name: String) -> String:
	if image == null or image.is_empty():
		return ""
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	var path := _capture_dir.path_join(name)
	var error_code := image.save_png(path)
	print("OLV_SURFACE_IMAGE path=", path, " size=", image.get_size(),
		" result=", error_string(error_code) if error_code != OK else "OK")
	return path

func _image_summary(image: Image, classify_domains: bool) -> Dictionary:
	if image == null or image.is_empty():
		return {"valid": false, "visible": false}
	var step_x := maxi(1, image.get_width() / 96)
	var step_y := maxi(1, image.get_height() / 54)
	var count := 0
	var visible_count := 0
	var sum_luma := 0.0
	var max_luma := 0.0
	var colored := 0
	var orange := 0
	var blue := 0
	var purple := 0
	var gray := 0
	for y in range(0, image.get_height(), step_y):
		for x in range(0, image.get_width(), step_x):
			var color := image.get_pixel(x, y)
			var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			sum_luma += luma
			max_luma = maxf(max_luma, luma)
			if luma > 0.025:
				visible_count += 1
			if classify_domains and luma > 0.025:
				if color.r > color.b * 1.25 and color.r > color.g * 1.12:
					orange += 1
					colored += 1
				elif color.b > color.r * 1.25 and color.b > color.g * 1.08:
					blue += 1
					colored += 1
				elif color.r > color.g * 1.2 and color.b > color.g * 1.2:
					purple += 1
					colored += 1
				else:
					gray += 1
			count += 1
	return {"valid": true, "size": image.get_size(), "samples": count,
		"mean_luma": sum_luma / maxf(1.0, float(count)), "max_luma": max_luma,
		"visible_fraction": float(visible_count) / maxf(1.0, float(count)),
		"visible": visible_count > count / 100,
		"domain_colored_pixels": colored, "orange_pixels": orange,
		"blue_pixels": blue, "purple_pixels": purple, "gray_pixels": gray}

func _image_delta(first: Image, second: Image) -> Dictionary:
	if first == null or second == null or first.is_empty() or second.is_empty() \
			or first.get_size() != second.get_size():
		return {"valid": false, "mean_abs_rgb": INF, "max_abs_rgb": INF}
	var step_x := maxi(1, first.get_width() / 96)
	var step_y := maxi(1, first.get_height() / 54)
	var sum_delta := 0.0
	var max_delta := 0.0
	var nonzero := 0
	var count := 0
	for y in range(0, first.get_height(), step_y):
		for x in range(0, first.get_width(), step_x):
			var a := first.get_pixel(x, y)
			var b := second.get_pixel(x, y)
			var delta := (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
			sum_delta += delta
			max_delta = maxf(max_delta, delta)
			if delta > 0.001:
				nonzero += 1
			count += 1
	return {"valid": true, "samples": count, "mean_abs_rgb": sum_delta / maxf(1.0, float(count)),
		"max_abs_rgb": max_delta, "nonzero_fraction": float(nonzero) / maxf(1.0, float(count))}

func _image_difference(first: Image, second: Image) -> Image:
	if first == null or second == null or first.is_empty() or second.is_empty() \
			or first.get_size() != second.get_size():
		return Image.new()
	var result := Image.create(first.get_width(), first.get_height(), false, Image.FORMAT_RGBA8)
	for y in first.get_height():
		for x in first.get_width():
			var delta := first.get_pixel(x, y) - second.get_pixel(x, y)
			result.set_pixel(x, y, Color(absf(delta.r) * 8.0, absf(delta.g) * 8.0,
				absf(delta.b) * 8.0, 1.0))
	return result

func _save_report() -> void:
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	var file := FileAccess.open(_capture_dir.path_join("report.json"),
		FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_report, "", true, true))
		file.close()

func _fail(reason: String) -> void:
	print("OLV_SURFACE_FATAL ", reason)
	quit(2)

func _wait_frames(count: int) -> void:
	for _frame in count:
		await process_frame
	await RenderingServer.frame_post_draw
