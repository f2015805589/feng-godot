extends "frp_exposure_history.gd"
## GPU regressions for bright moving sun pixels through the production post shaders.
## Run as --script with a Vulkan-capable editor. FRP_ENGINE_SOURCE_ROOT selects
## the checkout, allowing the same fixtures to demonstrate the unpatched failure.

func check(value: bool, message: String) -> bool:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)
	return value

func source_root() -> String:
	var path := OS.get_environment("FRP_ENGINE_SOURCE_ROOT")
	if path.is_empty():
		path = get_script().resource_path.get_base_dir().path_join("../../..").simplify_path()
	return path

func velocity_texture(value: Vector2) -> RID:
	var pixels := Image.create(SIZE, SIZE, false, Image.FORMAT_RGH)
	pixels.fill(Color(value.x, value.y, 0.0, 1.0))
	return texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, SIZE, SIZE, pixels.get_data())

func resolve_motion(fixture: Dictionary, current: RID, history: RID, velocity: Vector2, previous_velocity: Vector2, ratio := 1.0, float_output := false) -> Image:
	var blank := PackedByteArray()
	blank.resize(SIZE * SIZE * (16 if float_output else 8))
	var output_format := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT if float_output else RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var output := texture(output_format, SIZE, SIZE, blank)
	var current_velocity: RID = fixture.get("gradient_velocity", RID())
	if not current_velocity.is_valid():
		current_velocity = velocity_texture(velocity)
	var bindings: Array[RDUniform] = [
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [current]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [fixture.sampler, fixture.depth]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [current_velocity]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 3, [velocity_texture(previous_velocity)]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [fixture.sampler, history]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 5, [output]),
	]
	var set := keep(rd.uniform_set_create(bindings, fixture.shader, 0))
	var observe_velocity := 1.0 if fixture.get("observe_velocity", false) else 0.0
	var push := PackedFloat32Array([SIZE, SIZE, 2.5, 1.0, ratio, observe_velocity, 0.0, 0.0]).to_byte_array()
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, fixture.pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(SIZE) / 8.0), ceili(float(SIZE) / 8.0), 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	return Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBAF if float_output else Image.FORMAT_RGBAH, rd.texture_get_data(output, 0))

func taa_float_output_fixture() -> Dictionary:
	var fixture := taa_fixture()
	var path := source_root().path_join("servers/rendering/renderer_rd/shaders/effects/taa_resolve.glsl")
	var text := FileAccess.get_file_as_string(path)
	var source := RDShaderSource.new()
	# Preserve all production arithmetic; change only the output storage format
	# so drivers that saturate half stores cannot hide a pre-store overflow.
	source.source_compute = text.substr(text.find("#version")).replace("#VERSION_DEFINES", "").replace(
			"layout(rgba16f, set = 0, binding = 5)", "layout(rgba32f, set = 0, binding = 5)")
	var spirv := rd.shader_compile_spirv_from_source(source)
	require(spirv.compile_error_compute.is_empty(), spirv.compile_error_compute)
	fixture.shader = keep(rd.shader_create_from_spirv(spirv))
	fixture.pipeline = keep(rd.compute_pipeline_create(fixture.shader))
	return fixture

func closest_velocity_fixture() -> Dictionary:
	var fixture := taa_fixture()
	var path := source_root().path_join("servers/rendering/renderer_rd/shaders/effects/taa_resolve.glsl")
	var text := FileAccess.get_file_as_string(path)
	# Observe the production helper with the production main's coordinates.
	# A runtime uniform selects observation so all original bindings survive
	# reflection. No depth, coordinate or velocity math is duplicated here.
	var observation := """
	if (params.pad0 != 0.0) {
		vec2 selected_velocity;
		get_closest_pixel_velocity_3x3(pos_group, pos_group_top_left, selected_velocity);
		result = vec3(selected_velocity, 0.0);
	}
"""
	var output_line := "\timageStore(output_buffer, ivec2(gl_GlobalInvocationID.xy), vec4(result, 1.0));"
	require(text.contains(output_line), "production TAA output site changed")
	text = text.replace(output_line, observation + output_line)
	var source := RDShaderSource.new()
	source.source_compute = text.substr(text.find("#version")).replace("#VERSION_DEFINES", "")
	var spirv := rd.shader_compile_spirv_from_source(source)
	require(spirv.compile_error_compute.is_empty(), spirv.compile_error_compute)
	fixture.shader = keep(rd.shader_create_from_spirv(spirv))
	fixture.pipeline = keep(rd.compute_pipeline_create(fixture.shader))
	fixture.observe_velocity = true
	return fixture

func check_closest_velocity() -> void:
	var fixture := closest_velocity_fixture()
	var encoded := Image.create(SIZE, SIZE, false, Image.FORMAT_RGH)
	for y in SIZE:
		for x in SIZE:
			# Nonzero and exactly representable, including every border pixel.
			encoded.set_pixel(x, y, Color(float(x + 1) / 32.0, float(y + 1) / 32.0, 0.0, 1.0))
	fixture.gradient_velocity = texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, SIZE, SIZE, encoded.get_data())
	var current := solid_color_texture(Color(0.25, 0.5, 1.0, 1.0))
	for direction in [0, 1, -1]:
		var depths := PackedFloat32Array()
		depths.resize(SIZE * SIZE)
		for y in SIZE:
			for x in SIZE:
				depths[y * SIZE + x] = 1.0 if direction == 0 else 0.5 + float(direction * (y * SIZE + x)) / float(4 * SIZE * SIZE)
		fixture.depth = texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, SIZE, SIZE, depths.to_byte_array())
		var result := resolve_motion(fixture, current, current, Vector2.ZERO, Vector2.ZERO)
		# Start with an interior workgroup boundary to expose the exact (-1,-1)
		# shift separately from device-dependent out-of-bounds imageLoad values.
		var positions: Array[Vector2i] = [Vector2i(8, 8)]
		for y in SIZE:
			for x in SIZE:
				positions.append(Vector2i(x, y))
		for pos in positions:
			var selected: Vector2i = (pos - Vector2i.ONE * int(direction)).clamp(Vector2i.ZERO, Vector2i(SIZE - 1, SIZE - 1))
			var expected := encoded.get_pixelv(selected)
			var actual := result.get_pixelv(pos)
			if not check(actual.r == expected.r and actual.g == expected.g,
					"closest velocity coordinates differ: depth_direction=%d pixel=%s selected=%s actual=%s expected=%s" % [direction, pos, selected, actual, expected]):
				return
	print("PASS GPU TAA closest velocity matches its selected depth texel across workgroups and all viewport borders")

func check_bright_motion() -> void:
	var fixture := taa_fixture()
	var bright := solid_color_texture(Color(65504.0, 32.0, 0.25, 1.0))
	# Velocity disocclusion selects the current frame even when its reprojected
	# UV is in bounds. FP32 Reinhard inversion formerly produced 65535 here,
	# which overflows the RGBA16F output although the input was finite.
	var disoccluded := resolve_motion(fixture, bright, bright, Vector2.ZERO, Vector2(16.0, 0.0))
	for y in SIZE:
		for x in SIZE:
			var color := disoccluded.get_pixel(x, y)
			if not check(is_finite(color.r) and color.r >= 65000.0, "finite FP16 sun overflowed during disocclusion at %s: %s" % [Vector2i(x, y), color]):
				return
	var float_fixture := taa_float_output_fixture()
	var pre_store := resolve_motion(float_fixture, bright, bright, Vector2.ZERO, Vector2(16.0, 0.0), 1.0, true)
	for y in SIZE:
		for x in SIZE:
			var color := pre_store.get_pixel(x, y)
			if not check(is_finite(color.r) and color.r >= 65000.0 and color.r <= 65504.0, "TAA arithmetic exceeded FP16 range before storage at %s: %s" % [Vector2i(x, y), color]):
				return
	print("PASS GPU TAA keeps maximum finite HDR sun representable before and after FP16 storage")
	# An off-screen history sample must return the current frame, even if the
	# clamped history texture happens to contain an unrelated bright color.
	var current := color_texture(1.0)
	var expected := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBAH, rd.texture_get_data(current, 0))
	for motion in [Vector2(2.0, 0.0), Vector2(-2.0, 0.0), Vector2(0.0, 2.0), Vector2(0.0, -2.0)]:
		var resolved := resolve_motion(fixture, current, bright, motion, motion)
		if not check(image_error(resolved, expected, 1.0) < 0.00001, "out-of-screen history still influenced the current pixel for motion %s" % motion):
			return
	print("PASS GPU TAA rejects off-screen history before temporal blending")
	# The engine limits pre-exposure to [1e-12, 1e12], so this ratio reaches its
	# actual finite worst case without inventing a non-finite uniform value.
	var rebased := resolve_motion(fixture, current, bright, Vector2.ZERO, Vector2.ZERO, 1e24)
	image_error(rebased, rebased, 1.0)
	print("PASS GPU TAA remains finite at the engine's maximum exposure rebase ratio")

func grade_fixture() -> Dictionary:
	var path := source_root().path_join("misc/feng-addons/feng-render-pipeline/library/color-grade/color_grade.glsl")
	var shader := shader_file(path)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return {"shader": shader, "pipeline": keep(rd.compute_pipeline_create(shader)), "sampler": keep(rd.sampler_create(sampler_state))}

func run_grade(fixture: Dictionary, pixels: Image, grade: Vector4) -> Image:
	pixels.convert(Image.FORMAT_RGBAH)
	# Color Grade's real pass binds the same color attachment for input/output.
	var target := texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, SIZE, SIZE, pixels.get_data())
	var bindings: Array[RDUniform] = [
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [fixture.sampler, target]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [target]),
	]
	var set := keep(rd.uniform_set_create(bindings, fixture.shader, 0))
	var push := PackedFloat32Array([grade.x, grade.y, grade.z, grade.w]).to_byte_array()
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, fixture.pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(SIZE) / 8.0), ceili(float(SIZE) / 8.0), 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	return Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBAH, rd.texture_get_data(target, 0))

func grade_reference(c: Color, grade: Vector4) -> Color:
	var rgb := Vector3(c.r, c.g, c.b) * grade.z
	rgb = (rgb - Vector3.ONE * 0.5) * grade.y + Vector3.ONE * 0.5
	var luma := rgb.dot(Vector3(0.299, 0.587, 0.114))
	rgb = Vector3.ONE * luma * (1.0 - grade.x) + rgb * grade.x
	for channel in 3:
		rgb[channel] = minf(pow(maxf(rgb[channel], 0.0), 1.0 / maxf(grade.w, 1e-5)), 65504.0)
	return Color(rgb.x, rgb.y, rgb.z, c.a)

func check_color_grade(invalid_only := false) -> void:
	var fixture := grade_fixture()
	var parameter_cases := [] if invalid_only else [Vector4.ONE, Vector4(0.65, 1.1, 0.75, 1.2), Vector4(1.0, 1.0, 2.0, 1.0)]
	for parameters in parameter_cases:
		var finite := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBAF)
		for y in SIZE:
			for x in SIZE:
				finite.set_pixel(x, y, Color(65504.0 if x == 0 else float(x) * 0.25, float(y) * 0.5, 0.25, 0.5))
		finite.convert(Image.FORMAT_RGBAH)
		var resolved := run_grade(fixture, finite, parameters)
		for y in SIZE:
			for x in SIZE:
				var actual := resolved.get_pixel(x, y)
				var expected := grade_reference(finite.get_pixel(x, y), parameters)
				if parameters == Vector4.ONE and not check(actual == finite.get_pixel(x, y), "neutral Color Grade changed a finite HDR texel: %s vs %s" % [actual, finite.get_pixel(x, y)]):
					return
				for channel in 3:
					if not check(is_finite(actual[channel]), "finite HDR became invalid in Color Grade: %s" % actual):
						return
					if not check(absf(actual[channel] - expected[channel]) <= maxf(0.002, expected[channel] * 0.002), "finite Color Grade behavior changed: %s vs %s" % [actual, expected]):
						return
				if not check(actual.a == 0.5, "Color Grade changed alpha"):
					return
	if not invalid_only:
		print("PASS GPU Color Grade preserves finite grading and FP16 output representability")
	for invalid in [INF, -INF, NAN]:
		var pixels := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBAF)
		pixels.fill(Color(0.25, 1.0, 0.125, 0.5))
		pixels.set_pixel(SIZE / 2, SIZE / 2, Color(invalid, 1.0, 0.125, 0.5))
		var resolved := run_grade(fixture, pixels, Vector4.ONE)
		for y in SIZE:
			for x in SIZE:
				var color := resolved.get_pixel(x, y)
				if not check(is_finite(color.r) and is_finite(color.g) and is_finite(color.b), "overflowed sun produced invalid graded color: %s" % color):
					return
				if not check(color.g == 1.0 and color.b == 0.125 and color.a == 0.5, "one invalid HDR component contaminated unaffected channels at %s: source=%s actual=%s" % [Vector2i(x, y), invalid, color]):
					return
				var at_sun := x == SIZE / 2 and y == SIZE / 2
				var expected_red := (65504.0 if invalid == INF else 0.0) if at_sun else 0.25
				if not check(color.r == expected_red, "invalid sun component mismatch at %s: source=%s actual=%s expected_red=%s" % [Vector2i(x, y), invalid, color, expected_red]):
					return
	print("PASS GPU Color Grade repairs only invalid HDR channels without spreading black pixels")

func run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	require(rd != null, "a native RenderingDevice is required")
	var mode := OS.get_environment("FRP_HDR_SUN_TEST")
	if mode == "velocity" or mode.is_empty():
		check_closest_velocity()
	if not failed and not mode.begins_with("grade") and mode != "velocity":
		check_bright_motion()
	if not failed and mode != "taa" and mode != "velocity":
		check_color_grade(mode == "grade_invalid")
	for i in range(owned.size() - 1, -1, -1):
		rd.free_rid(owned[i])
	rd.free()
	if failed:
		quit(1)
	else:
		print("PASS FRP GPU moving HDR sun and post-process stability")
		quit(0)
