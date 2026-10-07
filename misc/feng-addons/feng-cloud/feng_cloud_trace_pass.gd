@tool
class_name FengCloudTracePass
extends FengVolumetricCloudPass
## Traces/reconstructs the cloud volume and composites it after opaque fog/AP
## while the resolved eye color is still available in linear HDR.

const FengCloudGPU = preload("feng_cloud_gpu.gd")

@export_enum("Quarter trace + temporal half resolve", "Half trace", "Quarter trace + full temporal resolve", "Full trace") var vrt_mode: int = 0:
	set(value):
		var next_mode := clampi(value, 0, 3)
		if vrt_mode == next_mode:
			return
		vrt_mode = next_mode
		emit_changed()

var _cloud_gpu = FengCloudGPU.new()
var _active_context: FRPPassContext
var _frame_vrt_mode := 0


func _init() -> void:
	stage = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	effect_callback_type = stage
	access_resolved_color = true
	access_resolved_depth = true


func get_frp_parameters() -> Dictionary:
	var result := super.get_frp_parameters()
	result["vrt_mode"] = vrt_mode
	return result


func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["vrt_mode"])


func _frp_execute(ctx: FRPPassContext) -> void:
	_active_context = ctx
	_frame_vrt_mode = _resolved_vrt_mode(ctx)
	super._frp_execute(ctx)
	_active_context = null


## Capture faces always use a full-resolution trace and do not retain temporal
## history between faces or capture batches.
func execute_capture(ctx: FRPPassContext, frozen_snapshot: Dictionary) -> void:
	_active_context = ctx
	_frame_vrt_mode = 3
	_frp_execute_with_snapshot(ctx, frozen_snapshot)
	_active_context = null


func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _active_context == null or _frame_scene_data == null:
		return
	_cloud_gpu.render_clouds(_active_context, _frame_snapshot, _frame_scene_data,
		view, buffers, rd, get_instance_id(), _frame_vrt_mode)


func _resolved_vrt_mode(ctx: FRPPassContext) -> int:
	var parameters := get_resolved_parameters(ctx)
	return clampi(int(parameters.get("vrt_mode", vrt_mode)), 0, 3)


func _cleanup(rd: RenderingDevice) -> void:
	_cloud_gpu.cleanup(rd)
	super._cleanup(rd)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	var pass_rids: Array[RID] = [_shader, _compute_pipeline, _sampler, _ubo]
	for pipeline in _raster_pipelines.values():
		if pipeline is RID:
			pass_rids.append(pipeline)
	var payload := _cloud_gpu.take_cleanup_payload(pass_rids)
	_shader = RID()
	_compute_pipeline = RID()
	_sampler = RID()
	_ubo = RID()
	_raster_pipelines.clear()
	FengCloudGPU.release_cleanup_payload(payload)
