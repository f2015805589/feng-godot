@tool
class_name FengReflectProbeCaptureContextPass
extends "res://addons/feng-render-pipeline/passes/pass_base.gd"
## First entry in a private probe-capture schedule. Its prepare hook publishes only
## value metadata, before Cloud/Fog or other capture-aware passes prepare this view.

const Runtime = preload("../rendering/feng_reflect_probe_runtime.gd")

var _snapshot: Dictionary = {}

func _init() -> void:
	resource_name = "Feng Probe Capture Context"
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_GBUFFER
	inputs = []
	outputs = []
	access_resolved_color = false
	access_resolved_depth = false

func _frp_prepare(ctx: FRPPassContext) -> void:
	_snapshot.clear()
	if ctx == null:
		return
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var target := buffers.get_render_target()
	_snapshot = Runtime.capture_snapshot_for_target(target)
	if _snapshot.is_empty() or not bool(_snapshot.get("active", false)):
		return
	if not ctx.has_method("set_reflection_capture_context"):
		return
	var exposure := 1.0
	if ctx.has_method("get_pre_exposure"):
		exposure *= float(ctx.call("get_pre_exposure", 0))
	if ctx.has_method("get_scene_exposure_normalization"):
		exposure *= float(ctx.call("get_scene_exposure_normalization"))
	var origin: Vector3 = _snapshot.get("origin_world", Vector3.ZERO)
	ctx.call("set_reflection_capture_context", true, int(_snapshot.get("batch_id", 0)),
			int(_snapshot.get("face_index", 0)), 6, origin, exposure)

func _frp_execute(_ctx: FRPPassContext) -> void:
	pass

