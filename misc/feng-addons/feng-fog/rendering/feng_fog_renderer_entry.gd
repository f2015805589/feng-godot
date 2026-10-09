@tool
extends RefCounted
## Optional FRP adapter for Feng Fog's owned GPU services and packet codecs.
## The FRP pass discovers this script by path; the base renderer stays usable
## when the Feng Fog addon is absent.

const Codec = preload("feng_volumetric_fog_codec.gd")
const VolumeGPUService = preload("feng_volumetric_fog_gpu_service.gd")
const VolumeCompositeService = preload("feng_volumetric_fog_composite_service.gd")
const AnalyticHeightFogFallbackService = preload("feng_analytic_height_fog_fallback_service.gd")
const FsssGPUService = preload("feng_fsss_gpu_service.gd")
const OwnedRids = preload("res://addons/feng-render-pipeline/rd/owned_rids.gd")

var _volume := VolumeGPUService.new()
var _composite := VolumeCompositeService.new()
var _analytic_fallback := AnalyticHeightFogFallbackService.new()
var _fsss := FsssGPUService.new()


func normalize_screen_space_scattering(value: Variant) -> Dictionary:
	return Codec.normalize_screen_space_scattering(value)


func normalize_frame_inputs(value: Variant, view: int) -> Dictionary:
	return Codec.normalize_frame_inputs(value, view)


func make_sampling_packet(grid: Vector3i, view_count: int, start_distance: float,
		far_distance: float, near_plane: float, pre_exposure: float) -> PackedFloat32Array:
	return Codec.make_sampling_packet(grid, view_count, start_distance, far_distance,
			near_plane, pre_exposure)


func render_volume(ctx: FRPPassContext, snapshot: Dictionary,
		buffers: RenderSceneBuffersRD, rd: RenderingDevice,
		frames: Array[Dictionary]) -> Dictionary:
	return _volume.render_volume(ctx, snapshot, buffers, rd, frames)


func clear_volume(ctx: FRPPassContext, buffers: RenderSceneBuffersRD,
		rd: RenderingDevice) -> void:
	_volume.clear(ctx, buffers, rd)


func render_fsss(ctx: FRPPassContext, snapshot: Dictionary,
		buffers: RenderSceneBuffersRD, rd: RenderingDevice,
		color_layers: Array[RID], depth_layers: Array[RID],
		frames: Array[Dictionary], source_options: Dictionary = {}) -> Dictionary:
	return _fsss.render(ctx, snapshot, buffers, rd, color_layers, depth_layers,
			frames, source_options)


func composite_volume_and_fsss(rd: RenderingDevice,
		color_layers: Array[RID], depth_layers: Array[RID], volume_texture: RID,
		fsss_textures: Array, sampling_ubos: Array[RID], frames: Array[Dictionary],
		fog_parameters_by_view: Array[PackedFloat32Array], size: Vector2i,
		cloud_composition: Dictionary) -> bool:
	return _composite.composite_volume_and_fsss(rd, color_layers, depth_layers,
			volume_texture, fsss_textures, sampling_ubos, frames,
			fog_parameters_by_view, size, cloud_composition)


func composite_analytic_near_fallback(rd: RenderingDevice,
		color_layers: Array[RID], depth_layers: Array[RID], frames: Array[Dictionary],
		fog_parameters_by_view: Array[PackedFloat32Array], size: Vector2i,
		pre_exposure: float) -> bool:
	return _analytic_fallback.composite_analytic_near(rd, color_layers,
			depth_layers, frames, fog_parameters_by_view, size, pre_exposure)


func get_last_error() -> String:
	return _composite.get_last_error()


func get_analytic_fallback_error() -> String:
	return _analytic_fallback.get_last_error()


func get_fsss_error() -> String:
	return _fsss.get_last_error()


func get_volume_error() -> String:
	return _volume.get_last_error()


func get_volume_status() -> String:
	return _volume.get_last_status()


func is_volume_inactive() -> bool:
	return _volume.is_volume_inactive()


func get_owned_rids() -> Array[RID]:
	return _collect_owned_rids(false)


func take_owned_rids() -> Array[RID]:
	return _collect_owned_rids(true)


func _collect_owned_rids(p_clear: bool) -> Array[RID]:
	var result: Array[RID] = []
	var seen: Dictionary = {}
	var child_rids: Array[RID] = _volume.take_owned_rids() if p_clear \
			else _volume.get_owned_rids()
	OwnedRids.append_all(result, seen, child_rids)
	child_rids = _composite.take_owned_rids() if p_clear else _composite.get_owned_rids()
	OwnedRids.append_all(result, seen, child_rids)
	child_rids = _analytic_fallback.take_owned_rids() if p_clear \
			else _analytic_fallback.get_owned_rids()
	OwnedRids.append_all(result, seen, child_rids)
	child_rids = _fsss.take_owned_rids() if p_clear else _fsss.get_owned_rids()
	OwnedRids.append_all(result, seen, child_rids)
	return result
