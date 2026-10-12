@tool
class_name FengReflectionResolvePass
extends FengPass
## Resolves current-frame reflection candidates over Feng probe and Sky sources.

const NativeSpec = preload("../pipeline/native_spec.gd")
const ReflectionSettings = preload("../reflection_settings.gd")
const U = preload("../rd/uniforms.gd")
const PIPELINE_SCOPE: StringName = NativeSpec.SCOPE_PIPELINE
const SHADER_PATH := "res://addons/feng-render-pipeline/library/reflection-resolve/reflection_resolve.glslinc"
const WORKGROUP_SIZE := 8

enum ReflectionSource {
	GI,
	SSR,
	PROBE,
	SKY,
}

## Kept as hidden storage so old Resolve resources can migrate their authored order.
@export_storage var source_priority: Array[int] = [
		ReflectionSource.GI, ReflectionSource.SSR, ReflectionSource.PROBE, ReflectionSource.SKY]:
	set(value):
		source_priority = value.duplicate()

var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _empty_candidate := RID()
var _frame_context: FRPPassContext
var _frame_source_priority: Array[int] = [0, 1, 2, 3]
var _warnings: Dictionary = {}

func _init() -> void:
	resource_name = "Reflection Resolve"
	stage = EFFECT_CALLBACK_TYPE_POST_LIGHTING
	inputs = _make_inputs()
	access_resolved_color = true
	access_resolved_depth = false

func get_reflection_source_kind() -> StringName:
	return &"resolve"

func get_required_before_native_ids() -> PackedInt32Array:
	return PackedInt32Array([
		NativeSpec.PASS_SKY,
		NativeSpec.PASS_TRANSPARENT,
		NativeSpec.PASS_TEMPORAL_AA,
		NativeSpec.PASS_BLOOM,
		NativeSpec.PASS_POST_PROCESS,
	])

func _make_inputs() -> Array[TextureInput]:
	var native := TextureInput.new()
	native.binding = 0
	native.source = TextureInput.Source.INDIRECT_SPECULAR
	return [native]

func ensure_frp_contract() -> bool:
	if _inputs_match(inputs, _make_inputs()):
		return false
	inputs = _make_inputs()
	return true

func _frp_prepare(ctx: FRPPassContext) -> void:
	if ctx != null:
		ctx.request_reflection_components()
		var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
		var target := buffers.get_render_target() if buffers != null else RID()
		_frame_source_priority = ReflectionSettings.priority_for_render_target(target, get_instance_id())

func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	_frame_context = ctx
	super._frp_execute(ctx)
	_frame_context = null

func _setup(rd: RenderingDevice) -> void:
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(SHADER_PATH)
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		_warn_once("Shader compilation failed: " + spirv.compile_error_compute)
		return
	_shader = rd.shader_create_from_spirv(spirv, "FRP Reflection Resolve")
	_sync_owned_rids()
	if not _shader.is_valid():
		_warn_once("Shader creation failed.")
		return
	_pipeline = rd.compute_pipeline_create(_shader)
	_sync_owned_rids()
	if not _pipeline.is_valid():
		_warn_once("Compute pipeline creation failed.")
		return
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_sampler = rd.sampler_create(sampler_state)
	_sync_owned_rids()
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	texture_format.width = 1
	texture_format.height = 1
	texture_format.depth = 1
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_empty_candidate = rd.texture_create(texture_format, RDTextureView.new())
	_sync_owned_rids()
	if _empty_candidate.is_valid():
		rd.texture_clear(_empty_candidate, Color(0, 0, 0, 0), 0, 1, 0, 1)
	if not _sampler.is_valid() or not _empty_candidate.is_valid():
		_warn_once("Sampler or neutral candidate texture creation failed.")

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _frame_context == null or not _frame_context.is_reflection_components_available():
		return
	if not _shader.is_valid() or not _pipeline.is_valid() or not _sampler.is_valid() or not _empty_candidate.is_valid():
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var native_texture := inputs[0].get_texture(buffers, view)
	var sky_texture := _frame_context.get_sky_light_specular_texture(view)
	var target := _frame_context.get_indirect_specular_composite_target(view)
	if not native_texture.is_valid() or not sky_texture.is_valid() or not target.is_valid():
		_warn_once("Native reflection components are unavailable for this frame; the native result was kept.")
		return
	var target_format := rd.texture_get_format(target)
	if target_format.texture_type != RenderingDevice.TEXTURE_TYPE_2D \
			or target_format.format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT \
			or target_format.width != size.x or target_format.height != size.y \
			or not (target_format.usage_bits & RenderingDevice.TEXTURE_USAGE_STORAGE_BIT):
		_warn_once("The native specular composite target is not a full-resolution storage RGBA16F texture; the native result was kept.")
		return
	var gi_candidate := _frame_context.get_reflection_candidate(&"gi", view)
	var ssr_candidate := _frame_context.get_reflection_candidate(&"ssr", view)
	var probe_candidate := _frame_context.get_reflection_candidate(&"feng_probe", view)
	if not gi_candidate.is_valid():
		gi_candidate = _empty_candidate
	if not ssr_candidate.is_valid():
		ssr_candidate = _empty_candidate
	if not probe_candidate.is_valid():
		probe_candidate = _empty_candidate
	var uniforms: Array[RDUniform] = [
		U.image(0, target),
		U.sampled(1, _sampler, native_texture),
		U.sampled(2, _sampler, sky_texture),
		U.sampled(3, _sampler, gi_candidate),
		U.sampled(4, _sampler, ssr_candidate),
		U.sampled(5, _sampler, probe_candidate),
	]
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)
	if not uniform_set.is_valid():
		_warn_once("Reflection Resolve bindings could not be created; the native result was kept.")
		return
	var list := rd.compute_list_begin()
	if list < 0:
		_warn_once("Reflection Resolve compute list could not begin; the native result was kept.")
		return
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	var push_data := PackedInt32Array(_frame_source_priority).to_byte_array()
	rd.compute_list_set_push_constant(list, push_data, push_data.size())
	rd.compute_list_dispatch(list, ceili(float(size.x) / WORKGROUP_SIZE), ceili(float(size.y) / WORKGROUP_SIZE), 1)
	rd.compute_list_end()
	_frame_context.mark_indirect_specular_modified(view)

func get_configuration_warnings() -> PackedStringArray:
	var warnings := super.get_configuration_warnings()
	if not ReflectionSettings.is_valid_priority(source_priority):
		warnings.append("Legacy Reflection Priority must contain GI, SSR, FengReflectProbe and FengSkyLight exactly once.")
	return warnings

func _warn_once(message: String) -> void:
	if _warnings.has(message):
		return
	_warnings[message] = true
	push_warning("Feng Reflection Resolve: " + message)

func _current_owned_rids() -> Array[RID]:
	return [_pipeline, _shader, _sampler, _empty_candidate]

func _sync_owned_rids() -> void:
	_replace_owned_rid_snapshot(_current_owned_rids())

func _take_owned_rids() -> Array[RID]:
	# During ordinary cleanup the derived fields are live. PREDELETE can suspend
	# derived script dispatch, in which case PassBase's detached snapshot is enough.
	var pipeline_value: Variant = super.call("get", "_pipeline")
	var shader_value: Variant = super.call("get", "_shader")
	if not pipeline_value is RID or not shader_value is RID:
		return super._take_owned_rids()
	var owned: Array[RID] = []
	for value in [pipeline_value, shader_value]:
		if value.is_valid():
			owned.append(value)
	for name in ["_sampler", "_empty_candidate"]:
		var value: Variant = super.call("get", name)
		if value is RID and value.is_valid():
			owned.append(value)
	super.call("set", "_pipeline", RID())
	super.call("set", "_shader", RID())
	super.call("set", "_sampler", RID())
	super.call("set", "_empty_candidate", RID())
	var rids := super._take_owned_rids()
	rids.append_array(owned)
	return rids
