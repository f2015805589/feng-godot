@tool
class_name FengFogRuntime
extends RefCounted
## Main-thread service: FengHeightFog nodes publish immutable, world-scoped
## parameter snapshots; viewports register so a snapshot can be matched to a
## render target by the FRP height fog pass.
##
## The node's snapshot_fields() owns the schema; the runtime attaches the
## world/render-target identity and the resolved sun. Published arrays and
## dictionaries are immutable by convention: the producer replaces the whole
## array under the mutex instead of mutating a published one.

const SUN_SCAN_MSEC := 500

static var _fogs: Dictionary = {} ## instance id -> {node: WeakRef, sequence: int}
static var _viewports: Dictionary = {} ## viewport id -> WeakRef
static var _debanding_original: Dictionary = {} ## viewport id -> use_debanding before fog activated
static var _sun_scans: Dictionary = {} ## world id -> {time: int, light: WeakRef}
static var _snapshots: Array[Dictionary] = []
static var _mutex := Mutex.new()
static var _sequence := 0
static var _last_frame := -1
static var _targets_version := 0
static var _targets_cache: Dictionary = {}

static func register(fog: FengHeightFog) -> void:
	var id := fog.get_instance_id()
	var entry: Variant = _fogs.get(id)
	if entry == null or entry["node"].get_ref() != fog:
		_sequence += 1
		_fogs[id] = {"node": weakref(fog), "sequence": _sequence}
	register_viewport(fog.get_viewport())

static func unregister(fog: FengHeightFog) -> void:
	_fogs.erase(fog.get_instance_id())
	_publish()

static func register_viewport(viewport: Viewport) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	var id := viewport.get_instance_id()
	var existing: WeakRef = _viewports.get(id)
	if existing != null and existing.get_ref() == viewport:
		return
	_viewports[id] = weakref(viewport)
	_targets_version += 1

static func unregister_viewport(viewport: Viewport) -> void:
	if viewport != null and is_instance_valid(viewport):
		var id := viewport.get_instance_id()
		_restore_debanding(id, viewport)
		if _viewports.erase(id):
			_targets_version += 1
		_publish()

static func _restore_debanding(id: int, viewport: Viewport) -> void:
	if _debanding_original.has(id):
		viewport.use_debanding = _debanding_original[id]
		_debanding_original.erase(id)

## The viewport's final tonemap knows its output bit depth and applies dither
## immediately before quantization. Doing this in the HDR fog pass would use
## the wrong scale and can leave visible rings after tone mapping.
static func _sync_debanding(selected: Dictionary) -> void:
	for id in _viewports.keys():
		var reference: WeakRef = _viewports[id]
		var viewport: Viewport = reference.get_ref() if reference != null else null
		if viewport == null:
			_viewports.erase(id)
			_debanding_original.erase(id)
			_targets_version += 1
			continue
		var world := viewport.find_world_3d() if viewport.is_inside_tree() else null
		var fog_active := world != null and selected.has(world.get_instance_id())
		if fog_active:
			if not _debanding_original.has(id):
				_debanding_original[id] = viewport.use_debanding
				viewport.use_debanding = true
		else:
			_restore_debanding(id, viewport)

static func publish(fog: FengHeightFog) -> void:
	if fog.is_inside_tree():
		register(fog)
	_publish()

## Called from each fog node's _process: republishes so a moving sun or an
## animated parameter keeps its world snapshot current. The frame guard keeps
## several fog nodes from republishing the same snapshot set within one frame.
static func tick() -> void:
	var frame := Engine.get_process_frames()
	if _last_frame == frame:
		return
	_last_frame = frame
	_publish()

static func snapshots() -> Array[Dictionary]:
	_mutex.lock()
	var result := _snapshots
	_mutex.unlock()
	return result

static func _render_targets(world: World3D) -> Array[RID]:
	var targets: Array[RID] = []
	if world == null:
		return targets
	var world_id := world.get_instance_id()
	var cached: Dictionary = _targets_cache.get(world_id, {})
	if not cached.is_empty() and int(cached.get("version", -1)) == _targets_version:
		return cached["targets"]
	for id in _viewports.keys():
		var reference: WeakRef = _viewports[id]
		var viewport: Viewport = reference.get_ref() if reference != null else null
		if viewport == null:
			_viewports.erase(id)
			_targets_version += 1
			continue
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

## The sun for a world: the component's explicit light when set, otherwise the
## first enabled DirectionalLight3D on the same World3D — Unreal's equivalent is
## the directional light flagged "Atmosphere Sun Light", which Godot does not
## have, so a dedicated override on the component covers the multi-sun case.
static func _sun_for(fog: FengHeightFog, world: World3D) -> DirectionalLight3D:
	var explicit_light := fog.sun_light
	if explicit_light != null and explicit_light.visible:
		return explicit_light
	var world_id := world.get_instance_id() if world != null else 0
	var now := Time.get_ticks_msec()
	var scan: Variant = _sun_scans.get(world_id)
	if scan != null and now - int(scan["time"]) < SUN_SCAN_MSEC:
		var cached: DirectionalLight3D = scan["light"].get_ref()
		return cached if cached != null and cached.visible else null
	var found: DirectionalLight3D = null
	var tree := fog.get_tree()
	if tree != null:
		var stack: Array = [tree.root]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			if node is DirectionalLight3D and node.visible and node.get_world_3d() == world:
				found = node
				break
			stack.append_array(node.get_children())
	_sun_scans[world_id] = {"time": now, "light": weakref(found)}
	return found

static func _publish() -> void:
	var selected: Dictionary = {} ## world id -> latest registered enabled fog
	for id in _fogs.keys():
		var entry: Dictionary = _fogs[id]
		var fog: FengHeightFog = entry["node"].get_ref()
		if fog == null:
			_fogs.erase(id)
			continue
		if not fog.is_inside_tree() or not fog.enabled:
			continue
		var world := fog.get_world_3d()
		if world == null:
			continue
		var world_id := world.get_instance_id()
		if not selected.has(world_id) or int(entry["sequence"]) > int(selected[world_id]["sequence"]):
			selected[world_id] = {"fog": fog, "sequence": entry["sequence"], "id": id, "world": world}
	_sync_debanding(selected)
	var result: Array[Dictionary] = []
	for world_id in selected.keys():
		var entry: Dictionary = selected[world_id]
		var fog: FengHeightFog = entry["fog"]
		var snapshot := fog.snapshot_fields()
		var sun := _sun_for(fog, entry["world"])
		if sun == null:
			snapshot["sun_direction"] = Vector3.ZERO
			snapshot["inscattering_color"] = Vector3.ZERO
			snapshot["inscattering_start"] = -1.0
		else:
			# DirectionalLight3D shines along its -Z axis; the shader wants the
			# direction toward the light. Unreal multiplies the component's
			# DirectionalInscatteringColor by the sun color's luminance.
			snapshot["sun_direction"] = sun.global_transform.basis.z.normalized()
			var sun_rgb := Vector3(sun.light_color.r, sun.light_color.g, sun.light_color.b) * sun.light_energy
			# UE 5.7 defaults to the working color space's luminance factors;
			# Godot's linear sRGB lights use the Rec.709 factors.
			var sun_luminance := sun_rgb.x * 0.2126 + sun_rgb.y * 0.7152 + sun_rgb.z * 0.0722
			snapshot["inscattering_color"] = snapshot["inscattering_color"] * sun_luminance
		snapshot["world_id"] = world_id
		snapshot["fog_id"] = entry["id"]
		snapshot["render_targets"] = _render_targets(entry["world"])
		result.append(snapshot)
	_mutex.lock()
	_snapshots = result
	_mutex.unlock()
