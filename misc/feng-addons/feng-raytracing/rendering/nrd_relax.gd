@tool
extends RefCounted
## Shared NRD RELAX resources and dispatch lifecycle.
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const MOTION_MODE_WORLD := 0
const MOTION_MODE_SCREEN := 1
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
var previous_projection := Projection.IDENTITY
var previous_view := Projection.IDENTITY
var previous_jitter := Vector2.ZERO
var previous_motion_mode := -1
var error := ""
var resource_binding_plans: Dictionary = {}
var constant_binding_plans: Dictionary = {}

const MAX_BINDING_PLANS_PER_DISPATCH := 4

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

## Creates NRD-owned GPU inputs and shared pools; callers add effect-specific resources.
func initialize(device: RenderingDevice, dimensions: Vector2i) -> bool:
	clear_dispatch_binding_plans()
	previous_motion_mode = -1
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
			var pool_texture := texture(FORMATS[desc.format], dimensions_small)
			if not pool_texture.is_valid():
				error = "NRD %s pool texture creation failed." % pool_name
				return false
			pool.append(pool_texture)
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
		var sampler := keep(rd.sampler_create(state))
		if not sampler.is_valid():
			error = "NRD sampler creation failed."
			return false
		samplers.append(sampler)
	for name in ["IN_DIFF_RADIANCE_HITDIST", "IN_NORMAL_ROUGHNESS", "IN_MV", "OUT_DIFF_RADIANCE_HITDIST"]:
		inputs[name] = texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, size)
	inputs["IN_VIEWZ"] = texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, size)
	for name in inputs:
		if not inputs[name].is_valid():
			error = "NRD input texture creation failed: " + name
			return false
	return true

## Old bridge builds retain the original world-space contract. Screen-space mode
## requires an explicit capability bit so normalized UV motion is never silently
## interpreted as world-space displacement by an older extension binary.
func supports_motion_mode(mode: int) -> bool:
	if bridge == null:
		return false
	if mode == MOTION_MODE_WORLD and not bridge.has_method("get_motion_capabilities"):
		return true
	if mode < MOTION_MODE_WORLD or mode > MOTION_MODE_SCREEN \
			or not bridge.has_method("get_motion_capabilities"):
		return false
	var capabilities := int(bridge.call("get_motion_capabilities"))
	return (capabilities & (1 << mode)) != 0

## Plans contain only RDUniform objects; RenderingDevice RIDs remain owned by resources.
func clear_dispatch_binding_plans() -> void:
	resource_binding_plans.clear()
	constant_binding_plans.clear()

## Dispatches NRD and commits the camera history only after every dispatch succeeds.
func dispatch(frame: Dictionary, generation: int, reset: bool,
		motion_mode: int = MOTION_MODE_WORLD) -> bool:
	if not supports_motion_mode(motion_mode):
		error = "NRD bridge does not support requested motion mode %d" % motion_mode
		return false
	var view := Projection((frame.camera_transform as Transform3D).affine_inverse())
	var projection: Projection = frame.get("projection_unjittered", frame.projection)
	# NRD uses top-left screen UVs and a conventional up-positive clip space.
	for c in 4: projection[c][1] = -projection[c][1]
	var effective_reset := reset or previous_motion_mode != motion_mode
	# Screen-space MV is already the non-jittered prevUV-currentUV vector. NRD's
	# cameraJitter remains a separate sampling input and must still track the
	# renderer's jitter in both motion modes.
	var jitter := -Vector2(frame.get("taa_jitter", Vector2.ZERO)) * Vector2(size) * 0.5
	var dispatches: Array = bridge.call("get_dispatches", {"projection": projection,
		"previous_projection": projection if effective_reset else previous_projection, "view": view,
		"previous_view": view if effective_reset else previous_view, "size": size, "index": generation,
		"jitter": jitter, "previous_jitter": jitter if effective_reset else previous_jitter,
		"delta_ms": frame.get("delta_ms", 0.0), "reset": effective_reset,
		"motion_mode": motion_mode})
	if dispatches.is_empty():
		error = "NRD returned no compute dispatches."
		return false
	for i in dispatches.size():
		if not _dispatch(dispatches[i], i): return false
	previous_projection = projection
	previous_view = view
	previous_jitter = jitter
	previous_motion_mode = motion_mode
	return true

func _dispatch(dispatch: Dictionary, index: int) -> bool:
	var shader: RID = shaders[dispatch.pipeline]
	if not pipelines[dispatch.pipeline].is_valid():
		pipelines[dispatch.pipeline] = keep(rd.compute_pipeline_create(shader))
		if not pipelines[dispatch.pipeline].is_valid():
			error = "NRD pipeline creation failed: " + dispatch.name
			return false
	var resource_descriptors: Array = dispatch.resources
	var resource_signature: Array = [index, int(dispatch.pipeline),
		pipelines[dispatch.pipeline].get_id(), shader.get_id(),
		layout.resource_set, layout.texture_binding, layout.storage_binding]
	var resolved_resources: Array[RID] = []
	var uniforms: Array = []
	var sampled_binding: int = layout.texture_binding
	var storage_binding: int = layout.storage_binding
	for desc in resource_descriptors:
		var rid: RID
		if desc.type == "PERMANENT_POOL": rid = permanent[desc.index]
		elif desc.type == "TRANSIENT_POOL": rid = transient[desc.index]
		else: rid = inputs.get(desc.type, RID())
		if not rid.is_valid():
			error = "Missing NRD resource " + desc.type
			return false
		resource_signature.append(str(desc.type))
		resource_signature.append(int(desc.index))
		resource_signature.append(bool(desc.storage))
		resource_signature.append(rid.get_id())
		resolved_resources.append(rid)
		if desc.storage: storage_binding += 1
		else: sampled_binding += 1
	var plans: Array = resource_binding_plans.get(index, [])
	var cached_resource_plan: Dictionary = {}
	for plan_value in plans:
		var plan: Dictionary = plan_value
		if plan.get("signature", []) == resource_signature:
			cached_resource_plan = plan
			break
	if not cached_resource_plan.is_empty():
		uniforms = cached_resource_plan.get("uniforms", [])
	else:
		sampled_binding = layout.texture_binding
		storage_binding = layout.storage_binding
		for resource_index in resource_descriptors.size():
			var desc: Dictionary = resource_descriptors[resource_index]
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if desc.storage else RenderingDevice.UNIFORM_TYPE_TEXTURE
			uniform.binding = storage_binding if desc.storage else sampled_binding
			uniform.add_id(resolved_resources[resource_index])
			uniforms.append(uniform)
			if desc.storage: storage_binding += 1
			else: sampled_binding += 1
		plans.append({"signature": resource_signature, "uniforms": uniforms})
		if plans.size() > MAX_BINDING_PLANS_PER_DISPATCH:
			plans.pop_front()
		resource_binding_plans[index] = plans
	var set := UniformSetCacheRD.get_cache(shader, layout.resource_set, uniforms)
	if not set.is_valid():
		error = "NRD resource binding failed: " + dispatch.name
		return false
	var constant_set := RID()
	if layout.pipelines[dispatch.pipeline].constants:
		while buffers.size() <= index: buffers.append(keep(rd.uniform_buffer_create(layout.constant_size)))
		var bytes: PackedByteArray = dispatch.constants
		if not bytes.is_empty(): rd.buffer_update(buffers[index], 0, bytes.size(), bytes)
		var constant_signature: Array = [index, int(dispatch.pipeline),
			pipelines[dispatch.pipeline].get_id(), shader.get_id(),
			layout.constant_set, layout.constant_binding, layout.sampler_binding,
			buffers[index].get_id(), samplers.size()]
		for sampler_index in samplers.size():
			constant_signature.append(samplers[sampler_index].get_id())
		var constant_plans: Array = constant_binding_plans.get(index, [])
		var cached_constant_plan: Dictionary = {}
		for plan_value in constant_plans:
			var plan: Dictionary = plan_value
			if plan.get("signature", []) == constant_signature:
				cached_constant_plan = plan
				break
		var constants: Array = []
		if not cached_constant_plan.is_empty():
			constants = cached_constant_plan.get("uniforms", [])
		else:
			constants.append(U.uniform_buffer(layout.constant_binding, buffers[index]))
			for i in samplers.size():
				var sampler := RDUniform.new()
				sampler.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
				sampler.binding = layout.sampler_binding + i
				sampler.add_id(samplers[i])
				constants.append(sampler)
			constant_plans.append({"signature": constant_signature, "uniforms": constants})
			if constant_plans.size() > MAX_BINDING_PLANS_PER_DISPATCH:
				constant_plans.pop_front()
			constant_binding_plans[index] = constant_plans
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
