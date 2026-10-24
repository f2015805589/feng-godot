extends SceneTree
## Real GPU regression for native ID 0 settings consumed before shadow culling.
## Both cameras see the same scene/light; only their compositor parameters differ.

const SHORT_DISTANCE := 8.0
const LONG_DISTANCE := 100.0
const MIN_SHADOW_PIXELS := 80
const MAX_CLEAR_SHADOW_PIXELS := 20
const MAX_UNCHANGED_PIXELS := 20

var views: Array[SubViewport] = []
var cameras: Array[Camera3D] = []
var compositors: Array[Compositor] = []
var schedule := PackedInt32Array()
var sun: DirectionalLight3D
var references: Array[Image] = []
var output_directory := ""
var measurements: Dictionary = {}
var checks := 0
var failed := false


func _initialize() -> void:
	run.call_deferred()


func require(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failed = true
		push_error("REGRESSION: " + message)


func settings(last_distance: float, enabled := true) -> Dictionary:
	return {
		"shadow_settings_enabled": enabled,
		"cascade_count": 4,
		"cascade_resolution": 4096,
		"cascade_1_distance": 2.0,
		"cascade_2_distance": 4.0,
		"cascade_3_distance": 6.0,
		"cascade_4_distance": last_distance,
		"blend_cascades": false,
		"shadow_fade_start": 0.95,
		"shadow_pancake_size": 20.0,
		"reserve_object_shadow_slot": false,
		"shadow_filter": 0,
		"shadow_blur": 1.0,
		"shadow_filter_quality": 2,
		"pcss_angular_diameter": 0.5,
		"shadow_bias": 0.1,
		"shadow_normal_bias": 1.0,
		"shadow_transmittance_bias": 0.05,
		"shadow_opacity": 1.0,
	}


func apply_settings(index: int, parameters: Dictionary) -> void:
	RenderingServer.compositor_set_frp_pipeline(compositors[index].get_rid(), schedule,
			PackedStringArray(), PackedInt32Array(), {0: parameters.duplicate(true)})


func luma(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722


func shadow_pixels(reference: Image, image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			if luma(reference.get_pixel(x, y)) - luma(image.get_pixel(x, y)) > 0.04:
				count += 1
	return count


func changed_pixels(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			if absf(luma(a.get_pixel(x, y)) - luma(b.get_pixel(x, y))) > 0.01:
				count += 1
	return count


func capture(label: String) -> Array[Image]:
	for frame in 8:
		await process_frame
		await RenderingServer.frame_post_draw
	var result: Array[Image] = []
	var counts: Array[int] = []
	for index in views.size():
		var image := views[index].get_texture().get_image()
		require(image != null and not image.is_empty(), "%s view %d must render an image" % [label, index])
		result.append(image)
		if references.size() == views.size():
			counts.append(shadow_pixels(references[index], image))
		if not output_directory.is_empty():
			require(image.save_png(output_directory.path_join("%s-view-%d.png" % [label, index])) == OK,
					"could not save %s view %d" % [label, index])
	measurements[label] = {"shadow_pixels": counts}
	print("SHADOW_SETTINGS ", label, " shadow_pixels=", counts)
	return result


func require_coverage(images: Array[Image], shadowed_view: int, label: String) -> void:
	for index in views.size():
		var count := shadow_pixels(references[index], images[index])
		if index == shadowed_view:
			require(count >= MIN_SHADOW_PIXELS, "%s view %d must retain real cast shadows, got %d pixels" % [label, index, count])
		else:
			require(count <= MAX_CLEAR_SHADOW_PIXELS, "%s view %d must stay outside shadow coverage, got %d pixels" % [label, index, count])


func make_scene() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.05, 0.05, 0.05)
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.15
	scene.add_child(world)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.6, 0.6, 0.6)
	material.roughness = 1.0
	material.metallic_specular = 0.0
	var receiver := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(64, 64)
	receiver.mesh = plane
	receiver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	receiver.material_override = material
	scene.add_child(receiver)
	var caster := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(5, 7, 5)
	caster.mesh = box
	caster.position.y = 3.5
	caster.material_override = material
	scene.add_child(caster)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 150, 0)
	sun.shadow_enabled = false
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = SHORT_DISTANCE
	sun.shadow_normal_bias = 1.0
	sun.shadow_blur = 0.0
	scene.add_child(sun)
	for index in 2:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(320, 240)
		viewport.world_3d = root.world_3d
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.msaa_3d = Viewport.MSAA_DISABLED
		viewport.use_taa = false
		root.add_child(viewport)
		views.append(viewport)
		var camera := Camera3D.new()
		viewport.add_child(camera)
		camera.position = Vector3(18, 22, 30)
		camera.far = 160.0
		camera.look_at(Vector3.ZERO)
		camera.current = true
		var compositor := Compositor.new()
		camera.compositor = compositor
		cameras.append(camera)
		compositors.append(compositor)
		apply_settings(index, settings(SHORT_DISTANCE))


func run() -> void:
	require(RenderingServer.get_current_rendering_method() == "frp", "this probe requires the FRP renderer")
	require(RenderingServer.get_rendering_device() != null, "this probe requires a real GPU; headless dummy rendering is not a test")
	if failed:
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		output_directory = args[0]
	var spec: Dictionary = RenderingServer.get_frp_pipeline_spec()
	for native_id in spec.get("default_order", []):
		if int(native_id) != 6: # Native TAA is the jitter switch; keep image comparisons deterministic.
			schedule.append(int(native_id))
	require(schedule.has(0), "the native default pipeline must include Shadow Pass ID 0")
	make_scene()
	references = await capture("unshadowed-reference")
	require(luma(references[0].get_pixel(160, 180)) > 0.15, "the reference receiver must be visibly lit")
	sun.shadow_enabled = true
	var short_pair := await capture("short-both")
	require_coverage(short_pair, -1, "short-both")
	# The scene's own 8 m range cannot cull a caster ~40 m from the camera.
	# A shadow here proves ID 0's 100 m override reached projection AND caster culling.
	apply_settings(0, settings(LONG_DISTANCE))
	var long_a := await capture("long-a-short-b")
	require_coverage(long_a, 0, "long-a-short-b")
	require(changed_pixels(long_a[0], short_pair[0]) >= MIN_SHADOW_PIXELS, "editing only the last cascade distance must change rendered shadows")
	require(changed_pixels(long_a[1], short_pair[1]) <= MAX_UNCHANGED_PIXELS, "editing compositor A must not alter camera B")
	apply_settings(0, settings(SHORT_DISTANCE))
	var shrunk := await capture("live-shrink-a")
	require_coverage(shrunk, -1, "live-shrink-a")
	require(changed_pixels(shrunk[0], short_pair[0]) <= MAX_UNCHANGED_PIXELS, "shrinking a live cascade must remove stale long-range shadows")
	apply_settings(1, settings(LONG_DISTANCE))
	var long_b := await capture("short-a-long-b")
	require_coverage(long_b, 1, "short-a-long-b")
	require(changed_pixels(long_b[0], shrunk[0]) <= MAX_UNCHANGED_PIXELS, "editing compositor B must not alter camera A")
	cameras[0].compositor = compositors[1]
	cameras[1].compositor = compositors[0]
	var swapped := await capture("swapped-compositors")
	require_coverage(swapped, 0, "swapped-compositors")
	apply_settings(1, settings(LONG_DISTANCE, false))
	var disabled := await capture("disabled-restores-short-light")
	require_coverage(disabled, -1, "disabled-restores-short-light")
	require(changed_pixels(disabled[0], short_pair[0]) <= MAX_UNCHANGED_PIXELS, "disabled pass settings must restore the scene light's short range")
	sun.directional_shadow_max_distance = LONG_DISTANCE
	var legacy_long := await capture("disabled-follows-long-light")
	require_coverage(legacy_long, 0, "disabled-follows-long-light")
	sun.directional_shadow_max_distance = SHORT_DISTANCE
	for filter_mode in [1, 2]:
		var filtered := settings(LONG_DISTANCE)
		filtered["shadow_filter"] = filter_mode
		filtered["shadow_bias"] = 0.2
		filtered["shadow_normal_bias"] = 0.75
		filtered["pcss_angular_diameter"] = 1.0
		apply_settings(1, filtered)
		var filtered_pair := await capture("live-filter-%d" % filter_mode)
		require_coverage(filtered_pair, 0, "live-filter-%d" % filter_mode)
		require(changed_pixels(filtered_pair[1], short_pair[1]) <= MAX_UNCHANGED_PIXELS, "live filter/bias edits must remain isolated to their compositor")
	require(is_equal_approx(sun.directional_shadow_max_distance, SHORT_DISTANCE)
			and is_equal_approx(sun.shadow_bias, 0.1) and is_equal_approx(sun.shadow_normal_bias, 1.0)
			and is_zero_approx(sun.shadow_blur) and is_zero_approx(sun.light_angular_distance),
			"view overrides must not mutate scene-authored light parameters")
	measurements["checks"] = checks
	measurements["failed"] = failed
	if not output_directory.is_empty():
		var report := FileAccess.open(output_directory.path_join("measurements.json"), FileAccess.WRITE)
		if report != null:
			report.store_string(JSON.stringify(measurements, "\t"))
		else:
			require(false, "could not write measurement report")
	if not failed:
		print("PASS FRP Shadow Pass settings before culling, live cascade distances, legacy fallback and camera/compositor isolation (%d checks)" % checks)
	quit(1 if failed else 0)
