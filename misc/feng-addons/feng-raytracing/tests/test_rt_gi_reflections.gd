extends SceneTree

const Pass = preload("res://addons/feng-raytracing/passes/feng_rt_gi_pass.gd")
const SkyLightScript = preload("res://addons/feng-sky/feng_sky_light.gd")
const RendererScript = preload("res://addons/feng-render-pipeline/renderer.gd")
const CompositionScript = preload("res://addons/feng-render-pipeline/compositor.gd")
const Worlds = preload("res://addons/feng-render-pipeline/passes/snapshot_worlds.gd")
const Spec = preload("res://addons/feng-render-pipeline/pipeline/native_spec.gd")
const ReflectionRenderer = preload("res://addons/feng-raytracing/rendering/rt_gi_reflections.gd")
const Selection = preload("res://addons/feng-render-pipeline/pipeline/indirect_gi_selection.gd")

var gi
var sky_light
var raw_capture_done := false
var raw_capture := Color(0, 0, 0, 0)
var raw_capture_pixel := Vector2i(-1, -1)
var hdr_test_done := false
var hdr_test_passed := false
var hdr_clamped_result := Color(0, 0, 0, 0)
var hdr_jump_result := Color(0, 0, 0, 0)
var invalid_composite_unchanged := false
var duplicate_owner_unchanged := false

func _initialize() -> void:
	call_deferred("run")

func _reflection_is_valid() -> bool:
	for state_variant in gi._states.values():
		var state: Dictionary = state_variant
		var reflection: Dictionary = state.get("reflection", {})
		if not reflection.is_empty() and bool(reflection.get("valid", false)):
			return true
	return false

func _capture_raw_pixel(requested_pixel: Vector2i) -> void:
	var rd := RenderingServer.get_rendering_device()
	for state_variant in gi._states.values():
		var state: Dictionary = state_variant
		var reflection: Dictionary = state.get("reflection", {})
		if reflection.is_empty() or not bool(reflection.get("valid", false)):
			continue
		var raw: RID = reflection.get("raw", RID())
		var size: Vector2i = reflection.get("size", Vector2i.ZERO)
		if not raw.is_valid() or size.x <= 0 or size.y <= 0:
			continue
		var bytes := rd.texture_get_data(raw, 0)
		if not bytes.is_empty():
			var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAH, bytes)
			var pixel := requested_pixel
			if pixel.x < 0 or pixel.y < 0:
				pixel = Vector2i(size.x / 2, size.y / 2)
			raw_capture_pixel = pixel.clamp(Vector2i.ZERO, size - Vector2i.ONE)
			raw_capture = image.get_pixel(raw_capture_pixel.x, raw_capture_pixel.y)
		raw_capture_done = true
		return
	raw_capture_done = true

func _read_raw_at(pixel: Vector2i) -> Color:
	raw_capture_done = false
	raw_capture = Color(0, 0, 0, 0)
	raw_capture_pixel = pixel
	RenderingServer.call_on_render_thread(_capture_raw_pixel.bind(pixel))
	for i in 30:
		if raw_capture_done:
			break
		await process_frame
	return raw_capture

func _read_raw_center() -> Color:
	return await _read_raw_at(Vector2i(-1, -1))

func _center_pixel() -> Color:
	await process_frame
	var image := root.get_texture().get_image()
	return image.get_pixel(image.get_width() / 2, image.get_height() / 2)

func _close_color(a: Color, b: Color, tolerance: float) -> bool:
	return absf(a.r - b.r) <= tolerance and absf(a.g - b.g) <= tolerance \
			and absf(a.b - b.b) <= tolerance and absf(a.a - b.a) <= tolerance

func _color_is_finite_half(color: Color) -> bool:
	return is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and is_finite(color.a) \
			and color.r >= 0.0 and color.g >= 0.0 and color.b >= 0.0 \
			and color.r <= 65504.0 and color.g <= 65504.0 and color.b <= 65504.0

func _make_data_texture(rd: RenderingDevice, format: int, data: PackedByteArray,
		usage: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.width = 1
	texture_format.height = 1
	texture_format.format = format
	texture_format.usage_bits = usage
	return rd.texture_create(texture_format, RDTextureView.new(), [data])

func _color_bytes(format: int, color: Color) -> PackedByteArray:
	var image := Image.create(1, 1, false, format)
	image.set_pixel(0, 0, color)
	return image.get_data()

func _execute_hdr_exposure_history_test() -> void:
	var rd := RenderingServer.get_rendering_device()
	var backend := ReflectionRenderer.new()
	if rd == null or not backend.initialize(rd, false):
		print("RTGI_REFLECTION_CASE hdr_exposure_history_safe false init=", backend.error)
		backend.release()
		hdr_test_done = true
		return
	var state := backend.create_state(Vector2i.ONE)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	var sampler := rd.sampler_create(sampler_state)
	var depth := _make_data_texture(rd, RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			PackedFloat32Array([1.0]).to_byte_array())
	var normal := _make_data_texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
			_color_bytes(Image.FORMAT_RGBAF, Color(0.5, 0.5, 1.0, 0.0)))
	var albedo := _make_data_texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
			_color_bytes(Image.FORMAT_RGBAF, Color(0.5, 0.5, 0.5, 1.0)))
	var orm := _make_data_texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
			_color_bytes(Image.FORMAT_RGBAF, Color(1.0, 0.25, 0.0, 0.0)))
	var emission := _make_data_texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
			_color_bytes(Image.FORMAT_RGBAF, Color(0.0, 0.0, 0.0, 0.5)))
	var success := not state.is_empty() and Vector2i(state.get("size", Vector2i.ZERO)) == Vector2i.ONE \
			and sampler.is_valid() \
			and depth.is_valid() and normal.is_valid() and albedo.is_valid() and orm.is_valid() and emission.is_valid()
	if success:
		var old_radiance: RID = state.history[0][0]
		var old_depth: RID = state.history[0][1]
		var old_normal: RID = state.history[0][2]
		var old_hit: RID = state.history[0][3]
		var old_material: RID = state.history[0][4]
		var old_albedo: RID = state.history[0][5]
		success = rd.texture_update(state.raw, 0, _color_bytes(Image.FORMAT_RGBAH, Color(60000.0, 60000.0, 60000.0, 4.0))) == OK \
				and rd.texture_update(old_radiance, 0, _color_bytes(Image.FORMAT_RGBAH, Color(60000.0, 60000.0, 60000.0, 1.0))) == OK \
				and rd.texture_update(old_depth, 0, PackedFloat32Array([1.0]).to_byte_array()) == OK \
				and rd.texture_update(old_normal, 0, _color_bytes(Image.FORMAT_RGBAH, Color(0.0, 0.0, 1.0, 0.25))) == OK \
				and rd.texture_update(old_hit, 0, PackedFloat32Array([4.0]).to_byte_array()) == OK \
				and rd.texture_update(old_material, 0, _color_bytes(Image.FORMAT_RGH, Color(0.0, 0.5, 0.0, 0.0))) == OK \
				and rd.texture_update(old_albedo, 0, _color_bytes(Image.FORMAT_RGBAH, Color(0.5, 0.5, 0.5, 1.0))) == OK
	if success:
		state.valid = true
		state.generation = 1
		state.signature = ["hdr-exposure-test"]
		state.exposure = 1.0
		state.camera = Transform3D.IDENTITY
		var frame := {"camera_transform": Transform3D.IDENTITY, "pre_exposure": 2.0,
				"scene_normalization": 1.0, "camera_cut": false}
		success = backend.resolve(state, sampler, frame, [depth, normal, albedo, orm, emission], 2,
				["hdr-exposure-test"], {"history_weight": 0.9}, 1.0)
		if success:
			var first_bytes := rd.texture_get_data(state.history[state.ping][0], 0)
			hdr_clamped_result = Image.create_from_data(1, 1, false, Image.FORMAT_RGBAH, first_bytes).get_pixel(0, 0)
			success = _color_is_finite_half(hdr_clamped_result) and hdr_clamped_result.r > 60000.0 \
					and hdr_clamped_result.r <= 65504.0 and absf(hdr_clamped_result.r - hdr_clamped_result.g) < 1.0
	if success:
		state.exposure = 1.0
		state.generation = 2
		var frame_jump := {"camera_transform": Transform3D.IDENTITY, "pre_exposure": 8.0,
				"scene_normalization": 1.0, "camera_cut": false}
		success = rd.texture_update(state.raw, 0, _color_bytes(Image.FORMAT_RGBAH, Color(100.0, 100.0, 100.0, 4.0))) == OK \
				and backend.resolve(state, sampler, frame_jump, [depth, normal, albedo, orm, emission], 3,
				["hdr-exposure-test"], {"history_weight": 0.9}, 1.0)
		if success:
			var jump_bytes := rd.texture_get_data(state.history[state.ping][0], 0)
			hdr_jump_result = Image.create_from_data(1, 1, false, Image.FORMAT_RGBAH, jump_bytes).get_pixel(0, 0)
			success = _color_is_finite_half(hdr_jump_result) and absf(hdr_jump_result.r - 100.0) < 1.0
	var target := _make_data_texture(rd, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			_color_bytes(Image.FORMAT_RGBAH, Color(10.0, 8.0, 6.0, 0.75)),
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	var native := _make_data_texture(rd, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			_color_bytes(Image.FORMAT_RGBAH, Color(1.0, 2.0, 3.0, 1.0)))
	if success and target.is_valid() and native.is_valid():
		var blocked_owner := {"kind": "rt_gi", "key": "", "blocked": true}
		var duplicate_blocked := not Selection.is_resolved_reflection_owner(blocked_owner, "test:rt_first") \
				and not Selection.is_resolved_reflection_owner(blocked_owner, "test:rt_second")
		var unchanged_duplicate_target := Image.create_from_data(1, 1, false, Image.FORMAT_RGBAH,
				rd.texture_get_data(target, 0)).get_pixel(0, 0)
		duplicate_owner_unchanged = duplicate_blocked and _close_color(unchanged_duplicate_target,
				Color(10.0, 8.0, 6.0, 0.75), 0.01)
		var invalid_trace := _color_bytes(Image.FORMAT_RGBAH, Color(INF, 20.0, 30.0, 1.0))
		var invalid_upload_ok := rd.texture_update(state.history[state.ping][0], 0, invalid_trace) == OK
		var invalid_composite_dispatched := invalid_upload_ok and backend.composite(state, target, native,
				sampler, Vector2i.ONE, 1.0)
		var unchanged_after_invalid := Image.create_from_data(1, 1, false, Image.FORMAT_RGBAH,
				rd.texture_get_data(target, 0)).get_pixel(0, 0)
		invalid_composite_unchanged = invalid_composite_dispatched \
				and _color_is_finite_half(unchanged_after_invalid) \
				and _close_color(unchanged_after_invalid, Color(10.0, 8.0, 6.0, 0.75), 0.01)
		success = success and duplicate_owner_unchanged and invalid_composite_unchanged
	else:
		success = false
	if not state.is_empty():
		backend.release_state(state)
	for rid in [depth, normal, albedo, orm, emission, target, native, sampler]:
		if rid.is_valid():
			rd.free_rid(rid)
	backend.release()
	hdr_test_passed = success
	print("RTGI_REFLECTION_CASE hdr_exposure_history_safe ", success,
			" clamped=", hdr_clamped_result, " jump_rejected=", hdr_jump_result,
			" invalid_composite_unchanged=", invalid_composite_unchanged,
			" duplicate_owner_unchanged=", duplicate_owner_unchanged)
	hdr_test_done = true

func run() -> void:
	if RenderingServer.get_rendering_device() == null:
		push_error("RT reflection acceptance requires the RenderingDevice renderer")
		quit(1)
		return
	var separate_specular_msaa := OS.get_cmdline_user_args().has("--separate-specular-msaa2x")
	root.size = Vector2i(320, 240)
	root.msaa_3d = Viewport.MSAA_2X if separate_specular_msaa else Viewport.MSAA_DISABLED
	print("RTGI_REFLECTION_MODE separate_specular_msaa2x ", separate_specular_msaa)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	world_environment.environment = environment
	root.add_child(world_environment)

	var panorama_image := Image.create(128, 64, false, Image.FORMAT_RGBAF)
	for y in panorama_image.get_height():
		var horizon_weight := smoothstep(0.15, 0.85, absf(float(y) / panorama_image.get_height() - 0.5) * 2.0)
		var sky_color := Color(0.08, 0.18, 0.45).lerp(Color(0.7, 0.55, 0.28), 1.0 - horizon_weight)
		for x in panorama_image.get_width():
			panorama_image.set_pixel(x, y, sky_color)
	var panorama := PanoramaSkyMaterial.new()
	panorama.panorama = ImageTexture.create_from_image(panorama_image)
	var source_sky := Sky.new()
	source_sky.sky_material = panorama
	sky_light = SkyLightScript.new()
	sky_light.source_mode = SkyLightScript.SourceMode.SPECIFIED_SKY
	sky_light.source_sky = source_sky
	sky_light.capture_resolution = 32
	sky_light.capture_distance = 40.0
	sky_light.capture_offset = Vector3.ZERO
	sky_light.capture_interval = 3600.0
	sky_light.radiance_energy = 1.0
	root.add_child(sky_light)

	var wall_image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in wall_image.get_height():
		for x in wall_image.get_width():
			var center_tile := absf(float(x) - 31.5) < 3.0 and absf(float(y) - 31.5) < 3.0
			wall_image.set_pixel(x, y, Color.WHITE if center_tile else Color(0.015, 0.015, 0.015))
	var wall_material := StandardMaterial3D.new()
	wall_material.albedo_texture = ImageTexture.create_from_image(wall_image)
	wall_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	wall_material.roughness = 1.0
	wall_material.metallic = 0.0
	wall_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var wall := MeshInstance3D.new()
	var wall_mesh := QuadMesh.new()
	wall_mesh.size = Vector2(10, 10)
	wall.mesh = wall_mesh
	wall.material_override = wall_material
	wall.position = Vector3(4.0, 0.0, 0.0)
	wall.rotation.y = PI / 2.0
	root.add_child(wall)

	var mirror_material := StandardMaterial3D.new()
	mirror_material.albedo_color = Color(0.82, 0.82, 0.82)
	mirror_material.metallic = 1.0
	mirror_material.roughness = 0.0
	mirror_material.metallic_specular = 1.0
	mirror_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mirror := MeshInstance3D.new()
	var mirror_mesh := QuadMesh.new()
	mirror_mesh.size = Vector2(2.4, 2.4)
	mirror.mesh = mirror_mesh
	mirror.material_override = mirror_material
	mirror.rotation.y = PI / 4.0
	root.add_child(mirror)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 3.8
	camera.position = Vector3(0, 0, 6)
	root.add_child(camera)
	camera.look_at(Vector3.ZERO, Vector3.UP)
	camera.current = true

	var renderer = RendererScript.new()
	var passes: Array[FengPass] = []
	gi = Pass.new()
	gi.stable_id = &"test:rtgi_reflections"
	gi.strength = 0.0
	gi.samples_per_pixel = 4
	gi.reflections_enabled = false
	gi.needs_separate_specular = separate_specular_msaa
	for native_id in Spec.seed_order():
		passes.append(renderer._make_native_pass(native_id))
		if native_id == Spec.PASS_LIGHTING:
			passes.append(gi)
	renderer.passes = passes
	for entry in renderer.LibraryManager.DEFAULT_LIBRARY_ENTRIES:
		renderer._deleted_library_ids.append(entry.id)
	var compositor = CompositionScript.new()
	compositor.renderer = renderer
	world_environment.compositor = compositor
	Worlds.scan(root, self)

	var wait_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wait_start < 30000 and not bool(sky_light.get("_native_radiance_ready")):
		await process_frame
	var sky_ready := bool(sky_light.get("_native_radiance_ready"))
	print("RTGI_REFLECTION_CASE only_sky_provider_ready ", sky_ready)
	if not sky_ready:
		var sky_world_id := int(sky_light.call("_world_id"))
		var output_sky: Sky = sky_light.get("_output_sky")
		print("RTGI_REFLECTION_SKY_STATE ", {
			"world_id": sky_world_id,
			"candidate": sky_light.call("_feng_sky_light_is_candidate", sky_world_id),
			"provider_active": sky_light.get("_provider_active"),
			"external_enabled": sky_light.get("_external_radiance_enabled"),
			"capture_pending": sky_light.get("_capture_request_pending"),
			"capture_in_flight": sky_light.get("_capture_in_flight"),
			"capture_config_dirty": sky_light.get("_capture_native_config_dirty"),
			"capture_probe": sky_light.get("_capture_probe"),
			"capture_environment": sky_light.get("_capture_environment"),
			"capture_signature": sky_light.get("_capture_native_signature"),
			"external_revision": RenderingServer.call("sky_get_external_radiance_revision", output_sky.get_rid()) if output_sky != null else -99,
			"external_ready": RenderingServer.call("sky_is_external_radiance_ready", output_sky.get_rid()) if output_sky != null else false,
			"supports_scene_capture": ["reflection_probe_set_capture_environment", "reflection_probe_set_capture_only",
				"reflection_probe_set_capture_output_sky", "reflection_probe_set_capture_resolution",
				"reflection_probe_set_capture_fog_effect", "reflection_probe_request_capture"].all(
				func(method: String) -> bool: return RenderingServer.has_method(method)),
			"supports_external_radiance": ["sky_set_external_radiance", "sky_set_external_radiance_cubemap",
				"sky_is_external_radiance_ready", "sky_get_external_radiance_revision",
				"sky_get_external_radiance_exposure", "sky_bake_panorama"].all(
				func(method: String) -> bool: return RenderingServer.has_method(method)),
			"source_sky_valid": sky_light.source_sky != null and sky_light.source_sky.get_rid().is_valid(),
		})
	var reflection_enabled := false
	if sky_ready:
		gi.reflections_enabled = true
		wait_start = Time.get_ticks_msec()
		while Time.get_ticks_msec() - wait_start < 15000:
			await process_frame
			if _reflection_is_valid():
				reflection_enabled = true
				break
	var raw_mirror := Color(0, 0, 0, 0)
	var raw_mirror_offcenter := Color(0, 0, 0, 0)
	if reflection_enabled:
		raw_mirror = await _read_raw_center()
		raw_mirror_offcenter = await _read_raw_at(Vector2i(root.size.x / 2 + 8, root.size.y / 2))
	var mirror_pixel := await _center_pixel()
	print("RTGI_REFLECTION_CASE sky_lit_geometry_hit ",
			reflection_enabled and raw_mirror.a > 0.0 and raw_mirror.r + raw_mirror.g + raw_mirror.b > 0.001,
			" raw=", raw_mirror, " final=", mirror_pixel)
	var geometry_hit := reflection_enabled and raw_mirror.a > 0.0 \
			and raw_mirror.r + raw_mirror.g + raw_mirror.b > 0.001
	var orthographic_offcenter_hit := reflection_enabled and raw_mirror_offcenter.a > 0.0 \
			and raw_mirror_offcenter.r + raw_mirror_offcenter.g + raw_mirror_offcenter.b > 0.001
	print("RTGI_REFLECTION_CASE orthographic_offcenter_hit ", orthographic_offcenter_hit,
			" pixel=", raw_mirror_offcenter)

	mirror_material.roughness = 0.65
	for i in 45:
		await process_frame
	var raw_rough := await _read_raw_center()
	var roughness_delta := absf(raw_mirror.r - raw_rough.r) + absf(raw_mirror.g - raw_rough.g) \
			+ absf(raw_mirror.b - raw_rough.b)
	var roughness_changed := raw_rough.a != 0.0 and roughness_delta > 0.001
	print("RTGI_REFLECTION_CASE roughness_response ", roughness_changed,
			" mirror=", raw_mirror, " rough=", raw_rough)

	mirror_material.roughness = 0.0
	mirror_material.metallic = 0.0
	mirror_material.metallic_specular = 0.5
	for i in 45:
		await process_frame
	var raw_dielectric := await _read_raw_center()
	mirror_material.metallic = 1.0
	for i in 45:
		await process_frame
	var raw_metal := await _read_raw_center()
	var metallic_changed := raw_dielectric.a > 0.0 and raw_metal.a > 0.0 \
			and raw_metal.r + raw_metal.g + raw_metal.b > raw_dielectric.r + raw_dielectric.g + raw_dielectric.b
	print("RTGI_REFLECTION_CASE metallic_f0_response ", metallic_changed,
			" dielectric=", raw_dielectric, " metal=", raw_metal)
	wall_material.metallic = 0.0
	wall_material.metallic_specular = 0.0
	wall_material.roughness = 0.35
	for i in 45:
		await process_frame
	var secondary_specular_zero := await _read_raw_center()
	wall_material.metallic = 1.0
	wall_material.metallic_specular = 0.5
	wall_material.roughness = 0.08
	for i in 45:
		await process_frame
	var secondary_metal := await _read_raw_center()
	var secondary_sky_specular_changed := secondary_specular_zero.a > 0.0 and secondary_metal.a > 0.0 \
			and absf(secondary_specular_zero.r - secondary_metal.r) \
			+ absf(secondary_specular_zero.g - secondary_metal.g) \
			+ absf(secondary_specular_zero.b - secondary_metal.b) > 0.001
	print("RTGI_REFLECTION_CASE secondary_sky_specular_0_vs_metal ", secondary_sky_specular_changed,
			" specular0=", secondary_specular_zero, " metal=", secondary_metal)
	var switch_on_pixel := await _center_pixel()
	gi.reflections_enabled = false
	for i in 12:
		await process_frame
	var switch_off_pixel := await _center_pixel()
	gi.reflections_enabled = true
	for i in 12:
		await process_frame
	var runtime_switch := absf(switch_on_pixel.r - switch_off_pixel.r) \
			+ absf(switch_on_pixel.g - switch_off_pixel.g) + absf(switch_on_pixel.b - switch_off_pixel.b) > 0.001
	print("RTGI_REFLECTION_CASE runtime_toggle ", runtime_switch,
			" on=", switch_on_pixel, " off=", switch_off_pixel)
	hdr_test_done = false
	RenderingServer.call_on_render_thread(_execute_hdr_exposure_history_test)
	for i in 30:
		if hdr_test_done:
			break
		await process_frame

	gi.reflections_enabled = false
	var diffuse_only_gpu := 0.0
	for i in 20:
		await process_frame
	for i in 30:
		await process_frame
		diffuse_only_gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
	gi.strength = 1.0
	for i in 30:
		await process_frame
	gi.reflections_enabled = true
	for i in 30:
		await process_frame
	var combined_gpu := 0.0
	for i in 30:
		await process_frame
		combined_gpu += RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
	print("RTGI_REFLECTION_TIMING_MS diffuse_only=", diffuse_only_gpu / 30.0,
			" diffuse_plus_reflections=", combined_gpu / 30.0)

	var warnings: Array = renderer._last_validation_warnings
	print("RTGI_REFLECTION_WARNINGS ", warnings)
	var success := sky_ready and geometry_hit and orthographic_offcenter_hit and roughness_changed and metallic_changed \
			and secondary_sky_specular_changed and runtime_switch and hdr_test_done and hdr_test_passed
	Worlds.unregister_owner(self)
	world_environment.compositor = null
	compositor.renderer = null
	world_environment.queue_free()
	sky_light.queue_free()
	for i in 5:
		await process_frame
	gi = null
	renderer = null
	compositor = null
	print("RTGI_REFLECTION_GPU_TEST ", success)
	quit(0 if success else 1)
