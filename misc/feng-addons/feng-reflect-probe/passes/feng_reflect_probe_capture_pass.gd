@tool
class_name FengReflectProbeCapturePass
extends "res://addons/feng-render-pipeline/passes/pass_base.gd"
## Copies the private viewport's linear HDR color after Transparent and builds a
## complete six-face, GGX-filtered cubemap before publishing its RD RID.

const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const Runtime = preload("../rendering/feng_reflect_probe_runtime.gd")
const COPY_SHADER_PATH := "res://addons/feng-reflect-probe/shaders/probe_capture_copy.glslinc"
const CONVERT_SHADER_PATH := "res://addons/feng-reflect-probe/shaders/probe_capture_convert.glslinc"
const PREFILTER_SHADER_PATH := "res://addons/feng-reflect-probe/shaders/probe_prefilter.glslinc"
const WORKGROUP_SIZE := 8
const CUBE_SIZE := 128
const MIP_COUNT := 8

var _copy_shader := RID()
var _copy_pipeline := RID()
var _convert_shader := RID()
var _convert_pipeline := RID()
var _prefilter_shader := RID()
var _prefilter_pipeline := RID()
var _sampler := RID()
var _copy_ubo := RID()
var _convert_ubo := RID()
var _prefilter_ubo := RID()
var _capture_state: Dictionary = {}
var _retired_capture_states: Array[Dictionary] = []
var _published_capture_rid := RID()
var _frame_snapshot: Dictionary = {}
var _frame_context: FRPPassContext

func _init() -> void:
	resource_name = "Feng Probe HDR Capture"
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	inputs = _make_inputs()
	outputs = []
	access_resolved_color = true
	access_resolved_depth = false

func _make_inputs() -> Array[FengPassTexture]:
	var input := FengPassTexture.new()
	input.binding = 0
	input.source = FengPassTexture.Source.COLOR
	return [input]

func ensure_frp_contract() -> bool:
	if inputs.size() == 1 and inputs[0] != null \
			and inputs[0].binding == 0 and inputs[0].source == FengPassTexture.Source.COLOR:
		return false
	inputs = _make_inputs()
	outputs = []
	access_resolved_color = true
	access_resolved_depth = false
	return true

func _frp_prepare(ctx: FRPPassContext) -> void:
	_frame_context = ctx
	_frame_snapshot.clear()
	if ctx == null:
		return
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	_frame_snapshot = Runtime.capture_snapshot_for_target(buffers.get_render_target())

func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null or _frame_snapshot.is_empty() or not bool(_frame_snapshot.get("active", false)):
		_frame_context = null
		_frame_snapshot.clear()
		return
	var data := ctx.get_render_data()
	if data != null:
		_render_callback(effect_callback_type, data)
	_frame_context = null
	_frame_snapshot.clear()

func _setup(rd: RenderingDevice) -> void:
	_copy_shader = _compile_shader(rd, COPY_SHADER_PATH, "Feng Probe HDR Copy")
	if _copy_shader.is_valid(): _copy_pipeline = rd.compute_pipeline_create(_copy_shader)
	_convert_shader = _compile_shader(rd, CONVERT_SHADER_PATH, "Feng Probe Cube Convert")
	if _convert_shader.is_valid(): _convert_pipeline = rd.compute_pipeline_create(_convert_shader)
	_prefilter_shader = _compile_shader(rd, PREFILTER_SHADER_PATH, "Feng Probe GGX Prefilter")
	if _prefilter_shader.is_valid(): _prefilter_pipeline = rd.compute_pipeline_create(_prefilter_shader)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(state)
	_copy_ubo = rd.uniform_buffer_create(32)
	_convert_ubo = rd.uniform_buffer_create(16)
	_prefilter_ubo = rd.uniform_buffer_create(32)
	_sync_owned_rids()

func _compile_shader(rd: RenderingDevice, path: String, label: String) -> RID:
	if not FileAccess.file_exists(path):
		_report("Missing capture shader: " + path)
		return RID()
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(path)
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		_report(label + " compilation failed: " + spirv.compile_error_compute)
		return RID()
	return rd.shader_create_from_spirv(spirv, label)

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if view != 0 or _frame_snapshot.is_empty() or not bool(_frame_snapshot.get("active", false)):
		return
	var owner_id := int(_frame_snapshot.get("owner_id", 0))
	var batch_id := int(_frame_snapshot.get("batch_id", 0))
	var step := int(_frame_snapshot.get("step", -1))
	if owner_id <= 0 or batch_id <= 0 or step < 0:
		return
	if not Runtime.is_capture_current(buffers.get_render_target(), owner_id, batch_id, step):
		return
	if not _copy_pipeline.is_valid() or not _convert_pipeline.is_valid() \
			or not _prefilter_pipeline.is_valid() or not _sampler.is_valid():
		_fail_step(owner_id, batch_id, step, "Capture shaders or pipelines are not ready.")
		return
	var resolution := clampi(int(_frame_snapshot.get("resolution", 128)), 16, 2048)
	if not _ensure_capture_state(rd, resolution):
		_fail_step(owner_id, batch_id, step, "HDR capture resources could not be allocated.")
		return
	var phase := StringName(_frame_snapshot.get("phase", &""))
	var next_mip := int(_frame_snapshot.get("mip_index", 0))
	if phase == &"face":
		var face := int(_frame_snapshot.get("face_index", -1))
		if face < 0 or face >= 6:
			_fail_step(owner_id, batch_id, step, "The capture face index is outside the cubemap.")
			return
		if not _dispatch_capture_face(rd, buffers, view, face, resolution):
			_fail_step(owner_id, batch_id, step, "HDR face copy dispatch failed.")
			return
		if face == 5:
			if not _dispatch_convert(rd, resolution):
				_fail_step(owner_id, batch_id, step, "Cubemap orientation conversion failed.")
				return
			if bool(_frame_snapshot.get("bake_requested", false)):
				_request_bake_readback(rd, owner_id, batch_id)
			next_mip = 0
			if not _dispatch_prefilter_range(rd, next_mip, int(_frame_snapshot.get("mips_per_step", 2))):
				_fail_step(owner_id, batch_id, step, "GGX prefilter dispatch failed.")
				return
			next_mip = mini(MIP_COUNT, next_mip + maxi(1, int(_frame_snapshot.get("mips_per_step", 2))))
	else:
		if phase != &"prefilter" or not bool(_capture_state.get("converted", false)):
			_fail_step(owner_id, batch_id, step, "Capture step does not follow the completed six-face conversion.")
			return
		var mip_budget := maxi(1, int(_frame_snapshot.get("mips_per_step", 2)))
		if not _dispatch_prefilter_range(rd, next_mip, mip_budget):
			_fail_step(owner_id, batch_id, step, "GGX prefilter dispatch failed.")
			return
		next_mip = mini(MIP_COUNT, next_mip + mip_budget)
	var completed := next_mip >= MIP_COUNT
	if completed and not _publish_complete_cube(buffers.get_render_target(), owner_id, batch_id):
		_fail_step(owner_id, batch_id, step, "The complete cubemap candidate could not be published.")
		return
	Runtime.complete_capture_step(owner_id, batch_id, step, {
		"phase": "complete" if completed else ("prefilter" if int(_frame_snapshot.get("face_index", -1)) == 5 or phase == &"prefilter" else "face"),
		"next_mip": next_mip, "complete": completed, "error": ""})

func _ensure_capture_state(rd: RenderingDevice, resolution: int) -> bool:
	if int(_capture_state.get("resolution", 0)) == resolution and not _capture_state.is_empty():
		return true
	var next := _create_capture_state(rd, resolution)
	if next.is_empty():
		return false
	if not _capture_state.is_empty():
		_retired_capture_states.append(_capture_state)
	_capture_state = next
	_sync_owned_rids()
	return true

func _create_capture_state(rd: RenderingDevice, resolution: int) -> Dictionary:
	var face_format := RDTextureFormat.new()
	face_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	face_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	face_format.width = resolution
	face_format.height = resolution
	face_format.depth = 1
	face_format.array_layers = 6
	face_format.mipmaps = 1
	face_format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	face_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var faces := rd.texture_create(face_format, RDTextureView.new())
	var raw := _create_cube(rd, resolution, 1, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	var filtered: Array[RID] = []
	var mip_views: Array = []
	for _slot in 2:
		var cube := _create_cube(rd, CUBE_SIZE, MIP_COUNT,
				RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
				| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
		filtered.append(cube)
		mip_views.append(_create_cube_mip_views(rd, cube))
	var state := {"resolution": resolution, "faces": faces, "raw": raw,
			"filtered": filtered, "mip_views": mip_views, "published_slot": -1,
			"write_slot": 0, "converted": false, "bake_requested_batch": -1}
	if not faces.is_valid() or not raw.is_valid() \
			or filtered.size() != 2 or not filtered[0].is_valid() or not filtered[1].is_valid() \
			or mip_views.size() != 2 or mip_views[0].size() != MIP_COUNT or mip_views[1].size() != MIP_COUNT:
		_free_capture_state(rd, state)
		return {}
	return state

func _create_cube(rd: RenderingDevice, size: int, mips: int, usage: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_CUBE
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = size
	format.height = size
	format.depth = 1
	format.array_layers = 6
	format.mipmaps = mips
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = usage
	return rd.texture_create(format, RDTextureView.new())

func _create_cube_mip_views(rd: RenderingDevice, cube: RID) -> Array[RID]:
	var result: Array[RID] = []
	if not cube.is_valid():
		return result
	for mip in MIP_COUNT:
		var view := rd.texture_create_shared_from_slice(RDTextureView.new(), cube, 0, mip, 1,
				RenderingDevice.TEXTURE_SLICE_CUBEMAP)
		if not view.is_valid():
			for created in result:
				if created.is_valid(): rd.free_rid(created)
			return []
		result.append(view)
	return result

func _dispatch_capture_face(rd: RenderingDevice, buffers: RenderSceneBuffersRD,
			view: int, face: int, resolution: int) -> bool:
	var scene_color := buffers.get_color_layer(view)
	var faces: RID = _capture_state.get("faces", RID())
	if not scene_color.is_valid() or not faces.is_valid():
		return false
	var exposure := 1.0
	if _frame_context != null:
		exposure = float(_frame_context.get_pre_exposure(view)) \
				* float(_frame_context.get_scene_exposure_normalization())
	if not is_finite(exposure) or exposure <= 1e-8:
		return false
	var bytes := PackedInt32Array([resolution, resolution, face, 0]).to_byte_array()
	bytes.append_array(PackedFloat32Array([exposure, 0.0, 0.0, 0.0]).to_byte_array())
	if rd.buffer_update(_copy_ubo, 0, bytes.size(), bytes) != OK:
		return false
	var set := UniformSetCacheRD.get_cache(_copy_shader, 0, [
			U.sampled(0, _sampler, scene_color), U.image(1, faces), U.uniform_buffer(2, _copy_ubo)])
	if not set.is_valid():
		return false
	return _dispatch(rd, _copy_pipeline, set, ceili(float(resolution) / WORKGROUP_SIZE),
			ceili(float(resolution) / WORKGROUP_SIZE), 1)

func _dispatch_convert(rd: RenderingDevice, resolution: int) -> bool:
	var bytes := PackedInt32Array([resolution, resolution, 0, 0]).to_byte_array()
	if rd.buffer_update(_convert_ubo, 0, bytes.size(), bytes) != OK:
		return false
	var raw: RID = _capture_state.get("raw", RID())
	var faces: RID = _capture_state.get("faces", RID())
	var set := UniformSetCacheRD.get_cache(_convert_shader, 0, [
			U.sampled(0, _sampler, faces), U.image(1, raw), U.uniform_buffer(2, _convert_ubo)])
	if not set.is_valid() or not _dispatch(rd, _convert_pipeline, set,
			ceili(float(resolution) / WORKGROUP_SIZE), ceili(float(resolution) / WORKGROUP_SIZE), 6):
		return false
	_capture_state["converted"] = true
	return true

func _dispatch_prefilter_range(rd: RenderingDevice, first_mip: int, mip_budget: int) -> bool:
	var filtered: Array = _capture_state.get("filtered", [])
	var mip_views: Array = _capture_state.get("mip_views", [])
	if filtered.size() != 2 or mip_views.size() != 2:
		return false
	var published_slot := int(_capture_state.get("published_slot", -1))
	var write_slot := int(_capture_state.get("write_slot", 0))
	if published_slot < 0:
		write_slot = 0
	else:
		write_slot = 1 - published_slot
	_capture_state["write_slot"] = write_slot
	var raw: RID = _capture_state.get("raw", RID())
	for mip in range(first_mip, mini(MIP_COUNT, first_mip + maxi(mip_budget, 1))):
		var mip_size := maxi(1, CUBE_SIZE >> mip)
		var bytes := PackedInt32Array([mip_size, mip_size, 0, mip]).to_byte_array()
		bytes.append_array(PackedFloat32Array([float(MIP_COUNT - 1), 128.0, 0.0, 0.0]).to_byte_array())
		if rd.buffer_update(_prefilter_ubo, 0, bytes.size(), bytes) != OK:
			return false
		var set := UniformSetCacheRD.get_cache(_prefilter_shader, 0, [
				U.sampled(0, _sampler, raw), U.image(1, mip_views[write_slot][mip]),
				U.uniform_buffer(2, _prefilter_ubo)])
		if not set.is_valid() or not _dispatch(rd, _prefilter_pipeline, set,
				ceili(float(mip_size) / WORKGROUP_SIZE), ceili(float(mip_size) / WORKGROUP_SIZE), 6):
			return false
	return true

func _dispatch(rd: RenderingDevice, pipeline: RID, uniform_set: RID,
			x: int, y: int, z: int) -> bool:
	if not pipeline.is_valid() or not uniform_set.is_valid():
		return false
	var list := rd.compute_list_begin()
	if list < 0:
		return false
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, x, y, z)
	rd.compute_list_end()
	return true

func _publish_complete_cube(capture_target: RID, owner_id: int, batch_id: int) -> bool:
	var filtered: Array = _capture_state.get("filtered", [])
	var slot := int(_capture_state.get("write_slot", 0))
	if filtered.size() != 2 or not filtered[slot].is_valid():
		return false
	var snapshot: Dictionary = _frame_snapshot.get("probe_snapshot", {}).duplicate(true)
	snapshot["owner_id"] = owner_id
	snapshot["source_revision"] = int(_frame_snapshot.get("source_revision", batch_id))
	snapshot["radiance_rid"] = filtered[slot]
	snapshot["source_faces"] = []
	snapshot["ready_generation"] = batch_id
	var targets: Array = _frame_snapshot.get("probe_targets", [])
	if targets.is_empty():
		return false
	if not Runtime.publish_capture_probe_targets(capture_target, targets, owner_id, batch_id, snapshot):
		return false
	_capture_state["published_slot"] = slot
	_published_capture_rid = filtered[slot]
	_capture_state["converted"] = false
	for old_state in _retired_capture_states:
		_free_capture_state(RenderingServer.get_rendering_device(), old_state)
	_retired_capture_states.clear()
	_sync_owned_rids()
	return true

func _request_bake_readback(rd: RenderingDevice, owner_id: int, batch_id: int) -> void:
	if int(_capture_state.get("bake_requested_batch", -1)) == batch_id:
		return
	_capture_state["bake_requested_batch"] = batch_id
	var raw: RID = _capture_state.get("raw", RID())
	if not raw.is_valid():
		return
	for face in 6:
		var callback := Callable(Runtime, "publish_bake_face").bind(owner_id, batch_id, face)
		var error := rd.texture_get_data_async(raw, face, callback)
		if error != OK:
			_report("Asynchronous bake readback could not be queued for cubemap face %d." % face)

func _fail_step(owner_id: int, batch_id: int, step: int, message: String) -> void:
	Runtime.complete_capture_step(owner_id, batch_id, step, {"error": message})
	_report(message)

func _free_capture_state(rd: RenderingDevice, state: Dictionary) -> void:
	if rd == null:
		return
	for views in state.get("mip_views", []):
		if views is Array:
			for view in views:
				if view is RID and view.is_valid(): rd.free_rid(view)
	for key in ["faces", "raw"]:
		var value: Variant = state.get(key, RID())
		if value is RID and value.is_valid(): rd.free_rid(value)
	for value in state.get("filtered", []):
		if value is RID and value.is_valid(): rd.free_rid(value)

func _current_owned_rids() -> Array[RID]:
	var result: Array[RID] = [_copy_pipeline, _copy_shader, _convert_pipeline, _convert_shader,
			_prefilter_pipeline, _prefilter_shader, _sampler, _copy_ubo, _convert_ubo, _prefilter_ubo]
	_append_state_rids(result, _capture_state)
	for state in _retired_capture_states:
		_append_state_rids(result, state)
	return result

func _append_state_rids(result: Array[RID], state: Dictionary) -> void:
	for views in state.get("mip_views", []):
		if views is Array:
			for view in views:
				if view is RID: result.append(view)
	for value in [state.get("faces", RID()), state.get("raw", RID())]:
		if value is RID: result.append(value)
	for cube in state.get("filtered", []):
		if cube is RID: result.append(cube)

func _sync_owned_rids() -> void:
	_replace_owned_rid_snapshot(_current_owned_rids())

func _take_owned_rids() -> Array[RID]:
	# PREDELETE may suspend derived Resource dispatch. Use detached field values,
	# and let the PassBase snapshot cover any state unavailable at destruction.
	var capture_value: Variant = super.call("get", "_capture_state")
	var retired_value: Variant = super.call("get", "_retired_capture_states")
	if not capture_value is Dictionary or not retired_value is Array:
		return super._take_owned_rids()
	var owned: Array[RID] = []
	for name in ["_copy_pipeline", "_convert_pipeline", "_prefilter_pipeline",
			"_copy_shader", "_convert_shader", "_prefilter_shader", "_sampler",
			"_copy_ubo", "_convert_ubo", "_prefilter_ubo"]:
		var value: Variant = super.call("get", name)
		if value is RID and value.is_valid():
			owned.append(value)
	var states: Array = [capture_value]
	states.append_array(retired_value)
	for state_value in states:
		if not state_value is Dictionary:
			continue
		var state: Dictionary = state_value
		for views in state.get("mip_views", []):
			if views is Array:
				for view in views:
					if view is RID and view.is_valid():
						owned.append(view)
		for value in [state.get("faces", RID()), state.get("raw", RID())]:
			if value is RID and value.is_valid():
				owned.append(value)
		for cube in state.get("filtered", []):
			if cube is RID and cube.is_valid():
				owned.append(cube)
	capture_value.clear()
	retired_value.clear()
	for name in ["_copy_pipeline", "_convert_pipeline", "_prefilter_pipeline",
			"_copy_shader", "_convert_shader", "_prefilter_shader", "_sampler",
			"_copy_ubo", "_convert_ubo", "_prefilter_ubo", "_published_capture_rid"]:
		super.call("set", name, RID())
	super.call("set", "_frame_snapshot", {})
	super.call("set", "_frame_context", null)
	var rids := super._take_owned_rids()
	rids.append_array(owned)
	return rids

