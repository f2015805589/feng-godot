extends SceneTree

# Execute the exact compact SH2 layout-7 sampler and apply implementation on a local GPU.
# A constant E/pi tensor is independent of the receiver normal. Clearing its
# x=1 plane leaves 0.75 valid trilinear support at x=0.25, without changing the
# normalized lighting. Coverage is cache support, not remaining physical Sky.
const LIBRARY := "res://addons/feng-render-pipeline/library/magic-gi/"
const INCIDENT := Vector3(0.25, 0.5, 1.0)
const SKY := Vector3(2.0, 4.0, 6.0)
const OTHER_AMBIENT := Vector3(0.1, 0.2, 0.3)
const ALBEDO := Vector3(0.8, 0.6, 0.4)
const AO := 0.7
const DIFFUSE_AO := 0.9
const NORMALIZATION := 1.5
const TOLERANCE := 0.00005

var checks := 0
var failures := 0
var rd: RenderingDevice
var shader := RID()
var pipeline := RID()
var resources: Array[RID] = []

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func run() -> void:
	rd = RenderingServer.create_local_rendering_device()
	check(rd != null, "Prepared CLV sky ownership requires a RenderingDevice.")
	if rd == null:
		_finish()
		return
	var source := RDShaderSource.new()
	source.source_compute = _shader_source()
	var spirv := rd.shader_compile_spirv_from_source(source)
	check(spirv.compile_error_compute.is_empty(),
			"Production prepared CLV shader must compile: " + spirv.compile_error_compute)
	if not spirv.compile_error_compute.is_empty():
		_finish()
		return
	shader = _own(rd.shader_create_from_spirv(spirv, "Prepared CLV Sky Ownership Regression"))
	pipeline = _own(rd.compute_pipeline_create(shader))
	check(shader.is_valid() and pipeline.is_valid(), "Prepared CLV pipeline must be valid.")
	if not shader.is_valid() or not pipeline.is_valid():
		_finish()
		return
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	var sampler := _own(rd.sampler_create(sampler_state))
	var output := _own(rd.storage_buffer_create(32))
	var set0 := _own(rd.uniform_set_create([
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER, 0, sampler),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, output),
	], shader, 0))
	var parameters := _own(rd.uniform_buffer_create(96, _parameters()))
	var owner := _own(rd.uniform_buffer_create(96, _owner(1.0, true)))
	var dummy := _own(rd.storage_buffer_create(16, PackedFloat32Array([0, 0, 0, 0]).to_byte_array()))
	var textures := {
		"full": _texture("full"),
		"partial": _texture("partial"),
		"empty": _texture("empty"),
		"black": _texture("black"),
	}
	var sets: Dictionary = {}
	for name: String in textures:
		var texture: RID = textures[name]
		sets[name] = _own(rd.uniform_set_create([
			_uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, 69, texture),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 76, parameters),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 77, owner),
			# These declarations belong to the other layout specialization. Extra
			# supplied bindings are harmless if the compiler optimizes them away.
			_uniform(RenderingDevice.UNIFORM_TYPE_TEXTURE, 87, texture),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 88, dummy),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 89, dummy),
		], shader, 1))
	var query := Vector3(0.25, 0.5, 0.5)
	var cases := [
		_case("full strength 1", "full", query, 1.0, true, 1.0),
		_case("full strength 0.5", "full", query, 0.5, true, 1.0),
		_case("partial strength 1", "partial", query, 1.0, true, 0.75),
		_case("partial strength 0.5", "partial", query, 0.5, true, 0.75),
		_case("valid black replaces sky", "black", query, 1.0, true, 1.0),
		_case("empty support preserves ambient", "empty", query, 1.0, false, 0.0),
		_case("insufficient support preserves ambient", "partial", Vector3(0.75, 0.5, 0.5), 1.0, false, 0.25),
		_case("outside atlas preserves ambient", "full", Vector3(2.0, 0.5, 0.5), 1.0, false, 0.0),
		_case("outside owner preserves ambient", "full", Vector3(20.0, 0.5, 0.5), 1.0, false, 0.0),
		_case("explicit additive mode keeps sky", "partial", query, 1.0, true, 0.75, false),
	]
	for test: Dictionary in cases:
		check(rd.buffer_update(owner, 0, 96, _owner(test.strength, test.replace_sky)) == OK,
				test.label + ": owner upload")
		var position: Vector3 = test.world
		var push := PackedFloat32Array([position.x, position.y, position.z, 0]).to_byte_array()
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, set0, 0)
		rd.compute_list_bind_uniform_set(list, sets[test.texture], 1)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, 1, 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var values := rd.buffer_get_data(output).to_float32_array()
		check(values.size() == 8, test.label + ": complete GPU output")
		if values.size() != 8:
			continue
		var hit := values[7] > 0.5
		var incident := Vector3(values[0], values[1], values[2])
		var ambient := Vector3(values[4], values[5], values[6])
		check(hit == bool(test.hit), test.label + ": sample validity")
		var expected := SKY + OTHER_AMBIENT
		if bool(test.hit):
			var expected_incident := Vector3.ZERO if test.texture == "black" else INCIDENT
			check(absf(values[3] - float(test.coverage)) < TOLERANCE,
					test.label + ": hardware filtered support must be " + str(test.coverage))
			check(incident.distance_to(expected_incident) < TOLERANCE,
					test.label + ": normalize missing taps exactly once; got " + str(incident))
			if bool(test.replace_sky):
				expected -= SKY * float(test.strength)
			expected += expected_incident * ALBEDO * AO * DIFFUSE_AO * NORMALIZATION * float(test.strength)
		check(ambient.distance_to(expected) < TOLERANCE,
				test.label + ": sky ownership must follow strength, not tap coverage; expected "
				+ str(expected) + ", got " + str(ambient))
		print("PREPARED_CLV_SKY_CASE ", test.label, " hit=", hit,
				" coverage=", values[3], " incident=", incident, " ambient=", ambient)
	_finish()

func _case(label: String, texture: String, world: Vector3, strength: float,
		hit: bool, coverage: float, replace_sky := true) -> Dictionary:
	return {"label": label, "texture": texture, "world": world, "strength": strength,
		"hit": hit, "coverage": coverage, "replace_sky": replace_sky}

func _shader_source() -> String:
	var tensor := FileAccess.get_file_as_string(LIBRARY + "magic_gi_sh4_tensor.glslinc")
	var sampling := FileAccess.get_file_as_string(LIBRARY + "magic_gi_dynamic_volume_sample.glslinc")
	sampling = sampling.replace("#include \"magic_gi_sh4_tensor.glslinc\"", "")
	# Optional mutation control: the unchanged numerical assertions must FAIL
	# with the former coverage-scaled sky subtraction (two partial-support cases).
	if OS.get_cmdline_user_args().has("--legacy-coverage-control"):
		sampling = sampling.replace(
			"global_sky_light_diffuse * clamp(strength, 0.0, 1.0);",
			"global_sky_light_diffuse * clamp(strength * coverage, 0.0, 1.0);")
	return """#version 450
#define MAGIC_GI_PREINTERPOLATED_ONLY
#define FRP_MAGIC_GI_DYNAMIC_VOLUME_LINEAR_SAMPLER regression_sampler
layout(local_size_x=1, local_size_y=1, local_size_z=1) in;
layout(set=0, binding=0) uniform sampler regression_sampler;
layout(set=0, binding=1, std430) buffer RegressionOutput { vec4 values[2]; } output_data;
layout(push_constant, std430) uniform Query { vec4 world; } query;
""" + tensor + "\n" + sampling + """
void main() {
	vec3 normal_world = normalize(vec3(0.2, 1.0, 0.3));
	vec3 incident; float coverage;
	bool hit = frp_magic_gi_dynamic_volume_sample(query.world.xyz,
		normal_world, normal_world, 0, incident, coverage);
	vec3 sky = vec3(2.0, 4.0, 6.0);
	vec3 ambient = sky + vec3(0.1, 0.2, 0.3);
	frp_magic_gi_dynamic_volume_apply(query.world.xyz, normal_world, normal_world,
		vec3(0.8, 0.6, 0.4), 0.7, 0.9, 0, ambient, sky);
	output_data.values[0] = vec4(incident, coverage);
	output_data.values[1] = vec4(ambient, hit ? 1.0 : 0.0);
}
"""

func _texture(mode: String) -> RID:
	var data := PackedFloat32Array()
	data.resize(2 * 2 * 2 * 4 * 4)
	for field in 4:
		for z in 2:
			for y in 2:
				for x in 2:
					if mode == "empty" or (mode == "partial" and x == 1):
						continue
					var index := (((field * 2 + z) * 2 + y) * 2 + x) * 4
					# L0-only fixture: Y00 * C0 reconstructs a constant response.
					if mode != "black" and field == 0:
						data[index] = INCIDENT.x / 0.2820947918
						data[index + 1] = INCIDENT.y / 0.2820947918
						data[index + 2] = INCIDENT.z / 0.2820947918
					if field == 3:
						data[index + 3] = 1.0
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.width = 2
	format.height = 2
	format.depth = 8
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return _own(rd.texture_create(format, RDTextureView.new(), [data.to_byte_array()]))

func _parameters() -> PackedByteArray:
	var data := PackedFloat32Array([
		0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 8,
	]).to_byte_array()
	data.append_array(PackedInt32Array([2, 2, 2, 7]).to_byte_array())
	# The first angular_layout lane is a float decode scale carried as int bits.
	data.append_array(PackedFloat32Array([1.0]).to_byte_array())
	data.append_array(PackedInt32Array([4, 1, 2]).to_byte_array())
	return data

func _owner(strength: float, replace_sky: bool) -> PackedByteArray:
	return PackedFloat32Array([
		1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
		10, 10, 10, 1, strength, 1.0 if replace_sky else 0.0, NORMALIZATION, 0,
	]).to_byte_array()

func _uniform(type: RenderingDevice.UniformType, binding: int, rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform

func _own(rid: RID) -> RID:
	resources.append(rid)
	return rid

func _finish() -> void:
	print("PREPARED_CLV_SKY_OWNERSHIP checks=", checks, " failures=", failures)
	if rd != null:
		resources.reverse()
		for rid in resources:
			if rid.is_valid():
				rd.free_rid(rid)
		rd.free()
		rd = null
	quit(1 if failures else 0)
