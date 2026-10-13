@tool
class_name FMagicGIRuntime
extends RefCounted
## Main-thread lighting publishes immutable, world-scoped PRT snapshots.

const RuntimeState = preload("feng_magic_gi_runtime_state.gd")
const Data = preload("feng_magic_gi_data.gd")
const Preview = preload("feng_magic_gi_preview.gd")
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
static var _preview_view_frame := -1
static var _preview_view_cache: Array[Dictionary] = []
static var _mutex := Mutex.new()
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
		var data_key := "%d:%d" % [data.get_instance_id(), data.bake_version] if data != null else ""
		if state.data_key != data_key:
			state.data_key = data_key
			_publish_sequence += 1
			state.published_sequence = _publish_sequence
	_publish()

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
	var data := volume.bake_data
	var data_valid := volume.has_usable_bake()
	var layout_matches := data_valid and Preview.layout_matches(data, volume.probe_positions)
	var state: RuntimeState = _registry.get(id)
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
	var revision_values: Array = [id, data.get_instance_id() if data != null else 0,
			data.bake_version if data != null else 0, data_valid, layout_matches,
			volume.probe_positions, volume.gi_strength, current_available]
	if current_available:
		revision_values.append_array([lighting, sky_lighting, emission_payload])
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
	return state.emission.warning if state != null else ""

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

static func _publish() -> void:
	var selected: Dictionary = {} # world instance id -> latest valid volume
	for id in _registry.keys():
		var state: RuntimeState = _registry[id]
		var volume := state.get_volume()
		if volume == null:
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
	var result: Array[Dictionary] = []
	for world_id in selected.keys():
		var state: RuntimeState = selected[world_id]
		var volume := state.get_volume()
		var id := volume.get_instance_id()
		var data := volume.bake_data
		var bake_version: int = data.bake_version
		var cache_key := "%d:%d" % [id, bake_version]
		var lighting_sets: Dictionary = state.lighting.coefficient_sets(volume)
		# A usable preview still owns indirect diffuse. Making a stale bake additive
		# restores unoccluded SkyLight under it, brightening interiors and hiding shadows.
		# Staleness remains reported by the volume; it does not change composition.
		var replacement_enabled := data.format_version == Data.FORMAT_VERSION
		if state.emission.update_snapshot(volume, data):
			_emission_revision_sequence += 1
			state.emission.revision = _emission_revision_sequence
		result.append({
			"data": data,
			"version": bake_version,
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
