@tool
extends RefCounted
## World/volume-owned GPU surfel cache used by FengMagicGIPass.
##
## All persistent RIDs are owned by this helper. Frame light buffers and GBuffer
## textures are borrowed for the duration of one render callback only.

const U = preload("../rd/uniforms.gd")
const ProbeField = preload("magic_gi_surfel_probe_field.gd")
const AdaptiveLayout = preload("magic_gi_surfel_adaptive_layout.gd")
const SCENE_GPU_PATH := "res://addons/feng-raytracing/rendering/rt_gi_scene_gpu.gd"
const RAY_SHADER_DIR := "res://addons/feng-raytracing/shaders/"
const SHADER_DIR := "res://addons/feng-render-pipeline/library/magic-gi/surfel/"
const SURFEL_CACHE_GLSL := SHADER_DIR + "gi_surfel_cache.glslinc"
const SURFEL_CACHE_HLSL := SHADER_DIR + "gi_surfel_cache.hlslinc"
const DIRECT_GLSL := SHADER_DIR + "surfel_direct_lighting.glslinc"
const DIRECT_HLSL := SHADER_DIR + "surfel_direct_lighting.hlslinc"
const SURFEL_GATHER_GLSL := SHADER_DIR + "surfel_gather.glslinc"
const SURFEL_GATHER_HLSL := SHADER_DIR + "surfel_gather.hlslinc"
const SURFEL_FILTER_GLSL := SHADER_DIR + "surfel_filter.glslinc"
const SURFEL_FILTER_HLSL := SHADER_DIR + "surfel_filter.hlslinc"
const SURFEL_PROBE_GLSL := SHADER_DIR + "gi_surfel_probe.glslinc"
const SURFEL_PROBE_HLSL := SHADER_DIR + "gi_surfel_probe.hlslinc"
const LOD_SUMMARY_SHADER := "magic_gi_surfel_lod_summary.glsl"
const MAX_CACHE_STATES := 16
const RECORD_BYTES := 80
const RESPONSE_BYTES := 16
const CONFIG_BYTES := 224
const TRACKING_BYTES := 16
const GUIDE_BYTES := 20
const FREE_INDEX_BYTES := 4
const COUNTER_BYTES := 32 # Words 4-7 persist ring, probe, free-stack, and maintenance state.
const MAINTENANCE_BATCH := 2048
const SEED_SHADER := "magic_gi_surfel_seed.glsl"
# Keep these values in sync with the compile-time branches in both raygen sources.
const RAYGEN_MODE_UPDATE := 0
const RAYGEN_MODE_GATHER := 1
const RAYGEN_MODE_FILTER := 2
const RAYGEN_MODE_NRD_GATHER := 3
const RAYGEN_MODE_PROBE := 4
const RAYGEN_MODE_COUNT := 5

var rd: RenderingDevice
var error := ""
var _states: Dictionary = {} # world_id/cache_key -> immutable layout + persistent GPU state.
var _backends: Dictionary = {} # sky-array/mode -> independent ray pipeline, SBT and shaders.
var _compute: Dictionary = {} # seed/commit compute shader and pipeline.
var _owned_shared: Array[RID] = []
var _cache_clock := 0
var resource_revision := 0
var _scene_gpu_script: Script
var _scene_gpu_script_checked := false

func initialize(device: RenderingDevice) -> bool:
	if device == null:
		return _fail("Surfel RenderingDevice is unavailable")
	var seed_pipeline: RID = _compute.get("seed_pipeline", RID())
	var commit_pipeline: RID = _compute.get("commit_pipeline", RID())
	if rd == device and seed_pipeline.is_valid() and commit_pipeline.is_valid():
		return true
	if rd != null and rd != device:
		release_all()
	rd = device
	error = ""
	return _ensure_compute("seed") and _ensure_compute("commit")

func release_all() -> void:
	if rd != null:
		for state in _states.values():
			_free_state(state)
		for backend in _backends.values():
			_free_rids(backend.get("owned", []))
		_free_rids(_owned_shared)
	_states.clear()
	_backends.clear()
	_compute.clear()
	_owned_shared.clear()
	rd = null
	resource_revision += 1

func take_owned_rids() -> Array[RID]:
	var result := _release_order_rids()
	_states.clear()
	_backends.clear()
	_compute.clear()
	_owned_shared.clear()
	resource_revision += 1
	return result

func get_resource_revision() -> int:
	return resource_revision

func get_all_rids() -> Array[RID]:
	return _release_order_rids()

func _release_order_rids() -> Array[RID]:
	var result: Array[RID] = []
	# RenderingDevice recursively frees dependent RIDs when a dependency is freed.
	# Return dependent pipelines/SBTs before the shaders and other resources they use.
	# Keep this order for both the live snapshot and detached cleanup inventory: base
	# pass finalization may need the stored snapshot after derived properties vanish.
	result.append_array(_reversed_rids(_owned_shared))
	for backend in _backends.values():
		result.append_array(_reversed_rids(backend.get("owned", [])))
	for state in _states.values():
		var scene: Variant = state.get("scene")
		if scene != null:
			result.append_array(_reversed_rids(scene.all_rids()))
		var probe_field: Variant = state.get("probe_field")
		if probe_field != null:
			result.append_array(_reversed_rids(probe_field.get_all_rids()))
		result.append_array(_reversed_rids(state.get("owned", [])))
	return _unique_rids(result)

func is_cache_ready(snapshot: Dictionary) -> bool:
	var key := _state_key(snapshot)
	if key.is_empty() or not _states.has(key):
		return false
	var state: Dictionary = _states[key]
	return not bool(state.get("needs_reset", false)) \
			and int(state.get("gpu_positive_updates", 0)) > 0 \
			and bool(state.get("scene_ready", false))

## Optional readback stalls the RenderingDevice and is intended for acceptance diagnostics only.
func get_debug_info(cache_key := "", readback_counters := false) -> Dictionary:
	var selected := cache_key
	if selected.is_empty() and not _states.is_empty():
		selected = str(_states.keys()[0])
	if not _states.has(selected):
		return {"cache_key": selected, "available": false}
	var state: Dictionary = _states[selected]
	var gpu_counts := PackedInt32Array()
	var lod_presence_mask := -1
	if readback_counters and rd != null \
			and int(state.get("counter_bytes", 0)) == COUNTER_BYTES:
		var bytes := rd.buffer_get_data(state.counters, 0, COUNTER_BYTES)
		if bytes.size() >= COUNTER_BYTES:
			gpu_counts = bytes.to_int32_array()
			state.gpu_active_count = gpu_counts[1]
			state.gpu_positive_updates = gpu_counts[2]
			state.gpu_seeded_this_frame = gpu_counts[3]
			state.gpu_background_cursor = gpu_counts[4]
			_states[selected] = state
		var presence_bytes := rd.buffer_get_data(state.lod_presence, 0, 4)
		if presence_bytes.size() >= 4:
			lod_presence_mask = presence_bytes.decode_u32(0)
	var seeded_views_value: Variant = state.get("seeded_views", {})
	var seeded_view_count: int = seeded_views_value.size() if seeded_views_value is Dictionary else 0
	return {"cache_key": str(state.get("cache_key", selected)),
		"available": true, "ready": not bool(state.get("needs_reset", false)) \
			and int(state.get("gpu_positive_updates", 0)) > 0 \
			and bool(state.get("scene_ready", false)),
		"needs_reset": bool(state.get("needs_reset", false)),
		"capacity": int(state.get("capacity", 0)), "hash_capacity": int(state.get("hash_capacity", 0)),
		"record_bytes": int(state.get("record_bytes", 0)),
		"response_bytes": int(state.get("response_bytes", 0)),
		"counter_bytes": int(state.get("counter_bytes", 0)),
		"lod_presence_bytes": int(state.get("lod_presence_bytes", 0)),
		"lod_presence_mask": lod_presence_mask,
		"probe_field_bytes": int(state.get("probe_field_bytes", 0)),
		"filtered_bytes": int(state.get("filtered_bytes", 0)),
		"statistics_bytes": int(state.get("statistics_bytes", 0)),
		"cache_bytes": int(state.get("cache_bytes", 0)),
		"layout_version": int(state.get("layout_version", -1)),
		"world_generation": int(state.get("world_generation", -1)),
		"last_update_frame": int(state.get("last_update_frame", -1)),
		"last_seed_frame": int(state.get("last_seed_frame", -1)),
		"seeded_view_count": seeded_view_count,
		"diagnostic_readback": readback_counters and not gpu_counts.is_empty(),
		"gpu_active_count": int(state.get("gpu_active_count", -1)),
		"gpu_positive_updates": int(state.get("gpu_positive_updates", -1)),
		"gpu_seeded_this_frame": int(state.get("gpu_seeded_this_frame", -1)),
		"gpu_background_cursor": int(state.get("gpu_background_cursor", -1)),
		"dispatch_count": int(state.get("dispatch_count", 0)),
		"last_error": str(state.get("error", ""))}

func render(device: RenderingDevice, snapshot: Dictionary, frame: Dictionary,
		textures: Array[RID], color: RID,
		output: RID, sky_diffuse: RID, diffuse_ao: RID, size: Vector2i,
		strength: float, replacement_enabled: bool, frame_token: int,
		gather_targets: Dictionary = {}) -> bool:
	error = ""
	if not initialize(device):
		return _fail(error if not error.is_empty() else "Surfel RenderingDevice is unavailable")
	if textures.size() < 4 or not color.is_valid() or not output.is_valid():
		return _fail("Surfel GBuffer or output attachment is unavailable")
	if not bool(snapshot.get("surfel", false)) or not bool(snapshot.get("valid", false)):
		return _fail(_snapshot_failure(snapshot))
	var settings_value: Variant = snapshot.get("surfel_settings", {})
	var settings: Dictionary = settings_value if settings_value is Dictionary else {}
	var radius := _finite_range(settings.get("surfel_radius", 0.15), 0.15, 0.001, 64.0)
	var capacity := clampi(int(settings.get("max_surfels", 65536)), 1024, 262144)
	var updates := clampi(int(settings.get("updates_per_frame", 2048)), 1, capacity)
	var rays := clampi(int(settings.get("rays_per_surfel", 4)), 1, 32)
	var adaptive_enabled := bool(settings.get("adaptive_distribution_enabled", true))
	var guiding_enabled := bool(settings.get("ray_guiding_enabled", true))
	var guide_cosine_floor := _finite_range(settings.get("guide_cosine_floor", 0.5), 0.5, 0.25, 1.0)
	var probe_enabled := bool(settings.get("probe_fallback_enabled", true))
	var probe_budget := _probe_reservation(updates, rays, probe_enabled)
	var effective_updates := int(probe_budget.effective_updates)
	var probe_ray_budget := int(probe_budget.max_probe_rays)
	var max_distance := _finite_range(settings.get("max_ray_distance", 128.0), 128.0, 0.1, 4096.0)
	var history_weight: float = _finite_range(settings.get("history_weight", 0.9), 0.9, 0.0, 0.99)
	var debug_view := clampi(int(settings.get("debug_view", 0)), 0, 3)
	var cache_key := _state_key(snapshot)
	if cache_key.is_empty():
		return _fail("Surfel cache key is unavailable")
	var layout_version := int(snapshot.get("layout_version", snapshot.get("version", -1)))
	var world_generation := int(snapshot.get("world_generation", 0))
	var registry_epoch := int(snapshot.get("registry_epoch", 0))
	var owner_transform_value: Variant = snapshot.get("owner_transform", Transform3D.IDENTITY)
	var owner_size_value: Variant = snapshot.get("owner_size", Vector3.ZERO)
	if not owner_transform_value is Transform3D or not owner_size_value is Vector3 \
			or owner_size_value.x <= 0.0 or owner_size_value.y <= 0.0 or owner_size_value.z <= 0.0:
		return _fail("Surfel volume bounds are invalid")
	var frame_token_u32 := frame_token & 0xffffffff
	var light_counts := PackedInt32Array([
		clampi(int(frame.get("directional_light_count", 0)), 0, 8),
		clampi(int(frame.get("omni_light_count", 0)), 0, 65535),
		clampi(int(frame.get("spot_light_count", 0)), 0, 65535),
		clampi(int(frame.get("area_light_count", 0)), 0, 65535)])
	var sky_array := bool(frame.get("sky_radiance_is_array", false))
	var state := _ensure_state(cache_key, snapshot, capacity, layout_version,
		world_generation, registry_epoch, sky_array)
	if state.is_empty():
		return _fail(error if not error.is_empty() else "Surfel cache allocation failed")
	state.radius = radius
	if probe_ray_budget > 0 and not _ensure_compute("probe_commit"):
		return _fail(error if not error.is_empty() else "Surfel probe cursor pipeline is unavailable")
	var gather_mode := RAYGEN_MODE_GATHER
	var gather_size := size
	var gather_output := output
	var gather_final_output := output
	var gather_auxiliary := output
	if not gather_targets.is_empty():
		var raw_value: Variant = gather_targets.get("raw", RID())
		var auxiliary_value: Variant = gather_targets.get("auxiliary", RID())
		var target_size_value: Variant = gather_targets.get("size", Vector2i.ZERO)
		if raw_value is RID and auxiliary_value is RID and target_size_value is Vector2i \
				and raw_value.is_valid() and auxiliary_value.is_valid() \
				and target_size_value.x > 0 and target_size_value.y > 0:
			gather_mode = RAYGEN_MODE_NRD_GATHER
			gather_size = target_size_value
			gather_output = raw_value
			gather_auxiliary = auxiliary_value
		else:
			return _fail("Surfel NRD gather targets are invalid")
	var backends := _ensure_backends(sky_array, gather_mode, probe_ray_budget > 0)
	if backends.is_empty():
		return _fail(error if not error.is_empty() else "Surfel ray pipeline is unavailable")
	var update_backend: Dictionary = backends[RAYGEN_MODE_UPDATE]
	var scene: Variant = state.get("scene")
	if scene == null:
		return _fail("Surfel TLAS is unavailable")
	var scene_rids_before: Array[RID] = scene.all_rids()
	var scene_synced: bool = bool(scene.sync_scene(snapshot, int(update_backend.get("sbt_range", 0))))
	var scene_rids_after: Array[RID] = scene.all_rids()
	if scene_rids_before != scene_rids_after:
		# FengPass keeps an owned-only RID snapshot between callbacks. SceneGPU may
		# release and replace TLAS/BLAS/geometry RIDs inside sync_scene, so refresh
		# that inventory after this render callback completes.
		resource_revision += 1
	if not scene_synced:
		state.error = scene.error if scene != null else "Surfel TLAS is unavailable"
		return _fail(str(state.error))
	state.scene_ready = true
	state.sky_array = sky_array
	var tracking_revision := _scene_tracking_revision(scene)
	var surface_count := _scene_surface_count(scene)
	if tracking_revision < 0 or surface_count < 0 or not _scene_tracking_buffer(scene).is_valid():
		return _fail("SceneGPU SurfaceTracking resources are unavailable")
	state.surface_tracking_revision = tracking_revision
	state.adaptive_enabled = adaptive_enabled
	state.guiding_enabled = guiding_enabled
	state.guide_cosine_floor = guide_cosine_floor
	state.seed_work_count = AdaptiveLayout.seed_work_count(updates, size, adaptive_enabled)
	var bounds: Transform3D = owner_transform_value
	var frame_bytes := _pack_frame(frame, size, max_distance, rays,
		int(state.get("update_cursor", 0)), frame_token_u32, sky_array)
	var config_bytes := _pack_config(bounds, owner_size_value, radius, capacity,
		int(state.hash_capacity), updates, frame_token_u32, light_counts,
		max_distance, history_weight, int(state.seed_work_count), debug_view,
		adaptive_enabled, guiding_enabled, guide_cosine_floor,
		int(state.get("seed_cursor", 0)),
		AdaptiveLayout.tile_count(size), surface_count)
	if frame_bytes.size() != 256 or config_bytes.size() != CONFIG_BYTES \
			or rd.buffer_update(state.frame_buffer, 0, frame_bytes.size(), frame_bytes) != OK \
			or rd.buffer_update(state.config_buffer, 0, config_bytes.size(), config_bytes) != OK:
		return _fail("Surfel frame/configuration upload failed")
	var probe_field: Variant = state.get("probe_field")
	if probe_field == null:
		return _fail("Surfel probe field component is unavailable")
	if int(state.get("last_probe_layout_frame", -1)) != frame_token:
		var camera_value: Variant = frame.get("camera_transform", Transform3D.IDENTITY)
		if not camera_value is Transform3D or not probe_field.configure(bounds,
				owner_size_value, camera_value, radius, updates, effective_updates,
				probe_ray_budget, rays, probe_enabled):
			return _fail(str(probe_field.error))
		state.last_probe_layout_frame = frame_token
	var textures_ok := true
	for rid in textures.slice(0, 4):
		textures_ok = textures_ok and rid.is_valid()
	if not textures_ok:
		return _fail("Surfel depth/normal/albedo/ORM input is unavailable")
	var effective_strength := clampf(float(snapshot.get("strength", 1.0)) * strength, 0.0, 8.0)
	var gather_bytes := PackedFloat32Array([effective_strength,
		1.0 if replacement_enabled else 0.0, float(frame_token_u32), 0.0]).to_byte_array()
	if not state.gather_ubo.is_valid() \
			or rd.buffer_update(state.gather_ubo, 0, gather_bytes.size(), gather_bytes) != OK:
		return _fail("Surfel gather parameter upload failed")
	if int(state.get("last_seed_frame", -1)) != frame_token:
		# Reset per-frame updates/urgent queue only; background cursor word 4 persists.
		var reset_counters := PackedInt32Array([0, 0]).to_byte_array()
		if rd.buffer_update(state.counters, 8, reset_counters.size(), reset_counters) != OK:
			return _fail("Surfel frame counter reset failed")
		state.last_seed_frame = frame_token
		state.seeded_views = {}
	var seeded_views: Dictionary = state.get("seeded_views", {})
	var view_key := _seed_view_key(textures[0], textures[1], size)
	if not _dispatch_frame_with_trace_sets(state, backends, frame, textures, color,
			gather_output, gather_final_output, sky_diffuse, diffuse_ao, gather_auxiliary,
		size, gather_size, max_distance, rays, updates,
		probe_ray_budget, gather_mode,
			frame_token, frame_token_u32, cache_key, view_key, seeded_views.has(view_key)):
		return _fail(error)
	state.error = ""
	_states[cache_key] = state
	return true

func _dispatch_frame_with_trace_sets(state: Dictionary, backends: Dictionary,
		frame: Dictionary, textures: Array[RID], color: RID, output: RID,
		final_output: RID, sky_diffuse: RID, diffuse_ao: RID, auxiliary: RID,
		size: Vector2i, gather_size: Vector2i, max_distance: float,
		rays_per_surfel: int, configured_updates: int,
		probe_ray_budget: int, gather_mode: int, frame_token: int,
		frame_token_u32: int, cache_key: String, view_key: String,
		view_seeded: bool) -> bool:
	var set_layout_backend: Dictionary = backends[RAYGEN_MODE_UPDATE]
	var trace_sets := _create_trace_set_bundle(state, set_layout_backend, frame, textures,
		color, output, final_output, sky_diffuse, diffuse_ao, auxiliary)
	if trace_sets.is_empty():
		return _fail(error if not error.is_empty() else "Surfel trace descriptor sets could not be created")
	var succeeded := _dispatch_frame_stages(state, backends, frame, trace_sets,
		textures, size, gather_size, max_distance,
		rays_per_surfel, configured_updates, probe_ray_budget,
		gather_mode, frame_token, frame_token_u32,
		cache_key, view_key, view_seeded)
	return succeeded

func _dispatch_frame_stages(state: Dictionary, backends: Dictionary,
		frame: Dictionary, trace_sets: Dictionary, textures: Array[RID],
		size: Vector2i, gather_size: Vector2i, max_distance: float, rays_per_surfel: int,
		configured_updates: int, probe_ray_budget: int,
		gather_mode: int, frame_token: int, frame_token_u32: int,
		cache_key: String, view_key: String, view_seeded: bool) -> bool:
	var scene: Variant = state.get("scene")
	var tracking_revision := _scene_tracking_revision(scene)
	if tracking_revision < 0:
		return _fail("SceneGPU SurfaceTracking revision is unavailable")
	var world_update_due := int(state.get("last_update_frame", -1)) != frame_token
	if world_update_due:
		var camera_value: Variant = frame.get("camera_transform", Transform3D.IDENTITY)
		var projection_value: Variant = frame.get("inverse_projection", Projection.IDENTITY)
		var lod_key := AdaptiveLayout.maintenance_lod_key(camera_value,
			projection_value, size, float(state.get("radius", 0.15))) \
			if camera_value is Transform3D and projection_value is Projection else 0
		var previous_tracking_revision := int(state.get("last_tracking_revision", -1))
		var previous_lod_key := int(state.get("last_maintenance_lod_key", -1))
		if previous_tracking_revision < 0:
			# A new cache has no anchors to relocate. Remember the baseline without
			# scheduling a capacity-sized empty scan.
			state.last_tracking_revision = tracking_revision
			state.last_maintenance_lod_key = lod_key
		elif previous_tracking_revision != tracking_revision or previous_lod_key != lod_key:
			state.maintenance_remaining = int(state.capacity)
			state.last_maintenance_lod_key = lod_key
		var maintenance_remaining := int(state.get("maintenance_remaining", 0))
		if maintenance_remaining > 0:
			if not _ensure_compute("maintenance"):
				return _fail(error if not error.is_empty() else "Surfel anchor maintenance pipeline is unavailable")
			# A changed SurfaceTracking revision can move anchors. Sweep the full
			# bounded record range before this frame's gather; stale motion revisions
			# are rejected by lookup until each anchor has been reprojected. Camera-
			# only LOD changes use the smaller background batch.
			var surface_tracking_changed := AdaptiveLayout.surface_tracking_changed(
				previous_tracking_revision, tracking_revision)
			var maintenance_count := AdaptiveLayout.maintenance_dispatch_count(
				int(state.capacity), maintenance_remaining, surface_tracking_changed,
				MAINTENANCE_BATCH)
			if rd.buffer_clear(state.processed_bits, 0, int(state.processed_bits_bytes)) != OK \
					or not _dispatch_maintenance(state, maintenance_count, frame_token):
				return _fail(error if not error.is_empty() else "Surfel anchor maintenance failed")
			state.lod_presence_dirty = true
			# Do not acknowledge a changed tracking snapshot until its full relocation
			# sweep was submitted successfully. A failed dispatch must retry the full
			# sweep next frame instead of degrading into a background chunk.
			if surface_tracking_changed:
				state.last_tracking_revision = tracking_revision
			state.maintenance_remaining = 0 if surface_tracking_changed \
					else maintenance_remaining - maintenance_count
	if not view_seeded:
		state.seed_count = int(state.get("seed_work_count", 0))
		if not _dispatch_seed(state, textures[0], textures[1], size):
			return false
		if bool(state.get("adaptive_enabled", true)):
			var total_tiles := AdaptiveLayout.tile_count(size)
			state.seed_cursor = AdaptiveLayout.advance_tile_cursor(
				int(state.get("seed_cursor", 0)), state.seed_count, total_tiles)
		var seeded_views: Dictionary = state.get("seeded_views", {})
		seeded_views[view_key] = true
		state.seeded_views = seeded_views
		state.lod_presence_dirty = true
		_states[cache_key] = state
	if bool(state.get("lod_presence_dirty", false)) \
			or int(state.get("lod_presence_frame", -1)) != frame_token:
		if not _dispatch_lod_presence(state):
			state.lod_presence_dirty = true
			_states[cache_key] = state
			return false
		state.lod_presence_frame = frame_token
		state.lod_presence_dirty = false
		_states[cache_key] = state
	if world_update_due:
		var read_index := int(state.get("response_read", 0))
		var previous: RID = state.responses[read_index]
		var next: RID = state.responses[1 - read_index]
		var copy_bytes := int(state.capacity) * RESPONSE_BYTES
		if rd.buffer_copy(previous, next, 0, 0, copy_bytes) != OK \
				or rd.buffer_clear(state.processed_bits, 0, int(state.processed_bits_bytes)) != OK:
			return _fail("Surfel response history copy failed")
		if not _dispatch_trace(state, backends, trace_sets, previous, next,
				min(configured_updates, int(state.capacity)), size, RAYGEN_MODE_UPDATE):
			return false
		if not _dispatch_commit(state, min(configured_updates, int(state.capacity))):
			return _invalidate_after_partial_update(state, cache_key,
				"Surfel commit dispatch failed")
		var updated_response: RID = state.responses[1 - read_index]
		var previous_response: RID = state.responses[read_index]
		if not _dispatch_filter(state, backends, frame, trace_sets,
				updated_response, previous_response, min(configured_updates, int(state.capacity)),
				rays_per_surfel, size, max_distance, frame_token_u32):
			return _invalidate_after_partial_update(state, cache_key,
				"Surfel spatial-filter dispatch failed")
		state.response_read = 1 - read_index
		state.update_cursor = (int(state.get("update_cursor", 0)) + mini(configured_updates, int(state.capacity))) & 0xffffffff
		if probe_ray_budget > 0:
			if not _ensure_compute("probe_commit"):
				return _invalidate_after_partial_update(state, cache_key,
					"Surfel probe cursor pipeline is unavailable")
			var probe_backend: Dictionary = backends.get(RAYGEN_MODE_PROBE, {})
			if probe_backend.is_empty():
				return _invalidate_after_partial_update(state, cache_key,
					"Surfel probe ray backend is unavailable")
			var probe_previous: RID = state.responses[int(state.response_read)]
			var probe_next: RID = state.responses[1 - int(state.response_read)]
			# Dispatch the configured upper bound. Raygen derives the active-set
			# reservation from GPU counters and guards excess lanes before tracing.
			var probe_slots := probe_ray_budget / 2
			if not _dispatch_trace(state, backends, trace_sets, probe_previous,
					probe_next, probe_slots, Vector2i(probe_slots, 1), RAYGEN_MODE_PROBE) \
					or not _dispatch_probe_commit(state):
				return _invalidate_after_partial_update(state, cache_key,
					"Surfel probe update or cursor commit failed")
		state.last_update_frame = frame_token
		state.dispatch_count = int(state.get("dispatch_count", 0)) + 1
	state.last_used = _cache_clock
	var current_response: RID = state.responses[int(state.response_read)]
	if not _dispatch_gather(state, backends, frame, trace_sets, size, gather_size,
			current_response, max_distance, rays_per_surfel, frame_token_u32, gather_mode):
		return false
	return true

func _seed_view_key(depth: RID, normal: RID, size: Vector2i) -> String:
	return "%d:%d:%d:%d" % [depth.get_id(), normal.get_id(), size.x, size.y]

func _invalidate_after_partial_update(state: Dictionary, cache_key: String,
		fallback_error: String) -> bool:
	var failure: String = error if not error.is_empty() else fallback_error
	state.needs_reset = true
	state.scene_ready = false
	state.error = failure
	_states[cache_key] = state
	return _fail(failure)

func _ensure_compute(kind: String) -> bool:
	var shader_key := kind + "_shader"
	var pipeline_key := kind + "_pipeline"
	if _compute.has(pipeline_key) and _compute[pipeline_key].is_valid():
		return true
	var source := RDShaderSource.new()
	var shader_name := ""
	match kind:
		"seed": shader_name = SEED_SHADER
		"commit": shader_name = "magic_gi_surfel_commit.glsl"
		"probe_commit": shader_name = "magic_gi_surfel_probe_commit.glsl"
		"maintenance": shader_name = "magic_gi_surfel_maintenance.glsl"
		"lod_summary": shader_name = LOD_SUMMARY_SHADER
		_:
			return _fail("Unknown Surfel compute stage: %s" % kind)
	var shader_text := FileAccess.get_file_as_string(SHADER_DIR + shader_name)
	if shader_text.is_empty():
		return _fail("Surfel %s shader source is missing" % kind)
	if shader_text.begins_with("#[compute]"):
		var marker_end := shader_text.find("\n")
		shader_text = shader_text.substr(marker_end + 1)
	source.source_compute = shader_text
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		return _fail("Surfel %s shader compile failed: %s" % [kind, spirv.compile_error_compute])
	var shader: RID = rd.shader_create_from_spirv(spirv, "Magic GI Surfel %s" % kind)
	if not shader.is_valid():
		return _fail("Surfel %s shader creation failed" % kind)
	var pipeline: RID = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		rd.free_rid(shader)
		return _fail("Surfel %s compute pipeline creation failed" % kind)
	_compute[shader_key] = shader
	_compute[pipeline_key] = pipeline
	_owned_shared.append_array([shader, pipeline])
	resource_revision += 1
	return true

func _ensure_backends(sky_array: bool, gather_mode: int, need_probe: bool) -> Dictionary:
	var backends: Dictionary = {}
	var common_sbt_range := -1
	var modes: Array[int] = [RAYGEN_MODE_UPDATE, RAYGEN_MODE_FILTER, gather_mode]
	if need_probe:
		modes.append(RAYGEN_MODE_PROBE)
	for raygen_mode in modes:
		if backends.has(raygen_mode):
			continue
		var backend := _ensure_backend(sky_array, raygen_mode)
		if backend.is_empty():
			return {}
		# SceneGPU bakes this hit-group offset into each TLAS instance.
		var sbt_range := int(backend.get("sbt_range", 0))
		if sbt_range <= 0 or (common_sbt_range >= 0 and sbt_range != common_sbt_range):
			_fail("Surfel mode pipelines use different SceneGPU hit SBT offsets")
			return {}
		common_sbt_range = sbt_range
		backends[raygen_mode] = backend
	return backends

func _ensure_backend(sky_array: bool, raygen_mode: int) -> Dictionary:
	if raygen_mode < RAYGEN_MODE_UPDATE or raygen_mode >= RAYGEN_MODE_COUNT:
		_fail("Surfel raygen mode is invalid")
		return {}
	var key := "%d:%d" % [int(sky_array), raygen_mode]
	if _backends.has(key):
		return _backends[key]
	# Separate pipelines keep each raygen call graph mode-specific. Their shader
	# declarations and hit stages stay identical so the callback sets can be shared.
	var source := RDShaderSource.new()
	if not _attach_trace_stage(source, RenderingDevice.SHADER_STAGE_RAYGEN,
		"magic_gi_surfel_raygen", "FengMagicGISurfelRayGen", true, sky_array, raygen_mode) \
		or not _attach_trace_stage(source, RenderingDevice.SHADER_STAGE_MISS,
		"gi_primary_miss", "FengGIPrimaryMiss", false, sky_array) \
		or not _attach_trace_stage(source, RenderingDevice.SHADER_STAGE_CLOSEST_HIT,
		"gi_closest_hit", "FengGIClosestHit", false, sky_array) \
		or not _attach_trace_stage(source, RenderingDevice.SHADER_STAGE_ANY_HIT,
		"gi_any_hit", "FengGIAnyHit", false, sky_array):
		return {}
	var shader := _compile_trace_source(source, "Magic GI Surfel Mode %d" % raygen_mode)
	if not shader.is_valid():
		return {}
	var shadow_source := RDShaderSource.new()
	if not _attach_trace_stage(shadow_source, RenderingDevice.SHADER_STAGE_MISS,
		"gi_shadow_miss", "FengGIShadowMiss", false, sky_array):
		rd.free_rid(shader)
		return {}
	var shadow_shader := _compile_trace_source(shadow_source,
			"Magic GI Surfel Mode %d Shadow" % raygen_mode)
	if not shadow_shader.is_valid():
		rd.free_rid(shader)
		return {}
	var raygen := RDPipelineShader.new()
	raygen.shader = shader
	var miss := RDPipelineShader.new()
	miss.shader = shader
	var shadow_miss := RDPipelineShader.new()
	shadow_miss.shader = shadow_shader
	var hit := RDHitGroup.new()
	# Gather and filter only issue first-hit LOS rays with SkipClosestHit. Keep
	# the closest-hit stage in the shader module, but omit it from these groups.
	var uses_closest_hit := raygen_mode == RAYGEN_MODE_UPDATE or raygen_mode == RAYGEN_MODE_PROBE
	if uses_closest_hit:
		hit.closest_hit_shader = raygen
	hit.any_hit_shader = raygen
	var owned: Array[RID] = [shader, shadow_shader]
	var recursion_depth := 2 if uses_closest_hit else 1
	var pipeline := rd.raytracing_pipeline_create([raygen], [miss, shadow_miss], [hit], recursion_depth)
	if not pipeline.is_valid():
		_free_rids(owned)
		_fail("Surfel ray tracing pipeline creation failed")
		return {}
	owned.append(pipeline)
	var sbt := rd.hit_sbt_create(pipeline, 1)
	if not sbt.is_valid():
		_free_rids(owned)
		_fail("Surfel hit SBT creation failed")
		return {}
	owned.append(sbt)
	var sbt_range := rd.hit_sbt_range_alloc(sbt, 1)
	if sbt_range == 0 or rd.hit_sbt_range_update(sbt, sbt_range, 0, PackedInt32Array([0])) != OK:
		_free_rids(owned)
		_fail("Surfel hit SBT range setup failed")
		return {}
	var neutral_local: Array[RID] = []
	for unused in 3:
		neutral_local.append(rd.storage_buffer_create(224))
	owned.append_array(neutral_local)
	for rid in owned:
		if not rid.is_valid():
			_free_rids(owned)
			_fail("Surfel ray backend resource allocation failed")
			return {}
	var backend := {"shader": shader, "shadow_shader": shadow_shader,
		"pipeline": pipeline, "sbt": sbt, "sbt_range": sbt_range,
		"neutral_local": neutral_local, "raygen_mode": raygen_mode,
		"owned": owned, "sky_array": sky_array}
	_backends[key] = backend
	resource_revision += 1
	return backend

func _attach_trace_stage(source: RDShaderSource, stage: int, stem: String,
		entry: String, surfel_raygen: bool, sky_array: bool,
		raygen_mode: int = RAYGEN_MODE_UPDATE) -> bool:
	var mode_define := raygen_mode if surfel_raygen else RAYGEN_MODE_UPDATE
	var prefix := "#define FENG_GI_SKY_ARRAY %d\n#define FENG_GI_SURFEL_CACHE 1\n#define FENG_GI_SURFEL_RAYGEN %d\n#define FENG_GI_SURFEL_MODE %d\n" % [int(sky_array), int(surfel_raygen), mode_define]
	var glsl_path := (SHADER_DIR + stem + ".glslinc") if surfel_raygen else (RAY_SHADER_DIR + stem + ".glslinc")
	var hlsl_path := (SHADER_DIR + stem + ".hlslinc") if surfel_raygen else (RAY_SHADER_DIR + stem + ".hlslinc")
	var glsl := FileAccess.get_file_as_string(
		glsl_path)
	if glsl.is_empty():
		return _fail("Surfel ray shader source is missing: %s" % stem)
	if glsl.begins_with("#version"):
		var line_end := glsl.find("\n")
		glsl = glsl.substr(0, line_end + 1) + prefix + glsl.substr(line_end + 1)
	else:
		glsl = prefix + glsl
	var native_hlsl := prefix + FileAccess.get_file_as_string(hlsl_path)
	if native_hlsl.trim_prefix(prefix).is_empty():
		return _fail("Surfel native HLSL ray shader source is missing: %s" % stem)
	if stem == "magic_gi_surfel_raygen":
		var cache_glsl := FileAccess.get_file_as_string(SURFEL_CACHE_GLSL)
		var gather_glsl := FileAccess.get_file_as_string(SURFEL_GATHER_GLSL)
		var filter_glsl := FileAccess.get_file_as_string(SURFEL_FILTER_GLSL)
		var probe_glsl := FileAccess.get_file_as_string(SURFEL_PROBE_GLSL)
		var cache_hlsl := FileAccess.get_file_as_string(SURFEL_CACHE_HLSL)
		var gather_hlsl := FileAccess.get_file_as_string(SURFEL_GATHER_HLSL)
		var filter_hlsl := FileAccess.get_file_as_string(SURFEL_FILTER_HLSL)
		var probe_hlsl := FileAccess.get_file_as_string(SURFEL_PROBE_HLSL)
		if cache_glsl.is_empty() or gather_glsl.is_empty() or filter_glsl.is_empty() \
				or probe_glsl.is_empty() or cache_hlsl.is_empty() or gather_hlsl.is_empty() \
				or filter_hlsl.is_empty() or probe_hlsl.is_empty():
			return _fail("Surfel raygen cache, gather, or filter shader include is missing")
		var include_marker := "// FENG_GI_SURFEL_CACHE_AND_GATHER_INCLUDES"
		var cache_and_gather_glsl := cache_glsl + "\n" + probe_glsl + "\n" + gather_glsl
		var cache_and_gather_hlsl := cache_hlsl + "\n" + probe_hlsl + "\n" + gather_hlsl
		if not glsl.contains(include_marker) or not native_hlsl.contains(include_marker):
			return _fail("Surfel raygen cache/gather injection point was not found")
		glsl = glsl.replace(include_marker, cache_and_gather_glsl)
		native_hlsl = native_hlsl.replace(include_marker, cache_and_gather_hlsl)
		var filter_marker := "// FENG_GI_SURFEL_FILTER_INCLUDE"
		if not glsl.contains(filter_marker) or not native_hlsl.contains(filter_marker):
			return _fail("Surfel raygen filter injection point was not found")
		glsl = glsl.replace(filter_marker, filter_glsl)
		native_hlsl = native_hlsl.replace(filter_marker, filter_hlsl)
		if not glsl.contains("void gi_surfel_gather()") \
				or not native_hlsl.contains("void gi_surfel_gather()") \
				or not glsl.contains("void gi_surfel_gather_nrd()") \
				or not native_hlsl.contains("void gi_surfel_gather_nrd()") \
				or not glsl.contains("void gi_surfel_filter_update") \
				or not native_hlsl.contains("void gi_surfel_filter_update") \
				or not glsl.contains("void gi_surfel_probe_update") \
				or not native_hlsl.contains("void gi_surfel_probe_update"):
			return _fail("Surfel gather, filter, or probe entry point was not found")
	elif stem == "gi_closest_hit":
		var cache_glsl := FileAccess.get_file_as_string(SURFEL_CACHE_GLSL)
		var direct_glsl := FileAccess.get_file_as_string(DIRECT_GLSL)
		var probe_glsl := FileAccess.get_file_as_string(SURFEL_PROBE_GLSL)
		var cache_hlsl := FileAccess.get_file_as_string(SURFEL_CACHE_HLSL)
		var direct_hlsl := FileAccess.get_file_as_string(DIRECT_HLSL)
		var probe_hlsl := FileAccess.get_file_as_string(SURFEL_PROBE_HLSL)
		if cache_glsl.is_empty() or direct_glsl.is_empty() or probe_glsl.is_empty() \
				or cache_hlsl.is_empty() or direct_hlsl.is_empty() or probe_hlsl.is_empty():
			return _fail("Surfel closest-hit cache or local-light shader include is missing")
		glsl = glsl.replace("void main() {", cache_glsl + "\n" + probe_glsl + "\n" + direct_glsl + "\nvoid main() {")
		native_hlsl = native_hlsl.replace("[shader(\"closesthit\")]",
				cache_hlsl + "\n" + probe_hlsl + "\n" + direct_hlsl + "\n[shader(\"closesthit\")]")
		if not glsl.contains("gi_surfel_lookup_previous") or not native_hlsl.contains("gi_surfel_lookup_previous"):
			return _fail("Surfel closest-hit cache include injection point was not found")
	source.set_stage_source(stage, glsl)
	if source.has_method("set_native_hlsl_stage_source"):
		source.call("set_native_hlsl_stage_source", stage, native_hlsl)
		source.call("set_native_hlsl_stage_export", stage, entry)
		source.call("set_native_hlsl_max_payload_size_bytes", 24)
		source.call("set_native_hlsl_max_attribute_size_bytes", 8)
	return true

func _compile_trace_source(source: RDShaderSource, label: String) -> RID:
	var spirv := rd.shader_compile_spirv_from_source(source)
	for stage in range(RenderingDevice.SHADER_STAGE_MAX):
		var stage_error := spirv.get_stage_compile_error(stage)
		if not stage_error.is_empty():
			_fail("%s shader compile failed: %s" % [label, stage_error])
			return RID()
	var shader := rd.shader_create_from_spirv(spirv, label)
	if not shader.is_valid():
		_fail("%s shader creation failed" % label)
	return shader

func _ensure_state(cache_key: String, snapshot: Dictionary, capacity: int,
		layout_version: int, world_generation: int, registry_epoch: int,
		sky_array: bool) -> Dictionary:
	_cache_clock += 1
	var state: Dictionary = _states.get(cache_key, {})
	var incompatible := not state.is_empty() and (int(state.get("layout_version", -1)) != layout_version \
			or int(state.get("world_generation", -1)) != world_generation \
			or int(state.get("registry_epoch", -1)) != registry_epoch \
			or int(state.get("capacity", 0)) != capacity \
			or int(state.get("counter_bytes", 0)) != COUNTER_BYTES \
			or bool(state.get("needs_reset", false)))
	if incompatible:
		_free_state(state)
		_states.erase(cache_key)
		state = {}
	if state.is_empty():
		var scene_type := _get_scene_gpu_script()
		if scene_type == null:
			error = "Surfel requires feng-raytracing SceneGPU support"
			return {}
		var scene: Variant = scene_type.new()
		if not scene.initialize(rd):
			error = "Surfel RTGI scene resources failed to initialize"
			scene.release()
			return {}
		var hash_capacity := _next_power_of_two(capacity * 2)
		var table_bytes := PackedInt32Array()
		table_bytes.resize(hash_capacity)
		for index in table_bytes.size():
			table_bytes[index] = -1
		var table := rd.storage_buffer_create(hash_capacity * 4, table_bytes.to_byte_array())
		var records := rd.storage_buffer_create(capacity * RECORD_BYTES)
		var update_queue := rd.storage_buffer_create(capacity * 8)
		var pending_results := rd.storage_buffer_create(capacity * 16)
		var processed_bits_bytes := maxi(4, ceili(float(capacity) / 32.0) * 4)
		var processed_bits := rd.storage_buffer_create(processed_bits_bytes)
		var responses: Array[RID] = [rd.storage_buffer_create(capacity * RESPONSE_BYTES),
			rd.storage_buffer_create(capacity * RESPONSE_BYTES)]
		var response_filtered := rd.storage_buffer_create(capacity * RESPONSE_BYTES)
		var statistics := rd.storage_buffer_create(capacity * RESPONSE_BYTES)
		var anchor_tracking := rd.storage_buffer_create(capacity * TRACKING_BYTES)
		var guide_previous := rd.storage_buffer_create(capacity * GUIDE_BYTES)
		var guide_next := rd.storage_buffer_create(capacity * GUIDE_BYTES)
		var free_indices := rd.storage_buffer_create(capacity * FREE_INDEX_BYTES)
		var lod_presence := rd.storage_buffer_create(4)
		var config := rd.uniform_buffer_create(CONFIG_BYTES)
		var maintenance_control := rd.uniform_buffer_create(16)
		var counters := rd.storage_buffer_create(COUNTER_BYTES,
			PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0]).to_byte_array())
		var frame_buffer := rd.uniform_buffer_create(256)
		var gather_ubo := rd.uniform_buffer_create(16)
		var sampler_state := RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		var sampler := rd.sampler_create(sampler_state)
		var owned: Array[RID] = [table, records, update_queue, pending_results, processed_bits,
			responses[0], responses[1], response_filtered, statistics, anchor_tracking,
			guide_previous, guide_next, free_indices, lod_presence,
			config, maintenance_control, counters, frame_buffer, gather_ubo, sampler]
		for rid in owned:
			if not rid.is_valid():
				_free_rids(owned)
				scene.release()
				error = "Surfel cache bounded storage allocation failed"
				return {}
		var probe_field: Variant = ProbeField.new()
		if not probe_field.initialize(rd):
			_free_rids(owned)
			scene.release()
			error = str(probe_field.error)
			return {}
		if rd.buffer_clear(records, 0, capacity * RECORD_BYTES) != OK \
				or rd.buffer_clear(update_queue, 0, capacity * 8) != OK \
				or rd.buffer_clear(pending_results, 0, capacity * 16) != OK \
				or rd.buffer_clear(processed_bits, 0, processed_bits_bytes) != OK \
				or rd.buffer_clear(responses[0], 0, capacity * RESPONSE_BYTES) != OK \
				or rd.buffer_clear(responses[1], 0, capacity * RESPONSE_BYTES) != OK \
				or rd.buffer_clear(response_filtered, 0, capacity * RESPONSE_BYTES) != OK \
				or rd.buffer_clear(statistics, 0, capacity * RESPONSE_BYTES) != OK \
				or rd.buffer_clear(anchor_tracking, 0, capacity * TRACKING_BYTES) != OK \
				or rd.buffer_clear(guide_previous, 0, capacity * GUIDE_BYTES) != OK \
				or rd.buffer_clear(guide_next, 0, capacity * GUIDE_BYTES) != OK \
				or rd.buffer_clear(free_indices, 0, capacity * FREE_INDEX_BYTES) != OK \
				or rd.buffer_clear(lod_presence, 0, 4) != OK:
			probe_field.release()
			_free_rids(owned)
			scene.release()
			error = "Surfel response history initialization failed"
			return {}
		state = {"cache_key": cache_key, "scene": scene, "owned": owned,
			"probe_field": probe_field, "probe_field_bytes": probe_field.get_byte_count(),
			"table": table, "records": records, "responses": responses,
			"response_filtered": response_filtered, "statistics": statistics,
			"anchor_tracking": anchor_tracking, "guide_previous": guide_previous,
			"guide_next": guide_next,
			"free_indices": free_indices,
			"lod_presence": lod_presence,
			"update_queue": update_queue, "pending_results": pending_results,
			"processed_bits": processed_bits, "processed_bits_bytes": processed_bits_bytes,
			"config_buffer": config, "maintenance_control": maintenance_control,
			"counters": counters, "frame_buffer": frame_buffer,
			"gather_ubo": gather_ubo, "sampler": sampler, "response_read": 0, "last_update_frame": -1,
			"last_seed_frame": -1, "valid_updates": 0, "capacity": capacity,
			"hash_capacity": hash_capacity, "record_bytes": capacity * RECORD_BYTES,
			"counter_bytes": COUNTER_BYTES,
			"response_bytes": capacity * RESPONSE_BYTES * 2,
			"filtered_bytes": capacity * RESPONSE_BYTES,
			"statistics_bytes": capacity * RESPONSE_BYTES,
			"tracking_bytes": capacity * TRACKING_BYTES,
			"guide_bytes": capacity * GUIDE_BYTES * 2,
			"lod_presence_bytes": 4,
			"cache_bytes": hash_capacity * 4 + capacity * (RECORD_BYTES + RESPONSE_BYTES * 4 + 8 + 16 + TRACKING_BYTES + GUIDE_BYTES * 2 + FREE_INDEX_BYTES) + processed_bits_bytes + CONFIG_BYTES + 16 + COUNTER_BYTES + 256 + 16 + 4 + probe_field.get_byte_count(),
			"layout_version": layout_version, "world_generation": world_generation,
			"registry_epoch": registry_epoch, "sky_array": sky_array,
			"scene_ready": false, "needs_reset": false,
			"last_used": _cache_clock, "error": ""}
		state.update_cursor = 0
		state.seed_cursor = 0
		state.last_probe_layout_frame = -1
		state.lod_presence_frame = -1
		state.lod_presence_dirty = true
		state.last_tracking_revision = -1
		state.last_maintenance_lod_key = -1
		state.maintenance_remaining = 0
		state.dispatch_count = 0
		state.gpu_positive_updates = 0
		state.gpu_active_count = 0
		_states[cache_key] = state
		resource_revision += 1
		_evict_old_states(cache_key)
	return state

func _evict_old_states(keep_key: String) -> void:
	while _states.size() > MAX_CACHE_STATES:
		var oldest_key := ""
		var oldest_frame := 0x7fffffff
		for key in _states:
			if str(key) == keep_key:
				continue
			var candidate: Dictionary = _states[key]
			if int(candidate.get("last_used", 0)) < oldest_frame:
				oldest_frame = int(candidate.get("last_used", 0))
				oldest_key = str(key)
		if oldest_key.is_empty():
			break
		var stale: Dictionary = _states[oldest_key]
		_states.erase(oldest_key)
		_free_state(stale)

func _free_state(state: Dictionary) -> void:
	var scene: Variant = state.get("scene")
	if scene != null:
		scene.release()
	var probe_field: Variant = state.get("probe_field")
	if probe_field != null:
		probe_field.release()
	_free_rids(state.get("owned", []))
	resource_revision += 1

func _dispatch_seed(state: Dictionary, depth: RID, normal: RID, size: Vector2i) -> bool:
	var scene: Variant = state.get("scene")
	var tracking := _scene_tracking_buffer(scene)
	if scene == null or not tracking.is_valid():
		return _fail("SceneGPU geometry/tracking inputs are unavailable for surfel seeding")
	var set0: Array[RDUniform] = [U.sampled(1, state.sampler, depth),
		U.sampled(2, state.sampler, normal), U.uniform_buffer(20, state.frame_buffer)]
	var set1: Array[RDUniform] = [U.storage_buffer(0, state.records),
		U.storage_buffer(1, state.table), U.storage_buffer(2, state.responses[0]),
		U.storage_buffer(3, state.responses[1]), U.uniform_buffer(4, state.config_buffer),
		U.storage_buffer(5, state.counters), U.storage_buffer(6, state.update_queue),
		U.storage_buffer(7, state.response_filtered), U.storage_buffer(8, state.statistics),
		U.storage_buffer(13, state.anchor_tracking), U.storage_buffer(14, state.guide_previous),
		U.storage_buffer(15, state.guide_next), U.storage_buffer(16, state.free_indices)]
	return _dispatch(_compute.seed_shader, _compute.seed_pipeline, set0, set1,
		int(state.get("seed_count", 0)), Vector2i(64, 1))

func _dispatch_lod_presence(state: Dictionary) -> bool:
	if not _ensure_compute("lod_summary"):
		return false
	var lod_presence: RID = state.get("lod_presence", RID())
	if not lod_presence.is_valid() or not state.records.is_valid() \
			or not state.anchor_tracking.is_valid() or not state.counters.is_valid():
		return _fail("Surfel LOD presence resources are unavailable")
	if rd.buffer_clear(lod_presence, 0, 4) != OK:
		return _fail("Surfel LOD presence reset failed")
	var set0: Array[RDUniform] = [U.uniform_buffer(4, state.config_buffer)]
	var set1: Array[RDUniform] = [U.storage_buffer(0, state.records),
		U.storage_buffer(5, state.counters), U.storage_buffer(13, state.anchor_tracking),
		U.storage_buffer(17, lod_presence)]
	return _dispatch(_compute.lod_summary_shader, _compute.lod_summary_pipeline,
		set0, set1, int(state.capacity), Vector2i(256, 1))

func _dispatch_maintenance(state: Dictionary, dispatch_count: int, frame_token: int) -> bool:
	var scene: Variant = state.get("scene")
	var tracking := _scene_tracking_buffer(scene)
	if scene == null or not tracking.is_valid() or dispatch_count <= 0:
		return _fail("SceneGPU SurfaceTracking buffer is unavailable")
	var maintenance_control: RID = state.get("maintenance_control", RID())
	var control_bytes := PackedInt32Array([dispatch_count, frame_token, 0, 0]).to_byte_array()
	if not maintenance_control.is_valid() \
			or rd.buffer_update(maintenance_control, 0, control_bytes.size(), control_bytes) != OK:
		return _fail("Surfel maintenance control upload failed")
	var set0: Array[RDUniform] = [U.storage_buffer(8, scene.vertices),
		U.storage_buffer(9, scene.indices), U.storage_buffer(10, scene.surfaces),
		U.uniform_buffer(20, state.frame_buffer), U.uniform_buffer(21, maintenance_control),
		U.storage_buffer(40, tracking)]
	var set1: Array[RDUniform] = [U.storage_buffer(0, state.records),
		U.storage_buffer(1, state.table), U.storage_buffer(2, state.responses[0]),
		U.storage_buffer(3, state.responses[1]), U.uniform_buffer(4, state.config_buffer),
		U.storage_buffer(5, state.counters), U.storage_buffer(9, state.response_filtered),
		U.storage_buffer(10, state.statistics), U.storage_buffer(13, state.anchor_tracking),
		U.storage_buffer(8, state.processed_bits), U.storage_buffer(14, state.guide_previous),
		U.storage_buffer(15, state.guide_next),
		U.storage_buffer(16, state.free_indices)]
	return _dispatch(_compute.maintenance_shader, _compute.maintenance_pipeline,
		set0, set1, dispatch_count, Vector2i(64, 1))

func _scene_tracking_buffer(scene: Variant) -> RID:
	if scene == null:
		return RID()
	var value: Variant = scene.call("get_surface_tracking_buffer") \
			if scene.has_method("get_surface_tracking_buffer") else scene.get("surface_tracking_buffer")
	return value if value is RID else RID()

func _scene_tracking_revision(scene: Variant) -> int:
	if scene == null:
		return -1
	var value: Variant = scene.call("get_surface_tracking_revision") \
			if scene.has_method("get_surface_tracking_revision") else scene.get("surface_tracking_revision")
	return int(value) if value != null else -1

func _scene_surface_count(scene: Variant) -> int:
	if scene == null:
		return -1
	var value: Variant = scene.call("get_surface_count") \
			if scene.has_method("get_surface_count") else scene.get("surface_count")
	return int(value) if value != null else -1

func _dispatch_commit(state: Dictionary, update_count: int) -> bool:
	var probe_field: Variant = state.get("probe_field")
	if probe_field == null:
		return _fail("Surfel probe budget resources are unavailable")
	var set0: Array[RDUniform] = [U.uniform_buffer(4, state.config_buffer),
		U.uniform_buffer(12, probe_field.config)]
	var set1: Array[RDUniform] = [U.storage_buffer(0, state.records),
		U.storage_buffer(1, state.table), U.storage_buffer(5, state.counters),
		U.storage_buffer(6, state.update_queue), U.storage_buffer(7, state.pending_results),
		U.storage_buffer(9, state.response_filtered), U.storage_buffer(10, state.statistics),
		U.storage_buffer(13, state.anchor_tracking), U.storage_buffer(14, state.guide_previous),
		U.storage_buffer(15, state.guide_next), U.storage_buffer(16, state.free_indices)]
	return _dispatch(_compute.commit_shader, _compute.commit_pipeline, set0, set1,
		update_count, Vector2i(64, 1))

func _dispatch_probe_commit(state: Dictionary) -> bool:
	var probe_field: Variant = state.get("probe_field")
	if probe_field == null or not _compute.get("probe_commit_pipeline", RID()).is_valid():
		return _fail("Surfel probe cursor resources are unavailable")
	return _dispatch(_compute.probe_commit_shader, _compute.probe_commit_pipeline,
		[U.uniform_buffer(12, probe_field.config)], [U.storage_buffer(5, state.counters)],
		1, Vector2i(1, 1))

func _dispatch_filter(state: Dictionary, backends: Dictionary, frame: Dictionary,
		trace_sets: Dictionary, current_response: RID, spare_response: RID, update_count: int,
		rays_per_surfel: int, size: Vector2i,
		max_distance: float, frame_token: int) -> bool:
	if update_count <= 0:
		return true
	var frame_bytes := _pack_frame(frame, size, max_distance, rays_per_surfel,
		int(state.get("update_cursor", 0)), frame_token, bool(state.get("sky_array", false)), 2)
	if frame_bytes.size() != 256 \
			or rd.buffer_update(state.frame_buffer, 0, frame_bytes.size(), frame_bytes) != OK:
		return _fail("Surfel spatial-filter frame upload failed")
	return _dispatch_trace(state, backends, trace_sets, current_response,
		spare_response, update_count, size, RAYGEN_MODE_FILTER)

func _dispatch_gather(state: Dictionary, backends: Dictionary, frame: Dictionary,
		trace_sets: Dictionary, frame_size: Vector2i, gather_size: Vector2i,
		current_response: RID, max_distance: float, rays_per_surfel: int,
		frame_token: int, gather_mode: int) -> bool:
	if gather_size.x <= 0 or gather_size.y <= 0:
		return true
	var frame_bytes := _pack_frame(frame, frame_size, max_distance, rays_per_surfel,
		int(state.get("update_cursor", 0)), frame_token, bool(state.get("sky_array", false)), gather_mode)
	if frame_bytes.size() != 256 \
			or rd.buffer_update(state.frame_buffer, 0, frame_bytes.size(), frame_bytes) != OK:
		return _fail("Surfel gather frame upload failed")
	var next_response: RID = state.responses[1 - int(state.get("response_read", 0))]
	return _dispatch_trace(state, backends, trace_sets, current_response,
		next_response, 1, gather_size, gather_mode)

func _dispatch_trace(state: Dictionary, backends: Dictionary, trace_sets: Dictionary,
		previous: RID, next: RID, update_count: int, size: Vector2i,
		raygen_mode: int) -> bool:
	if raygen_mode != RAYGEN_MODE_GATHER and raygen_mode != RAYGEN_MODE_NRD_GATHER \
			and update_count <= 0:
		return true
	var backend_value: Variant = backends.get(raygen_mode, {})
	if not backend_value is Dictionary:
		return _fail("Surfel raygen backend is unavailable for mode %d" % raygen_mode)
	var backend: Dictionary = backend_value
	var response0: RID = trace_sets.get("response0", RID())
	var response1: RID = trace_sets.get("response1", RID())
	var set1: RID = RID()
	if previous == response0 and next == response1:
		set1 = trace_sets.get("set1_response0", RID())
	elif previous == response1 and next == response0:
		set1 = trace_sets.get("set1_response1", RID())
	else:
		return _fail("Surfel trace response pair does not match this render callback")
	var set0: RID = trace_sets.get("set0", RID())
	if not set0.is_valid() or not set1.is_valid():
		return _fail("Surfel trace descriptor sets are invalid")
	var list := rd.raytracing_list_begin()
	if list < 0:
		return _fail("Surfel ray tracing list could not begin")
	rd.raytracing_list_bind_raytracing_pipeline(list, backend.pipeline)
	rd.raytracing_list_bind_uniform_set(list, set0, 0)
	rd.raytracing_list_bind_uniform_set(list, set1, 1)
	var ray_width := update_count
	var ray_height := 1
	if raygen_mode == RAYGEN_MODE_GATHER or raygen_mode == RAYGEN_MODE_NRD_GATHER:
		ray_width = size.x
		ray_height = size.y
	rd.raytracing_list_trace_rays(list, 0, backend.sbt, ray_width, ray_height, 1)
	rd.raytracing_list_end()
	return true

func _create_trace_set_bundle(state: Dictionary, backend: Dictionary,
		frame: Dictionary, textures: Array[RID], color: RID, output: RID,
		final_output: RID, sky_diffuse: RID, diffuse_ao: RID, auxiliary: RID) -> Dictionary:
	var scene: Variant = state.get("scene")
	if scene == null:
		_fail("Surfel TLAS is unavailable")
		return {}
	var sky_array := bool(state.sky_array)
	var sky: RID = frame.get("sky_radiance_texture", RID())
	if not sky.is_valid():
		sky = scene.black_array if sky_array else scene.black_2d
	var directional: RID = frame.get("directional_light_buffer", RID())
	if not directional.is_valid():
		directional = scene.neutral_lights
	var set0_uniforms := _trace_uniforms(state, backend, frame, sky,
		directional, textures, color, output, final_output, sky_diffuse, diffuse_ao, auxiliary)
	if set0_uniforms.is_empty():
		return {}
	var response0: RID = state.responses[0]
	var response1: RID = state.responses[1]
	var bundle := {"set0": RID(), "set1_response0": RID(),
		"set1_response1": RID(), "response0": response0, "response1": response1}
	bundle.set0 = UniformSetCacheRD.get_cache(backend.shader, 0, set0_uniforms)
	if bundle.set0.is_valid():
		bundle.set1_response0 = UniformSetCacheRD.get_cache(backend.shader, 1,
			_trace_response_uniforms(state, response0, response1))
	if bundle.set0.is_valid() and bundle.set1_response0.is_valid():
		bundle.set1_response1 = UniformSetCacheRD.get_cache(backend.shader, 1,
			_trace_response_uniforms(state, response1, response0))
	if not bundle.set0.is_valid() or not bundle.set1_response0.is_valid() \
			or not bundle.set1_response1.is_valid():
		_fail("Surfel trace descriptor sets are invalid")
		return {}
	return bundle

func _trace_uniforms(state: Dictionary, backend: Dictionary, frame: Dictionary,
		sky: RID, directional: RID, textures: Array[RID], color: RID,
		output: RID, final_output: RID, sky_diffuse: RID, diffuse_ao: RID, auxiliary: RID) -> Array:
	var scene: Variant = state.scene
	if textures.size() < 4 or not color.is_valid() or not output.is_valid() \
			or not final_output.is_valid() or not auxiliary.is_valid():
		_fail("Surfel ray dispatch is missing per-view attachments")
		return []
	var neutral: Array = backend.neutral_local
	var omni: RID = _valid_light_buffer(frame, "omni_light_buffer", "omni_light_count", 224, neutral[0])
	var spot: RID = _valid_light_buffer(frame, "spot_light_buffer", "spot_light_count", 224, neutral[1])
	var area: RID = _valid_light_buffer(frame, "area_light_buffer", "area_light_count", 224, neutral[2])
	var set0: Array[RDUniform] = []
	var acceleration := RDUniform.new()
	acceleration.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	acceleration.binding = 0
	acceleration.add_id(scene.tlas)
	set0.append(acceleration)
	set0.append(U.sampled(6, scene.sampler, sky))
	set0.append(U.uniform_buffer(7, directional))
	set0.append(U.storage_buffer(8, scene.vertices))
	set0.append(U.storage_buffer(9, scene.indices))
	set0.append(U.storage_buffer(10, scene.surfaces))
	set0.append(U.storage_buffer(11, scene.materials))
	for index in 8:
		var group := mini(index, scene.atlas.size() - 1)
		set0.append(U.sampled(12 + index, scene.atlas_samplers[group], scene.atlas[group]))
	set0.append(U.uniform_buffer(20, state.frame_buffer))
	set0.append(U.sampled(23, scene.sampler, scene.black_2d))
	set0.append(U.storage_buffer(25, scene.emitters))
	set0.append(U.storage_buffer(26, omni))
	set0.append(U.storage_buffer(27, spot))
	set0.append(U.storage_buffer(28, area))
	var tracking := _scene_tracking_buffer(scene)
	if not tracking.is_valid():
		_fail("Surfel SurfaceTracking buffer is unavailable")
		return []
	set0.append(U.storage_buffer(40, tracking))
	var sky_diffuse_texture: RID = sky_diffuse if sky_diffuse.is_valid() else scene.black_2d
	var ao_texture: RID = diffuse_ao if diffuse_ao.is_valid() else _ensure_white_ao(state)
	if not sky_diffuse_texture.is_valid() or not ao_texture.is_valid():
		_fail("Surfel gather fallback textures are unavailable")
		return []
	set0.append(U.image(29, color))
	set0.append(U.image(30, output))
	set0.append(U.sampled(31, state.sampler, textures[0]))
	set0.append(U.sampled(32, state.sampler, textures[1]))
	set0.append(U.sampled(33, state.sampler, textures[2]))
	set0.append(U.sampled(34, state.sampler, textures[3]))
	set0.append(U.sampled(35, scene.sampler, sky_diffuse_texture))
	set0.append(U.sampled(36, state.sampler, ao_texture))
	set0.append(U.uniform_buffer(37, state.gather_ubo))
	set0.append(U.image(38, auxiliary))
	set0.append(U.image(39, final_output))
	return set0

func _trace_response_uniforms(state: Dictionary, previous: RID, next: RID) -> Array[RDUniform]:
	var probe_field: Variant = state.get("probe_field")
	return [U.storage_buffer(0, state.records), U.storage_buffer(1, state.table),
		U.storage_buffer(2, previous), U.storage_buffer(3, next),
		U.uniform_buffer(4, state.config_buffer), U.storage_buffer(5, state.counters),
		U.storage_buffer(6, state.update_queue), U.storage_buffer(7, state.pending_results),
		U.storage_buffer(8, state.processed_bits), U.storage_buffer(9, state.response_filtered),
		U.storage_buffer(10, state.statistics), U.storage_buffer(11, probe_field.records),
		U.storage_buffer(13, state.anchor_tracking), U.storage_buffer(14, state.guide_previous),
		U.storage_buffer(15, state.guide_next),
		U.storage_buffer(16, state.free_indices),
		U.storage_buffer(17, state.lod_presence),
		U.uniform_buffer(12, probe_field.config)]

func _valid_light_buffer(frame: Dictionary, buffer_key: String, count_key: String,
		stride: int, fallback: RID) -> RID:
	var rid_value: Variant = frame.get(buffer_key, RID())
	var count := int(frame.get(count_key, 0))
	if rid_value is RID and rid_value.is_valid() and count > 0 \
			and int(frame.get(buffer_key.trim_suffix("buffer") + "stride_bytes", stride)) == stride:
		return rid_value
	return fallback

func _dispatch(shader: RID, pipeline: RID, set0_uniforms: Array[RDUniform],
		set1_uniforms: Array[RDUniform], extent: Variant, workgroup: Vector2i) -> bool:
	var groups: Vector3i
	if extent is Vector2i:
		groups = Vector3i(ceili(float(extent.x) / workgroup.x), ceili(float(extent.y) / workgroup.y), 1)
	else:
		groups = Vector3i(ceili(float(int(extent)) / workgroup.x), 1, 1)
	if groups.x <= 0 or groups.y <= 0:
		return true
	var set0 := UniformSetCacheRD.get_cache(shader, 0, set0_uniforms)
	var set1 := UniformSetCacheRD.get_cache(shader, 1, set1_uniforms) \
			if not set1_uniforms.is_empty() else RID()
	if not set0.is_valid() or (not set1_uniforms.is_empty() and not set1.is_valid()):
		return _fail("Surfel compute descriptor set is invalid")
	var list := rd.compute_list_begin()
	if list < 0:
		return _fail("Surfel compute list could not begin")
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set0, 0)
	if set1.is_valid():
		rd.compute_list_bind_uniform_set(list, set1, 1)
	if extent is Vector2i:
		rd.compute_list_dispatch(list, groups.x, groups.y, 1)
	else:
		rd.compute_list_dispatch(list, groups.x, 1, 1)
	rd.compute_list_end()
	return true

func _pack_frame(frame: Dictionary, size: Vector2i, max_distance: float,
		rays_per_surfel: int, update_cursor: int, frame_token: int,
		sky_array: bool, raygen_mode: int = 0) -> PackedByteArray:
	var bytes := PackedByteArray()
	_append_projection(bytes, frame.get("inverse_projection", Projection.IDENTITY))
	var camera: Transform3D = frame.get("camera_transform", Transform3D.IDENTITY)
	_append_transform(bytes, Transform3D(camera.basis.orthonormalized(), camera.origin))
	bytes.append_array(PackedFloat32Array([size.x, size.y,
		_finite_range(frame.get("pre_exposure", 1.0), 1.0, 1e-6, 1e6),
		_finite_range(frame.get("scene_normalization", 1.0), 1.0, 1e-6, 1e6),
		_finite_range(frame.get("light_buffer_exposure_normalization", 1.0), 1.0, 1e-6, 1e6),
		_finite_range(frame.get("sky_light_energy", 0.0), 0.0, 0.0, 1e6),
		_finite_range(frame.get("sky_captured_exposure", 1.0), 1.0, 1e-6, 1e6),
		_finite_range(frame.get("sky_uv_border_size", 0.0), 0.0, 0.0, 0.49)]).to_byte_array())
	var sky_rotation: Basis = frame.get("sky_light_rotation", Basis.IDENTITY)
	var rotation: Basis = sky_rotation.inverse()
	for axis in [rotation.x, rotation.y, rotation.z]:
		bytes.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]).to_byte_array())
	var sun := int(frame.get("cloud_primary_sun_directional_index", -1))
	if sun < 0 and int(frame.get("directional_light_count", 0)) > 0:
		sun = 0
	bytes.append_array(PackedInt32Array([sun, int(frame.get("view_index", 0)), frame_token, int(sky_array)]).to_byte_array())
	bytes.append_array(PackedFloat32Array([max_distance, 1.0, float(rays_per_surfel), 0.0]).to_byte_array())
	# Surfel updates perform matching emitter NEE when the scene has valid emitters
	# and the per-surfel ray budget is at least two. Other pipelines may still use
	# this flag to disable emitter MIS.
	bytes.append_array(PackedInt32Array([update_cursor, 0, raygen_mode, 0]).to_byte_array())
	return bytes

func _pack_config(owner: Transform3D, owner_size: Vector3, radius: float,
		capacity: int, hash_capacity: int, updates: int, frame_token: int,
		light_counts: PackedInt32Array, max_distance: float, history_weight: float,
		seed_count: int, debug_view: int, adaptive_enabled: bool, guiding_enabled: bool,
		guide_cosine_floor: float, seed_cursor: int, tile_count: int,
		surface_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	_append_transform(bytes, owner.affine_inverse())
	_append_transform(bytes, owner)
	bytes.append_array(PackedFloat32Array([owner_size.x, owner_size.y, owner_size.z, radius]).to_byte_array())
	bytes.append_array(PackedInt32Array([capacity, hash_capacity - 1, updates, frame_token]).to_byte_array())
	bytes.append_array(light_counts.to_byte_array())
	bytes.append_array(PackedFloat32Array([max_distance, history_weight, seed_count, debug_view]).to_byte_array())
	bytes.append_array(PackedInt32Array([int(adaptive_enabled), tile_count,
		seed_cursor, surface_count]).to_byte_array())
	bytes.append_array(PackedFloat32Array([int(guiding_enabled),
		_finite_range(guide_cosine_floor, 0.5, 0.25, 1.0),
		0.75, 0.5]).to_byte_array())
	return bytes

func _append_projection(bytes: PackedByteArray, projection: Projection) -> void:
	var values := PackedFloat32Array()
	for column in 4:
		var axis: Vector4 = projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))
	bytes.append_array(values.to_byte_array())

func _append_transform(bytes: PackedByteArray, transform: Transform3D) -> void:
	for axis in [transform.basis.x, transform.basis.y, transform.basis.z]:
		bytes.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]).to_byte_array())
	bytes.append_array(PackedFloat32Array([transform.origin.x, transform.origin.y, transform.origin.z, 1.0]).to_byte_array())

func _ensure_white_ao(state: Dictionary) -> RID:
	var texture: RID = state.get("white_ao", RID())
	if texture.is_valid() and rd.texture_is_valid(texture):
		return texture
	var format := RDTextureFormat.new()
	format.width = 1
	format.height = 1
	format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	texture = rd.texture_create(format, RDTextureView.new(), [PackedByteArray([0, 0x3c])])
	if texture.is_valid():
		state.white_ao = texture
		state.owned.append(texture)
		state.cache_bytes = int(state.get("cache_bytes", 0)) + 2
		resource_revision += 1
	return texture

func _state_key(snapshot: Dictionary) -> String:
	var cache_key := str(snapshot.get("cache_key", ""))
	var world_id := int(snapshot.get("world_id", 0))
	return "%d/%s" % [world_id, cache_key] if world_id != 0 and not cache_key.is_empty() else ""

func _get_scene_gpu_script() -> Script:
	if not _scene_gpu_script_checked:
		_scene_gpu_script_checked = true
		if ResourceLoader.exists(SCENE_GPU_PATH):
			var loaded: Variant = load(SCENE_GPU_PATH)
			if loaded is Script:
				_scene_gpu_script = loaded
	return _scene_gpu_script

func _next_power_of_two(value: int) -> int:
	var result := 1
	while result < value:
		result <<= 1
	return result

func _finite_range(value: Variant, fallback: float, minimum: float, maximum: float) -> float:
	var number := float(value)
	return clampf(number, minimum, maximum) if is_finite(number) else fallback

func _probe_reservation(updates: int, rays: int, enabled: bool) -> Dictionary:
	var bounded_updates := maxi(updates, 1)
	var bounded_rays := clampi(rays, 1, 32)
	if not enabled:
		return {"effective_updates": bounded_updates, "max_probe_rays": 0}
	var alignment := bounded_rays if bounded_rays % 2 == 0 else bounded_rays * 2
	var available := mini(256, floori(float(bounded_updates * bounded_rays) / 8.0))
	var reserved_rays := int(available / alignment) * alignment
	var reserved_updates := int(reserved_rays / bounded_rays)
	return {"effective_updates": maxi(1, bounded_updates - reserved_updates),
		"max_probe_rays": reserved_rays}

func _snapshot_failure(snapshot: Dictionary) -> String:
	var reasons: Array = snapshot.get("unsupported_reasons", [])
	return str(reasons[0]) if not reasons.is_empty() else "Surfel geometry snapshot is not ready"

func _unique_rids(values: Array) -> Array[RID]:
	var result: Array[RID] = []
	var seen: Dictionary = {}
	for value in values:
		if value is RID and value.is_valid() and not seen.has(value):
			seen[value] = true
			result.append(value)
	return result

func _reversed_rids(values: Array) -> Array[RID]:
	var result: Array[RID] = []
	for index in range(values.size() - 1, -1, -1):
		var value: Variant = values[index]
		if value is RID:
			result.append(value)
	return result

func _free_rids(values: Array) -> void:
	if rd == null:
		return
	var seen: Dictionary = {}
	for index in range(values.size() - 1, -1, -1):
		var rid: Variant = values[index]
		if rid is RID and rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			rd.free_rid(rid)

func _fail(message: String) -> bool:
	error = message
	return false
