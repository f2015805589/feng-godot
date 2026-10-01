extends SceneTree
## Deterministic GPU regression for the production TAA and eye-adaptation shaders.
## Run with a Vulkan-capable editor and the imported FRP addon. The TAA source is
## read from this checkout (or FRP_ENGINE_SOURCE_ROOT), not a duplicated test shader.

const SIZE := 16
var rd: RenderingDevice
var owned: Array[RID] = []
var taa_has_exposure_ratio := false
var failed := false

func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)
		quit(1)
		assert(value, message)

func _initialize() -> void:
	call_deferred("run")

func keep(rid: RID) -> RID:
	require(rid.is_valid(), "GPU resource creation failed")
	owned.append(rid)
	return rid

func shader_file(path: String) -> RID:
	var text := FileAccess.get_file_as_string(path)
	require(text.contains("#version"), "cannot read shader: " + path)
	var source := RDShaderSource.new()
	source.source_compute = text.substr(text.find("#version")).replace("#VERSION_DEFINES", "")
	var spirv := rd.shader_compile_spirv_from_source(source)
	require(spirv.compile_error_compute.is_empty(), spirv.compile_error_compute)
	return keep(rd.shader_create_from_spirv(spirv))

func texture(format: int, width: int, height: int, data: PackedByteArray) -> RID:
	var descriptor := RDTextureFormat.new()
	descriptor.format = format
	descriptor.width = width
	descriptor.height = height
	descriptor.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return keep(rd.texture_create(descriptor, RDTextureView.new(), [data]))

func uniform(kind: int, binding: int, ids: Array[RID]) -> RDUniform:
	var value := RDUniform.new()
	value.uniform_type = kind
	value.binding = binding
	for rid in ids:
		value.add_id(rid)
	return value

func color_texture(exposure: float) -> RID:
	var pixels := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBAF)
	for y in SIZE:
		for x in SIZE:
			var c := Vector3(0.12 + float((x + y) % 3) * 0.3, 0.08 + float((x * 2 + y) % 4) * 0.12, 0.04 + float((x + y * 3) % 5) * 0.08) * exposure
			pixels.set_pixel(x, y, Color(c.x, c.y, c.z, 1.0))
	pixels.convert(Image.FORMAT_RGBAH)
	return texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, SIZE, SIZE, pixels.get_data())

func run_taa(shader: RID, pipeline: RID, current: RID, history: RID, depth: RID, velocity: RID, sampler: RID, ratio: float) -> Image:
	var blank := PackedByteArray()
	blank.resize(SIZE * SIZE * 8)
	var output := texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, SIZE, SIZE, blank)
	var bindings: Array[RDUniform] = [
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [current]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [sampler, depth]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [velocity]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 3, [velocity]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [sampler, history]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 5, [output]),
	]
	var set := keep(rd.uniform_set_create(bindings, shader, 0))
	var push_values := PackedFloat32Array([SIZE, SIZE, 2.5, 1.0])
	if taa_has_exposure_ratio:
		push_values.append_array(PackedFloat32Array([ratio, 0.0, 0.0, 0.0]))
	var push := push_values.to_byte_array()
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(SIZE) / 8.0), ceili(float(SIZE) / 8.0), 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	return Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBAH, rd.texture_get_data(output, 0))

func image_error(a: Image, b: Image, exposure: float) -> float:
	var result := 0.0
	for y in SIZE:
		for x in SIZE:
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			for channel in 3:
				require(is_finite(ca[channel]) and is_finite(cb[channel]), "TAA generated non-finite HDR color")
				result = maxf(result, absf(ca[channel] - cb[channel]) / exposure)
	return result

func taa_fixture() -> Dictionary:
	var root_path := OS.get_environment("FRP_ENGINE_SOURCE_ROOT")
	if root_path.is_empty():
		root_path = get_script().resource_path.get_base_dir().path_join("../../..").simplify_path()
	var shader_path := root_path.path_join("servers/rendering/renderer_rd/shaders/effects/taa_resolve.glsl")
	taa_has_exposure_ratio = FileAccess.get_file_as_string(shader_path).contains("float history_exposure_ratio;")
	var shader := shader_file(shader_path)
	var pipeline := keep(rd.compute_pipeline_create(shader))
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	var sampler := keep(rd.sampler_create(sampler_state))
	var depths := PackedFloat32Array()
	depths.resize(SIZE * SIZE)
	depths.fill(1.0)
	var depth := texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, SIZE, SIZE, depths.to_byte_array())
	var zeros := PackedByteArray()
	zeros.resize(SIZE * SIZE * 4)
	var velocity := texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, SIZE, SIZE, zeros)
	return {"shader": shader, "pipeline": pipeline, "sampler": sampler, "depth": depth, "velocity": velocity}

func resolve_fixture(fixture: Dictionary, current: RID, history: RID, ratio: float) -> Image:
	return run_taa(fixture.shader, fixture.pipeline, current, history, fixture.depth, fixture.velocity, fixture.sampler, ratio)

func check_taa_rebase() -> void:
	var fixture := taa_fixture()
	var history := color_texture(1.0)
	for exposure in [1.0 / 32.0, 1.0, 32.0]:
		var current := color_texture(exposure)
		var reference := resolve_fixture(fixture, current, current, 1.0)
		var rebased := resolve_fixture(fixture, current, history, exposure)
		var error := image_error(reference, rebased, exposure)
		require(error < 0.004, "history rebase changed color at exposure %f: %f" % [exposure, error])
		if exposure != 1.0:
			var wrong_scale := resolve_fixture(fixture, current, history, 1.0)
			require(image_error(reference, wrong_scale, exposure) > 0.02, "TAA exposure test was vacuous")
	if failed:
		return
	print("PASS GPU TAA rebases colored HDR history before clipping in both exposure directions")

func check_adaptation() -> void:
	var path := OS.get_environment("FRP_EYE_ADAPTATION_SHADER")
	if path.is_empty():
		path = "res://addons/feng-render-pipeline/library/eye-adaptation/eye_adaptation.glsl"
	var shader := shader_file(path)
	var pipeline := keep(rd.compute_pipeline_create(shader))
	var sampler := keep(rd.sampler_create(RDSamplerState.new()))
	var placeholder := texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, 1, 1, PackedFloat32Array([1.0]).to_byte_array())
	var output := texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, 1, 1, PackedFloat32Array([0.0]).to_byte_array())
	for direction in [-1.0, 1.0]:
		for speed in [1.0, 3.0, 100.0]:
			for dt in [0.0, 1.0 / 60.0, 0.25, 2.0]:
				var target_ev: float = direction
				var values := PackedByteArray()
				values.resize(64 * 8 + 16)
				values.encode_u32(0, 524288)
				values.encode_float(64 * 8, 1.0)
				values.encode_float(64 * 8 + 4, 1.0)
				var state := keep(rd.storage_buffer_create(values.size(), values))
				var set0 := keep(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [state])], shader, 0))
				var set1 := keep(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [sampler, placeholder])], shader, 1))
				var set2 := keep(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [output])], shader, 2))
				var push := PackedFloat32Array([
					log(0.18) / log(2.0) + target_ev, 0.0, 0.0001, 1048576.0,
					0.0, 1.0, speed, speed, dt, 1.0, 1.0, 0.0,
					0.0, 0.0, 0.0, 1.0,
				]).to_byte_array()
				var list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(list, pipeline)
				rd.compute_list_bind_uniform_set(list, set0, 0)
				rd.compute_list_bind_uniform_set(list, set1, 1)
				rd.compute_list_bind_uniform_set(list, set2, 2)
				rd.compute_list_set_push_constant(list, push, push.size())
				rd.compute_list_dispatch(list, 1, 1, 1)
				rd.compute_list_end()
				rd.submit()
				rd.sync()
				var adapted := rd.buffer_get_data(state).decode_float(64 * 8)
				var actual_ev := log(adapted) / log(2.0)
				require(is_finite(actual_ev) and actual_ev >= minf(0.0, target_ev) - 0.0001 and actual_ev <= maxf(0.0, target_ev) + 0.0001,
						"exposure overshot target EV: target=%f speed=%f dt=%f actual=%f" % [target_ev, speed, dt, actual_ev])
	if failed:
		return
	print("PASS GPU eye adaptation stays between prior and target EV after long frames")

func solid_color_texture(color: Color) -> RID:
	var pixels := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBAF)
	pixels.fill(color)
	pixels.convert(Image.FORMAT_RGBAH)
	return texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, SIZE, SIZE, pixels.get_data())

func check_hdr_recovery() -> void:
	var fixture := taa_fixture()
	var finite := color_texture(1.0)
	var reference := resolve_fixture(fixture, finite, finite, 1.0)
	for invalid in [INF, NAN]:
		var bad_history := solid_color_texture(Color(invalid, invalid, invalid, 1.0))
		var recovered := resolve_fixture(fixture, finite, bad_history, 1.0)
		var invalid_pixels := 0
		var max_error := 0.0
		for y in SIZE:
			for x in SIZE:
				var color := recovered.get_pixel(x, y)
				var expected := reference.get_pixel(x, y)
				for channel in 3:
					if not is_finite(color[channel]):
						invalid_pixels += 1
					else:
						max_error = maxf(max_error, absf(color[channel] - expected[channel]))
		print("HDR history=", invalid, " invalid_channels=", invalid_pixels, " max_error=", max_error)
		require(invalid_pixels == 0 and max_error < 0.004, "one invalid HDR history frame contaminated later finite TAA colors")
	if failed:
		return
	print("PASS GPU TAA recovers finite colored frames from invalid HDR history")

func histogram_for_texture(shader: RID, pipeline: RID, sampler: RID, source: RID) -> PackedByteArray:
	var zeros := PackedByteArray()
	zeros.resize(64 * 8 + 16)
	var state := keep(rd.storage_buffer_create(zeros.size(), zeros))
	var set0 := keep(rd.uniform_set_create([
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [sampler, source]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [sampler, source]),
	], shader, 0))
	var set1 := keep(rd.uniform_set_create([uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [state])], shader, 1))
	var push := PackedInt32Array([SIZE, SIZE]).to_byte_array() + PackedFloat32Array([
		-10.0, 1.0 / 30.0, 1.0, pow(2.0, -10.0), 0.0, 0.0, 0.0, 0.0,
	]).to_byte_array()
	# Stock Godot 4.6 reflects a vec2-led block rounded up to 16 bytes.
	# The current Feng reflection retains the exact 40-byte declared size.
	if int(Engine.get_version_info().minor) <= 6:
		push.resize(48)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set0, 0)
	rd.compute_list_bind_uniform_set(list, set1, 1)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	return rd.buffer_get_data(state)

func histogram_for_color(shader: RID, pipeline: RID, sampler: RID, color: Color) -> PackedByteArray:
	return histogram_for_texture(shader, pipeline, sampler, solid_color_texture(color))

func check_hdr_histogram() -> void:
	var path := OS.get_environment("FRP_HISTOGRAM_SHADER")
	if path.is_empty():
		path = "res://addons/feng-render-pipeline/library/eye-adaptation/eye_adaptation_histogram.glsl"
	var shader := shader_file(path)
	var pipeline := keep(rd.compute_pipeline_create(shader))
	var sampler := keep(rd.sampler_create(RDSamplerState.new()))
	var expected_weight := SIZE * SIZE * 524288
	for invalid in [INF, -INF, NAN]:
		var data := histogram_for_color(shader, pipeline, sampler, Color(invalid, 1.0, 0.1, 1.0))
		var bright_weight := data.decode_u32(63 * 4)
		var total_weight := 0
		for bin in 64:
			total_weight += data.decode_u32(bin * 4)
		print("HDR source=", invalid, " brightest-bin weight=", bright_weight, " total=", total_weight)
		if invalid == INF:
			require(bright_weight == expected_weight, "positive FP16 overflow was not metered as bright radiance")
		else:
			require(total_weight == 0, "NaN/negative infinity incorrectly contributed to exposure")
	# Finite HDR must retain the exact fractional-bin metering rather than being
	# clamped, discarded, or promoted to the overflow bin by the new guard.
	var finite := Color(1024.0, 16.0, 4.0, 1.0)
	var finite_data := histogram_for_color(shader, pipeline, sampler, finite)
	var location := (log((finite.r + finite.g + finite.b) / 3.0) / log(2.0) + 10.0) / 30.0 * 63.0
	var lower := int(floor(location))
	var expected_upper := int(float(expected_weight) * fposmod(location, 1.0))
	require(absi(finite_data.decode_u32((lower + 1) * 4) - expected_upper) < 2048, "finite HDR histogram weights changed")
	require(finite_data.decode_u32(63 * 4) == 0, "finite HDR was incorrectly classified as overflow")
	if not failed:
		print("PASS GPU exposure histogram handles positive overflow, rejects invalid data and preserves finite HDR")

func check_hdr_current() -> void:
	var fixture := taa_fixture()
	var finite_history := color_texture(1.0)
	var overflow := solid_color_texture(Color(INF, 1.0, 0.1, 1.0))
	var resolved := resolve_fixture(fixture, overflow, finite_history, 1.0)
	var finite_limit := solid_color_texture(Color(65504.0, 1.0, 0.1, 1.0))
	var reference := resolve_fixture(fixture, finite_limit, finite_history, 1.0)
	var invalid_channels := 0
	var finite_reference_error := 0.0
	for y in SIZE:
		for x in SIZE:
			var color := resolved.get_pixel(x, y)
			for channel in 3:
				if not is_finite(color[channel]):
					invalid_channels += 1
				else:
					finite_reference_error = maxf(finite_reference_error, absf(color[channel] - reference.get_pixel(x, y)[channel]))
	var shader := shader_file("res://addons/feng-render-pipeline/library/eye-adaptation/eye_adaptation_histogram.glsl")
	var pipeline := keep(rd.compute_pipeline_create(shader))
	var sampler := keep(rd.sampler_create(RDSamplerState.new()))
	var output := texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, SIZE, SIZE, resolved.get_data())
	var data := histogram_for_texture(shader, pipeline, sampler, output)
	var bright_weight := 0
	for bin in range(45, 64):
		bright_weight += data.decode_u32(bin * 4)
	print("HDR current overflow through TAA: invalid_channels=", invalid_channels, " bright-weight=", bright_weight)
	require(invalid_channels == 0, "current HDR overflow became invalid during TAA")
	require(finite_reference_error < 0.004, "overflow repair changed unaffected finite color components")
	require(bright_weight > SIZE * SIZE * 524288 - 2048, "TAA-to-histogram chain lost bright overflow samples")
	var zero_component := solid_color_texture(Color(0.0, 1.0, 0.1, 1.0))
	var zero_reference := resolve_fixture(fixture, zero_component, finite_history, 1.0)
	for invalid in [-INF, NAN]:
		var invalid_current := solid_color_texture(Color(invalid, 1.0, 0.1, 1.0))
		var repaired := resolve_fixture(fixture, invalid_current, finite_history, 1.0)
		require(image_error(repaired, zero_reference, 1.0) < 0.004, "current NaN/negative infinity repair changed finite components")
	if not failed:
		print("PASS GPU current HDR overflow stays finite and bright through TAA and metering")

func run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	require(rd != null, "a native RenderingDevice is required")
	var mode := OS.get_environment("FRP_EXPOSURE_SHADER_TEST")
	if mode == "hdr_current":
		check_hdr_current()
	elif mode == "hdr_recovery":
		check_hdr_recovery()
	elif mode == "hdr_histogram":
		check_hdr_histogram()
	else:
		if mode != "adaptation":
			check_taa_rebase()
		if not failed and mode != "taa":
			check_adaptation()
		if not failed and mode.is_empty():
			check_hdr_recovery()
		if not failed and mode.is_empty():
			check_hdr_histogram()
		if not failed and mode.is_empty():
			check_hdr_current()
	for i in range(owned.size() - 1, -1, -1):
		rd.free_rid(owned[i])
	rd.free()
	if failed:
		quit(1)
	else:
		print("PASS FRP GPU exposure history rebasing and bounded adaptation")
		quit(0)
