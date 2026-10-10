@tool
extends RefCounted
## Main-thread scene snapshots and render-thread immutable publication for RTGI.

const SNAPSHOT_WORLDS_PATH := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"
const WORLD_SNAPSHOT_PATH := "res://addons/feng-raytracing/scene/feng_rt_gi_world_snapshot.gd"
const ABI_VERSION := 1

static var _worlds_script: GDScript
static var _worlds_queried := false
static var _snapshot_type: GDScript
static var _snapshot_type_queried := false
static var _world_states: Dictionary = {} # world id -> weak world/root, generation, registry
static var _published_by_target: Dictionary = {} # target id -> immutable plain dictionary
static var _published_mutex := Mutex.new()
static var _publish_generation := 0
static var _registry_epoch := 0

## Called by the main-thread snapshot tick. World3D is resolved from
## the existing viewport-to-target registry, never from Environment identity.
static func prepare_target(target: RID) -> Dictionary:
	if not target.is_valid():
		return _publish_failure(target, "invalid_render_target")
	var worlds := _load_snapshot_worlds()
	if worlds == null or not worlds.has_method("world_for_target"):
		return _publish_failure(target, "snapshot_world_registry_unavailable")
	var route: Variant = worlds.call("world_for_target", target)
	if not route is Dictionary or not bool(route.get("valid", false)):
		return _publish_failure(target, str(route.get("reason", "render_target_world_unavailable")))
	var world: World3D = route.get("world")
	var viewport: Viewport = route.get("viewport")
	var world_id := int(route.get("world_id", 0))
	var world_generation := int(route.get("generation", 0))
	if world == null or viewport == null or world_id == 0:
		return _publish_failure(target, "render_target_world_route_incomplete")
	var state: Dictionary = _world_states.get(world_id, {})
	var old_world_ref: WeakRef = state.get("world")
	var old_root_ref: WeakRef = state.get("root")
	var old_registry: RefCounted = state.get("registry")
	var old_world = old_world_ref.get_ref() if old_world_ref != null else null
	var old_root = old_root_ref.get_ref() if old_root_ref != null else null
	if old_world != world or old_root != viewport.get_tree().root or int(state.get("world_generation", -1)) != world_generation:
		if old_registry != null and old_registry.has_method("detach"):
			old_registry.call("detach")
		_world_states.erase(world_id)
		old_registry = null
	if old_registry == null:
		var snapshot_type := _load_world_snapshot_type()
		if snapshot_type == null:
			return _publish_failure(target, "world_snapshot_type_unavailable")
		_registry_epoch += 1
		old_registry = snapshot_type.new()
		if not old_registry.call("attach", world, viewport.get_tree().root, world_generation):
			return _publish_failure(target, "world_snapshot_attach_failed")
		_world_states[world_id] = {"world": weakref(world), "root": weakref(viewport.get_tree().root),
			"world_generation": world_generation, "registry": old_registry, "epoch": _registry_epoch}
	var targets: Variant = worlds.call("targets_for", world)
	if not targets is Array or not targets.has(target):
		return _publish_failure(target, "target_left_world_route")
	var snapshot: Variant = old_registry.call("snapshot", target, targets)
	if not snapshot is Dictionary:
		return _publish_failure(target, "world_snapshot_returned_non_dictionary")
	_publish_generation += 1
	var published: Dictionary = snapshot.duplicate(false)
	published["publication"] = _publish_generation
	published["registry_epoch"] = _world_states[world_id].epoch
	_publish_target(target, published)
	return published

## Render-thread read. The value snapshot contains no Node or Resource references.
static func snapshot_for_target(target: RID) -> Dictionary:
	if not target.is_valid():
		return {}
	_published_mutex.lock()
	var value: Dictionary = _published_by_target.get(target.get_id(), {})
	var result := value.duplicate(false)
	_published_mutex.unlock()
	return result

static func clear_target(target: RID, reason := "inactive") -> void:
	if not target.is_valid():
		return
	_publish_target(target, {"valid": false, "abi_version": ABI_VERSION,
		"render_target": target, "unsupported_reasons": [reason], "instances": []})

static func clear_world(world_id: int) -> void:
	var state: Dictionary = _world_states.get(world_id, {})
	var registry: RefCounted = state.get("registry")
	if registry != null and registry.has_method("detach"):
		registry.call("detach")
	_world_states.erase(world_id)
	_published_mutex.lock()
	var stale_targets: Array[int] = []
	for target_id in _published_by_target:
		var snapshot: Dictionary = _published_by_target[target_id]
		if int(snapshot.get("world_id", 0)) == world_id:
			stale_targets.append(int(target_id))
	for target_id in stale_targets:
		_published_by_target.erase(target_id)
	_published_mutex.unlock()

static func _publish_failure(target: RID, reason: String) -> Dictionary:
	if target.is_valid():
		clear_target(target, reason)
	return {"valid": false, "abi_version": ABI_VERSION, "reason": reason,
		"render_target": target, "instances": [], "unsupported_reasons": [reason]}

static func _publish_target(target: RID, snapshot: Dictionary) -> void:
	_published_mutex.lock()
	_published_by_target[target.get_id()] = snapshot
	_published_mutex.unlock()

static func _load_snapshot_worlds() -> GDScript:
	if not _worlds_queried:
		_worlds_queried = true
		if ResourceLoader.exists(SNAPSHOT_WORLDS_PATH):
			var loaded: Variant = load(SNAPSHOT_WORLDS_PATH)
			if loaded is GDScript:
				_worlds_script = loaded
	return _worlds_script

static func _load_world_snapshot_type() -> GDScript:
	if not _snapshot_type_queried:
		_snapshot_type_queried = true
		if ResourceLoader.exists(WORLD_SNAPSHOT_PATH):
			var loaded: Variant = load(WORLD_SNAPSHOT_PATH)
			if loaded is GDScript:
				_snapshot_type = loaded
	return _snapshot_type

static var _requests: Dictionary = {}
static var _started := false

static func start() -> void:
	if _started:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_started = true
	tree.process_frame.connect(tick)

static func request_target(target: RID) -> void:
	_published_mutex.lock()
	_requests[target] = Engine.get_process_frames()
	_published_mutex.unlock()

static func tick() -> void:
	_published_mutex.lock()
	var requests := _requests.duplicate()
	_published_mutex.unlock()
	var active_worlds: Dictionary = {}
	for target: RID in requests:
		if Engine.get_process_frames() - int(requests[target]) > 3:
			_published_mutex.lock()
			_requests.erase(target)
			_published_by_target.erase(target.get_id())
			_published_mutex.unlock()
			continue
		var snapshot := prepare_target(target)
		active_worlds[int(snapshot.get("world_id", 0))] = true
	for world_id in _world_states.keys():
		if not active_worlds.has(world_id):
			clear_world(world_id)
