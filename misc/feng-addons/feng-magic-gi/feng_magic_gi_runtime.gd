@tool
class_name FMagicGIRuntime
extends RefCounted
## Main-thread lighting publishes immutable, world-scoped PRT snapshots.

const Lighting = preload("feng_magic_gi_lighting.gd")
const VIEWPORT_SCAN_MSEC := 1000

static var _volumes: Dictionary = {}
static var _viewports: Dictionary = {}
static var _lighting: Dictionary = {}
static var _published_at: Dictionary = {}
static var _data_keys: Dictionary = {}
static var _publish_sequence := 0
static var _snapshots: Array[Dictionary] = []
static var _mutex := Mutex.new()
static var _last_frame := -1
static var _next_viewport_scan := 0

static func register(volume: FMagicGIVolume) -> void:
	var id := volume.get_instance_id()
	if not _volumes.has(id):
		_volumes[id] = weakref(volume)
		_publish_sequence += 1
		_published_at[id] = _publish_sequence
		_data_keys.erase(id)
	register_viewport(volume.get_viewport())

static func unregister(volume: FMagicGIVolume) -> void:
	var id := volume.get_instance_id()
	_volumes.erase(id)
	_lighting.erase(id)
	_published_at.erase(id)
	_data_keys.erase(id)
	_publish()

static func register_viewport(viewport: Viewport) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	_viewports[viewport.get_instance_id()] = weakref(viewport)

static func unregister_viewport(viewport: Viewport) -> void:
	if viewport != null and is_instance_valid(viewport):
		_viewports.erase(viewport.get_instance_id())
		_publish()

static func publish(volume: FMagicGIVolume) -> void:
	if volume.is_inside_tree():
		register(volume)
		var id := volume.get_instance_id()
		var data := volume.bake_data
		var data_key := "%d:%d" % [data.get_instance_id(), data.bake_version] if data != null else ""
		if str(_data_keys.get(id, "")) != data_key:
			_data_keys[id] = data_key
			_publish_sequence += 1
			_published_at[id] = _publish_sequence
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
	_mutex.lock()
	var result := _snapshots
	_mutex.unlock()
	return result

static func _refresh_viewports() -> void:
	for id in _volumes.keys():
		var reference: WeakRef = _volumes.get(id)
		var volume: FMagicGIVolume = reference.get_ref() if reference != null else null
		if volume == null or not volume.is_inside_tree():
			continue
		register_viewport(volume.get_viewport())
		var root: Node = volume
		while root.get_parent() != null and not root.get_parent() is Viewport:
			root = root.get_parent()
		_scan_viewports(root)
	for id in _viewports.keys():
		var reference: WeakRef = _viewports[id]
		var viewport: Viewport = reference.get_ref() if reference != null else null
		if viewport == null:
			_viewports.erase(id)

static func _scan_viewports(node: Node) -> void:
	if node is Viewport:
		register_viewport(node)
	for child in node.get_children():
		_scan_viewports(child)

static func _render_targets(world: World3D) -> Array[RID]:
	var targets: Array[RID] = []
	if world == null:
		return targets
	for id in _viewports.keys():
		var reference: WeakRef = _viewports[id]
		var viewport: Viewport = reference.get_ref() if reference != null else null
		if viewport == null or not viewport.is_inside_tree() or viewport.find_world_3d() != world:
			continue
		var target := RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
		if target.is_valid() and not targets.has(target):
			targets.append(target)
	return targets

static func _publish() -> void:
	var selected: Dictionary = {} # world instance id -> latest valid volume
	for id in _volumes.keys():
		var reference: WeakRef = _volumes[id]
		var volume: FMagicGIVolume = reference.get_ref() if reference != null else null
		if volume == null:
			_volumes.erase(id)
			_lighting.erase(id)
			_published_at.erase(id)
			continue
		if not volume.is_inside_tree() or not volume.enabled or not volume.has_bake():
			continue
		var world := volume.get_world_3d()
		if world == null:
			continue
		var world_id := world.get_instance_id()
		var sequence: int = int(_published_at.get(id, 0))
		if not selected.has(world_id) or sequence > int(selected[world_id].sequence):
			selected[world_id] = {"volume": volume, "sequence": sequence, "id": id, "world": world}
	var result: Array[Dictionary] = []
	for world_id in selected.keys():
		var entry: Dictionary = selected[world_id]
		var volume: FMagicGIVolume = entry.volume
		var id: int = entry.id
		if not _lighting.has(id):
			_lighting[id] = Lighting.new()
		var data := volume.bake_data
		var bake_version: int = data.bake_version
		var cache_key := "%d:%d" % [id, bake_version]
		result.append({
			"data": data,
			"version": bake_version,
			"cache_key": cache_key,
			"strength": volume.gi_strength,
			"lighting": _lighting[id].coefficients(volume),
			"world_id": world_id,
			"volume_id": id,
			"render_targets": _render_targets(entry.world),
		})
	_mutex.lock()
	_snapshots = result
	_mutex.unlock()
