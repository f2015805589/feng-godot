@tool
class_name FengSkyLightCaptureEffect
extends CompositorEffect
## A persistent, capture-only adapter for the frozen SkyLight batch inputs.
## The renderer invokes metadata, shadow, Fog, and cloud work at their actual
## FRP stages; this object owns the per-capture snapshots and reusable pass RIDs.

const FOG_EFFECT_PATH := "res://addons/feng-render-pipeline/library/height-fog/height_fog.tres"
const CLOUD_SHADOW_SCRIPT_PATH := "res://addons/feng-cloud/feng_cloud_shadow_pass.gd"
const CLOUD_TRACE_SCRIPT_PATH := "res://addons/feng-cloud/feng_cloud_trace_pass.gd"

var _fog_pass: CompositorEffect
var _cloud_shadow_pass: CompositorEffect
var _cloud_trace_pass: CompositorEffect
var _fog_snapshot: Dictionary = {}
var _atmosphere_snapshot: Dictionary = {}
var _cloud_snapshot: Dictionary = {}


func _init() -> void:
	# The capture target is a typed RGBA16F storage image for the cloud composite,
	# and the cloud trace/shadow stages also sample this face's depth.
	access_resolved_color = true
	access_resolved_depth = true


func set_capture_snapshots(fog_snapshot: Dictionary, atmosphere_snapshot: Dictionary,
		cloud_snapshot: Dictionary) -> void:
	var had_cloud_snapshot := not _cloud_snapshot.is_empty()
	_fog_snapshot = fog_snapshot.duplicate(true)
	_atmosphere_snapshot = atmosphere_snapshot.duplicate(true)
	_cloud_snapshot = cloud_snapshot.duplicate(true)
	if had_cloud_snapshot and _cloud_snapshot.is_empty():
		_release_cloud_passes()
	if not _fog_snapshot.is_empty() or not _atmosphere_snapshot.is_empty():
		_ensure_fog_pass()
	_ensure_cloud_passes()
	if _fog_pass != null and _fog_pass.has_method("set_capture_snapshots"):
		_fog_pass.call("set_capture_snapshots", _fog_snapshot, _atmosphere_snapshot)


func clear_capture_snapshots() -> void:
	_fog_snapshot.clear()
	_atmosphere_snapshot.clear()
	_cloud_snapshot.clear()
	_release_cloud_passes()
	if _fog_pass != null and _fog_pass.has_method("clear_capture_snapshots"):
		_fog_pass.call("clear_capture_snapshots")


## Called once per capture face after FRPPassContext.setup() and before lighting.
## Fog publishes atmospheric direct-light data first; cloud metadata then fills
## the native packet consumed by the one-time lighting preparation.
func _frp_prepare(ctx: FRPPassContext) -> void:
	if _fog_pass != null and _fog_pass.has_method("_frp_prepare"):
		_fog_pass.call("_frp_prepare", ctx)
	if not _cloud_snapshot.is_empty() and _cloud_shadow_pass != null \
			and _cloud_shadow_pass.has_method("prepare_capture"):
		_cloud_shadow_pass.call("prepare_capture", ctx, _cloud_snapshot)
	elif ctx != null and ctx.has_method("clear_cloud_snapshot"):
		ctx.call("clear_cloud_snapshot")


## Capture cloud shadows are generated after this face's geometry has reached
## its pre-lighting point, before native opaque lighting consumes the map.
func _frp_capture_shadow(ctx: FRPPassContext) -> void:
	if _cloud_snapshot.is_empty() or _cloud_shadow_pass == null \
			or not _cloud_shadow_pass.has_method("execute_capture"):
		return
	_cloud_shadow_pass.call("execute_capture", ctx, _cloud_snapshot)


## HeightFog/AP runs after Sky resolve, before the cloud radiance is composed.
func _frp_capture_fog(ctx: FRPPassContext) -> void:
	if _fog_pass != null and _fog_pass.has_method("_frp_execute"):
		_fog_pass.call("_frp_execute", ctx)


## Cloud radiance/transmittance/depth is composed after opaque Fog/AP and before
## transparent geometry, using the same frozen snapshot as the shadow stage.
func _frp_capture_cloud(ctx: FRPPassContext) -> void:
	if _cloud_snapshot.is_empty() or _cloud_trace_pass == null \
			or not _cloud_trace_pass.has_method("execute_capture"):
		return
	_cloud_trace_pass.call("execute_capture", ctx, _cloud_snapshot)


func _ensure_fog_pass() -> void:
	if _fog_pass != null and is_instance_valid(_fog_pass):
		return
	if not ResourceLoader.exists(FOG_EFFECT_PATH):
		return
	var template: Variant = load(FOG_EFFECT_PATH)
	if template is CompositorEffect:
		_fog_pass = template.duplicate(true) as CompositorEffect


func _ensure_cloud_passes() -> void:
	if _cloud_snapshot.is_empty():
		return
	if _cloud_shadow_pass == null:
		_cloud_shadow_pass = _new_script_effect(CLOUD_SHADOW_SCRIPT_PATH)
	if _cloud_trace_pass == null:
		_cloud_trace_pass = _new_script_effect(CLOUD_TRACE_SCRIPT_PATH)


func _release_cloud_passes() -> void:
	# Dropping these owned Resources schedules their existing PREDELETE cleanup
	# on the render thread. Keep them alive across batches while cloud remains.
	_cloud_shadow_pass = null
	_cloud_trace_pass = null


func _new_script_effect(path: String) -> CompositorEffect:
	if not ResourceLoader.exists(path):
		return null
	var script: Variant = load(path)
	if not script is Script:
		return null
	var instance: Variant = script.new()
	if instance is CompositorEffect:
		return instance
	return null
