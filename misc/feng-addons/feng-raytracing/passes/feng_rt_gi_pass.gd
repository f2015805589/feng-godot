@tool
class_name FengRTGIPass
extends FengPass
## Hardware ray traced diffuse GI and an independently enabled specular replacement.
const Runtime = preload("../scene/feng_rt_gi_runtime.gd")
const AvailabilityState = preload("rtgi_runtime_availability.gd")
const GPU = preload("../rendering/rt_gi_gpu.gd")
const SceneGPU = preload("../rendering/rt_gi_scene_gpu.gd")
const Emitters = preload("../rendering/rt_gi_emitters.gd")
const ReflectionRenderer = preload("../rendering/rt_gi_reflections.gd")
const NRDRenderer = preload("../rendering/rt_gi_nrd.gd")
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const Selection = preload("res://addons/feng-render-pipeline/pipeline/indirect_gi_selection.gd")
const NativeSpec = preload("res://addons/feng-render-pipeline/pipeline/native_spec.gd")
const REFLECTION_OUTPUT: StringName = &"rtgi_reflection"
const PIPELINE_SCOPE: StringName = NativeSpec.SCOPE_PIPELINE

@export_range(0, 8, 0.01) var strength := 1.0:
	set(value):
		strength = value
		emit_changed()
@export var reflections_enabled := true:
	set(value):
		reflections_enabled = value
		emit_changed()
@export_range(0, 1, 0.01) var reflection_strength := 1.0:
	set(value):
		reflection_strength = value
		emit_changed()
@export_range(1, 1000, 1) var max_distance := 100.0:
	set(value):
		max_distance = value
		emit_changed()
@export_enum("1:1", "2:2", "4:4") var samples_per_pixel := 1:
	set(value):
		samples_per_pixel = value
		emit_changed()
@export var importance_sampling := true:
	set(value):
		importance_sampling = value
		emit_changed()
@export var half_resolution := true:
	set(value):
		half_resolution = value
		emit_changed()
@export_enum("NRD RELAX", "Temporal") var denoiser := 0:
	set(value):
		denoiser = value
		emit_changed()
@export_range(0, 0.98, 0.01) var history_weight := 0.97:
	set(value):
		history_weight = value
		emit_changed()

var _states: Dictionary = {} # [target RID, view] -> shared scene plus independent effect histories.
var _warnings: Dictionary = {}
var _sky_input: FengPassTexture
var _shared: Array[RID] = []
var _diffuse_temporal_shader := RID()
var _diffuse_temporal_pipeline := RID()
var _diffuse_composite_shader := RID()
var _diffuse_composite_pipeline := RID()
var _scene_color_readback_shader := RID()
var _scene_color_readback_pipeline := RID()
var _reflection_backends: Dictionary = {} # native sky texture type -> independent pass backend.
var _runtime_start_queued := false
var _availability_state := AvailabilityState.new()
var _diffuse_attempt_expected := false
var _diffuse_attempt_composited := false
var _diffuse_attempt_reason := ""
var _last_diffuse_attempt: Dictionary = {}
var _rtgi_diagnostics_enabled := false
var _rtgi_diagnostics: Dictionary = {}

func _init() -> void:
	stage = 8 # Post Lighting, before Sky, Transparent and the temporal/post transforms.
	resource_name = "Hardware RTGI"
	access_resolved_color = true
	access_resolved_depth = true
	needs_normal_roughness = true
	inputs = _make_inputs()
	outputs = _make_outputs()
	_sky_input = FengPassTexture.new()
	_sky_input.source = FengPassTexture.Source.CUSTOM
	_sky_input.custom_scope = &"frp_clustered"
	_sky_input.custom_name = &"sky_light_diffuse"

func _make_inputs() -> Array[FengPassTexture]:
	var declarations: Array[FengPassTexture] = []
	for source in [FengPassTexture.Source.DEPTH, FengPassTexture.Source.NORMAL_ROUGHNESS,
			FengPassTexture.Source.ALBEDO, FengPassTexture.Source.ORM, FengPassTexture.Source.EMISSION,
			FengPassTexture.Source.INDIRECT_SPECULAR]:
		var input := FengPassTexture.new()
		input.binding = declarations.size() + 1
		input.source = source
		declarations.append(input)
	return declarations

func _make_outputs() -> Array[OutputDeclaration]:
	var reflection := OutputDeclaration.new()
	reflection.name = REFLECTION_OUTPUT
	reflection.data_format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	reflection.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE | OutputDeclaration.Usage.COPY_TO
	reflection.scale = Vector2.ONE
	return [reflection]

## Repair serialized pass resources from builds that stored an incomplete binding list.
## RTGI's shader ABI requires these six sampled textures at bindings 1 through 6.
func ensure_frp_contract() -> bool:
	var expected := _make_inputs()
	var changed := false
	if not _inputs_match(inputs, expected):
		inputs = expected
		changed = true
	if not _outputs_match(outputs, _make_outputs()):
		outputs = _make_outputs()
		changed = true
	if not access_resolved_color:
		access_resolved_color = true
		changed = true
	if not access_resolved_depth:
		access_resolved_depth = true
		changed = true
	if not needs_normal_roughness:
		needs_normal_roughness = true
		changed = true
	return changed

func _inputs_match(actual: Array[FengPassTexture], expected: Array[FengPassTexture]) -> bool:
	if actual.size() != expected.size():
		return false
	for index in expected.size():
		var input := actual[index]
		var required := expected[index]
		if input == null or input.binding != required.binding or input.source != required.source \
				or input.binding_type != FengPassTexture.BindingType.SAMPLED_TEXTURE \
				or input.custom_scope != &"" or input.custom_name != &"":
			return false
	return true

func _start_runtime() -> void:
	Runtime.start()

func _queue_runtime_start() -> void:
	if _runtime_start_queued:
		return
	_runtime_start_queued = true
	# _frp_prepare runs on the render thread. Start the main-thread snapshot tick only
	# after an enabled pass actually claims diffuse or reflection work for this frame.
	_start_runtime.call_deferred()

## Optional counters for a same-scene activation audit. Disabled by default so the
## normal render path does not retain diagnostic data or build state summaries.
func set_rtgi_diagnostics_enabled(value: bool) -> void:
	_rtgi_diagnostics_enabled = value
	if value:
		_rtgi_diagnostics = {
			"prepare_callbacks": 0,
			"execute_callbacks": 0,
			"valid_snapshots": 0,
			"scene_sync_successes": 0,
			"trace_dispatches": 0,
			"resolve_successes": 0,
			"composite_dispatches": 0,
			"raytracing_supported": false,
			"last_snapshot": {},
			"last_lighting": {},
			"readback_requested": false,
			"raw_output_stats": {},
			"resolved_output_stats": {},
			"sky_diffuse_stats": {},
			"scene_color_readback_requested": false,
			"scene_color_composite_readback": {},
			"messages": [],
		}
	else:
		_rtgi_diagnostics.clear()

func get_rtgi_diagnostics_snapshot() -> Dictionary:
	var states: Array[Dictionary] = []
	for key in _states:
		var state: Dictionary = _states[key]
		var scene: Variant = state.get("scene")
		var gpu: Variant = state.get("gpu")
		var diffuse: Dictionary = state.get("diffuse", {})
		var resolved: Variant = diffuse.get("resolved", RID())
		var diffuse_size: Vector2i = diffuse.get("size", Vector2i.ZERO)
		var scene_blas_count := 0
		if scene != null:
			for row_value in scene.scene_rows:
				if row_value is Dictionary:
					var blas_rid: Variant = row_value.get("blas", RID())
					if blas_rid is RID and blas_rid.is_valid():
						scene_blas_count += 1
		states.append({
			"view": int(key[1]),
			"tlas_valid": scene != null and scene.tlas.is_valid(),
			"blas_count": scene_blas_count,
			"surface_buffer_valid": scene != null and scene.surfaces.is_valid(),
			"material_buffer_valid": scene != null and scene.materials.is_valid(),
			"emitter_buffer_valid": scene != null and scene.emitters.is_valid(),
			"geometry_key": scene.geometry_key if scene != null else 0,
			"transform_key": scene.transform_key if scene != null else 0,
			"ray_pipeline_valid": gpu != null and gpu.pipeline.is_valid(),
			"diffuse_size": [diffuse_size.x, diffuse_size.y],
			"raw_texture_valid": diffuse.get("raw", RID()).is_valid(),
			"resolved_texture_valid": resolved is RID and resolved.is_valid(),
			"diffuse_state_valid": bool(diffuse.get("valid", false)),
			"diffuse_generation": int(diffuse.get("generation", -1)),
			"nrd_ready": bool(diffuse.get("nrd_ready", false)),
			"temporal_denoiser_active": int(diffuse.get("denoiser", -1)) == 1,
		})
	return {"enabled": _rtgi_diagnostics_enabled,
		"availability": get_indirect_gi_availability(),
		"counters": _rtgi_diagnostics.duplicate(true), "states": states,
		"last_diffuse_attempt": _last_diffuse_attempt.duplicate(true)}

## Request one synchronous, opt-in GPU readback of the raw and resolved diffuse
## outputs on the render thread. The activation profile uses this to prove they
## contain nonzero radiance.
func request_rtgi_output_readback() -> void:
	if _rtgi_diagnostics_enabled:
		_rtgi_diagnostics.readback_requested = true
		_rtgi_diagnostics.raw_output_stats = {}
		_rtgi_diagnostics.resolved_output_stats = {}
		_rtgi_diagnostics.sky_diffuse_stats = {}

## Request an opt-in linear HDR readback immediately before and after RTGI's
## in-place scene-color composite. This is independent of the later viewport PNG.
func request_rtgi_scene_color_readback() -> void:
	if _rtgi_diagnostics_enabled:
		_rtgi_diagnostics.scene_color_readback_requested = true
		_rtgi_diagnostics.scene_color_composite_readback = {}

func can_share_view_execution() -> bool:
	return true

func get_indirect_gi_kind() -> StringName:
	# Only diffuse ownership is planned here. Reflections remain independent of MagicGI.
	return Selection.KIND_RT

## An enabled RTGI resource must not take diffuse ownership on devices where its
## required ray-tracing pipeline is unavailable. This lets the planned MagicGI
## fallback remain the single writer for that frame.
func get_indirect_gi_availability() -> Dictionary:
	var hardware := _get_hardware_rt_availability()
	return _availability_state.get_status(bool(hardware.get("available", false)),
		str(hardware.get("reason", "")), str(hardware.get("device", "")),
		Engine.get_frames_drawn())

func _get_hardware_rt_availability() -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return {"available": false, "reason": "rendering_device_unavailable", "device": ""}
	var supported := rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)
	return {
		"available": supported,
		"reason": "" if supported else "raytracing_pipeline_unsupported",
		"device": rd.get_device_name(),
	}

func get_reflection_source_kind() -> StringName:
	return &"gi"

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["strength", "reflections_enabled", "reflection_strength", "max_distance",
			"samples_per_pixel", "half_resolution", "history_weight", "denoiser", "importance_sampling"])

func get_required_before_native_ids() -> PackedInt32Array:
	return PackedInt32Array([NativeSpec.PASS_TRANSPARENT, NativeSpec.PASS_TEMPORAL_AA,
			NativeSpec.PASS_BLOOM, NativeSpec.PASS_POST_PROCESS])

func _reflection_slot_active(ctx: FRPPassContext, options: Dictionary) -> bool:
	var amount := float(options.get("reflection_strength", 0.0))
	if not bool(options.get("reflections_enabled", false)) or not is_finite(amount) or amount <= 0.0:
		return false
	if Selection.is_reflection_owner(ctx, String(get_parameter_key())):
		return true
	warn_once("RTGI reflections require one unique planned provider; native indirect specular remains active.")
	return false

func _frp_prepare(ctx: FRPPassContext) -> void:
	if _rtgi_diagnostics_enabled:
		_rtgi_diagnostics.prepare_callbacks += 1
	var hardware := _get_hardware_rt_availability()
	if not bool(hardware.get("available", false)):
		var availability := get_indirect_gi_availability()
		var reason := str(availability.get("reason", "indirect_gi_provider_unavailable"))
		warn_once("Hardware RTGI unavailable (%s); the planned MagicGI fallback retains diffuse lighting." % reason)
		return
	var diffuse_availability := get_indirect_gi_availability()
	if not bool(diffuse_availability.get("available", false)):
		warn_once("RTGI diffuse temporarily unavailable (%s); the planned MagicGI fallback retains diffuse lighting." % str(diffuse_availability.get("reason", "indirect_gi_provider_unavailable")))
	var options := get_resolved_parameters(ctx)
	var diffuse_amount := float(options.get("strength", 0.0))
	var diffuse_active := Selection.is_owner(ctx, String(get_parameter_key()), Selection.KIND_RT, false) \
			and is_finite(diffuse_amount) and diffuse_amount > 0.0
	var reflection_active := _reflection_slot_active(ctx, options)
	if not diffuse_active and not reflection_active:
		return
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		return
	var buffers := ctx.get_render_scene_buffers()
	if buffers != null:
		_queue_runtime_start()
		Runtime.request_target(buffers.get_render_target())
	elif diffuse_active:
		_record_prepare_failure("render_scene_buffers_unavailable")
	if diffuse_active:
		ctx.request_sky_light_diffuse()
	if reflection_active:
		ctx.request_indirect_specular()

func _frp_execute(ctx: FRPPassContext) -> void:
	if _rtgi_diagnostics_enabled:
		_rtgi_diagnostics.execute_callbacks += 1
	var options := get_resolved_parameters(ctx)
	var diffuse_amount := float(options.get("strength", 0.0))
	_diffuse_attempt_expected = Selection.is_owner(ctx, String(get_parameter_key()), Selection.KIND_RT, false) \
			and is_finite(diffuse_amount) and diffuse_amount > 0.0 \
			and bool(_get_hardware_rt_availability().get("available", false))
	_diffuse_attempt_composited = false
	_diffuse_attempt_reason = "diffuse_composite_not_dispatched"
	_execute_frame(ctx)
	if _diffuse_attempt_expected:
		_availability_state.report_diffuse_result(_diffuse_attempt_composited,
			_diffuse_attempt_reason, Engine.get_frames_drawn())
	_last_diffuse_attempt = {
		"attempted": _diffuse_attempt_expected,
		"composited": _diffuse_attempt_composited,
		"reason": _diffuse_attempt_reason if _diffuse_attempt_expected and not _diffuse_attempt_composited else "",
		"frame": Engine.get_frames_drawn(),
	}
	_diffuse_attempt_expected = false
	refresh_owned()

func _set_diffuse_attempt_failure(reason: String) -> void:
	if _diffuse_attempt_expected and not _diffuse_attempt_composited:
		_diffuse_attempt_reason = reason if not reason.is_empty() else "diffuse_composite_not_dispatched"

func _record_prepare_failure(reason: String) -> void:
	var frame := Engine.get_frames_drawn()
	_availability_state.report_diffuse_result(false, reason, frame)
	_last_diffuse_attempt = {"attempted": true, "composited": false,
		"reason": reason, "frame": frame, "stage": "prepare"}

func _execute_frame(ctx: FRPPassContext) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_set_diffuse_attempt_failure("rendering_device_unavailable")
		return
	_sweep_idle_states(rd)
	var buffers := ctx.get_render_scene_buffers()
	if buffers == null:
		_set_diffuse_attempt_failure("render_scene_buffers_unavailable")
		return
	_clear_reflection_outputs(rd, buffers)
	var target := buffers.get_render_target()
	if not target.is_valid():
		_set_diffuse_attempt_failure("invalid_render_target")
		return
	var options := get_resolved_parameters(ctx)
	var diffuse_amount := float(options.get("strength", 0.0))
	var diffuse_active := Selection.is_owner(ctx, String(get_parameter_key()), Selection.KIND_RT, false) \
			and is_finite(diffuse_amount) and diffuse_amount > 0.0
	var reflection_amount := float(options.get("reflection_strength", 0.0))
	var reflection_active := _reflection_slot_active(ctx, options) and ctx.is_reflection_components_available()
	if not diffuse_active and not reflection_active:
		return
	if not rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		warn_once("Hardware RT pipelines are unavailable; native diffuse and specular lighting remain active.")
		_set_diffuse_attempt_failure("raytracing_pipeline_unsupported")
		invalidate(target)
		return
	if _rtgi_diagnostics_enabled:
		_rtgi_diagnostics.raytracing_supported = true
	_queue_runtime_start()
	Runtime.request_target(target)
	var snapshot := Runtime.snapshot_for_target(target)
	if _rtgi_diagnostics_enabled:
		var instances: Array = snapshot.get("instances", [])
		var surface_count := 0
		var material_count := 0
		for instance: Dictionary in instances:
			var mesh: Dictionary = instance.get("mesh", {})
			surface_count += (mesh.get("surfaces", []) as Array).size()
			material_count += (mesh.get("materials", []) as Array).size()
		_rtgi_diagnostics.last_snapshot = {
			"valid": bool(snapshot.get("valid", false)),
			"reason": str(snapshot.get("reason", "")),
			"abi_version": int(snapshot.get("abi_version", -1)),
			"world_id": int(snapshot.get("world_id", 0)),
			"instance_count": instances.size(),
			"surface_count": surface_count,
			"material_count": material_count,
			"emissive_surface_candidates": Emitters.signature(instances).size(),
			"snapshot_generation": int(snapshot.get("snapshot_generation", -1)),
			"unsupported_reasons": snapshot.get("unsupported_reasons", []),
		}
	if not bool(snapshot.get("valid", false)):
		var reasons: Array = snapshot.get("unsupported_reasons", [])
		if not reasons.is_empty():
			warn_once("Unsupported scene geometry/material: " + str(reasons[0]) + "; native lighting remains active.")
		invalidate(target)
		_set_diffuse_attempt_failure("scene_snapshot_invalid: " + str(snapshot.get("reason", "unknown")))
		return
	if _rtgi_diagnostics_enabled:
		_rtgi_diagnostics.valid_snapshots += 1
	if diffuse_active and not ensure_diffuse_compute(rd):
		_set_diffuse_attempt_failure("diffuse_compute_pipeline_unavailable")
		diffuse_active = false
	var full_size: Vector2i = buffers.get_internal_size()
	for view in buffers.get_view_count():
		var frame: Dictionary = ctx.get_volume_frame_inputs(view)
		if frame.is_empty():
			_set_diffuse_attempt_failure("view_frame_inputs_unavailable")
			continue
		if _rtgi_diagnostics_enabled:
			_rtgi_diagnostics.last_lighting = {
				"directional_light_count": int(frame.get("directional_light_count", 0)),
				"sky_light_source_valid": bool(frame.get("sky_light_source_valid", false)),
				"sky_light_energy": float(frame.get("sky_light_energy", 0.0)),
				"sky_light_source_owner_id": int(frame.get("sky_light_source_owner_id", 0)),
				"pre_exposure": float(frame.get("pre_exposure", 1.0)),
				"scene_normalization": float(frame.get("scene_normalization", 1.0)),
			}
		var sky_array := bool(frame.get("sky_radiance_is_array", false))
		var key: Array = [target, view]
		var state: Dictionary = _states.get(key, {})
		if state.is_empty():
			state = _create_scene_state(rd, sky_array)
			if state.is_empty():
				_set_diffuse_attempt_failure("raytracing_scene_state_initialization_failed")
				continue
			_states[key] = state
		elif bool(state.get("sky_array", false)) != sky_array:
			_free_state(rd, state)
			state = _create_scene_state(rd, sky_array)
			if state.is_empty():
				_states.erase(key)
				_set_diffuse_attempt_failure("raytracing_scene_state_reinitialization_failed")
				continue
			_states[key] = state
		state.last_seen = Engine.get_frames_drawn()
		var view_diffuse_active := diffuse_active
		var view_reflection_active := reflection_active
		var textures: Array[RID] = []
		for declaration in inputs:
			textures.append(declaration.get_texture(buffers, view))
		if textures.size() < 6:
			_set_diffuse_attempt_failure("required_sampled_inputs_unavailable")
			continue
		var sky_diffuse := _sky_input.get_texture(buffers, view) if view_diffuse_active else RID()
		if view_diffuse_active and not sky_diffuse.is_valid():
			_set_diffuse_attempt_failure("sky_diffuse_input_unavailable")
			view_diffuse_active = false
		var dfg: RID = frame.get("dfg_texture", RID())
		if view_reflection_active and (not dfg is RID or not dfg.is_valid()):
			warn_once("The native DFG LUT is unavailable; native indirect specular remains active.")
			view_reflection_active = false
		if not view_diffuse_active and not view_reflection_active:
			continue
		var reflection_backend: Variant
		if view_reflection_active:
			reflection_backend = _get_reflection_backend(rd, sky_array)
			if reflection_backend == null:
				view_reflection_active = false
		var gpu: Variant
		if view_diffuse_active:
			gpu = _ensure_diffuse_gpu(rd, state, sky_array)
			if gpu == null:
				_set_diffuse_attempt_failure("raytracing_pipeline_initialization_failed")
				view_diffuse_active = false
		if not view_diffuse_active and not view_reflection_active:
			continue
		if view_diffuse_active and view_reflection_active \
				and int(gpu.sbt_range) != int(reflection_backend.sbt_range):
			warn_once("Diffuse and reflection hit-group records do not share an AS instance range.")
			view_reflection_active = false
		var sync_ok := false
		if view_diffuse_active:
			sync_ok = gpu.sync_scene(snapshot)
		else:
			sync_ok = state.scene.sync_scene(snapshot, reflection_backend.sbt_range)
		if not sync_ok:
			warn_once(state.scene.error)
			_set_diffuse_attempt_failure("scene_sync_failed: " + str(state.scene.error))
			_invalidate_history(state, "diffuse")
			_invalidate_history(state, "reflection")
			continue
		if _rtgi_diagnostics_enabled:
			_rtgi_diagnostics.scene_sync_successes += 1
		var generation := int(frame.get("frame_generation", Engine.get_frames_drawn()))
		var trace_options := options.duplicate(true)
		trace_options["max_distance"] = _finite_option(options, "max_distance", max_distance, 0.001, 1000.0)
		trace_options["samples_per_pixel"] = _valid_samples(int(options.get("samples_per_pixel", samples_per_pixel)))
		trace_options["history_weight"] = clampf(_finite_option(options, "history_weight", history_weight, 0.0, 0.98), 0.0, 0.98)
		if view_diffuse_active:
			var diffuse_size := Vector2i(maxi(1, (full_size.x + 1) / 2), maxi(1, (full_size.y + 1) / 2)) \
					if bool(options.get("half_resolution", half_resolution)) else full_size
			if state.diffuse.is_empty() or state.diffuse.size != diffuse_size:
				_release_diffuse_state(rd, state.diffuse)
				state.diffuse = _create_diffuse_state(rd, diffuse_size)
			if not state.diffuse.is_empty():
				trace_options["strength"] = diffuse_amount
				var diffuse_frame := _pack_trace_frame(frame, diffuse_size, generation, view, diffuse_amount, trace_options)
				var trace_ok: bool = gpu.trace(textures.slice(0, 4), diffuse_frame, frame, state.diffuse.raw, dfg, diffuse_size, state.diffuse.hit_distance)
				if _rtgi_diagnostics_enabled and trace_ok:
					_rtgi_diagnostics.trace_dispatches += 1
				if trace_ok:
					var diffuse_revision := hash([snapshot.get("registry_epoch", 0), snapshot.get("snapshot_generation", 0),
							gpu.scene.geometry_key, gpu.scene.transform_key, trace_options.get("max_distance"), diffuse_amount,
							trace_options.get("samples_per_pixel"), _lighting_signature(frame)])
					if _resolve_diffuse(rd, state.scene.sampler, state.diffuse, frame, textures, generation,
							diffuse_revision, trace_options):
						if _rtgi_diagnostics_enabled:
							_rtgi_diagnostics.resolve_successes += 1
							if bool(_rtgi_diagnostics.get("readback_requested", false)):
								_rtgi_diagnostics.raw_output_stats = _measure_rgba16f_texture(rd,
										state.diffuse.raw, diffuse_size)
								_rtgi_diagnostics.resolved_output_stats = _measure_rgba16f_texture(rd,
										state.diffuse.resolved, diffuse_size)
								_rtgi_diagnostics.sky_diffuse_stats = _measure_rgba16f_texture(rd,
										sky_diffuse, full_size)
								_rtgi_diagnostics.readback_requested = false
						var scene_color_target := buffers.get_color_layer(view)
						var capture_scene_color := _rtgi_diagnostics_enabled \
								and bool(_rtgi_diagnostics.get("scene_color_readback_requested", false))
						var scene_color_before: Image
						var depth_capture: Dictionary = {}
						var scene_color_readback_texture := RID()
						var depth_readback_texture := RID()
						var scene_color_format: Variant = rd.texture_get_format(scene_color_target) if scene_color_target.is_valid() else null
						var depth_format: Variant = rd.texture_get_format(textures[0]) if textures[0].is_valid() else null
						if capture_scene_color:
							if scene_color_format != null:
								scene_color_readback_texture = _texture(rd, full_size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
								if scene_color_readback_texture.is_valid() \
										and _copy_sampled_texture_to_readback(rd, state.scene.sampler, scene_color_target,
											scene_color_readback_texture, full_size):
									scene_color_before = _read_rgba16f_image(rd, scene_color_readback_texture, full_size)
							if depth_format != null:
								depth_readback_texture = _texture(rd, full_size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
								if depth_readback_texture.is_valid() \
										and _copy_sampled_texture_to_readback(rd, state.scene.sampler, textures[0],
											depth_readback_texture, full_size):
									var depth_image := _read_rgba16f_image(rd, depth_readback_texture, full_size)
									depth_capture = {"valid": depth_image != null, "image": depth_image,
										"format": int(depth_format.format), "byte_count": depth_image.get_data_size() if depth_image != null else 0}
						var history: Array = state.diffuse.history[state.diffuse.ping]
						var composite_ok := _dispatch(rd, _diffuse_composite_shader, _diffuse_composite_pipeline,
								[U.image(0, scene_color_target), U.sampled(1, state.scene.sampler, state.diffuse.get("resolved", history[0])),
								U.sampled(2, state.scene.sampler, sky_diffuse), U.sampled(3, state.scene.sampler, textures[0]),
								U.sampled(4, state.scene.sampler, history[2]),
								U.sampled(5, state.scene.sampler, textures[1]), U.sampled(6, state.scene.sampler, history[3]),
								U.sampled(7, state.scene.sampler, textures[2]), U.sampled(8, state.scene.sampler, textures[3]),
								U.sampled(9, state.scene.sampler, history[4]), U.uniform_buffer(10, state.diffuse.ubo)], full_size)
						if capture_scene_color:
							if composite_ok:
								var scene_color_after: Image
								if scene_color_readback_texture.is_valid() \
										and _copy_sampled_texture_to_readback(rd, state.scene.sampler, scene_color_target,
											scene_color_readback_texture, full_size):
									scene_color_after = _read_rgba16f_image(rd, scene_color_readback_texture, full_size)
								_rtgi_diagnostics.scene_color_composite_readback = _measure_scene_color_composite(
										scene_color_before, scene_color_after, depth_capture, scene_color_target.get_id(),
										int(scene_color_format.format) if scene_color_format != null else -1)
							else:
								_rtgi_diagnostics.scene_color_composite_readback = {
									"valid": false, "reason": "diffuse composite dispatch failed",
									"color_target_id": scene_color_target.get_id(),
								}
							_rtgi_diagnostics.scene_color_readback_requested = false
						if scene_color_readback_texture.is_valid():
							rd.free_rid(scene_color_readback_texture)
						if depth_readback_texture.is_valid():
							rd.free_rid(depth_readback_texture)
						if _rtgi_diagnostics_enabled and composite_ok:
							_rtgi_diagnostics.composite_dispatches += 1
						if composite_ok:
							_diffuse_attempt_composited = true
							_diffuse_attempt_reason = ""
						else:
							_set_diffuse_attempt_failure("diffuse_composite_dispatch_failed")
					else:
						_set_diffuse_attempt_failure("diffuse_resolve_failed")
				else:
					warn_once(gpu.error)
					_set_diffuse_attempt_failure("raytracing_trace_failed: " + str(gpu.error))
					state.diffuse.valid = false
			else:
				_set_diffuse_attempt_failure("diffuse_output_state_initialization_failed")
		if view_reflection_active:
			var reflection_state: Dictionary = state.reflection
			if reflection_state.is_empty() or reflection_state.size != full_size:
				reflection_backend.release_state(reflection_state)
				reflection_state = reflection_backend.create_state(full_size)
				state.reflection = reflection_state
			if not reflection_state.is_empty():
				var reflection_frame := _pack_trace_frame(frame, full_size, generation, view, 1.0, trace_options)
				var candidate_output := buffers.get_texture_slice(PIPELINE_SCOPE, REFLECTION_OUTPUT, view, 0, 1, 1)
				if not candidate_output.is_valid():
					warn_once("RTGI reflection candidate output is unavailable for the current frame/view.")
					reflection_state.valid = false
				elif not reflection_backend.trace(state.scene, textures.slice(0, 5), reflection_frame, frame,
						reflection_state.raw, reflection_state.raw_coverage,
						reflection_state.raw_virtual_hit, dfg, full_size):
					warn_once(reflection_backend.error)
					reflection_state.valid = false
				else:
					var signature := _reflection_signature(snapshot, [state.scene.geometry_key, state.scene.transform_key],
							frame, trace_options, reflection_amount, full_size)
					if reflection_backend.resolve(reflection_state, state.scene.sampler, frame,
							textures.slice(0, 5), generation, signature, trace_options, reflection_amount):
						if not (reflection_backend.publish_candidate(reflection_state, candidate_output, full_size) \
								and ctx.publish_reflection_candidate(&"gi", candidate_output, view)):
							warn_once("RTGI reflection candidate could not be published for the current frame/view.")
					else:
						reflection_state.valid = false

func _clear_reflection_outputs(rd: RenderingDevice, buffers: RenderSceneBuffersRD) -> void:
	if not buffers.has_texture(PIPELINE_SCOPE, REFLECTION_OUTPUT):
		return
	for view in buffers.get_view_count():
		var output := buffers.get_texture_slice(PIPELINE_SCOPE, REFLECTION_OUTPUT, view, 0, 1, 1)
		if output.is_valid():
			rd.texture_clear(output, Color(0, 0, 0, 0), 0, 1, 0, 1)

func _sweep_idle_states(rd: RenderingDevice) -> void:
	var frame := Engine.get_frames_drawn()
	var expired: Array = []
	for key in _states.keys():
		if frame - int(_states[key].get("last_seen", 0)) > 120:
			expired.append(key)
	for key in expired:
		_free_state(rd, _states[key])
		_states.erase(key)

func _create_scene_state(rd: RenderingDevice, sky_array: bool) -> Dictionary:
	var scene: Variant = SceneGPU.new()
	if not scene.initialize(rd):
		warn_once("Shared RTGI scene resources failed to initialize.")
		scene.release()
		return {}
	return {"scene": scene, "gpu": null, "diffuse": {}, "reflection": {},
			"sky_array": sky_array, "last_seen": Engine.get_frames_drawn()}

func _ensure_diffuse_gpu(rd: RenderingDevice, state: Dictionary, sky_array: bool) -> Variant:
	var gpu: Variant = state.get("gpu")
	if gpu == null:
		gpu = GPU.new()
		gpu.scene = state.scene
		if not gpu.initialize(rd, sky_array):
			warn_once(gpu.error)
			gpu.release()
			return null
		state.gpu = gpu
	return gpu

func _get_reflection_backend(rd: RenderingDevice, sky_array: bool) -> Variant:
	var key := int(sky_array)
	var backend: Variant = _reflection_backends.get(key)
	if backend == null:
		backend = ReflectionRenderer.new()
		if not backend.initialize(rd, sky_array):
			warn_once(backend.error)
			backend.release()
			return null
		_reflection_backends[key] = backend
	return backend

func _release_diffuse_state(rd: RenderingDevice, state: Dictionary) -> void:
	if state.is_empty():
		return
	var releasing: Array = state.resources.duplicate()
	releasing.reverse()
	for rid: RID in releasing:
		if rid.is_valid():
			rd.free_rid(rid)

func _free_state(rd: RenderingDevice, state: Dictionary) -> void:
	if state.is_empty():
		return
	_release_diffuse_state(rd, state.get("diffuse", {}))
	var backend: Variant = _reflection_backends.get(int(bool(state.get("sky_array", false))))
	if backend != null:
		backend.release_state(state.get("reflection", {}))
	var gpu: Variant = state.get("gpu")
	if gpu != null:
		gpu.release()
	var scene: Variant = state.get("scene")
	if scene != null:
		scene.release()

func invalidate(target: RID) -> void:
	for key in _states:
		if key[0] == target:
			_invalidate_history(_states[key], "diffuse")
			_invalidate_history(_states[key], "reflection")

func _invalidate_history(state: Dictionary, slot: String) -> void:
	var history: Dictionary = state.get(slot, {})
	if not history.is_empty():
		history.valid = false
		state[slot] = history

func warn_once(message: String) -> void:
	if message.is_empty() or _warnings.has(message):
		return
	_warnings[message] = true
	if _rtgi_diagnostics_enabled:
		var messages: Array = _rtgi_diagnostics.get("messages", [])
		if messages.size() < 32:
			messages.append(message)
			_rtgi_diagnostics.messages = messages
	push_warning("FengRTGI: " + message)

func _finite_option(options: Dictionary, key: String, fallback: float, minimum: float, maximum: float) -> float:
	var value := float(options.get(key, fallback))
	return clampf(value, minimum, maximum) if is_finite(value) else fallback

func _valid_samples(value: int) -> int:
	return value if value in [1, 2, 4] else 1

func _lighting_signature(frame: Dictionary) -> Array:
	# A realtime capture alternates radiance textures and publishes revisions in
	# separate frames. Those are content updates, not a new lighting source: a hard
	# reset here repeatedly throws away convergence while the camera stands still.
	return [frame.get("sky_light_source_owner_id", 0),
			frame.get("sky_light_source", RID()), frame.get("sky_light_source_valid", false),
			frame.get("sky_light_energy", 0.0), frame.get("sky_light_rotation", Basis.IDENTITY),
			frame.get("directional_light_signature", []), frame.get("directional_light_count", 0),
			frame.get("cloud_primary_sun_directional_index", -1)]

func _reflection_signature(snapshot: Dictionary, scene_key: Array, frame: Dictionary,
		options: Dictionary, replacement_strength: float, size: Vector2i) -> Array:
	return [snapshot.get("world_id", 0), snapshot.get("registry_epoch", 0),
		snapshot.get("snapshot_generation", 0), scene_key, _lighting_signature(frame),
		frame.get("inverse_projection_unjittered", frame.get("inverse_projection", Projection.IDENTITY)),
		frame.get("camera_generation", 0), frame.get("dfg_texture", RID()), size,
		options.get("max_distance", max_distance),
		options.get("samples_per_pixel", samples_per_pixel), replacement_strength,
		options.get("history_weight", history_weight)]

func _matrix_bytes(matrix: Projection) -> PackedByteArray:
	var values := PackedFloat32Array()
	for column in 4:
		for row in 4:
			values.append(matrix[column][row])
	return values.to_byte_array()

func _pack_trace_frame(frame: Dictionary, size: Vector2i, generation: int, view: int,
		amount: float, options: Dictionary) -> PackedByteArray:
	var bytes := _matrix_bytes(frame.get("inverse_projection", Projection.IDENTITY))
	bytes.append_array(_matrix_bytes(Projection(frame.get("camera_transform", Transform3D.IDENTITY))))
	bytes.append_array(PackedFloat32Array([size.x, size.y, frame.get("pre_exposure", 1.0),
			frame.get("scene_normalization", 1.0), frame.get("light_buffer_exposure_normalization", 1.0),
			frame.get("sky_light_energy", 0.0), frame.get("sky_captured_exposure", 1.0),
			frame.get("sky_uv_border_size", 0.0)]).to_byte_array())
	var rotation: Basis = frame.get("sky_light_rotation", Basis.IDENTITY)
	rotation = rotation.inverse()
	for column in [rotation.x, rotation.y, rotation.z]:
		bytes.append_array(PackedFloat32Array([column.x, column.y, column.z, 0.0]).to_byte_array())
	var sun := int(frame.get("cloud_primary_sun_directional_index", -1))
	if sun < 0 and int(frame.get("directional_light_count", 0)) > 0:
		sun = 0
	bytes.append_array(PackedInt32Array([sun, view, generation & 0xffffffff,
			int(bool(frame.get("sky_radiance_is_array", false)))]).to_byte_array())
	bytes.append_array(PackedFloat32Array([options.get("max_distance", max_distance), amount,
			options.get("samples_per_pixel", samples_per_pixel), options.get("history_weight", history_weight)]).to_byte_array())
	var sky_size := int(frame.get("sky_radiance_size", 1))
	var sky_max_roughness_lod := int(frame.get("sky_max_roughness_lod", 0))
	bytes.append_array(PackedInt32Array([generation >> 32, int(not bool(options.get("importance_sampling", importance_sampling))), sky_max_roughness_lod, sky_size]).to_byte_array())
	return bytes

func _texture(rd: RenderingDevice, size: Vector2i, format: int) -> RID:
	var desc := RDTextureFormat.new()
	desc.width = size.x
	desc.height = size.y
	desc.format = format
	desc.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var rid := rd.texture_create(desc, RDTextureView.new())
	if rid.is_valid():
		rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return rid

func _create_diffuse_state(rd: RenderingDevice, size: Vector2i) -> Dictionary:
	var resources: Array[RID] = []
	var raw := _texture(rd, size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	resources.append(raw)
	var hit_distance := _texture(rd, size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	resources.append(hit_distance)
	var histories: Array = []
	for history_index in 2:
		var images: Array[RID] = []
		for format in [RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				RenderingDevice.DATA_FORMAT_R32G32_SFLOAT, RenderingDevice.DATA_FORMAT_R32_SFLOAT,
				RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT]:
			var image := _texture(rd, size, format)
			images.append(image)
			resources.append(image)
		histories.append(images)
	var ubo := rd.uniform_buffer_create(240)
	resources.append(ubo)
	for rid in resources:
		if not rid.is_valid():
			_release_diffuse_state(rd, {"resources": resources})
			return {}
	return {"size": size, "raw": raw, "hit_distance": hit_distance, "history": histories, "resources": resources,
			"ubo": ubo, "ping": 0, "valid": false, "generation": -1, "revision": -1,
			"exposure": 1.0, "vp": Projection.IDENTITY}

func _resolve_diffuse(rd: RenderingDevice, sampler: RID, state: Dictionary, frame: Dictionary,
		textures: Array[RID], generation: int, revision: int, options: Dictionary) -> bool:
	var transform: Transform3D = frame.camera_transform
	var projection: Projection = frame.projection
	var vp := projection * Projection(transform.affine_inverse())
	var exposure := float(frame.get("pre_exposure", 1.0)) * float(frame.get("scene_normalization", 1.0))
	var camera_cut := bool(frame.get("camera_cut", false))
	var requested_denoiser := int(options.get("denoiser", denoiser))
	var active_denoiser := 1 if requested_denoiser == 0 and state.has("nrd_ready") and not state.nrd_ready else requested_denoiser
	var valid: bool = state.valid and state.generation + 1 == generation \
			and state.get("denoiser", active_denoiser) == active_denoiser \
			and state.revision == revision and not camera_cut and state.get("camera", -1) == frame.get("camera_generation", 0)
	var bytes := _matrix_bytes(vp.inverse())
	bytes.append_array(_matrix_bytes(state.vp))
	bytes.append_array(PackedFloat32Array([state.size.x, state.size.y,
			options.get("history_weight", history_weight), exposure / maxf(state.exposure, 1e-8),
			0.85, 0.01, 0.0001, float(valid)]).to_byte_array())
	bytes.append_array(PackedInt32Array([generation & 0xffffffff, generation >> 32, 0, 0]).to_byte_array())
	bytes.append_array(_matrix_bytes(Projection(transform)))
	if rd.buffer_update(state.ubo, 0, bytes.size(), bytes) != OK:
		state.valid = false
		return false
	if int(options.get("denoiser", denoiser)) == 0:
		if not state.has("nrd"):
			var nrd := NRDRenderer.new()
			state.nrd = nrd
			state.nrd_ready = nrd.initialize(rd, state.size)
			state.nrd_count = 0
			if not state.nrd_ready: warn_once(nrd.error)
		var nrd: RefCounted = state.nrd
		if state.nrd_ready:
			var nrd_ok: bool = nrd.resolve(state, frame, textures, generation,
					not valid or state.get("denoiser", -1) != 0, exposure,
					float(options.get("strength", strength)))
			state.resources.append_array(nrd.resources.slice(state.nrd_count))
			state.nrd_count = nrd.resources.size()
			if not nrd_ok:
				warn_once("NRD resolve failed: " + nrd.error)
				state.valid = false
				return false
			state.resolved = nrd.output
			state.valid = true
			state.generation = generation
			state.revision = revision
			state.exposure = exposure
			state.vp = vp
			state.camera = frame.get("camera_generation", 0)
			state.denoiser = 0
			return true
		# Retain ownership of partially initialized NRD resources on failure.
		state.resources.append_array(nrd.resources.slice(state.nrd_count))
		state.nrd_count = nrd.resources.size()
	var previous: Array = state.history[state.ping]
	var next_index: int = 1 - int(state.ping)
	var next: Array = state.history[next_index]
	var sampled: Array = [state.raw, previous[0], previous[1], textures[0], textures[1], previous[2], previous[3]]
	var bindings: Array[RDUniform] = []
	for index in sampled.size():
		bindings.append(U.sampled(index, sampler, sampled[index]))
	for index in 4:
		bindings.append(U.image(7 + index, next[index]))
	bindings.append(U.uniform_buffer(11, state.ubo))
	bindings.append(U.sampled(12, sampler, textures[2]))
	bindings.append(U.sampled(13, sampler, textures[3]))
	bindings.append(U.sampled(14, sampler, previous[4]))
	bindings.append(U.image(15, next[4]))
	if not _dispatch(rd, _diffuse_temporal_shader, _diffuse_temporal_pipeline, bindings, state.size):
		state.valid = false
		return false
	state.ping = next_index
	state.resolved = next[0]
	state.denoiser = 1
	state.valid = true
	state.generation = generation
	state.revision = revision
	state.exposure = exposure
	state.vp = vp
	state.camera = frame.get("camera_generation", 0)
	return true

func _dispatch(rd: RenderingDevice, shader: RID, pipeline: RID, bindings: Array[RDUniform], size: Vector2i) -> bool:
	var uniform_set := rd.uniform_set_create(bindings, shader, 0)
	if not uniform_set.is_valid():
		return false
	var list := rd.compute_list_begin()
	if list < 0:
		rd.free_rid(uniform_set)
		return false
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	rd.compute_list_end()
	rd.free_rid(uniform_set)
	return true

func _measure_rgba16f_texture(rd: RenderingDevice, texture: RID, size: Vector2i) -> Dictionary:
	if not texture.is_valid() or size.x <= 0 or size.y <= 0:
		return {"valid": false, "reason": "invalid texture or size"}
	var bytes := rd.texture_get_data(texture, 0)
	if bytes.is_empty():
		return {"valid": false, "reason": "empty GPU readback"}
	var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAH, bytes)
	if image == null or image.is_empty():
		return {"valid": false, "reason": "RGBA16F image decode failed", "bytes": bytes.size()}
	var result := _measure_rgba16f_image(image)
	result["byte_count"] = bytes.size()
	return result

func _read_rgba16f_image(rd: RenderingDevice, texture: RID, size: Vector2i) -> Image:
	if not texture.is_valid() or size.x <= 0 or size.y <= 0:
		return null
	var bytes := rd.texture_get_data(texture, 0)
	if bytes.is_empty():
		return null
	var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAH, bytes)
	return image if image != null and not image.is_empty() else null

func _measure_rgba16f_image(image: Image) -> Dictionary:
	if image == null or image.is_empty():
		return {"valid": false, "reason": "empty or invalid RGBA16F image"}
	var size := image.get_size()
	var sum := Vector3.ZERO
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	var alpha_sum := 0.0
	var alpha_minimum := INF
	var alpha_maximum := -INF
	var nonzero_pixels := 0
	var nonfinite_pixels := 0
	var finite_pixels := 0
	for y in size.y:
		for x in size.x:
			var pixel := image.get_pixel(x, y)
			if not is_finite(pixel.r) or not is_finite(pixel.g) or not is_finite(pixel.b) or not is_finite(pixel.a):
				nonfinite_pixels += 1
				continue
			var rgb := Vector3(pixel.r, pixel.g, pixel.b)
			sum += rgb
			minimum = Vector3(minf(minimum.x, rgb.x), minf(minimum.y, rgb.y), minf(minimum.z, rgb.z))
			maximum = Vector3(maxf(maximum.x, rgb.x), maxf(maximum.y, rgb.y), maxf(maximum.z, rgb.z))
			alpha_sum += pixel.a
			alpha_minimum = minf(alpha_minimum, pixel.a)
			alpha_maximum = maxf(alpha_maximum, pixel.a)
			finite_pixels += 1
			if maxf(rgb.x, maxf(rgb.y, rgb.z)) > 1e-6:
				nonzero_pixels += 1
	if finite_pixels == 0:
		return {"valid": false, "reason": "no finite RGBA16F pixels", "size": [size.x, size.y],
			"nonfinite_pixel_count": nonfinite_pixels}
	var mean := sum / float(finite_pixels)
	var max_component := maxf(0.0, maxf(maximum.x, maxf(maximum.y, maximum.z)))
	var max_absolute_component := maxf(maxf(absf(minimum.x), absf(maximum.x)),
			maxf(maxf(absf(minimum.y), absf(maximum.y)), maxf(absf(minimum.z), absf(maximum.z))))
	return {"valid": true, "size": [size.x, size.y], "mean_rgb": [mean.x, mean.y, mean.z],
		"min_rgb": [minimum.x, minimum.y, minimum.z], "max_rgb": [maximum.x, maximum.y, maximum.z],
		"mean_alpha": alpha_sum / float(finite_pixels), "min_alpha": alpha_minimum, "max_alpha": alpha_maximum,
		"max_component": max_component, "max_absolute_component": max_absolute_component,
		"nonzero_pixel_count": nonzero_pixels,
		"nonzero_pixel_ratio": float(nonzero_pixels) / float(finite_pixels),
		"finite_pixel_count": finite_pixels, "nonfinite_pixel_count": nonfinite_pixels}

func _read_depth_mask_image(rd: RenderingDevice, texture: RID, size: Vector2i) -> Dictionary:
	if not texture.is_valid() or size.x <= 0 or size.y <= 0:
		return {"valid": false, "reason": "invalid depth texture or size"}
	var texture_format: RDTextureFormat = rd.texture_get_format(texture)
	if texture_format.format not in [RenderingDevice.DATA_FORMAT_D32_SFLOAT, RenderingDevice.DATA_FORMAT_R32_SFLOAT]:
		return {"valid": false, "reason": "unsupported sampled depth format", "format": int(texture_format.format)}
	var bytes := rd.texture_get_data(texture, 0)
	if bytes.is_empty() or bytes.size() != size.x * size.y * 4:
		return {"valid": false, "reason": "depth readback size mismatch", "format": int(texture_format.format),
			"byte_count": bytes.size()}
	var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RF, bytes)
	if image == null or image.is_empty():
		return {"valid": false, "reason": "depth R32F image decode failed", "format": int(texture_format.format)}
	return {"valid": true, "image": image, "format": int(texture_format.format), "byte_count": bytes.size()}

func _copy_sampled_texture_to_readback(rd: RenderingDevice, sampler: RID, source: RID,
		destination: RID, size: Vector2i) -> bool:
	if not source.is_valid() or not destination.is_valid() or not _scene_color_readback_pipeline.is_valid():
		return false
	return _dispatch(rd, _scene_color_readback_shader, _scene_color_readback_pipeline,
		[U.sampled(0, sampler, source), U.image(1, destination)], size)

func _measure_scene_color_composite(before: Image, after: Image, depth_capture: Dictionary,
		color_target_id: int, color_format: int) -> Dictionary:
	if before == null or after == null or before.is_empty() or after.is_empty() \
			or before.get_size() != after.get_size():
		return {"valid": false, "reason": "scene-color before/after readback is invalid or mismatched",
			"color_target_id": color_target_id, "color_format": color_format}
	var size := before.get_size()
	var depth: Image
	if bool(depth_capture.get("valid", false)):
		depth = depth_capture.get("image") as Image
	if depth != null and depth.get_size() != size:
		depth = null
	var delta_sum_all := Vector3.ZERO
	var delta_sum_surface := Vector3.ZERO
	var finite_count := 0
	var surface_count := 0
	var changed_1e5 := 0
	var changed_1e4 := 0
	var changed_1e3 := 0
	var max_delta_all := 0.0
	var max_delta_surface := 0.0
	for y in size.y:
		for x in size.x:
			var a := before.get_pixel(x, y)
			var b := after.get_pixel(x, y)
			if not is_finite(a.r) or not is_finite(a.g) or not is_finite(a.b) \
					or not is_finite(b.r) or not is_finite(b.g) or not is_finite(b.b):
				continue
			var delta := Vector3(absf(b.r - a.r), absf(b.g - a.g), absf(b.b - a.b))
			var magnitude := maxf(delta.x, maxf(delta.y, delta.z))
			delta_sum_all += delta
			finite_count += 1
			max_delta_all = maxf(max_delta_all, magnitude)
			if magnitude > 1e-5:
				changed_1e5 += 1
			if magnitude > 1e-4:
				changed_1e4 += 1
			if magnitude > 1e-3:
				changed_1e3 += 1
			if depth != null and depth.get_pixel(x, y).r > 0.0:
				delta_sum_surface += delta
				surface_count += 1
				max_delta_surface = maxf(max_delta_surface, magnitude)
	var all_denominator := float(maxi(1, finite_count))
	var surface_denominator := float(maxi(1, surface_count))
	var mean_all := delta_sum_all / all_denominator
	var mean_surface := delta_sum_surface / surface_denominator
	return {"valid": finite_count > 0, "size": [size.x, size.y], "color_target_id": color_target_id,
		"color_format": color_format,
		"before": _measure_rgba16f_image(before), "after": _measure_rgba16f_image(after),
		"depth_mask": {"valid": depth != null, "format": int(depth_capture.get("format", -1)),
			"positive_pixel_count": surface_count, "positive_pixel_ratio": float(surface_count) / all_denominator,
			"reason": str(depth_capture.get("reason", ""))},
		"mean_absolute_rgb_delta_all": [mean_all.x, mean_all.y, mean_all.z],
		"mean_absolute_rgb_delta_depth_positive": [mean_surface.x, mean_surface.y, mean_surface.z],
		"max_absolute_component_delta_all": max_delta_all,
		"max_absolute_component_delta_depth_positive": max_delta_surface,
		"changed_pixel_count_over_1e-5": changed_1e5,
		"changed_pixel_count_over_1e-4": changed_1e4,
		"changed_pixel_count_over_1e-3": changed_1e3,
		"finite_pixel_count": finite_count}

func ensure_diffuse_compute(rd: RenderingDevice) -> bool:
	if _diffuse_temporal_pipeline.is_valid() and _diffuse_composite_pipeline.is_valid():
		return true
	for shader_name in ["gi_temporal", "gi_composite", "gi_scene_color_readback"]:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string("res://addons/feng-raytracing/shaders/" + shader_name + ".glslinc")
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			warn_once(spirv.compile_error_compute)
			return false
		var shader := rd.shader_create_from_spirv(spirv, shader_name)
		var pipeline := rd.compute_pipeline_create(shader)
		if not shader.is_valid() or not pipeline.is_valid():
			warn_once(shader_name + " pipeline creation failed")
			return false
		_shared.append_array([shader, pipeline])
		match shader_name:
			"gi_temporal":
				_diffuse_temporal_shader = shader
				_diffuse_temporal_pipeline = pipeline
			"gi_composite":
				_diffuse_composite_shader = shader
				_diffuse_composite_pipeline = pipeline
			"gi_scene_color_readback":
				_scene_color_readback_shader = shader
				_scene_color_readback_pipeline = pipeline
	return _diffuse_temporal_pipeline.is_valid() and _diffuse_composite_pipeline.is_valid() \
			and _scene_color_readback_pipeline.is_valid()

func refresh_owned() -> void:
	var resources: Array[RID] = []
	resources.append_array(_shared)
	for backend in _reflection_backends.values():
		resources.append_array(backend.all_rids())
	for state in _states.values():
		if state.is_empty():
			continue
		if not state.diffuse.is_empty():
			resources.append_array(state.diffuse.resources)
		var reflection_backend: Variant = _reflection_backends.get(int(bool(state.get("sky_array", false))))
		if reflection_backend != null and not state.reflection.is_empty():
			resources.append_array(state.reflection.resources)
		if state.gpu != null:
			resources.append_array(state.gpu.all_rids())
		resources.append_array(state.scene.all_rids())
	resources.reverse()
	_replace_owned_rid_snapshot(resources)

func _take_owned_rids() -> Array[RID]:
	var result := _shared.duplicate()
	_shared.clear()
	for backend in _reflection_backends.values():
		result.append_array(backend.all_rids())
	_reflection_backends.clear()
	for state in _states.values():
		if not state.diffuse.is_empty():
			result.append_array(state.diffuse.resources)
		if not state.reflection.is_empty():
			result.append_array(state.reflection.resources)
		if state.gpu != null:
			result.append_array(state.gpu.all_rids())
		result.append_array(state.scene.all_rids())
	_states.clear()
	_diffuse_temporal_shader = RID()
	_diffuse_temporal_pipeline = RID()
	_diffuse_composite_shader = RID()
	_diffuse_composite_pipeline = RID()
	_scene_color_readback_shader = RID()
	_scene_color_readback_pipeline = RID()
	result.reverse()
	return result
