@tool
extends RefCounted
## Per-target/view NRD RELAX adapter for Surfel MagicGI.
##
## The world cache remains shared and camera independent. Each view owns its own
## raw guide textures and NRD history so one camera never filters another view's
## screen-space signal.

const U = preload("../rd/uniforms.gd")
const CORE_PATH := "res://addons/feng-raytracing/rendering/nrd_relax.gd"
const EXTENSION_PATH := "res://addons/feng-raytracing/feng_nrd.gdextension"
const SHADER_DIR := "res://addons/feng-render-pipeline/library/magic-gi/surfel/"
const PREP_SHADER_PATH := SHADER_DIR + "magic_gi_surfel_nrd_prepare.glsl"
const COMPOSE_SHADER_PATH := SHADER_DIR + "magic_gi_surfel_nrd_compose.glsl"
const MAX_VIEWS := 8
const NRD_MOTION_MODE_SCREEN := 1
const PREP_UBO_BYTES := 160
const COMPOSE_UBO_BYTES := 256

var rd: RenderingDevice
var error := ""
var resource_revision := 0
var _core_script: Script
var _core_script_checked := false
var _extension_checked := false
var _views: Dictionary = {}
var _clock := 0
var _owned_shared: Array[RID] = []
var _prep_shader := RID()
var _prep_pipeline := RID()
var _compose_shader := RID()
var _compose_pipeline := RID()
var _black_2d := RID()
var _white_ao := RID()


func get_resource_revision() -> int:
	return resource_revision


func has_owned_resources() -> bool:
	return _has_owned_resources()


func prepare_view(device: RenderingDevice, frame: Dictionary, snapshot: Dictionary,
		full_size: Vector2i, render_target_id: int, view_index: int,
		motion_vectors: RID) -> Dictionary:
	error = ""
	if device == null:
		return _inactive("RenderingDevice is unavailable")
	if not motion_vectors.is_valid():
		return _inactive("FRP motion-vector attachment is unavailable")
	if rd != null and rd != device:
		release_all()
	rd = device
	var settings_value: Variant = snapshot.get("surfel_settings", {})
	var settings: Dictionary = settings_value if settings_value is Dictionary else {}
	if int(settings.get("denoiser", 0)) != 0:
		if _has_owned_resources():
			release_all()
		return _inactive("World Cache denoiser selected")
	if full_size.x <= 0 or full_size.y <= 0:
		return _inactive("viewport size is invalid")
	if not _ensure_nrd_extension():
		return _inactive(error)
	if not _ensure_shared_resources():
		return _inactive(error)
	var half_resolution := bool(settings.get("half_resolution", true))
	var output_size := Vector2i(
		maxi(1, ceili(float(full_size.x) / (2.0 if half_resolution else 1.0))),
		maxi(1, ceili(float(full_size.y) / (2.0 if half_resolution else 1.0))))
	var camera_generation := int(frame.get("camera_generation", 0))
	var frame_token := int(frame.get("frame_generation", 0))
	var key := "%d:%d:%d" % [render_target_id, view_index, camera_generation]
	var metadata := _metadata(frame, snapshot, full_size, output_size)
	_clock += 1
	var state: Dictionary = _views.get(key, {})
	var reset := state.is_empty()
	var reset_reason := "new_view" if reset else ""
	if not state.is_empty():
		var pending_reset := bool(state.get("reset_pending", false))
		var pending_reason := str(state.get("reset_reason", ""))
		reset_reason = _invalidation_reason(state, metadata, frame, frame_token)
		reset = pending_reset or not reset_reason.is_empty()
		if pending_reset and not pending_reason.is_empty():
			reset_reason = pending_reason
		if Vector2i(state.get("size", Vector2i.ZERO)) != output_size:
			_release_view(state)
			_views.erase(key)
			state = {}
			reset = true
			reset_reason = "denoiser_resolution_changed"
	if state.is_empty():
		state = _create_view_state(output_size)
		if state.is_empty():
			return _inactive(error)
		_views[key] = state
		reset = true
		if reset_reason.is_empty():
			reset_reason = "new_view"
	state["metadata"] = metadata
	state["reset_pending"] = reset
	state["reset_reason"] = reset_reason
	if reset:
		state["last_reset_reason"] = reset_reason
	state["last_used"] = _clock
	state["target_key"] = key
	state["last_frame_attempt"] = frame_token
	_views[key] = state
	_prune_views(key)
	return {"active": true, "raw": state.raw, "auxiliary": state.auxiliary,
		"size": output_size, "key": key, "reset": reset,
		"reset_reason": reset_reason}


func resolve_view(frame: Dictionary, snapshot: Dictionary, full_size: Vector2i,
		textures: Array[RID], motion_vectors: RID, color: RID, output: RID, sky_diffuse: RID,
		diffuse_ao: RID, strength: float, replacement_enabled: bool,
		frame_token: int, target: Dictionary) -> bool:
	error = ""
	if not bool(target.get("active", false)):
		return _fail("NRD view target is inactive")
	var key := str(target.get("key", ""))
	if not _views.has(key):
		return _fail("NRD view history was evicted before dispatch")
	var state: Dictionary = _views[key]
	if textures.size() < 4 or not motion_vectors.is_valid() \
			or not color.is_valid() or not output.is_valid():
		return _fail_view(state, "NRD compose attachments are unavailable")
	var core: Variant = state.get("core")
	if core == null:
		return _fail_view(state, "NRD RELAX core is unavailable")
	var reset := bool(state.get("reset_pending", true))
	var settings_value: Variant = snapshot.get("surfel_settings", {})
	var settings: Dictionary = settings_value if settings_value is Dictionary else {}
	if not _upload_prepare_parameters(state, frame, full_size,
			_finite_range(settings.get("max_ray_distance", 128.0), 128.0, 0.1, 4096.0)):
		return _fail_view(state, error)
	if not _dispatch_prepare(state, textures[0], textures[1], motion_vectors):
		var prepare_error := error if not error.is_empty() else "NRD guide preparation failed"
		return _fail_view(state, prepare_error)
	var core_inputs: Dictionary = core.inputs
	var prep_outputs: Array = state.get("nrd_inputs", [])
	if prep_outputs.size() != 4 or core.samplers.is_empty():
		return _fail_view(state, "NRD input texture inventory is incomplete")
	for output_value in prep_outputs:
		if not output_value is RID:
			return _fail_view(state, "NRD input texture inventory contains a non-RID value")
		var output_rid: RID = output_value
		if not output_rid.is_valid():
			return _fail_view(state, "NRD input texture inventory contains an invalid RID")
	core_inputs["IN_DIFF_RADIANCE_HITDIST"] = prep_outputs[0]
	core_inputs["IN_NORMAL_ROUGHNESS"] = prep_outputs[1]
	core_inputs["IN_VIEWZ"] = prep_outputs[2]
	core_inputs["IN_MV"] = prep_outputs[3]
	var resources_before: int = core.resources.size()
	var dispatch_ok := bool(core.call("dispatch", frame, frame_token, reset,
		NRD_MOTION_MODE_SCREEN))
	if core.resources.size() != resources_before:
		resource_revision += 1
	if not dispatch_ok:
		return _fail_view(state, "NRD RELAX dispatch failed: %s" % str(core.get("error")))
	_record_successful_history_dispatch(state, frame_token, reset)
	_views[key] = state
	if not _upload_compose_parameters(state, frame, snapshot, full_size,
			strength, replacement_enabled, frame_token):
		return _fail_view(state, error)
	var ao := diffuse_ao if diffuse_ao.is_valid() else _white_ao
	var sky := sky_diffuse if sky_diffuse.is_valid() else _black_2d
	var compose_uniforms: Array[RDUniform] = [
		U.sampled(0, core.samplers[0], textures[0]),
		U.sampled(1, core.samplers[0], textures[1]),
		U.sampled(2, core.samplers[0], textures[2]),
		U.sampled(3, core.samplers[0], textures[3]),
		U.sampled(4, core.samplers[0], sky),
		U.sampled(5, core.samplers[0], ao),
		U.sampled(6, core.samplers[0], core.inputs["OUT_DIFF_RADIANCE_HITDIST"]),
		U.sampled(7, core.samplers[0], state.raw),
		U.sampled(8, core.samplers[0], state.auxiliary),
		U.image(9, color), U.image(10, output), U.uniform_buffer(11, state.compose_ubo)]
	if not _dispatch_compute(_compose_pipeline, _compose_shader, compose_uniforms,
			full_size):
		return _fail_view(state, error)
	state["reset_pending"] = false
	state["reset_reason"] = ""
	state["last_frame"] = frame_token
	state["last_used"] = _clock
	state["dispatch_count"] = int(state.get("dispatch_count", 0)) + 1
	state["error"] = ""
	_views[key] = state
	return true


func invalidate_view(target: Dictionary, reason: String) -> void:
	var key := str(target.get("key", ""))
	if key.is_empty() or not _views.has(key):
		return
	_fail_view(_views[key], reason if not reason.is_empty() else "NRD gather failed")


func request_reset_cache(cache_key: String, reason: String) -> void:
	if cache_key.is_empty():
		return
	for key_value in _views.keys():
		var key := str(key_value)
		var state: Dictionary = _views[key]
		var metadata: Dictionary = state.get("metadata", {})
		if str(metadata.get("cache_key", "")) != cache_key:
			continue
		state["reset_pending"] = true
		state["reset_reason"] = reason if not reason.is_empty() else "source_resources_changed"
		state["last_reset_reason"] = state["reset_reason"]
		_views[key] = state


func get_debug_info() -> Dictionary:
	var total_bytes := 0
	var rows: Array[Dictionary] = []
	for key_value in _views.keys():
		var key := str(key_value)
		var state: Dictionary = _views[key]
		var core: Variant = state.get("core")
		var core_bytes := int(state.get("core_bytes", 0))
		var view_size: Vector2i = state.get("size", Vector2i.ZERO)
		var own_bytes: int = view_size.x * view_size.y * 16 \
				+ PREP_UBO_BYTES + COMPOSE_UBO_BYTES
		total_bytes += core_bytes + own_bytes
		var view_active := int(state.get("dispatch_count", 0)) > 0 \
				and not bool(state.get("reset_pending", false)) \
				and str(state.get("error", "")).is_empty()
		rows.append({"key": key, "size": state.get("size", Vector2i.ZERO),
			"active": view_active,
			"dispatch_count": int(state.get("dispatch_count", 0)),
			"history_reset_count": int(state.get("history_reset_count", 0)),
			"last_reset_frame": int(state.get("last_reset_frame", -1)),
			"last_dispatch_was_reset": bool(state.get("last_dispatch_was_reset", false)),
			"reset_reason": str(state.get("reset_reason", "")),
			"last_reset_reason": str(state.get("last_reset_reason", "")),
			"error": str(state.get("error", "")),
			"core_error": str(core.get("error")) if core != null else "NRD core unavailable",
			"bytes": core_bytes + own_bytes})
	var active := false
	for state_value in _views.values():
		var state: Dictionary = state_value
		if int(state.get("dispatch_count", 0)) > 0 \
				and not bool(state.get("reset_pending", false)) \
				and str(state.get("error", "")).is_empty():
			active = true
			break
	return {"available": not _views.is_empty(), "active": active,
		"view_count": _views.size(), "views": rows, "bytes": total_bytes,
		"resource_revision": resource_revision, "error": error}


func get_all_rids() -> Array[RID]:
	var result: Array[RID] = []
	for key in _views:
		var state: Dictionary = _views[key]
		var core: Variant = state.get("core")
		if core != null:
			var core_rids: Array = core.get("resources").duplicate()
			core_rids.reverse()
			result.append_array(core_rids)
		result.append_array(_reversed_rids(state.get("owned", [])))
	result.append_array(_reversed_rids(_owned_shared))
	return _unique_rids(result)


func take_owned_rids() -> Array[RID]:
	var result := get_all_rids()
	for state_value in _views.values():
		var state: Dictionary = state_value
		var core: Variant = state.get("core")
		_detach_core(core)
	_views.clear()
	_owned_shared.clear()
	_prep_shader = RID()
	_prep_pipeline = RID()
	_compose_shader = RID()
	_compose_pipeline = RID()
	_black_2d = RID()
	_white_ao = RID()
	rd = null
	resource_revision += 1
	return result


func release_all() -> void:
	if rd != null:
		for state_value in _views.values():
			_release_view(state_value)
		_free_rids(_reversed_rids(_owned_shared))
	_views.clear()
	_owned_shared.clear()
	_prep_shader = RID()
	_prep_pipeline = RID()
	_compose_shader = RID()
	_compose_pipeline = RID()
	_black_2d = RID()
	_white_ao = RID()
	rd = null
	resource_revision += 1


func _ensure_shared_resources() -> bool:
	if _prep_pipeline.is_valid() and _compose_pipeline.is_valid() \
			and _black_2d.is_valid() and _white_ao.is_valid():
		return true
	if not _ensure_compute("prepare") or not _ensure_compute("compose"):
		return false
	if not _black_2d.is_valid():
		_black_2d = _create_texture(Vector2i.ONE, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
		if _black_2d.is_valid():
			_owned_shared.append(_black_2d)
			if rd.texture_clear(_black_2d, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
				_free_shared_rid(_black_2d)
				_black_2d = RID()
	if not _white_ao.is_valid():
		_white_ao = rd.texture_create(_texture_format(Vector2i.ONE,
				RenderingDevice.DATA_FORMAT_R16_SFLOAT), RDTextureView.new(),
			[PackedByteArray([0, 0x3c])])
		if _white_ao.is_valid():
			_owned_shared.append(_white_ao)
	if not _black_2d.is_valid() or not _white_ao.is_valid():
		return _fail("NRD fallback textures could not be created")
	resource_revision += 1
	return true


func _ensure_compute(kind: String) -> bool:
	var pipeline: RID = _prep_pipeline if kind == "prepare" else _compose_pipeline
	if pipeline.is_valid():
		return true
	var shader_path := PREP_SHADER_PATH if kind == "prepare" else COMPOSE_SHADER_PATH
	var shader_source := FileAccess.get_file_as_string(shader_path)
	if shader_source.is_empty():
		return _fail("NRD %s shader is missing" % kind)
	if shader_source.begins_with("#[compute]"):
		var marker_end := shader_source.find("\n")
		shader_source = shader_source.substr(marker_end + 1)
	var source := RDShaderSource.new()
	source.source_compute = shader_source
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		return _fail("NRD %s shader compile failed: %s" % [kind, spirv.compile_error_compute])
	var shader: RID = rd.shader_create_from_spirv(spirv, "Magic GI Surfel NRD " + kind)
	if not shader.is_valid():
		return _fail("NRD %s shader creation failed" % kind)
	var created_pipeline: RID = rd.compute_pipeline_create(shader)
	if not created_pipeline.is_valid():
		rd.free_rid(shader)
		return _fail("NRD %s pipeline creation failed" % kind)
	if kind == "prepare":
		_prep_shader = shader
		_prep_pipeline = created_pipeline
	else:
		_compose_shader = shader
		_compose_pipeline = created_pipeline
	_owned_shared.append_array([shader, created_pipeline])
	resource_revision += 1
	return true


func _create_view_state(size: Vector2i) -> Dictionary:
	var core_script := _get_core_script()
	if core_script == null:
		return {}
	var core: Variant = core_script.new()
	if core == null or not bool(core.call("initialize", rd, size)):
		var core_error := str(core.get("error")) if core != null else "NRD script could not be instantiated"
		_release_core(core)
		error = "NRD RELAX initialization failed: %s" % core_error
		return {}
	if not core.has_method("supports_motion_mode") \
			or not bool(core.call("supports_motion_mode", NRD_MOTION_MODE_SCREEN)):
		_release_core(core)
		error = "The loaded NRD bridge does not advertise screen-space motion support"
		return {}
	var raw := _create_texture(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var auxiliary := _create_texture(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var prep_ubo: RID = rd.uniform_buffer_create(PREP_UBO_BYTES)
	var compose_ubo: RID = rd.uniform_buffer_create(COMPOSE_UBO_BYTES)
	var owned: Array[RID] = [raw, auxiliary, prep_ubo, compose_ubo]
	for rid in owned:
		if not rid.is_valid():
			_free_rids(owned)
			_release_core(core)
			error = "NRD Surfel view resources could not be allocated"
			return {}
	for texture in [raw, auxiliary]:
		if rd.texture_clear(texture, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
			_free_rids(owned)
			_release_core(core)
			error = "NRD Surfel view textures could not be initialized"
			return {}
	var core_bytes := 0
	# RELAX input textures: four RGBA16F and one R32F at full denoiser resolution.
	core_bytes += size.x * size.y * (4 * 8 + 4)
	# Pool byte accounting follows the native layout's real format/downsample values.
	for pool_name in ["permanent", "transient"]:
		var pool_descriptors: Array = core.layout.get(pool_name, [])
		for descriptor_value in pool_descriptors:
			if not descriptor_value is Dictionary: continue
			var descriptor: Dictionary = descriptor_value
			var downsample: int = maxi(1, int(descriptor.get("downsample", 1)))
			var pool_size := Vector2i(ceili(float(size.x) / downsample),
					ceili(float(size.y) / downsample))
			core_bytes += pool_size.x * pool_size.y * _format_bytes(int(descriptor.get("format", -1)))
	resource_revision += 1
	return {"core": core, "raw": raw, "auxiliary": auxiliary, "prep_ubo": prep_ubo,
		"compose_ubo": compose_ubo, "owned": owned, "size": size,
		"nrd_inputs": [core.inputs["IN_DIFF_RADIANCE_HITDIST"],
			core.inputs["IN_NORMAL_ROUGHNESS"], core.inputs["IN_VIEWZ"], core.inputs["IN_MV"]],
		"core_bytes": core_bytes, "dispatch_count": 0,
		"history_reset_count": 0, "last_reset_frame": -1,
		"last_dispatch_was_reset": false, "reset_pending": true,
		"reset_reason": "new_view", "last_frame": -1, "last_used": _clock,
		"error": ""}


func _dispatch_prepare(state: Dictionary, depth: RID, normal: RID,
		motion_vectors: RID) -> bool:
	var core: Variant = state.get("core")
	if core == null:
		return _fail("NRD RELAX core is unavailable")
	var outputs: Array = state.get("nrd_inputs", [])
	if outputs.size() != 4:
		return _fail("NRD input texture inventory is incomplete")
	var uniforms: Array[RDUniform] = [
		U.sampled(0, core.samplers[0], state.raw),
		U.sampled(1, core.samplers[0], state.auxiliary),
		U.sampled(2, core.samplers[0], depth),
		U.sampled(3, core.samplers[0], normal),
		U.sampled(4, core.samplers[0], motion_vectors),
		U.image(5, outputs[0]), U.image(6, outputs[1]),
		U.image(7, outputs[2]), U.image(8, outputs[3]),
		U.uniform_buffer(9, state.prep_ubo)]
	return _dispatch_compute(_prep_pipeline, _prep_shader, uniforms,
		state.get("size", Vector2i.ZERO))


func _dispatch_compute(pipeline: RID, shader: RID, uniforms: Array[RDUniform],
		extent: Vector2i) -> bool:
	if rd == null or not pipeline.is_valid() or not shader.is_valid() \
			or extent.x <= 0 or extent.y <= 0:
		return _fail("NRD compute pipeline or dispatch extent is invalid")
	var set := UniformSetCacheRD.get_cache(shader, 0, uniforms)
	if not set.is_valid():
		return _fail("NRD compute descriptor set is invalid")
	var list := rd.compute_list_begin()
	if list < 0:
		return _fail("NRD compute list could not begin")
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_dispatch(list, ceili(float(extent.x) / 8.0), ceili(float(extent.y) / 8.0), 1)
	rd.compute_list_end()
	return true


func _upload_prepare_parameters(state: Dictionary, frame: Dictionary,
		full_size: Vector2i, max_distance: float) -> bool:
	var half_size: Vector2i = state.get("size", Vector2i.ZERO)
	var bytes := PackedByteArray()
	_append_projection(bytes, frame.get("inverse_projection", Projection.IDENTITY))
	_append_transform(bytes, frame.get("camera_transform", Transform3D.IDENTITY))
	bytes.append_array(PackedFloat32Array([full_size.x, full_size.y,
		half_size.x, half_size.y, float(frame.get("near_plane_m", 0.1)),
		float(frame.get("far_plane_m", max_distance)), max_distance, 0.0]).to_byte_array())
	if bytes.size() != PREP_UBO_BYTES or rd.buffer_update(state.prep_ubo,
			0, bytes.size(), bytes) != OK:
		return _fail("NRD guide parameter upload failed")
	return true


func _upload_compose_parameters(state: Dictionary, frame: Dictionary,
		snapshot: Dictionary, full_size: Vector2i, strength: float,
		replacement_enabled: bool, frame_token: int) -> bool:
	var bytes := PackedByteArray()
	_append_projection(bytes, frame.get("inverse_projection", Projection.IDENTITY))
	_append_transform(bytes, frame.get("camera_transform", Transform3D.IDENTITY))
	var owner_transform: Transform3D = snapshot.get("owner_transform", Transform3D.IDENTITY)
	_append_transform(bytes, owner_transform.affine_inverse())
	var owner_size: Vector3 = snapshot.get("owner_size", Vector3.ZERO)
	var settings_value: Variant = snapshot.get("surfel_settings", {})
	var settings: Dictionary = settings_value if settings_value is Dictionary else {}
	bytes.append_array(PackedFloat32Array([owner_size.x * 0.5, owner_size.y * 0.5,
		owner_size.z * 0.5, _finite_range(settings.get("surfel_radius", 0.15), 0.15, 0.001, 64.0),
		clampf(float(snapshot.get("strength", 1.0)) * strength, 0.0, 8.0),
		1.0 if replacement_enabled else 0.0,
		_finite_range(frame.get("pre_exposure", 1.0), 1.0, 1.0e-6, 1.0e6),
		_finite_range(frame.get("scene_normalization", 1.0), 1.0, 1.0e-6, 1.0e6)]).to_byte_array())
	var half_size: Vector2i = state.get("size", Vector2i.ZERO)
	bytes.append_array(PackedInt32Array([full_size.x, full_size.y,
		half_size.x, half_size.y]).to_byte_array())
	bytes.append_array(PackedInt32Array([clampi(int(settings.get("debug_view", 0)), 0, 3),
		frame_token & 0x7fffffff, 0, 0]).to_byte_array())
	if bytes.size() != COMPOSE_UBO_BYTES or rd.buffer_update(state.compose_ubo,
			0, bytes.size(), bytes) != OK:
		return _fail("NRD composition parameter upload failed")
	return true


func _metadata(frame: Dictionary, snapshot: Dictionary, full_size: Vector2i,
		output_size: Vector2i) -> Dictionary:
	return {"full_size": full_size, "size": output_size,
		"layout_version": int(snapshot.get("layout_version", snapshot.get("version", -1))),
		"world_generation": int(snapshot.get("world_generation", 0)),
		"registry_epoch": int(snapshot.get("registry_epoch", 0)),
		"topology_revision": int(snapshot.get("topology_revision", 0)),
		"snapshot_generation": int(snapshot.get("snapshot_generation", 0)),
		"material_revision": int(snapshot.get("material_revision", 0)),
		"world_id": int(snapshot.get("world_id", 0)),
		"volume_id": int(snapshot.get("volume_id", 0)),
		"cache_key": str(snapshot.get("cache_key", "")),
		"owner_transform": snapshot.get("owner_transform", Transform3D.IDENTITY),
		"owner_size": snapshot.get("owner_size", Vector3.ZERO),
		"geometry_signature": _geometry_signature(snapshot),
		"sky_light_source_owner_id": int(frame.get("sky_light_source_owner_id", 0)),
		"sky_light_source_valid": bool(frame.get("sky_light_source_valid", false)),
		"sky_light_source_revision": int(frame.get("sky_light_source_revision", 0)),
		# This is the committed radiance content revision, distinct from the
		# source-registration token above; it changes only when a new capture is active.
		"sky_light_revision": int(frame.get("sky_light_revision", 0)),
		"sky_light_energy": float(frame.get("sky_light_energy", 0.0)),
		"sky_light_rotation": frame.get("sky_light_rotation", Basis.IDENTITY),
		"sky_captured_exposure": float(frame.get("sky_captured_exposure", 1.0)),
		"sky_radiance_is_array": bool(frame.get("sky_radiance_is_array", false)),
		"sky_radiance_size": int(frame.get("sky_radiance_size", 0)),
		"sky_uv_border_size": float(frame.get("sky_uv_border_size", 0.0)),
		"directional_light_signature": frame.get("directional_light_signature", PackedByteArray()),
		"camera_transform": frame.get("camera_transform", Transform3D.IDENTITY),
		"projection": frame.get("projection_unjittered", frame.get("projection", Projection.IDENTITY)),
		"camera_generation": int(frame.get("camera_generation", 0)),
		"render_target_id": int(frame.get("render_target_id", 0)),
		"view_index": int(frame.get("view_index", 0))}


func _invalidation_reason(state: Dictionary, next: Dictionary,
		frame: Dictionary, frame_token: int) -> String:
	var previous: Dictionary = state.get("metadata", {})
	if previous.is_empty(): return "missing_previous_metadata"
	if bool(frame.get("camera_cut", false)): return "camera_cut"
	for key in ["full_size", "size", "layout_version", "world_generation",
			"registry_epoch", "topology_revision", "world_id", "volume_id",
			"cache_key", "owner_transform", "owner_size", "geometry_signature",
			"sky_light_source_owner_id", "sky_light_source_valid",
			"sky_light_source_revision", "sky_light_energy", "sky_light_rotation",
			"sky_radiance_is_array", "sky_radiance_size",
			"sky_uv_border_size", "directional_light_signature", "camera_generation",
			"render_target_id", "view_index"]:
		if previous.get(key) != next.get(key): return "source_or_view_changed:%s" % key
	var last_frame := int(state.get("last_frame", -1))
	if last_frame >= 0 and frame_token > last_frame + 1: return "frame_gap"
	var old_camera: Transform3D = previous.get("camera_transform", Transform3D.IDENTITY)
	var camera: Transform3D = next.get("camera_transform", Transform3D.IDENTITY)
	if old_camera.origin.distance_to(camera.origin) > 2.0:
		return "camera_translation_cut"
	var old_forward := -old_camera.basis.z.normalized()
	var forward := -camera.basis.z.normalized()
	if old_forward.dot(forward) < 0.819152:
		return "camera_rotation_cut"
	var old_projection: Projection = previous.get("projection", Projection.IDENTITY)
	var projection: Projection = next.get("projection", Projection.IDENTITY)
	for column in 4:
		var a: Vector4 = old_projection[column]
		var b: Vector4 = projection[column]
		if (a - b).length() > 0.25:
			return "projection_cut"
	return ""


func _geometry_signature(snapshot: Dictionary) -> int:
	# Ordinary transforms and deformation revisions are continuous radiance inputs,
	# not view-history discontinuities. Keep them out of the NRD reset signature;
	# topology changes are tracked independently above.
	var signature: Array = [int(snapshot.get("world_id", 0)),
		int(snapshot.get("world_generation", 0)), int(snapshot.get("registry_epoch", 0)),
		int(snapshot.get("topology_revision", 0))]
	var instances_value: Variant = snapshot.get("instances", [])
	if instances_value is Array:
		for instance_value in instances_value:
			if not instance_value is Dictionary: continue
			var instance: Dictionary = instance_value
			signature.append([int(instance.get("instance_id", 0)),
				int(instance.get("mesh_id", 0)), int(instance.get("layers", 0)),
				bool(instance.get("cast_shadow", true)), _instance_surface_signature(instance)])
	return hash(signature)


func _instance_surface_signature(instance: Dictionary) -> Array:
	var result: Array = []
	var rows_value: Variant = instance.get("surface_rows", [])
	if rows_value is Array:
		for row_value in rows_value:
			if not row_value is Dictionary: continue
			var row: Dictionary = row_value
			result.append([int(row.get("slot", -1)), int(row.get("generation", 0)),
				int(row.get("geometry_revision", 0)), int(row.get("surface_index", -1))])
	return result


func _get_core_script() -> Script:
	if not _core_script_checked:
		_core_script_checked = true
		if not ResourceLoader.exists(CORE_PATH):
			error = "Optional feng-raytracing NRD RELAX script is missing"
			return null
		var loaded: Variant = load(CORE_PATH)
		if loaded is Script:
			_core_script = loaded
		else:
			error = "Optional feng-raytracing NRD RELAX script could not be loaded"
	return _core_script


func _ensure_nrd_extension() -> bool:
	if ClassDB.class_exists("FengNRDBridge"):
		return true
	if not _extension_checked:
		_extension_checked = true
		if ResourceLoader.exists(EXTENSION_PATH) or FileAccess.file_exists(
				ProjectSettings.globalize_path(EXTENSION_PATH)):
			GDExtensionManager.load_extension(EXTENSION_PATH)
	if ClassDB.class_exists("FengNRDBridge"):
		return true
	error = "Optional feng-raytracing NRD extension is unavailable"
	return false


func _prune_views(keep_key: String) -> void:
	for key_value in _views.keys():
		var key := str(key_value)
		if key == keep_key: continue
		var state: Dictionary = _views[key]
		if _clock - int(state.get("last_used", 0)) > 240:
			_views.erase(key)
			_release_view(state)
	while _views.size() > MAX_VIEWS:
		var oldest_key := ""
		var oldest_clock := 0x7fffffff
		for key_value in _views.keys():
			var key := str(key_value)
			if key == keep_key: continue
			var state: Dictionary = _views[key]
			if int(state.get("last_used", 0)) < oldest_clock:
				oldest_clock = int(state.get("last_used", 0))
				oldest_key = key
		if oldest_key.is_empty(): break
		var stale: Dictionary = _views[oldest_key]
		_views.erase(oldest_key)
		_release_view(stale)


func _release_view(state: Dictionary) -> void:
	var core: Variant = state.get("core")
	_release_core(core)
	_free_rids(_reversed_rids(state.get("owned", [])))
	resource_revision += 1


func _release_core(core: Variant) -> void:
	if core == null: return
	if core.has_method("clear_dispatch_binding_plans"):
		core.call("clear_dispatch_binding_plans")
	var core_resources: Array = core.get("resources").duplicate()
	core_resources.reverse()
	_free_rids(core_resources)
	_detach_core(core)


func _detach_core(core: Variant) -> void:
	if core == null: return
	if core.has_method("clear_dispatch_binding_plans"):
		core.call("clear_dispatch_binding_plans")
	core.set("resources", [])
	core.set("bridge", null)


func _format_bytes(format: int) -> int:
	match format:
		0: return 1 # R8_UNORM
		8: return 4 # R8G8B8A8_UNORM
		27: return 8 # R16G16B16A16_SFLOAT
		30: return 4 # R32_SFLOAT
		_: return 0


func _has_owned_resources() -> bool:
	return not _views.is_empty() or not _owned_shared.is_empty()


func _free_shared_rid(rid: RID) -> void:
	if rd == null or not rid.is_valid(): return
	var id: int = rid.get_id()
	rd.free_rid(rid)
	for index in range(_owned_shared.size() - 1, -1, -1):
		if _owned_shared[index].get_id() == id:
			_owned_shared.remove_at(index)
			break


func _create_texture(size: Vector2i, format: int) -> RID:
	return rd.texture_create(_texture_format(size, format), RDTextureView.new())


func _texture_format(size: Vector2i, format: int) -> RDTextureFormat:
	var desc := RDTextureFormat.new()
	desc.width = size.x
	desc.height = size.y
	desc.format = format
	desc.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return desc


func _append_projection(bytes: PackedByteArray, projection: Projection) -> void:
	for column in 4:
		var axis: Vector4 = projection[column]
		bytes.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]).to_byte_array())


func _append_transform(bytes: PackedByteArray, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z]:
		bytes.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]).to_byte_array())
	bytes.append_array(PackedFloat32Array([transform.origin.x, transform.origin.y,
		transform.origin.z, 1.0]).to_byte_array())


func _finite_range(value: Variant, fallback: float, minimum: float, maximum: float) -> float:
	var result := float(value)
	if not is_finite(result): result = fallback
	return clampf(result, minimum, maximum)


func _inactive(reason: String) -> Dictionary:
	error = reason
	return {"active": false, "reason": reason}


func _fail(reason: String) -> bool:
	error = reason
	return false


func _fail_view(state: Dictionary, reason: String) -> bool:
	state["reset_pending"] = true
	state["reset_reason"] = "dispatch_failed"
	state["error"] = reason
	var key := str(state.get("target_key", ""))
	if not key.is_empty() and _views.has(key):
		_views[key] = state
	return _fail(reason)


func _record_successful_history_dispatch(state: Dictionary, frame_token: int,
		was_reset: bool) -> void:
	# Only called after RELAX reports a successful dispatch. A prepare retry or
	# failed dispatch must not make a pending reset look completed in diagnostics.
	state["last_dispatch_was_reset"] = was_reset
	if was_reset:
		state["history_reset_count"] = int(state.get("history_reset_count", 0)) + 1
		state["last_reset_frame"] = frame_token


func _free_rids(rids: Array) -> void:
	if rd == null: return
	for value in rids:
		var rid: Variant = value
		if rid is RID and rid.is_valid():
			rd.free_rid(rid)


func _reversed_rids(rids: Array) -> Array[RID]:
	var result: Array[RID] = []
	for value in rids:
		if value is RID: result.append(value)
	result.reverse()
	return result


func _unique_rids(rids: Array[RID]) -> Array[RID]:
	var result: Array[RID] = []
	var seen: Dictionary = {}
	for rid in rids:
		if not rid.is_valid(): continue
		var id: int = rid.get_id()
		if seen.has(id): continue
		seen[id] = true
		result.append(rid)
	return result
