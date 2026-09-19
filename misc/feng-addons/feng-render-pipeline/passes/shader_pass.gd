@tool
class_name FengShaderPass
extends "pass_base.gd"
## Declaration-driven compute or full-screen raster pass.

enum Mode {
	COMPUTE,
	RASTER,
}

const NativeSpec = preload("../pipeline/native_spec.gd")
const PIPELINE_SCOPE: StringName = NativeSpec.SCOPE_PIPELINE

@export var shader_file: RDShaderFile
@export var mode: Mode = Mode.COMPUTE
@export var parameters := Vector4(1.0, 1.0, 1.0, 1.0)
@export var workgroup_size := Vector2i(8, 8)

## Shader keywords: specialization constants, keyed by the `constant_id` the shader
## declares. A shader that starts with
##
##     layout(constant_id = 0) const bool POST_AFTER_TONEMAP = false;
##
## is given that keyword by `shader_keywords = { 0: true }`, or at runtime by
## `set_shader_keyword(0, true)`. Changing a keyword recreates the pipeline, so the
## shader really is re-specialized (the branch the keyword guards is compiled away).
@export var shader_keywords: Dictionary = {}

## Empty targets mean the viewport's internal color texture for raster and the
## internal render size for compute. Named targets refer to frp_pipeline.
@export var raster_target: StringName = &""
@export var dispatch_target: StringName = &""
## Common alias retained for templates that use one target field for either mode.
@export var target_name: StringName = &""

var _shader := RID()
var _compute_pipeline := RID()
var _sampler := RID()
var _spirv: RDShaderSPIRV
var _shader_resource: RDShaderFile
var _shader_mode := -1
var _keyword_signature := ""
var _raster_pipelines := {}
var _binding_error := false

## Sets one shader keyword (a specialization constant) and re-specializes the shader
## when its value actually changed.
func set_shader_keyword(constant_id: int, value) -> void:
	if shader_keywords.has(constant_id) and shader_keywords[constant_id] == value:
		return
	shader_keywords[constant_id] = value
	_keyword_signature = ""

func get_shader_keyword(constant_id: int, default_value = false):
	return shader_keywords.get(constant_id, default_value)

func _keyword_signature_now() -> String:
	var ids := shader_keywords.keys()
	ids.sort()
	var parts := PackedStringArray()
	for constant_id in ids:
		parts.append("%s=%s" % [str(constant_id), str(shader_keywords[constant_id])])
	return ",".join(parts)

func _specialization() -> Array:
	var constants: Array = []
	var ids := shader_keywords.keys()
	ids.sort()
	for constant_id in ids:
		var constant := RDPipelineSpecializationConstant.new()
		constant.constant_id = int(constant_id)
		constant.value = shader_keywords[constant_id]
		constants.append(constant)
	return constants

func _render(_buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if shader_file == null:
		_report("Shader file is not assigned.")
		return
	if not _ensure_shader(rd):
		return
	if mode == Mode.COMPUTE:
		_render_compute(_buffers, view, rd)
	else:
		_render_raster(_buffers, view, rd)

func _ensure_shader(rd: RenderingDevice) -> bool:
	var spirv := shader_file.get_spirv()
	if spirv == null:
		_report("Shader file has no SPIR-V data.")
		return false
	if shader_file.base_error != "":
		_report("Shader compilation failed: " + shader_file.base_error)
		return false
	if _shader.is_valid() and _shader_resource == shader_file and _spirv == spirv and _shader_mode == mode and _keyword_signature == _keyword_signature_now():
		return true
	_destroy_shader_objects(rd)
	if mode == Mode.COMPUTE:
		if spirv.bytecode_compute.is_empty():
			_report("Compute mode requires a compute shader stage.")
			return false
		if spirv.compile_error_compute != "":
			_report("Compute shader compilation failed: " + spirv.compile_error_compute)
			return false
	else:
		if spirv.bytecode_vertex.is_empty() or spirv.bytecode_fragment.is_empty():
			_report("Raster mode requires both vertex and fragment shader stages.")
			return false
		if spirv.compile_error_vertex != "" or spirv.compile_error_fragment != "":
			_report("Raster shader compilation failed: %s %s" % [spirv.compile_error_vertex, spirv.compile_error_fragment])
			return false
	_shader = rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		_report("Cannot create RenderingDevice shader.")
		return false
	_shader_resource = shader_file
	_spirv = spirv
	_shader_mode = mode
	_keyword_signature = _keyword_signature_now()
	if mode == Mode.COMPUTE:
		_compute_pipeline = rd.compute_pipeline_create(_shader, _specialization())
		if not _compute_pipeline.is_valid():
			_report("Cannot create compute pipeline.")
			_destroy_shader_objects(rd)
			return false
	return true

func _ensure_sampler(rd: RenderingDevice) -> bool:
	if _sampler.is_valid():
		return true
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(state)
	if not _sampler.is_valid():
		_report("Cannot create texture sampler.")
		return false
	return true

func _collect_bindings(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	_binding_error = false
	var uniforms: Array[RDUniform] = []
	var textures: Array[RID] = []
	var bindings := {}
	for declaration in inputs:
		if declaration == null:
			_binding_error = true
			_report("Texture declarations cannot be null.")
			continue
		if declaration.binding < 0 or declaration.binding > 31 or bindings.has(declaration.binding):
			_binding_error = true
			_report("Texture declarations must use unique bindings between 0 and 31.")
			continue
		bindings[declaration.binding] = true
		var texture: RID = declaration.get_texture(buffers, view)
		if not texture.is_valid():
			_binding_error = true
			_report("Texture is unavailable for binding %d." % declaration.binding)
			continue
		var uniform := RDUniform.new()
		uniform.binding = declaration.binding
		if declaration.binding_type == TextureInput.BindingType.SAMPLED_TEXTURE:
			if not _ensure_sampler(rd):
				_binding_error = true
				continue
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			uniform.add_id(_sampler)
		else:
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.add_id(texture)
		uniforms.append(uniform)
		textures.append(texture)
	return {"uniforms": uniforms, "textures": textures}

func _make_uniform_set(uniforms: Array[RDUniform]) -> RID:
	if uniforms.is_empty():
		return RID()
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)
	if not uniform_set.is_valid():
		_report("Bindings do not match the shader layout or texture usage.")
	return uniform_set

func _render_compute(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if workgroup_size.x <= 0 or workgroup_size.y <= 0:
		_report("Workgroup size must be positive.")
		return
	var binding_data := _collect_bindings(buffers, view, rd)
	if _binding_error:
		return
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	var uniform_set := _make_uniform_set(uniforms)
	if not uniforms.is_empty() and not uniform_set.is_valid():
		return
	var dispatch_size := buffers.get_internal_size()
	var target := _selected_target(false)
	if target != &"":
		if not buffers.has_texture(PIPELINE_SCOPE, target):
			_report("Dispatch target '%s' is unavailable." % target)
			return
		dispatch_size = buffers.get_texture_slice_size(PIPELINE_SCOPE, target, 0)
	if dispatch_size.x <= 0 or dispatch_size.y <= 0:
		return
	var push := PackedFloat32Array([parameters.x, parameters.y, parameters.z, parameters.w]).to_byte_array()
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _compute_pipeline)
	if uniform_set.is_valid():
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, ceili(float(dispatch_size.x) / workgroup_size.x), ceili(float(dispatch_size.y) / workgroup_size.y), 1)
	rd.compute_list_end()

func _render_raster(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	var target := _resolve_raster_target(buffers, view)
	if not target.is_valid():
		_report("Raster target is unavailable.")
		return
	var binding_data := _collect_bindings(buffers, view, rd)
	if _binding_error:
		return
	var textures: Array[RID] = binding_data["textures"]
	for texture in textures:
		if texture == target:
			_report("Raster input and output refer to the same texture; use an intermediate output to avoid feedback.")
			return
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	var uniform_set := _make_uniform_set(uniforms)
	if not uniforms.is_empty() and not uniform_set.is_valid():
		return
	var framebuffer := rd.framebuffer_create([target])
	if not framebuffer.is_valid():
		_report("Cannot create framebuffer for raster target.")
		return
	var pipeline := _get_raster_pipeline(rd, framebuffer)
	if not pipeline.is_valid():
		rd.free_rid(framebuffer)
		return
	var push := PackedFloat32Array([parameters.x, parameters.y, parameters.z, parameters.w]).to_byte_array()
	var list := rd.draw_list_begin(framebuffer)
	rd.draw_list_bind_render_pipeline(list, pipeline)
	if uniform_set.is_valid():
		rd.draw_list_bind_uniform_set(list, uniform_set, 0)
	rd.draw_list_set_push_constant(list, push, push.size())
	rd.draw_list_draw(list, false, 1, 3)
	rd.draw_list_end()
	rd.free_rid(framebuffer)

func _resolve_raster_target(buffers: RenderSceneBuffersRD, view: int) -> RID:
	var target := _selected_target(true)
	if target == &"":
		return buffers.get_color_layer(view)
	if not buffers.has_texture(PIPELINE_SCOPE, target):
		return RID()
	return buffers.get_texture_slice(PIPELINE_SCOPE, target, view, 0, 1, 1)

func _selected_target(raster: bool) -> StringName:
	var explicit := raster_target if raster else dispatch_target
	if explicit != &"":
		return explicit
	return target_name

func _get_raster_pipeline(rd: RenderingDevice, framebuffer: RID) -> RID:
	var framebuffer_format := rd.framebuffer_get_format(framebuffer)
	# Pipelines depend on the framebuffer format, not on the per-frame
	# framebuffer instance. Keeping the attachment RID out of this key avoids a
	# pipeline leak when a raster pass runs every frame.
	var key := str(framebuffer_format) + "|" + _keyword_signature_now()
	if _raster_pipelines.has(key):
		return _raster_pipelines[key]
	var raster_state := RDPipelineRasterizationState.new()
	raster_state.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var multisample_state := RDPipelineMultisampleState.new()
	var depth_stencil_state := RDPipelineDepthStencilState.new()
	var blend_state := RDPipelineColorBlendState.new()
	var attachments: Array[RDPipelineColorBlendStateAttachment] = []
	attachments.append(RDPipelineColorBlendStateAttachment.new())
	blend_state.attachments = attachments
	var pipeline := rd.render_pipeline_create(
			_shader,
			framebuffer_format,
			RenderingDevice.INVALID_ID,
			RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
			raster_state,
			multisample_state,
			depth_stencil_state,
			blend_state,
			0,
			0,
			_specialization()
	)
	if not pipeline.is_valid():
		_report("Cannot create raster pipeline.")
		return RID()
	_raster_pipelines[key] = pipeline
	return pipeline

func _destroy_shader_objects(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for pipeline in _raster_pipelines.values():
		if pipeline.is_valid():
			rd.free_rid(pipeline)
	_raster_pipelines.clear()
	if _compute_pipeline.is_valid():
		rd.free_rid(_compute_pipeline)
	_compute_pipeline = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
	_shader = RID()
	_shader_resource = null
	_spirv = null
	_shader_mode = -1
	_keyword_signature = ""

func _cleanup(rd: RenderingDevice) -> void:
	_destroy_shader_objects(rd)
	if rd != null and _sampler.is_valid():
		rd.free_rid(_sampler)
	_sampler = RID()

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# Resource destruction can happen on the main thread while these RIDs were
	# created on the rendering thread. Capture only value types and free them on
	# the render thread; keeping a callback to this Resource would be too late at
	# NOTIFICATION_PREDELETE time.
	var shader := _shader
	var compute_pipeline := _compute_pipeline
	var sampler := _sampler
	var raster_pipelines: Array[RID] = []
	for pipeline in _raster_pipelines.values():
		if pipeline is RID:
			raster_pipelines.append(pipeline)
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		if rd == null:
			return
		for pipeline in raster_pipelines:
			if pipeline.is_valid():
				rd.free_rid(pipeline)
		if compute_pipeline.is_valid():
			rd.free_rid(compute_pipeline)
		if shader.is_valid():
			rd.free_rid(shader)
		if sampler.is_valid():
			rd.free_rid(sampler)
	)

func get_configuration_warnings() -> PackedStringArray:
	var warnings := super.get_configuration_warnings()
	if shader_file == null:
		warnings.append("Shader file is not assigned.")
	if mode == Mode.COMPUTE:
		if workgroup_size.x <= 0 or workgroup_size.y <= 0:
			warnings.append("Compute workgroup size must be positive.")
	else:
		if raster_target != &"":
			var has_target := false
			for output in outputs:
				if output != null and output.name == raster_target:
					has_target = true
			if not has_target:
				warnings.append("Raster target '%s' is not declared by this pass; it must be produced by another pass." % raster_target)
		for output in outputs:
			if output != null and output.name == raster_target and not (output.usage & RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT):
				warnings.append("Raster target '%s' must include COLOR_ATTACHMENT usage." % raster_target)
	return warnings
