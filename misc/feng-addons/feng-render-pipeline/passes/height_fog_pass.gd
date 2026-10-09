@tool
class_name FengHeightFogPass
extends FengRuntimeSnapshotPass
## Applies independently published height fog and spherical aerial perspective.
## Both providers are optional, world-scoped snapshots. Metadata preparation
## supplies direct-light transport before Lighting; the existing Sky-anchored
## dispatch applies aerial perspective and height fog to opaque scene color.
## With neither provider, the pass is a no-op. Authoring/lifecycles stay outside it.

const UBO_BINDING := 2
const UBO_SIZE := 496 # Two mat4s + seven fog vec4s + sixteen atmosphere vec4s.
const CLOUD_VISIBILITY_UBO_SIZE := 592 # 35 projection vec4s + sun mapping + validity flags.
const AtmospherePacket = preload("atmosphere_packet.gd")
const FOG_RENDERER_ENTRY_PATH := "res://addons/feng-fog/rendering/feng_fog_renderer_entry.gd"
const OP_LIGHTING_PREPARE := FRPPassContext.OP_LIGHTING_PREPARE
const OP_SCREEN_AND_DEPTH_COPY := FRPPassContext.OP_SCREEN_AND_DEPTH_COPY
const OP_PRE_LIGHTING_STAGE_NAME := &"OP_PRE_LIGHTING_STAGE"
const OP_GBUFFER_NAME := &"OP_GBUFFER"
const SKY_RUNTIME_PATH := "res://addons/feng-sky/feng_sky_runtime.gd"
const RUNTIME_SCRIPT_PATH := "res://addons/feng-fog/feng_fog_runtime.gd"
const VOLUME_SAMPLING_UBO_BYTES := 128
const OP_PRE_LIGHTING_STAGE := FRPPassContext.OP_PRE_LIGHTING_STAGE
var _pre_exposure := 1.0
var _sky_runtime: Script
var _next_sky_runtime_probe_msec := 0
var _atmosphere_snapshot: Dictionary = {}
var _prepared_context_id := 0
var _atmosphere_optical := RID()
var _atmosphere_multiple := RID()
var _empty_atmosphere_lut := RID()
var _atmosphere_sampler := RID()
var _capture_snapshot_active := false
var _capture_fog_snapshot: Dictionary = {}
var _capture_atmosphere_snapshot: Dictionary = {}
var _capture_exposure_normalization := 1.0
var _cloud_visibility_parameters := PackedFloat32Array()
var _cloud_shadow0 := RID()
var _cloud_shadow1 := RID()
var _cloud_raw_ao := RID()
var _cloud_visibility_ubo := RID()
var _fog_renderer: RefCounted
var _volume_result: Dictionary = {}
var _fsss_result: Dictionary = {}
var _late_fsss_snapshot: Dictionary = {}
var _late_analytic_snapshot: Dictionary = {}
var _late_fog_scale := 1.0
var _frame_inputs: Array[Dictionary] = []
var _volume_sampling_ubos: Array[RID] = []
var _empty_volume_texture := RID()
var _empty_fsss_texture := RID()
var _volume_composite_deferred := false
var _fsss_composite_deferred := false
var _lighting_callback_queued := false
var _volume_depth_ready_generation := -1
var _volume_cloud_ready_generation := -1
var _prepared_snapshot: Dictionary = {}
var _volume_result_frame_generation := -1
var _last_volume_failure_signature := ""


func _ensure_fog_renderer() -> bool:
	if _fog_renderer != null:
		return true
	if not ResourceLoader.exists(FOG_RENDERER_ENTRY_PATH):
		return false
	var script: Variant = load(FOG_RENDERER_ENTRY_PATH)
	if not script is Script:
		return false
	var instance: Variant = script.new()
	if not instance is RefCounted:
		return false
	_fog_renderer = instance
	return true


func _frp_operation_value(operation_name: StringName) -> int:
	if not ClassDB.class_has_integer_constant(&"FRPPassContext", operation_name):
		return -1
	return int(ClassDB.class_get_integer_constant(&"FRPPassContext", operation_name))

## The capture-only effect is a private duplicate of this resource. These value
## snapshots and their texture references stay frozen for the six-face capture.
func set_capture_snapshots(fog_snapshot: Dictionary, atmosphere_snapshot: Dictionary) -> void:
	_capture_fog_snapshot = fog_snapshot.duplicate(true)
	_capture_atmosphere_snapshot = atmosphere_snapshot.duplicate(true)
	_capture_snapshot_active = true

func clear_capture_snapshots() -> void:
	_capture_snapshot_active = false
	_capture_fog_snapshot = {}
	_capture_atmosphere_snapshot = {}

func _atmosphere_for_target(buffers: RenderSceneBuffersRD) -> Dictionary:
	if buffers == null:
		return {}
	if _sky_runtime == null:
		var now := Time.get_ticks_msec()
		if now < _next_sky_runtime_probe_msec:
			return {}
		_next_sky_runtime_probe_msec = now + 500
		if ResourceLoader.exists(SKY_RUNTIME_PATH):
			var script: Variant = load(SKY_RUNTIME_PATH)
			if script is Script and script.has_method("rendering_snapshots"):
				_sky_runtime = script
	if _sky_runtime == null:
		return {}
	var snapshots: Variant = _sky_runtime.call("rendering_snapshots")
	if snapshots is Array:
		for snapshot in snapshots:
			if snapshot is Dictionary and snapshot.get("render_targets", []).has(buffers.get_render_target()):
				return snapshot
	return {}

func _prepare_atmosphere(ctx: FRPPassContext) -> PackedFloat32Array:
	_atmosphere_snapshot = {}
	_atmosphere_optical = RID()
	_atmosphere_multiple = RID()
	if ctx == null:
		return PackedFloat32Array()
	_atmosphere_snapshot = _capture_atmosphere_snapshot if _capture_snapshot_active \
			else _atmosphere_for_target(ctx.get_render_scene_buffers() as RenderSceneBuffersRD)
	var render_data := ctx.get_render_data()
	var scene_data: RenderSceneData = render_data.get_render_scene_data() if render_data != null else null
	if _atmosphere_snapshot.is_empty() or scene_data == null:
		return PackedFloat32Array()
	var optical: Variant = _atmosphere_snapshot.get("optical_column_lut")
	var multiple: Variant = _atmosphere_snapshot.get("multi_scattering_lut")
	var settings: Dictionary = _atmosphere_snapshot.get("settings", {})
	var lut_safe := float(settings.get("atmosphere_height_km", 60.0)) / maxf(minf(float(settings.get("rayleigh_scale_height_km", 8.0)), float(settings.get("mie_scale_height_km", 1.2))), 0.001) <= 64.0
	if optical is Texture2D and lut_safe and bool(_atmosphere_snapshot.get("use_optical_column_lut", true)):
		_atmosphere_optical = RenderingServer.texture_get_rd_texture(optical.get_rid())
	if multiple is Texture2D:
		_atmosphere_multiple = RenderingServer.texture_get_rd_texture(multiple.get_rid())
	return AtmospherePacket.make(_atmosphere_snapshot, scene_data.get_cam_transform(), _atmosphere_optical.is_valid(), _atmosphere_multiple.is_valid())

func _capture_cloud_visibility(ctx: FRPPassContext) -> void:
	_clear_cloud_visibility()
	if ctx == null:
		return
	var parameters: PackedFloat32Array = ctx.get_cloud_atmosphere_parameters()
	if parameters.size() != 148:
		return
	_cloud_visibility_parameters = parameters
	if parameters[142] > 0.5:
		_cloud_shadow0 = ctx.get_cloud_output(3)
	if parameters[143] > 0.5:
		_cloud_shadow1 = ctx.get_cloud_output(4)
	if parameters[144] > 0.5:
		_cloud_raw_ao = ctx.get_cloud_output(7)

func _clear_cloud_visibility() -> void:
	_cloud_visibility_parameters = PackedFloat32Array()
	_cloud_shadow0 = RID()
	_cloud_shadow1 = RID()
	_cloud_raw_ao = RID()

## Metadata only: publish before deferred lighting, while the actual compute
## work retains the existing Sky-anchored pass position.
func _frp_prepare(ctx: FRPPassContext) -> void:
	_prepared_context_id = ctx.get_instance_id() if ctx != null else 0
	_prepared_snapshot = {}
	_lighting_callback_queued = false
	_volume_depth_ready_generation = -1
	_volume_cloud_ready_generation = -1
	_volume_result.clear()
	_volume_result_frame_generation = -1
	_volume_composite_deferred = false
	var packet := _prepare_atmosphere(ctx)
	if ctx != null:
		ctx.set_atmosphere_parameters(packet,
			_atmosphere_snapshot.get("sun_light_rid", RID()),
			_atmosphere_snapshot.get("secondary_sun_light_rid", RID()),
			_atmosphere_optical, _atmosphere_multiple)
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD if ctx != null else null
	var snapshot := _capture_fog_snapshot if _capture_snapshot_active \
			else _snapshot_for_target(buffers)
	_prepared_snapshot = snapshot
	if _advanced_fog_requested(snapshot):
		_ensure_fog_renderer()
	var volume_service_cleared := false
	if not _volume_requested(snapshot) and _fog_renderer != null and buffers != null:
		var volume_clear_rd: RenderingDevice = RenderingServer.get_rendering_device()
		if volume_clear_rd != null and _fog_renderer.has_method("clear_volume"):
			_fog_renderer.call("clear_volume", ctx, buffers, volume_clear_rd)
			volume_service_cleared = true
	if not volume_service_cleared and ctx != null and ctx.has_method("clear_volume_output"):
		ctx.call("clear_volume_output")
	if ctx != null:
		ctx.set_meta(&"frp_fsss_deferred_composition", false)
		ctx.set_meta(&"frp_cloud_fog_composition", {})
	if ctx != null and ctx.has_method("set_volume_deferred_composition"):
		ctx.call("set_volume_deferred_composition", false)
	var pre_lighting_operation := _frp_operation_value(OP_PRE_LIGHTING_STAGE_NAME)
	if _volume_requested(snapshot) and _fog_renderer != null \
			and ctx != null and ctx.has_method("enqueue_after_operation"):
		if pre_lighting_operation >= 0:
			_lighting_callback_queued = bool(ctx.call("enqueue_after_operation", pre_lighting_operation,
					Callable(self, "_on_pre_lighting_stage")))
		if not _lighting_callback_queued:
			# A custom plan may prepare light buffers without running the compositor
			# PRE_LIGHTING operation. This fallback intentionally has no current
			# cloud shadow/AO inputs; stale cloud maps are never sampled.
			_lighting_callback_queued = bool(ctx.call("enqueue_after_operation", OP_LIGHTING_PREPARE,
					Callable(self, "_on_lighting_prepare_fallback")))
	elif _fsss_requested(snapshot):
		_prepare_late_composite(ctx, snapshot)


func _on_pre_lighting_stage(ctx: FRPPassContext) -> void:
	_render_volume_after_lighting(ctx, true)


func _on_lighting_prepare_fallback(ctx: FRPPassContext) -> void:
	_render_volume_after_lighting(ctx, false)


func _render_volume_after_lighting(ctx: FRPPassContext, cloud_inputs_ready: bool) -> void:
	if ctx == null or ctx.get_instance_id() != _prepared_context_id:
		return
	if cloud_inputs_ready:
		_capture_cloud_visibility(ctx)
	else:
		_clear_cloud_visibility()
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	var frames := _read_volume_frame_inputs(ctx, buffers,
			int(_prepared_snapshot.get("world_id", 0)))
	if _fog_renderer == null or buffers == null or frames.is_empty():
		if not frames.is_empty() or not _volume_requested(_prepared_snapshot):
			return
		_report_volume_failure(_prepared_snapshot,
				"native frame inputs were unavailable after lighting preparation")
		return
	_frame_inputs = frames
	_volume_cloud_ready_generation = int(frames[0].frame_generation) \
			if cloud_inputs_ready and not frames.is_empty() else -1
	var gbuffer_operation := _frp_operation_value(OP_GBUFFER_NAME)
	var gbuffer_completed := gbuffer_operation >= 0 \
			and ctx.has_method("is_operation_completed") \
			and bool(ctx.call("is_operation_completed", gbuffer_operation))
	var frames_have_current_depth_prepass := true
	for frame in _frame_inputs:
		frames_have_current_depth_prepass = frames_have_current_depth_prepass \
				and bool(frame.get("depth_prepass_enabled", false))
	var depth_available_for_frame := cloud_inputs_ready and gbuffer_completed \
			and frames_have_current_depth_prepass
	for frame in _frame_inputs:
		frame["depth_constraint_available"] = depth_available_for_frame
	_volume_depth_ready_generation = int(frames[0].frame_generation) \
			if depth_available_for_frame and not frames.is_empty() else -1
	var render_snapshot: Dictionary = _prepared_snapshot.duplicate(false)
	render_snapshot["volume_cloud_maps_current"] = cloud_inputs_ready
	_volume_result = _fog_renderer.call("render_volume", ctx, render_snapshot, buffers,
			RenderingServer.get_rendering_device(), frames)
	if _volume_result.is_empty():
		_report_volume_failure(_prepared_snapshot)
	else:
		_last_volume_failure_signature = ""
	_volume_result_frame_generation = int(frames[0].frame_generation) \
			if not _volume_result.is_empty() else -1
	_prepare_late_composite(ctx, _prepared_snapshot)
	_frame_inputs.clear()


func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	# Reuse the pre-lighting lease; captures supply a frozen snapshot per face.
	if _capture_snapshot_active or _prepared_context_id != ctx.get_instance_id():
		_frp_prepare(ctx)
	var snapshot := _capture_fog_snapshot if _capture_snapshot_active \
			else _snapshot_for_target(ctx.get_render_scene_buffers() as RenderSceneBuffersRD)
	var render_data := ctx.get_render_data()
	var scene_data: RenderSceneData = render_data.get_render_scene_data() if render_data != null else null
	var frame_parameters := PackedFloat32Array()
	if not snapshot.is_empty() and scene_data != null:
		var resolved: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
		var fog_scale := float(resolved.x) if resolved is Vector4 else 1.0
		frame_parameters = _make_forward_parameters(snapshot, scene_data.get_cam_transform(),
			fog_scale, scene_data.get_view_projection(0))
	ctx.set_height_fog_parameters(frame_parameters)
	_capture_cloud_visibility(ctx)
	_pre_exposure = ctx.get_pre_exposure(0)
	_capture_exposure_normalization = ctx.get_scene_exposure_normalization() if _capture_snapshot_active else 1.0
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	if _advanced_fog_requested(snapshot):
		_frame_inputs = _read_volume_frame_inputs(ctx, buffers,
				int(snapshot.get("world_id", 0)))
	else:
		_frame_inputs.clear()
	var current_frame_generation := int(_frame_inputs[0].frame_generation) \
			if not _frame_inputs.is_empty() else -1
	var current_depth_available := current_frame_generation >= 0 \
			and _volume_depth_ready_generation == current_frame_generation
	for frame in _frame_inputs:
		frame["depth_constraint_available"] = current_depth_available
	if _volume_requested(snapshot) and current_frame_generation >= 0 \
			and _volume_result_frame_generation != current_frame_generation:
		if _fog_renderer == null:
			_ensure_fog_renderer()
		if _fog_renderer != null:
			var render_snapshot: Dictionary = snapshot.duplicate(false)
			render_snapshot["volume_cloud_maps_current"] = \
					_volume_cloud_ready_generation == current_frame_generation
			_volume_result = _fog_renderer.call("render_volume", ctx, render_snapshot, buffers,
					RenderingServer.get_rendering_device(), _frame_inputs)
			if _volume_result.is_empty():
				_report_volume_failure(snapshot)
			else:
				_last_volume_failure_signature = ""
			_volume_result_frame_generation = current_frame_generation \
				if not _volume_result.is_empty() else -1
		if not _volume_result.is_empty():
			_prepare_late_composite(ctx, snapshot)
	if _fsss_composite_deferred:
		_fsss_result = {}
	else:
		_fsss_result = _render_fsss_inline(ctx, snapshot, buffers,
				RenderingServer.get_rendering_device(), _frame_inputs)
	super._frp_execute_with_snapshot(ctx, snapshot)
	_frame_inputs.clear()
	if not _volume_composite_deferred and not _fsss_composite_deferred:
		_clear_late_composite_state()
	_clear_cloud_visibility()
	_pre_exposure = 1.0
	_capture_exposure_normalization = 1.0


func _prepare_late_composite(ctx: FRPPassContext, snapshot: Dictionary) -> void:
	_volume_composite_deferred = false
	_fsss_composite_deferred = false
	_volume_cloud_ready_generation = -1
	_late_fsss_snapshot.clear()
	if ctx == null:
		return
	var output_texture: RID = _volume_result.get("texture", RID())
	var output_valid := output_texture.is_valid()
	var fsss: Dictionary = _fog_renderer.call("normalize_screen_space_scattering",
			snapshot.get("screen_space_scattering", {})) \
			if _fog_renderer != null else {}
	var callback_queued := false
	if (output_valid or not fsss.is_empty()) and ctx.has_method("enqueue_after_operation"):
		callback_queued = bool(ctx.call("enqueue_after_operation", OP_SCREEN_AND_DEPTH_COPY,
				Callable(self, "_on_after_screen_depth_copy")))
	_volume_composite_deferred = output_valid and callback_queued
	_fsss_composite_deferred = not fsss.is_empty() and callback_queued
	if callback_queued:
		_late_fsss_snapshot = {"screen_space_scattering": fsss}
		var resolved: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
		_late_fog_scale = float(resolved.x) if resolved is Vector4 else 1.0
		_late_analytic_snapshot = _late_analytic_fields(snapshot)
	if ctx.has_method("set_volume_deferred_composition"):
		ctx.call("set_volume_deferred_composition", _volume_composite_deferred)
	ctx.set_meta(&"frp_fsss_deferred_composition", _fsss_composite_deferred)


func _late_analytic_fields(snapshot: Dictionary) -> Dictionary:
	var result := {}
	for key in ["fog_density", "fog_height_falloff", "fog_height",
			"second_fog_density", "second_fog_height_falloff", "second_fog_height",
			"fog_color", "sun_direction", "inscattering_color", "start_distance",
			"cutoff_distance", "min_opacity", "inscattering_start", "inscattering_exponent",
			"volumetric_fog"]:
		if snapshot.has(key):
			result[key] = snapshot[key]
	return result


func _render_fsss_inline(ctx: FRPPassContext, snapshot: Dictionary,
		buffers: RenderSceneBuffersRD, rd: RenderingDevice,
		frames: Array[Dictionary]) -> Dictionary:
	if buffers == null or rd == null or frames.is_empty():
		return {}
	var color_textures: Array[RID] = []
	var depth_textures: Array[RID] = []
	for view in buffers.get_view_count():
		color_textures.append(inputs[0].get_texture(buffers, view) if inputs.size() > 0 else RID())
		depth_textures.append(inputs[1].get_texture(buffers, view) if inputs.size() > 1 else RID())
	if _fog_renderer == null and not _ensure_fog_renderer():
		return {}
	var fsss_settings: Dictionary = _fog_renderer.call("normalize_screen_space_scattering",
			snapshot.get("screen_space_scattering", {}))
	if fsss_settings.is_empty():
		return {}
	var resolved: Variant = get_resolved_parameters(ctx).get("parameters", parameters)
	var fog_scale := float(resolved.x) if resolved is Vector4 else 1.0
	var fog_parameters_by_view: Array[PackedFloat32Array] = []
	var atmosphere_parameters_by_view: Array[PackedFloat32Array] = []
	for view in frames.size():
		fog_parameters_by_view.append(_make_forward_parameters(snapshot,
				frames[view].camera_transform, fog_scale, frames[view].projection))
		atmosphere_parameters_by_view.append(AtmospherePacket.make(_atmosphere_snapshot,
				frames[view].camera_transform, _atmosphere_optical.is_valid(),
				_atmosphere_multiple.is_valid()))
		if not _update_volume_sampling_ubo(view, rd):
			return {}
	var source_options := {
		"source_mode": 0,
		"fog_parameters_by_view": fog_parameters_by_view,
		"atmosphere_parameters_by_view": atmosphere_parameters_by_view,
		"atmosphere_optical_texture": _atmosphere_optical,
		"atmosphere_multiple_texture": _atmosphere_multiple,
		"cloud_visibility_parameters": _cloud_visibility_parameters,
		"cloud_shadow0_texture": _cloud_shadow0,
		"cloud_shadow1_texture": _cloud_shadow1,
		"cloud_raw_ao_texture": _cloud_raw_ao,
		"sampling_ubos": _volume_sampling_ubos,
		"volume_texture": _volume_result.get("texture", RID()),
		"volume_sample_parameters": _volume_result.get("sample_parameters", PackedFloat32Array()),
		"cloud_composition": {},
		"history_signature": _fsss_history_signature(snapshot, fog_scale),
		"volume_source_signature": str(_volume_result.get("source_signature", "")),
	}
	var result: Dictionary = _fog_renderer.call("render_fsss", ctx, snapshot, buffers, rd,
			color_textures, depth_textures, frames, source_options)
	if result.is_empty():
		_report_fsss_failure()
	return result


func _on_after_screen_depth_copy(ctx: FRPPassContext) -> void:
	if ctx == null or (not _volume_composite_deferred and not _fsss_composite_deferred):
		_clear_late_composite_state()
		return
	if _volume_composite_deferred and not _volume_result.get("texture", RID()).is_valid():
		_clear_late_composite_state()
		return
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	var rd := RenderingServer.get_rendering_device()
	var frames := _read_volume_frame_inputs(ctx, buffers,
			int(_late_analytic_snapshot.get("world_id", 0)))
	if _fog_renderer == null or buffers == null or rd == null or frames.is_empty():
		_report("Late volumetric fog composition could not read the current frame inputs.")
		_clear_late_composite_state()
		return
	if _volume_composite_deferred \
			and int(frames[0].frame_generation) != _volume_result_frame_generation:
		_report("Late volumetric fog callback belongs to an older frame.")
		_clear_late_composite_state()
		return
	var color_layers: Array[RID] = []
	var depth_layers: Array[RID] = []
	for view in buffers.get_view_count():
		color_layers.append(buffers.get_color_layer(view))
		depth_layers.append(buffers.get_depth_layer(view))
	_frame_inputs = frames
	_pre_exposure = float(frames[0].pre_exposure)
	var fsss_snapshot: Dictionary = _late_fsss_snapshot
	var fog_parameters_by_view: Array[PackedFloat32Array] = []
	var cloud_composition := _validated_cloud_composition(ctx, frames, buffers, rd)
	var fsss_settings: Dictionary = _fog_renderer.call("normalize_screen_space_scattering",
			fsss_snapshot.get("screen_space_scattering", {}))
	for view in buffers.get_view_count():
		fog_parameters_by_view.append(_make_forward_parameters(_late_analytic_snapshot,
				frames[view].camera_transform, _late_fog_scale, frames[view].projection))
		if not _update_volume_sampling_ubo(view, rd, true):
			_report("Cannot prepare volumetric fog sampling parameters for late composition.")
			_clear_late_composite_state()
			return
	if not fsss_settings.is_empty():
		var source_options := {
			"source_mode": 2 if not cloud_composition.is_empty() else 1,
			"fog_parameters_by_view": fog_parameters_by_view,
			"sampling_ubos": _volume_sampling_ubos,
			"volume_texture": _volume_result.get("texture", RID()),
			"volume_sample_parameters": _volume_result.get("sample_parameters", PackedFloat32Array()),
			"cloud_composition": cloud_composition,
			"history_signature": _fsss_history_signature(_late_analytic_snapshot, _late_fog_scale),
			"volume_source_signature": str(_volume_result.get("source_signature", "")),
		}
		_fsss_result = _fog_renderer.call("render_fsss", ctx, fsss_snapshot, buffers, rd,
				color_layers, depth_layers, frames, source_options)
	else:
		_fsss_result = {}
	if not fsss_settings.is_empty() and _fsss_result.is_empty():
		_report_fsss_failure()
	for view in buffers.get_view_count():
		if not _update_volume_sampling_ubo(view, rd, true):
			_report("Cannot enable FSSS sampling for late volumetric composition.")
			_clear_late_composite_state()
			return
	var fsss_textures: Array = _fsss_result.get("textures_by_view", [])
	var volume_texture: RID = _volume_result.get("texture", RID())
	if not volume_texture.is_valid():
		volume_texture = _empty_volume_texture
	if not bool(_fog_renderer.call("composite_volume_and_fsss", rd, color_layers,
			depth_layers, volume_texture, fsss_textures,
			_volume_sampling_ubos, frames, fog_parameters_by_view, buffers.get_internal_size(),
			cloud_composition)):
		var reason := str(_fog_renderer.call("get_last_error"))
		_report("Late volumetric fog composition failed%s." % \
				(": " + reason if not reason.is_empty() else ""))
	_clear_late_composite_state()


func _fsss_history_signature(snapshot: Dictionary, fog_scale: float) -> Dictionary:
	var signature := {"fog_scale": fog_scale}
	for key in ["fog_density", "fog_height_falloff", "fog_height",
			"second_fog_density", "second_fog_height_falloff", "second_fog_height",
			"fog_color", "sun_direction", "inscattering_color", "start_distance",
			"cutoff_distance", "min_opacity", "inscattering_start", "inscattering_exponent",
			"fog_id", "world_id"]:
		if snapshot.has(key):
			signature[key] = snapshot[key]
	return signature


func _report_fsss_failure() -> void:
	var reason := ""
	if _fog_renderer != null and _fog_renderer.has_method("get_fsss_error"):
		reason = str(_fog_renderer.call("get_fsss_error"))
	if reason.is_empty():
		reason = "GPU service returned no FSSS output or failure detail"
	# PassBase deduplicates repeated identical errors; the FSSS service also
	# caches failed shader source fingerprints so a bad shader is not recompiled.
	_report("FSSS output unavailable: %s." % reason)


static func cloud_composition_metadata_matches_current_frame(ctx: Object, value: Variant,
		frame_generation: int, buffer_id: int, view_count: int,
		internal_size: Vector2i) -> bool:
	if ctx == null or not value is Dictionary:
		return false
	if typeof(value.get("frame_generation")) != TYPE_INT \
			or typeof(value.get("buffer_id")) != TYPE_INT \
			or typeof(value.get("view_count")) != TYPE_INT \
			or typeof(value.get("internal_size")) != TYPE_VECTOR2I \
			or typeof(value.get("native_snapshot_source_signature")) != TYPE_INT:
		return false
	if int(value.frame_generation) != frame_generation \
			or int(value.buffer_id) != buffer_id \
			or int(value.view_count) != view_count \
			or value.internal_size != internal_size:
		return false
	if not ctx.has_method("has_cloud_snapshot") \
			or not ctx.has_method("get_cloud_snapshot_source_signature"):
		return false
	var has_snapshot: Variant = ctx.call("has_cloud_snapshot")
	if typeof(has_snapshot) != TYPE_BOOL or not bool(has_snapshot):
		return false
	var native_signature: Variant = ctx.call("get_cloud_snapshot_source_signature")
	return typeof(native_signature) == TYPE_INT \
			and int(value.native_snapshot_source_signature) == int(native_signature)


func _validated_cloud_composition(ctx: FRPPassContext, frames: Array[Dictionary],
		buffers: RenderSceneBuffersRD, rd: RenderingDevice) -> Dictionary:
	if ctx == null or buffers == null or rd == null or frames.is_empty():
		return {}
	var value: Variant = ctx.get_meta(&"frp_cloud_fog_composition", {})
	if not cloud_composition_metadata_matches_current_frame(ctx, value,
			int(frames[0].frame_generation), buffers.get_instance_id(), frames.size(),
			buffers.get_internal_size()):
		return {}
	# The native snapshot signature validates the current context owner. The
	# separate GPU source signature may include animated radiance and remains a
	# cloud-local cache/history key; it is never compared to the native value.
	value["history_identity"] = value.get("history_identity", [
		value.get("buffer_id", 0), value.get("view_count", 0),
		value.get("internal_size", Vector2i.ZERO),
	])
	var radiance: Variant = value.get("radiance", RID())
	var transmittance: Variant = value.get("transmittance", RID())
	if not radiance is RID or not transmittance is RID \
			or not radiance.is_valid() or not transmittance.is_valid() \
			or not rd.texture_is_valid(radiance) or not rd.texture_is_valid(transmittance):
		return {}
	return value


func _clear_late_composite_state() -> void:
	_frame_inputs.clear()
	_volume_result.clear()
	_volume_result_frame_generation = -1
	_fsss_result.clear()
	_late_fsss_snapshot.clear()
	_late_analytic_snapshot.clear()
	_volume_composite_deferred = false
	_fsss_composite_deferred = false
	_late_fog_scale = 1.0
	_pre_exposure = 1.0
	_capture_exposure_normalization = 1.0


func _read_volume_frame_inputs(ctx: FRPPassContext, buffers: RenderSceneBuffersRD,
		world_id: int = 0) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if ctx == null or buffers == null or not ctx.has_method("get_volume_frame_inputs"):
		return result
	if not _ensure_fog_renderer():
		return result
	for view in buffers.get_view_count():
		var frame: Dictionary = _fog_renderer.call("normalize_frame_inputs",
				ctx.call("get_volume_frame_inputs", view), view)
		if frame.is_empty():
			return []
		frame["world_id"] = world_id
		result.append(frame)
	return result


func _volume_requested(snapshot: Dictionary) -> bool:
	var volume: Variant = snapshot.get("volumetric_fog", {})
	if volume is Dictionary and bool(volume.get("enabled", false)):
		return true
	var local_volumes: Variant = snapshot.get("local_volumes", [])
	if local_volumes is Array:
		for local_volume in local_volumes:
			if local_volume is Dictionary and bool(local_volume.get("enabled", false)):
				return true
	return false


func _fsss_requested(snapshot: Dictionary) -> bool:
	var value: Variant = snapshot.get("screen_space_scattering", {})
	return value is Dictionary and bool(value.get("enabled", false))


func _advanced_fog_requested(snapshot: Dictionary) -> bool:
	return _volume_requested(snapshot) or _fsss_requested(snapshot)


func _report_volume_failure(snapshot: Dictionary, fallback_reason: String = "") -> void:
	if not _volume_requested(snapshot):
		return
	if fallback_reason.is_empty() and _fog_renderer != null \
			and _fog_renderer.has_method("is_volume_inactive") \
			and bool(_fog_renderer.call("is_volume_inactive")):
		return
	var reason := fallback_reason
	if reason.is_empty() and _fog_renderer != null and _fog_renderer.has_method("get_volume_error"):
		reason = str(_fog_renderer.call("get_volume_error"))
	if reason.is_empty() and _fog_renderer != null and _fog_renderer.has_method("get_volume_status"):
		reason = str(_fog_renderer.call("get_volume_status"))
	if reason.is_empty():
		reason = "GPU service returned no integrated texture and no failure detail"
	var identity := str(snapshot.get("fog_id", 0)) + ":" + reason
	if identity == _last_volume_failure_signature:
		return
	_last_volume_failure_signature = identity
	_report("Volumetric fog output unavailable: %s." % reason)

func _make_forward_parameters(snapshot: Dictionary, camera: Transform3D, fog_scale: float,
		projection: Projection) -> PackedFloat32Array:
	var density := float(snapshot.get("fog_density", 0.0))
	var falloff := float(snapshot.get("fog_height_falloff", 0.0))
	var height := float(snapshot.get("fog_height", 0.0))
	var density2 := float(snapshot.get("second_fog_density", 0.0))
	var falloff2 := float(snapshot.get("second_fog_height_falloff", 0.0))
	var height2 := float(snapshot.get("second_fog_height", 0.0))
	var observer_y := _observer_height(camera.origin.y, density, height, density2, height2, projection)
	var global_density := density * pow(2.0, clampf(-falloff * (observer_y - height), -125.0, 126.0))
	var global_density2 := density2 * pow(2.0, clampf(-falloff2 * (observer_y - height2), -125.0, 126.0))
	var fog_color: Variant = snapshot.get("fog_color", Vector3.ZERO)
	var sun_direction: Variant = snapshot.get("sun_direction", Vector3.ZERO)
	var inscattering_color: Variant = snapshot.get("inscattering_color", Vector3.ZERO)
	var volume_far_distance := 0.0
	var volume_settings: Variant = snapshot.get("volumetric_fog", {})
	if volume_settings is Dictionary and bool(volume_settings.get("enabled", false)):
		var volume_start: Variant = volume_settings.get("start_distance", 0.0)
		var volume_distance: Variant = volume_settings.get("distance", 0.0)
		if (volume_start is float or volume_start is int) \
				and (volume_distance is float or volume_distance is int) \
				and is_finite(float(volume_start)) and is_finite(float(volume_distance)):
			volume_far_distance = clampf(maxf(float(volume_start), 0.0)
					+ maxf(float(volume_distance), 0.0), 0.0, 1000000.0)
	var values := PackedFloat32Array([camera.origin.x, camera.origin.y, camera.origin.z, volume_far_distance,
			global_density, falloff, observer_y, float(snapshot.get("start_distance", 0.0)),
			global_density2, falloff2, density2, height2,
			density, height, fog_scale, float(snapshot.get("cutoff_distance", 0.0))])
	if fog_color is Vector3:
		values.append_array(PackedFloat32Array([fog_color.x, fog_color.y, fog_color.z,
				float(snapshot.get("min_opacity", 0.0))]))
	else:
		values.append_array(PackedFloat32Array([0.0, 0.0, 0.0, float(snapshot.get("min_opacity", 0.0))]))
	if sun_direction is Vector3:
		values.append_array(PackedFloat32Array([sun_direction.x, sun_direction.y, sun_direction.z,
				float(snapshot.get("inscattering_start", -1.0))]))
	else:
		values.append_array(PackedFloat32Array([0.0, 0.0, 0.0, -1.0]))
	if inscattering_color is Vector3:
		values.append_array(PackedFloat32Array([inscattering_color.x, inscattering_color.y, inscattering_color.z,
				clampf(float(snapshot.get("inscattering_exponent", 4.0)), 0.000001, 1000.0)]))
	else:
		values.append_array(PackedFloat32Array([0.0, 0.0, 0.0, 4.0]))
	return values


func _observer_height(camera_y: float, density: float, height: float, density2: float,
		height2: float, projection: Projection) -> float:
	# Unreal caps the observer for perspective rays to 65536 cm above each
	# nonzero fog layer. Orthographic cameras use ViewTarget distance instead;
	# Godot exposes no equivalent target distance, so retain their actual height.
	if projection.is_orthogonal() or not is_finite(camera_y):
		return camera_y
	var cap := INF
	if density > 0.0 and is_finite(density) and is_finite(height):
		cap = minf(cap, height + 655.36)
	if density2 > 0.0 and is_finite(density2) and is_finite(height2):
		cap = minf(cap, height2 + 655.36)
	return minf(camera_y, cap) if is_finite(cap) else camera_y

func _parameter_bytes() -> PackedByteArray:
	var value: Vector4 = _frame_parameters if _frame_parameters is Vector4 else parameters
	var exposure := _pre_exposure * (_capture_exposure_normalization if _capture_snapshot_active else 1.0)
	return PackedFloat32Array([value.x, exposure, value.z, value.w]).to_byte_array()

func _init() -> void:
	inputs = _make_inputs()

func runtime_script_path() -> String:
	return RUNTIME_SCRIPT_PATH

## Resources saved before the contract changed are repaired on load (see
## FengRenderer._observe_pass): the declaration is rebuilt without touching the
## authored enabled state or parameter scale.
func ensure_frp_contract() -> bool:
	var expected_inputs := _make_inputs()
	if _inputs_match(inputs, expected_inputs):
		return false
	inputs = expected_inputs
	return true

func _make_inputs() -> Array[TextureInput]:
	var color := TextureInput.new()
	color.binding = 0
	color.source = TextureInput.Source.COLOR
	color.binding_type = TextureInput.BindingType.STORAGE_IMAGE
	var depth := TextureInput.new()
	depth.binding = 1
	depth.source = TextureInput.Source.DEPTH
	return [color, depth]

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["parameters"])

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	# No fog node in this world: the pass is a true no-op — color is modified in
	# place, so there is nothing to clear and no dispatch to schedule.
	if (_frame_snapshot.is_empty() and _atmosphere_snapshot.is_empty()) or _frame_scene_data == null:
		return
	if not _update_frame_ubo(_frame_snapshot, _frame_scene_data, view, rd):
		return
	if not _update_volume_sampling_ubo(view, rd):
		return
	super._render(buffers, view, rd)


func _update_volume_sampling_ubo(view: int, rd: RenderingDevice,
		for_late_composite: bool = false) -> bool:
	if not _ensure_volume_sampling_resources(rd):
		_binding_error = true
		_report("Cannot create volumetric fog sampling resources.")
		return false
	while _volume_sampling_ubos.size() <= view:
		var ubo := rd.uniform_buffer_create(VOLUME_SAMPLING_UBO_BYTES)
		if not ubo.is_valid():
			return false
		_volume_sampling_ubos.append(ubo)
	var packet: PackedFloat32Array = _volume_result.get("sample_parameters", PackedFloat32Array())
	var volume_texture: RID = _volume_result.get("texture", RID())
	var volume_valid := packet.size() == 20 and volume_texture.is_valid()
	var storage_exposure := 1.0
	if volume_valid:
		storage_exposure = float(_volume_result.get("rgb_pre_exposure", 1.0))
	else:
		packet = PackedFloat32Array([
			1.0, 0.0, 32.0, 1.0,
			1.0, 1.0, 1.0, 1.0,
			1.0, 1.0, 1.0, 1.0,
			0.0, 1.0, 0.05, 1.0,
			1.0, 1.0, 1.0, 0.0,
		])
		packet[19] = 0.0
	var current_exposure := _pre_exposure
	if view < _frame_inputs.size():
		current_exposure = float(_frame_inputs[view].get("pre_exposure", _pre_exposure))
	var textures_by_view: Array = _fsss_result.get("textures_by_view", [])
	var fsss_texture: RID = textures_by_view[view] if view < textures_by_view.size() else RID()
	var composite_enabled := for_late_composite or not _volume_composite_deferred
	var fsss_enabled := fsss_texture.is_valid() and composite_enabled
	var fsss: Dictionary = {}
	var fsss_snapshot: Dictionary = _late_fsss_snapshot if for_late_composite else _frame_snapshot
	if _fsss_requested(fsss_snapshot) and _fog_renderer != null:
		fsss = _fog_renderer.call("normalize_screen_space_scattering",
				fsss_snapshot.get("screen_space_scattering", {}))
	var values := packet.duplicate()
	values.append_array(PackedFloat32Array([
		float(view), current_exposure, 1.0 if fsss_enabled else 0.0,
			1.0 if volume_valid and composite_enabled else 0.0,
	]))
	values.append_array(PackedFloat32Array([
		float(fsss.get("scene_color_scattering_amount_scale", 1.0)),
		float(fsss.get("scene_color_scattering_amount_power", 1.0)),
		float(fsss.get("spread_scale", 0.1)), float(fsss.get("blur_control", 0.5)),
	]))
	values.append_array(PackedFloat32Array([
		1.0 if volume_valid else 0.0,
		float(packet[13]) if volume_valid else 0.0,
		float(packet[12]) if volume_valid else 0.0,
		0.0,
	]))
	var bytes := values.to_byte_array()
	return bytes.size() == VOLUME_SAMPLING_UBO_BYTES \
			and rd.buffer_update(_volume_sampling_ubos[view], 0, bytes.size(), bytes) == OK


func _ensure_volume_sampling_resources(rd: RenderingDevice) -> bool:
	if not _empty_volume_texture.is_valid():
		_empty_volume_texture = _create_empty_volume_texture(rd)
	if not _empty_fsss_texture.is_valid():
		_empty_fsss_texture = _create_empty_fsss_texture(rd)
	return _empty_volume_texture.is_valid() and _empty_fsss_texture.is_valid()


func _create_empty_volume_texture(rd: RenderingDevice) -> RID:
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
	var zero := PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])
	return rd.texture_create(format, RDTextureView.new(), [zero])


func _create_empty_fsss_texture(rd: RenderingDevice) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = 1
	format.height = 1
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var zero := PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])
	return rd.texture_create(format, RDTextureView.new(), [zero])

func _update_frame_ubo(snapshot: Dictionary, scene_data: RenderSceneData, view: int, rd: RenderingDevice) -> bool:
	if scene_data == null or view >= scene_data.get_view_count():
		return false
	# Godot's view projection is the eye's projection matrix, not a combined
	# world-to-clip matrix. The shader must apply the camera transform as well.
	var projection: Projection = scene_data.get_view_projection(view)
	var inverse_projection: Projection = projection.inverse()
	var camera: Transform3D = scene_data.get_cam_transform()
	camera.origin += camera.basis.orthonormalized() * scene_data.get_view_eye_offset(view)
	var values := PackedFloat32Array()
	_append_projection(values, inverse_projection)
	var view_to_world := Transform3D(camera.basis.orthonormalized(), camera.origin)
	_append_transform(values, view_to_world)
	# Both paths use the same seven vec4s. Compute applies strength through its
	# push constant, so its reserved packet lane remains zero.
	values.append_array(_make_forward_parameters(snapshot, camera, 0.0, projection))
	values.append_array(AtmospherePacket.make(_atmosphere_snapshot, camera, _atmosphere_optical.is_valid(), _atmosphere_multiple.is_valid()))
	return _commit_frame_ubo(values, UBO_SIZE, rd)

func _collect_bindings(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> Dictionary:
	var binding_data := super._collect_bindings(buffers, view, rd)
	if _binding_error or not _ubo.is_valid() or view >= _volume_sampling_ubos.size():
		return binding_data
	var uniforms: Array[RDUniform] = binding_data["uniforms"]
	uniforms.append(_ubo_uniform(UBO_BINDING))
	if not _atmosphere_sampler.is_valid():
		var state := RDSamplerState.new()
		state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_atmosphere_sampler = rd.sampler_create(state)
	if not _empty_atmosphere_lut.is_valid():
		var format := RDTextureFormat.new()
		format.width = 1
		format.height = 1
		format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		_empty_atmosphere_lut = rd.texture_create(format, RDTextureView.new(), [PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array()])
	var cloud_parameters := _cloud_visibility_parameters
	if cloud_parameters.size() != 148:
		cloud_parameters.resize(148)
		cloud_parameters[140] = -1.0
		cloud_parameters[141] = -1.0
	if not _cloud_visibility_ubo.is_valid():
		_cloud_visibility_ubo = rd.uniform_buffer_create(CLOUD_VISIBILITY_UBO_SIZE)
	if not _cloud_visibility_ubo.is_valid() or rd.buffer_update(_cloud_visibility_ubo, 0,
			CLOUD_VISIBILITY_UBO_SIZE, cloud_parameters.to_byte_array()) != OK:
		_binding_error = true
		_report("Cannot update the cloud atmosphere visibility UBO.")
		return binding_data
	var cloud_visibility_uniform := RDUniform.new()
	cloud_visibility_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	cloud_visibility_uniform.binding = 5
	cloud_visibility_uniform.add_id(_cloud_visibility_ubo)
	uniforms.append(cloud_visibility_uniform)
	var textures: Array[RID] = [_atmosphere_optical, _atmosphere_multiple, _cloud_shadow0, _cloud_shadow1, _cloud_raw_ao]
	var bindings := [3, 4, 6, 7, 8]
	for slot in textures.size():
		var texture := textures[slot]
		if not texture.is_valid() or not rd.texture_is_valid(texture):
			texture = _empty_atmosphere_lut
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = bindings[slot]
		uniform.add_id(_atmosphere_sampler)
		uniform.add_id(texture)
		uniforms.append(uniform)
	var volume_texture: RID = _volume_result.get("texture", RID())
	if not volume_texture.is_valid() or not rd.texture_is_valid(volume_texture):
		volume_texture = _empty_volume_texture
	var fsss_textures: Array = _fsss_result.get("textures_by_view", [])
	var fsss_texture: RID = fsss_textures[view] if view < fsss_textures.size() else RID()
	if not fsss_texture.is_valid() or not rd.texture_is_valid(fsss_texture):
		fsss_texture = _empty_fsss_texture
	for binding_texture in [[9, volume_texture], [10, fsss_texture]]:
		var sampled := RDUniform.new()
		sampled.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		sampled.binding = int(binding_texture[0])
		sampled.add_id(_atmosphere_sampler)
		sampled.add_id(binding_texture[1])
		uniforms.append(sampled)
	var sampling_ubo := RDUniform.new()
	sampling_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	sampling_ubo.binding = 11
	sampling_ubo.add_id(_volume_sampling_ubos[view])
	uniforms.append(sampling_ubo)
	binding_data["uniforms"] = uniforms
	return binding_data

func _take_owned_rids() -> Array[RID]:
	var rids := super._take_owned_rids()
	rids.append_array([_empty_atmosphere_lut, _atmosphere_sampler, _cloud_visibility_ubo])
	if _fog_renderer != null:
		rids.append_array(_fog_renderer.call("take_owned_rids"))
		_fog_renderer = null
	rids.append_array(_volume_sampling_ubos)
	rids.append_array([_empty_volume_texture, _empty_fsss_texture])
	_volume_sampling_ubos.clear()
	_empty_volume_texture = RID()
	_empty_fsss_texture = RID()
	_atmosphere_sampler = RID()
	_empty_atmosphere_lut = RID()
	_cloud_visibility_ubo = RID()
	return rids
