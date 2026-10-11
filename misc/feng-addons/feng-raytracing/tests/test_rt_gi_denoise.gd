extends SceneTree
## Exercise the diffuse denoiser with controlled radiance, surfaces and camera changes.
const Pass = preload("res://addons/feng-raytracing/passes/feng_rt_gi_pass.gd")
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const SIZE := Vector2i(64, 32)
var done := false
var passed := true

func _initialize() -> void:
	RenderingServer.call_on_render_thread(run)
	for frame in 120:
		await process_frame
		if done:
			quit(0 if passed else 1)
			return
	quit(2)

func check(value: bool, label: String) -> void:
	passed = passed and value
	print("RTGI_DENOISE ", label, " ", value)

func texture(rd: RenderingDevice, format: int, data: PackedByteArray) -> RID:
	var desc := RDTextureFormat.new()
	desc.width = SIZE.x
	desc.height = SIZE.y
	desc.format = format
	desc.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return rd.texture_create(desc, RDTextureView.new(), [data])

func filled(color: Color) -> PackedByteArray:
	var image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAF)
	image.fill(color)
	return image.get_data()

func read(rd: RenderingDevice, state: Dictionary) -> Image:
	return Image.create_from_data(state.size.x, state.size.y, false, Image.FORMAT_RGBAH,
			rd.texture_get_data(state.history[state.ping][0], 0))

func run() -> void:
	var rd := RenderingServer.get_rendering_device()
	var pass_instance := Pass.new()
	pass_instance.denoiser = 1 # This fixture validates the Temporal backend.
	if not pass_instance.ensure_diffuse_compute(rd):
		check(false, "compile")
		done = true
		return
	var state := pass_instance._create_diffuse_state(rd, SIZE)
	var depth_values := PackedFloat32Array()
	depth_values.resize(SIZE.x * SIZE.y)
	depth_values.fill(0.5)
	var depth := texture(rd, RenderingDevice.DATA_FORMAT_R32_SFLOAT, depth_values.to_byte_array())
	var normal := texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, filled(Color(0.5, 0.5, 1.0, 0.0)))
	var albedo_image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAF)
	for y in SIZE.y:
		for x in SIZE.x:
			albedo_image.set_pixel(x, y, Color.WHITE if x < SIZE.x / 2 else Color.RED)
	var albedo := texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, albedo_image.get_data())
	var orm := texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, filled(Color(1.0, 1.0, 0.0, 1.0 / 255.0)))
	var sampler := rd.sampler_create(RDSamplerState.new())
	var inputs: Array[RID] = [depth, normal, albedo, orm]
	var lighting := {"sky_light_source_owner_id": 1, "sky_light_source": depth,
			"sky_light_source_valid": true, "sky_radiance_texture": albedo,
			"sky_light_revision": 1, "sky_light_source_revision": 1, "sky_captured_exposure": 0.1}
	var lighting_key: Array = pass_instance._lighting_signature(lighting)
	lighting.sky_radiance_texture = orm
	lighting.sky_light_revision = 2
	lighting.sky_light_source_revision = 2
	lighting.sky_captured_exposure = 0.2
	check(lighting_key == pass_instance._lighting_signature(lighting), "realtime_capture_preserves_history")
	lighting.sky_light_source_owner_id = 2
	check(lighting_key != pass_instance._lighting_signature(lighting), "new_sky_owner_invalidates_history")
	lighting.sky_light_source_owner_id = 1
	lighting.sky_light_rotation = Basis(Vector3.UP, 0.5)
	check(lighting_key != pass_instance._lighting_signature(lighting), "sky_rotation_invalidates_history")
	var frame := {"camera_transform": Transform3D.IDENTITY, "projection": Projection.IDENTITY,
			"pre_exposure": 1.0, "scene_normalization": 1.0, "camera_generation": 1}
	var options := {"history_weight": 0.97}
	var raw := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	for generation in range(1, 65):
		for y in SIZE.y:
			for x in SIZE.x:
				var energy := 8.0 if (x * 13 + y * 29 + generation * 7) % 16 < 2 else 0.0
				var color := albedo_image.get_pixel(x, y) * energy
				color.a = 1.0
				raw.set_pixel(x, y, color)
		rd.texture_update(state.raw, 0, raw.get_data())
		passed = pass_instance._resolve_diffuse(rd, sampler, state, frame, inputs, generation, 1, options) and passed
	var image := read(rd, state)
	var mean := 0.0
	var mse := 0.0
	var leak := 0.0
	for y in SIZE.y:
		for x in SIZE.x:
			var c := image.get_pixel(x, y)
			mean += c.r
			mse += (c.r - 1.0) * (c.r - 1.0)
			if x >= SIZE.x / 2:
				leak = maxf(leak, maxf(c.g, c.b))
	mean /= SIZE.x * SIZE.y
	mse /= SIZE.x * SIZE.y
	print("RTGI_DENOISE stats mean=", mean, " rms=", sqrt(mse), " material_leak=", leak)
	check(absf(mean - 1.0) < 0.05 and sqrt(mse) < 0.15, "noise_reduction_preserves_mean")
	check(leak < 0.001, "material_boundary")
	raw.fill(Color(0, 0, 0, 1))
	rd.texture_update(state.raw, 0, raw.get_data())
	frame.camera_transform = Transform3D(Basis.IDENTITY, Vector3(0.02, 0, 0))
	passed = pass_instance._resolve_diffuse(rd, sampler, state, frame, inputs, 65, 1, options) and passed
	check(read(rd, state).get_pixel(16, 16).r > 0.5, "camera_motion_reprojects_history")
	depth_values.fill(0.2)
	rd.texture_update(depth, 0, depth_values.to_byte_array())
	passed = pass_instance._resolve_diffuse(rd, sampler, state, frame, inputs, 66, 1, options) and passed
	check(read(rd, state).get_pixel(16, 16).r < 0.001, "disocclusion_rejects_history")
	state.valid = false
	raw.fill(Color(1, 1, 1, 1))
	rd.texture_update(state.raw, 0, raw.get_data())
	passed = pass_instance._resolve_diffuse(rd, sampler, state, frame, inputs, 67, 1, options) and passed
	frame.pre_exposure = 2.0
	raw.fill(Color(2, 2, 2, 1))
	rd.texture_update(state.raw, 0, raw.get_data())
	passed = pass_instance._resolve_diffuse(rd, sampler, state, frame, inputs, 68, 1, options) and passed
	check(absf(read(rd, state).get_pixel(16, 16).r - 2.0) < 0.002, "pre_exposure_rescales_history")
	frame.camera_cut = true
	raw.fill(Color(0, 0, 0, 1))
	rd.texture_update(state.raw, 0, raw.get_data())
	passed = pass_instance._resolve_diffuse(rd, sampler, state, frame, inputs, 69, 1, options) and passed
	check(read(rd, state).get_pixel(16, 16).r < 0.001, "camera_cut")
	pass_instance._release_diffuse_state(rd, state)
	check_half_resolution(rd, pass_instance, sampler, inputs)
	for rid in [depth, normal, albedo, orm, sampler]:
		rd.free_rid(rid)
	pass_instance._shared.reverse()
	for rid in pass_instance._shared:
		rd.free_rid(rid)
	pass_instance._shared.clear()
	done = true

func check_half_resolution(rd: RenderingDevice, pass_instance: Resource, sampler: RID, inputs: Array[RID]) -> void:
	var size := SIZE / 2
	var state: Dictionary = pass_instance._create_diffuse_state(rd, size)
	var previous: Array = state.history[0]
	var values := Image.create(size.x, size.y, false, Image.FORMAT_RGBAH)
	for y in size.y:
		for x in size.x:
			values.set_pixel(x, y, Color(x, x, x, 1))
	rd.texture_update(previous[0], 0, values.get_data())
	values.fill(Color(0, 0, 1, 32))
	rd.texture_update(previous[3], 0, values.get_data())
	values.fill(Color.WHITE)
	rd.texture_update(previous[4], 0, values.get_data())
	rd.texture_update(state.raw, 0, values.get_data())
	var depths := PackedFloat32Array()
	depths.resize(size.x * size.y)
	depths.fill(0.5)
	rd.texture_update(previous[2], 0, depths.to_byte_array())
	depths.resize(SIZE.x * SIZE.y)
	depths.fill(0.5)
	rd.texture_update(inputs[0], 0, depths.to_byte_array())
	var moments := PackedFloat32Array()
	for pixel in size.x * size.y:
		moments.append_array(PackedFloat32Array([8.0, 128.0]))
	rd.texture_update(previous[1], 0, moments.to_byte_array())
	state.valid = true
	state.generation = 1
	state.revision = 1
	state.camera = 1
	var frame := {"camera_transform": Transform3D(Basis.IDENTITY, Vector3(-0.4 / SIZE.x, 0, 0)),
			"projection": Projection.IDENTITY, "pre_exposure": 1.0,
			"scene_normalization": 1.0, "camera_generation": 1}
	passed = pass_instance._resolve_diffuse(rd, sampler, state, frame, inputs, 2, 1, {"history_weight": 0.97}) and passed
	# A 0.2-full-pixel shift mixes history x=7/8 at 10%/90%, then accumulates frame 33.
	var actual := read(rd, state).get_pixel(8, 8).r
	var expected := (1.0 + 7.9 * 32.0) / 33.0
	print("RTGI_DENOISE half_resolution actual=", actual, " expected=", expected)
	check(absf(actual - expected) < 0.006, "fractional_motion_uses_both_history_neighbors")
	var scene: RID = pass_instance._texture(rd, SIZE, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var scene_image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	scene_image.fill(Color(0.25, 0.25, 0.25, 1))
	rd.texture_update(scene, 0, scene_image.get_data())
	var sky: RID = pass_instance._texture(rd, SIZE, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var orm_image := Image.create_from_data(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAF, filled(Color(1, 1, 0, 1.0 / 255.0)))
	orm_image.set_pixel(17, 17, Color(1, 1, 0, 0))
	rd.texture_update(inputs[3], 0, orm_image.get_data())
	var history: Array = state.history[state.ping]
	var bindings: Array[RDUniform] = [U.image(0, scene), U.sampled(1, sampler, history[0]), U.sampled(2, sampler, sky),
			U.sampled(3, sampler, inputs[0]), U.sampled(4, sampler, history[2]),
			U.sampled(5, sampler, inputs[1]), U.sampled(6, sampler, history[3]),
			U.sampled(7, sampler, inputs[2]), U.sampled(8, sampler, inputs[3]),
			U.sampled(9, sampler, history[4]), U.uniform_buffer(10, state.ubo)]
	passed = pass_instance._dispatch(rd, pass_instance._diffuse_composite_shader, pass_instance._diffuse_composite_pipeline,
			bindings, SIZE) and passed
	scene_image = Image.create_from_data(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH, rd.texture_get_data(scene, 0))
	check(absf(scene_image.get_pixel(17, 17).r - 0.25) < 0.001
			and scene_image.get_pixel(16, 17).r > 1.0, "composite_preserves_unlit_neighbor")
	rd.free_rid(scene)
	rd.free_rid(sky)
	pass_instance._release_diffuse_state(rd, state)
