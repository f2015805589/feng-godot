@tool
extends RefCounted
## Optional FRP adapter for Feng Fog's owned GPU services and packet codecs.
## The FRP pass discovers this script by path; the base renderer stays usable
## when the Feng Fog addon is absent.

const Codec = preload("feng_volumetric_fog_codec.gd")
const VolumeGPUService = preload("feng_volumetric_fog_gpu_service.gd")
const VolumeCompositeService = preload("feng_volumetric_fog_composite_service.gd")
const FsssGPUService = preload("feng_fsss_gpu_service.gd")

var _volume := VolumeGPUService.new()
var _composite := VolumeCompositeService.new()
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


func get_last_error() -> String:
	return _composite.get_last_error()


func get_fsss_error() -> String:
	return _fsss.get_last_error()


func get_volume_error() -> String:
	return _volume.get_last_error()


func get_volume_status() -> String:
	return _volume.get_last_status()


func is_volume_inactive() -> bool:
	return _volume.is_volume_inactive()


func take_owned_rids() -> Array[RID]:
	var result: Array[RID] = []
	result.append_array(_volume.take_owned_rids())
	result.append_array(_composite.take_owned_rids())
	result.append_array(_fsss.take_owned_rids())
	return result
