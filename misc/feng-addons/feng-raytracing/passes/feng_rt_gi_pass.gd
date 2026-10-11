@tool
class_name FengRTGIPass
extends FengPass
## Hardware ray traced diffuse GI and an independently enabled specular replacement.
const Runtime = preload("../scene/feng_rt_gi_runtime.gd")
const GPU = preload("../rendering/rt_gi_gpu.gd")
const SceneGPU = preload("../rendering/rt_gi_scene_gpu.gd")
const ReflectionRenderer = preload("../rendering/rt_gi_reflections.gd")
const NRDRenderer = preload("../rendering/rt_gi_nrd.gd")
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const Selection = preload("res://addons/feng-render-pipeline/pipeline/indirect_gi_selection.gd")
const NativeSpec = preload("res://addons/feng-render-pipeline/pipeline/native_spec.gd")

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
var _reflection_backends: Dictionary = {} # native sky texture type -> independent pass backend.

func _init() -> void:
	stage = 8 # Post Lighting, before Sky, Transparent and the temporal/post transforms.
	resource_name = "Hardware RTGI"
	access_resolved_color = true
	access_resolved_depth = true
	needs_normal_roughness = true
	for source in [FengPassTexture.Source.DEPTH, FengPassTexture.Source.NORMAL_ROUGHNESS,
			FengPassTexture.Source.ALBEDO, FengPassTexture.Source.ORM, FengPassTexture.Source.EMISSION]:
		_add_input(source)
	_add_input(FengPassTexture.Source.INDIRECT_SPECULAR)
	_sky_input = FengPassTexture.new()
	_sky_input.source = FengPassTexture.Source.CUSTOM
	_sky_input.custom_scope = &"frp_clustered"
	_sky_input.custom_name = &"sky_light_diffuse"
	_start_runtime.call_deferred()

func _add_input(source: int) -> void:
	var input := FengPassTexture.new()
	input.source = source
	input.binding = inputs.size() + 1
	inputs.append(input)

func _start_runtime() -> void:
	Runtime.start()

func can_share_view_execution() -> bool:
	return true

func get_indirect_gi_kind() -> StringName:
	# Only diffuse ownership is planned here. Reflections remain independent of MagicGI.
	return Selection.KIND_RT

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
	var options := get_resolved_parameters(ctx)
	var diffuse_amount := float(options.get("strength", 0.0))
	var diffuse_active := Selection.is_owner(ctx, String(get_parameter_key()), Selection.KIND_RT, false) \
			and is_finite(diffuse_amount) and diffuse_amount > 0.0
	var reflection_active := _reflection_slot_active(ctx, options)
	if not diffuse_active and not reflection_active:
		return
	var buffers := ctx.get_render_scene_buffers()
	if buffers != null:
		Runtime.request_target(buffers.get_render_target())
	if diffuse_active:
		ctx.request_sky_light_diffuse()
	if reflection_active:
		ctx.request_indirect_specular()

func _frp_execute(ctx: FRPPassContext) -> void:
	_execute_frame(ctx)
	refresh_owned()

func _execute_frame(ctx: FRPPassContext) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	_sweep_idle_states(rd)
	var buffers := ctx.get_render_scene_buffers()
	if buffers == null:
		return
	var target := buffers.get_render_target()
	if not target.is_valid():
		return
	var options := get_resolved_parameters(ctx)
	var diffuse_amount := float(options.get("strength", 0.0))
	var diffuse_active := Selection.is_owner(ctx, String(get_parameter_key()), Selection.KIND_RT, false) \
			and is_finite(diffuse_amount) and diffuse_amount > 0.0
	var reflection_amount := float(options.get("reflection_strength", 0.0))
	var reflection_active := _reflection_slot_active(ctx, options)
	if not diffuse_active and not reflection_active:
		return
	if not rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE):
		warn_once("Hardware RT pipelines are unavailable; native diffuse and specular lighting remain active.")
		invalidate(target)
		return
	Runtime.request_target(target)
	var snapshot := Runtime.snapshot_for_target(target)
	if not bool(snapshot.get("valid", false)):
		var reasons: Array = snapshot.get("unsupported_reasons", [])
		if not reasons.is_empty():
			warn_once("Unsupported scene geometry/material: " + str(reasons[0]) + "; native lighting remains active.")
		invalidate(target)
		return
	if diffuse_active and not ensure_diffuse_compute(rd):
		diffuse_active = false
	var full_size: Vector2i = buffers.get_internal_size()
	for view in buffers.get_view_count():
		var frame: Dictionary = ctx.get_volume_frame_inputs(view)
		if frame.is_empty():
			continue
		var sky_array := bool(frame.get("sky_radiance_is_array", false))
		var key: Array = [target, view]
		var state: Dictionary = _states.get(key, {})
		if state.is_empty():
			state = _create_scene_state(rd, sky_array)
			if state.is_empty():
				continue
			_states[key] = state
		elif bool(state.get("sky_array", false)) != sky_array:
			_free_state(rd, state)
			state = _create_scene_state(rd, sky_array)
			if state.is_empty():
				_states.erase(key)
				continue
			_states[key] = state
		state.last_seen = Engine.get_frames_drawn()
		var view_diffuse_active := diffuse_active
		var view_reflection_active := reflection_active
		var textures: Array[RID] = []
		for declaration in inputs:
			textures.append(declaration.get_texture(buffers, view))
		if textures.size() < 6:
			continue
		var sky_diffuse := _sky_input.get_texture(buffers, view) if view_diffuse_active else RID()
		if view_diffuse_active and not sky_diffuse.is_valid():
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
			_invalidate_history(state, "diffuse")
			_invalidate_history(state, "reflection")
			continue
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
				if gpu.trace(textures.slice(0, 4), diffuse_frame, frame, state.diffuse.raw, dfg, diffuse_size, state.diffuse.hit_distance):
					var diffuse_revision := hash([snapshot.get("registry_epoch", 0), snapshot.get("snapshot_generation", 0),
							gpu.scene.geometry_key, gpu.scene.transform_key, trace_options.get("max_distance"), diffuse_amount,
							trace_options.get("samples_per_pixel"), _lighting_signature(frame)])
					if _resolve_diffuse(rd, state.scene.sampler, state.diffuse, frame, textures, generation,
							diffuse_revision, trace_options):
						var history: Array = state.diffuse.history[state.diffuse.ping]
						_dispatch(rd, _diffuse_composite_shader, _diffuse_composite_pipeline,
								[U.image(0, buffers.get_color_layer(view)), U.sampled(1, state.scene.sampler, state.diffuse.get("resolved", history[0])),
								U.sampled(2, state.scene.sampler, sky_diffuse), U.sampled(3, state.scene.sampler, textures[0]),
								U.sampled(4, state.scene.sampler, history[2]),
								U.sampled(5, state.scene.sampler, textures[1]), U.sampled(6, state.scene.sampler, history[3]),
								U.sampled(7, state.scene.sampler, textures[2]), U.sampled(8, state.scene.sampler, textures[3]),
								U.sampled(9, state.scene.sampler, history[4]), U.uniform_buffer(10, state.diffuse.ubo)], full_size)
				else:
					warn_once(gpu.error)
					state.diffuse.valid = false
		if view_reflection_active:
			var reflection_state: Dictionary = state.reflection
			if reflection_state.is_empty() or reflection_state.size != full_size:
				reflection_backend.release_state(reflection_state)
				reflection_state = reflection_backend.create_state(full_size)
				state.reflection = reflection_state
			if not reflection_state.is_empty():
				var reflection_frame := _pack_trace_frame(frame, full_size, generation, view, 1.0, trace_options)
				if reflection_backend.trace(state.scene, textures.slice(0, 5), reflection_frame, frame,
						reflection_state.raw, dfg, full_size):
						var signature := _reflection_signature(snapshot, [state.scene.geometry_key, state.scene.transform_key],
								frame, trace_options, reflection_amount, full_size)
						if reflection_backend.resolve(reflection_state, state.scene.sampler, frame,
								textures.slice(0, 5), generation, signature, trace_options, reflection_amount):
							var native_indirect: RID = textures[5]
							var composite_target: RID = ctx.get_indirect_specular_composite_target(view)
							if reflection_backend.composite(reflection_state, composite_target, native_indirect,
									state.scene.sampler, full_size, reflection_amount):
								ctx.mark_indirect_specular_modified(view)
						else:
							reflection_state.valid = false
				else:
					warn_once(reflection_backend.error)
					reflection_state.valid = false
		state.last_seen = Engine.get_frames_drawn()
	refresh_owned()

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
		frame.get("light_buffer_exposure_normalization", 1.0),
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
			"exposure": 1.0, "vp": Projection.IDENTITY, "last_seen": Engine.get_frames_drawn()}

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
			state.last_seen = Engine.get_frames_drawn()
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
	state.last_seen = Engine.get_frames_drawn()
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

func ensure_diffuse_compute(rd: RenderingDevice) -> bool:
	if _diffuse_temporal_pipeline.is_valid() and _diffuse_composite_pipeline.is_valid():
		return true
	for shader_name in ["gi_temporal", "gi_composite"]:
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
		if shader_name == "gi_temporal":
			_diffuse_temporal_shader = shader
			_diffuse_temporal_pipeline = pipeline
		else:
			_diffuse_composite_shader = shader
			_diffuse_composite_pipeline = pipeline
	return _diffuse_temporal_pipeline.is_valid() and _diffuse_composite_pipeline.is_valid()

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
	result.reverse()
	return result
