@tool
class_name FengComputePass
extends CompositorEffect
## A reusable compute pass. Configure stage, shader and texture bindings in a
## Compositor resource; order in its effects array determines same-stage order.
## Shaders use set 0, the declared bindings, and a 16-byte vec4 push constant.

const TextureBinding = preload("pass_texture.gd")

@export var shader_file: RDShaderFile
@export var textures: Array[FengPassTexture] = []
@export var parameters := Vector4(1.0, 1.0, 1.0, 1.0)
@export var workgroup_size := Vector2i(8, 8)

var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _spirv: RDShaderSPIRV
var _last_error := ""

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# Resolved color is the default post-processing input. Additional
	# dependencies use the inherited flags in the inspector.
	access_resolved_color = true

func _report(message: String) -> void:
	if message != _last_error:
		push_error("FengComputePass: " + message)
		_last_error = message

func _render_callback(_stage: int, data: RenderData) -> void:
	if shader_file == null:
		return
	var buffers: RenderSceneBuffersRD = data.get_render_scene_buffers()
	if buffers == null or not buffers.has_texture("deferred_clustered", "gbuffer_albedo"):
		return
	var rd := RenderingServer.get_rendering_device()
	var spirv := shader_file.get_spirv()
	if spirv != _spirv:
		var next_shader := rd.shader_create_from_spirv(spirv)
		if not next_shader.is_valid():
			_report("Shader compilation failed: " + spirv.compile_error_compute)
			return
		var next_pipeline := rd.compute_pipeline_create(next_shader)
		if not next_pipeline.is_valid():
			rd.free_rid(next_shader)
			_report("Cannot create compute pipeline.")
			return
		if _shader.is_valid():
			rd.free_rid(_shader)
		_shader = next_shader
		_pipeline = next_pipeline
		_spirv = spirv
	if not _sampler.is_valid():
		var state := RDSamplerState.new()
		state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		_sampler = rd.sampler_create(state)
	if workgroup_size.x <= 0 or workgroup_size.y <= 0:
		_report("Workgroup size must match the shader and be positive.")
		return
	var push := PackedFloat32Array([parameters.x, parameters.y, parameters.z, parameters.w]).to_byte_array()
	var size := buffers.get_internal_size()
	for view in buffers.get_view_count():
		var uniforms: Array[RDUniform] = []
		var used_bindings := {}
		for declaration in textures:
			if declaration == null or used_bindings.has(declaration.binding):
				_report("Texture declarations must be non-null and use unique bindings.")
				return
			used_bindings[declaration.binding] = true
			var texture := declaration.get_texture(buffers, view)
			if not texture.is_valid():
				_report("Texture is unavailable at the selected stage: binding " + str(declaration.binding))
				return
			var uniform := RDUniform.new()
			uniform.binding = declaration.binding
			if declaration.binding_type == TextureBinding.BindingType.SAMPLED_TEXTURE:
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				uniform.add_id(_sampler)
			else:
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			uniform.add_id(texture)
			uniforms.append(uniform)
		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)
		if not uniform_set.is_valid():
			_report("Bindings do not match the shader layout or texture usage.")
			return
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, ceili(float(size.x) / workgroup_size.x), ceili(float(size.y) / workgroup_size.y), 1)
		rd.compute_list_end()
	_last_error = ""

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		var shader := _shader
		var sampler := _sampler
		RenderingServer.call_on_render_thread(func():
			var rd := RenderingServer.get_rendering_device()
			if rd:
				if shader.is_valid():
					rd.free_rid(shader)
				if sampler.is_valid():
					rd.free_rid(sampler))
