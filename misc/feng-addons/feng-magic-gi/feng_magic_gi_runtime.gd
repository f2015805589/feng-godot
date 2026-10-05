@tool
class_name FMagicGIRuntime
extends RefCounted
## Main-thread lighting publishes immutable, world-scoped PRT snapshots.

const RuntimeState = preload("feng_magic_gi_runtime_state.gd")
const Data = preload("feng_magic_gi_data.gd")
const VIEWPORT_SCAN_MSEC := 1000
## Optional render-target registry shared by the FRP snapshot consumers.
const SNAPSHOT_WORLDS_PATH := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"

# One per-volume entry owns its weak reference, lighting calculator, emission
# helper/cache, data identity, and diagnostic state. Viewports and publication
# are service-wide concerns and remain separate.
static var _registry: Dictionary = {}
static var _emission_revision_sequence := 0
static var _publish_sequence := 0
static var _snapshots: Array[Dictionary] = []
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
		state.data_key = ""
	register_viewport(volume.get_viewport(), volume)

static func unregister(volume: FMagicGIVolume) -> void:
	var worlds := _snapshot_worlds()
	if worlds != null:
		worlds.unregister_owner(volume)
	var id := volume.get_instance_id()
	_registry.erase(id)
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

static func emission_warning(volume: FMagicGIVolume) -> String:
	if volume == null or not is_instance_valid(volume):
		return ""
	var state: RuntimeState = _registry.get(volume.get_instance_id())
	return state.emission_warning if state != null else ""

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
		state.emission_warning = ""
		return
	state.refresh_emission_diagnostics(volume, volume.bake_data)

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
			state.emission_warning = ""
			continue
		if not volume.enabled:
			continue
		if not volume.has_usable_bake():
			state.emission_warning = ""
			continue
		var world := volume.get_world_3d()
		if world == null:
			continue
		var world_id := world.get_instance_id()
		if not selected.has(world_id) or state.published_sequence > int(selected[world_id].sequence):
			selected[world_id] = {"volume": volume, "state": state,
					"sequence": state.published_sequence, "id": id, "world": world}
	var result: Array[Dictionary] = []
	for world_id in selected.keys():
		var entry: Dictionary = selected[world_id]
		var volume: FMagicGIVolume = entry.volume
		var state: RuntimeState = entry.state
		var id: int = entry.id
		var data := volume.bake_data
		var bake_version: int = data.bake_version
		var cache_key := "%d:%d" % [id, bake_version]
		var lighting_sets: Dictionary = state.lighting.coefficient_sets(volume)
		var replacement_enabled := data.format_version == Data.FORMAT_VERSION \
				and volume.has_bake()
		if state.update_emission_snapshot(volume, data, bake_version):
			_emission_revision_sequence += 1
			state.emission_revision = _emission_revision_sequence
		result.append({
			"data": data,
			"version": bake_version,
			"cache_key": cache_key,
			"strength": volume.gi_strength,
			"lighting": lighting_sets.get("lighting", PackedFloat32Array()),
			"sky_lighting": lighting_sets.get("sky_lighting", PackedFloat32Array()),
			"replacement_enabled": replacement_enabled,
			"emission_payload": state.emission_payload,
			"emission_revision": state.emission_revision,
			"emission_identity": state.emission_identity,
			"world_id": world_id,
			"volume_id": id,
			"render_targets": _render_targets(entry.world),
		})
	_mutex.lock()
	_snapshots = result
	_mutex.unlock()
