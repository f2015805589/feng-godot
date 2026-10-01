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

const SKY_RUNTIME_PATH := "res://addons/feng-sky/feng_sky_runtime.gd"
const SKY_RUNTIME_PROBE_INTERVAL_MSEC := 500
## The viewport/world/targets registry lives with the snapshot passes that
## consume it; the same soft path-loading the passes use for producer runtimes
## applies here, so a missing feng-render-pipeline addon degrades to nothing
## consuming the snapshots anyway.
const SNAPSHOT_WORLDS_PATH := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"

static var _fogs: Dictionary = {} ## instance id -> {node: WeakRef, sequence: int}
static var _debanding_original: Dictionary = {} ## viewport id -> {viewport: WeakRef, enabled: bool}
static var _light_tree: SceneTree
static var _scene_lights: Dictionary = {} ## instance id -> WeakRef; membership follows tree signals
static var _snapshots: Array[Dictionary] = []
static var _mutex := Mutex.new()
static var _sequence := 0
static var _last_frame := -1
static var _worlds_queried := false
static var _worlds: GDScript = null
static var _viewport_owner := RefCounted.new() ## Lease for public calls without an explicit owner
static var _next_sky_runtime_probe_msec := 0
static var _sky_runtime: GDScript = null

static func _snapshot_worlds() -> GDScript:
	if not _worlds_queried:
		_worlds_queried = true
		if ResourceLoader.exists(SNAPSHOT_WORLDS_PATH):
			_worlds = load(SNAPSHOT_WORLDS_PATH)
	return _worlds

## FengSkyAtmosphere is an optional addon. Query its main-thread, world-scoped
## radiance snapshot by soft path so fog remains usable when feng-sky is absent.
static func _sky_snapshot_for_world(world_id: int) -> Dictionary:
	if _sky_runtime == null:
		var now := Time.get_ticks_msec()
		if now < _next_sky_runtime_probe_msec:
			return {}
		_next_sky_runtime_probe_msec = now + SKY_RUNTIME_PROBE_INTERVAL_MSEC
		if ResourceLoader.exists(SKY_RUNTIME_PATH):
			var loaded: Variant = load(SKY_RUNTIME_PATH)
			if loaded is GDScript and loaded.has_method("snapshot_for_world"):
				_sky_runtime = loaded
	if _sky_runtime == null:
		return {}
	var result: Variant = _sky_runtime.call("snapshot_for_world", world_id)
	if not result is Dictionary or result.is_empty():
		return {}
	var result_world_id: Variant = result.get("world_id")
	if not result_world_id is int or result_world_id != world_id:
		return {}
	return result

## Adds the sky model's mean incident radiance, tinted by the material albedo
## in Lit mode. Direct illumination is resolved independently from the same
## DirectionalLight3D used by scene surfaces.
## Pre-exposure remains solely the height-fog pass's responsibility.
static func _add_sky_ambient(snapshot: Dictionary, world_id: int) -> void:
	var sky: Dictionary = _sky_snapshot_for_world(world_id)
	if sky.is_empty() or (sky.has("affect_height_fog") and not bool(sky["affect_height_fog"])):
		return
	var ambient: Variant = sky.get("ambient_radiance")
	var fog_color: Variant = snapshot.get("fog_color", Vector3.ZERO)
	if not ambient is Vector3 or not fog_color is Vector3:
		return
	var scale_value: Variant = sky.get("height_fog_contribution", 1.0)
	var contribution_scale := 1.0
	if scale_value is int or scale_value is float:
		var authored_scale := float(scale_value)
		if is_finite(authored_scale):
			contribution_scale = maxf(authored_scale, 0.0)
	var albedo: Vector3 = snapshot.get("fog_albedo", Vector3.ONE)
	snapshot["fog_color"] = fog_color + albedo * ambient * contribution_scale

static func register(fog: FengHeightFog) -> void:
	if fog.is_inside_tree():
		_attach_light_tree(fog.get_tree())
	var id := fog.get_instance_id()
	var entry: Variant = _fogs.get(id)
	if entry == null or entry["node"].get_ref() != fog:
		_sequence += 1
		_fogs[id] = {"node": weakref(fog), "sequence": _sequence}
	register_viewport(fog.get_viewport(), fog)

static func unregister(fog: FengHeightFog) -> void:
	var worlds := _snapshot_worlds()
	if worlds != null:
		worlds.unregister_owner(fog)
	_fogs.erase(fog.get_instance_id())
	if _fogs.is_empty():
		_detach_light_tree()
	_publish()

static func register_viewport(viewport: Viewport, owner: Object = null) -> void:
	var worlds := _snapshot_worlds()
	if worlds != null:
		worlds.register_viewport(viewport, owner if owner != null else _viewport_owner)

static func unregister_viewport(viewport: Viewport, owner: Object = null) -> void:
	if viewport != null and is_instance_valid(viewport):
		var id := viewport.get_instance_id()
		_restore_debanding(id, viewport)
		var worlds := _snapshot_worlds()
		if worlds != null:
			worlds.unregister_viewport(viewport, owner if owner != null else _viewport_owner)
		_publish()

static func _restore_debanding(id: int, viewport: Viewport) -> void:
	if _debanding_original.has(id):
		viewport.use_debanding = _debanding_original[id]["enabled"]
		_debanding_original.erase(id)

## The viewport's final tonemap knows its output bit depth and applies dither
## immediately before quantization. Doing this in the HDR fog pass would use
## the wrong scale and can leave visible rings after tone mapping.
static func _sync_debanding(selected: Dictionary) -> void:
	var worlds := _snapshot_worlds()
	if worlds == null:
		return
	var viewports: Dictionary = worlds.viewports()
	for id in _debanding_original.keys():
		if not viewports.has(id):
			var original_viewport: Viewport = _debanding_original[id]["viewport"].get_ref()
			if original_viewport != null:
				_restore_debanding(id, original_viewport)
			_debanding_original.erase(id)
	for id in viewports.keys():
		var reference: WeakRef = viewports[id]
		var viewport: Viewport = reference.get_ref() if reference != null else null
		if viewport == null:
			continue
		var world := viewport.find_world_3d() if viewport.is_inside_tree() else null
		var fog_active := world != null and selected.has(world.get_instance_id())
		if fog_active:
			if not _debanding_original.has(id):
				_debanding_original[id] = {"viewport": weakref(viewport), "enabled": viewport.use_debanding}
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
	var worlds := _snapshot_worlds()
	if worlds != null:
		return worlds.targets_for(world)
	var targets: Array[RID] = []
	return targets

## The sun for a world: the component's explicit light when set, otherwise the
## first enabled DirectionalLight3D on the same World3D — Unreal's equivalent is
## the directional light flagged "Atmosphere Sun Light", which Godot does not
## have, so a dedicated override on the component covers the multi-sun case.
static func _attach_light_tree(tree: SceneTree) -> void:
	if tree == _light_tree:
		return
	_detach_light_tree()
	_light_tree = tree
	if tree == null:
		return
	tree.node_added.connect(_light_added)
	tree.node_removed.connect(_light_removed)
	for light in tree.root.find_children("*", "DirectionalLight3D", true, false):
		_light_added(light)

static func _detach_light_tree() -> void:
	if is_instance_valid(_light_tree):
		if _light_tree.node_added.is_connected(_light_added):
			_light_tree.node_added.disconnect(_light_added)
		if _light_tree.node_removed.is_connected(_light_removed):
			_light_tree.node_removed.disconnect(_light_removed)
	_light_tree = null
	_scene_lights.clear()

static func _light_added(node: Node) -> void:
	if node is DirectionalLight3D:
		_scene_lights[node.get_instance_id()] = weakref(node)

static func _light_removed(node: Node) -> void:
	if node is DirectionalLight3D:
		_scene_lights.erase(node.get_instance_id())

static func _light_in_world(light: DirectionalLight3D, world: World3D) -> bool:
	return is_instance_valid(light) and light.is_inside_tree() and light.is_visible_in_tree() and light.get_world_3d() == world

static func _sun_for(fog: FengHeightFog, world: World3D) -> DirectionalLight3D:
	var explicit_light := fog.sun_light
	if explicit_light != null:
		return explicit_light if _light_in_world(explicit_light, world) else null
	var found: DirectionalLight3D
	for reference: WeakRef in _scene_lights.values():
		var candidate := reference.get_ref() as DirectionalLight3D
		if not _light_in_world(candidate, world):
			continue
		if found == null or found.is_greater_than(candidate):
			found = candidate
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
		_add_sky_ambient(snapshot, world_id)
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
			# Match DirectionalLightData in light_storage.cpp: non-physical
			# lights carry PI in their energy, while physical directional lights
			# multiply their artist energy by the authored illuminance in lux.
			var sun_energy := sun.light_energy
			var use_physical_light_units := bool(ProjectSettings.get_setting(
					"rendering/lights_and_shadows/use_physical_light_units", false))
			if use_physical_light_units:
				sun_energy *= float(sun.get("light_intensity_lux"))
			else:
				sun_energy *= PI
			if sun.light_negative:
				sun_energy *= -1.0
			var linear_sun_color := sun.light_color.srgb_to_linear()
			# Godot applies correlated color temperature to physical lights only.
			# Keep this conditional in step with Light3D so non-physical lights are
			# byte-for-byte unchanged by the fog's directional lobe.
			if use_physical_light_units:
				linear_sun_color *= sun.get_correlated_color().srgb_to_linear()
			var sun_rgb := Vector3(linear_sun_color.r, linear_sun_color.g, linear_sun_color.b) * sun_energy
			if snapshot.has("fog_albedo"):
				# The base medium scatters the same selected light that illuminates
				# scene surfaces. The atmosphere snapshot's ground irradiance must
				# not replace this source: surfaces do not consume that transmission,
				# and it is zero at the horizon, erasing white fog's body entirely.
				# The sky mean is already phase-integrated; only direct light gets
				# the isotropic 1/(4*PI) phase here.
				var albedo: Vector3 = snapshot["fog_albedo"]
				snapshot["fog_color"] += albedo * sun_rgb.max(Vector3.ZERO) / (4.0 * PI)
			# The directional lobe is an independent artist-authored color,
			# not another material-albedo term. Preserve its original raw-sun
			# luminance contract in both modes so changing the base color cannot
			# recolor it or silently disable it (including a black base color).
			var sun_luminance := sun_rgb.x * 0.2126 + sun_rgb.y * 0.7152 + sun_rgb.z * 0.0722
			snapshot["inscattering_color"] *= sun_luminance
		snapshot["world_id"] = world_id
		snapshot["fog_id"] = entry["id"]
		snapshot["render_targets"] = _render_targets(entry["world"])
		result.append(snapshot)
	_mutex.lock()
	_snapshots = result
	_mutex.unlock()
