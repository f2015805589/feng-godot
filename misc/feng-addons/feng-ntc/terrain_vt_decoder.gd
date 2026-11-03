@tool
extends RefCounted
const Features = preload("gpu_decoder.gd")
## Owned by Terrain3DSurfaceBaker. Every method touching RIDs runs on the main RD
## render thread. Decodes directly into its existing three canonical page arrays.
var packages: Array[Dictionary] = []
var cache_limit := 2
var _rd: RenderingDevice
var _models: Dictionary = {}
var _pipelines: Dictionary = {}
var _clock := 0
var _error := ""
var _disposed := false


func decode_page(entry: Dictionary, targets: Array, layer: int) -> Dictionary:
	if _disposed: return {"ok": false}
	if _rd == null: _rd = RenderingServer.get_rendering_device()
	if _rd == null or targets.size() != 3 or layer < 0: return {"ok": false}
	var index := int(entry.get("model", -1))
	var rect: Rect2i = entry.get("rect", Rect2i())
	if index < 0 or index >= packages.size() or rect.size.x < 1 or rect.size.y < 1: return {"ok": false}
	for target: RID in targets:
		if not _rd.texture_is_valid(target): return {"ok": false}
	var format := _rd.texture_get_format(targets[0])
	if rect.size.x != format.width or rect.size.y != format.height or layer >= format.array_layers: return {"ok": false}
	var window := Features.page_window(packages[index], rect, 0, 4*1024*1024)
	if not window.get("ok", false): return {"ok": false}
	var model := _model(index, window, rect)
	if model.is_empty(): return {"ok": false}
	if model.staged_rect != rect:
		var latent_bytes: PackedByteArray = window.latents
		var layout_bytes: PackedByteArray = window.layout
		_rd.buffer_update(model.buffers[2], 0, latent_bytes.size(), latent_bytes)
		_rd.buffer_update(model.buffers[3], 0, layout_bytes.size(), layout_bytes)
		model.staged_rect = rect
	_clock += 1
	model.used = _clock
	if model.get("targets", []) != targets:
		if model.get("set", RID()).is_valid() and _rd.uniform_set_is_valid(model.set): _rd.free_rid(model.set)
		var uniforms: Array[RDUniform] = []
		for i in range(4): uniforms.append(_uniform(i, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, model.buffers[i]))
		for i in range(3): uniforms.append(_uniform(4+i, RenderingDevice.UNIFORM_TYPE_IMAGE, targets[i]))
		model.set = _rd.uniform_set_create(uniforms, model.shader, 0)
		model.targets = targets.duplicate()
	if not model.set.is_valid(): return {"ok": false}
	var push := PackedInt32Array([rect.position.x, rect.position.y, rect.size.x, rect.size.y, 0, 0, 0, int(packages[index].layers), 0, 4, 8, layer, 0, 0, 0, 0]).to_byte_array()
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, model.pipeline)
	_rd.compute_list_bind_uniform_set(list, model.set, 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, ceili(rect.size.x / 8.0), ceili(rect.size.y / 8.0), 1)
	_rd.compute_list_end()
	var bytes := 0
	for item: Dictionary in _models.values(): bytes += int(item.bytes)
	return {"ok": true, "gpu_bytes": bytes}


func _model(index: int, window: Dictionary, rect: Rect2i) -> Dictionary:
	if _models.has(index):
		if int(_models[index].latent_capacity) >= window.latents.size(): return _models[index]
		_free_model(_models[index])
		_models.erase(index)
	if _models.size() >= cache_limit:
		var oldest := int(_models.keys()[0])
		for key: int in _models:
			if int(_models[key].used) < int(_models[oldest].used): oldest = key
		_free_model(_models[oldest])
		_models.erase(oldest)
	var data: Dictionary = packages[index]
	var shape := int(data.layers)
	if not _pipelines.has(shape):
		var source := FileAccess.get_file_as_string("res://addons/feng-ntc/shaders/decode.glsl").replace("#[compute]", "")
		source = source.replace("#define NTC_LATENT_LAYERS 4", "#define NTC_LATENT_LAYERS %d" % shape).replace("#define NTC_OUTPUT_CHANNELS 16", "#define NTC_OUTPUT_CHANNELS 12")
		source = source.replace("rgba8) uniform writeonly image2D", "rgba16f) uniform writeonly image2DArray")
		var begin := source.find("vec4 output_map(")
		var end := source.find("void main()", begin)
		if begin < 0 or end < begin: return {}
		# Preserve signed/HDR linear VT values. No UNORM8 clamp, colour conversion,
		# tangent normal decode, mip resize or material blending at runtime.
		source = source.substr(0, begin) + "vec4 output_map(uint v[16], int first, int count) { vec4 value; for(int i=0;i<4;++i) { int ch=first+i; value[i]=linearize(uintBitsToFloat(v[ch]),(c[81]>>uint(ch*2))&3u); } return value; }\n" + source.substr(end)
		source = source.replace("imageStore(albedo_out,destination,output_map(output_values,p.maps.x,4));", "imageStore(albedo_out,ivec3(destination,p.maps.w),output_map(output_values,0,4));")
		source = source.replace("if(p.maps.y>=0) imageStore(normal_out,destination,output_map(output_values,p.maps.y,3));", "vec4 n=output_map(output_values,4,4); n.rgb=normalize(n.rgb+vec3(0.0,1e-12,0.0)); n.a=clamp(n.a,0.0,1.0); imageStore(normal_out,ivec3(destination,p.maps.w),n);")
		source = source.replace("if(p.maps.z>=0) imageStore(orm_out,destination,output_map(output_values,p.maps.z,3));", "vec4 parameters=output_map(output_values,8,4); parameters.a=step(0.5,parameters.a); imageStore(orm_out,ivec3(destination,p.maps.w),parameters);")
		var shader_source := RDShaderSource.new()
		shader_source.source_compute = source
		var spirv := _rd.shader_compile_spirv_from_source(shader_source)
		_error = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not _error.is_empty(): push_error("NTC VT shader: " + _error); return {}
		var shader := _rd.shader_create_from_spirv(spirv)
		var pipeline := _rd.compute_pipeline_create(shader)
		if not shader.is_valid() or not pipeline.is_valid(): return {}
		_pipelines[shape] = {"shader": shader, "pipeline": pipeline}
	# Upload only the two feature windows needed for this page, including taps
	# across its gutter. The full virtual atlas and other mips stay compressed on CPU.
	var latent_capacity: int = ((window.latents.size()+4095)/4096+1)*4096
	var latents: PackedByteArray = window.latents.duplicate()
	latents.resize(latent_capacity)
	var buffers: Array[RID] = []
	var bytes := 0
	for value: PackedByteArray in [window.constants, data.weights, latents, window.layout]:
		var buffer := _rd.storage_buffer_create(value.size(), value)
		if not buffer.is_valid():
			for allocated: RID in buffers: _rd.free_rid(allocated)
			return {}
		buffers.append(buffer)
		bytes += value.size()
	var result: Dictionary = {"buffers": buffers, "bytes": bytes, "used": _clock, "shader": _pipelines[shape].shader, "pipeline": _pipelines[shape].pipeline, "set": RID(), "latent_capacity": latent_capacity, "staged_rect": rect}
	_models[index] = result
	return result


func _free_model(model: Dictionary) -> void:
	if model.set.is_valid() and _rd.uniform_set_is_valid(model.set): _rd.free_rid(model.set)
	for buffer: RID in model.buffers: _rd.free_rid(buffer)


func dispose() -> void:
	_disposed = true
	if _rd == null: return
	for model: Dictionary in _models.values(): _free_model(model)
	for item: Dictionary in _pipelines.values():
		_rd.free_rid(item.pipeline)
		_rd.free_rid(item.shader)
	_models.clear()
	_pipelines.clear()
	_rd = null


static func _uniform(binding: int, type: int, rid: RID) -> RDUniform:
	var result := RDUniform.new()
	result.binding = binding
	result.uniform_type = type
	result.add_id(rid)
	return result
