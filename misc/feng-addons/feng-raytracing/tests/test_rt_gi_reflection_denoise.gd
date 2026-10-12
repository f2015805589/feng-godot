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

func _close_color(a: Color, b: Color, tolerance: float) -> bool:
	return absf(a.r - b.r) <= tolerance and absf(a.g - b.g) <= tolerance \
			and absf(a.b - b.b) <= tolerance and absf(a.a - b.a) <= tolerance

func _texture(image: Image, format: int) -> RID:
	var texture: RID = backend._texture(SIZE, format)
	if texture.is_valid():
		rd.texture_update(texture, 0, image.get_data())
	return texture

func _guides(roughness: float, boundary: String = "", depth_value: float = 0.5,
		normal_tilt_degrees: float = 0.0) -> Array[RID]:
	var depth := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RF)
	var normal := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	var albedo := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	var orm := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	var emission := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	for y in SIZE.y:
		for x in SIZE.x:
			var right := x >= SIZE.x / 2
			depth.set_pixel(x, y, Color(0.8 if right and boundary == "depth" else depth_value, 0, 0))
			var normal_color := Color(0.5, 0.5, 1.0)
			if normal_tilt_degrees != 0.0:
				var angle := deg_to_rad(normal_tilt_degrees)
				normal_color = Color(0.5 + 0.5 * sin(angle), 0.5, 0.5 + 0.5 * cos(angle))
			elif right and boundary == "normal":
				normal_color = Color(1, 0.5, 0.5)
			normal.set_pixel(x, y, normal_color)
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

func _state_layout() -> void:
	var state: Dictionary = backend.create_state(SIZE)
	var guides := _guides(0.7)
	var camera := Transform3D(Basis.IDENTITY, Vector3(0.125, 0.0, 0.0))
	_resolve(state, guides, "white", 1, camera)
	var bytes := rd.buffer_get_data(state.ubo)
	var layout_ok := bytes.size() == 256 \
			and bytes.slice(48, 64) == PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array() \
			and bytes.decode_float(112) == camera.origin.x \
			and bytes.decode_float(128) == 1.0 \
			and bytes.decode_float(240) == camera.origin.x
	_record("reserved_temporal_ubo_layout", state.valid and layout_ok, bytes.size())
	_record("history_keeps_only_used_state", not state.has("camera") and not state.has("last_seen"), true)
	_release(state, guides)

func _solid_image(color: Color, format: int = Image.FORMAT_RGBAH) -> Image:
	var image := Image.create(SIZE.x, SIZE.y, false, format)
	for y in SIZE.y:
		for x in SIZE.x:
			image.set_pixel(x, y, color)
	return image

func _coverage_candidate() -> void:
	var cases := [
		["miss_publishes_empty_candidate", 0.0, Color(0.0, 0.0, 0.0, -100.0), Color(0.0, 0.0, 0.0, 0.0)],
		["zero_coverage_discards_stray_radiance", 0.0, Color(12.0, 8.0, 4.0, 1.0), Color(0.0, 0.0, 0.0, 0.0)],
		["half_coverage_publishes_premultiplied_candidate", 0.5, Color(1.0, 0.5, 0.25, 1.0), Color(1.0, 0.5, 0.25, 0.5)],
		["full_coverage_publishes_candidate", 1.0, Color(2.0, 1.0, 0.5, 1.0), Color(2.0, 1.0, 0.5, 1.0)],
	]
	var frame := {"camera_transform": Transform3D.IDENTITY, "inverse_projection": Projection.IDENTITY,
			"pre_exposure": 1.0, "scene_normalization": 1.0}
	for case in cases:
		var state: Dictionary = backend.create_state(SIZE)
		var guides := _guides(0.0)
		var raw_image := _solid_image(case[2])
		var coverage_image := _solid_image(Color(case[1], 0.0, 0.0, 1.0), Image.FORMAT_RH)
		var candidate: RID = backend._texture(SIZE, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
		var ready := not state.is_empty() and candidate.is_valid()
		if ready:
			ready = rd.texture_update(state.raw, 0, raw_image.get_data()) == OK \
					and rd.texture_update(state.raw_coverage, 0, coverage_image.get_data()) == OK
		if ready:
			ready = backend.resolve(state, sampler, frame, guides, 1, ["coverage-composite"], {}, 1.0)
		if ready:
			ready = backend.publish_candidate(state, candidate, SIZE)
		var actual := Color(0.0, 0.0, 0.0, 0.0)
		if ready:
			var image := Image.create_from_data(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH,
					rd.texture_get_data(candidate, 0))
			actual = image.get_pixel(SIZE.x / 2, SIZE.y / 2)
		var expected: Color = case[3]
		var matches := ready and _close_color(actual, expected, 0.02)
		_record(case[0], matches, {"ready": ready, "expected": expected,
				"actual": actual, "coverage": case[1]})
		if candidate.is_valid():
			rd.free_rid(candidate)
		_release(state, guides)

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
	for roughness in [0.16, 0.7]:
		var state: Dictionary = backend.create_state(SIZE)
		var guides := _guides(roughness)
		var image: Image
		# Glossy and broad lobes alternate between black sky and bright geometry.
		# The receiver remains fixed, so different legal ray outcomes must converge.
		for generation in range(1, 33):
			image = _resolve(state, guides, "white" if generation % 2 == 1 else "black", generation)
		var value := image.get_pixel(SIZE.x / 2, SIZE.y / 2)
		_record("rough_%0.2f_hit_miss_convergence" % roughness,
				absf(value.r - 1.0) < 0.02 and value.a == 32.0, value)
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

func _upload_mirror_guides(state: Dictionary, coverage: float, valid: bool,
		virtual_hit_position: Vector3 = Vector3.ZERO) -> bool:
	var coverage_image := _solid_image(Color(coverage, 0.0, 0.0, 0.0), Image.FORMAT_RH)
	var virtual_image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAF)
	var guide := Color(virtual_hit_position.x, virtual_hit_position.y,
			virtual_hit_position.z, coverage) if valid else Color(0.0, 0.0, 0.0, 0.0)
	for y in SIZE.y:
		for x in SIZE.x:
			virtual_image.set_pixel(x, y, guide)
	return rd.texture_update(state.raw_coverage, 0, coverage_image.get_data()) == OK \
			and rd.texture_update(state.raw_virtual_hit, 0, virtual_image.get_data()) == OK

func _mirror_virtual_reprojection() -> void:
	var state: Dictionary = backend.create_state(SIZE)
	var guides := _guides(0.0)
	var setup_ok := not state.is_empty() and _upload_mirror_guides(state, 1.0, true)
	var previous := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	if setup_ok:
		previous = _resolve(state, guides, "gradient", 1)
	var current_ok := setup_ok and _upload_mirror_guides(state, 1.0, true)
	var current := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	if current_ok:
		current = _resolve(state, guides, "black", 2,
				Transform3D(Basis.IDENTITY, Vector3(1.0 / SIZE.x, 0.0, 0.0)))
	var old_value := (previous.get_pixel(SIZE.x / 2 - 1, SIZE.y / 2).r
			+ previous.get_pixel(SIZE.x / 2, SIZE.y / 2).r) * 0.5
	var moved_value := current.get_pixel(SIZE.x / 2, SIZE.y / 2)
	var reprojection_ok := current_ok and old_value > 0.0 and moved_value.r > 0.0 \
			and absf(moved_value.r - old_value * 0.5) < 0.15 and moved_value.a == 2.0
	_record("mirror_virtual_point_camera_reprojection", reprojection_ok,
		{"old": old_value, "moved": moved_value})
	_release(state, guides)

	var miss_state: Dictionary = backend.create_state(SIZE)
	var miss_guides := _guides(0.0)
	var miss_setup_ok := not miss_state.is_empty() and _upload_mirror_guides(miss_state, 1.0, true)
	if miss_setup_ok:
		_resolve(miss_state, miss_guides, "gradient", 1)
	var miss_ok := miss_setup_ok and _upload_mirror_guides(miss_state, 0.0, false)
	var miss_image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	if miss_ok:
		miss_image = _resolve(miss_state, miss_guides, "black", 2)
	var miss_value := miss_image.get_pixel(SIZE.x / 2, SIZE.y / 2)
	var miss_coverage_value := -1.0
	var miss_virtual_hit_value := Color(1.0, 1.0, 1.0, 1.0)
	if miss_ok:
		var miss_history: Array = miss_state.history[miss_state.ping]
		var miss_coverage_image := Image.create_from_data(SIZE.x, SIZE.y, false,
				Image.FORMAT_RH, rd.texture_get_data(miss_history[6], 0))
		var miss_virtual_hit_image := Image.create_from_data(SIZE.x, SIZE.y, false,
				Image.FORMAT_RGBAF, rd.texture_get_data(miss_history[7], 0))
		miss_coverage_value = miss_coverage_image.get_pixel(SIZE.x / 2, SIZE.y / 2).r
		miss_virtual_hit_value = miss_virtual_hit_image.get_pixel(SIZE.x / 2, SIZE.y / 2)
	var miss_contract_ok := miss_ok \
			and _close_color(miss_value, Color(0.0, 0.0, 0.0, 1.0), 0.001) \
			and absf(miss_coverage_value) < 0.001 \
			and _close_color(miss_virtual_hit_value, Color(0.0, 0.0, 0.0, 0.0), 0.001)
	_record("mirror_miss_rejects_old_virtual_hit", miss_contract_ok,
			{"radiance_count": miss_value, "coverage": miss_coverage_value,
				"virtual_hit": miss_virtual_hit_value})
	_release(miss_state, miss_guides)

	var changed_hit_state: Dictionary = backend.create_state(SIZE)
	var changed_hit_guides := _guides(0.0)
	var changed_hit_setup := not changed_hit_state.is_empty() \
			and _upload_mirror_guides(changed_hit_state, 1.0, true)
	if changed_hit_setup:
		_resolve(changed_hit_state, changed_hit_guides, "gradient", 1)
	var changed_hit_ready := changed_hit_setup \
			and _upload_mirror_guides(changed_hit_state, 1.0, true, Vector3(0.2, 0.0, 0.0))
	var changed_hit_image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	if changed_hit_ready:
		changed_hit_image = _resolve(changed_hit_state, changed_hit_guides, "black", 2)
	var changed_hit_value := changed_hit_image.get_pixel(SIZE.x / 2, SIZE.y / 2)
	_record("mirror_changed_virtual_point_rejects_history", changed_hit_ready
			and absf(changed_hit_value.r) < 0.001 and changed_hit_value.a == 1.0,
			changed_hit_value)
	_release(changed_hit_state, changed_hit_guides)

	var changed_plane_state: Dictionary = backend.create_state(SIZE)
	var previous_plane_guides := _guides(0.0)
	var changed_plane_setup := not changed_plane_state.is_empty() \
			and _upload_mirror_guides(changed_plane_state, 1.0, true)
	if changed_plane_setup:
		_resolve(changed_plane_state, previous_plane_guides, "gradient", 1)
	for texture in previous_plane_guides:
		rd.free_rid(texture)
	var current_plane_guides := _guides(0.0, "depth")
	var changed_plane_ready := changed_plane_setup \
			and _upload_mirror_guides(changed_plane_state, 1.0, true)
	var changed_plane_image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	if changed_plane_ready:
		changed_plane_image = _resolve(changed_plane_state, current_plane_guides, "black", 2)
	var changed_plane_value := changed_plane_image.get_pixel(SIZE.x / 2, SIZE.y / 2)
	_record("mirror_changed_receiver_plane_rejects_history", changed_plane_ready
			and absf(changed_plane_value.r) < 0.001 and changed_plane_value.a == 1.0,
			changed_plane_value)
	_release(changed_plane_state, current_plane_guides)

	var guide_kind_state: Dictionary = backend.create_state(SIZE)
	var mirror_guides := _guides(0.0)
	var guide_kind_setup := not guide_kind_state.is_empty() \
			and _upload_mirror_guides(guide_kind_state, 1.0, true)
	if guide_kind_setup:
		_resolve(guide_kind_state, mirror_guides, "gradient", 1)
	for texture in mirror_guides:
		rd.free_rid(texture)
	var glossy_guides := _guides(0.03)
	var guide_kind_ready := guide_kind_setup \
			and _upload_mirror_guides(guide_kind_state, 1.0, true)
	var guide_kind_image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	if guide_kind_ready:
		guide_kind_image = _resolve(guide_kind_state, glossy_guides, "black", 2)
	var guide_kind_value := guide_kind_image.get_pixel(SIZE.x / 2, SIZE.y / 2)
	_record("mirror_plane_offset_guide_is_not_ray_distance", guide_kind_ready
			and absf(guide_kind_value.r) < 0.001 and guide_kind_value.a == 1.0,
			guide_kind_value)
	_release(guide_kind_state, glossy_guides)

	var curved_state: Dictionary = backend.create_state(SIZE)
	var previous_curved_guides := _guides(0.0, "", 1.0)
	var curved_setup := not curved_state.is_empty() \
			and _upload_mirror_guides(curved_state, 1.0, true)
	var previous_curved := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	if curved_setup:
		previous_curved = _resolve(curved_state, previous_curved_guides, "gradient", 1)
	for texture in previous_curved_guides:
		rd.free_rid(texture)
	var tilted_guides := _guides(0.0, "", 1.0, 17.0)
	var curved_ready := curved_setup and _upload_mirror_guides(curved_state, 1.0, true)
	var tilted_image := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBAH)
	if curved_ready:
		tilted_image = _resolve(curved_state, tilted_guides, "black", 2)
	# The virtual hit projects to UV (0.5, 0.5), halfway across four history taps.
	var center_x := SIZE.x / 2
	var center_y := SIZE.y / 2
	var previous_bilinear := (
			previous_curved.get_pixel(center_x - 1, center_y - 1).r
			+ previous_curved.get_pixel(center_x, center_y - 1).r
			+ previous_curved.get_pixel(center_x - 1, center_y).r
			+ previous_curved.get_pixel(center_x, center_y).r) * 0.25
	var expected_curved := previous_bilinear * 0.5
	var tilted_value := tilted_image.get_pixel(SIZE.x / 2, SIZE.y / 2)
	_record("mirror_plane_residual_uses_previous_normal", curved_ready
			and absf(tilted_value.r - expected_curved) < 0.15 and tilted_value.a == 2.0,
			{"expected": expected_curved, "actual": tilted_value})
	_release(curved_state, tilted_guides)

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
	# This compute-only fixture skips initialize(), which normally creates it.
	backend.candidate_sampler = sampler
	_state_layout()
	_noise_and_mirror()
	_boundaries()
	_rough_history_convergence()
	_motion()
	_mirror_virtual_reprojection()
	_coverage_candidate()
	rd.free_rid(sampler)
	backend.release()
	done = true
