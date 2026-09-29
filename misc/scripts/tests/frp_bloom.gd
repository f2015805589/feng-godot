extends SceneTree

# Native Bloom is a scheduled FRP pass that prepares Environment Gaussian Glow before
# the Post Process/Tonemap entry composites it. This covers the native schedule,
# schema-7 migration, the optional TAA/MSAA resolve path, and the Bloom and exposure
# switches on rendered pixels.

const CENTER := Vector2i(160, 120)
const EXPECTED_ORDER := [0, 1, 2, 3, 4, 5, 6, 8, 7]
const FRP_BASE = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")

var scene: Node3D
var camera: Camera3D
var environment: Environment
var renderer
var bloom_entry
var eye_entry


func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		quit(1)
		assert(value, message)


func _initialize() -> void:
	call_deferred("run")


func _find_native(p_renderer: Object, native_id: int):
	for entry in p_renderer.passes:
		if entry.get("native_id") != null and int(entry.native_id) == native_id:
			return entry
	return null


func _find_library(p_renderer: Object, stable_id: StringName):
	for entry in p_renderer.passes:
		if entry != null and entry.stable_id == stable_id:
			return entry
	return null


func frame() -> Image:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func ring_luminance(image: Image) -> float:
	var total := 0.0
	var count := 0
	for y in range(maxi(0, CENTER.y - 48), mini(image.get_height(), CENTER.y + 49)):
		for x in range(maxi(0, CENTER.x - 48), mini(image.get_width(), CENTER.x + 49)):
			var distance := Vector2(x - CENTER.x, y - CENTER.y).length()
			if distance < 10.0 or distance > 45.0:
				continue
			total += image.get_pixel(x, y).get_luminance()
			count += 1
	return total / float(maxi(1, count))


func max_luminance(image: Image) -> float:
	var result := 0.0
	for y in image.get_height():
		for x in image.get_width():
			result = maxf(result, image.get_pixel(x, y).get_luminance())
	return result


func image_delta(a: Image, b: Image) -> float:
	var total := 0.0
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			total += maxf(maxf(absf(pa.r - pb.r), absf(pa.g - pb.g)), absf(pa.b - pb.b))
			count += 1
	return total / float(maxi(1, count))


func _check_default_spec_and_schedule(renderer_script: Script) -> void:
	require(RenderingServer.has_method("get_frp_pipeline_spec"), "FRP native pass spec is not exposed")
	var spec: Dictionary = RenderingServer.call("get_frp_pipeline_spec")
	require(int(spec.get("pass_count", 0)) == 9, "native spec must retain ids 0..7 and append Bloom id 8")
	require(spec.get("default_order", []) == EXPECTED_ORDER, "Bloom default schedule must be 0..6, 8, 7: %s" % [spec.get("default_order", [])])
	require(spec.get("mandatory", []) == [0, 1, 2, 3, 7], "Bloom must remain non-mandatory")
	var required_edges := [[5, 8], [6, 8], [8, 7]]
	var edges: Array = spec.get("edges", [])
	for edge in required_edges:
		require(edges.has(edge), "native dependency is missing: %s" % [edge])

	renderer = renderer_script.new()
	var native_order: Array[int] = []
	for entry in renderer.passes:
		if entry.get("native_id") != null and int(entry.native_id) >= 0:
			native_order.append(int(entry.native_id))
	require(native_order == EXPECTED_ORDER, "fresh renderer order changed: %s" % [native_order])
	bloom_entry = _find_native(renderer, 8)
	eye_entry = _find_library(renderer, &"library:eye_adaptation")
	var grade_entry = _find_library(renderer, &"library:color_grade")
	require(bloom_entry != null and bloom_entry.enabled, "native Bloom must exist and ship enabled")
	require(eye_entry != null and eye_entry.enabled, "default renderer must contain enabled Eye Adaptation")
	require(grade_entry != null, "default renderer must contain Color Grade")
	require(renderer.passes.find(eye_entry) < renderer.passes.find(bloom_entry)
			and renderer.passes.find(bloom_entry) < renderer.passes.find(grade_entry),
			"default Eye Adaptation/Bloom/Color Grade order is wrong")
	require(renderer.get_validation_warnings().is_empty(), "default Bloom schedule must validate: %s" % [renderer.get_validation_warnings()])

	# The dependency must still hold while TAA is disabled by default.
	var normal_passes: Array[FRP_BASE] = renderer.passes.duplicate()
	var invalid: Array[FRP_BASE] = normal_passes.duplicate()
	var moved_bloom = _find_native(renderer, 8)
	invalid.erase(moved_bloom)
	var transparent_index := -1
	for i in invalid.size():
		if invalid[i].get("native_id") != null and int(invalid[i].native_id) == 5:
			transparent_index = i
			break
	invalid.insert(transparent_index, moved_bloom)
	renderer.passes = invalid
	var warnings: PackedStringArray = renderer.get_configuration_warnings()
	var transparent_warning := false
	for warning in warnings:
		if warning.contains("Transparent") and warning.contains("Bloom"):
			transparent_warning = true
	require(transparent_warning, "Bloom must not be draggable before Transparent when TAA is disabled: %s" % [warnings])
	renderer.passes = normal_passes

	# Post is id 7, so moving Bloom to its right violates the native edge.
	invalid = normal_passes.duplicate()
	invalid.erase(moved_bloom)
	invalid.append(moved_bloom)
	renderer.passes = invalid
	warnings = renderer.get_configuration_warnings()
	var post_warning := false
	for warning in warnings:
		if warning.contains("Bloom") and warning.contains("Post Process"):
			post_warning = true
	require(post_warning, "Bloom must remain before Post Process: %s" % [warnings])
	renderer.passes = normal_passes

	# Eye Adaptation is an addon library pass, so the addon checks its relative order.
	invalid = normal_passes.duplicate()
	var moved_eye = _find_library(renderer, &"library:eye_adaptation")
	invalid.erase(moved_eye)
	invalid.insert(invalid.find(moved_bloom) + 1, moved_eye)
	renderer.passes = invalid
	warnings = renderer.get_configuration_warnings()
	var eye_warning := false
	for warning in warnings:
		if warning.contains("Eye Adaptation") and warning.contains("Bloom"):
			eye_warning = true
	require(eye_warning, "Eye Adaptation must precede Bloom: %s" % [warnings])
	renderer.passes = normal_passes


func _check_native_name_recovery(renderer_script: Script) -> void:
	var authored = renderer_script.new()
	var bloom = _find_native(authored, 8)
	var transparent = _find_native(authored, 5)
	var temporal_aa = _find_native(authored, 6)
	require(bloom != null and bloom.implementation != null, "Bloom name fixture has no implementation")
	require(transparent != null and transparent.implementation != null, "Transparent name fixture has no implementation")
	require(temporal_aa != null and temporal_aa.implementation != null, "Temporal AA name fixture has no implementation")

	# Simulate names persisted by an engine build that did not recognize Bloom.
	bloom.resource_name = "native id 8"
	bloom.implementation.resource_name = "native id 8"
	# Names authored by a project must survive normalization unchanged.
	transparent.resource_name = "Project Transparent Label"
	transparent.implementation.resource_name = "Project Transparent Implementation"
	# A mismatched native implementation is not eligible for automatic relabeling.
	var replacement_script = load("res://addons/feng-render-pipeline/passes/native/transparent_pass.gd") as Script
	require(replacement_script != null, "could not load replacement native implementation script")
	var replacement_implementation = replacement_script.new()
	replacement_implementation.native_id = 6
	replacement_implementation.resource_name = "native id 6"
	temporal_aa.implementation = replacement_implementation
	temporal_aa.resource_name = "native id 6"

	authored.set("_normalizing", true)
	var path := "user://frp_bloom_native_names_%d.tres" % Time.get_ticks_usec()
	require(ResourceSaver.save(authored, path) == OK, "could not save native-name recovery fixture")
	authored.set("_normalizing", false)
	var loaded = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	require(loaded != null, "native-name recovery fixture did not load")
	var loaded_entries: Array = loaded.passes
	var loaded_bloom = _find_native(loaded, 8)
	var loaded_transparent = _find_native(loaded, 5)
	var loaded_temporal_aa = _find_native(loaded, 6)
	require(loaded_entries.size() > 0, "loading the name fixture produced no native schedule")
	require(loaded_bloom != null and loaded_bloom.implementation != null, "reloaded Bloom entry has no implementation")
	require(loaded_transparent != null and loaded_transparent.implementation != null,
			"reloaded Transparent entry has no implementation")
	require(loaded_temporal_aa != null and loaded_temporal_aa.implementation != null,
			"reloaded Temporal AA entry has no implementation")
	require(loaded_bloom.resource_name == "Bloom", "placeholder wrapper name did not recover to Bloom")
	require(loaded_bloom.implementation.resource_name == "Bloom", "placeholder implementation name did not recover to Bloom")
	require(loaded_transparent.resource_name == "Project Transparent Label", "custom wrapper name was changed")
	require(loaded_transparent.implementation.resource_name == "Project Transparent Implementation",
			"custom implementation name was changed")
	require(loaded_temporal_aa.resource_name == "Temporal AA", "placeholder wrapper name did not recover for a valid native id")
	require(loaded_temporal_aa.implementation.native_id == 6, "name recovery changed the authored implementation id")
	require(loaded_temporal_aa.implementation._native_pass_id() == 5,
			"mismatched implementation fixture no longer uses the replacement pass script")
	require(loaded_temporal_aa.implementation.resource_name == "native id 6",
			"mismatched implementation placeholder was relabeled")


func _check_schema_migration(renderer_script: Script) -> void:
	var migrating = renderer_script.new()
	var legacy_passes: Array[FRP_BASE] = migrating.passes.duplicate()
	var legacy_bloom = _find_native(migrating, 8)
	require(legacy_bloom != null, "schema migration fixture has no Bloom entry")
	legacy_passes.erase(legacy_bloom)
	var legacy_taa = _find_native(migrating, 6)
	legacy_taa.enabled = true
	var legacy_grade = _find_library(migrating, &"library:color_grade")
	legacy_grade.enabled = true
	var before_ids: Array[String] = []
	var before_enabled := {}
	for entry in legacy_passes:
		before_ids.append(String(entry.stable_id))
		before_enabled[String(entry.stable_id)] = entry.enabled
	migrating.passes = legacy_passes
	migrating.set("_pipeline_schema_version", 7)
	var migrated: Array = migrating.passes
	var bloom = _find_native(migrating, 8)
	var eye = _find_library(migrating, &"library:eye_adaptation")
	var grade = _find_library(migrating, &"library:color_grade")
	require(bloom != null and bloom.enabled, "schema 7 migration must insert enabled native Bloom")
	require(migrated.find(eye) + 1 == migrated.find(bloom) and migrated.find(bloom) < migrated.find(grade),
			"migration must insert Bloom after Eye Adaptation and before Color Grade")
	var after_ids: Array[String] = []
	for entry in migrated:
		if entry.get("native_id") != null and int(entry.native_id) == 8:
			continue
		after_ids.append(String(entry.stable_id))
		require(entry.enabled == before_enabled[String(entry.stable_id)], "migration changed the enabled state of %s" % [entry.stable_id])
	require(after_ids == before_ids, "schema 7 migration changed other entries' relative order")
	require(int(migrating.get("_pipeline_schema_version")) == 8, "migration did not persist schema 8")

	# Save a schema-7 .tres with Bloom absent, then let ResourceLoader invoke the
	# production migration path. Keep the old authored order and enabled switches.
	var saved_legacy = renderer_script.new()
	var saved_legacy_passes: Array[FRP_BASE] = saved_legacy.passes.duplicate()
	var saved_bloom = _find_native(saved_legacy, 8)
	saved_legacy_passes.erase(saved_bloom)
	var saved_taa = _find_native(saved_legacy, 6)
	saved_taa.enabled = true
	var saved_grade = _find_library(saved_legacy, &"library:color_grade")
	saved_grade.enabled = true
	var expected_ids: Array[String] = []
	var expected_enabled := {}
	for entry in saved_legacy_passes:
		expected_ids.append(String(entry.stable_id))
		expected_enabled[String(entry.stable_id)] = entry.enabled
	saved_legacy.passes = saved_legacy_passes
	saved_legacy.set("_pipeline_schema_version", 7)
	# ResourceSaver asks for the exported `passes` property. Suppress its lazy getter
	# migration long enough to write the intended schema-7 fixture to disk.
	saved_legacy.set("_normalizing", true)
	var legacy_path := "user://frp_schema7_bloom_%d.tres" % Time.get_ticks_usec()
	require(ResourceSaver.save(saved_legacy, legacy_path) == OK, "could not save schema-7 Bloom fixture")
	saved_legacy.set("_normalizing", false)
	var loaded_legacy = ResourceLoader.load(legacy_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	require(loaded_legacy != null, "schema-7 Bloom fixture did not load")
	var loaded_entries: Array = loaded_legacy.passes
	var loaded_bloom = _find_native(loaded_legacy, 8)
	var loaded_eye = _find_library(loaded_legacy, &"library:eye_adaptation")
	var loaded_grade = _find_library(loaded_legacy, &"library:color_grade")
	require(loaded_bloom != null and loaded_bloom.enabled, "loading schema-7 .tres must add enabled native Bloom")
	require(loaded_entries.find(loaded_eye) + 1 == loaded_entries.find(loaded_bloom)
			and loaded_entries.find(loaded_bloom) < loaded_entries.find(loaded_grade),
			"schema-7 .tres must place Bloom after Eye Adaptation and before Color Grade")
	var actual_ids: Array[String] = []
	for entry in loaded_entries:
		if entry.get("native_id") != null and int(entry.native_id) == 8:
			continue
		actual_ids.append(String(entry.stable_id))
		require(entry.enabled == expected_enabled[String(entry.stable_id)],
				"schema-7 .tres migration changed %s enabled state" % [entry.stable_id])
	require(actual_ids == expected_ids, "schema-7 .tres migration reordered existing passes")
	require(int(loaded_legacy.get("_pipeline_schema_version")) == 8, "schema-7 .tres did not upgrade to schema 8")


func _make_scene() -> void:
	scene = Node3D.new()
	root.add_child(scene)
	camera = Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 5.0)
	camera.current = true
	scene.add_child(camera)

	var glow_quad := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.24, 0.24)
	glow_quad.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.emission_enabled = true
	material.emission = Color.WHITE
	material.emission_energy_multiplier = 32.0
	glow_quad.material_override = material
	scene.add_child(glow_quad)

	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.glow_intensity = 3.0
	environment.glow_strength = 1.0
	environment.glow_bloom = 0.5
	environment.glow_enabled = false
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene.add_child(world_environment)

	var compositor := Compositor.new()
	camera.compositor = compositor
	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	require(renderer_script != null, "FRP renderer script did not load")
	renderer = renderer_script.new()
	renderer.apply(compositor)
	require(renderer.get_validation_warnings().is_empty(), "default Glow pipeline must validate: %s" % [renderer.get_validation_warnings()])
	bloom_entry = _find_native(renderer, 8)
	eye_entry = _find_library(renderer, &"library:eye_adaptation")
	# Pixel comparisons below isolate native Glow from the separate exposure pass.
	eye_entry.enabled = false
	renderer.apply(compositor)


func run() -> void:
	print("START FRP native Bloom tests")
	root.msaa_3d = Viewport.MSAA_4X
	root.use_taa = false
	root.debug_draw = Viewport.DEBUG_DRAW_DISABLED

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	require(renderer_script != null, "FRP renderer script did not load")
	_check_default_spec_and_schedule(renderer_script)
	_check_native_name_recovery(renderer_script)
	_check_schema_migration(renderer_script)

	_make_scene()
	var baseline := await frame()
	environment.glow_enabled = true
	renderer.apply(camera.compositor)
	var bloom_on := await frame()
	var bloom_ring := ring_luminance(bloom_on)
	print("native Bloom pixels: size=%s center=%s baseline_ring=%f enabled_ring=%f baseline_max=%f enabled_max=%f" % [baseline.get_size(), bloom_on.get_pixel(CENTER.x, CENTER.y), ring_luminance(baseline), bloom_ring, max_luminance(baseline), max_luminance(bloom_on)])
	require(bloom_ring > ring_luminance(baseline) + 0.002, "enabled Bloom did not add an Environment Glow halo")
	# Bloom remains executable when authors move it to another dependency-valid slot.
	var moved_entries: Array[FRP_BASE] = renderer.passes.duplicate()
	moved_entries.erase(bloom_entry)
	var grade_entry = _find_library(renderer, &"library:color_grade")
	moved_entries.insert(moved_entries.find(grade_entry) + 1, bloom_entry)
	renderer.passes = moved_entries
	require(renderer.get_configuration_warnings().is_empty(), "Bloom's legal move after Color Grade was rejected")
	renderer.apply(camera.compositor)
	var moved_bloom_frame := await frame()
	require(ring_luminance(moved_bloom_frame) > ring_luminance(baseline) + 0.002,
			"Bloom did not execute after a legal drag within its dependency range")
	# Temporal upscaling is a viewport feature and must still produce its HDR source
	# when native TAA entry 6 is disabled in an explicit pipeline.
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	root.scaling_3d_scale = 0.5
	require(not _find_native(renderer, 6).enabled, "the upscaling check requires native TAA to remain disabled")
	renderer.apply(camera.compositor)
	var upscaled_bloom_frame := await frame()
	require(ring_luminance(upscaled_bloom_frame) > ring_luminance(baseline) + 0.002,
			"Bloom/tonemap did not receive a current upscaled source with TAA disabled")
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = 1.0
	root.msaa_3d = Viewport.MSAA_4X
	var compositor: Compositor = camera.compositor
	camera.compositor = null
	var no_pipeline_fallback := await frame()
	require(ring_luminance(no_pipeline_fallback) > ring_luminance(baseline) + 0.002,
			"the FRP engine default schedule must keep native Glow without a pipeline resource")
	camera.compositor = compositor

	# The native pass is a real switch: a stale blur texture must not be composited
	# when Environment Glow remains enabled but Bloom itself is disabled.
	bloom_entry.enabled = false
	renderer.apply(camera.compositor)
	var bloom_off := await frame()
	print("Bloom on/off pixels: ring_on=%f ring_off=%f ring_delta=%f image_delta=%f" % [bloom_ring, ring_luminance(bloom_off), bloom_ring - ring_luminance(bloom_off), image_delta(bloom_on, bloom_off)])
	require(image_delta(bloom_off, baseline) < 0.01,
			"disabling Bloom must suppress Environment Glow even when it remains enabled")
	bloom_entry.enabled = true
	environment.glow_enabled = false
	renderer.apply(camera.compositor)
	var environment_off := await frame()
	require(image_delta(environment_off, baseline) < 0.01,
			"Environment.glow_enabled=false must keep native Bloom a no-op")

	# Eye Adaptation remains before Bloom. Compare the Glow pixel contribution with
	# Eye Adaptation enabled and pre-exposure switched both ways. The HDR blur source
	# is the resolved internal scene-color texture (after MSAA/temporal upscaling).
	environment.glow_enabled = true
	eye_entry.enabled = true
	eye_entry.pre_exposure = false
	renderer.apply(camera.compositor)
	var eye_without_pre_exposure := await frame()
	bloom_entry.enabled = false
	renderer.apply(camera.compositor)
	var eye_without_pre_exposure_no_bloom := await frame()
	var eye_without_pre_exposure_glow_delta := ring_luminance(eye_without_pre_exposure) - ring_luminance(eye_without_pre_exposure_no_bloom)
	require(eye_without_pre_exposure_glow_delta > 0.002,
			"Bloom must contribute visible Glow after Eye Adaptation with pre-exposure off")
	bloom_entry.enabled = true
	eye_entry.pre_exposure = true
	renderer.apply(camera.compositor)
	var eye_with_pre_exposure := await frame()
	bloom_entry.enabled = false
	renderer.apply(camera.compositor)
	var eye_with_pre_exposure_no_bloom := await frame()
	var eye_with_pre_exposure_glow_delta := ring_luminance(eye_with_pre_exposure) - ring_luminance(eye_with_pre_exposure_no_bloom)
	require(eye_with_pre_exposure_glow_delta > 0.002,
			"Bloom must contribute visible Glow after Eye Adaptation with pre-exposure on")
	var pre_exposure_glow_ratio := eye_with_pre_exposure_glow_delta / eye_without_pre_exposure_glow_delta
	print("Bloom HDR blur source: resolved internal scene-color texture after MSAA/temporal upscale")
	print("Eye Adaptation Glow ring delta (Bloom on minus off): pre_exposure=false %f, true %f, ratio=%f" % [eye_without_pre_exposure_glow_delta, eye_with_pre_exposure_glow_delta, pre_exposure_glow_ratio])
	require(pre_exposure_glow_ratio > 0.25 and pre_exposure_glow_ratio < 4.0,
			"Eye Adaptation pre-exposure caused an abnormal Bloom threshold/brightness jump: ratio=%f" % [pre_exposure_glow_ratio])

	# Threshold-sensitive A/B removes glow_bloom's fixed floor and uses a manual
	# 10x exposure so the same HDR threshold should produce a similar halo with PE
	# on and off.
	eye_entry.metering_mode = 2
	eye_entry.apply_physical_camera_exposure = true
	eye_entry.aperture = 1.0
	eye_entry.shutter_speed = 0.1
	eye_entry.iso = 100.0
	environment.glow_bloom = 0.0
	environment.glow_hdr_threshold = 1.0
	environment.glow_hdr_scale = 0.25
	var threshold_deltas := {}
	for pre_exposure in [false, true]:
		eye_entry.pre_exposure = pre_exposure
		bloom_entry.enabled = true
		renderer.apply(camera.compositor)
		var threshold_on := await frame()
		bloom_entry.enabled = false
		renderer.apply(camera.compositor)
		var threshold_off := await frame()
		threshold_deltas[pre_exposure] = ring_luminance(threshold_on) - ring_luminance(threshold_off)
		print("Threshold Bloom PE=%s ring_on=%f ring_off=%f delta=%f" % [pre_exposure, ring_luminance(threshold_on), ring_luminance(threshold_off), threshold_deltas[pre_exposure]])
	require(threshold_deltas[false] > 0.002 and threshold_deltas[true] > 0.002,
			"HDR-threshold Bloom did not produce a visible ring with PE on and off: %s" % [threshold_deltas])
	var threshold_pre_exposure_ratio: float = threshold_deltas[true] / threshold_deltas[false]
	require(threshold_pre_exposure_ratio > 0.8 and threshold_pre_exposure_ratio < 1.25,
			"HDR-threshold Bloom changed abnormally with pre-exposure: ratio=%f" % [threshold_pre_exposure_ratio])
	print("PASS Bloom threshold PE ratio=%f" % [threshold_pre_exposure_ratio])

	print("PASS FRP native Bloom schedule, migration, dependencies and glow switch")
	print("PASS Bloom pre-exposure pixel comparison")
	scene.queue_free()
	await process_frame
	quit(0)
