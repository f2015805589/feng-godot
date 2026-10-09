class_name FFogSkySHProvider
extends RefCounted
## Projects an explicitly registered, ready FengSkyLight RD octmap into the
## seven-vec4 UE diffuse-convolved SH9 layout. All returned RIDs are provider
## owned and must be treated as borrowed by the caller.

const SHADER_DIR := "res://addons/feng-fog/rendering/lighting"
const SH_LAYOUT_VERSION := 1
const SH_COEFFICIENT_COUNT := 7
const SH_BYTES := SH_COEFFICIENT_COUNT * 16
const SH_SAMPLE_WIDTH := 128
const SH_SAMPLE_HEIGHT := 64
const SH_PARTIAL_GROUP_COUNT := 128
const SH_PARTIAL_BYTES := SH_PARTIAL_GROUP_COUNT * 9 * 16
const MIN_CAPTURED_EXPOSURE := 0.000001
const SH_NEUTRAL_BYTES := 7 * 16

var _rd: RenderingDevice
var _sampler := RID()
var _project_shader_2d := RID()
var _project_pipeline_2d := RID()
var _project_shader_array := RID()
var _project_pipeline_array := RID()
var _pack_shader := RID()
var _pack_pipeline := RID()
var _partial_buffer := RID()
var _packed_buffer := RID()
var _neutral_buffer := RID()
var _source_key: Array = []
var _last_error := ""


## `sky_sh_buffer` is the UE ReflectionEnvironment seven-vec4 layout. Its RGB
## values are raw linear radiance projected and diffuse-convolved with the UE
## l=0,1,2 factors divided by PI. The buffer has no Sky energy or exposure.
## Consumers apply `scene_radiance_scale * source_energy * scattering_intensity`
## once. SH coefficients remain in sky-local axes; rotate the view/camera vector
## from world to sky-local before the UE `GetSkySHDiffuseSimple(dir * -g)` dot.
func update_frame_inputs(p_frame: Dictionary, p_rd: RenderingDevice,
		p_sky_metadata: Dictionary = {}) -> Dictionary:
	_last_error = ""
	if p_rd == null:
		return _invalid_result("No RenderingDevice was supplied.", p_frame, null)
	var main_rd := RenderingServer.get_rendering_device()
	if main_rd == null or p_rd != main_rd:
		return _invalid_result("Sky SH projection must use the RenderingServer main RenderingDevice.", p_frame, p_rd)
	if int(p_frame.get("abi_version", 0)) != 1 or not bool(p_frame.get("valid", false)):
		return _invalid_result("FRP volume frame input ABI is invalid.", p_frame, p_rd)
	if not bool(p_frame.get("sky_light_source_valid", false)):
		return _invalid_result("No explicit ready FengSkyLight source was provided.", p_frame, p_rd)
	var source: RID = p_frame.get("sky_light_source", RID())
	var texture: RID = p_frame.get("sky_radiance_texture", RID())
	var owner_id := int(p_frame.get("sky_light_source_owner_id", 0))
	if owner_id <= 0 or not source.is_valid() or not texture.is_valid() \
			or not p_rd.texture_is_valid(texture):
		return _invalid_result("Explicit FengSkyLight source or borrowed radiance texture is invalid.", p_frame, p_rd)
	var texture_format: RDTextureFormat = p_rd.texture_get_format(texture)
	var nominal_size := int(p_frame.get("sky_radiance_size", 0))
	var border := float(p_frame.get("sky_uv_border_size", -1.0))
	if texture_format == null:
		return _invalid_result("Sky radiance texture format is unavailable.", p_frame, p_rd)
	if not _is_supported_sky_texture(texture_format, bool(p_frame.get("sky_radiance_is_array", false))):
		return _invalid_result("Sky radiance format is unsupported: actual=%dx%d, nominal=%d, border=%.8f; expected a square sampleable 2D or 2D-array float texture." % [
				texture_format.width, texture_format.height, nominal_size, border], p_frame, p_rd)
	var dimension_validation := validate_radiance_dimensions(
			texture_format.width, texture_format.height, nominal_size, border)
	if not bool(dimension_validation.get("valid", false)):
		return _invalid_result(str(dimension_validation.get("reason", "Sky radiance dimensions are incompatible with their metadata.")), p_frame, p_rd)
	var captured_exposure := float(p_frame.get("sky_captured_exposure", 0.0))
	var scene_normalization := float(p_frame.get("scene_normalization", 0.0))
	var pre_exposure := float(p_frame.get("pre_exposure", 0.0))
	var source_energy := float(p_frame.get("sky_light_energy", -1.0))
	if not is_finite(captured_exposure) or captured_exposure <= MIN_CAPTURED_EXPOSURE \
			or not is_finite(scene_normalization) or scene_normalization <= 0.0 \
			or not is_finite(pre_exposure) or pre_exposure <= 0.0 \
			or not is_finite(source_energy) or source_energy < 0.0:
		return _invalid_result("Sky exposure, scene normalization, pre-exposure, or energy metadata is invalid.", p_frame, p_rd)
	if not _ensure_resources(p_rd):
		return _invalid_result(_last_error, p_frame, p_rd)
	var key := _make_source_key(p_frame, texture_format, border)
	var cache_hit := key == _source_key and _packed_buffer.is_valid()
	if not cache_hit and not _project_source(p_rd, texture, border, bool(p_frame.get("sky_radiance_is_array", false))):
		return _invalid_result(_last_error, p_frame, p_rd)
	if not cache_hit:
		_source_key = key
	var metadata_matches := _metadata_matches_frame(p_frame, p_sky_metadata)
	var scattering_intensity := float(p_sky_metadata.get("volumetric_scattering_intensity", 0.0)) \
			if metadata_matches else 0.0
	return {
		"valid": true,
		"can_apply": metadata_matches,
		"reason": "" if metadata_matches else "Sky coefficients are ready; active FengSkyLight volumetric metadata is missing or does not match this frame source.",
		"sky_sh_buffer": _packed_buffer,
		"sky_sh_buffer_bytes": SH_BYTES,
		"sky_sh_layout_version": SH_LAYOUT_VERSION,
		"sky_sh_layout": "UE_ReflectionEnvironment_7xvec4_diffuse_convolved_over_pi",
		"sky_sh_coordinates": "sky_local",
		"sky_sh_includes_l2": true,
		"simple_lookup_uses_coefficients": 3,
		"sky_light_source_owner_id": owner_id,
		"sky_light_source_revision": int(p_frame.get("sky_light_source_revision", 0)),
		"sky_light_revision": int(p_frame.get("sky_light_revision", 0)),
		"source_energy": source_energy,
		"volumetric_scattering_intensity": scattering_intensity,
		"scene_radiance_scale": scene_normalization * pre_exposure / captured_exposure,
		"exposure_scale_contract": "rawSkyRadiance * energy * scene_normalization / capturedExposure * preExposure * volumetricScatteringIntensity; each factor exactly once",
		"source_metadata_matches": metadata_matches,
		"cache_hit": cache_hit,
		"source_key": _source_key.duplicate(),
		"output_ownership": "provider",
		"source_texture_ownership": "borrowed",
		"source_device": "RenderingServer main RenderingDevice",
	}


func get_last_error() -> String:
	return _last_error


## CPU mirror of ReflectionEnvironmentShared.ush GetSkySHDiffuseSimple.
## The caller supplies a normalized sky-local vector; this intentionally uses
## only the first three packed vectors, like UE's Simple path.
static func evaluate_simple_diffuse(p_coefficients: PackedFloat32Array,
		p_direction_sky_local: Vector3) -> Vector3:
	if p_coefficients.size() != 28 or not p_direction_sky_local.is_finite():
		return Vector3.ZERO
	var n := p_direction_sky_local
	var n4 := Vector4(n.x, n.y, n.z, 1.0)
	var result := Vector3.ZERO
	for channel in 3:
		var base := channel * 4
		var value := p_coefficients[base] * n4.x + p_coefficients[base + 1] * n4.y \
				+ p_coefficients[base + 2] * n4.z + p_coefficients[base + 3] * n4.w
		if channel == 0:
			result.x = value
		elif channel == 1:
			result.y = value
		else:
			result.z = value
	return Vector3(maxf(result.x, 0.0), maxf(result.y, 0.0), maxf(result.z, 0.0))


## CPU mirror of the GPU's exact diffuse/PI packing constants and seven-vector
## order. Raw coefficients use UE's real SH basis and its signed coefficient
## convention: (1, y-, z+, x-, xy+, yz-, zz, xz-, x2-y2+).
static func pack_ue_diffuse_over_pi(p_raw_sh: PackedFloat32Array) -> PackedFloat32Array:
	if p_raw_sh.size() != 27:
		return PackedFloat32Array()
	var output := PackedFloat32Array()
	output.resize(28)
	output.fill(0.0)
	const C0 := 0.28209479177387814
	const C1 := 0.32573500793527993
	const C2 := 0.343046698469648
	const C3 := 0.07884789131313001
	const C4 := 0.171523349234824
	for channel in 3:
		var raw := PackedFloat32Array()
		raw.resize(9)
		for coefficient in 9:
			raw[coefficient] = p_raw_sh[coefficient * 3 + channel]
		var base := channel * 4
		output[base] = -C1 * raw[3]
		output[base + 1] = -C1 * raw[1]
		output[base + 2] = C1 * raw[2]
		output[base + 3] = C0 * raw[0] - C3 * raw[6]
		base = (3 + channel) * 4
		output[base] = C2 * raw[4]
		output[base + 1] = -C2 * raw[5]
		output[base + 2] = 3.0 * C3 * raw[6]
		output[base + 3] = -C2 * raw[7]
		output[24 + channel] = C4 * raw[8]
	output[27] = 1.0
	return output


## Solid-angle-uniform CPU fixture projector. Inputs are local-space directions
## and linear radiances; the sample directions must cover the sphere evenly.
static func project_samples_to_raw_sh(p_directions: PackedVector3Array,
		p_radiances: PackedVector3Array) -> PackedFloat32Array:
	if p_directions.is_empty() or p_directions.size() != p_radiances.size():
		return PackedFloat32Array()
	var raw := PackedFloat32Array()
	raw.resize(27)
	raw.fill(0.0)
	var weight := 4.0 * PI / float(p_directions.size())
	for index in p_directions.size():
		var direction := p_directions[index]
		var radiance := p_radiances[index]
		if not direction.is_finite() or direction.length_squared() <= 0.00000001 \
				or not radiance.is_finite():
			return PackedFloat32Array()
		direction = direction.normalized()
		var x := direction.x
		var y := direction.y
		var z := direction.z
		var basis := [
			0.28209479177387814,
			-0.4886025119029199 * y,
			0.4886025119029199 * z,
			-0.4886025119029199 * x,
			1.0925484305920792 * x * y,
			-1.0925484305920792 * y * z,
			0.31539156525252005 * (3.0 * z * z - 1.0),
			-1.0925484305920792 * x * z,
			0.5462742152960396 * (x * x - y * y),
		]
		for coefficient in 9:
			var base := coefficient * 3
			var factor: float = float(basis[coefficient]) * weight
			raw[base] += radiance.x * factor
			raw[base + 1] += radiance.y * factor
			raw[base + 2] += radiance.z * factor
	return raw


func release() -> void:
	if _rd != null:
		for rid in [_partial_buffer, _packed_buffer, _neutral_buffer, _sampler,
				_project_pipeline_2d, _project_pipeline_array, _pack_pipeline,
				_project_shader_2d, _project_shader_array, _pack_shader]:
			_free_rid(_rd, rid)
	_rd = null
	_sampler = RID()
	_project_shader_2d = RID()
	_project_pipeline_2d = RID()
	_project_shader_array = RID()
	_project_pipeline_array = RID()
	_pack_shader = RID()
	_pack_pipeline = RID()
	_partial_buffer = RID()
	_packed_buffer = RID()
	_neutral_buffer = RID()
	_source_key.clear()
	_last_error = ""


func _ensure_resources(p_rd: RenderingDevice) -> bool:
	if _rd != null and _rd != p_rd:
		release()
	_rd = p_rd
	if not _sampler.is_valid():
		var sampler_state := RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_sampler = p_rd.sampler_create(sampler_state)
	if not _partial_buffer.is_valid():
		_partial_buffer = p_rd.storage_buffer_create(SH_PARTIAL_BYTES)
	if not _packed_buffer.is_valid():
		_packed_buffer = p_rd.storage_buffer_create(SH_BYTES)
	return _sampler.is_valid() and _partial_buffer.is_valid() and _packed_buffer.is_valid()


func _ensure_pipeline(p_rd: RenderingDevice, p_array_texture: bool) -> bool:
	if not _pack_pipeline.is_valid():
		var packed := _compile_compute(p_rd, "fog_sky_sh_pack.glslinc")
		if packed.is_empty():
			return false
		_pack_shader = packed.shader
		_pack_pipeline = packed.pipeline
	var project_pipeline := _project_pipeline_array if p_array_texture else _project_pipeline_2d
	if project_pipeline.is_valid():
		return true
	var project_source := FileAccess.get_file_as_string(SHADER_DIR.path_join("fog_sky_sh_project.glslinc"))
	if project_source.is_empty():
		_last_error = "Sky SH projection shader source is missing or empty."
		return false
	if p_array_texture:
		project_source = project_source.replace("#define FENG_FOG_SKY_ARRAY 0", "#define FENG_FOG_SKY_ARRAY 1")
	var projected := _compile_compute_source(p_rd, project_source, "FengFogSkySHProjectArray" if p_array_texture else "FengFogSkySHProject2D")
	if projected.is_empty():
		return false
	if p_array_texture:
		_project_shader_array = projected.shader
		_project_pipeline_array = projected.pipeline
	else:
		_project_shader_2d = projected.shader
		_project_pipeline_2d = projected.pipeline
	return true


func _project_source(p_rd: RenderingDevice, p_texture: RID, p_border: float,
		p_array_texture: bool) -> bool:
	if not _ensure_pipeline(p_rd, p_array_texture):
		return false
	var project_shader := _project_shader_array if p_array_texture else _project_shader_2d
	var project_pipeline := _project_pipeline_array if p_array_texture else _project_pipeline_2d
	var projection_parameters := PackedFloat32Array([p_border, 0.0, 0.0, 0.0]).to_byte_array()
	var parameter_buffer := p_rd.uniform_buffer_create(projection_parameters.size(), projection_parameters)
	if not parameter_buffer.is_valid():
		_last_error = "Could not allocate the sky SH projection parameters."
		return false
	var project_uniforms: Array[RDUniform] = []
	var texture_uniform := RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	texture_uniform.binding = 0
	texture_uniform.add_id(_sampler)
	texture_uniform.add_id(p_texture)
	project_uniforms.append(texture_uniform)
	var partial_uniform := RDUniform.new()
	partial_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	partial_uniform.binding = 1
	partial_uniform.add_id(_partial_buffer)
	project_uniforms.append(partial_uniform)
	var parameter_uniform := RDUniform.new()
	parameter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	parameter_uniform.binding = 2
	parameter_uniform.add_id(parameter_buffer)
	project_uniforms.append(parameter_uniform)
	var project_set := p_rd.uniform_set_create(project_uniforms, project_shader, 0)
	if not project_set.is_valid():
		_free_rid(p_rd, parameter_buffer)
		_last_error = "Could not bind the explicit sky source for SH projection."
		return false
	var pack_uniforms: Array[RDUniform] = []
	var pack_partial := RDUniform.new()
	pack_partial.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	pack_partial.binding = 0
	pack_partial.add_id(_partial_buffer)
	pack_uniforms.append(pack_partial)
	var pack_output := RDUniform.new()
	pack_output.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	pack_output.binding = 1
	pack_output.add_id(_packed_buffer)
	pack_uniforms.append(pack_output)
	var pack_set := p_rd.uniform_set_create(pack_uniforms, _pack_shader, 0)
	if not pack_set.is_valid():
		_free_rid(p_rd, project_set)
		_free_rid(p_rd, parameter_buffer)
		_last_error = "Could not bind the UE sky SH output buffer."
		return false
	var compute_list := p_rd.compute_list_begin()
	if compute_list == RenderingDevice.INVALID_ID:
		_free_rid(p_rd, project_set)
		_free_rid(p_rd, pack_set)
		_free_rid(p_rd, parameter_buffer)
		_last_error = "Could not begin the sky SH projection compute list."
		return false
	p_rd.compute_list_bind_compute_pipeline(compute_list, project_pipeline)
	p_rd.compute_list_bind_uniform_set(compute_list, project_set, 0)
	p_rd.compute_list_dispatch(compute_list, SH_SAMPLE_WIDTH >> 3, SH_SAMPLE_HEIGHT >> 3, 1)
	p_rd.compute_list_add_barrier(compute_list)
	p_rd.compute_list_bind_compute_pipeline(compute_list, _pack_pipeline)
	p_rd.compute_list_bind_uniform_set(compute_list, pack_set, 0)
	p_rd.compute_list_dispatch(compute_list, 1, 1, 1)
	p_rd.compute_list_end()
	_free_rid(p_rd, project_set)
	_free_rid(p_rd, pack_set)
	_free_rid(p_rd, parameter_buffer)
	return true


func _compile_compute(p_rd: RenderingDevice, p_filename: String) -> Dictionary:
	var shader_source := FileAccess.get_file_as_string(SHADER_DIR.path_join(p_filename))
	if shader_source.is_empty():
		_last_error = "Compute shader source is missing or empty: " + p_filename
		return {}
	return _compile_compute_source(p_rd, shader_source, p_filename.get_basename())


func _compile_compute_source(p_rd: RenderingDevice, p_source_text: String,
		p_debug_name: String) -> Dictionary:
	var raw_compute_source := strip_compute_marker(p_source_text)
	if raw_compute_source.is_empty():
		_last_error = "Godot compute marker is missing from " + p_debug_name + "."
		return {}
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = raw_compute_source
	var spirv: RDShaderSPIRV = p_rd.shader_compile_spirv_from_source(source)
	if spirv == null:
		_last_error = "RD returned no SPIR-V for " + p_debug_name + "."
		return {}
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		_last_error = "Sky SH compute shader compile failed: " + compile_error
		return {}
	var shader := p_rd.shader_create_from_spirv(spirv, p_debug_name)
	if not shader.is_valid():
		_last_error = "Could not create sky SH shader RID: " + p_debug_name
		return {}
	var pipeline := p_rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		_free_rid(p_rd, shader)
		_last_error = "Could not create sky SH compute pipeline: " + p_debug_name
		return {}
	return {"shader": shader, "pipeline": pipeline}


static func strip_compute_marker(p_source_text: String) -> String:
	var first_newline := p_source_text.find("\n")
	if first_newline < 0 or p_source_text.substr(0, first_newline).strip_edges() != "#[compute]":
		return ""
	return p_source_text.substr(first_newline + 1)


func _ensure_neutral_buffer(p_rd: RenderingDevice) -> RID:
	if _rd != null and _rd != p_rd:
		release()
	_rd = p_rd
	if not _neutral_buffer.is_valid():
		var zero_bytes := PackedByteArray()
		zero_bytes.resize(SH_NEUTRAL_BYTES)
		_neutral_buffer = p_rd.storage_buffer_create(SH_NEUTRAL_BYTES, zero_bytes)
	return _neutral_buffer


func _invalid_result(p_reason: String, p_frame: Dictionary,
		p_rd: RenderingDevice) -> Dictionary:
	_last_error = p_reason
	var neutral := RID()
	if p_rd != null and p_rd == RenderingServer.get_rendering_device():
		neutral = _ensure_neutral_buffer(p_rd)
	return {
		"valid": false,
		"can_apply": false,
		"reason": p_reason,
		"sky_sh_buffer": neutral,
		"sky_sh_buffer_bytes": SH_BYTES if neutral.is_valid() else 0,
		"sky_sh_layout_version": SH_LAYOUT_VERSION,
		"sky_light_source_owner_id": int(p_frame.get("sky_light_source_owner_id", 0)),
		"output_ownership": "provider" if neutral.is_valid() else "none",
	}


func _is_supported_sky_texture(p_format: RDTextureFormat,
		p_array_texture: bool) -> bool:
	if p_format == null or p_format.width <= 0 or p_format.height <= 0 \
			or p_format.depth != 1 or not (p_format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT):
		return false
	var expected_type := RenderingDevice.TEXTURE_TYPE_2D_ARRAY if p_array_texture else RenderingDevice.TEXTURE_TYPE_2D
	if p_format.texture_type != expected_type or (p_array_texture and p_format.array_layers < 1):
		return false
	return p_format.format in [RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT]


## `sky_radiance_size` is the nominal cube-face resolution. Native SkyRD stores
## an octmap interior at twice that resolution and adds a filtering border. The
## same relation is used by regular and externally captured skies, with either
## a 2D texture or a 2D-array texture.
static func validate_radiance_dimensions(p_actual_width: int, p_actual_height: int,
		p_nominal_size: int, p_border: float) -> Dictionary:
	var result := {
		"actual_width": p_actual_width,
		"actual_height": p_actual_height,
		"nominal_size": p_nominal_size,
		"border": p_border,
	}
	if p_actual_width <= 0 or p_actual_height <= 0 or p_nominal_size <= 0 \
			or not is_finite(p_border) or p_border < 0.0 or p_border >= 0.5:
		result["valid"] = false
		result["reason"] = "Invalid sky dimensions: actual=%dx%d, nominal=%d, border=%.8f." % [
				p_actual_width, p_actual_height, p_nominal_size, p_border]
		return result
	var interior_width := float(p_actual_width) * (1.0 - 2.0 * p_border)
	var interior_height := float(p_actual_height) * (1.0 - 2.0 * p_border)
	var expected_interior := float(p_nominal_size) * 2.0
	var tolerance := maxf(0.5, expected_interior * 0.0001)
	var dimensions_match := p_actual_width == p_actual_height \
			and absf(interior_width - expected_interior) <= tolerance \
			and absf(interior_height - expected_interior) <= tolerance
	result["valid"] = dimensions_match
	result["interior_width"] = interior_width
	result["interior_height"] = interior_height
	result["expected_interior"] = expected_interior
	result["tolerance"] = tolerance
	if not dimensions_match:
		result["reason"] = "Sky radiance dimensions mismatch: actual=%dx%d, nominal=%d, border=%.8f gives interior=%.4fx%.4f; expected square interior=%.1f (tolerance %.3f)." % [
				p_actual_width, p_actual_height, p_nominal_size, p_border,
				interior_width, interior_height, expected_interior, tolerance]
	return result


func _make_source_key(p_frame: Dictionary, p_format: RDTextureFormat,
		p_border: float) -> Array:
	var rotation: Basis = p_frame.get("sky_light_rotation", Basis.IDENTITY)
	return [
		int(p_frame.get("sky_light_source_owner_id", 0)),
		_rid_id(p_frame.get("sky_light_source", RID())),
		_rid_id(p_frame.get("sky_radiance_texture", RID())),
		int(p_frame.get("sky_light_source_revision", 0)),
		int(p_frame.get("sky_light_revision", 0)),
		rotation.x, rotation.y, rotation.z,
		# Actual atlas dimensions differ from the nominal cube-face resolution.
		p_format.width, p_format.height, p_format.array_layers, p_format.texture_type, p_format.format,
		bool(p_frame.get("sky_radiance_is_array", false)),
		int(p_frame.get("sky_radiance_size", 0)), p_border,
	]


func _metadata_matches_frame(p_frame: Dictionary, p_metadata: Dictionary) -> bool:
	if p_metadata.is_empty() or not bool(p_metadata.get("ready", false)):
		return false
	var owner_id := int(p_frame.get("sky_light_source_owner_id", 0))
	if owner_id <= 0 or int(p_metadata.get("provider_id", 0)) != owner_id \
			or int(p_metadata.get("source_revision", -1)) != int(p_frame.get("sky_light_source_revision", -2)):
		return false
	var metadata_energy := float(p_metadata.get("radiance_energy", -1.0))
	var frame_energy := float(p_frame.get("sky_light_energy", -2.0))
	var metadata_exposure := float(p_metadata.get("captured_exposure", 0.0))
	var frame_exposure := float(p_frame.get("sky_captured_exposure", -1.0))
	if not is_finite(metadata_energy) or not is_finite(frame_energy) \
			or not is_equal_approx(metadata_energy, frame_energy) \
			or not is_finite(metadata_exposure) or not is_finite(frame_exposure) \
			or not is_equal_approx(metadata_exposure, frame_exposure):
		return false
	var metadata_rotation: Variant = p_metadata.get("rotation", null)
	var frame_rotation: Variant = p_frame.get("sky_light_rotation", null)
	if not metadata_rotation is Basis or not frame_rotation is Basis:
		return false
	var metadata_basis: Basis = metadata_rotation
	var frame_basis: Basis = frame_rotation
	return metadata_basis.x.is_equal_approx(frame_basis.x) \
			and metadata_basis.y.is_equal_approx(frame_basis.y) \
			and metadata_basis.z.is_equal_approx(frame_basis.z)


func _rid_id(p_value: Variant) -> int:
	if p_value is RID and p_value.is_valid():
		return p_value.get_id()
	return 0


func _free_rid(p_rd: RenderingDevice, p_rid: RID) -> void:
	if p_rid.is_valid():
		p_rd.free_rid(p_rid)
