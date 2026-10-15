@tool
class_name FMagicGIRuntime
extends RefCounted
## Main-thread lighting publishes immutable, world-scoped PRT snapshots.

const RuntimeState = preload("feng_magic_gi_runtime_state.gd")
const PageStreamer = preload("feng_magic_gi_page_streamer.gd")
const Data = preload("feng_magic_gi_data.gd")
const PreviewExposure = preload("../feng-render-pipeline/passes/editor_preview_exposure_cache.gd")
const VIEWPORT_SCAN_MSEC := 1000
## Optional render-target registry shared by the FRP snapshot consumers.
const SNAPSHOT_WORLDS_PATH := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"

static var _registry: Dictionary = {}
static var _emission_revision_sequence := 0
static var _publish_sequence := 0
static var _snapshots: Array[Dictionary] = []
static var _preview_cache: Dictionary = {}
static var _editor_preview_viewports: Dictionary = {}
static var _streaming_requests: Dictionary = {}
static var _retired_streamers: Array = []
static var _retirement_poll_scheduled := false
static var _preview_view_frame := -1
static var _preview_view_cache: Array[Dictionary] = []
static var _mutex := Mutex.new()
static var _streaming_request_mutex := Mutex.new()
static var _last_frame := -1
static var _next_viewport_scan := 0
static var _worlds_queried := false
static var _worlds: GDScript = null
static var _viewport_owner := RefCounted.new() ## Lease for public calls without an explicit owner

static func _snapshot_worlds() -> GDScript:
	if not _worlds_queried:
		_worlds_queried = true
		if ResourceLoader.exists(SNAPSHOT_WORLDS_PATH):
			_worlds = load(SNAPSHOT_WORLDS_PATH)
	return _worlds

static func register(volume: FMagicGIVolume) -> void:
	var id := volume.get_instance_id()
	var state: RuntimeState = _registry.get(id)
	if state == null or state.get_volume() != volume:
		state = RuntimeState.new()
		state.attach(volume)
		_registry[id] = state
		_publish_sequence += 1
		state.published_sequence = _publish_sequence
	register_viewport(volume.get_viewport(), volume)

static func unregister(volume: FMagicGIVolume) -> void:
	var worlds := _snapshot_worlds()
	if worlds != null:
		worlds.unregister_owner(volume)
	var id := volume.get_instance_id()
	set_preview_requested(volume, false)
	var state: RuntimeState = _registry.get(id)
	if state != null:
		_retire_streamer(state.streamer)
	_registry.erase(id)
	_preview_cache.erase(id)
	_publish()

static func register_viewport(viewport: Viewport, owner: Object = null) -> void:
	var worlds := _snapshot_worlds()
	if worlds != null:
		worlds.register_viewport(viewport, owner if owner != null else _viewport_owner)

static func unregister_viewport(viewport: Viewport, owner: Object = null) -> void:
	if viewport != null and is_instance_valid(viewport):
		var worlds := _snapshot_worlds()
		if worlds != null:
			worlds.unregister_viewport(viewport, owner if owner != null else _viewport_owner)
		_publish()

## Registers an actual editor 3D viewport for exposure-aware debug materials.
## This stays separate from the world snapshot registry, which also includes
## ordinary scene and subviewports.
static func register_editor_preview_viewport(viewport: Viewport, owner: Object) -> void:
	if viewport == null or not is_instance_valid(viewport) or owner == null or not is_instance_valid(owner):
		return
	var viewport_id := viewport.get_instance_id()
	_editor_preview_viewports[viewport_id] = {"viewport_ref": weakref(viewport), "owner_ref": weakref(owner)}
	_preview_view_frame = -1
	PreviewExposure.register_editor_viewport(viewport, owner)

static func unregister_editor_preview_viewport(viewport: Viewport, owner: Object) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	var viewport_id := viewport.get_instance_id()
	PreviewExposure.unregister_editor_viewport(viewport, owner)
	var entry: Dictionary = _editor_preview_viewports.get(viewport_id, {})
	var registered_owner: Object = entry.get("owner_ref", null).get_ref() if entry.get("owner_ref", null) is WeakRef else null
	if registered_owner == owner:
		_editor_preview_viewports.erase(viewport_id)
	_preview_view_frame = -1

static func set_preview_requested(volume: FMagicGIVolume, requested: bool) -> void:
	if volume == null or not is_instance_valid(volume):
		return
	PreviewExposure.set_preview_requested(volume.get_instance_id(), requested)
	_preview_view_frame = -1

static func publish(volume: FMagicGIVolume) -> void:
	if volume.is_inside_tree():
		register(volume)
		var id := volume.get_instance_id()
		var state: RuntimeState = _registry.get(id)
		var data := volume.bake_data
		var data_key := ""
		if volume.bake_manifest != null and is_instance_valid(volume.bake_manifest):
			data_key = "stream:%s:%s" % [volume.bake_manifest.manifest_key,
				volume.bake_manifest.generation]
		elif data != null:
			data_key = "%d:%d:%d" % [data.get_instance_id(), data.bake_version,
				volume.data_revision()]
		if state.data_key != data_key:
			state.data_key = data_key
			_publish_sequence += 1
			state.published_sequence = _publish_sequence
	_publish()

## Called by FRP while preparing a render view. Only RID identifiers and value
## types cross this boundary; Resource loading and page publication stay on the
## main thread in tick().
static func request_streaming_view(target: RID, view_id: int, camera: Vector3,
		visible_bounds: AABB = AABB()) -> void:
	if not target.is_valid() or view_id < 0 or not camera.is_finite():
		return
	var target_id := int(target.get_id())
	var key := "%d:%d" % [target_id, view_id]
	_streaming_request_mutex.lock()
	_streaming_requests[key] = {"target_id": target_id, "view_id": view_id,
		"camera": camera, "bounds": visible_bounds}
	_streaming_request_mutex.unlock()

static func tick() -> void:
	var frame := Engine.get_process_frames()
	if _last_frame == frame:
		return
	_last_frame = frame
	var now := Time.get_ticks_msec()
	if now >= _next_viewport_scan:
		_refresh_viewports()
		_next_viewport_scan = now + VIEWPORT_SCAN_MSEC
	_publish()

static func snapshots() -> Array[Dictionary]:
	# Published arrays and dictionaries are immutable by convention. The producer
	# replaces the whole array under the mutex instead of mutating a published one.
	_mutex.lock()
	var result := _snapshots
	_mutex.unlock()
	return result

## Returns the current editor-preview inputs for this volume, including when it
## is disabled or not selected for rendering. Published values are reused for
## the selected volume; other volumes read from the same cached producers.
static func preview_snapshot(volume: FMagicGIVolume) -> Dictionary:
	if volume == null or not is_instance_valid(volume) or not volume.is_inside_tree():
		return {}
	var id := volume.get_instance_id()
	var state: RuntimeState = _registry.get(id)
	if volume.bake_manifest != null and is_instance_valid(volume.bake_manifest):
		var manifest := volume.bake_manifest
		var lighting := PackedFloat32Array()
		var sky_lighting := PackedFloat32Array()
		var pages: Array[Dictionary] = []
		var streaming_status: Dictionary = {}
		if state != null and state.get_volume() == volume:
			var published := _published_snapshot_for_volume(id)
			if not published.is_empty() and published.get("manifest") == manifest:
				lighting = published.get("lighting", PackedFloat32Array())
				sky_lighting = published.get("sky_lighting", PackedFloat32Array())
				pages = published.get("pages", [])
				streaming_status = published.get("streaming_status", {})
			else:
				var lighting_sets: Dictionary = state.lighting.coefficient_sets(volume)
				lighting = lighting_sets.get("lighting", PackedFloat32Array())
				sky_lighting = lighting_sets.get("sky_lighting", PackedFloat32Array())
				pages = state.streamer.ready_pages(lighting, sky_lighting)
				streaming_status = state.streamer.status()
		var data_valid := volume.has_usable_bake()
		var current_available := lighting.size() == 27 and sky_lighting.size() == 27
		var streamer_revision := state.streamer.revision() if state != null else 0
		var page_layout_revision := state.streamer.layout_revision() if state != null else 0
		var lighting_revision := state.lighting.revision if state != null else 0
		var layout_key := "%s:%s:%d" % [manifest.manifest_key,
			manifest.generation, page_layout_revision]
		var revision_values: Array = [id, manifest.manifest_key, manifest.generation,
			data_valid, current_available, streamer_revision, lighting_revision,
			volume.gi_strength, volume.preview_revision(), streaming_status.get("active_pages", 0),
			streaming_status.get("resident_pages", 0), streaming_status.get("loading_pages", 0),
			streaming_status.get("budget_blocked_pages", 0)]
		var revision := hash(revision_values)
		var editor_views := _editor_preview_view_snapshots()
		var view_revision_values: Array = []
		for view in editor_views:
			view_revision_values.append_array([
				view.get("target_id", 0), view.get("origin", Vector3.ZERO),
				view.get("right", Vector3.RIGHT), view.get("up", Vector3.UP),
				view.get("back", Vector3.BACK), view.get("projection_x", 0.0),
				view.get("projection_y", 0.0), view.get("orthogonal", false),
				view.get("viewport_size", Vector2.ZERO), view.get("exposure_scale", 1.0),
				view.get("exposure_valid", false)])
		var view_revision := hash(view_revision_values)
		var cached: Dictionary = _preview_cache.get(id, {})
		if bool(cached.get("streamed", false)) \
				and int(cached.get("revision", 0)) == revision \
				and int(cached.get("view_revision", 0)) == view_revision:
			cached["layout_stale"] = volume.is_layout_stale()
			return cached
		var result := {
			"streamed": true,
			"manifest": manifest,
			"data": null,
			"data_valid": data_valid,
			"layout_matches": data_valid,
			"current_available": current_available,
			"pages": pages,
			"page_layout_key": layout_key,
			"total_pages": manifest.get_page_count(),
			"streaming_status": streaming_status,
			"lighting": lighting,
			"sky_lighting": sky_lighting,
			"strength": volume.gi_strength,
			"layout_stale": volume.is_layout_stale(),
			"revision": revision,
			"editor_views": editor_views,
			"view_revision": view_revision,
		}
		_preview_cache[id] = result
		return result
	var data := volume.bake_data
	var data_valid := data != null and volume.has_usable_bake()
	var layout_matches := data_valid and volume.preview_layout_matches(data)
	var lighting := PackedFloat32Array()
	var sky_lighting := PackedFloat32Array()
	var emission_payload := PackedFloat32Array()
	var current_available := false
	if layout_matches and state != null and state.get_volume() == volume:
		var published := _published_snapshot_for_volume(id)
		if not published.is_empty() and published.get("data") == data:
			lighting = published.get("lighting", PackedFloat32Array())
			sky_lighting = published.get("sky_lighting", PackedFloat32Array())
			emission_payload = published.get("emission_payload", PackedFloat32Array())
		else:
			var lighting_sets: Dictionary = state.lighting.coefficient_sets(volume)
			lighting = lighting_sets.get("lighting", PackedFloat32Array())
			sky_lighting = lighting_sets.get("sky_lighting", PackedFloat32Array())
			if state.emission.update_snapshot(volume, data):
				_emission_revision_sequence += 1
				state.emission.revision = _emission_revision_sequence
			emission_payload = state.emission.payload
		current_available = lighting.size() == 27 and sky_lighting.size() == 27
	var lighting_revision := state.lighting.revision if state != null else 0
	var emission_revision := state.emission.revision if state != null else 0
	var revision_values: Array = [id, data.get_instance_id() if data != null else 0,
			data.bake_version if data != null else 0, volume.data_revision(),
			data_valid, layout_matches,
			volume.probe_layout_revision(), volume.preview_revision(),
			volume.gi_strength, current_available, lighting_revision, emission_revision]
	var revision := hash(revision_values)
	var editor_views := _editor_preview_view_snapshots()
	var view_revision_values: Array = []
	for view in editor_views:
		view_revision_values.append_array([
			view.get("target_id", 0), view.get("origin", Vector3.ZERO),
			view.get("right", Vector3.RIGHT), view.get("up", Vector3.UP),
			view.get("back", Vector3.BACK), view.get("projection_x", 0.0),
			view.get("projection_y", 0.0), view.get("orthogonal", false),
			view.get("viewport_size", Vector2.ZERO), view.get("exposure_scale", 1.0),
			view.get("exposure_valid", false)])
	var view_revision := hash(view_revision_values)
	var cached: Dictionary = _preview_cache.get(id, {})
	if int(cached.get("revision", 0)) == revision \
			and int(cached.get("view_revision", 0)) == view_revision:
		cached["layout_stale"] = volume.is_layout_stale()
		return cached
	var result := {
		"data": data if data_valid else null,
		"data_valid": data_valid,
		"layout_matches": layout_matches,
		"current_available": current_available,
		"lighting": lighting,
		"sky_lighting": sky_lighting,
		"emission_payload": emission_payload,
		"strength": volume.gi_strength,
		"layout_stale": volume.is_layout_stale(),
		"revision": revision,
		"editor_views": editor_views,
		"view_revision": view_revision,
	}
	_preview_cache[id] = result
	return result

static func _editor_preview_view_snapshots() -> Array[Dictionary]:
	var frame := Engine.get_process_frames()
	if _preview_view_frame == frame:
		return _preview_view_cache
	var viewport_ids: Array = _editor_preview_viewports.keys()
	viewport_ids.sort()
	var result: Array[Dictionary] = []
	for viewport_id_variant in viewport_ids:
		var viewport_id := int(viewport_id_variant)
		var entry: Dictionary = _editor_preview_viewports.get(viewport_id, {})
		var viewport: Object = entry.get("viewport_ref", null).get_ref() if entry.get("viewport_ref", null) is WeakRef else null
		var owner: Object = entry.get("owner_ref", null).get_ref() if entry.get("owner_ref", null) is WeakRef else null
		if viewport == null or not is_instance_valid(viewport) or owner == null or not is_instance_valid(owner):
			_editor_preview_viewports.erase(viewport_id)
			continue
		var editor_viewport := viewport as Viewport
		PreviewExposure.refresh_editor_viewport(editor_viewport, owner)
		var target_id := PreviewExposure.target_id_for_viewport(editor_viewport)
		var camera := editor_viewport.get_camera_3d()
		if target_id == 0 or camera == null or not is_instance_valid(camera):
			continue
		var transform := camera.get_camera_transform()
		var basis := transform.basis.orthonormalized()
		var projection := camera.get_camera_projection()
		var exposure: Dictionary = PreviewExposure.get_snapshot(target_id, 0)
		result.append({
			"target_id": target_id,
			"view": 0,
			"origin": transform.origin,
			"right": basis.x,
			"up": basis.y,
			"back": basis.z,
			"projection_x": absf(projection.x.x),
			"projection_y": absf(projection.y.y),
			"orthogonal": camera.projection == Camera3D.PROJECTION_ORTHOGONAL,
			"viewport_size": Vector2(editor_viewport.size),
			"exposure_scale": float(exposure.get("exposure_scale", 1.0)) if bool(exposure.get("valid", false)) else 1.0,
			"exposure_valid": bool(exposure.get("valid", false)),
			"sequence": int(exposure.get("sequence", 0)),
		})
	_preview_view_cache = result
	_preview_view_frame = frame
	return _preview_view_cache

static func _published_snapshot_for_volume(volume_id: int) -> Dictionary:
	_mutex.lock()
	for snapshot in _snapshots:
		if int(snapshot.get("volume_id", -1)) == volume_id:
			_mutex.unlock()
			return snapshot
	_mutex.unlock()
	return {}

static func emission_warning(volume: FMagicGIVolume) -> String:
	if volume == null or not is_instance_valid(volume):
		return ""
	var state: RuntimeState = _registry.get(volume.get_instance_id())
	if state == null:
		return ""
	if volume.bake_manifest != null:
		var messages := PackedStringArray()
		if not state.streamer.warning.is_empty():
			messages.append(state.streamer.warning)
		var source_warning := state.streamer.emission_warning()
		if not source_warning.is_empty() and not messages.has(source_warning):
			messages.append(source_warning)
		return "; ".join(messages)
	return state.emission.warning

static func streaming_status(volume: FMagicGIVolume) -> Dictionary:
	if volume == null or not is_instance_valid(volume):
		return {}
	var state: RuntimeState = _registry.get(volume.get_instance_id())
	if state == null or state.get_volume() != volume:
		return {}
	var result := state.streamer.status()
	result["cpu_budget_bytes"] = volume.cpu_resident_budget_bytes
	result["gpu_budget_bytes"] = volume.gpu_resident_budget_bytes
	return result

## Refreshes warnings for a volume that may not currently be selected for a
## viewport. This explicit, throttled path keeps configuration warnings useful
## without making the warning getter mutate emission state.
static func refresh_emission_diagnostics(volume: FMagicGIVolume) -> void:
	if volume == null or not is_instance_valid(volume) or not volume.is_inside_tree():
		return
	var state: RuntimeState = _registry.get(volume.get_instance_id())
	if state == null:
		return
	_mutex.lock()
	for snapshot in _snapshots:
		if int(snapshot["volume_id"]) == volume.get_instance_id():
			_mutex.unlock()
			return # The selected volume's warning was refreshed by _publish().
	_mutex.unlock()
	if not volume.has_usable_bake():
		state.emission.warning = ""
		return
	if volume.bake_manifest != null:
		return # Page source diagnostics are refreshed by the page streamer.
	state.emission.read_source_values(volume, volume.bake_data)

static func _refresh_viewports() -> void:
	var worlds := _snapshot_worlds()
	for id in _registry.keys():
		var state: RuntimeState = _registry[id]
		var volume := state.get_volume()
		if volume == null or not volume.is_inside_tree():
			continue
		if worlds != null:
			worlds.register_viewport(volume.get_viewport(), volume)
			var root: Node = volume
			while root.get_parent() != null and not root.get_parent() is Viewport:
				root = root.get_parent()
			worlds.scan(root, volume)
	if worlds != null:
		worlds.prune()

static func _render_targets(world: World3D) -> Array[RID]:
	var worlds := _snapshot_worlds()
	return worlds.targets_for(world) if worlds != null else []

static func _take_streaming_requests() -> Array[Dictionary]:
	var requests: Array[Dictionary] = []
	_streaming_request_mutex.lock()
	for value in _streaming_requests.values():
		requests.append(value)
	_streaming_requests.clear()
	_streaming_request_mutex.unlock()
	return requests

static func _publish() -> void:
	_drain_retired_streamers()
	var selected: Dictionary = {} # world instance id -> latest valid volume
	for id in _registry.keys():
		var state: RuntimeState = _registry[id]
		var volume := state.get_volume()
		if volume == null:
			_retire_streamer(state.streamer)
			_registry.erase(id)
			continue
		if not volume.is_inside_tree():
			state.emission.warning = ""
			continue
		if not volume.enabled:
			continue
		if not volume.has_usable_bake():
			state.emission.warning = ""
			continue
		var world := volume.get_world_3d()
		if world == null:
			continue
		var world_id := world.get_instance_id()
		if not selected.has(world_id) or state.published_sequence > selected[world_id].published_sequence:
			selected[world_id] = state
	var targets_to_state: Dictionary = {}
	var selected_state_ids: Dictionary = {}
	for world_id in selected:
		var state: RuntimeState = selected[world_id]
		selected_state_ids[state.get_instance_id()] = true
		var volume := state.get_volume()
		if volume == null:
			continue
		for target in _render_targets(volume.get_world_3d()):
			if target.is_valid():
				targets_to_state[int(target.get_id())] = state
	var now := Time.get_ticks_msec()
	for request in _take_streaming_requests():
		var state: RuntimeState = targets_to_state.get(int(request.get("target_id", 0)))
		if state == null:
			continue
		var volume := state.get_volume()
		if volume == null or volume.bake_manifest == null:
			continue
		state.streamer.request_view(int(request.target_id), int(request.view_id),
				request.camera, request.bounds, now)
	for id in _registry.keys():
		var state: RuntimeState = _registry[id]
		var volume := state.get_volume()
		if volume == null or not selected_state_ids.has(state.get_instance_id()) \
				or volume.bake_manifest == null:
			state.streamer.deactivate()
			state.streamer.drain_completed()
		elif volume.is_inside_tree() and volume.enabled:
			state.streamer.refresh(volume, now)
	_drain_retired_streamers()
	var result: Array[Dictionary] = []
	for world_id in selected.keys():
		var state: RuntimeState = selected[world_id]
		var volume := state.get_volume()
		var id := volume.get_instance_id()
		var world := volume.get_world_3d()
		if world == null:
			continue
		var data := volume.bake_data
		var lighting_sets: Dictionary = state.lighting.coefficient_sets(volume)
		if volume.bake_manifest != null:
			var manifest := volume.bake_manifest
			var streamed_pages := state.streamer.ready_pages(
				lighting_sets.get("lighting", PackedFloat32Array()),
				lighting_sets.get("sky_lighting", PackedFloat32Array()))
			var pending_pages := state.streamer.pending_pages()
			var cache_key := "%d:stream:%s:%s" % [id, manifest.manifest_key, manifest.generation]
			result.append({
				"streamed": true,
				"manifest": manifest,
				"manifest_key": manifest.manifest_key,
				"generation": manifest.generation,
				"pages": streamed_pages,
				"pending_pages": pending_pages,
				"pending_page_keys": state.streamer.pending_page_keys(),
				"streaming_budget": {
					"cpu_resident_bytes": volume.cpu_resident_budget_bytes,
					"cpu_bytes": volume.cpu_resident_budget_bytes,
					"gpu_bytes": volume.gpu_resident_budget_bytes,
					"gpu_resident_bytes": volume.gpu_resident_budget_bytes,
					"upload_bytes_per_frame": volume.upload_budget_bytes_per_frame,
					"inflight_loads": state.streamer.inflight_count(),
					"max_inflight": clampi(volume.max_inflight_page_loads, 1, 2),
				},
				"streaming_status": state.streamer.status(),
				"data": null,
				"version": hash([manifest.manifest_key, manifest.generation]),
				"cache_key": cache_key,
				"strength": volume.gi_strength,
				"use_clv": volume.use_clv,
				"clv_cell_size": clampf(volume.clv_cell_size, 0.1, 2.0),
				"clv_cells_per_frame": clampi(volume.clv_cells_per_frame, 32, 512),
				"lighting": lighting_sets.get("lighting", PackedFloat32Array()),
				"sky_lighting": lighting_sets.get("sky_lighting", PackedFloat32Array()),
				"replacement_enabled": manifest.is_valid() and state.streamer.has_active_pages(),
				"emission_payload": PackedFloat32Array(),
				"emission_sources": PackedFloat32Array(),
				"emission_revision": state.streamer.revision(),
				"emission_identity": cache_key,
				"world_id": world_id,
				"volume_id": id,
				"owner_transform": volume.global_transform,
				"owner_size": volume.size,
				"render_targets": _render_targets(world),
			})
			continue
		if data == null:
			continue
		var bake_version: int = data.bake_version
		var data_id := data.get_instance_id()
		var data_revision := volume.data_revision()
		var data_token := hash([data_id, bake_version, data_revision])
		var cache_key := "%d:%d:%d:%d" % [id, data_id, bake_version, data_revision]
		# A usable preview still owns indirect diffuse. Making a stale bake additive
		# restores unoccluded SkyLight under it, brightening interiors and hiding shadows.
		# Staleness remains reported by the volume; it does not change composition.
		var replacement_enabled := data.format_version == Data.FORMAT_VERSION
		if state.emission.update_snapshot(volume, data):
			_emission_revision_sequence += 1
			state.emission.revision = _emission_revision_sequence
		result.append({
			"data": data,
			"version": data_token,
			"cache_key": cache_key,
			"strength": volume.gi_strength,
			"use_clv": volume.use_clv,
			"clv_cell_size": clampf(volume.clv_cell_size, 0.1, 2.0),
			"clv_cells_per_frame": clampi(volume.clv_cells_per_frame, 32, 512),
			"lighting": lighting_sets.get("lighting", PackedFloat32Array()),
			"sky_lighting": lighting_sets.get("sky_lighting", PackedFloat32Array()),
			"replacement_enabled": replacement_enabled,
			"emission_payload": state.emission.payload,
			"emission_sources": state.emission.source_values(),
			"emission_revision": state.emission.revision,
			"emission_identity": state.emission.identity,
			"world_id": world_id,
			"volume_id": id,
			"render_targets": _render_targets(volume.get_world_3d()),
		})
	_mutex.lock()
	_snapshots = result
	_mutex.unlock()

static func _retire_streamer(streamer: PageStreamer) -> void:
	if streamer == null:
		return
	streamer.deactivate()
	streamer.drain_completed()
	if streamer.is_drained():
		return
	if not _retired_streamers.has(streamer):
		_retired_streamers.append(streamer)
	_schedule_retirement_poll()

static func _drain_retired_streamers() -> void:
	for index in range(_retired_streamers.size() - 1, -1, -1):
		var streamer: PageStreamer = _retired_streamers[index]
		streamer.drain_completed()
		if streamer.is_drained():
			_retired_streamers.remove_at(index)
	if not _retired_streamers.is_empty():
		_schedule_retirement_poll()

static func _schedule_retirement_poll() -> void:
	if _retirement_poll_scheduled or _retired_streamers.is_empty():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_retirement_poll_scheduled = true
	tree.create_timer(0.05).timeout.connect(
		Callable(FMagicGIRuntime, "_on_retirement_poll"), CONNECT_ONE_SHOT)

static func _on_retirement_poll() -> void:
	_retirement_poll_scheduled = false
	_drain_retired_streamers()
