extends SceneTree
## GPU readbacks exercise denoising, reprojection and boundary preservation.
const ReflectionRenderer = preload("res://addons/feng-raytracing/rendering/rt_gi_reflections.gd")
const SIZE := Vector2i(32, 16)
var done := false
var passed := true
var rd: RenderingDevice
var backend
var sampler := RID()

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	if RenderingServer.get_rendering_device() == null:
		push_error("Reflection denoising acceptance requires RenderingDevice")
		quit(1)
		return
	RenderingServer.call_on_render_thread(execute)
	for frame_index in 1800:
		await process_frame
		if done:
			break
	print("RTGI_REFLECTION_DENOISE_TEST ", passed and done)
	quit(0 if passed and done else 1)

func _record(label: String, success: bool, detail: Variant) -> void:
	passed = passed and success
	print("RTGI_REFLECTION_DENOISE_CASE ", label, " ", success, " ", detail)

func _texture(image: Image, format: int) -> RID:
	var texture: RID = backend._texture(SIZE, format)
	if texture.is_valid():
		rd.texture_update(texture, 0, image.get_data())
	return texture

func _guides(roughness: float, boundary: String = "") -> Array[RID]:
	var depth := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RF)
	var normal := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	var albedo := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	var orm := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	var emission := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	for y in SIZE.y:
		for x in SIZE.x:
			var right := x >= SIZE.x / 2
			depth.set_pixel(x, y, Color(0.8 if right and boundary == "depth" else 0.5, 0, 0))
			normal.set_pixel(x, y, Color(1, 0.5, 0.5) if right and boundary == "normal" else Color(0.5, 0.5, 1))
			albedo.set_pixel(x, y, Color(0.1, 0.1, 0.1) if right and boundary == "albedo" else Color(0.7, 0.7, 0.7))
			orm.set_pixel(x, y, Color(1, roughness, 1.0 if right and boundary == "metallic" else 0.5, 1.0 / 255.0))
			emission.set_pixel(x, y, Color(0, 0, 0, 0.8 if right and boundary == "specular" else 0.5))
	return [_texture(depth, RenderingDevice.DATA_FORMAT_R32_SFLOAT),
			_texture(normal, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT),
			_texture(albedo, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT),
			_texture(orm, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT),
			_texture(emission, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)]

func _raw(pattern: String) -> Image:
	var image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	for y in SIZE.y:
		for x in SIZE.x:
			var value := 0.0
			var hit := 1.0
			if pattern in ["noise", "mirror"]:
				value = 2.0 if (x + y) % 2 == 0 else 0.0
				if pattern == "noise" and value == 0.0:
					hit = -100.0
			elif pattern == "edge":
				value = 100.0 if x >= SIZE.x / 2 else 1.0
			elif pattern == "gradient":
				value = float(x + 1)
			elif pattern == "black":
				hit = -100.0
			elif pattern == "white":
				value = 2.0
			image.set_pixel(x, y, Color(value, value, value, hit))
	return image

func _resolve(state: Dictionary, guides: Array[RID], pattern: String, generation: int,
		camera: Transform3D = Transform3D.IDENTITY, cut: bool = false) -> Image:
	var upload_ok := rd.texture_update(state.raw, 0, _raw(pattern).get_data()) == OK
	var frame := {"camera_transform": camera, "inverse_projection": Projection.IDENTITY,
			"pre_exposure": 1.0, "scene_normalization": 1.0, "camera_cut": cut}
	var resolved: bool = upload_ok and backend.resolve(state, sampler, frame, guides, generation,
			["denoise-test"], {"history_weight": 0.97}, 1.0)
	if not resolved:
		passed = false
		return Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	return Image.create_from_data(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH,
			rd.texture_get_data(state.history[state.ping][0], 0))

func _release(state: Dictionary, guides: Array[RID]) -> void:
	backend.release_state(state)
	for texture in guides:
		rd.free_rid(texture)

func _noise_and_mirror() -> void:
	for pattern in ["noise", "mirror"]:
		var state: Dictionary = backend.create_state(SIZE)
		var guides := _guides(0.7 if pattern == "noise" else 0.0)
		var image := _resolve(state, guides, pattern, 1)
		var raw := _raw(pattern)
		var sum := 0.0
		var squared_error := 0.0
		var maximum_change := 0.0
		var count := 0
		for y in range(2, SIZE.y - 2):
			for x in range(2, SIZE.x - 2):
				var value := image.get_pixel(x, y).r
				sum += value
				squared_error += (value - 1.0) * (value - 1.0)
				maximum_change = maxf(maximum_change, absf(value - raw.get_pixel(x, y).r))
				count += 1
		var rmse := sqrt(squared_error / count)
		var mean := sum / count
		_record(pattern, (rmse < 0.15 and absf(mean - 1.0) < 0.02) if pattern == "noise"
				else maximum_change < 0.001, {"rmse": rmse, "mean": mean, "maximum_change": maximum_change})
		_release(state, guides)

func _boundaries() -> void:
	for boundary in ["depth", "normal", "metallic", "specular", "albedo"]:
		var state: Dictionary = backend.create_state(SIZE)
		var guides := _guides(0.7, boundary)
		var image := _resolve(state, guides, "edge", 1)
		var left := image.get_pixel(SIZE.x / 2 - 1, SIZE.y / 2).r
		var right := image.get_pixel(SIZE.x / 2, SIZE.y / 2).r
		_record(boundary + "_boundary", absf(left - 1.0) < 0.01 and absf(right - 100.0) < 0.1, [left, right])
		_release(state, guides)

func _rough_history_convergence() -> void:
	var state: Dictionary = backend.create_state(SIZE)
	var guides := _guides(0.7)
	var image: Image
	# A broad lobe alternates between black sky and a bright geometry hit. Its
	# primary surface stays fixed, so both ray outcomes must contribute to history.
	for generation in range(1, 33):
		image = _resolve(state, guides, "white" if generation % 2 == 1 else "black", generation)
	var value := image.get_pixel(SIZE.x / 2, SIZE.y / 2)
	_record("rough_hit_miss_convergence", absf(value.r - 1.0) < 0.01 and value.a == 32.0, value)
	_release(state, guides)

func _motion() -> void:
	for case in ["rough", "mirror", "camera_cut", "disocclusion", "bilinear_depth"]:
		var state: Dictionary = backend.create_state(SIZE)
		var guides := _guides(0.0 if case == "mirror" else 0.7, "depth" if case == "bilinear_depth" else "")
		var previous := _resolve(state, guides, "edge" if case == "bilinear_depth" else "gradient", 1)
		if case in ["disocclusion", "bilinear_depth"]:
			for texture in guides:
				rd.free_rid(texture)
			guides = _guides(0.7, "depth" if case == "disocclusion" else "")
		var movement := Transform3D(Basis.IDENTITY, Vector3((1.0 if case == "bilinear_depth" else 2.0) / SIZE.x, 0, 0))
		var image := _resolve(state, guides, "black", 2, movement, case == "camera_cut")
		var x: int = SIZE.x / 2 - 1 if case == "bilinear_depth" else SIZE.x / 2
		var value := image.get_pixel(x, SIZE.y / 2)
		var expected := previous.get_pixel(x + 1, SIZE.y / 2).r * 0.5 if case == "rough" else 0.0
		if case == "bilinear_depth":
			expected = 0.5
		_record(case + "_motion", absf(value.r - expected) < 0.02
				and value.a == (2.0 if case in ["rough", "bilinear_depth"] else 1.0), [value, expected])
		_release(state, guides)

func execute() -> void:
	rd = RenderingServer.get_rendering_device()
	backend = ReflectionRenderer.new()
	backend.rd = rd
	if not backend._create_compute_pipelines():
		_record("initialize", false, backend.error)
		backend.release()
		done = true
		return
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler = rd.sampler_create(sampler_state)
	_noise_and_mirror()
	_boundaries()
	_rough_history_convergence()
	_motion()
	rd.free_rid(sampler)
	backend.release()
	done = true
