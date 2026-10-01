@tool
extends RefCounted
## Shared viewport → World3D → render-target registry behind the world-scoped
## snapshot contract that runtime_snapshot_pass.gd defines.
##
## Producer runtimes (feng-fog, feng-magic-gi) register the viewports they render
## to and ask which render targets a world owns, so a published snapshot's
## `render_targets` can be matched against RenderSceneBuffersRD.get_render_target().
## The registry is a static singleton: every producer shares the same viewport set,
## and the world→targets cache invalidates once for all of them. Producers load
## this script by path like the passes load them — a missing addon degrades to no
## registered viewports, which is correct because nothing consumes snapshots
## without the passes.

static var _viewports: Dictionary = {} ## viewport id -> WeakRef
static var _viewport_owners: Dictionary = {} ## viewport id -> {owner id: WeakRef}; 0 is the legacy lease
static var _viewport_world_ids: Dictionary = {} ## last observed live World3D identity
static var _targets_version := 0
static var _targets_cache: Dictionary = {} ## world id -> {version, targets}

## Registrations are idempotent per owner. The optional owner keeps independent
## producers from removing each other's routes; it is held weakly. Calls without
## an owner retain their original register/unregister behavior as one legacy lease.
static func register_viewport(viewport: Viewport, owner: Object = null) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	var id := viewport.get_instance_id()
	var owners: Dictionary = _viewport_owners.get(id, {})
	var owner_id := owner.get_instance_id() if is_instance_valid(owner) else 0
	owners[owner_id] = weakref(owner) if owner_id != 0 else null
	_viewport_owners[id] = owners
	var existing: WeakRef = _viewports.get(id)
	if existing != null and existing.get_ref() == viewport:
		return
	_viewports[id] = weakref(viewport)
	_viewport_world_ids[id] = _world_id(viewport)
	_targets_version += 1

static func unregister_viewport(viewport: Viewport, owner: Object = null) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	var id := viewport.get_instance_id()
	var owners: Dictionary = _viewport_owners.get(id, {})
	owners.erase(owner.get_instance_id() if is_instance_valid(owner) else 0)
	_prune_owners(owners)
	if not owners.is_empty():
		return
	_remove_viewport(id)

## Release a producer's subtree scan as well as its directly registered viewport.
## Nodes call this on tree exit; forgotten releases are pruned through WeakRef.
static func unregister_owner(owner: Object) -> void:
	if not is_instance_valid(owner):
		return
	var owner_id := owner.get_instance_id()
	for id in _viewport_owners.keys():
		var owners: Dictionary = _viewport_owners[id]
		owners.erase(owner_id)
		_prune_owners(owners)
		if owners.is_empty():
			_remove_viewport(id)

static func _prune_owners(owners: Dictionary) -> void:
	for owner_id in owners.keys():
		if owner_id != 0 and owners[owner_id].get_ref() == null:
			owners.erase(owner_id)

static func _remove_viewport(id: int) -> void:
	_viewport_owners.erase(id)
	if _viewports.erase(id):
		_viewport_world_ids.erase(id)
		_targets_version += 1

## Live viewport registrations as id -> WeakRef. Returned as a copy so producers
## may keep per-viewport bookkeeping keyed by id without racing the registry.
static func viewports() -> Dictionary:
	prune()
	return _viewports.duplicate()

static func prune() -> void:
	for id in _viewports.keys():
		var reference: WeakRef = _viewports[id]
		var viewport: Viewport = reference.get_ref() if reference != null else null
		var owners: Dictionary = _viewport_owners.get(id, {})
		_prune_owners(owners)
		if viewport == null or owners.is_empty():
			_remove_viewport(id)
		else:
			var world_id := _world_id(viewport)
			if _viewport_world_ids.get(id, -1) != world_id:
				_viewport_world_ids[id] = world_id
				_targets_version += 1

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

## Render targets whose viewports draw the given world. Viewport edits bump the
## version so a published targets array is reused until the set actually changes.
static func targets_for(world: World3D) -> Array[RID]:
	var targets: Array[RID] = []
	if world == null:
		return targets
	# World reassignment and tree detach/reentry do not recreate the Viewport.
	# Validate those cheap identities before returning cached render targets.
	prune()
	var world_id := world.get_instance_id()
	var cached: Dictionary = _targets_cache.get(world_id, {})
	if not cached.is_empty() and int(cached.get("version", -1)) == _targets_version:
		return cached["targets"]
	for id in _viewports.keys():
		var reference: WeakRef = _viewports[id]
		var viewport: Viewport = reference.get_ref() if reference != null else null
		if viewport == null:
			continue # prune() already removed expired registrations.
		if not viewport.is_inside_tree() or viewport.find_world_3d() != world:
			continue
		var target := RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
		if target.is_valid() and not targets.has(target):
			targets.append(target)
	_targets_cache[world_id] = {"version": _targets_version, "targets": targets}
	if _targets_cache.size() > 32:
		_targets_cache.clear()
		_targets_cache[world_id] = {"version": _targets_version, "targets": targets}
	return targets
