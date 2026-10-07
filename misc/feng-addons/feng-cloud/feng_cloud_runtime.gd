@tool
class_name FengCloudRuntime
extends RefCounted
## Main-thread owner of immutable, world-scoped cloud snapshots.
##
## The registry stores weak component references only. A world query validates
## its current owner and returns the newest live enabled cloud; no SceneTree
## traversal is performed here.

const SNAPSHOT_WORLDS_PATH := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"
const SKY_RUNTIME_PATH := "res://addons/feng-sky/feng_sky_runtime.gd"

static var _providers_by_world: Dictionary = {} # world id -> Array[Dictionary]
static var _published_by_world: Dictionary = {} # render-thread-safe copied snapshots; no Node access.
static var _published_mutex := Mutex.new()
static var _next_sequence := 0
static var _snapshot_worlds_queried := false
static var _snapshot_worlds: GDScript
static var _sky_runtime_queried := false
static var _sky_runtime: GDScript
static var _viewport_owner := RefCounted.new()


static func register_cloud(cloud: FengVolumetricCloud, world: World3D) -> int:
	if cloud == null or not is_instance_valid(cloud) or world == null or not is_instance_valid(world):
		return 0
	var world_id := world.get_instance_id()
	var entries: Array = _providers_by_world.get(world_id, [])
	var owner_id := cloud.get_instance_id()
	for entry in entries:
		var reference: WeakRef = entry.get("owner")
		var current: Object = reference.get_ref() if reference != null else null
		if current == cloud:
			return world_id
	_next_sequence += 1
	entries.append({"owner_id": owner_id, "owner": weakref(cloud), "sequence": _next_sequence, "snapshot": {}})
	_providers_by_world[world_id] = entries
	return world_id


static func unregister_cloud(cloud: FengVolumetricCloud, world_id: int) -> void:
	if world_id == 0:
		return
	var entries: Array = _providers_by_world.get(world_id, [])
	var owner_id := cloud.get_instance_id() if cloud != null and is_instance_valid(cloud) else 0
	for index in range(entries.size() - 1, -1, -1):
		var entry: Dictionary = entries[index]
		var reference: WeakRef = entry.get("owner")
		var current: Object = reference.get_ref() if reference != null else null
		if current == null or not is_instance_valid(current) or int(entry.get("owner_id", 0)) == owner_id:
			entries.remove_at(index)
	if entries.is_empty():
		_providers_by_world.erase(world_id)
	else:
		_providers_by_world[world_id] = entries
	_refresh_published_world(world_id)


static func publish_cloud(cloud: FengVolumetricCloud, world_id: int, snapshot: Dictionary) -> void:
	if cloud == null or not is_instance_valid(cloud) or world_id == 0:
		return
	var entries: Array = _providers_by_world.get(world_id, [])
	var owner_id := cloud.get_instance_id()
	for index in range(entries.size()):
		var entry: Dictionary = entries[index]
		if int(entry.get("owner_id", 0)) == owner_id:
			var published := snapshot.duplicate(true)
			var world := cloud.get_world_3d()
			var worlds := _get_snapshot_worlds()
			if world != null and is_instance_valid(world) and worlds != null and worlds.has_method("targets_for"):
				var targets: Variant = worlds.call("targets_for", world)
				published["render_targets"] = targets if targets is Array else []
			else:
				published["render_targets"] = []
			entry["snapshot"] = published
			entries[index] = entry
			_providers_by_world[world_id] = entries
			_refresh_published_world(world_id)
			return


static func snapshot_for_world(world_id: int) -> Dictionary:
	if world_id == 0:
		return {}
	var entries: Array = _providers_by_world.get(world_id, [])
	var changed := false
	for index in range(entries.size() - 1, -1, -1):
		var entry: Dictionary = entries[index]
		var reference: WeakRef = entry.get("owner")
		var owner: Object = reference.get_ref() if reference != null else null
		if owner == null or not is_instance_valid(owner):
			entries.remove_at(index)
			changed = true
			continue
		if not owner.has_method("_feng_cloud_runtime_is_active") \
				or not bool(owner.call("_feng_cloud_runtime_is_active", world_id)):
			continue
		if changed:
			_store_entries(world_id, entries)
		return (entry.get("snapshot", {}) as Dictionary).duplicate(true)
	if changed:
		_store_entries(world_id, entries)
	return {}


## FengRuntimeSnapshotPass routes by render target. Build only the targets leased to
## each live cloud world's viewports; providers themselves remain weakly held.
static func snapshots() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	_published_mutex.lock()
	for snapshot in _published_by_world.values():
		if snapshot is Dictionary and not snapshot.is_empty():
			result.append(snapshot.duplicate(true))
	_published_mutex.unlock()
	return result


## Called on the main thread after a provider publishes or leaves. Render callbacks
## only read the resulting value snapshot and never resolve instance IDs or Nodes.
static func _refresh_published_world(world_id: int) -> void:
	var entries: Array = _providers_by_world.get(world_id, [])
	for index in range(entries.size() - 1, -1, -1):
		var entry: Dictionary = entries[index]
		var reference: WeakRef = entry.get("owner")
		var owner: Object = reference.get_ref() if reference != null else null
		if owner == null or not is_instance_valid(owner):
			entries.remove_at(index)
			continue
		if not owner.has_method("_feng_cloud_runtime_is_active") \
				or not bool(owner.call("_feng_cloud_runtime_is_active", world_id)):
			continue
		var snapshot: Variant = entry.get("snapshot", {})
		if snapshot is Dictionary and not snapshot.is_empty():
			_providers_by_world[world_id] = entries
			_published_mutex.lock()
			_published_by_world[world_id] = snapshot.duplicate(true)
			_published_mutex.unlock()
			return
	if entries.is_empty():
		_providers_by_world.erase(world_id)
	else:
		_providers_by_world[world_id] = entries
	_published_mutex.lock()
	_published_by_world.erase(world_id)
	_published_mutex.unlock()


static func register_viewport(viewport: Viewport, owner: Object = null) -> void:
	var worlds := _get_snapshot_worlds()
	if worlds != null and viewport != null and is_instance_valid(viewport):
		worlds.call("register_viewport", viewport, owner if owner != null else _viewport_owner)


static func unregister_viewport(viewport: Viewport, owner: Object = null) -> void:
	var worlds := _get_snapshot_worlds()
	if worlds != null and viewport != null and is_instance_valid(viewport):
		worlds.call("unregister_viewport", viewport, owner if owner != null else _viewport_owner)


static func sky_rendering_snapshot_for_world(world_id: int) -> Dictionary:
	if world_id == 0:
		return {}
	if not _sky_runtime_queried:
		_sky_runtime_queried = true
		if ResourceLoader.exists(SKY_RUNTIME_PATH):
			var loaded: Variant = load(SKY_RUNTIME_PATH)
			if loaded is GDScript and loaded.has_method("rendering_snapshot_for_world"):
				_sky_runtime = loaded
	if _sky_runtime == null:
		return {}
	var result: Variant = _sky_runtime.call("rendering_snapshot_for_world", world_id)
	return result if result is Dictionary else {}


static func _get_snapshot_worlds() -> GDScript:
	if not _snapshot_worlds_queried:
		_snapshot_worlds_queried = true
		if ResourceLoader.exists(SNAPSHOT_WORLDS_PATH):
			var loaded: Variant = load(SNAPSHOT_WORLDS_PATH)
			if loaded is GDScript:
				_snapshot_worlds = loaded
	return _snapshot_worlds


static func _store_entries(world_id: int, entries: Array) -> void:
	if entries.is_empty():
		_providers_by_world.erase(world_id)
		_published_mutex.lock()
		_published_by_world.erase(world_id)
		_published_mutex.unlock()
	else:
		_providers_by_world[world_id] = entries
		_refresh_published_world(world_id)


static func viewport_generation_for_world(world: World3D) -> int:
	var worlds := _get_snapshot_worlds()
	if world == null or not is_instance_valid(world) or worlds == null or not worlds.has_method("generation_for_world"):
		return -1
	return int(worlds.call("generation_for_world", world))
