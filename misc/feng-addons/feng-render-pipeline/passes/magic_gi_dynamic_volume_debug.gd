@tool
extends RefCounted
const U = preload("../rd/uniforms.gd")
const PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_dynamic_volume_debug.glsl"
const PAGED_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_paged_volume_debug.glsl"
const PREPARED_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_prepared_volume_debug.glsl"
var _shader := RID()
var _pipeline := RID()
var _shader_path := ""
var _nearest := RID()
var _linear := RID()
var _frame := RID()
var _olv_dummy_atlas := RID()
var _olv_dummy_parameters := RID()

func draw(rd: RenderingDevice, cache: RefCounted, owner: RID, frame_bytes: PackedByteArray,
		depth: RID, normal: RID, albedo: RID, orm: RID, ao: RID, output: RID,
		size: Vector2i, mode: int, exposure: float) -> String:
	if cache == null or not cache.has_method("get_runtime_state"):
		return "dynamic_debug_cache_unavailable"
	var state: Dictionary = cache.get_runtime_state()
	var layout_version := int(state.get("layout_version", 0))
	var paged := layout_version == 7
	var prepared_sh2 := layout_version == 8
	if not _ensure(rd, paged, prepared_sh2):
		return "dynamic_debug_shader_unavailable"
	if frame_bytes.size() != 448: return "dynamic_debug_camera_unavailable"
	if not _frame.is_valid(): _frame = rd.uniform_buffer_create(448, frame_bytes)
	elif rd.buffer_update(_frame, 0, 448, frame_bytes) != OK: return "dynamic_debug_camera_upload_failed"
	if not _ensure_olv_dummy(rd): return "dynamic_debug_olv_fallback_unavailable"
	for rid in [owner, _frame, depth, normal, albedo, orm, ao, output]:
		if not rid.is_valid(): return "dynamic_debug_input_unavailable"
	var olv_atlas := _olv_dummy_atlas
	var olv_parameters := _olv_dummy_parameters
	if cache.has_method("get_olv_binding"):
		var binding_value: Variant = cache.call("get_olv_binding")
		if binding_value is Dictionary:
			var binding: Dictionary = binding_value
			var candidate_atlas: Variant = binding.get("label_atlas", RID())
			var candidate_parameters: Variant = binding.get("label_parameters", RID())
			if bool(binding.get("enabled", false)) and candidate_atlas is RID \
					and candidate_parameters is RID \
					and candidate_atlas.is_valid() and candidate_parameters.is_valid():
				olv_atlas = candidate_atlas
				olv_parameters = candidate_parameters
	var set0 := UniformSetCacheRD.get_cache(_shader, 0, [
		U.sampled(0, _nearest, depth), U.sampled(1, _nearest, normal),
		U.sampled(2, _nearest, albedo), U.sampled(3, _nearest, orm),
		U.image(4, output), U.uniform_buffer(5, _frame), U.sampled(6, _linear, ao)])
	var set1 := UniformSetCacheRD.get_cache(_shader, 1, [
		_sampler(61, _nearest), _sampler(62, _linear), _texture(69, cache.get_field_textures()[0]),
		U.uniform_buffer(76, cache.parameters), U.uniform_buffer(77, owner),
		_texture(87, cache.get_moments_texture()),
		U.storage_buffer(88, cache.get_relocation_buffer()),
		U.storage_buffer(89, cache.get_validity_buffer()),
		_texture(90, olv_atlas), U.uniform_buffer(91, olv_parameters)])
	if not set0.is_valid() or not set1.is_valid(): return "dynamic_debug_uniforms_failed"
	var push := PackedInt32Array([size.x, size.y, mode]).to_byte_array()
	push.append_array(PackedFloat32Array([exposure]).to_byte_array())
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, set0, 0)
	rd.compute_list_bind_uniform_set(list, set1, 1)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	rd.compute_list_end()
	if mode == 6 and olv_atlas == _olv_dummy_atlas:
		return "native_preinterpolated_olv_debug_labels_unavailable"
	return "native_preinterpolated_clv_debug_current"

func _ensure(rd: RenderingDevice, paged := false, prepared_sh2 := false) -> bool:
	if rd == null: return false
	var path := PAGED_PATH if paged else (PREPARED_PATH if prepared_sh2 else PATH)
	if _shader_path != path:
		# Descriptor sets are shader-owned in UniformSetCacheRD. Dropping the old
		# shader invalidates its sets; retain only the shared samplers/frame UBO.
		if _pipeline.is_valid(): rd.free_rid(_pipeline)
		_pipeline = RID()
		if _shader.is_valid(): rd.free_rid(_shader)
		_shader = RID()
		_shader_path = path
	if not _shader.is_valid():
		var resource := load(path) as RDShaderFile
		if resource == null: return false
		var spirv := resource.get_spirv()
		if spirv == null or not spirv.compile_error_compute.is_empty(): return false
		_shader = rd.shader_create_from_spirv(spirv, "Magic GI Live CLV Debug")
	if not _shader.is_valid(): return false
	if not _pipeline.is_valid(): _pipeline = rd.compute_pipeline_create(_shader)
	if not _nearest.is_valid():
		var state := RDSamplerState.new()
		state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_nearest = rd.sampler_create(state)
	if not _linear.is_valid():
		var state := RDSamplerState.new()
		state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_linear = rd.sampler_create(state)
	return _pipeline.is_valid() and _nearest.is_valid() and _linear.is_valid() \
			and _ensure_olv_dummy(rd)

func _ensure_olv_dummy(rd: RenderingDevice) -> bool:
	if rd == null:
		return false
	if not _olv_dummy_atlas.is_valid():
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
		format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		format.width = 1
		format.height = 1
		format.depth = 1
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		_olv_dummy_atlas = rd.texture_create(format, RDTextureView.new(),
			[PackedFloat32Array([0.0]).to_byte_array()])
	if not _olv_dummy_parameters.is_valid():
		# Schema 1, disabled payload, one layer. The disabled bit deliberately
		# makes the debug shader render the unknown color when no active cache
		# published a generation-matched OLV binding.
		var metadata := PackedInt32Array([1, 1, 1, 7, 1, 0, 1, 0])
		_olv_dummy_parameters = rd.uniform_buffer_create(metadata.size() * 4,
			metadata.to_byte_array())
	return _olv_dummy_atlas.is_valid() and _olv_dummy_parameters.is_valid()

func _sampler(binding: int, rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform

func _texture(binding: int, rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform

func owned_rids() -> Array[RID]:
	return [_pipeline, _shader, _nearest, _linear, _frame,
		_olv_dummy_atlas, _olv_dummy_parameters]
