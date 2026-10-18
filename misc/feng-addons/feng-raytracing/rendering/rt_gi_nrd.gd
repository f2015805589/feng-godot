@tool
extends "res://addons/feng-raytracing/rendering/nrd_relax.gd"
## RTGI-specific signal preparation around the shared NRD RELAX dispatcher.
const DIR := "res://addons/feng-raytracing/shaders/"

var prepare_shader := RID()
var prepare_pipeline := RID()
var output := RID()

func initialize(device: RenderingDevice, dimensions: Vector2i) -> bool:
	if not super.initialize(device, dimensions):
		return false
	output = texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, size)
	if not output.is_valid():
		error = "RTGI denoised output texture creation failed."
		return false
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(DIR + "gi_nrd_prepare.glslinc")
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		error = spirv.compile_error_compute
		return false
	prepare_shader = keep(rd.shader_create_from_spirv(spirv))
	if not prepare_shader.is_valid():
		error = "RTGI NRD preparation shader creation failed."
		return false
	prepare_pipeline = keep(rd.compute_pipeline_create(prepare_shader))
	if not prepare_pipeline.is_valid():
		error = "RTGI NRD preparation pipeline creation failed."
		return false
	return true

func resolve(state: Dictionary, frame: Dictionary, textures: Array[RID], generation: int,
		reset: bool, scale: float, strength: float) -> bool:
	var history: Array = state.history[state.ping]
	var bindings: Array[RDUniform] = [U.sampled(0, samplers[0], state.raw)]
	for i in 4: bindings.append(U.sampled(i + 1, samplers[0], textures[i]))
	bindings.append(U.sampled(5, samplers[0], state.hit_distance))
	for pair in [[6,"IN_DIFF_RADIANCE_HITDIST"],[7,"IN_NORMAL_ROUGHNESS"],[8,"IN_VIEWZ"],[9,"IN_MV"]]:
		bindings.append(U.image(pair[0], inputs[pair[1]]))
	for i in 3: bindings.append(U.image(10 + i, history[2 + i]))
	bindings.append(U.uniform_buffer(13, state.ubo))
	bindings.append(U.image(14, output))
	bindings.append(U.sampled(15, samplers[0], inputs.OUT_DIFF_RADIANCE_HITDIST))
	if not _prepare(bindings, scale, strength, 0): return false
	if not dispatch(frame, generation, reset): return false
	return _prepare(bindings, scale, strength, 1)

func _prepare(bindings: Array[RDUniform], scale: float, strength: float, stage: int) -> bool:
	var set := UniformSetCacheRD.get_cache(prepare_shader, 0, bindings)
	if not set.is_valid(): return false
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, prepare_pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	var push := PackedFloat32Array([scale, float(stage), strength, 0]).to_byte_array()
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	rd.compute_list_end()
	return true
