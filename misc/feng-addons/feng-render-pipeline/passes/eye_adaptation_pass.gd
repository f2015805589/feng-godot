@tool
class_name FengEyeAdaptationPass
extends "pass_base.gd"
## UE-style eye adaptation: 64-bin log-luminance histogram metering plus
## exponential temporal adaptation, then exposure applied to the color buffer
## (color *= scale / adapted).
##
## The metering state lives in one small storage buffer per view (a 64-bin
## histogram plus the adapted luminance), so adaptation is temporal without any
## CPU readback. Placed before other post passes this is the addon equivalent
## of UE's pre-exposure: downstream effects and tone mapping see luminance
## already folded around the middle-gray `scale` target.
##
## `parameters`: x = exposure scale (middle-gray target), y = adaptation speed,
## z/w = the histogram's log-luminance clamp range. The default range
## (2^-13.3 .. 2^18) spans from candlelight to a 60000-energy directional
## light, so adaptation converges to the same image no matter the absolute
## energy — a range too narrow saturates the histogram and leaves the
## frame over-exposed.

const HISTOGRAM_SHADER := "res://addons/feng-render-pipeline/library/eye-adaptation/eye_adaptation_histogram.glsl"
const ADAPT_SHADER := "res://addons/feng-render-pipeline/library/eye-adaptation/eye_adaptation.glsl"
const APPLY_SHADER := "res://addons/feng-render-pipeline/library/eye-adaptation/eye_adaptation_apply.glsl"
const NUM_BINS := 64
const PARAMS_BYTES := NUM_BINS * 4 + 16 # uint histogram[64] + float adapted + padding
const STATE_PRUNE_LIMIT := 16

# x = exposure scale, y = adaptation speed, z/w = luminance clamp range.
@export var parameters := Vector4(1.0, 5.0, 0.0001, 262144.0)

var _histogram_pipeline := RID()
var _adapt_pipeline := RID()
var _apply_pipeline := RID()
var _shaders: Array[RID] = []
var _sampler := RID()
# buffers instance id -> {"wr": WeakRef, "views": {view: {"params": RID, "last_usec": int}}}
var _state: Dictionary = {}
var _frame_parameters: Variant = null

func _init() -> void:
	var color := TextureInput.new()
	color.binding = 0
	color.source = TextureInput.Source.COLOR
	color.binding_type = TextureInput.BindingType.STORAGE_IMAGE
	inputs = [color]

func get_frp_parameters() -> Dictionary:
	return {"parameters": parameters}

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["parameters"])

func _frp_execute(ctx: FRPPassContext) -> void:
	_frame_parameters = get_resolved_parameters(ctx).get("parameters", parameters)
	super._frp_execute(ctx)
	_frame_parameters = null

func _setup(rd: RenderingDevice) -> void:
	super._setup(rd)
	for path in [HISTOGRAM_SHADER, ADAPT_SHADER, APPLY_SHADER]:
		var shader_file: RDShaderFile = load(path)
		if shader_file == null:
			_report("Eye adaptation shader file is missing: " + path)
			return
		var spirv := shader_file.get_spirv()
		if spirv == null or spirv.compile_error_compute != "":
			_report("Eye adaptation shader failed to compile: %s %s" % [path, spirv.compile_error_compute if spirv != null else ""])
			return
		var shader := rd.shader_create_from_spirv(spirv)
		if not shader.is_valid():
			_report("Cannot create eye adaptation shader: " + path)
			return
		_shaders.append(shader)
		var pipeline := rd.compute_pipeline_create(shader)
		if not pipeline.is_valid():
			_report("Cannot create eye adaptation pipeline: " + path)
			return
		match _shaders.size():
			1: _histogram_pipeline = pipeline
			2: _adapt_pipeline = pipeline
			3: _apply_pipeline = pipeline
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(state)

func _get_view_state(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	var key := buffers.get_instance_id()
	var entry: Dictionary = _state.get(key, {})
	if entry.is_empty() or not entry["wr"].get_ref():
		entry = {"wr": weakref(buffers), "views": {}}
		_state[key] = entry
	if _state.size() > STATE_PRUNE_LIMIT:
		for other_key in _state.keys():
			if other_key != key and _state[other_key]["wr"].get_ref() == null:
				for view_state in _state[other_key]["views"].values():
					rd.free_rid(view_state["params"])
				_state.erase(other_key)
	var view_state: Dictionary = entry["views"].get(view, {})
	if view_state.is_empty():
		var params := rd.storage_buffer_create(PARAMS_BYTES)
		if not params.is_valid():
			_report("Cannot create eye adaptation buffer.")
			return {}
		view_state = {"params": params, "last_usec": 0}
		entry["views"][view] = view_state
	return view_state

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _shaders.size() != 3 or not _sampler.is_valid():
		return
	var color := buffers.get_color_layer(view)
	if not color.is_valid():
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var state := _get_view_state(buffers, view, rd)
	if state.is_empty():
		return
	var params: RID = state["params"]
	var value: Vector4 = _frame_parameters if _frame_parameters is Vector4 else parameters

	var now_usec := Time.get_ticks_usec()
	var last_usec: int = state["last_usec"]
	state["last_usec"] = now_usec
	var dt := clampf(float(now_usec - last_usec) / 1000000.0, 0.0, 0.5)
	var set_immediate := last_usec == 0
	var adjust := maxf(value.y * dt, 0.0)

	var log_min := log(maxf(value.z, 0.0001)) / log(2.0)
	var log_max := log(maxf(value.w, value.z)) / log(2.0)

	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 0
	params_uniform.add_id(params)

	var list := rd.compute_list_begin()

	# Meter the frame's luminance into a 64-bin log histogram.
	var source_uniform := RDUniform.new()
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	source_uniform.binding = 0
	source_uniform.add_id(_sampler)
	source_uniform.add_id(color)
	var histogram_set := UniformSetCacheRD.get_cache(_shaders[0], 0, [source_uniform])
	var histogram_params_set := UniformSetCacheRD.get_cache(_shaders[0], 1, [params_uniform])
	if not histogram_set.is_valid() or not histogram_params_set.is_valid():
		rd.compute_list_end()
		_report("Eye adaptation histogram bindings are invalid.")
		return
	var histogram_push := PackedInt32Array([size.x, size.y]).to_byte_array() + PackedFloat32Array([
		log_min, 1.0 / maxf(log_max - log_min, 0.001), 0.0, 0.0, 0.0, 0.0,
	]).to_byte_array()
	rd.compute_list_bind_compute_pipeline(list, _histogram_pipeline)
	rd.compute_list_bind_uniform_set(list, histogram_set, 0)
	rd.compute_list_bind_uniform_set(list, histogram_params_set, 1)
	rd.compute_list_set_push_constant(list, histogram_push, histogram_push.size())
	rd.compute_list_dispatch(list, ceili(float(size.x) / 16.0), ceili(float(size.y) / 16.0), 1)
	rd.compute_list_add_barrier(list)

	# Adapt towards the weighted log-average (UE PostProcessEyeAdaptation).
	var adapt_set := UniformSetCacheRD.get_cache(_shaders[1], 0, [params_uniform])
	if not adapt_set.is_valid():
		rd.compute_list_end()
		_report("Eye adaptation bindings are invalid.")
		return
	var adapt_push := PackedFloat32Array([
		adjust, log_min, log_max - log_min, value.z, value.w,
		float(size.x) * float(size.y), 1.0 if set_immediate else 0.0, 0.0,
	]).to_byte_array()
	rd.compute_list_bind_compute_pipeline(list, _adapt_pipeline)
	rd.compute_list_bind_uniform_set(list, adapt_set, 0)
	rd.compute_list_set_push_constant(list, adapt_push, adapt_push.size())
	rd.compute_list_dispatch(list, 1, 1, 1)

	rd.compute_list_end()

	# Apply: color *= scale / adapted. Separate compute list — the color texture
	# is sampled above and written as a storage image here, which the tracker
	# only allows as distinct usages across different compute lists.
	var apply_set := UniformSetCacheRD.get_cache(_shaders[2], 0, [_image_uniform(color)])
	var apply_params_set := UniformSetCacheRD.get_cache(_shaders[2], 1, [params_uniform])
	if not apply_set.is_valid() or not apply_params_set.is_valid():
		_report("Eye adaptation apply bindings are invalid.")
		return
	var apply_push := PackedFloat32Array([value.x, 0.0, 0.0, 0.0]).to_byte_array()
	var apply_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(apply_list, _apply_pipeline)
	rd.compute_list_bind_uniform_set(apply_list, apply_set, 0)
	rd.compute_list_bind_uniform_set(apply_list, apply_params_set, 1)
	rd.compute_list_set_push_constant(apply_list, apply_push, apply_push.size())
	rd.compute_list_dispatch(apply_list, ceili(float(size.x) / 16.0), ceili(float(size.y) / 16.0), 1)
	rd.compute_list_end()

func _image_uniform(texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture)
	return uniform

func _cleanup(rd: RenderingDevice) -> void:
	super._cleanup(rd)
	if rd == null:
		return
	for entry in _state.values():
		for view_state in entry["views"].values():
			rd.free_rid(view_state["params"])
	_state.clear()
	for rid in [_histogram_pipeline, _adapt_pipeline, _apply_pipeline, _sampler]:
		if rid.is_valid():
			rd.free_rid(rid)
	for shader in _shaders:
		if shader.is_valid():
			rd.free_rid(shader)
	_histogram_pipeline = RID()
	_adapt_pipeline = RID()
	_apply_pipeline = RID()
	_sampler = RID()
	_shaders.clear()

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# Value-capture the RIDs: the resource is being torn down, so only local
	# state is safe to touch (see FengRuntimeSnapshotPass._free_on_render_thread).
	var rids: Array[RID] = [_histogram_pipeline, _adapt_pipeline, _apply_pipeline, _sampler]
	for entry in _state.values():
		for view_state in entry["views"].values():
			rids.append(view_state["params"])
	for shader in _shaders:
		rids.append(shader)
	_histogram_pipeline = RID()
	_adapt_pipeline = RID()
	_apply_pipeline = RID()
	_sampler = RID()
	_state.clear()
	_shaders.clear()
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		if rd != null:
			for rid in rids:
				if rid is RID and rid.is_valid():
					rd.free_rid(rid)
	)
