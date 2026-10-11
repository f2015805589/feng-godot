@tool
extends RefCounted
## NRD RELAX dispatch adapter. All GPU work stays on Godot's RenderingDevice.
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const DIR := "res://addons/feng-raytracing/shaders/"
const FORMATS := {0: RenderingDevice.DATA_FORMAT_R8_UNORM,
	8: RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,
	27: RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	30: RenderingDevice.DATA_FORMAT_R32_SFLOAT}
var rd: RenderingDevice
var size: Vector2i
var bridge: Object
var layout: Dictionary
var resources: Array[RID] = []
var permanent: Array[RID] = []
var transient: Array[RID] = []
var shaders: Array[RID] = []
var pipelines: Array[RID] = []
var buffers: Array[RID] = []
var samplers: Array[RID] = []
var inputs: Dictionary = {}
var prepare_shader := RID()
var prepare_pipeline := RID()
var output := RID()
var previous_projection := Projection.IDENTITY
var previous_view := Projection.IDENTITY
var previous_jitter := Vector2.ZERO
var error := ""

func keep(rid: RID) -> RID:
	if rid.is_valid(): resources.append(rid)
	return rid

func texture(format: int, dimensions: Vector2i) -> RID:
	var desc := RDTextureFormat.new()
	desc.width = dimensions.x
	desc.height = dimensions.y
	desc.format = format
	desc.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var rid := keep(rd.texture_create(desc, RDTextureView.new()))
	if rid.is_valid(): rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return rid

func initialize(device: RenderingDevice, dimensions: Vector2i) -> bool:
	rd = device
	size = dimensions
	if not ClassDB.class_exists("FengNRDBridge"):
		error = "NRD native extension is unavailable; build feng-raytracing/native."
		return false
	bridge = ClassDB.instantiate("FengNRDBridge")
	if not bridge.call("initialize"):
		error = "NRD RELAX instance creation failed."
		return false
	layout = bridge.call("get_layout")
	for pool_name in ["permanent", "transient"]:
		var pool: Array[RID] = permanent if pool_name == "permanent" else transient
		for desc in layout[pool_name]:
			if not FORMATS.has(desc.format):
				error = "Unsupported NRD pool format: %s" % desc.format
				return false
			var dimensions_small := Vector2i(ceili(float(size.x) / desc.downsample), ceili(float(size.y) / desc.downsample))
			pool.append(texture(FORMATS[desc.format], dimensions_small))
	for desc in layout.pipelines:
		var spirv := RDShaderSPIRV.new()
		spirv.bytecode_compute = desc.spirv
		var shader := keep(rd.shader_create_from_spirv(spirv, "NRD " + desc.name))
		if not shader.is_valid():
			error = "NRD shader creation failed: " + desc.name
			return false
		shaders.append(shader)
		pipelines.append(RID())
	for filter in [RenderingDevice.SAMPLER_FILTER_NEAREST, RenderingDevice.SAMPLER_FILTER_LINEAR]:
		var state := RDSamplerState.new()
		state.min_filter = filter
		state.mag_filter = filter
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		samplers.append(keep(rd.sampler_create(state)))
	for name in ["IN_DIFF_RADIANCE_HITDIST", "IN_NORMAL_ROUGHNESS", "IN_MV", "OUT_DIFF_RADIANCE_HITDIST"]:
		inputs[name] = texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, size)
	inputs["IN_VIEWZ"] = texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, size)
	output = texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, size)
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(DIR + "gi_nrd_prepare.glslinc")
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		error = spirv.compile_error_compute
		return false
	prepare_shader = keep(rd.shader_create_from_spirv(spirv))
	prepare_pipeline = keep(rd.compute_pipeline_create(prepare_shader))
	return prepare_pipeline.is_valid() and output.is_valid()

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
	var view := Projection((frame.camera_transform as Transform3D).affine_inverse())
	var projection: Projection = frame.get("projection_unjittered", frame.projection)
	# NRD uses top-left screen UVs and a conventional up-positive clip space.
	for c in 4: projection[c][1] = -projection[c][1]
	var jitter: Vector2 = -Vector2(frame.get("taa_jitter", Vector2.ZERO)) * Vector2(size) * 0.5
	var dispatches: Array = bridge.call("get_dispatches", {"projection": projection,
		"previous_projection": projection if reset else previous_projection, "view": view,
		"previous_view": view if reset else previous_view, "size": size, "index": generation,
		"jitter": jitter, "previous_jitter": jitter if reset else previous_jitter, "reset": reset})
	if dispatches.is_empty():
		error = "NRD returned no compute dispatches."
		return false
	for i in dispatches.size():
		if not _dispatch(dispatches[i], i): return false
	previous_projection = projection
	previous_view = view
	previous_jitter = jitter
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

func _dispatch(dispatch: Dictionary, index: int) -> bool:
	var shader: RID = shaders[dispatch.pipeline]
	if not pipelines[dispatch.pipeline].is_valid():
		pipelines[dispatch.pipeline] = keep(rd.compute_pipeline_create(shader))
		if not pipelines[dispatch.pipeline].is_valid():
			error = "NRD pipeline creation failed: " + dispatch.name
			return false
	var uniforms: Array[RDUniform] = []
	var sampled_binding: int = layout.texture_binding
	var storage_binding: int = layout.storage_binding
	for desc in dispatch.resources:
		var rid: RID
		if desc.type == "PERMANENT_POOL": rid = permanent[desc.index]
		elif desc.type == "TRANSIENT_POOL": rid = transient[desc.index]
		else: rid = inputs.get(desc.type, RID())
		if not rid.is_valid():
			error = "Missing NRD resource " + desc.type
			return false
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if desc.storage else RenderingDevice.UNIFORM_TYPE_TEXTURE
		uniform.binding = storage_binding if desc.storage else sampled_binding
		uniform.add_id(rid)
		uniforms.append(uniform)
		if desc.storage: storage_binding += 1
		else: sampled_binding += 1
	var set := UniformSetCacheRD.get_cache(shader, layout.resource_set, uniforms)
	if not set.is_valid():
		error = "NRD resource binding failed: " + dispatch.name
		return false
	var constant_set := RID()
	if layout.pipelines[dispatch.pipeline].constants:
		while buffers.size() <= index: buffers.append(keep(rd.uniform_buffer_create(layout.constant_size)))
		var bytes: PackedByteArray = dispatch.constants
		if not bytes.is_empty(): rd.buffer_update(buffers[index], 0, bytes.size(), bytes)
		var constants: Array[RDUniform] = [U.uniform_buffer(layout.constant_binding, buffers[index])]
		for i in samplers.size():
			var sampler := RDUniform.new()
			sampler.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
			sampler.binding = layout.sampler_binding + i
			sampler.add_id(samplers[i])
			constants.append(sampler)
		constant_set = UniformSetCacheRD.get_cache(shader, layout.constant_set, constants)
		if not constant_set.is_valid():
			return false
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipelines[dispatch.pipeline])
	rd.compute_list_bind_uniform_set(list, set, layout.resource_set)
	if constant_set.is_valid(): rd.compute_list_bind_uniform_set(list, constant_set, layout.constant_set)
	rd.compute_list_dispatch(list, dispatch.grid.x, dispatch.grid.y, 1)
	rd.compute_list_end()
	return true
