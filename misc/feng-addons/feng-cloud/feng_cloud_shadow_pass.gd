@tool
class_name FengCloudShadowPass
extends FengVolumetricCloudPass
## Builds the optional cloud shadow maps and sky-occlusion texture before
## deferred lighting. The pass is inert when no cloud snapshot is routed.

func _init() -> void:
	stage = EFFECT_CALLBACK_TYPE_PRE_LIGHTING
	effect_callback_type = stage


func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _active_context == null or _frame_scene_data == null:
		return
	_cloud_gpu.render_shadow(_active_context, _frame_snapshot, _frame_scene_data,
		view, buffers, rd, get_instance_id())
