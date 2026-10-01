extends SceneTree
## Numerical input checks run headlessly. -- --gpu additionally dispatches the
## production sky shader as float32 compute work and reads values before any
## tone mapper or half-float target can hide NaN/Inf as a black pixel.
const FengSkyAtmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const OpticalLut = preload("res://addons/feng-sky/feng_sky_optical_lut.gd")
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
	# GDScript smoothstep treats approximately equal edges as equal; use the
	# mathematical double-precision reference without that epsilon shortcut.
	var outer := cos(radius * 1.15)
	var inner := cos(radius * 0.85)
	var t := clampf((cos(angle) - outer) / (inner - outer), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


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
	uint offset = index * 8;
	POSITION = rays[offset].xyz;
	sun_angular_radius_deg = rays[offset].w;
	EYEDIR = normalize(rays[offset + 1].xyz);
	mie_asymmetry = rays[offset + 1].w;
	sun_direction = normalize(rays[offset + 2].xyz);
	sun_irradiance = rays[offset + 2].w;
	sun_color_linear = rays[offset + 3].xyz;
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
	float legacy_disk = smoothstep(cos(radius * 1.15), cos(radius * 0.85), dot(EYEDIR, sun_direction));
	values[index * 3 + 1] = vec4(raw_scattering, legacy_disk);
	values[index * 3 + 2] = vec4(transmission, entry_distance);
}
"""


func make_gpu_inputs(settings: Dictionary, use_lut: bool) -> Dictionary:
	var rays := PackedFloat32Array()
	var expected_masks := PackedFloat32Array()
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
		for radius_deg in [0.01, 0.02, 0.2666, 2.0]:
			for angle_fraction in [0.0, 0.84, 0.85, 1.0, 1.15, 1.16, 2.0, 10000.0]:
				var angle := minf(deg_to_rad(radius_deg) * angle_fraction, PI)
				var view := (sun * cos(angle) + tangent * sin(angle)).normalized()
				var color := Vector3.ONE if motion_index % 2 == 0 else Vector3(1.0, 0.2, 0.05)
				var beta: Vector3 = settings["rayleigh_scattering_per_km"]
				rays.append_array(PackedFloat32Array([
					camera.x, camera.y, camera.z, radius_deg,
					view.x, view.y, view.z, [-0.95, 0.0, 0.95][motion_index % 3],
					sun.x, sun.y, sun.z, [0.0, 60000.0, 10000000.0][motion_index % 3],
					color.x, color.y, color.z, 60000.0 if motion_index % 2 == 0 else 6000.0,
					settings["planet_radius_km"], settings["atmosphere_height_km"], settings["rayleigh_scale_height_km"], settings["mie_scale_height_km"],
					beta.x, beta.y, beta.z, settings["mie_scattering_per_km"],
					settings["mie_extinction_per_km"], 1.0 if use_lut else 0.0, 0.0, 0.0,
					0.1, 0.1, 0.1, 0.0,
				]))
				expected_masks.append(reference_disk_weight(deg_to_rad(radius_deg), angle))
	return {"rays": rays, "expected_masks": expected_masks}


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
	var count := expected_masks.size()
	var input_buffer := rd.storage_buffer_create(rays.size() * 4, rays.to_byte_array())
	var output_buffer := rd.storage_buffer_create(count * 12 * 4)
	var image := OpticalLut.make_image(settings)
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	format.width = image.get_width()
	format.height = image.get_height()
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var texture := rd.texture_create(format, RDTextureView.new(), [image.get_data()])
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
	var legacy_disk_failures := 0
	for index in count:
		for component in 12:
			var value := output[index * 12 + component]
			if component != 7 and not is_finite(value):
				bad_values += 1
			if component < 3 and (value < 0.0 or value > rays[index * 32 + 15]):
				bad_values += 1
			if component >= 8 and component <= 10 and (value < 0.0 or value > 1.0):
				bad_values += 1
		maximum_mask_error = maxf(maximum_mask_error, absf(output[index * 12 + 3] - expected_masks[index]))
		var legacy_disk := output[index * 12 + 7]
		if not is_finite(legacy_disk) or absf(legacy_disk - expected_masks[index]) >= 0.002:
			legacy_disk_failures += 1
	require(bad_values == 0, "production sky produced non-finite/out-of-domain radiance or transmission")
	# Direction vectors are float32: their angular precision is finite even
	# with stable mask edges. 0.2% allows rounding at the smallest disk's edge.
	require(maximum_mask_error < 0.002, "production solar mask changed angular profile: %s" % maximum_mask_error)
	require(legacy_disk_failures > 0, "GPU fixture did not reproduce the previous cosine-disk failure")
	print("SKY NUMERICS GPU rays=", count, " lut=", use_lut,
		" profile=", OpticalLut.geometry_signature(settings), " bad_values=", bad_values,
		" max_disk_weight_error=", maximum_mask_error, " legacy_disk_failures=", legacy_disk_failures)
	for resource in [uniform_set, sampler, texture, output_buffer, input_buffer]:
		rd.free_rid(resource)
