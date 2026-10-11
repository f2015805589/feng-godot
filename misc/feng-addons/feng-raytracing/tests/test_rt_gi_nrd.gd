extends SceneTree
const Pass = preload("res://addons/feng-raytracing/passes/feng_rt_gi_pass.gd")
const SIZE := Vector2i(64, 64)
var done := false
var passed := true
func _initialize() -> void:
	GDExtensionManager.load_extension("res://addons/feng-raytracing/feng_nrd.gdextension")
	RenderingServer.call_on_render_thread(run)
	for i in 1200:
		await process_frame
		if done:
			quit(0 if passed else 1)
			return
	quit(2)
func check(ok: bool, label: String) -> void:
	passed = passed and ok
	print("NRD_TEST ", label, " ", ok)
func texture(rd: RenderingDevice, color: Color) -> RID:
	var desc := RDTextureFormat.new()
	desc.width = SIZE.x
	desc.height = SIZE.y
	desc.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	desc.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAF)
	image.fill(color)
	return rd.texture_create(desc, RDTextureView.new(), [image.get_data()])
func run() -> void:
	var rd := RenderingServer.get_rendering_device()
	var owner := Pass.new()
	var state := owner._create_diffuse_state(rd, SIZE)
	var projection := Projection.create_perspective(70, 1, 0.1, 100)
	# Convert conventional projection to Vulkan depth and Godot viewport Y.
	projection.y.y *= -1
	for c in 4: projection[c][2] = (projection[c][2] + projection[c][3]) * 0.5
	var clip := projection * Vector4(0, 0, -2, 1)
	var depth := texture(rd, Color(clip.z / clip.w, 0, 0, 0))
	var normal := texture(rd, Color(0.5, 0.5, 1, 0.8))
	var albedo := texture(rd, Color.WHITE)
	var orm := texture(rd, Color(1, 0.8, 0, 1.0 / 255))
	var inputs: Array[RID] = [depth, normal, albedo, orm]
	var sampler := rd.sampler_create(RDSamplerState.new())
	var frame := {"projection": projection, "projection_unjittered": projection,
		"camera_transform": Transform3D.IDENTITY, "camera_generation": 1, "pre_exposure": 1.0, "scene_normalization": 1.0}
	var distances := PackedFloat32Array()
	distances.resize(SIZE.x * SIZE.y)
	distances.fill(2.0)
	rd.texture_update(state.hit_distance, 0, distances.to_byte_array())
	var random := RandomNumberGenerator.new()
	random.seed = 73192
	var raw := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	var success := true
	for generation in range(1, 97):
		# Fixed radiance with sparse 1-spp noise; pre-exposure changes at frame 65.
		frame.pre_exposure = 0.125 if generation >= 65 else 1.0
		for y in SIZE.y:
			for x in SIZE.x:
				var energy := 8.0 if random.randf() < 0.125 else 0.0
				raw.set_pixel(x, y, Color(energy, energy, energy, 1) * frame.pre_exposure)
		rd.texture_update(state.raw, 0, raw.get_data())
		success = owner._resolve_diffuse(rd, sampler, state, frame, inputs, generation, 1, {"strength": 1.0}) and success
	check(success and state.get("denoiser", -1) == 0, "real_relax_dispatches")
	if success:
		var output := Image.create_from_data(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH, rd.texture_get_data(state.resolved, 0))
		var sum := 0.0
		var square := 0.0
		var finite := true
		for y in range(12, 52):
			for x in range(12, 52):
				var value := output.get_pixel(x, y).r / float(frame.pre_exposure)
				finite = finite and is_finite(value)
				sum += value
				square += value * value
		var mean := sum / 1600.0
		var stddev := sqrt(maxf(square / 1600.0 - mean * mean, 0))
		print("NRD_SIGNAL mean=", mean, " std=", stddev)
		check(finite, "finite_output")
		check(absf(mean - 1.0) < 0.12, "radiance_and_exposure_preserved")
		check(stddev < 0.08, "sparse_noise_smoothed")
	owner._release_diffuse_state(rd, state)
	for rid in inputs: rd.free_rid(rid)
	rd.free_rid(sampler)
	done = true
