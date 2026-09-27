@tool
class_name FMagicGIRuntime
extends RefCounted
## Main-thread lighting publishes immutable, world-scoped PRT snapshots.

const RuntimeState = preload("feng_magic_gi_runtime_state.gd")
const VIEWPORT_SCAN_MSEC := 1000

# One per-volume entry owns its weak reference, lighting calculator, emission
# helper/cache, data identity, and diagnostic state. Viewports and publication
# are service-wide concerns and remain separate.
static var _registry: Dictionary = {}
static var _viewports: Dictionary = {}
static var _emission_revision_sequence := 0
static var _publish_sequence := 0
static var _snapshots: Array[Dictionary] = []
static var _mutex := Mutex.new()
static var _last_frame := -1
static var _next_viewport_scan := 0

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
	register_viewport(volume.get_viewport())

static func unregister(volume: FMagicGIVolume) -> void:
	var id := volume.get_instance_id()
	_registry.erase(id)
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
		if int(snapshot.get("volume_id", 0)) == volume.get_instance_id():
			_mutex.unlock()
			return # The selected volume's warning was refreshed by _publish().
	_mutex.unlock()
	if not volume.has_usable_bake():
		state.emission_warning = ""
		return
	state.refresh_emission_diagnostics(volume, volume.bake_data)

static func _refresh_viewports() -> void:
	for id in _registry.keys():
		var state: RuntimeState = _registry.get(id)
		var volume: FMagicGIVolume = state.get_volume() if state != null else null
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
	for id in _registry.keys():
		var state: RuntimeState = _registry.get(id)
		var volume: FMagicGIVolume = state.get_volume() if state != null else null
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
		if state.update_emission_snapshot(volume, data, bake_version):
			_emission_revision_sequence += 1
			state.emission_revision = _emission_revision_sequence
		result.append({
			"data": data,
			"version": bake_version,
			"cache_key": cache_key,
			"strength": volume.gi_strength,
			"lighting": state.lighting.coefficients(volume),
			"emission_payload": state.emission_payload,
			"emission_revision": state.emission_revision,
			"emission_identity": state.emission_identity if not state.emission_identity.is_empty() else cache_key,
			"world_id": world_id,
			"volume_id": id,
			"render_targets": _render_targets(entry.world),
		})
	_mutex.lock()
	_snapshots = result
	_mutex.unlock()
