@tool
extends RefCounted
const U = preload("../rd/uniforms.gd")
const PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_dynamic_volume_debug.glsl"
const PAGED_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_paged_volume_debug.glsl"
var _shader := RID()
var _pipeline := RID()
var _shader_path := ""
var _nearest := RID()
var _linear := RID()
var _frame := RID()

func draw(rd: RenderingDevice, cache: RefCounted, owner: RID, frame_bytes: PackedByteArray,
		depth: RID, normal: RID, albedo: RID, orm: RID, ao: RID, output: RID,
		size: Vector2i, mode: int, exposure: float) -> String:
	if cache == null or not cache.has_method("get_runtime_state"):
		return "dynamic_debug_cache_unavailable"
	var state: Dictionary = cache.get_runtime_state()
	var paged := int(state.get("layout_version", 0)) == 6
	if not _ensure(rd, paged):
		return "dynamic_debug_shader_unavailable"
	if frame_bytes.size() != 448: return "dynamic_debug_camera_unavailable"
	if not _frame.is_valid(): _frame = rd.uniform_buffer_create(448, frame_bytes)
	elif rd.buffer_update(_frame, 0, 448, frame_bytes) != OK: return "dynamic_debug_camera_upload_failed"
	for rid in [owner, _frame, depth, normal, albedo, orm, ao, output]:
		if not rid.is_valid(): return "dynamic_debug_input_unavailable"
	var set0 := UniformSetCacheRD.get_cache(_shader, 0, [
		U.sampled(0, _nearest, depth), U.sampled(1, _nearest, normal),
		U.sampled(2, _nearest, albedo), U.sampled(3, _nearest, orm),
		U.image(4, output), U.uniform_buffer(5, _frame), U.sampled(6, _linear, ao)])
	var set1 := UniformSetCacheRD.get_cache(_shader, 1, [
		_sampler(62, _linear), _texture(69, cache.get_field_textures()[0]),
		U.uniform_buffer(76, cache.parameters), U.uniform_buffer(77, owner),
		_texture(87, cache.get_moments_texture()),
		U.storage_buffer(88, cache.get_relocation_buffer()),
		U.storage_buffer(89, cache.get_validity_buffer())])
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
	return "native_preinterpolated_clv_debug_current"

func _ensure(rd: RenderingDevice, paged := false) -> bool:
	if rd == null: return false
	var path := PAGED_PATH if paged else PATH
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
	return _pipeline.is_valid() and _nearest.is_valid() and _linear.is_valid()

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
	return [_pipeline, _shader, _nearest, _linear, _frame]
