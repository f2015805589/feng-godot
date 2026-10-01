extends SceneTree
## Numerical input checks run headlessly. -- --gpu additionally dispatches the
## production sky shader as float32 compute work and reads values before any
## tone mapper or half-float target can hide NaN/Inf as a black pixel.
const FengSkyAtmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const MultiScatteringLut = preload("res://addons/feng-sky/feng_sky_multiscattering_lut.gd")
const OpticalLut = preload("res://addons/feng-sky/feng_sky_optical_lut.gd")
const FengSkyTransport = preload("res://addons/feng-sky/feng_sky_transport.gd")
var _failed := false


func _initialize() -> void:
	call_deferred("run")


func require(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("REGRESSION: " + message)


func require_vec3_near(actual: Vector3, expected: Vector3, tolerance: float, message: String) -> void:
	require(actual.distance_to(expected) <= tolerance, message)


func run() -> void:
	run_solar_input_checks()
	test_float32_disk_edges()
	if "--gpu" in OS.get_cmdline_user_args():
		run_gpu_checks()
	if not _failed:
		print("SKY NUMERICS PASS")
	quit(1 if _failed else 0)


func run_solar_input_checks() -> void:
	for direction in [Vector3.ZERO, Vector3(NAN, 1.0, 0.0), Vector3(INF, 0.0, 0.0)]:
		require(FengSkyRuntime.sanitize_sun_direction(direction) == Vector3.UP,
			"invalid solar direction did not use the finite zenith fallback")
	for magnitude in [1.0e-30, 1.0, 1.0e30]:
		var direction := FengSkyRuntime.sanitize_sun_direction(Vector3(1.0, 2.0, 3.0) * magnitude)
		require_vec3_near(direction, Vector3(1.0, 2.0, 3.0).normalized(), 0.000001,
			"finite solar transform normalization overflowed or underflowed")
	var reference := FengSkyRuntime.compute_atmosphere_sample({}, Vector3.UP, 1.0, Vector3.ONE)
	var fallback := FengSkyRuntime.compute_atmosphere_sample({}, Vector3(NAN, 0.0, 0.0), 1.0, Vector3.ONE)
	require_vec3_near(fallback["ambient_radiance"], reference["ambient_radiance"], 0.000001,
		"invalid solar direction contaminated the CPU scattering integration")
	for invalid in [NAN, INF, -INF]:
		var sample := FengSkyRuntime.compute_atmosphere_sample({}, Vector3.UP, invalid, Vector3.ONE)
		require(sample["ambient_radiance"] == Vector3.ZERO and sample["sun_ground_illuminance"] == Vector3.ZERO,
			"non-finite irradiance did not disable the solar source")
		var invalid_color := FengSkyRuntime.compute_atmosphere_sample({}, Vector3.UP, 1.0, Vector3(invalid, 1.0, 1.0))
		require(invalid_color["ambient_radiance"] == Vector3.ZERO,
			"non-finite solar color contaminated the CPU scattering integration")
	var provider := FengSkyAtmosphere.new()
	var sun := DirectionalLight3D.new()
	for invalid in [NAN, INF, -INF]:
		sun.light_energy = invalid
		require(provider._sun_irradiance(sun) == 0.0, "non-finite authored light energy reached the sky")
	sun.light_energy = 1.0
	sun.light_color = Color(NAN, 1.0, 1.0)
	require(provider._sun_linear_color(sun) == Vector3.ZERO, "non-finite authored light color reached the sky")
	sun.light_color = Color.WHITE
	if bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
		for invalid in [NAN, INF, -INF]:
			sun.light_intensity_lux = invalid
			require(provider._sun_irradiance(sun) == 0.0, "non-finite authored lux reached the sky")
	sun.free()
	provider.free()


func float32(value: float) -> float:
	return PackedFloat32Array([value])[0]


func reference_disk_weight(radius: float, angle: float) -> float:
	if radius <= 0.0:
		return 0.0
	if radius < 0.00001:
		var inner_chord := 2.0 * sin(radius * 0.425)
		var outer_chord := 2.0 * sin(radius * 0.575)
		var chord := 2.0 * sin(angle * 0.5)
		var t := clampf((chord * chord - inner_chord * inner_chord) /
			(outer_chord * outer_chord - inner_chord * inner_chord), 0.0, 1.0)
		return 1.0 - t * t * (3.0 - 2.0 * t)
	# GDScript smoothstep treats approximately equal edges as equal; use the
	# mathematical double-precision reference without that epsilon shortcut.
	var outer := cos(radius * 1.15)
	var inner := cos(radius * 0.85)
	var t := clampf((cos(angle) - outer) / (inner - outer), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func reference_disk_weight_from_directions(radius: float, view: Vector3, sun: Vector3) -> float:
	if radius <= 0.0:
		return 0.0
	var inner_chord := 2.0 * sin(radius * 0.425)
	var outer_chord := 2.0 * sin(radius * 0.575)
	var chord := view - sun
	var t := clampf((chord.length_squared() - inner_chord * inner_chord) /
		(outer_chord * outer_chord - inner_chord * inner_chord), 0.0, 1.0)
	return 1.0 - t * t * (3.0 - 2.0 * t)


func test_float32_disk_edges() -> void:
	# Reproduce the original singularity, rather than only testing double
	# precision GDScript math, which never rounded these two edges together.
	for radius_deg in [0.01, 0.02]:
		var radius := float32(deg_to_rad(radius_deg))
		var original_inner := float32(cos(float32(radius * float32(0.85))))
		var original_outer := float32(cos(float32(radius * float32(1.15))))
		require(original_inner == original_outer, "fixture no longer reproduces collapsed float32 cosine edges")
	for radius_deg in [0.01, 0.02, 0.03, 0.2666, 2.0]:
		var radius := float32(deg_to_rad(radius_deg))
		var inner_chord := float32(2.0 * float32(sin(float32(radius * float32(0.425)))))
		var outer_chord := float32(2.0 * float32(sin(float32(radius * float32(0.575)))))
		var inner := float32(inner_chord * inner_chord)
		var outer := float32(outer_chord * outer_chord)
		require(outer > inner and inner > 0.0, "squared chord disk edges must stay ordered and finite")
		for sample_index in 101:
			var angle := deg_to_rad(radius_deg) * float(sample_index) / 50.0
			var chord := float32(2.0 * float32(sin(float32(angle * 0.5))))
			var t := clampf(float32(float32(chord * chord - inner) / float32(outer - inner)), 0.0, 1.0)
			var actual := 1.0 - t * t * (3.0 - 2.0 * t)
			var reference := reference_disk_weight(deg_to_rad(radius_deg), angle)
			require(is_finite(actual) and absf(actual - reference) < 0.00001,
				"stable float32 disk changed the intended angular profile")


func gpu_source() -> String:
	# Reuse the production functions and sky() verbatim. Only replace the engine
	# uniform/builtin declarations with compute inputs; no CPU reimplementation.
	var source := FileAccess.get_file_as_string(FengSkyRuntime.ATMOSPHERE_SHADER_PATH)
	source = source.replace("shader_type sky;", "")
	source = source.replace("uniform sampler2D optical_column_lut : filter_linear, repeat_disable;",
		"layout(set = 0, binding = 2) uniform sampler2D optical_column_lut;")
	source = source.replace("uniform sampler2D multi_scattering_lut : filter_linear, repeat_disable;",
		"layout(set = 0, binding = 3) uniform sampler2D multi_scattering_lut;")
	var declarations := RegEx.new()
	declarations.compile("(?m)^uniform (float|vec3|bool) ")
	source = declarations.sub(source, "$1 ", true)
	return """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(push_constant, std430) uniform Params { uvec4 counts; } params;
layout(set = 0, binding = 0, std430) readonly buffer InputData { vec4 rays[]; };
layout(set = 0, binding = 1, std430) writeonly buffer OutputData { vec4 values[]; };
const float PI = 3.14159265358979323846;
vec3 POSITION;
vec3 EYEDIR;
vec3 COLOR;
""" + source + """
void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= params.counts.x) { return; }
	uint offset = index * 13;
	POSITION = rays[offset].xyz;
	sun_angular_radius_deg = rays[offset].w;
	EYEDIR = normalize(rays[offset + 1].xyz);
	mie_asymmetry = rays[offset + 1].w;
	sun_direction = normalize(rays[offset + 2].xyz);
	sun_irradiance = rays[offset + 2].w;
	sun_color_linear = rays[offset + 3].xyz;
	sun_disk_color_scale = vec3(0.5, 0.25, 1.0);
	sky_radiance_limit = rays[offset + 3].w;
	planet_radius_km = rays[offset + 4].x;
	atmosphere_height_km = rays[offset + 4].y;
	rayleigh_scale_height_km = rays[offset + 4].z;
	mie_scale_height_km = rays[offset + 4].w;
	rayleigh_scattering_per_km = rays[offset + 5].xyz;
	mie_scattering_per_km = rays[offset + 5].w;
	mie_extinction_per_km = rays[offset + 6].x;
	use_optical_column_lut = rays[offset + 6].y > 0.0;
	ground_albedo = rays[offset + 7].xyz;
	mie_scattering_coefficients = rays[offset + 8].xyz;
	mie_extinction_coefficients = rays[offset + 9].xyz;
	absorption_extinction_per_km = rays[offset + 10].xyz;
	absorption_density_layer_width_km = rays[offset + 11].x;
	absorption_layer0_linear_term = rays[offset + 11].y;
	absorption_layer0_constant_term = rays[offset + 11].z;
	absorption_layer1_linear_term = rays[offset + 11].w;
	absorption_layer1_constant_term = rays[offset + 12].x;
	multi_scattering_factor = rays[offset + 12].y;
	trace_sample_count_scale = rays[offset + 12].z;
	use_multi_scattering_lut = rays[offset + 12].w > 0.0;
	planet_center_m = vec3(0.0, -1000.0 * planet_radius_km, 0.0);
	sky();
	values[index * 3] = vec4(COLOR, solar_disk_weight(EYEDIR, sun_direction, radians(sun_angular_radius_deg)));
	vec3 origin = (POSITION - planet_center_m) / 1000.0;
	origin = normalize(origin) * max(length(origin), planet_radius_km + 0.001);
	vec3 transmission;
	float ground_distance;
	float entry_distance;
	vec3 raw_scattering = integrate_atmosphere(origin, EYEDIR, transmission, ground_distance, entry_distance);
	float radius = radians(sun_angular_radius_deg);
	// Diagnostic control reproduces the previous float32 implementation.
	float legacy_disk = radius > 0.0 ? smoothstep(cos(radius * 1.15), cos(radius * 0.85), dot(EYEDIR, sun_direction)) : 0.0;
	values[index * 3 + 1] = vec4(raw_scattering, legacy_disk);
	values[index * 3 + 2] = vec4(transmission, solar_disk_solid_angle(radians(sun_angular_radius_deg)));
}
"""


func make_gpu_inputs(settings: Dictionary, use_lut: bool) -> Dictionary:
	var rays := PackedFloat32Array()
	var expected_masks := PackedFloat32Array()
	var expected_solid_angles := PackedFloat32Array()
	var cameras := [Vector3(0.0, 1.0, 0.0), Vector3(150.0, 20.0, -100.0),
		Vector3(0.0, 80000.0, 0.0), Vector3(100000.0, 60000.0, -100000.0)]
	var elevations := [-15.0, -1.0, 0.0, 1.0, 15.0, 45.0, 89.9, 90.0]
	for motion_index in 64:
		var elevation := deg_to_rad(elevations[motion_index % elevations.size()])
		var azimuth := deg_to_rad(float(motion_index) * 137.0)
		var sun := Vector3(cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth)).normalized()
		var tangent := sun.cross(Vector3.FORWARD).normalized()
		var camera: Vector3 = cameras[(motion_index / 8) % cameras.size()]
		# Translation and rotation change together to cover the reported motion
		# case, including ground-adjacent, horizon and orbital camera positions.
		camera += Vector3(float(motion_index), float(motion_index % 3), -float(motion_index))
		for radius_deg in [0.0, 0.000001, 0.01, 0.02, 0.2666, 2.0]:
			for angle_fraction in [0.0, 0.84, 0.85, 1.0, 1.15, 1.16, 2.0, 10000.0]:
				var angle := minf(deg_to_rad(radius_deg) * angle_fraction, PI)
				var view := (sun * cos(angle) + tangent * sin(angle)).normalized()
				var color := Vector3.ONE if motion_index % 2 == 0 else Vector3(1.0, 0.2, 0.05)
				var beta: Vector3 = settings["rayleigh_scattering_per_km"]
				var mie: Vector3 = settings["mie_scattering_coefficients"]
				var extinction: Vector3 = settings["mie_extinction_coefficients"]
				var absorption: Vector3 = settings["absorption_extinction_per_km"]
				var irradiance: float = [0.0, 18.8495559215, 10000000.0][motion_index % 3]
				if motion_index == 5:
					irradiance = 0.01 # Keep one tinted disk sample below the HDR cap.
				rays.append_array(PackedFloat32Array([
					camera.x, camera.y, camera.z, radius_deg,
					view.x, view.y, view.z, [-0.95, 0.0, 1.0][motion_index % 3],
				sun.x, sun.y, sun.z, irradiance,
					color.x, color.y, color.z, 60000.0 if motion_index % 2 == 0 else 6000.0,
					settings["planet_radius_km"], settings["atmosphere_height_km"], settings["rayleigh_scale_height_km"], settings["mie_scale_height_km"],
					beta.x, beta.y, beta.z, settings["mie_scattering_per_km"],
					settings["mie_extinction_per_km"], 1.0 if use_lut else 0.0, 0.0, 0.0,
					0.1, 0.1, 0.1, 0.0,
					mie.x, mie.y, mie.z, 0.0,
					extinction.x, extinction.y, extinction.z, 0.0,
					absorption.x, absorption.y, absorption.z, 0.0,
					settings["absorption_density_layer_width_km"], settings["absorption_layer0_linear_term"], settings["absorption_layer0_constant_term"], settings["absorption_layer1_linear_term"],
					settings["absorption_layer1_constant_term"], settings["multi_scattering_factor"], settings["trace_sample_count_scale"], 1.0,
				]))
				var gpu_view := Vector3(float32(view.x), float32(view.y), float32(view.z)).normalized()
				var gpu_sun := Vector3(float32(sun.x), float32(sun.y), float32(sun.z)).normalized()
				expected_masks.append(reference_disk_weight_from_directions(deg_to_rad(radius_deg), gpu_view, gpu_sun))
				expected_solid_angles.append(FengSkyTransport.solar_disk_solid_angle(deg_to_rad(radius_deg)))
	return {"rays": rays, "expected_masks": expected_masks, "expected_solid_angles": expected_solid_angles}


func run_gpu_checks() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		require(false, "--gpu requires a RenderingDevice driver; headless dummy rendering cannot run this probe")
		return
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = gpu_source()
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	if not spirv.compile_error_compute.is_empty():
		require(false, "production sky compute compilation: " + spirv.compile_error_compute)
		rd.free()
		return
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var default_settings := FengSkyRuntime.sanitize_atmosphere_settings({})
	for use_lut in [false, true]:
		dispatch_gpu_checks(rd, shader, pipeline, default_settings, use_lut)
	for settings in [
		{"planet_radius_km": 6000.0, "atmosphere_height_km": 120.0, "rayleigh_scale_height_km": 1.0, "mie_scale_height_km": 0.1,
			"rayleigh_scattering_per_km": Vector3.ONE, "mie_scattering_per_km": 1.0, "mie_extinction_per_km": 1.0},
		{"planet_radius_km": 7000.0, "atmosphere_height_km": 1.0, "rayleigh_scale_height_km": 30.0, "mie_scale_height_km": 0.1,
			"rayleigh_scattering_per_km": Vector3.ZERO, "mie_scattering_per_km": 0.0, "mie_extinction_per_km": 0.0},
	]:
		dispatch_gpu_checks(rd, shader, pipeline, FengSkyRuntime.sanitize_atmosphere_settings(settings), false)
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	rd.free()


func dispatch_gpu_checks(rd: RenderingDevice, shader: RID, pipeline: RID, settings: Dictionary, use_lut: bool) -> void:
	var inputs := make_gpu_inputs(settings, use_lut)
	var rays: PackedFloat32Array = inputs["rays"]
	var expected_masks: PackedFloat32Array = inputs["expected_masks"]
	var expected_solid_angles: PackedFloat32Array = inputs["expected_solid_angles"]
	var count := expected_masks.size()
	var input_buffer := rd.storage_buffer_create(rays.size() * 4, rays.to_byte_array())
	var output_buffer := rd.storage_buffer_create(count * 12 * 4)
	var image := OpticalLut.make_image(settings)
	image.convert(Image.FORMAT_RGBAF)
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.width = image.get_width()
	format.height = image.get_height()
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var texture := rd.texture_create(format, RDTextureView.new(), [image.get_data()])
	var multi_image := MultiScatteringLut.make_image(settings)
	multi_image.convert(Image.FORMAT_RGBAF)
	var multi_format := RDTextureFormat.new()
	multi_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	multi_format.width = multi_image.get_width()
	multi_format.height = multi_image.get_height()
	multi_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var multi_texture := rd.texture_create(multi_format, RDTextureView.new(), [multi_image.get_data()])
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	var sampler := rd.sampler_create(sampler_state)
	var uniforms: Array[RDUniform] = []
	for binding in 2:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(input_buffer if binding == 0 else output_buffer)
		uniforms.append(uniform)
	var lut_uniform := RDUniform.new()
	lut_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	lut_uniform.binding = 2
	lut_uniform.add_id(sampler)
	lut_uniform.add_id(texture)
	uniforms.append(lut_uniform)
	var multi_uniform := RDUniform.new()
	multi_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	multi_uniform.binding = 3
	multi_uniform.add_id(sampler)
	multi_uniform.add_id(multi_texture)
	uniforms.append(multi_uniform)
	var uniform_set := rd.uniform_set_create(uniforms, shader, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, PackedInt32Array([count, 0, 0, 0]).to_byte_array(), 16)
	rd.compute_list_dispatch(list, ceili(float(count) / 64.0), 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var output := rd.buffer_get_data(output_buffer).to_float32_array()
	var bad_values := 0
	var maximum_mask_error := 0.0
	var maximum_mask_error_sample := ""
	var legacy_disk_failures := 0
	var first_bad_sample := ""
	for index in count:
		for component in 12:
			var value := output[index * 12 + component]
			if component != 7 and not is_finite(value):
				bad_values += 1
				if first_bad_sample.is_empty():
					first_bad_sample = "index=%d component=%d value=%s" % [index, component, value]
			if component < 3 and (value < 0.0 or value > rays[index * 52 + 15]):
				bad_values += 1
				if first_bad_sample.is_empty():
					first_bad_sample = "index=%d component=%d value=%s cap=%s" % [index, component, value, rays[index * 52 + 15]]
			if component >= 8 and component <= 10 and (value < 0.0 or value > 1.0):
				bad_values += 1
				if first_bad_sample.is_empty():
					first_bad_sample = "index=%d component=%d transmission=%s" % [index, component, value]
		var radius_deg := rays[index * 52 + 3]
		if radius_deg >= 0.01:
			var mask_error := absf(output[index * 12 + 3] - expected_masks[index])
			if mask_error > maximum_mask_error:
				maximum_mask_error = mask_error
				maximum_mask_error_sample = "index=%d radius=%s mask=%s expected=%s" % [index, radius_deg, output[index * 12 + 3], expected_masks[index]]
		var actual_solid_angle := output[index * 12 + 11]
		var expected_solid_angle := expected_solid_angles[index]
		if expected_solid_angle == 0.0:
			if actual_solid_angle != 0.0:
				bad_values += 1
				if first_bad_sample.is_empty():
					first_bad_sample = "index=%d radius=%s solid_angle=%s expected=0" % [index, radius_deg, actual_solid_angle]
		elif not is_finite(actual_solid_angle) or actual_solid_angle <= 0.0 or absf(actual_solid_angle - expected_solid_angle) > maxf(expected_solid_angle * 0.001, 1.0e-20):
			bad_values += 1
			if first_bad_sample.is_empty():
				first_bad_sample = "index=%d radius=%s solid_angle=%s expected=%s" % [index, radius_deg, actual_solid_angle, expected_solid_angle]
		var legacy_disk := output[index * 12 + 7]
		if radius_deg >= 0.01 and radius_deg <= 0.02 and (not is_finite(legacy_disk) or absf(legacy_disk - expected_masks[index]) >= 0.002):
			legacy_disk_failures += 1
	require(bad_values == 0, "production sky produced non-finite/out-of-domain radiance, transmission or solid angle")
	# Direction vectors are float32: their angular precision is finite even
	# with stable mask edges. 0.2% allows rounding at the smallest disk's edge.
	require(maximum_mask_error < 0.002, "production solar mask changed angular profile: %s" % maximum_mask_error)
	require(legacy_disk_failures > 0, "GPU fixture did not reproduce the previous cosine-disk failure")
	var default_sun_start := 4 * 6 * 8 # 15 degree sun, finite test irradiance, center ray.
	var zero_disk_color := Vector3(output[default_sun_start * 12], output[default_sun_start * 12 + 1], output[default_sun_start * 12 + 2])
	var zero_disk_scattering := Vector3(output[default_sun_start * 12 + 4], output[default_sun_start * 12 + 5], output[default_sun_start * 12 + 6])
	var zero_disk_limit := rays[default_sun_start * 52 + 15]
	require(output[default_sun_start * 12 + 3] == 0.0
		and zero_disk_color.distance_to(zero_disk_scattering.clamp(Vector3.ZERO, Vector3.ONE * zero_disk_limit)) < 0.001,
		"zero source angle must remove only the explicit disk while retaining atmosphere scattering")
	var tiny_disk_index := default_sun_start + 8
	var tiny_disk_color := Vector3(output[tiny_disk_index * 12], output[tiny_disk_index * 12 + 1], output[tiny_disk_index * 12 + 2])
	var tiny_disk_scattering := Vector3(output[tiny_disk_index * 12 + 4], output[tiny_disk_index * 12 + 5], output[tiny_disk_index * 12 + 6])
	require((tiny_disk_color - tiny_disk_scattering).length() > 0.1,
		"a positive microscopic source angle lost its finite explicit disk")
	var tinted_disk_index := 5 * 6 * 8 + 4 * 8 # Nonwhite source light, tinted disk, below the radiance cap.
	var tinted_disk_color := Vector3(output[tinted_disk_index * 12], output[tinted_disk_index * 12 + 1], output[tinted_disk_index * 12 + 2])
	var tinted_disk_scattering := Vector3(output[tinted_disk_index * 12 + 4], output[tinted_disk_index * 12 + 5], output[tinted_disk_index * 12 + 6])
	var tinted_disk_transmission := Vector3(output[tinted_disk_index * 12 + 8], output[tinted_disk_index * 12 + 9], output[tinted_disk_index * 12 + 10])
	var tinted_disk_light_color := Vector3(rays[tinted_disk_index * 52 + 12], rays[tinted_disk_index * 52 + 13], rays[tinted_disk_index * 52 + 14])
	var tinted_disk_irradiance := rays[tinted_disk_index * 52 + 11]
	var tinted_disk_solid_angle := output[tinted_disk_index * 12 + 11]
	var expected_tinted_disk_radiance := tinted_disk_light_color * tinted_disk_irradiance * Vector3(0.5, 0.25, 1.0) / tinted_disk_solid_angle
	var has_tinted_disk_transmission := tinted_disk_transmission.x > 0.001 and tinted_disk_transmission.y > 0.001 and tinted_disk_transmission.z > 0.001
	var measured_tinted_disk_radiance := Vector3.ZERO
	if has_tinted_disk_transmission:
		measured_tinted_disk_radiance = (tinted_disk_color - tinted_disk_scattering) / tinted_disk_transmission
	require(has_tinted_disk_transmission
		and measured_tinted_disk_radiance.distance_to(expected_tinted_disk_radiance) < maxf(expected_tinted_disk_radiance.length() * 0.01, 0.001),
		"sun disk must preserve source light RGB and multiply only its independent RGB tint")
	print("SKY NUMERICS GPU rays=", count, " lut=", use_lut,
		" profile=", OpticalLut.geometry_signature(settings), " bad_values=", bad_values,
		" first_bad=", first_bad_sample, " max_disk_weight_error=", maximum_mask_error,
		" mask_sample=", maximum_mask_error_sample, " legacy_disk_failures=", legacy_disk_failures)
	for resource in [uniform_set, sampler, texture, multi_texture, output_buffer, input_buffer]:
		rd.free_rid(resource)
