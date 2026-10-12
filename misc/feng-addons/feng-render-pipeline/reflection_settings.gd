@tool
class_name FengReflectionSettings
extends Node
## Main-thread settings node for FRP's internal reflection resolve.
##
## Nodes, weak references, and SnapshotWorlds are only touched on the main thread.
## Render callbacks read an immutable target -> priority snapshot under a mutex.

const SnapshotWorlds = preload("passes/snapshot_worlds.gd")

const SOURCE_COUNT := 4
const DEFAULT_PRIORITY: Array[int] = [0, 1, 2, 3]

static var _settings_by_id: Dictionary = {} ## node id -> WeakRef; main thread only
static var _priority_mutex := Mutex.new()
static var _runtime_priority_by_target: Dictionary = {} ## target id -> PackedInt32Array
static var _legacy_priority_by_resolver: Dictionary = {} ## resolver object id -> PackedInt32Array
static var _duplicate_targets_warned: Dictionary = {} ## main thread only

@export_node_path("Viewport") var target_viewport_path: NodePath = NodePath():
	set(value):
		if target_viewport_path == value:
			return
		target_viewport_path = value
		update_configuration_warnings()
		if is_inside_tree():
			_refresh_runtime_snapshots()

@export_enum("GI", "SSR", "FengReflectProbe", "FengSkyLight") var source_priority: Array[int] = DEFAULT_PRIORITY.duplicate():
	set(value):
		source_priority = value.duplicate()
		update_configuration_warnings()
		if is_inside_tree():
			_refresh_runtime_snapshots()

var _observed_world_id := 0
var _observed_world_generation := -1
var _observed_target_id := 0
var _duplicate_route_warning := false

func _enter_tree() -> void:
	set_process(true)
	_settings_by_id[get_instance_id()] = weakref(self)
	_refresh_runtime_snapshots()

func _exit_tree() -> void:
	_settings_by_id.erase(get_instance_id())
	_duplicate_route_warning = false
	update_configuration_warnings()
	_refresh_runtime_snapshots()

## Route changes are event-backed in SnapshotWorlds. Polling its cached world
## generation handles newly registered/removed viewports without scanning the
## scene tree; explicit viewport paths are checked directly for late resolution.
func _process(_delta: float) -> void:
	if _route_changed():
		_refresh_runtime_snapshots()

func _route_changed() -> bool:
	var world_id := 0
	var world_generation := -1
	var target_id := 0
	if target_viewport_path.is_empty():
		var viewport := get_viewport()
		var world := viewport.find_world_3d() if viewport != null else null
		if world != null:
			world_id = world.get_instance_id()
			world_generation = SnapshotWorlds.generation_for_world(world)
	else:
		var viewport := _target_viewport()
		if viewport != null:
			var target := RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
			if target.is_valid():
				target_id = target.get_id()
	var changed := world_id != _observed_world_id \
			or world_generation != _observed_world_generation \
			or target_id != _observed_target_id
	_observed_world_id = world_id
	_observed_world_generation = world_generation
	_observed_target_id = target_id
	return changed

func _target_viewport() -> Viewport:
	if target_viewport_path.is_empty():
		return get_viewport()
	return get_node_or_null(target_viewport_path) as Viewport

func get_source_priority_snapshot() -> Array[int]:
	return _validated_priority(source_priority)

## Called on the main thread by FengRenderer while building the runtime plan.
## This is the compatibility fallback for a migrated legacy Resolve priority.
static func publish_legacy_fallback_priority(resolver_id: int, values: Array) -> void:
	var valid := _validated_priority(values)
	_priority_mutex.lock()
	_legacy_priority_by_resolver[resolver_id] = PackedInt32Array(valid)
	_priority_mutex.unlock()

## A view-local Resolve duplicate shares only its source Resource's immutable
## legacy priority snapshot; mutable execution state remains isolated per view.
static func copy_legacy_fallback_priority(source_resolver_id: int, view_resolver_id: int) -> void:
	if source_resolver_id == view_resolver_id:
		return
	_priority_mutex.lock()
	var source: Variant = _legacy_priority_by_resolver.get(source_resolver_id)
	if source is PackedInt32Array:
		_legacy_priority_by_resolver[view_resolver_id] = source.duplicate()
	_priority_mutex.unlock()

## Render-thread API: reads only a target RID and mutex-protected value snapshots.
static func priority_for_render_target(target: RID, resolver_id: int) -> Array[int]:
	var result: Array[int] = []
	_priority_mutex.lock()
	var values: PackedInt32Array = _legacy_priority_by_resolver.get(
			resolver_id, PackedInt32Array(DEFAULT_PRIORITY))
	if target.is_valid():
		var stored: Variant = _runtime_priority_by_target.get(target.get_id())
		if stored is PackedInt32Array:
			values = stored
	for value in values:
		result.append(value)
	_priority_mutex.unlock()
	return result if result.size() == SOURCE_COUNT else DEFAULT_PRIORITY.duplicate()

## Refreshes the target map from live Nodes and SnapshotWorlds on the main thread.
## Duplicate settings fail closed to the default and emit one warning per target.
static func _refresh_runtime_snapshots() -> void:
	var priorities_by_target: Dictionary = {} ## target id -> Array[{settings_id, priority}]
	var stale_ids: Array[int] = []
	for instance_id_variant in _settings_by_id.keys():
		var instance_id := int(instance_id_variant)
		var reference: WeakRef = _settings_by_id.get(instance_id)
		var settings := reference.get_ref() as FengReflectionSettings if reference != null else null
		if settings == null or not is_instance_valid(settings) or not settings.is_inside_tree():
			stale_ids.append(instance_id)
			continue
		var priority := settings.get_source_priority_snapshot()
		var targets: Array[RID] = []
		if settings.target_viewport_path.is_empty():
			var host_viewport := settings.get_viewport()
			var world := host_viewport.find_world_3d() if host_viewport != null else null
			if world != null:
				# SnapshotWorlds returns all registered viewport targets for this world,
				# including editor and SubViewport targets.
				targets = SnapshotWorlds.targets_for(world)
		else:
			var explicit_viewport := settings._target_viewport()
			if explicit_viewport != null:
				var target := RenderingServer.viewport_get_render_target(explicit_viewport.get_viewport_rid())
				if target.is_valid():
					targets.append(target)
		for target in targets:
			if not target.is_valid():
				continue
			var target_id := target.get_id()
			var entries: Array = priorities_by_target.get(target_id, [])
			entries.append({"settings_id": instance_id, "priority": priority})
			priorities_by_target[target_id] = entries
	for stale_id in stale_ids:
		_settings_by_id.erase(stale_id)

	var published: Dictionary = {}
	var duplicate_settings: Dictionary = {}
	for target_id_variant in priorities_by_target.keys():
		var target_id := int(target_id_variant)
		var entries: Array = priorities_by_target[target_id]
		if entries.size() == 1:
			published[target_id] = PackedInt32Array(entries[0].priority)
		elif entries.size() > 1:
			published[target_id] = PackedInt32Array(DEFAULT_PRIORITY)
			for entry in entries:
				duplicate_settings[int(entry.settings_id)] = true
			if not _duplicate_targets_warned.has(target_id):
				_duplicate_targets_warned[target_id] = true
				push_warning("FengReflectionSettings: more than one settings node targets this render target; FRP uses the default source priority until only one remains.")
	for instance_id_variant in _settings_by_id.keys():
		var instance_id := int(instance_id_variant)
		var reference: WeakRef = _settings_by_id.get(instance_id)
		var settings := reference.get_ref() as FengReflectionSettings if reference != null else null
		if settings == null or not is_instance_valid(settings):
			continue
		var has_duplicate := duplicate_settings.has(instance_id)
		if settings._duplicate_route_warning != has_duplicate:
			settings._duplicate_route_warning = has_duplicate
			settings.update_configuration_warnings()
	_priority_mutex.lock()
	_runtime_priority_by_target = published
	_priority_mutex.unlock()

static func is_valid_priority(values: Array) -> bool:
	if values.size() != SOURCE_COUNT:
		return false
	var seen := {}
	for value in values:
		var source := int(value)
		if source < 0 or source >= SOURCE_COUNT or seen.has(source):
			return false
		seen[source] = true
	return true

static func _validated_priority(values: Array) -> Array[int]:
	var result: Array[int] = []
	result.assign(values if is_valid_priority(values) else DEFAULT_PRIORITY)
	return result

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not target_viewport_path.is_empty() and _target_viewport() == null:
		warnings.append("Target Viewport does not resolve to a Viewport node.")
	if not is_valid_priority(source_priority):
		warnings.append("Reflection Priority must contain GI, SSR, FengReflectProbe and FengSkyLight exactly once; FRP uses the default priority until corrected.")
	if _duplicate_route_warning:
		warnings.append("More than one FengReflectionSettings node targets this viewport or world render target; FRP uses the default priority until only one remains.")
	return warnings
