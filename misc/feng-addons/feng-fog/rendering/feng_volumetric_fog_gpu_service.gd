@tool
extends RefCounted
## Owns the 3D froxel resources and schedules the medium, light, temporal and
## integration stages. Native frame inputs are read for this call only; only
## addon-owned textures survive into the next frame.

const Codec = preload("feng_volumetric_fog_codec.gd")
const LocalVolumeCodec = preload("feng_local_volume_codec.gd")
const LightExtensionRegistry = preload("res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension_registry.gd")
const LightExtensionLayout = preload("res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension_layout.gd")
const LightExtensionProviderScript = preload("res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension_provider.gd")
const EnvironmentVisibilityProviderScript = preload("res://addons/feng-fog/rendering/lighting/environment_visibility/fog_volume_environment_visibility_provider.gd")
const RTVolumeBridgeScript = preload("fog_rt_volume_bridge.gd")
const OwnedRids = preload("res://addons/feng-render-pipeline/rd/owned_rids.gd")
const ShaderSource = preload("res://addons/feng-render-pipeline/rd/shader_source.gd")
const RDUniforms = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const SkySHProviderScript = preload("res://addons/feng-fog/rendering/lighting/fog_sky_sh_provider.gd")
const BakedLightingProviderScript = preload("res://addons/feng-fog/rendering/baked_lighting/fog_baked_lighting_provider.gd")
const VolumetricLightmapProviderScript = preload("res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap_provider.gd")
const SHADER_ROOT := "res://addons/feng-fog/rendering/shaders/"
const FRAME_BYTES := Codec.FRAME_UNIFORM_FLOATS * 4
const LIGHT_BYTES := 224
const BAKED_MODE_NONE := 0
const BAKED_MODE_LIGHTMAP_GI_PROBES := 1
const BAKED_MODE_UE_VOLUMETRIC_LIGHTMAP := 2
const VLM_FLAG_STATIC_DIRECT_DIRECTIONAL := VolumetricLightmapProviderScript.FLAG_CONTAINS_STATIC_DIRECT_DIRECTIONAL_LIGHTING
const VLM_FLAG_STATIC_LIGHT_KEY_MATCH := VolumetricLightmapProviderScript.FLAG_STATIC_LIGHT_KEY_MATCH
const FRAME_INPUT_ABI := 1
const DIRECTIONAL_STRIDE := 464
const LOCAL_STRIDE := 224
const MAX_DIRECTIONAL_LIGHTS := 8
const MAX_LOCAL_VOLUMES := LocalVolumeCodec.MAX_VOLUMES
const UE_DEFAULT_LIGHT_SOFT_FADING := 0.0
const WORKGROUP_3D := 4
const WORKGROUP_INTEGRATE := 8
const WORKGROUP_DEPTH := 8

var _pipelines: Dictionary = {}
var _failed_pipeline_sources: Dictionary = {}
var _states: Dictionary = {}
var _tracked_baked_probe_resource_ids: Dictionary = {}
var _tracked_vlm_resource_ids: Dictionary = {}
var _sampler_nearest := RID()
var _sampler_linear := RID()
var _sampler_compare := RID()
var _fallback_texture_2d := RID()
var _fallback_texture_array := RID()
var _fallback_density_3d := RID()
var _fallback_depth_2d := RID()
var _fallback_shadow := RID()
var _fallback_directional_buffer := RID()
var _fallback_local_buffer := RID()
var _fallback_cluster_buffer := RID()
var _fallback_sky_sh_buffer := RID()
var _fallback_baked_buffers: Dictionary = {}
var _sky_sh_provider := SkySHProviderScript.new()
var _baked_lighting_provider := BakedLightingProviderScript.new()
var _volumetric_lightmap_provider: RefCounted = VolumetricLightmapProviderScript.new()
var _fallback_vlm_inputs: Dictionary = {}
var _vlm_rendering_device: RenderingDevice
var _light_extension_provider: RefCounted = LightExtensionProviderScript.new()
var _environment_visibility_provider: RefCounted = EnvironmentVisibilityProviderScript.new()
var _rt_volume_bridge: RefCounted = RTVolumeBridgeScript.new()
var _last_error := ""
var _last_status := "idle"
var _inactive_volume_range := false
var _last_rt_fallback_reason := ""


func render_volume(ctx: FRPPassContext, snapshot: Dictionary, buffers: RenderSceneBuffersRD,
		rd: RenderingDevice, frame_inputs: Array[Dictionary] = []) -> Dictionary:
	_last_error = ""
	_last_status = "starting"
	_inactive_volume_range = false
	_last_rt_fallback_reason = ""
	_prune_states(buffers, rd)
	if ctx == null or buffers == null or rd == null:
		_clear_native_output(ctx)
		_release_state_for(buffers, rd)
		return _fail("input", "context, render buffers, or RenderingDevice is null")
	_clear_native_output(ctx)
	var local_volume_source: Variant = snapshot.get("local_volumes", [])
	var local_volume_packet := LocalVolumeCodec.pack(local_volume_source)
	var local_batches: Array = local_volume_packet.get("batches", [])
	if local_batches.is_empty():
		return _fail("local_volume_codec", "codec did not emit the required base-medium batch")
	var volume := Codec.normalize_volume_packet(snapshot.get("volumetric_fog", {}))
	if volume.is_empty() and int(local_volume_packet.count) > 0:
		volume = Codec.normalize_volume_packet({
			"enabled": true, "distance": 60.0, "start_distance": 0.0,
			"scattering_distribution": 0.0, "albedo": Vector3.ONE,
			"emissive": Vector3.ZERO, "extinction_scale": 1.0,
		})
	if volume.is_empty():
		_inactive_volume_range = true
		_last_status = "inactive: volume disabled and no valid local media (local input count %d, accepted %d)" % [
				local_volume_source.size() if local_volume_source is Array else 0,
				int(local_volume_packet.count)]
		_clear_native_output(ctx)
		_release_state_for(buffers, rd)
		return {}
	var view_count := buffers.get_view_count()
	var frames: Array[Dictionary] = frame_inputs.duplicate()
	if frames.is_empty():
		if not ctx.has_method("get_volume_frame_inputs"):
			return _fail("frame_inputs", "active volume has no get_volume_frame_inputs() provider")
		for view in view_count:
			var raw: Variant = ctx.call("get_volume_frame_inputs", view)
			var frame := Codec.normalize_frame_inputs(raw, view)
			if frame.is_empty():
				_clear_native_output(ctx)
				_release_state_for(buffers, rd)
				return _fail("frame_inputs", "codec rejected view %d (abi=%d, valid=%s, keys=%d)" % [
						view, int(raw.get("abi_version", 0)) if raw is Dictionary else 0,
						str(raw.get("valid", false)) if raw is Dictionary else "false",
						raw.size() if raw is Dictionary else 0])
			frames.append(frame)
	for frame in frames:
		frame["world_id"] = int(snapshot.get("world_id", 0))
	if frames.is_empty() or not _valid_frame_set(frames, buffers):
		_clear_native_output(ctx)
		_release_state_for(buffers, rd)
		return _fail("frame_set", "expected %d normalized view(s), received %d; frame generations, view indices, or internal sizes disagree" % [
				view_count, frames.size()])
	var range_frame: Dictionary = frames[0]
	if not Codec.has_valid_volume_depth_range(float(range_frame.near_plane_m),
			float(volume.start_distance), float(volume.far_distance)):
		_inactive_volume_range = true
		_last_status = "inactive: volume far plane does not extend past camera/start near offset"
		_clear_native_output(ctx)
		_release_state_for(buffers, rd)
		return {}
	if not ctx.has_method("set_volume_output"):
		_clear_native_output(ctx)
		return _fail("publish", "context has no set_volume_output() method")
	if not _ensure_pipelines(rd):
		_clear_native_output(ctx)
		if _last_error.is_empty():
			_set_failure("pipelines", "pipeline setup returned false without a shader error")
		return {}
	if not _ensure_fallbacks(rd):
		_clear_native_output(ctx)
		if _last_error.is_empty():
			_set_failure("fallbacks", "could not allocate required fallback resources")
		return {}
	var frame0: Dictionary = frames[0]
	var sky_inputs: Dictionary = _sky_sh_provider.update_frame_inputs(frame0, rd,
			snapshot.get("volumetric_sky_metadata", {}))
	var baked_snapshot: Variant = snapshot.get("baked_irradiance", {})
	var baked_mode := _baked_mode_for_snapshot(baked_snapshot)
	var baked_inputs: Dictionary = {}
	var active_baked_source_mode := BAKED_MODE_NONE
	var active_baked_resource_id := 0
	if baked_mode == BAKED_MODE_LIGHTMAP_GI_PROBES:
		baked_inputs = _baked_lighting_provider.get_gpu_inputs(baked_snapshot, rd, frame0)
		if bool(baked_inputs.get("valid", false)):
			active_baked_source_mode = BAKED_MODE_LIGHTMAP_GI_PROBES
			active_baked_resource_id = int(baked_inputs.get("resource_id", 0))
			if active_baked_resource_id != 0:
				_tracked_baked_probe_resource_ids[active_baked_resource_id] = true
	if _vlm_rendering_device != rd or _fallback_vlm_inputs.is_empty():
		_fallback_vlm_inputs = _volumetric_lightmap_provider.get_neutral_gpu_inputs(rd)
		_vlm_rendering_device = rd
	if not bool(_fallback_vlm_inputs.get("valid", false)):
		_clear_native_output(ctx)
		_release_unreferenced_baked_resources()
		return _fail("vlm_fallback", str(_fallback_vlm_inputs.get("reason",
				"the required neutral Set 5 descriptors could not be created")))
	if sky_inputs.is_empty() or not _valid_buffer_rid(sky_inputs.get("sky_sh_buffer", RID())):
		sky_inputs = {"valid": false, "can_apply": false, "sky_sh_buffer": _fallback_sky_sh_buffer}
	var size: Vector2i = frame0.internal_size
	var froxel_pixel_size := maxi(int(volume.get("froxel_pixel_size", Codec.FROXEL_PIXEL_SIZE)), 1)
	var froxel_depth := maxi(int(volume.get("froxel_depth", Codec.FROXEL_DEPTH)), 1)
	var grid := Vector3i(ceili(float(size.x) / float(froxel_pixel_size)),
			ceili(float(size.y) / float(froxel_pixel_size)), froxel_depth)
	if grid.x <= 0 or grid.y <= 0:
		_clear_native_output(ctx)
		_release_unreferenced_baked_resources()
		return _fail("grid", "invalid froxel dimensions %s for internal size %s" % [grid, size])
	var state := _ensure_state(buffers, rd, grid, view_count)
	if state.is_empty():
		_clear_native_output(ctx)
		if _last_error.is_empty():
			_set_failure("state", "resource allocation returned an empty state for grid %s and %d view(s)" % [grid, view_count])
		_release_unreferenced_baked_resources()
		return {}
	state["sky_sh_buffer"] = sky_inputs.get("sky_sh_buffer", _fallback_sky_sh_buffer)
	var signature := _source_signature(snapshot, volume, frames, local_volume_packet)
	var history_valid := _history_contiguous(state, frames, size, view_count, signature, volume)
	if not history_valid:
		state.history_index = 0
	var history_write_index := 1 - int(state.history_index)
	var storage_exposure := _positive(frame0.pre_exposure, 1.0)
	var selected_sun: RID = snapshot.get("volumetric_selected_sun_rid", RID())
	var failure_reason := ""
	var all_views_have_depth := true
	for view in view_count:
		var frame: Dictionary = frames[view]
		var extension_rows: Dictionary = LightExtensionLayout.collect_native_rows(frame)
		if not bool(extension_rows.get("valid", false)):
			failure_reason = "native light extension rows: " + str(extension_rows.get("reason", "invalid frame"))
			break
		var extension_metadata: Variant = snapshot.get("light_extension_metadata", {})
		if extension_metadata is Dictionary and bool(extension_metadata.get("valid", false)):
			extension_rows = LightExtensionRegistry.join_native_frame(extension_metadata,
					frame, int(snapshot.get("world_id", 0)))
		if not bool(extension_rows.get("valid", false)):
			failure_reason = "light extension join: " + str(extension_rows.get("reason", "invalid rows"))
			break
		var extension_inputs: Dictionary = _light_extension_provider.update_frame_inputs(extension_rows, rd)
		if not bool(extension_inputs.get("valid", false)):
			failure_reason = "light extension provider: " + str(extension_inputs.get("reason",
					_light_extension_provider.get_last_error()))
			break
		var environment_inputs: Dictionary = _environment_visibility_provider.update_frame_inputs(
				ctx, rd, frame, bool(snapshot.get("volume_cloud_maps_current", false)),
				snapshot.get("volumetric_environment_metadata", {}))
		if not bool(environment_inputs.get("valid", false)):
			failure_reason = "environment visibility provider: " + str(environment_inputs.get("reason",
					_environment_visibility_provider.get_last_error()))
			break
		var vlm_inputs: Dictionary = _fallback_vlm_inputs
		if baked_mode == BAKED_MODE_UE_VOLUMETRIC_LIGHTMAP:
			var static_light_key := _selected_sun_static_lighting_key(
					frame, extension_rows, selected_sun)
			vlm_inputs = _volumetric_lightmap_provider.get_gpu_inputs(baked_snapshot, rd, {
				"static_directional_light_key": static_light_key,
			})
			if not bool(vlm_inputs.get("valid", false)):
				failure_reason = "VLM provider: " + str(vlm_inputs.get("reason",
						_volumetric_lightmap_provider.get_last_error()))
				break
			if not bool(vlm_inputs.get("payload_valid", false)):
				# Invalid/missing VLM data is neutral; keep the analytic fog and live
				# light sources, and bind the valid neutral set for the reflected ABI.
				vlm_inputs = _fallback_vlm_inputs
			else:
				active_baked_source_mode = BAKED_MODE_UE_VOLUMETRIC_LIGHTMAP
				active_baked_resource_id = int(vlm_inputs.get("resource_id", 0))
				if active_baked_resource_id != 0:
					_tracked_vlm_resource_ids[active_baked_resource_id] = true
		var depth_layer: RID = buffers.get_depth_layer(view)
		var depth_layer_valid := _current_depth_available(ctx, frame, depth_layer, rd)
		all_views_have_depth = all_views_have_depth and depth_layer_valid
		var frame_values := Codec.pack_frame_uniform(frame, snapshot, volume, grid,
				int(frame.frame_generation), float(state.previous_pre_exposure), history_valid,
				storage_exposure, depth_layer_valid,
				history_valid and bool(state.get("depth_history_valid", false)))
		if frame_values.size() * 4 != FRAME_BYTES:
			failure_reason = "frame UBO view %d packed %d bytes; expected %d" % [view,
					frame_values.size() * 4, FRAME_BYTES]
			break
		var light_values := _pack_light_uniform(frame, snapshot, volume, storage_exposure,
				selected_sun, sky_inputs, baked_inputs, false, 0, 0,
				vlm_inputs, baked_mode)
		if not _update_ubo(state.frame_ubos[view], frame_values, FRAME_BYTES, rd):
			failure_reason = "frame UBO update failed for view %d (values=%d bytes, RID valid=%s)" % [
					view, frame_values.size() * 4, str(state.frame_ubos[view].is_valid())]
			break
		if not _update_ubo(state.light_ubos[view], light_values, LIGHT_BYTES, rd):
			failure_reason = "light UBO update failed for view %d (values=%d bytes, expected %d, RID valid=%s)" % [
					view, light_values.size() * 4, LIGHT_BYTES, str(state.light_ubos[view].is_valid())]
			break
		if not _dispatch_view(ctx, rd, state, frame, snapshot, volume, grid, view,
				int(state.history_index), history_write_index, history_valid,
				baked_inputs, vlm_inputs, local_volume_packet,
				depth_layer if depth_layer_valid else RID(),
				extension_inputs, environment_inputs, extension_rows, light_values):
			failure_reason = _last_error if not _last_error.is_empty() else "GPU dispatch failed for view %d" % view
			break
	if not failure_reason.is_empty():
		state.history_valid = false
		state.depth_history_valid = false
		state["baked_source_mode"] = BAKED_MODE_NONE
		state["baked_resource_id"] = 0
		_states[buffers.get_instance_id()] = state
		_clear_native_output(ctx)
		_set_failure("render", failure_reason)
		_release_unreferenced_baked_resources()
		return {}
	state.history_index = history_write_index
	state.history_valid = true
	state.depth_history_valid = all_views_have_depth
	state.previous_pre_exposure = storage_exposure \
			* _positive(frame0.get("scene_normalization", 1.0), 1.0)
	state.last_frame_generation = int(frame0.frame_generation)
	state.camera_generation = int(frame0.camera_generation)
	state.environment_id = int(frame0.get("environment_id", 0))
	state.render_target_id = int(frame0.get("render_target_id", 0))
	state.signature = signature
	state.size = size
	state.view_count = view_count
	state.eye_offsets = _eye_offsets(frames)
	state.camera_origin = frame0.camera_origin
	state.camera_basis = frame0.camera_transform.basis
	state["baked_source_mode"] = active_baked_source_mode
	state["baked_resource_id"] = active_baked_resource_id
	state.projection_unjittered = frame0.get("projection_unjittered", frame0.projection)
	state.froxel_pixel_size = froxel_pixel_size
	state.froxel_depth = froxel_depth
	_states[buffers.get_instance_id()] = state
	_release_unreferenced_baked_resources()
	var sample_packet := Codec.make_sampling_packet(grid, view_count, float(volume.start_distance),
			float(volume.far_distance), float(frame0.near_plane_m), storage_exposure,
			froxel_pixel_size)
	if not state.integrated.is_valid() or sample_packet.size() != Codec.SAMPLE_PACKET_FLOATS:
		_clear_native_output(ctx)
		state.history_valid = false
		return _fail("publish", "integrated RID valid=%s, sampling packet has %d floats (expected %d)" % [
				str(state.integrated.is_valid()), sample_packet.size(), Codec.SAMPLE_PACKET_FLOATS])
	ctx.call("set_volume_output", state.integrated, sample_packet, storage_exposure)
	if ctx.has_method("get_volume_texture") and ctx.has_method("get_volume_sampling_parameters"):
		var published_texture: Variant = ctx.call("get_volume_texture")
		var published_packet: Variant = ctx.call("get_volume_sampling_parameters")
		if not published_texture is RID or published_texture != state.integrated \
				or not published_packet is PackedFloat32Array \
				or published_packet.size() != Codec.SAMPLE_PACKET_FLOATS:
			_clear_native_output(ctx)
			state.history_valid = false
			return _fail("publish", "native context rejected output (texture=%s, packet_type=%s, packet_floats=%d)" % [
					str(published_texture is RID and published_texture.is_valid()),
					str(type_string(typeof(published_packet))),
					published_packet.size() if published_packet is PackedFloat32Array else 0])
	_last_status = "published: %d view(s), grid=%s, local media=%d in %d batch(es)" % [
			view_count, grid, int(local_volume_packet.count), int(local_volume_packet.batch_count)]
	if not _last_rt_fallback_reason.is_empty():
		_last_status += "; RT used raster fallback: " + _last_rt_fallback_reason
	return {
		"texture": state.integrated,
		"sample_parameters": sample_packet,
		"rgb_pre_exposure": storage_exposure,
		"grid": grid,
		"source_signature": signature,
	}


func clear(ctx: FRPPassContext, buffers: RenderSceneBuffersRD, rd: RenderingDevice) -> void:
	_last_error = ""
	_last_status = "cleared"
	_clear_native_output(ctx)
	_release_state_for(buffers, rd)


func get_owned_rids() -> Array[RID]:
	return _collect_owned_rids(false)


func take_owned_rids() -> Array[RID]:
	return _collect_owned_rids(true)


func _collect_owned_rids(p_clear: bool) -> Array[RID]:
	var rids: Array[RID] = []
	var seen: Dictionary = {}
	for state in _states.values():
		OwnedRids.append_all(rids, seen, _state_rids(state))
	for entry in _pipelines.values():
		OwnedRids.append(rids, seen, entry.pipeline)
		OwnedRids.append(rids, seen, entry.shader)
	for rid in [_sampler_nearest, _sampler_linear, _sampler_compare,
			_fallback_texture_2d, _fallback_texture_array, _fallback_shadow,
			_fallback_density_3d, _fallback_depth_2d, _fallback_directional_buffer,
			_fallback_local_buffer, _fallback_cluster_buffer, _fallback_sky_sh_buffer]:
		OwnedRids.append(rids, seen, rid)
	for rid_value in _fallback_baked_buffers.values():
		if rid_value is RID:
			OwnedRids.append(rids, seen, rid_value)
	var provider_rids: Array[RID] = _sky_sh_provider.take_owned_rids() if p_clear \
			else _sky_sh_provider.get_owned_rids()
	OwnedRids.append_all(rids, seen, provider_rids)
	provider_rids = _baked_lighting_provider.take_owned_rids() if p_clear \
			else _baked_lighting_provider.get_owned_rids()
	OwnedRids.append_all(rids, seen, provider_rids)
	provider_rids = _volumetric_lightmap_provider.call("take_owned_rids") if p_clear \
			else _volumetric_lightmap_provider.call("get_owned_rids")
	OwnedRids.append_all(rids, seen, provider_rids)
	provider_rids = _light_extension_provider.call("take_owned_rids") if p_clear \
			else _light_extension_provider.call("get_owned_rids")
	OwnedRids.append_all(rids, seen, provider_rids)
	provider_rids = _environment_visibility_provider.call("take_owned_rids") if p_clear \
			else _environment_visibility_provider.call("get_owned_rids")
	OwnedRids.append_all(rids, seen, provider_rids)
	provider_rids = _rt_volume_bridge.take_owned_rids() if p_clear \
			else _rt_volume_bridge.get_owned_rids()
	OwnedRids.append_all(rids, seen, provider_rids)
	if p_clear:
		_states.clear()
		_pipelines.clear()
		_failed_pipeline_sources.clear()
		_sampler_nearest = RID()
		_sampler_linear = RID()
		_sampler_compare = RID()
		_fallback_texture_2d = RID()
		_fallback_texture_array = RID()
		_fallback_shadow = RID()
		_fallback_density_3d = RID()
		_fallback_depth_2d = RID()
		_fallback_directional_buffer = RID()
		_fallback_local_buffer = RID()
		_fallback_cluster_buffer = RID()
		_fallback_sky_sh_buffer = RID()
		_fallback_baked_buffers.clear()
		_tracked_baked_probe_resource_ids.clear()
		_tracked_vlm_resource_ids.clear()
		_fallback_vlm_inputs.clear()
		_vlm_rendering_device = null
	return rids


func get_last_error() -> String:
	return _last_error


func get_last_status() -> String:
	return _last_status


func is_volume_inactive() -> bool:
	return _inactive_volume_range


func _fail(stage: String, reason: String) -> Dictionary:
	_set_failure(stage, reason)
	return {}


func _set_failure(stage: String, reason: String) -> void:
	_last_status = "failed: " + stage
	_last_error = "%s: %s" % [stage, reason]


func _dispatch_view(ctx: FRPPassContext, rd: RenderingDevice, state: Dictionary, frame: Dictionary,
		snapshot: Dictionary, volume: Dictionary, grid: Vector3i, view: int,
		history_read_index: int, history_write_index: int, history_valid: bool,
		baked_inputs: Dictionary, vlm_inputs: Dictionary, local_volume_packet: Dictionary,
		current_depth_layer: RID, extension_inputs: Dictionary,
		environment_inputs: Dictionary, extension_rows: Dictionary,
		light_values: PackedFloat32Array) -> bool:
	var medium_pipeline: Dictionary = _pipelines["volumetric_fog_medium.glslinc"]
	var conservative_depth_pipeline: Dictionary = _pipelines["volumetric_fog_conservative_depth_compute.glslinc"]
	var light_pipeline: Dictionary = _pipelines["volumetric_fog_light.glslinc"]
	var reproject_pipeline: Dictionary = _pipelines["volumetric_fog_reproject.glslinc"]
	var integrate_pipeline: Dictionary = _pipelines["volumetric_fog_integrate.glslinc"]
	var frame_ubo: RID = state.frame_ubos[view]
	var light_ubo: RID = state.light_ubos[view]
	var shadow_sampler := _frame_sampler(frame.get("shadow_sampler", RID()), _sampler_compare)
	var area_profile_sampler := _frame_sampler(frame.get("area_profile_sampler", RID()), _sampler_linear)
	var conservative_current: RID = state.depth_history[history_write_index]
	var conservative_previous: RID = state.depth_history[history_read_index]
	var conservative_set := _uniform_set(conservative_depth_pipeline.shader, [
		RDUniforms.uniform_buffer(0, frame_ubo),
		RDUniforms.sampled(1, _sampler_nearest, _texture(current_depth_layer, _fallback_depth_2d, rd)),
		RDUniforms.image(2, conservative_current),
	])
	if not _dispatch(rd, conservative_depth_pipeline.pipeline, conservative_set,
			Vector3i(grid.x, grid.y, 1), WORKGROUP_DEPTH, "conservative-depth/view%d" % view):
		return false
	var batches: Array = local_volume_packet.get("batches", [])
	for batch_index in batches.size():
		var batch: Dictionary = batches[batch_index]
		var batch_bytes: Variant = batch.get("bytes", PackedByteArray())
		if not batch_bytes is PackedByteArray or batch_bytes.size() != LocalVolumeCodec.BUFFER_BYTES \
				or rd.buffer_update(state.local_volume_buffer, 0, batch_bytes.size(), batch_bytes) != OK:
			_set_failure("local_volume_buffer", "batch %d has %d bytes; expected %d; buffer valid=%s" % [
				batch_index, batch_bytes.size() if batch_bytes is PackedByteArray else 0,
				LocalVolumeCodec.BUFFER_BYTES, str(state.local_volume_buffer.is_valid())])
			return false
		var density_textures: Array = batch.get("textures", [])
		var medium_uniforms: Array[RDUniform] = [
			RDUniforms.uniform_buffer(0, frame_ubo), RDUniforms.image(1, state.medium), RDUniforms.image(2, state.emissive),
			RDUniforms.storage_buffer(3, state.local_volume_buffer),
		]
		for texture_index in MAX_LOCAL_VOLUMES:
			var texture_rid: RID = density_textures[texture_index] \
					if texture_index < density_textures.size() else RID()
			medium_uniforms.append(RDUniforms.sampled(4 + texture_index, _sampler_linear,
					_texture(texture_rid, _fallback_density_3d, rd)))
		medium_uniforms.append(RDUniforms.sampled(20, _sampler_nearest,
				_texture(current_depth_layer, _fallback_depth_2d, rd)))
		var medium_set := _uniform_set(medium_pipeline.shader, medium_uniforms)
		# Each batch is a separate ordered compute dispatch. Batch zero initializes
		# the shared height medium; later batches imageLoad and add their local media.
		if not _dispatch(rd, medium_pipeline.pipeline, medium_set, grid, WORKGROUP_3D,
				"medium/view%d/batch%d" % [view, batch_index]):
			return false
	var requested_samples := Codec.normalize_history_miss_count(
			int(volume.get("history_miss_supersample_count", Codec.HISTORY_MISS_SUPERSAMPLE_COUNT)))
	var rt_prepared: Dictionary = _rt_volume_bridge.call("prepare_view", ctx, rd, frame,
			snapshot, volume, grid, view, extension_rows, extension_inputs,
			requested_samples, current_depth_layer)
	var rt_enabled := bool(rt_prepared.get("valid", false)) and bool(rt_prepared.get("enabled", false))
	if bool(volume.get("ray_traced_shadows_enabled", false)) and not rt_enabled:
		_last_rt_fallback_reason = str(rt_prepared.get("reason", "RT bridge selected complete raster fallback"))
	var work_mask_valid := false
	var rt_result: Dictionary = rt_prepared
	if rt_enabled:
		if _ensure_history_work_mask(rd, state, grid, int(frame.get("view_count", 1))) \
				and _dispatch_history_work_mask(rd, state, frame_ubo, grid, view, requested_samples):
			work_mask_valid = true
		else:
			_last_rt_fallback_reason = "could not build the RT-only history work mask"
			_last_error = ""
			rt_enabled = false
	if rt_enabled:
		var history_work_mask: RID = state.get("history_work_mask", RID()) if work_mask_valid else RID()
		var history_work_mask_bytes := grid.x * grid.y * grid.z * 4 if work_mask_valid else 0
		rt_result = _rt_volume_bridge.call("trace_prepared_view", rd, frame, rt_prepared,
				history_work_mask, history_work_mask_bytes)
		if not bool(rt_result.get("valid", false)) or not bool(rt_result.get("enabled", false)):
			_last_rt_fallback_reason = str(rt_result.get("reason", "RT bridge requested complete raster fallback"))
			rt_enabled = false
			work_mask_valid = false
	var rt_slot_count := int(rt_result.get("slot_count", 0)) if rt_enabled else 0
	var rt_visibility_buffer: RID = rt_result.get("visibility_buffer", RID()) if rt_enabled else _fallback_local_buffer
	var rt_slot_map_buffer: RID = rt_result.get("slot_map_buffer", RID()) if rt_enabled else _fallback_local_buffer
	if rt_enabled and (not rt_visibility_buffer.is_valid() or not rt_slot_map_buffer.is_valid()):
		_last_rt_fallback_reason = "RT bridge did not return valid borrowed buffers"
		rt_enabled = false
		work_mask_valid = false
		rt_slot_count = 0
		rt_visibility_buffer = _fallback_local_buffer
		rt_slot_map_buffer = _fallback_local_buffer
	light_values[48] = 1.0 if rt_enabled else 0.0
	light_values[49] = float(rt_slot_count)
	light_values[50] = float(requested_samples)
	light_values[51] = 1.0 if work_mask_valid else 0.0
	if not _update_ubo(light_ubo, light_values, LIGHT_BYTES, rd):
		_set_failure("lighting", "could not update the light UBO with RT/sample state")
		return false
	var light_uniforms: Array[RDUniform] = [
		RDUniforms.uniform_buffer(0, frame_ubo), RDUniforms.uniform_buffer(1, light_ubo),
		RDUniforms.uniform_buffer(2, _directional_buffer(frame, rd)),
		RDUniforms.storage_buffer(3, _local_buffer(frame, "omni_light_buffer", "omni_light_count", rd)),
		RDUniforms.storage_buffer(4, _local_buffer(frame, "spot_light_buffer", "spot_light_count", rd)),
		RDUniforms.storage_buffer(5, _local_buffer(frame, "area_light_buffer", "area_light_count", rd)),
		RDUniforms.storage_buffer(6, _cluster_buffer(frame, rd)),
		RDUniforms.sampled(7, shadow_sampler, _shadow_texture(frame, "shadow_atlas", rd)),
		RDUniforms.sampled(8, shadow_sampler, _shadow_texture(frame, "directional_shadow_atlas", rd)),
		RDUniforms.sampled(9, area_profile_sampler, _texture(frame.get("area_profile_atlas", RID()), _fallback_texture_2d, rd)),
		RDUniforms.storage_buffer(10, state.get("sky_sh_buffer", _fallback_sky_sh_buffer)),
		RDUniforms.sampled(13, _sampler_nearest, state.medium), RDUniforms.sampled(14, _sampler_nearest, state.emissive),
		RDUniforms.image(15, state.injected),
		RDUniforms.sampled(16, _sampler_nearest, _texture(current_depth_layer, _fallback_depth_2d, rd)),
		RDUniforms.storage_buffer(11, rt_visibility_buffer),
		RDUniforms.storage_buffer(12, rt_slot_map_buffer),
		RDUniforms.storage_buffer(17, _history_work_mask_buffer(state)),
		RDUniforms.sampled(18, _sampler_nearest, conservative_current),
		RDUniforms.sampled(19, _sampler_nearest, conservative_previous),
	]
	var baked_set := _uniform_set(light_pipeline.shader,
			_baked_uniforms(baked_inputs), 2)
	var vlm_uniforms: Array[RDUniform] = VolumetricLightmapProviderScript.make_set5_uniforms(vlm_inputs)
	var vlm_set := _uniform_set(light_pipeline.shader, vlm_uniforms, 5)
	if vlm_uniforms.size() != 11 or not vlm_set.is_valid():
		_set_failure("vlm_descriptors", "Set 5 needs eleven valid neutral or active bindings; got %d" % vlm_uniforms.size())
		return false
	var extension_records: RID = extension_inputs.get("records_buffer", RID())
	var extension_cookie_sampler: RID = extension_inputs.get("cookie_sampler", RID())
	var extension_cookie_array: RID = extension_inputs.get("cookie_texture_array", RID())
	var extension_header: RID = extension_inputs.get("header_buffer", RID())
	var extension_uniforms: Array[RDUniform] = [
		RDUniforms.storage_buffer(0, extension_records),
		RDUniforms.sampled(1, extension_cookie_sampler, extension_cookie_array),
		RDUniforms.uniform_buffer(2, extension_header),
	]
	var extension_set := _uniform_set(light_pipeline.shader, extension_uniforms, 3)
	var environment_uniforms: Array[RDUniform] = environment_inputs.get("uniforms", [])
	var environment_set := _uniform_set(light_pipeline.shader, environment_uniforms, 4)
	var light_set := _uniform_set(light_pipeline.shader, light_uniforms)
	if not _dispatch(rd, light_pipeline.pipeline, light_set, grid, WORKGROUP_3D,
			"lighting/view%d" % view,
			{2: baked_set, 3: extension_set, 4: environment_set, 5: vlm_set}):
		return false
	var previous: RID = state.history[history_read_index]
	var reproject_set := _uniform_set(reproject_pipeline.shader, [
		RDUniforms.uniform_buffer(0, frame_ubo), RDUniforms.sampled(1, _sampler_nearest, state.injected),
		RDUniforms.sampled(2, _sampler_linear, previous), RDUniforms.image(3, state.history[history_write_index]),
		RDUniforms.sampled(4, _sampler_nearest, conservative_current),
		RDUniforms.sampled(5, _sampler_nearest, state.depth_history[history_read_index]),
	])
	if not _dispatch(rd, reproject_pipeline.pipeline, reproject_set, grid, WORKGROUP_3D,
			"reprojection/view%d" % view):
		return false
	var integrate_set := _uniform_set(integrate_pipeline.shader, [
		RDUniforms.uniform_buffer(0, frame_ubo),
		RDUniforms.sampled(1, _sampler_nearest, state.history[history_write_index]), RDUniforms.image(2, state.integrated),
	])
	return _dispatch(rd, integrate_pipeline.pipeline, integrate_set, Vector3i(grid.x, grid.y, 1),
			WORKGROUP_INTEGRATE, "integration/view%d" % view)


func _ensure_history_work_mask(rd: RenderingDevice, state: Dictionary,
		grid: Vector3i, view_count: int) -> bool:
	var required_bytes := grid.x * grid.y * grid.z * 4
	var mask: RID = state.get("history_work_mask", RID())
	if not mask.is_valid():
		mask = rd.storage_buffer_create(required_bytes)
		if not mask.is_valid():
			return false
		state["history_work_mask"] = mask
	var buffers: Array = state.get("work_mask_ubos", [])
	if buffers.size() == view_count:
		for rid in buffers:
			if not rid is RID or not rid.is_valid():
				return false
		return true
	for rid in buffers:
		if rid is RID and rid.is_valid():
			rd.free_rid(rid)
	var replacement: Array[RID] = []
	for _view in view_count:
		var ubo := rd.uniform_buffer_create(16)
		if not ubo.is_valid():
			for allocated in replacement:
				rd.free_rid(allocated)
			return false
		replacement.append(ubo)
	state["work_mask_ubos"] = replacement
	return true


func _history_work_mask_buffer(state: Dictionary) -> RID:
	var mask: RID = state.get("history_work_mask", RID())
	return mask if mask.is_valid() else _fallback_local_buffer


func _dispatch_history_work_mask(rd: RenderingDevice, state: Dictionary,
		frame_ubo: RID, grid: Vector3i, view: int, requested_samples: int) -> bool:
	var parameters := PackedInt32Array([requested_samples, 0, 0, 0]).to_byte_array()
	var work_mask_ubos: Array = state.get("work_mask_ubos", [])
	if view < 0 or view >= work_mask_ubos.size():
		return false
	var work_mask_ubo: RID = work_mask_ubos[view]
	if rd.buffer_update(work_mask_ubo, 0, parameters.size(), parameters) != OK:
		return false
	var pipeline_value: Variant = _pipelines.get("volumetric_fog_work_mask.glslinc", {})
	if not pipeline_value is Dictionary or pipeline_value.is_empty():
		return false
	var pipeline: Dictionary = pipeline_value
	var mask: RID = state.get("history_work_mask", RID())
	if not mask.is_valid():
		return false
	var current_depth: RID = state.depth_history[1 - int(state.history_index)]
	var previous_depth: RID = state.depth_history[int(state.history_index)]
	var set := _uniform_set(pipeline.shader, [
		RDUniforms.uniform_buffer(0, frame_ubo), RDUniforms.uniform_buffer(1, work_mask_ubo),
		RDUniforms.storage_buffer(2, mask),
		RDUniforms.sampled(3, _sampler_nearest, current_depth),
		RDUniforms.sampled(4, _sampler_nearest, previous_depth),
	])
	return _dispatch(rd, pipeline.pipeline, set, grid, WORKGROUP_3D,
			"history-work-mask/view%d" % view)


func _pack_light_uniform(frame: Dictionary, snapshot: Dictionary, volume: Dictionary,
		storage_exposure: float, selected_sun: RID, sky_inputs: Dictionary,
		baked_inputs: Dictionary, rt_enabled: bool = false,
		rt_slot_count: int = 0, rt_sample_count: int = 0,
		vlm_inputs: Dictionary = {}, baked_mode: int = BAKED_MODE_NONE) -> PackedFloat32Array:
	var directional_valid := _valid_buffer_rid(frame.get("directional_light_buffer", RID())) \
			and int(frame.get("directional_light_stride_bytes", 0)) == DIRECTIONAL_STRIDE \
			and int(frame.get("directional_light_buffer_capacity", 0)) == MAX_DIRECTIONAL_LIGHTS
	var omni_valid := _valid_buffer_rid(frame.get("omni_light_buffer", RID())) \
			and int(frame.get("omni_light_stride_bytes", 0)) == LOCAL_STRIDE
	var spot_valid := _valid_buffer_rid(frame.get("spot_light_buffer", RID())) \
			and int(frame.get("spot_light_stride_bytes", 0)) == LOCAL_STRIDE
	var area_valid := _valid_buffer_rid(frame.get("area_light_buffer", RID())) \
			and int(frame.get("area_light_stride_bytes", 0)) == LOCAL_STRIDE
	var directional_count := clampi(int(frame.get("directional_light_count", 0)), 0, MAX_DIRECTIONAL_LIGHTS) if directional_valid else 0
	var omni_count := maxi(int(frame.get("omni_light_count", 0)), 0) if omni_valid else 0
	var spot_count := maxi(int(frame.get("spot_light_count", 0)), 0) if spot_valid else 0
	var area_count := maxi(int(frame.get("area_light_count", 0)), 0) if area_valid else 0
	var cluster_valid := _valid_buffer_rid(frame.get("cluster_buffer", RID())) \
			and int(frame.get("cluster_layout_version", 0)) == 1
	var cluster_width := maxi(int(frame.get("cluster_width", 0)), 0) if cluster_valid else 0
	var cluster_height := maxi(int(frame.get("cluster_height", 0)), 0) if cluster_valid else 0
	var cluster_max := maxi(int(frame.get("cluster_max_elements", 0)), 0) if cluster_valid else 0
	var cluster_type_stride := maxi(int(frame.get("cluster_type_stride_words", 0)), 0) if cluster_valid else 0
	var cluster_header_words := maxi(int(frame.get("cluster_header_words", 0)), 0) if cluster_valid else 0
	var cluster_buckets := maxi(int(frame.get("cluster_z_bucket_count", 32)), 1) if cluster_valid else 1
	var selected_index := _selected_directional_index(frame, selected_sun, directional_count)
	var scene_norm := _positive(frame.get("scene_normalization", 1.0), 1.0)
	var light_buffer_norm := _positive(frame.get("light_buffer_exposure_normalization", 1.0), 1.0)
	var camera_exposure_norm := _positive(frame.get("camera_exposure_normalization", 1.0), 1.0)
	var lum := _positive(frame.get("luminance_multiplier", 1.0), 1.0)
	var sky_valid := bool(sky_inputs.get("can_apply", false)) \
			and _valid_buffer_rid(sky_inputs.get("sky_sh_buffer", RID()))
	var sky_rotation: Basis = frame.get("sky_light_rotation", Basis.IDENTITY)
	var sky_energy := maxf(float(sky_inputs.get("source_energy", 0.0)), 0.0) if sky_valid else 0.0
	var sky_capture := _positive(frame.get("sky_captured_exposure", 1.0), 1.0)
	var sky_scattering := maxf(float(sky_inputs.get("volumetric_scattering_intensity", 0.0)), 0.0) if sky_valid else 0.0
	var artist_fog_color: Variant = snapshot.get("artist_fog_inscattering_color", snapshot.get("fog_color", Vector3.ZERO))
	var artist_directional_color: Variant = snapshot.get("artist_directional_inscattering_color", Vector3.ZERO)
	var override_sky_color := artist_fog_color if artist_fog_color is Vector3 and artist_fog_color.is_finite() else Vector3.ZERO
	var override_directional_color := artist_directional_color \
			if artist_directional_color is Vector3 and artist_directional_color.is_finite() else Vector3.ZERO
	var override_requested := bool(volume.get("override_light_colors_with_fog_inscattering_colors", false))
	var directional_inscattering_active: bool = artist_directional_color is Vector3 \
			and artist_directional_color.is_finite() and artist_directional_color.length_squared() > 1.0e-8 \
			and float(snapshot.get("inscattering_start", -1.0)) >= 0.0
	var baked_valid := false
	var baked_exposure := 1.0
	var baked_key_matches := false
	if baked_mode == BAKED_MODE_LIGHTMAP_GI_PROBES:
		baked_valid = bool(baked_inputs.get("valid", false)) \
				and _valid_buffer_rid(baked_inputs.get("probe_positions_buffer", RID()))
		baked_exposure = _positive(baked_inputs.get("baked_exposure", 1.0), 1.0)
	elif baked_mode == BAKED_MODE_UE_VOLUMETRIC_LIGHTMAP:
		baked_valid = bool(vlm_inputs.get("valid", false)) \
				and bool(vlm_inputs.get("payload_valid", false))
		baked_exposure = _positive(vlm_inputs.get("baked_exposure", 1.0), 1.0)
		baked_key_matches = bool(vlm_inputs.get("static_light_key_match", false))
	if not baked_valid:
		baked_mode = BAKED_MODE_NONE
	# The light shader applies the shared storage pre-exposure once after all
	# incident sources are summed, so keep baked source scaling in scene space.
	var baked_scale := scene_norm / baked_exposure if baked_valid else 0.0
	var static_scattering := maxf(float(volume.get("static_lighting_scattering_intensity", 1.0)), 0.0)
	var history_miss_samples := Codec.normalize_history_miss_count(
			int(volume.get("history_miss_supersample_count", Codec.HISTORY_MISS_SUPERSAMPLE_COUNT)))
	var output := PackedFloat32Array()
	output.append_array(PackedFloat32Array([float(directional_count), float(omni_count), float(spot_count), float(area_count)]))
	output.append_array(PackedFloat32Array([
		float(frame.get("cluster_tile_size", Codec.FROXEL_PIXEL_SIZE)), float(cluster_width),
		float(cluster_height), float(cluster_max),
	]))
	output.append_array(PackedFloat32Array([
		float(cluster_type_stride), float(cluster_header_words), float(cluster_buckets), float(selected_index),
	]))
	output.append_array(PackedFloat32Array([light_buffer_norm, camera_exposure_norm, lum, storage_exposure]))
	output.append_array(PackedFloat32Array([1.0 if sky_valid else 0.0, sky_energy,
			sky_capture, sky_scattering]))
	for axis in [sky_rotation.x, sky_rotation.y, sky_rotation.z]:
		output.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	output.append_array(PackedFloat32Array([override_directional_color.x, override_directional_color.y,
			override_directional_color.z,
			1.0 if override_requested and directional_inscattering_active else 0.0]))
	output.append_array(PackedFloat32Array([override_sky_color.x, override_sky_color.y,
			override_sky_color.z,
			1.0 if override_requested else 0.0]))
	output.append_array(PackedFloat32Array([
		scene_norm, static_scattering, baked_scale,
		maxf(float(volume.get("light_soft_fading", UE_DEFAULT_LIGHT_SOFT_FADING)), 0.0),
	]))
	output.append_array(PackedFloat32Array([
		float(history_miss_samples), 1.0 if bool(volume.get("jitter_enabled", true)) else 0.0,
		1.0 if bool(volume.get("area_light_source_textures_enabled", false)) else 0.0, 1.0,
	]))
	output.append_array(PackedFloat32Array([
		1.0 if rt_enabled else 0.0, float(maxi(rt_slot_count, 0)),
		1.0 if selected_index >= 0 else 0.0, float(maxi(rt_sample_count, 0)),
	]))
	output.append_array(PackedFloat32Array([
		float(baked_mode), 1.0 if baked_key_matches else 0.0,
		1.0 if baked_valid else 0.0, 0.0,
	]))
	return output


func _selected_directional_index(frame: Dictionary, selected_sun: RID, count: int) -> int:
	if not selected_sun.is_valid():
		return -1
	var base_rids: Variant = frame.get("directional_light_base_rids", [])
	if not base_rids is Array:
		return -1
	for index in mini(base_rids.size(), count):
		var candidate: Variant = base_rids[index]
		if candidate is RID and candidate == selected_sun:
			return index
	return -1


func _baked_mode_for_snapshot(snapshot: Variant) -> int:
	if not snapshot is Dictionary or not bool(snapshot.get("valid", false)):
		return BAKED_MODE_NONE
	match String(snapshot.get("source_mode", "")):
		"lightmap_gi_probe_tetra":
			return BAKED_MODE_LIGHTMAP_GI_PROBES
		"ue_volumetric_lightmap_bricks":
			return BAKED_MODE_UE_VOLUMETRIC_LIGHTMAP
	return BAKED_MODE_NONE


func _selected_sun_static_lighting_key(frame: Dictionary, extension_rows: Dictionary,
		selected_sun: RID) -> String:
	var selected_index := _selected_directional_index(frame, selected_sun,
			int(frame.get("directional_light_count", 0)))
	if selected_index < 0:
		return ""
	var native_rids: Variant = frame.get("directional_light_base_rids", [])
	if not native_rids is Array or selected_index >= native_rids.size() \
			or native_rids[selected_index] != selected_sun:
		return ""
	var rows: Variant = extension_rows.get("rows", [])
	if not rows is Array:
		return ""
	for row_value in rows:
		if not row_value is Dictionary:
			continue
		if int(row_value.get("native_kind", -1)) == LightExtensionLayout.KIND_DIRECTIONAL \
				and int(row_value.get("native_index", -1)) == selected_index \
				and row_value.get("light_rid", RID()) == selected_sun:
			return _exact_static_lighting_key(row_value)
	return ""


static func _exact_static_lighting_key(row: Dictionary) -> String:
	# These opaque keys are compared byte-for-byte with the baked resource key.
	# Whitespace can be part of an authored identifier and is not normalized.
	return str(row.get("static_lighting_key", ""))


func _valid_frame_set(frames: Array[Dictionary], buffers: RenderSceneBuffersRD) -> bool:
	if frames.size() != buffers.get_view_count():
		return false
	var first: Dictionary = frames[0]
	for frame in frames:
		if int(frame.get("view_count", 0)) != frames.size() \
				or int(frame.get("frame_generation", -1)) != int(first.get("frame_generation", -2)) \
				or frame.get("internal_size") != first.get("internal_size"):
			return false
	return true


func _source_signature(snapshot: Dictionary, volume: Dictionary, frames: Array[Dictionary],
		local_volume_packet: Dictionary) -> String:
	var frame: Dictionary = frames[0] if not frames.is_empty() else {}
	var baked_snapshot: Variant = snapshot.get("baked_irradiance", {})
	var baked_source_key := str(baked_snapshot.get("static_directional_light_key", "")) \
			if baked_snapshot is Dictionary else ""
	var selected_sun: Variant = snapshot.get("volumetric_selected_sun_rid", RID())
	var extension_metadata: Variant = snapshot.get("light_extension_metadata", {})
	var extension_rows: Variant = extension_metadata.get("by_light_rid", {}) \
			if extension_metadata is Dictionary else {}
	var selected_sun_key := ""
	if selected_sun is RID and extension_rows is Dictionary:
		var selected_sun_row: Variant = extension_rows.get(selected_sun, {})
		if selected_sun_row is Dictionary:
			selected_sun_key = _exact_static_lighting_key(selected_sun_row)
	var baked_identity := [str(baked_snapshot.get("source_mode", "")),
			int(baked_snapshot.get("resource_id", 0)),
			int(baked_snapshot.get("revision", -1)), baked_source_key, selected_sun_key] \
			if baked_snapshot is Dictionary else ["", 0, -1, "", selected_sun_key]
	var identity := {
		"fog_id": int(snapshot.get("fog_id", 0)),
		"medium": volume,
		"height": [snapshot.get("fog_density", 0.0), snapshot.get("fog_height_falloff", 0.0),
				snapshot.get("fog_height", 0.0), snapshot.get("second_fog_density", 0.0),
				snapshot.get("second_fog_height_falloff", 0.0), snapshot.get("second_fog_height", 0.0)],
		"sun": snapshot.get("volumetric_selected_sun_rid", RID()),
		"sky": [frame.get("sky_light_source", RID()), frame.get("sky_light_source_owner_id", 0),
				frame.get("sky_light_source_valid", false)],
		"baked": baked_identity,
		"light_topology": [
			[frame.get("directional_light_buffer", RID()), frame.get("directional_light_count", 0)],
			[frame.get("omni_light_buffer", RID()), frame.get("omni_light_count", 0)],
			[frame.get("spot_light_buffer", RID()), frame.get("spot_light_count", 0)],
			[frame.get("area_light_buffer", RID()), frame.get("area_light_count", 0)],
		],
		"local_volumes": local_volume_packet.signature,
	}
	return var_to_str(identity).sha256_text()


func _history_contiguous(state: Dictionary, frames: Array[Dictionary], size: Vector2i,
		view_count: int, signature: String, volume: Dictionary) -> bool:
	var frame: Dictionary = frames[0]
	if not bool(state.get("history_valid", false)) or state.get("size") != size \
			or int(state.get("view_count", 0)) != view_count \
			or int(state.get("camera_generation", -1)) != int(frame.get("camera_generation", -2)) \
			or int(state.get("environment_id", -1)) != int(frame.get("environment_id", -2)) \
			or int(state.get("render_target_id", -1)) != int(frame.get("render_target_id", -2)) \
			or int(state.get("froxel_pixel_size", 0)) \
				!= int(volume.get("froxel_pixel_size", Codec.FROXEL_PIXEL_SIZE)) \
			or int(state.get("froxel_depth", 0)) \
				!= int(volume.get("froxel_depth", Codec.FROXEL_DEPTH)) \
			or int(state.get("last_frame_generation", -2)) + 1 != int(frame.get("frame_generation", -1)) \
			or str(state.get("signature", "")) != signature:
		return false
	var previous_origin: Vector3 = state.get("camera_origin", frame.camera_origin)
	var max_jump := maxf(float(volume.get("distance", 60.0)) * 0.35, 5.0)
	if previous_origin.distance_to(frame.camera_origin) > max_jump:
		return false
	var previous_basis: Basis = state.get("camera_basis", frame.camera_transform.basis)
	var current_basis: Basis = frame.camera_transform.basis
	if previous_basis.get_rotation_quaternion().angle_to(current_basis.get_rotation_quaternion()) > deg_to_rad(60.0):
		return false
	var stable_projection: Projection = frame.get("projection_unjittered", frame.projection)
	var previous_stable_projection: Projection = state.get("projection_unjittered", stable_projection)
	if _projection_changed(previous_stable_projection, stable_projection):
		return false
	var previous_offsets: Array = state.get("eye_offsets", [])
	var current_offsets := _eye_offsets(frames)
	if previous_offsets.size() != current_offsets.size():
		return false
	for index in previous_offsets.size():
		var previous_offset: Variant = previous_offsets[index]
		var current_offset: Variant = current_offsets[index]
		if not previous_offset is Vector3 or not current_offset is Vector3 \
				or previous_offset.distance_to(current_offset) > 1.0e-5:
			return false
	return true


func _eye_offsets(frames: Array[Dictionary]) -> Array:
	var offsets: Array = []
	for frame in frames:
		offsets.append(frame.get("eye_offset", Vector3.ZERO))
	return offsets


func _projection_changed(previous: Projection, current: Projection) -> bool:
	for column in 4:
		if (previous[column] - current[column]).length() > 1.0e-4:
			return true
	return false


func _ensure_state(buffers: RenderSceneBuffersRD, rd: RenderingDevice,
		grid: Vector3i, view_count: int) -> Dictionary:
	var key := buffers.get_instance_id()
	var state: Dictionary = _states.get(key, {})
	if not state.is_empty() and state.grid == grid and state.view_count == view_count:
		return state
	if not state.is_empty():
		_free_state(state, rd)
		# A failed replacement allocation must not leave freed RIDs or the prior
		# baked-resource identity reachable through the old state map entry.
		_states.erase(key)
	var atlas_size := Vector3i(grid.x * view_count, grid.y, grid.z)
	var textures: Dictionary = {}
	for name in ["medium", "emissive", "injected", "history0", "history1", "integrated"]:
		var texture := _create_3d_texture(rd, atlas_size)
		if not texture.is_valid():
			for allocated in textures.values():
				rd.free_rid(allocated)
			_set_failure("state", "cannot allocate %s RGBA16F 3D texture with size %s" % [name, atlas_size])
			return {}
		textures[name] = texture
	var depth_history: Array[RID] = []
	for _index in 2:
		var depth_texture := _create_conservative_depth_texture(rd, Vector2i(atlas_size.x, atlas_size.y))
		if not depth_texture.is_valid():
			for allocated in textures.values():
				rd.free_rid(allocated)
			for allocated in depth_history:
				rd.free_rid(allocated)
			_set_failure("state", "cannot allocate R32F depth-history 3D texture with size %s" % atlas_size)
			return {}
		depth_history.append(depth_texture)
	var frame_ubos: Array[RID] = []
	var light_ubos: Array[RID] = []
	for _view in view_count:
		var frame_ubo := rd.uniform_buffer_create(FRAME_BYTES)
		var light_ubo := rd.uniform_buffer_create(LIGHT_BYTES)
		if not frame_ubo.is_valid() or not light_ubo.is_valid():
			if frame_ubo.is_valid(): rd.free_rid(frame_ubo)
			if light_ubo.is_valid(): rd.free_rid(light_ubo)
			for allocated in textures.values(): rd.free_rid(allocated)
			for allocated in depth_history: rd.free_rid(allocated)
			for allocated in frame_ubos: rd.free_rid(allocated)
			for allocated in light_ubos: rd.free_rid(allocated)
			_set_failure("state", "cannot allocate frame/light UBO pair for view %d (frame=%s, light=%s)" % [
					_view, str(frame_ubo.is_valid()), str(light_ubo.is_valid())])
			return {}
		frame_ubos.append(frame_ubo)
		light_ubos.append(light_ubo)
	var local_volume_buffer := rd.storage_buffer_create(LocalVolumeCodec.BUFFER_BYTES)
	if not local_volume_buffer.is_valid():
		for allocated in textures.values(): rd.free_rid(allocated)
		for allocated in depth_history: rd.free_rid(allocated)
		for allocated in frame_ubos: rd.free_rid(allocated)
		for allocated in light_ubos: rd.free_rid(allocated)
		if local_volume_buffer.is_valid(): rd.free_rid(local_volume_buffer)
		_set_failure("state", "cannot allocate local-volume storage buffer for grid %s" % grid)
		return {}
	state = {
		"weak_buffers": weakref(buffers), "size": Vector2i.ZERO, "grid": grid,
		"view_count": view_count, "medium": textures.medium, "emissive": textures.emissive,
		"injected": textures.injected, "history": [textures.history0, textures.history1],
		"integrated": textures.integrated, "frame_ubos": frame_ubos, "light_ubos": light_ubos,
		"depth_history": depth_history,
		"local_volume_buffer": local_volume_buffer,
		"history_work_mask": RID(),
		"work_mask_ubos": [],
		"history_index": 0, "history_valid": false, "depth_history_valid": false,
		"previous_pre_exposure": 1.0,
		"last_frame_generation": -1, "camera_generation": -1, "environment_id": -1,
		"render_target_id": -1, "signature": "", "eye_offsets": [],
	}
	_states[key] = state
	return state


func _create_3d_texture(rd: RenderingDevice, size: Vector3i,
		data_format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = size.x
	format.height = size.y
	format.depth = size.z
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = data_format
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return rd.texture_create(format, RDTextureView.new(), [])


func _create_conservative_depth_texture(rd: RenderingDevice, size: Vector2i) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = size.x
	format.height = size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return rd.texture_create(format, RDTextureView.new(), [])


func _ensure_pipelines(rd: RenderingDevice) -> bool:
	for filename in ["volumetric_fog_medium.glslinc", "volumetric_fog_conservative_depth_compute.glslinc",
			"volumetric_fog_work_mask.glslinc",
			"volumetric_fog_light.glslinc",
			"volumetric_fog_reproject.glslinc", "volumetric_fog_integrate.glslinc"]:
		if _pipelines.has(filename):
			continue
		var expanded_source: String = ShaderSource.expand(SHADER_ROOT.path_join(filename))
		if expanded_source.is_empty():
			_last_error = "Cannot load or expand volumetric fog shader %s." % filename
			return false
		var source_fingerprint: String = expanded_source.sha256_text()
		var cached_failure: Variant = _failed_pipeline_sources.get(filename, {})
		if cached_failure is Dictionary \
				and String(cached_failure.get("fingerprint", "")) == source_fingerprint:
			_last_error = String(cached_failure.get("error", "Cached shader pipeline failure (%s)." % filename))
			return false
		var pipeline: Dictionary = _compile_pipeline(rd, filename, expanded_source)
		if pipeline.is_empty():
			if _last_error.is_empty():
				_set_failure("pipelines", "shader %s produced no pipeline and no lower-level error" % filename)
			_failed_pipeline_sources[filename] = {
				"fingerprint": source_fingerprint,
				"error": _last_error,
			}
			return false
		_failed_pipeline_sources.erase(filename)
		_pipelines[filename] = pipeline
	return true


func _compile_pipeline(rd: RenderingDevice, filename: String, source: String) -> Dictionary:
	source = source.replace("#[compute]", "")
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = source
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	if spirv == null or not spirv.compile_error_compute.is_empty():
		_last_error = "Volumetric shader compile failed (%s): %s" % [filename,
				spirv.compile_error_compute if spirv != null else "no SPIR-V result"]
		return {}
	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		_last_error = "Cannot create volumetric shader RID for %s." % filename
		return {}
	var pipeline := rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		rd.free_rid(shader)
		_last_error = "Cannot create volumetric compute pipeline for %s." % filename
		return {}
	return {"shader": shader, "pipeline": pipeline}


func _ensure_fallbacks(rd: RenderingDevice) -> bool:
	if not _sampler_nearest.is_valid():
		_sampler_nearest = _make_sampler(rd, false, false)
	if not _sampler_linear.is_valid():
		_sampler_linear = _make_sampler(rd, true, false)
	if not _sampler_compare.is_valid():
		_sampler_compare = _make_sampler(rd, true, true)
	if not _fallback_texture_2d.is_valid():
		_fallback_texture_2d = _create_color_texture(rd, RenderingDevice.TEXTURE_TYPE_2D, 1, 1, 1)
	if not _fallback_texture_array.is_valid():
		_fallback_texture_array = _create_color_texture(rd, RenderingDevice.TEXTURE_TYPE_2D_ARRAY, 1, 1, 1)
	if not _fallback_density_3d.is_valid():
		_fallback_density_3d = _create_density_texture(rd)
	if not _fallback_depth_2d.is_valid():
		_fallback_depth_2d = _create_depth_texture_2d(rd)
	if not _fallback_shadow.is_valid():
		_fallback_shadow = _create_shadow_texture(rd)
	if not _fallback_directional_buffer.is_valid():
		_fallback_directional_buffer = rd.uniform_buffer_create(DIRECTIONAL_STRIDE * MAX_DIRECTIONAL_LIGHTS)
	if not _fallback_local_buffer.is_valid():
		_fallback_local_buffer = rd.storage_buffer_create(LOCAL_STRIDE)
	if not _fallback_cluster_buffer.is_valid():
		_fallback_cluster_buffer = rd.storage_buffer_create(4)
	if not _fallback_sky_sh_buffer.is_valid():
		_fallback_sky_sh_buffer = _zero_storage_buffer(rd, 7 * 16)
	if _fallback_baked_buffers.is_empty():
		_fallback_baked_buffers = {
			"probe_positions_buffer": _zero_storage_buffer(rd, 16),
			"probe_sh_buffer": _zero_storage_buffer(rd, 27 * 4),
			"tetrahedra_buffer": _zero_storage_buffer(rd, 16),
			"bsp_nodes_buffer": _zero_storage_buffer(rd, 6 * 4),
			"params_buffer": _zero_uniform_buffer(rd, BakedLightingProviderScript.PARAMS_BYTES),
		}
	var validity := {
		"nearest sampler": _sampler_nearest.is_valid(), "linear sampler": _sampler_linear.is_valid(),
		"compare sampler": _sampler_compare.is_valid(), "2D fallback texture": _fallback_texture_2d.is_valid(),
		"array fallback texture": _fallback_texture_array.is_valid(), "3D density fallback": _fallback_density_3d.is_valid(),
		"2D depth fallback": _fallback_depth_2d.is_valid(),
		"shadow fallback": _fallback_shadow.is_valid(), "directional buffer fallback": _fallback_directional_buffer.is_valid(),
		"local buffer fallback": _fallback_local_buffer.is_valid(), "cluster buffer fallback": _fallback_cluster_buffer.is_valid(),
		"sky SH fallback buffer": _fallback_sky_sh_buffer.is_valid(),
	}
	for buffer_name in _fallback_baked_buffers:
		validity["baked fallback " + String(buffer_name)] = _fallback_baked_buffers[buffer_name].is_valid()
	for resource_name in validity:
		if not bool(validity[resource_name]):
			_set_failure("fallbacks", "failed to create %s" % resource_name)
			return false
	return true


func _make_sampler(rd: RenderingDevice, linear: bool, compare: bool) -> RID:
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR if linear else RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = state.min_filter
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.enable_compare = compare
	if compare:
		state.compare_op = RenderingDevice.COMPARE_OP_GREATER
	return rd.sampler_create(state)


func _create_color_texture(rd: RenderingDevice, texture_type: int, width: int,
		height: int, layers: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = texture_type
	format.width = width
	format.height = height
	format.depth = 1
	format.array_layers = layers
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var zero := PackedByteArray()
	zero.resize(8 * maxi(layers, 1))
	return rd.texture_create(format, RDTextureView.new(), [zero])


func _create_shadow_texture(rd: RenderingDevice) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_D32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(format, RDTextureView.new(), [PackedFloat32Array([1.0]).to_byte_array()])


func _zero_storage_buffer(rd: RenderingDevice, size_bytes: int) -> RID:
	var bytes := PackedByteArray()
	bytes.resize(size_bytes)
	return rd.storage_buffer_create(size_bytes, bytes)


func _zero_uniform_buffer(rd: RenderingDevice, size_bytes: int) -> RID:
	var bytes := PackedByteArray()
	bytes.resize(size_bytes)
	return rd.uniform_buffer_create(size_bytes, bytes)


func _baked_uniforms(baked_inputs: Dictionary) -> Array[RDUniform]:
	var bindings := ["probe_positions_buffer", "probe_sh_buffer", "tetrahedra_buffer",
			"bsp_nodes_buffer", "params_buffer"]
	var uniforms: Array[RDUniform] = []
	for binding in bindings.size():
		var buffer_name: String = bindings[binding]
		var rid: Variant = baked_inputs.get(buffer_name, RID())
		if not _valid_buffer_rid(rid):
			rid = _fallback_baked_buffers.get(buffer_name, RID())
		uniforms.append(RDUniforms.uniform_buffer(binding, rid) if binding == 4
				else RDUniforms.storage_buffer(binding, rid))
	return uniforms


func _create_density_texture(rd: RenderingDevice) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(format, RDTextureView.new(), [
		PackedByteArray([0x00, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c])])


func _create_depth_texture_2d(rd: RenderingDevice) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(format, RDTextureView.new(), [PackedFloat32Array([0.0]).to_byte_array()])


func _directional_buffer(frame: Dictionary, rd: RenderingDevice) -> RID:
	var rid: Variant = frame.get("directional_light_buffer", RID())
	if _valid_buffer_rid(rid) and int(frame.get("directional_light_stride_bytes", 0)) == DIRECTIONAL_STRIDE \
			and int(frame.get("directional_light_buffer_capacity", 0)) == MAX_DIRECTIONAL_LIGHTS:
		return rid
	return _fallback_directional_buffer


func _local_buffer(frame: Dictionary, buffer_key: String, count_key: String, rd: RenderingDevice) -> RID:
	var rid: Variant = frame.get(buffer_key, RID())
	var prefix := buffer_key.trim_suffix("_light_buffer")
	if int(frame.get(count_key, 0)) > 0 and _valid_buffer_rid(rid) \
			and int(frame.get(prefix + "_light_stride_bytes", 0)) == LOCAL_STRIDE:
		return rid
	return _fallback_local_buffer


func _cluster_buffer(frame: Dictionary, rd: RenderingDevice) -> RID:
	var rid: Variant = frame.get("cluster_buffer", RID())
	return rid if _valid_buffer_rid(rid) else _fallback_cluster_buffer


func _shadow_texture(frame: Dictionary, key: String, rd: RenderingDevice) -> RID:
	return _texture(frame.get(key, RID()), _fallback_shadow, rd)


func _frame_sampler(value: Variant, fallback: RID) -> RID:
	return value if value is RID and value.is_valid() else fallback


func _sky_texture_for_type(frame: Dictionary, array_texture: bool, rd: RenderingDevice) -> RID:
	var is_array := bool(frame.get("sky_radiance_is_array", false))
	if is_array != array_texture:
		return _fallback_texture_array if array_texture else _fallback_texture_2d
	return _texture(frame.get("sky_radiance_texture", RID()),
			_fallback_texture_array if array_texture else _fallback_texture_2d, rd)


func _texture(value: Variant, fallback: RID, rd: RenderingDevice) -> RID:
	if value is RID and value.is_valid() and rd.texture_is_valid(value):
		return value
	return fallback


func _valid_texture(value: Variant) -> bool:
	return value is RID and value.is_valid()


func _valid_texture_rid(value: Variant) -> bool:
	return value is RID and value.is_valid()


func _valid_buffer_rid(value: Variant) -> bool:
	return value is RID and value.is_valid()


func _uniform_set(shader: RID, uniforms: Array[RDUniform], set_index: int = 0) -> RID:
	return UniformSetCacheRD.get_cache(shader, set_index, uniforms) if not uniforms.is_empty() else RID()


func _dispatch(rd: RenderingDevice, pipeline: RID, uniform_set: RID,
		size: Vector3i, workgroup: int, stage: String = "compute",
		additional_sets: Dictionary = {}) -> bool:
	if not pipeline.is_valid() or not uniform_set.is_valid() or size.x <= 0 or size.y <= 0 or size.z <= 0:
		_set_failure("dispatch", "%s has invalid pipeline=%s uniform_set=%s dimensions=%s" % [
				stage, str(pipeline.is_valid()), str(uniform_set.is_valid()), size])
		return false
	var list := rd.compute_list_begin()
	if list < 0:
		_set_failure("dispatch", "%s could not begin a compute list" % stage)
		return false
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	for set_index in additional_sets.keys():
		var additional_set: RID = additional_sets[set_index]
		if not additional_set.is_valid():
			rd.compute_list_end()
			_set_failure("dispatch", "%s has invalid descriptor set %d" % [stage, int(set_index)])
			return false
		rd.compute_list_bind_uniform_set(list, additional_set, int(set_index))
	rd.compute_list_dispatch(list, ceili(float(size.x) / float(workgroup)),
			ceili(float(size.y) / float(workgroup)), ceili(float(size.z) / float(workgroup)))
	rd.compute_list_end()
	return true


func _update_ubo(rid: RID, values: PackedFloat32Array, bytes: int, rd: RenderingDevice) -> bool:
	var data := values.to_byte_array()
	return rid.is_valid() and data.size() == bytes and rd.buffer_update(rid, 0, data.size(), data) == OK


func _release_state_for(buffers: RenderSceneBuffersRD, rd: RenderingDevice) -> void:
	if buffers == null:
		return
	var key := buffers.get_instance_id()
	if _states.has(key):
		_free_state(_states[key], rd)
		_states.erase(key)
		_release_unreferenced_baked_resources()


func _prune_states(current: RenderSceneBuffersRD, rd: RenderingDevice) -> void:
	var current_id := current.get_instance_id() if current != null else 0
	var removed_state := false
	for key in _states.keys():
		if key == current_id:
			continue
		var state: Dictionary = _states[key]
		var reference: WeakRef = state.get("weak_buffers")
		var buffers: Object = reference.get_ref() if reference != null else null
		if buffers == null or not is_instance_valid(buffers):
			_free_state(state, rd)
			_states.erase(key)
			removed_state = true
	if removed_state:
		_release_unreferenced_baked_resources()


static func _unreferenced_baked_resource_ids(states: Dictionary, tracked_ids: Dictionary,
		source_mode: int) -> Array[int]:
	var live_ids: Dictionary = {}
	for state_value in states.values():
		if not state_value is Dictionary \
				or int(state_value.get("baked_source_mode", BAKED_MODE_NONE)) != source_mode:
			continue
		var resource_id := int(state_value.get("baked_resource_id", 0))
		if resource_id != 0:
			live_ids[resource_id] = true
	var unused: Array[int] = []
	for resource_id_value in tracked_ids.keys():
		var resource_id := int(resource_id_value)
		if resource_id != 0 and not live_ids.has(resource_id):
			unused.append(resource_id)
	return unused


func _release_unreferenced_baked_resources() -> void:
	for resource_id in _unreferenced_baked_resource_ids(_states,
			_tracked_baked_probe_resource_ids, BAKED_MODE_LIGHTMAP_GI_PROBES):
		_baked_lighting_provider.release_resource(resource_id)
		_tracked_baked_probe_resource_ids.erase(resource_id)
	for resource_id in _unreferenced_baked_resource_ids(_states,
			_tracked_vlm_resource_ids, BAKED_MODE_UE_VOLUMETRIC_LIGHTMAP):
		_volumetric_lightmap_provider.release_resource(resource_id)
		_tracked_vlm_resource_ids.erase(resource_id)


func _state_rids(state: Dictionary) -> Array[RID]:
	var result: Array[RID] = []
	for key in ["medium", "emissive", "injected", "integrated"]:
		var rid: RID = state.get(key, RID())
		if rid.is_valid(): result.append(rid)
	for rid in state.get("history", []):
		if rid is RID and rid.is_valid(): result.append(rid)
	for rid in state.get("depth_history", []):
		if rid is RID and rid.is_valid(): result.append(rid)
	for key in ["frame_ubos", "light_ubos", "work_mask_ubos"]:
		for rid in state.get(key, []):
			if rid is RID and rid.is_valid(): result.append(rid)
	var local_volume_buffer: RID = state.get("local_volume_buffer", RID())
	if local_volume_buffer.is_valid():
		result.append(local_volume_buffer)
	var history_work_mask: RID = state.get("history_work_mask", RID())
	if history_work_mask.is_valid():
		result.append(history_work_mask)
	return result


func _free_state(state: Dictionary, rd: RenderingDevice) -> void:
	if rd == null:
		return
	for rid in _state_rids(state):
		rd.free_rid(rid)


func _clear_native_output(ctx: FRPPassContext) -> void:
	if ctx != null and ctx.has_method("clear_volume_output"):
		ctx.call("clear_volume_output")


func _positive(value: Variant, fallback: float) -> float:
	if not (value is float or value is int) or not is_finite(float(value)) or float(value) <= 0.0:
		return fallback
	return float(value)


func _current_depth_available(ctx: FRPPassContext, frame: Dictionary, depth: RID,
		rd: RenderingDevice) -> bool:
	if ctx == null or not ctx.has_method("is_operation_completed") \
			or not bool(ctx.call("is_operation_completed", FRPPassContext.OP_GBUFFER)) \
			or not bool(frame.get("depth_prepass_enabled", false)) \
			or not depth.is_valid() or not rd.texture_is_valid(depth):
		return false
	var depth_format: RDTextureFormat = rd.texture_get_format(depth)
	var internal_size: Vector2i = frame.get("internal_size", Vector2i.ZERO)
	return depth_format.texture_type == RenderingDevice.TEXTURE_TYPE_2D \
			and depth_format.width == internal_size.x and depth_format.height == internal_size.y \
			and (depth_format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) != 0
