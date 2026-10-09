@tool
extends RefCounted
## UE's advanced scene-color scattering path has its own 2D history and blur
## pyramid. It shares only the frame-input codec with volumetric fog.

const Codec = preload("feng_volumetric_fog_codec.gd")
const OwnedRids = preload("res://addons/feng-render-pipeline/rd/owned_rids.gd")
const ShaderSource = preload("res://addons/feng-render-pipeline/rd/shader_source.gd")
const RDUniforms = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const SHADER_ROOT := "res://addons/feng-fog/rendering/shaders/"
const FRAME_BYTES := 288
const ANALYTIC_BYTES := 96
const ATMOSPHERE_BYTES := 256
const CLOUD_VISIBILITY_BYTES := 592
const WORKGROUP := 8

var _pipelines: Dictionary = {}
var _failed_pipeline_sources: Dictionary = {}
var _states: Dictionary = {}
var _sampler_nearest := RID()
var _sampler_linear := RID()
var _empty_volume_texture := RID()
var _empty_fsss_texture := RID()
var _empty_cloud_radiance := RID()
var _empty_cloud_transmittance := RID()
var _last_error := ""


func render(ctx: FRPPassContext, snapshot: Dictionary, buffers: RenderSceneBuffersRD,
		rd: RenderingDevice, color_textures: Array[RID], depth_textures: Array[RID],
		frame_inputs: Array[Dictionary] = [], source_options: Dictionary = {}) -> Dictionary:
	_last_error = ""
	_prune_states(buffers, rd)
	if ctx == null or buffers == null or rd == null:
		_release_state_for(buffers, rd)
		return {}
	var settings := Codec.normalize_screen_space_scattering(snapshot.get("screen_space_scattering", {}))
	if settings.is_empty():
		_release_state_for(buffers, rd)
		return {}
	var frames: Array[Dictionary] = frame_inputs.duplicate()
	if frames.is_empty():
		if not ctx.has_method("get_volume_frame_inputs"):
			return {}
		for view in buffers.get_view_count():
			var frame := Codec.normalize_frame_inputs(ctx.call("get_volume_frame_inputs", view), view)
			if frame.is_empty():
				_release_state_for(buffers, rd)
				return {}
			frames.append(frame)
	if frames.is_empty() or frames.size() != color_textures.size() or frames.size() != depth_textures.size():
		_release_state_for(buffers, rd)
		return {}
	for view in frames.size():
		if not _valid_texture(rd, color_textures[view]) or not _valid_texture(rd, depth_textures[view]):
			_release_state_for(buffers, rd)
			return {}
	if not _ensure_pipelines(rd) or not _ensure_samplers(rd) \
			or not _ensure_source_textures(rd):
		return {}
	var size: Vector2i = frames[0].internal_size
	var state := _ensure_state(buffers, rd, size, frames.size())
	if state.is_empty():
		return {}
	var analytic_by_view: Array = source_options.get("fog_parameters_by_view", [])
	var atmosphere_by_view: Array = source_options.get("atmosphere_parameters_by_view", [])
	var sampling_ubos: Array = source_options.get("sampling_ubos", [])
	if analytic_by_view.size() != frames.size() or sampling_ubos.size() != frames.size():
		_last_error = "FSSS source generation requires one analytic packet and volume sampling UBO per view."
		return {}
	if atmosphere_by_view.size() != frames.size():
		atmosphere_by_view.clear()
		for _view in frames.size():
			var neutral_atmosphere := PackedFloat32Array()
			neutral_atmosphere.resize(64)
			atmosphere_by_view.append(neutral_atmosphere)
	var volume_texture: RID = source_options.get("volume_texture", RID())
	if not _valid_texture(rd, volume_texture):
		volume_texture = _empty_volume(rd)
	var cloud_composition: Dictionary = source_options.get("cloud_composition", {})
	var cloud_radiance: RID = cloud_composition.get("radiance", RID())
	var cloud_transmittance: RID = cloud_composition.get("transmittance", RID())
	var cloud_valid: bool = int(source_options.get("source_mode", 0)) == 2 \
			and _valid_texture(rd, cloud_radiance) and _valid_texture(rd, cloud_transmittance)
	if not cloud_valid:
		cloud_radiance = _empty_cloud_radiance_texture(rd)
		cloud_transmittance = _empty_cloud_transmittance_texture(rd)
	if not _valid_texture(rd, volume_texture) or not cloud_radiance.is_valid() \
			or not cloud_transmittance.is_valid():
		_last_error = "FSSS source generation could not allocate neutral source textures."
		return {}
	var volume_sample_parameters: Variant = source_options.get("volume_sample_parameters", PackedFloat32Array())
	var source_signature := [settings,
			source_options.get("history_signature", {}),
			source_options.get("volume_source_signature", ""),
			_volume_geometry_signature(volume_sample_parameters),
			int(source_options.get("source_mode", 0)),
			cloud_composition.get("history_identity", [
				cloud_composition.get("buffer_id", 0),
				cloud_composition.get("view_count", 0),
				cloud_composition.get("internal_size", Vector2i.ZERO),
			])]
	var signature := var_to_str(source_signature).sha256_text()
	var history_valid := _history_valid(state, frames, size, signature)
	if not history_valid:
		state.history_index = 0
	var read_index := int(state.history_index)
	var write_index := 1 - read_index
	var values_ok := true
	for view in frames.size():
		var frame: Dictionary = frames[view]
		var frame_values := _pack_frame(frame, float(state.previous_exposures[view]),
				bool(history_valid), int(source_options.get("source_mode", 0)))
		if frame_values.size() * 4 != FRAME_BYTES \
				or not _update_ubo(state.frame_ubos[view], frame_values, rd):
			values_ok = false
			break
		var fog_values := _pack_analytic(analytic_by_view[view])
		if fog_values.size() * 4 != ANALYTIC_BYTES \
				or not _update_ubo_bytes(state.analytic_ubos[view], fog_values, ANALYTIC_BYTES, rd):
			values_ok = false
			break
		if not _dispatch_view(rd, state, view, read_index, write_index,
				color_textures[view], depth_textures[view], history_valid, size,
				settings, volume_texture, sampling_ubos[view],
				atmosphere_by_view[view], source_options,
				cloud_radiance, cloud_transmittance):
			values_ok = false
			break
	if not values_ok:
		state.history_valid = false
		return {}
	state.history_index = write_index
	state.history_valid = true
	state.previous_exposures.clear()
	for frame in frames:
		state.previous_exposures.append(_domain_scale(frame))
	state.last_frame_generation = int(frames[0].frame_generation)
	state.camera_generation = int(frames[0].camera_generation)
	state.environment_id = int(frames[0].get("environment_id", 0))
	state.render_target_id = int(frames[0].get("render_target_id", 0))
	state.signature = signature
	state.size = size
	state.view_count = frames.size()
	state.eye_offsets = _eye_offsets(frames)
	state.camera_origin = frames[0].camera_origin
	state.camera_basis = frames[0].camera_transform.basis
	state.projection_unjittered = frames[0].projection_unjittered
	_states[buffers.get_instance_id()] = state
	return {
		"textures_by_view": state.textures[write_index],
		"maximum_mip": state.mip_count - 1,
		"settings": settings,
	}


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
	OwnedRids.append(rids, seen, _sampler_nearest)
	OwnedRids.append(rids, seen, _sampler_linear)
	OwnedRids.append(rids, seen, _empty_volume_texture)
	OwnedRids.append(rids, seen, _empty_fsss_texture)
	OwnedRids.append(rids, seen, _empty_cloud_radiance)
	OwnedRids.append(rids, seen, _empty_cloud_transmittance)
	if p_clear:
		_states.clear()
		_pipelines.clear()
		_failed_pipeline_sources.clear()
		_sampler_nearest = RID()
		_sampler_linear = RID()
		_empty_volume_texture = RID()
		_empty_fsss_texture = RID()
		_empty_cloud_radiance = RID()
		_empty_cloud_transmittance = RID()
	return rids


func get_last_error() -> String:
	return _last_error


static func mip_count_for_size(size: Vector2i) -> int:
	# A complete 2D chain is based on the longer axis and includes mip 0 and
	# the final 1x1 level. Using ceil(log2(min(width, height))) omits levels for
	# powers of two and for non-square targets.
	var longest_axis := maxi(maxi(size.x, size.y), 1)
	return int(floor(log(float(longest_axis)) / log(2.0))) + 1


func _pack_frame(frame: Dictionary, previous_exposure: float,
		history_valid: bool, source_mode: int) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	_append_projection(values, frame.inverse_projection)
	_append_transform(values, frame.camera_transform)
	_append_projection(values, frame.previous_projection)
	_append_transform(values, frame.previous_camera_transform.affine_inverse())
	values.append_array(PackedFloat32Array([
		_domain_scale(frame), _positive(previous_exposure, 1.0),
		0.9, 1.0 if history_valid else 0.0,
	]))
	values.append_array(PackedFloat32Array([
		float(frame.internal_size.x), float(frame.internal_size.y), 0.02,
			float(clampi(source_mode, 0, 2)),
	]))
	return values


func _pack_analytic(value: Variant) -> PackedFloat32Array:
	if not value is PackedFloat32Array or value.size() != 28:
		return PackedFloat32Array()
	return value.slice(4, 28)


func _dispatch_view(rd: RenderingDevice, state: Dictionary, view: int,
		read_index: int, write_index: int, scene_color: RID, depth: RID,
		history_valid: bool, size: Vector2i, settings: Dictionary,
		volume_texture: RID, sampling_ubo: RID,
		atmosphere_parameters: PackedFloat32Array, source_options: Dictionary,
		cloud_radiance: RID, cloud_transmittance: RID) -> bool:
	var reproject: Dictionary = _pipelines["fsss_reproject.glslinc"]
	var downsample: Dictionary = _pipelines["fsss_downsample.glslinc"]
	var filter: Dictionary = _pipelines["fsss_filter.glslinc"]
	var upsample: Dictionary = _pipelines["fsss_upsample.glslinc"]
	var output_mips: Array = state.mip_views[write_index][view]
	var previous: RID = state.textures[read_index][view]
	var previous_depth: RID = state.depth_histories[read_index][view]
	var output_depth: RID = state.depth_histories[write_index][view]
	var frame_ubo: RID = state.frame_ubos[view]
	var analytic_ubo: RID = state.analytic_ubos[view]
	var atmosphere_ubo: RID = state.atmosphere_ubos[view]
	var cloud_visibility_ubo: RID = state.cloud_visibility_ubos[view]
	if atmosphere_parameters.size() != 64:
		atmosphere_parameters = PackedFloat32Array()
		atmosphere_parameters.resize(64)
	if not _update_ubo_bytes(atmosphere_ubo, atmosphere_parameters, ATMOSPHERE_BYTES, rd):
		return false
	var cloud_parameters: PackedFloat32Array = source_options.get(
			"cloud_visibility_parameters", PackedFloat32Array())
	if cloud_parameters.size() != 148:
		cloud_parameters = PackedFloat32Array()
		cloud_parameters.resize(148)
		cloud_parameters[140] = -1.0
		cloud_parameters[141] = -1.0
	var shadow0: RID = source_options.get("cloud_shadow0_texture", RID())
	var shadow1: RID = source_options.get("cloud_shadow1_texture", RID())
	var cloud_ao: RID = source_options.get("cloud_raw_ao_texture", RID())
	if not _valid_texture(rd, shadow0):
		cloud_parameters[142] = 0.0
	if not _valid_texture(rd, shadow1):
		cloud_parameters[143] = 0.0
	if not _valid_texture(rd, cloud_ao):
		cloud_parameters[144] = 0.0
	if not _update_ubo_bytes(cloud_visibility_ubo, cloud_parameters,
			CLOUD_VISIBILITY_BYTES, rd):
		return false
	var optical_texture: RID = source_options.get("atmosphere_optical_texture", RID())
	var multiple_texture: RID = source_options.get("atmosphere_multiple_texture", RID())
	if not _valid_texture(rd, optical_texture):
		optical_texture = _empty_fsss_texture
	if not _valid_texture(rd, multiple_texture):
		multiple_texture = _empty_fsss_texture
	if not _valid_texture(rd, shadow0):
		shadow0 = _empty_fsss_texture
	if not _valid_texture(rd, shadow1):
		shadow1 = _empty_fsss_texture
	if not _valid_texture(rd, cloud_ao):
		cloud_ao = _empty_fsss_texture
	var reproject_set := _uniform_set(reproject.shader, [
		RDUniforms.uniform_buffer(0, frame_ubo), RDUniforms.sampled(1, _sampler_nearest, scene_color),
		RDUniforms.sampled(2, _sampler_nearest, depth), RDUniforms.sampled(3, _sampler_linear, previous),
		RDUniforms.image(4, output_mips[0]), RDUniforms.uniform_buffer(5, analytic_ubo),
		RDUniforms.sampled(6, _sampler_nearest, previous_depth), RDUniforms.image(7, output_depth),
		RDUniforms.sampled(9, _sampler_nearest, volume_texture),
		RDUniforms.sampled(10, _sampler_linear, _empty_fsss_texture),
		RDUniforms.uniform_buffer(11, sampling_ubo), RDUniforms.sampled(12, _sampler_nearest, cloud_radiance),
		RDUniforms.sampled(13, _sampler_nearest, cloud_transmittance),
		RDUniforms.uniform_buffer(14, atmosphere_ubo),
		RDUniforms.sampled(15, _sampler_linear, optical_texture),
		RDUniforms.sampled(16, _sampler_linear, multiple_texture),
		RDUniforms.uniform_buffer(17, cloud_visibility_ubo),
		RDUniforms.sampled(18, _sampler_linear, shadow0),
		RDUniforms.sampled(19, _sampler_linear, shadow1),
		RDUniforms.sampled(20, _sampler_linear, cloud_ao),
	])
	if not _dispatch(rd, reproject.pipeline, reproject_set, size):
		return false
	var downsample_mips: Array = state.downsample_mip_views[view]
	var blur_mips: Array = state.blur_mip_views[view]
	for mip in range(1, state.mip_count):
		var source_view: RID = output_mips[0] if mip == 1 else downsample_mips[mip - 1]
		var target_view: RID = downsample_mips[mip]
		var source_set := _uniform_set(downsample.shader, [
			RDUniforms.sampled(0, _sampler_linear, source_view), RDUniforms.image(1, target_view),
		])
		var mip_size := Vector2i(maxi(size.x >> mip, 1), maxi(size.y >> mip, 1))
		if not _dispatch(rd, downsample.pipeline, source_set, mip_size):
			return false
		var filter_set := _uniform_set(filter.shader, [
			RDUniforms.sampled(0, _sampler_linear, target_view), RDUniforms.image(1, blur_mips[mip]),
		])
		if not _dispatch(rd, filter.pipeline, filter_set, mip_size):
			return false
	var upsample_ubo: RID = state.upsample_ubos[view]
	for mip in range(state.mip_count - 1, 0, -1):
		var has_coarser_mip: bool = mip + 1 < int(state.mip_count)
		var coarser_view: RID = output_mips[mip + 1] if has_coarser_mip else blur_mips[mip]
		var control_values := PackedFloat32Array([
			float(settings.get("blur_control", 0.5)), 1.0 if has_coarser_mip else 0.0, 0.0, 0.0,
		])
		var control_bytes := control_values.to_byte_array()
		if rd.buffer_update(upsample_ubo, 0, control_bytes.size(), control_bytes) != OK:
			return false
		var upsample_set := _uniform_set(upsample.shader, [
			RDUniforms.sampled(0, _sampler_linear, blur_mips[mip]),
			RDUniforms.sampled(1, _sampler_linear, coarser_view),
			RDUniforms.image(2, output_mips[mip]), RDUniforms.uniform_buffer(3, upsample_ubo),
		])
		var mip_size := Vector2i(maxi(size.x >> mip, 1), maxi(size.y >> mip, 1))
		if not _dispatch(rd, upsample.pipeline, upsample_set, mip_size):
			return false
	return true


func _ensure_state(buffers: RenderSceneBuffersRD, rd: RenderingDevice,
		size: Vector2i, view_count: int) -> Dictionary:
	var key := buffers.get_instance_id()
	var state: Dictionary = _states.get(key, {})
	var mip_count := mip_count_for_size(size)
	if not state.is_empty() and state.size == size and state.view_count == view_count \
			and state.mip_count == mip_count:
		return state
	if not state.is_empty():
		_free_state(state, rd)
	var textures: Array = [[], []]
	var mip_views: Array = [[], []]
	var depth_histories: Array = [[], []]
	var downsample_textures: Array = []
	var downsample_mip_views: Array = []
	var blur_textures: Array = []
	var blur_mip_views: Array = []
	var allocated: Array[RID] = []
	for slot in 2:
		for view in view_count:
			var chain := _create_mip_chain(rd, size, mip_count, allocated)
			if chain.is_empty():
				_free_rids(allocated, rd)
				return {}
			textures[slot].append(chain.texture)
			mip_views[slot].append(chain.views)
			var depth_history := _create_depth_texture(rd, size)
			if not depth_history.is_valid():
				_free_rids(allocated, rd)
				return {}
			allocated.append(depth_history)
			depth_histories[slot].append(depth_history)
	for _view in view_count:
		var downsample_chain := _create_mip_chain(rd, size, mip_count, allocated)
		var blur_chain := _create_mip_chain(rd, size, mip_count, allocated)
		if downsample_chain.is_empty() or blur_chain.is_empty():
			_free_rids(allocated, rd)
			return {}
		downsample_textures.append(downsample_chain.texture)
		downsample_mip_views.append(downsample_chain.views)
		blur_textures.append(blur_chain.texture)
		blur_mip_views.append(blur_chain.views)
	var ubos: Array[RID] = []
	var analytic_ubos: Array[RID] = []
	var atmosphere_ubos: Array[RID] = []
	var cloud_visibility_ubos: Array[RID] = []
	var upsample_ubos: Array[RID] = []
	for _view in view_count:
		var ubo := rd.uniform_buffer_create(FRAME_BYTES)
		if not ubo.is_valid():
			_free_rids(allocated, rd)
			_free_rids(ubos, rd)
			_free_rids(analytic_ubos, rd)
			_free_rids(atmosphere_ubos, rd)
			_free_rids(cloud_visibility_ubos, rd)
			_free_rids(upsample_ubos, rd)
			return {}
		ubos.append(ubo)
		var analytic_ubo := rd.uniform_buffer_create(ANALYTIC_BYTES)
		if not analytic_ubo.is_valid():
			_free_rids(allocated, rd)
			_free_rids(ubos, rd)
			_free_rids(analytic_ubos, rd)
			_free_rids(atmosphere_ubos, rd)
			_free_rids(cloud_visibility_ubos, rd)
			_free_rids(upsample_ubos, rd)
			return {}
		analytic_ubos.append(analytic_ubo)
		var atmosphere_ubo := rd.uniform_buffer_create(ATMOSPHERE_BYTES)
		if not atmosphere_ubo.is_valid():
			_free_rids(allocated, rd)
			_free_rids(ubos, rd)
			_free_rids(analytic_ubos, rd)
			_free_rids(atmosphere_ubos, rd)
			_free_rids(cloud_visibility_ubos, rd)
			_free_rids(upsample_ubos, rd)
			return {}
		atmosphere_ubos.append(atmosphere_ubo)
		var cloud_visibility_ubo := rd.uniform_buffer_create(CLOUD_VISIBILITY_BYTES)
		if not cloud_visibility_ubo.is_valid():
			_free_rids(allocated, rd)
			_free_rids(ubos, rd)
			_free_rids(analytic_ubos, rd)
			_free_rids(atmosphere_ubos, rd)
			_free_rids(cloud_visibility_ubos, rd)
			_free_rids(upsample_ubos, rd)
			return {}
		cloud_visibility_ubos.append(cloud_visibility_ubo)
		var upsample_ubo := rd.uniform_buffer_create(16)
		if not upsample_ubo.is_valid():
			_free_rids(allocated, rd)
			_free_rids(ubos, rd)
			_free_rids(analytic_ubos, rd)
			_free_rids(atmosphere_ubos, rd)
			_free_rids(cloud_visibility_ubos, rd)
			_free_rids(upsample_ubos, rd)
			return {}
		upsample_ubos.append(upsample_ubo)
	state = {
		"weak_buffers": weakref(buffers), "size": size, "view_count": view_count,
		"mip_count": mip_count, "textures": textures, "mip_views": mip_views,
		"depth_histories": depth_histories,
		"downsample_textures": downsample_textures,
		"downsample_mip_views": downsample_mip_views,
		"blur_textures": blur_textures, "blur_mip_views": blur_mip_views,
		"frame_ubos": ubos, "analytic_ubos": analytic_ubos,
		"atmosphere_ubos": atmosphere_ubos,
		"cloud_visibility_ubos": cloud_visibility_ubos,
		"upsample_ubos": upsample_ubos,
		"history_index": 0, "history_valid": false,
		"previous_exposures": PackedFloat32Array(), "last_frame_generation": -1,
		"camera_generation": -1, "environment_id": -1, "render_target_id": -1,
		"signature": "", "eye_offsets": [], "projection_unjittered": Projection.IDENTITY,
	}
	state.previous_exposures.resize(view_count)
	for view in view_count:
		state.previous_exposures[view] = 1.0
	_states[key] = state
	return state


func _create_mip_chain(rd: RenderingDevice, size: Vector2i, mip_count: int,
		allocated: Array[RID]) -> Dictionary:
	var base := _create_mip_texture(rd, size, mip_count)
	if not base.is_valid():
		return {}
	allocated.append(base)
	var views: Array[RID] = []
	for mip in mip_count:
		var view := rd.texture_create_shared_from_slice(RDTextureView.new(), base, 0, mip)
		if not view.is_valid():
			return {}
		allocated.append(view)
		views.append(view)
	return {"texture": base, "views": views}


func _create_mip_texture(rd: RenderingDevice, size: Vector2i, mip_count: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = size.x
	format.height = size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = mip_count
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return rd.texture_create(format, RDTextureView.new(), [])


func _create_depth_texture(rd: RenderingDevice, size: Vector2i) -> RID:
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


func _history_valid(state: Dictionary, frames: Array[Dictionary], size: Vector2i,
		signature: String) -> bool:
	var first: Dictionary = frames[0]
	if not bool(state.history_valid) or state.size != size or int(state.view_count) != frames.size() \
			or int(state.camera_generation) != int(first.camera_generation) \
			or int(state.environment_id) != int(first.get("environment_id", 0)) \
			or int(state.render_target_id) != int(first.get("render_target_id", 0)) \
			or int(state.last_frame_generation) + 1 != int(first.frame_generation) \
			or str(state.signature) != signature:
		return false
	if state.camera_origin.distance_to(first.camera_origin) > 50.0:
		return false
	if state.camera_basis.get_rotation_quaternion().angle_to(
			first.camera_transform.basis.get_rotation_quaternion()) > deg_to_rad(60.0):
		return false
	if _projection_changed(state.get("projection_unjittered", first.projection_unjittered),
			first.projection_unjittered):
		return false
	var offsets := _eye_offsets(frames)
	if offsets.size() != state.eye_offsets.size():
		return false
	for index in offsets.size():
		if offsets[index].distance_to(state.eye_offsets[index]) > 0.25:
			return false
	return true


func _ensure_pipelines(rd: RenderingDevice) -> bool:
	for filename in ["fsss_reproject.glslinc", "fsss_downsample.glslinc",
			"fsss_filter.glslinc", "fsss_upsample.glslinc"]:
		if _pipelines.has(filename):
			continue
		var expanded_source: String = ShaderSource.expand(SHADER_ROOT.path_join(filename))
		if expanded_source.is_empty():
			_last_error = "Cannot load or expand FSSS shader %s." % filename
			return false
		var source_fingerprint: String = expanded_source.sha256_text()
		var cached_failure: Variant = _failed_pipeline_sources.get(filename, {})
		if cached_failure is Dictionary \
				and String(cached_failure.get("fingerprint", "")) == source_fingerprint:
			_last_error = String(cached_failure.get("error", "Cached FSSS pipeline failure (%s)." % filename))
			return false
		var pipeline: Dictionary = _compile_pipeline(rd, filename, expanded_source)
		if pipeline.is_empty():
			if _last_error.is_empty():
				_last_error = "FSSS shader %s produced no pipeline." % filename
			_failed_pipeline_sources[filename] = {
				"fingerprint": source_fingerprint,
				"error": _last_error,
			}
			return false
		_failed_pipeline_sources.erase(filename)
		_pipelines[filename] = pipeline
	return true


func _compile_pipeline(rd: RenderingDevice, filename: String, source: String) -> Dictionary:
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = source.replace("#[compute]", "")
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	if spirv == null or not spirv.compile_error_compute.is_empty():
		_last_error = "FSSS shader compile failed (%s): %s" % [filename,
				spirv.compile_error_compute if spirv != null else "no SPIR-V result"]
		return {}
	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		_last_error = "Cannot create FSSS shader RID for %s." % filename
		return {}
	var pipeline := rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		rd.free_rid(shader)
		_last_error = "Cannot create FSSS compute pipeline for %s." % filename
		return {}
	return {"shader": shader, "pipeline": pipeline}


func _ensure_samplers(rd: RenderingDevice) -> bool:
	if not _sampler_nearest.is_valid():
		_sampler_nearest = _create_sampler(rd, false)
	if not _sampler_linear.is_valid():
		_sampler_linear = _create_sampler(rd, true)
	return _sampler_nearest.is_valid() and _sampler_linear.is_valid()


func _ensure_source_textures(rd: RenderingDevice) -> bool:
	if not _empty_volume_texture.is_valid():
		_empty_volume_texture = _create_small_texture(rd,
				RenderingDevice.TEXTURE_TYPE_3D, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				PackedByteArray([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c]))
	if not _empty_fsss_texture.is_valid():
		_empty_fsss_texture = _create_small_texture(rd,
				RenderingDevice.TEXTURE_TYPE_2D, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				PackedByteArray([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
	if not _empty_cloud_radiance.is_valid():
		_empty_cloud_radiance = _create_small_texture(rd,
				RenderingDevice.TEXTURE_TYPE_2D_ARRAY, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				PackedByteArray([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
	if not _empty_cloud_transmittance.is_valid():
		_empty_cloud_transmittance = _create_small_texture(rd,
				RenderingDevice.TEXTURE_TYPE_2D_ARRAY, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				PackedByteArray([0x00, 0x3c, 0x00, 0x3c, 0x00, 0x3c, 0x00, 0x3c]))
	return _empty_volume_texture.is_valid() and _empty_fsss_texture.is_valid() \
			and _empty_cloud_radiance.is_valid() and _empty_cloud_transmittance.is_valid()


func _empty_volume(rd: RenderingDevice) -> RID:
	return _empty_volume_texture if _valid_texture(rd, _empty_volume_texture) else RID()


func _empty_cloud_radiance_texture(rd: RenderingDevice) -> RID:
	return _empty_cloud_radiance if _valid_texture(rd, _empty_cloud_radiance) else RID()


func _empty_cloud_transmittance_texture(rd: RenderingDevice) -> RID:
	return _empty_cloud_transmittance \
			if _valid_texture(rd, _empty_cloud_transmittance) else RID()


func _create_small_texture(rd: RenderingDevice, texture_type: int, format_id: int,
		initial_data: PackedByteArray) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = texture_type
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = format_id
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(format, RDTextureView.new(), [initial_data])


func _create_sampler(rd: RenderingDevice, linear: bool) -> RID:
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR if linear else RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = state.min_filter
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return rd.sampler_create(state)


func _uniform_set(shader: RID, uniforms: Array[RDUniform]) -> RID:
	return UniformSetCacheRD.get_cache(shader, 0, uniforms)


func _dispatch(rd: RenderingDevice, pipeline: RID, uniform_set: RID, size: Vector2i) -> bool:
	if not pipeline.is_valid() or not uniform_set.is_valid() or size.x <= 0 or size.y <= 0:
		return false
	var list := rd.compute_list_begin()
	if list < 0:
		return false
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, ceili(float(size.x) / WORKGROUP), ceili(float(size.y) / WORKGROUP), 1)
	rd.compute_list_end()
	return true


func _update_ubo(rid: RID, values: PackedFloat32Array, rd: RenderingDevice) -> bool:
	var bytes := values.to_byte_array()
	return rid.is_valid() and bytes.size() == FRAME_BYTES and rd.buffer_update(rid, 0, bytes.size(), bytes) == OK


func _update_ubo_bytes(rid: RID, values: PackedFloat32Array, expected_bytes: int,
		rd: RenderingDevice) -> bool:
	var bytes := values.to_byte_array()
	return rid.is_valid() and bytes.size() == expected_bytes \
			and rd.buffer_update(rid, 0, bytes.size(), bytes) == OK


func _valid_texture(rd: RenderingDevice, rid: RID) -> bool:
	return rid.is_valid() and rd.texture_is_valid(rid)


func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in 4:
		var axis: Vector4 = projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))


func _append_transform(values: PackedFloat32Array, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z]:
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	values.append_array(PackedFloat32Array([transform.origin.x, transform.origin.y, transform.origin.z, 1.0]))


func _eye_offsets(frames: Array[Dictionary]) -> Array:
	var result: Array = []
	for frame in frames:
		result.append(frame.get("eye_offset", Vector3.ZERO))
	return result


func _projection_changed(previous: Projection, current: Projection) -> bool:
	for column in 4:
		if (previous[column] - current[column]).length() > 1.0e-4:
			return true
	return false


func _state_rids(state: Dictionary) -> Array[RID]:
	var result: Array[RID] = []
	for key in ["mip_views", "downsample_mip_views", "blur_mip_views",
			"textures", "downsample_textures", "blur_textures",
			"depth_histories", "frame_ubos", "analytic_ubos",
			"atmosphere_ubos", "cloud_visibility_ubos", "upsample_ubos"]:
		_append_rids(result, state.get(key, []))
	return result


func _append_rids(result: Array[RID], value: Variant) -> void:
	if value is RID:
		if value.is_valid():
			result.append(value)
		return
	if value is Array:
		for item in value:
			_append_rids(result, item)


func _free_rids(rids: Array[RID], rd: RenderingDevice) -> void:
	for rid in rids:
		if rid.is_valid():
			rd.free_rid(rid)


func _free_state(state: Dictionary, rd: RenderingDevice) -> void:
	if rd == null:
		return
	for rid in _state_rids(state):
		rd.free_rid(rid)


func _release_state_for(buffers: RenderSceneBuffersRD, rd: RenderingDevice) -> void:
	if buffers == null:
		return
	var key := buffers.get_instance_id()
	if _states.has(key):
		_free_state(_states[key], rd)
		_states.erase(key)


func _prune_states(current: RenderSceneBuffersRD, rd: RenderingDevice) -> void:
	var current_id := current.get_instance_id() if current != null else 0
	for key in _states.keys():
		if key == current_id:
			continue
		var reference: WeakRef = _states[key].get("weak_buffers")
		var buffers: Object = reference.get_ref() if reference != null else null
		if buffers == null or not is_instance_valid(buffers):
			_free_state(_states[key], rd)
			_states.erase(key)


func _positive(value: Variant, fallback: float) -> float:
	return float(value) if (value is int or value is float) and is_finite(float(value)) and float(value) > 0.0 else fallback


func _domain_scale(frame: Dictionary) -> float:
	var exposure := _positive(frame.get("pre_exposure", 1.0), 1.0)
	var normalization := _positive(frame.get("scene_normalization", 1.0), 1.0)
	return clampf(exposure * normalization, 1.0e-8, 1.0e8)


func _volume_geometry_signature(value: Variant) -> PackedFloat32Array:
	if not value is PackedFloat32Array or value.size() < 15:
		return PackedFloat32Array()
	# Slot 15 is storage pre-exposure and is handled by history rescaling.
	return value.slice(0, 15)
