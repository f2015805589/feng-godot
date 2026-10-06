@tool
extends RefCounted
## Shared viewport → World3D → render-target registry behind the world-scoped
## snapshot contract that runtime_snapshot_pass.gd defines.
##
## Producer runtimes register the viewports they render to. World changes update
## only the affected buckets; queries still validate the requested bucket's
## weak references and live World3D identity before returning any route.

const REGISTRY_SWEEP_BUDGET := 32

static var _viewports: Dictionary = {} ## viewport id -> WeakRef
static var _viewport_owners: Dictionary = {} ## viewport id -> {owner id: WeakRef}; 0 is the legacy lease
static var _viewport_world_ids: Dictionary = {} ## last observed live World3D identity
static var _viewports_by_world: Dictionary = {} ## world id -> {viewport id: true}
static var _world_generations: Dictionary = {} ## world id -> route generation
static var _next_world_generation := 0
static var _targets_cache: Dictionary = {} ## world id -> {generation, targets}
static var _viewport_world_callbacks: Dictionary = {} ## viewport id -> callback; captures only the id
static var _legacy_viewports: Dictionary = {} ## viewports without world_3d_changed need old full validation
static var _owner_refs: Dictionary = {} ## owner id -> WeakRef
static var _owner_viewports: Dictionary = {} ## owner id -> {viewport id: true}
static var _owner_sweep_ids: Array[int] = []
static var _owner_sweep_queued: Dictionary = {}
static var _owner_sweep_cursor := 0
static var _owner_sweep_frame := -1
static var _viewport_sweep_ids: Array[int] = []
static var _viewport_sweep_queued: Dictionary = {}
static var _viewport_sweep_cursor := 0
static var _viewport_sweep_frame := -1
static var _targets_version := 0 ## retained for diagnostics/tests that observe any route change

## Registrations are idempotent per owner. The optional owner keeps independent
## producers from removing each other's routes; it is held weakly. Calls without
## an owner retain their original register/unregister behavior as one legacy lease.
static func register_viewport(viewport: Viewport, owner: Object = null) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	var id := viewport.get_instance_id()
	var existing_ref: WeakRef = _viewports.get(id)
	var existing_viewport: Viewport = existing_ref.get_ref() if existing_ref != null else null
	if existing_viewport != null and existing_viewport != viewport:
		_remove_viewport(id)
		existing_ref = null
	if existing_ref != null and existing_viewport == viewport:
		_prune_owners_for_viewport(id)
		existing_ref = _viewports.get(id)
	if existing_ref == null:
		_viewports[id] = weakref(viewport)
		_viewport_owners[id] = {}
		_viewport_world_ids[id] = 0
		_connect_viewport_world_changed(id, viewport)
		_queue_viewport_sweep(id)
	var owner_id := owner.get_instance_id() if is_instance_valid(owner) else 0
	_add_owner_lease(id, owner_id, owner)
	_set_viewport_world(id, _world_id(viewport))

static func unregister_viewport(viewport: Viewport, owner: Object = null) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	var id := viewport.get_instance_id()
	if not _viewports.has(id):
		return
	var owner_id := owner.get_instance_id() if is_instance_valid(owner) else 0
	_remove_owner_lease(id, owner_id)
	_prune_owners_for_viewport(id)
	if _viewports.has(id) and _viewport_owners[id].is_empty():
		_remove_viewport(id)

## Release every route leased by one producer without scanning unrelated viewports.
static func unregister_owner(owner: Object) -> void:
	if not is_instance_valid(owner):
		return
	_unregister_owner_id(owner.get_instance_id())

static func _add_owner_lease(viewport_id: int, owner_id: int, owner: Object) -> void:
	var owners: Dictionary = _viewport_owners.get(viewport_id, {})
	if owners.has(owner_id):
		if owner_id == 0:
			return
		var existing_ref: WeakRef = owners[owner_id]
		if existing_ref != null and existing_ref.get_ref() == owner:
			return
		_unindex_owner_viewport(owner_id, viewport_id)
	owners[owner_id] = weakref(owner) if owner_id != 0 and is_instance_valid(owner) else null
	_viewport_owners[viewport_id] = owners
	if owner_id != 0 and is_instance_valid(owner):
		_owner_refs[owner_id] = weakref(owner)
		_queue_owner_sweep(owner_id)
		var owned_viewports: Dictionary = _owner_viewports.get(owner_id, {})
		owned_viewports[viewport_id] = true
		_owner_viewports[owner_id] = owned_viewports

static func _remove_owner_lease(viewport_id: int, owner_id: int) -> void:
	var owners: Dictionary = _viewport_owners.get(viewport_id, {})
	if not owners.has(owner_id):
		return
	owners.erase(owner_id)
	if owner_id != 0:
		_unindex_owner_viewport(owner_id, viewport_id)

static func _unindex_owner_viewport(owner_id: int, viewport_id: int) -> void:
	var owned_viewports: Dictionary = _owner_viewports.get(owner_id, {})
	owned_viewports.erase(viewport_id)
	if owned_viewports.is_empty():
		_owner_viewports.erase(owner_id)
		_owner_refs.erase(owner_id)
	else:
		_owner_viewports[owner_id] = owned_viewports

static func _unregister_owner_id(owner_id: int) -> void:
	var owned_viewports: Dictionary = _owner_viewports.get(owner_id, {})
	var viewport_ids: Array = owned_viewports.keys()
	_owner_viewports.erase(owner_id)
	_owner_refs.erase(owner_id)
	for viewport_id in viewport_ids:
		var owners: Dictionary = _viewport_owners.get(viewport_id, {})
		owners.erase(owner_id)
		if owners.is_empty():
			_remove_viewport(viewport_id)

## Remove dead leases only in the requested viewport bucket. RefCounted owners
## have no tree-exit event, so an occasional unique-owner sweep cleans forgotten
## registrations that were not queried.
static func _prune_owners_for_viewport(viewport_id: int) -> void:
	var owners: Dictionary = _viewport_owners.get(viewport_id, {})
	for owner_id in owners.keys():
		if owner_id == 0:
			continue
		var owner_ref: WeakRef = owners.get(owner_id)
		if owner_ref == null or owner_ref.get_ref() == null:
			owners.erase(owner_id)
			_unindex_owner_viewport(owner_id, viewport_id)
	if owners.is_empty() and _viewports.has(viewport_id):
		_remove_viewport(viewport_id)

static func _queue_owner_sweep(owner_id: int) -> void:
	if _owner_sweep_queued.has(owner_id):
		return
	_owner_sweep_queued[owner_id] = true
	_owner_sweep_ids.append(owner_id)

static func _queue_viewport_sweep(viewport_id: int) -> void:
	if _viewport_sweep_queued.has(viewport_id):
		return
	_viewport_sweep_queued[viewport_id] = true
	_viewport_sweep_ids.append(viewport_id)

static func _compact_owner_sweep_ids() -> void:
	var live_ids: Array[int] = []
	_owner_sweep_queued.clear()
	for owner_id in _owner_sweep_ids:
		if _owner_refs.has(owner_id):
			live_ids.append(owner_id)
			_owner_sweep_queued[owner_id] = true
	_owner_sweep_ids = live_ids
	_owner_sweep_cursor = 0

static func _compact_viewport_sweep_ids() -> void:
	var live_ids: Array[int] = []
	_viewport_sweep_queued.clear()
	for viewport_id in _viewport_sweep_ids:
		if _viewports.has(viewport_id):
			live_ids.append(viewport_id)
			_viewport_sweep_queued[viewport_id] = true
	_viewport_sweep_ids = live_ids
	_viewport_sweep_cursor = 0

static func _sweep_dead_owners_budgeted() -> void:
	var frame := Engine.get_process_frames()
	if frame == _owner_sweep_frame:
		return
	_owner_sweep_frame = frame
	if _owner_sweep_cursor >= _owner_sweep_ids.size():
		_compact_owner_sweep_ids()
	if _owner_sweep_ids.is_empty():
		return
	var checked := mini(REGISTRY_SWEEP_BUDGET, _owner_sweep_ids.size() - _owner_sweep_cursor)
	for offset in checked:
		var owner_id := _owner_sweep_ids[_owner_sweep_cursor]
		_owner_sweep_cursor += 1
		var owner_ref: WeakRef = _owner_refs.get(owner_id)
		if owner_ref == null or owner_ref.get_ref() == null:
			_unregister_owner_id(owner_id)
	if _owner_sweep_cursor >= _owner_sweep_ids.size():
		_compact_owner_sweep_ids()

static func _sweep_dead_viewports_budgeted() -> void:
	var frame := Engine.get_process_frames()
	if frame == _viewport_sweep_frame:
		return
	_viewport_sweep_frame = frame
	if _viewport_sweep_cursor >= _viewport_sweep_ids.size():
		_compact_viewport_sweep_ids()
	if _viewport_sweep_ids.is_empty():
		return
	var checked := mini(REGISTRY_SWEEP_BUDGET, _viewport_sweep_ids.size() - _viewport_sweep_cursor)
	for offset in checked:
		var viewport_id := _viewport_sweep_ids[_viewport_sweep_cursor]
		_viewport_sweep_cursor += 1
		var viewport := _registered_viewport(viewport_id)
		if viewport != null:
			_prune_owners_for_viewport(viewport_id)
	if _viewport_sweep_cursor >= _viewport_sweep_ids.size():
		_compact_viewport_sweep_ids()

static func _connect_viewport_world_changed(viewport_id: int, viewport: Viewport) -> void:
	if not viewport.has_signal("world_3d_changed"):
		_legacy_viewports[viewport_id] = true
		return
	var callback := func(signal_world_id: int) -> void:
		_on_viewport_world_changed(viewport_id, signal_world_id)
	viewport.connect("world_3d_changed", callback)
	_viewport_world_callbacks[viewport_id] = callback

static func _disconnect_viewport_world_changed(viewport_id: int, viewport: Viewport) -> void:
	var callback: Callable = _viewport_world_callbacks.get(viewport_id, Callable())
	if callback.is_valid() and viewport != null and is_instance_valid(viewport) \
			and viewport.is_connected("world_3d_changed", callback):
		viewport.disconnect("world_3d_changed", callback)
	_viewport_world_callbacks.erase(viewport_id)
	_legacy_viewports.erase(viewport_id)

static func _on_viewport_world_changed(viewport_id: int, signal_world_id: int) -> void:
	var viewport := _registered_viewport(viewport_id)
	if viewport == null:
		return
	_prune_owners_for_viewport(viewport_id)
	if not _viewports.has(viewport_id):
		return
	# A zero event marks tree exit or a viewport with no active world. Otherwise
	# use the live inherited world identity, not a cached signal payload.
	var world_id := 0
	if signal_world_id != 0 and viewport.is_inside_tree():
		world_id = _world_id(viewport)
	_set_viewport_world(viewport_id, world_id)

static func _registered_viewport(viewport_id: int) -> Viewport:
	var reference: WeakRef = _viewports.get(viewport_id)
	var viewport: Viewport = reference.get_ref() if reference != null else null
	if viewport == null or not is_instance_valid(viewport):
		_remove_viewport(viewport_id)
		return null
	return viewport

static func _remove_viewport(viewport_id: int) -> void:
	var was_registered := _viewports.has(viewport_id)
	var world_id := int(_viewport_world_ids.get(viewport_id, 0))
	if world_id != 0:
		var world_bucket: Dictionary = _viewports_by_world.get(world_id, {})
		world_bucket.erase(viewport_id)
		if world_bucket.is_empty():
			_viewports_by_world.erase(world_id)
		else:
			_viewports_by_world[world_id] = world_bucket
	var viewport := _registered_viewport_without_removal(viewport_id)
	_disconnect_viewport_world_changed(viewport_id, viewport)
	var owners: Dictionary = _viewport_owners.get(viewport_id, {})
	for owner_id in owners.keys():
		if owner_id != 0:
			_unindex_owner_viewport(owner_id, viewport_id)
	_viewport_owners.erase(viewport_id)
	_viewports.erase(viewport_id)
	_viewport_world_ids.erase(viewport_id)
	if was_registered:
		if world_id != 0:
			_invalidate_world(world_id)
		else:
			_targets_version += 1

static func _registered_viewport_without_removal(viewport_id: int) -> Viewport:
	var reference: WeakRef = _viewports.get(viewport_id)
	return reference.get_ref() if reference != null else null

static func _set_viewport_world(viewport_id: int, new_world_id: int) -> void:
	var old_world_id := int(_viewport_world_ids.get(viewport_id, 0))
	if old_world_id == new_world_id:
		return
	if old_world_id != 0:
		var old_bucket: Dictionary = _viewports_by_world.get(old_world_id, {})
		old_bucket.erase(viewport_id)
		if old_bucket.is_empty():
			_viewports_by_world.erase(old_world_id)
		else:
			_viewports_by_world[old_world_id] = old_bucket
	if new_world_id != 0:
		var new_bucket: Dictionary = _viewports_by_world.get(new_world_id, {})
		new_bucket[viewport_id] = true
		_viewports_by_world[new_world_id] = new_bucket
	_viewport_world_ids[viewport_id] = new_world_id
	if old_world_id != 0:
		_invalidate_world(old_world_id)
	if new_world_id != 0:
		_invalidate_world(new_world_id)
	if old_world_id == 0 and new_world_id == 0:
		_targets_version += 1

static func _invalidate_world(world_id: int) -> void:
	var bucket: Dictionary = _viewports_by_world.get(world_id, {})
	if bucket.is_empty():
		_world_generations.erase(world_id)
		_targets_cache.erase(world_id)
	else:
		_next_world_generation += 1
		_world_generations[world_id] = _next_world_generation
		_targets_cache.erase(world_id)
	_targets_version += 1

## Live viewport registrations as id -> WeakRef. Returned as a copy so producers
## may keep per-viewport bookkeeping keyed by id without racing the registry.
## Full enumeration is reserved for callers that actually need every viewport.
static func viewports() -> Dictionary:
	for viewport_id in _viewports.keys():
		var viewport := _registered_viewport(viewport_id)
		if viewport != null:
			_prune_owners_for_viewport(viewport_id)
			if _viewports.has(viewport_id):
				_set_viewport_world(viewport_id, _world_id(viewport))
	return _viewports.duplicate()

## World-scoped weak references for consumers that only need one World3D.
## Each requested bucket validates its leases and live world before returning.
static func viewports_for_world(world: World3D) -> Dictionary:
	if world == null or not is_instance_valid(world):
		return {}
	# Reap a bounded number of forgotten weak leases/viewport nodes once per
	# engine frame, then validate the requested world bucket in full below.
	_sweep_dead_owners_budgeted()
	_sweep_dead_viewports_budgeted()
	_refresh_legacy_world_ids()
	var world_id := world.get_instance_id()
	var result: Dictionary = {}
	var world_bucket: Dictionary = _viewports_by_world.get(world_id, {})
	for viewport_id in world_bucket.keys():
		var viewport := _viewport_for_world(viewport_id, world_id)
		if viewport != null:
			result[viewport_id] = _viewports[viewport_id]
	return result

## Per-world route generation changes only when a viewport enters/leaves that
## world's bucket. Consumers may use it to avoid rebuilding world-local state.
static func generation_for_world(world: World3D) -> int:
	if world == null or not is_instance_valid(world):
		return 0
	viewports_for_world(world)
	return int(_world_generations.get(world.get_instance_id(), 0))

static func _viewport_for_world(viewport_id: int, world_id: int) -> Viewport:
	var viewport := _registered_viewport(viewport_id)
	if viewport == null:
		return null
	_prune_owners_for_viewport(viewport_id)
	if not _viewports.has(viewport_id):
		return null
	if not viewport.is_inside_tree():
		_set_viewport_world(viewport_id, 0)
		return null
	var live_world_id := _world_id(viewport)
	if live_world_id != world_id:
		_set_viewport_world(viewport_id, live_world_id)
		return null
	return viewport

static func _refresh_legacy_world_ids() -> void:
	if _legacy_viewports.is_empty():
		return
	for viewport_id in _legacy_viewports.keys():
		var viewport := _registered_viewport(viewport_id)
		if viewport == null:
			continue
		_prune_owners_for_viewport(viewport_id)
		if _viewports.has(viewport_id):
			_set_viewport_world(viewport_id, _world_id(viewport))

## Reap a bounded set of missed weak releases. World lookups also validate every
## lease in their requested bucket immediately.
static func prune() -> void:
	_sweep_dead_owners_budgeted()
	_sweep_dead_viewports_budgeted()
	_refresh_legacy_world_ids()

static func _world_id(viewport: Viewport) -> int:
	var world := viewport.find_world_3d() if viewport.is_inside_tree() else null
	return world.get_instance_id() if world != null else 0

## Registers every Viewport in the subtree rooted at node.
static func scan(node: Node, owner: Object = null) -> void:
	if node == null:
		return
	if node is Viewport:
		register_viewport(node, owner)
	for child in node.get_children():
		scan(child, owner)

## Render targets whose viewports draw the given world. The cache is per-world;
## viewport membership is validated before a generation-matched cache hit.
static func targets_for(world: World3D) -> Array[RID]:
	if world == null or not is_instance_valid(world):
		return []
	var world_id := world.get_instance_id()
	var viewports_for_requested_world := viewports_for_world(world)
	var generation := int(_world_generations.get(world_id, 0))
	var cached: Dictionary = _targets_cache.get(world_id, {})
	if int(cached.get("generation", -1)) == generation:
		var cached_value: Variant = cached.get("targets", null)
		if cached_value is Array:
			var cached_targets: Array[RID] = cached_value
			return cached_targets
	var targets: Array[RID] = []
	for viewport_id in viewports_for_requested_world.keys():
		var reference: WeakRef = viewports_for_requested_world[viewport_id]
		var viewport: Viewport = reference.get_ref() if reference != null else null
		if viewport == null or not is_instance_valid(viewport):
			continue
		# RendererViewport creates one render-target RID per viewport; resize and
		# screen/XR changes update that RID until the viewport itself is freed.
		var target := RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
		if target.is_valid() and not targets.has(target):
			targets.append(target)
	_targets_cache[world_id] = {"generation": generation, "targets": targets}
	if _targets_cache.size() > 32:
		_targets_cache.clear()
		_targets_cache[world_id] = {"generation": generation, "targets": targets}
	return targets
