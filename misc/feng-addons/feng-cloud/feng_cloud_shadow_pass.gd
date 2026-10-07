@tool
class_name FengCloudShadowPass
extends FengVolumetricCloudPass
## Builds the optional cloud shadow maps and sky-occlusion texture before
## deferred lighting. The pass is inert when no cloud snapshot is routed.

const FengCloudGPU = preload("feng_cloud_gpu.gd")

var _cloud_gpu = FengCloudGPU.new()
var _active_context: FRPPassContext


func _init() -> void:
	stage = EFFECT_CALLBACK_TYPE_PRE_LIGHTING
	effect_callback_type = stage


func _frp_execute(ctx: FRPPassContext) -> void:
	_active_context = ctx
	super._frp_execute(ctx)
	_active_context = null


## Capture adapters call this during their post-setup/pre-lighting phase so the
## native lighting stage sees the same frozen cloud and shadow settings as the
## later face trace.
func prepare_capture(ctx: FRPPassContext, frozen_snapshot: Dictionary) -> void:
	_capture_snapshot_for_prepare(ctx, frozen_snapshot)
	_frp_prepare(ctx)


## Runs the shadow work for one capture face after its G-buffer is available.
func execute_capture(ctx: FRPPassContext, frozen_snapshot: Dictionary) -> void:
	_active_context = ctx
	_frp_execute_with_snapshot(ctx, frozen_snapshot)
	_active_context = null


func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _active_context == null or _frame_scene_data == null:
		return
	_cloud_gpu.render_shadow(_active_context, _frame_snapshot, _frame_scene_data,
		view, buffers, rd, get_instance_id())


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


func _capture_snapshot_for_prepare(ctx: FRPPassContext, snapshot: Dictionary) -> void:
	_frame_snapshot = snapshot.duplicate(true)
	_frame_scene_data = null
	if ctx != null:
		var render_data := ctx.get_render_data()
		if render_data != null:
			_frame_scene_data = render_data.get_render_scene_data()
