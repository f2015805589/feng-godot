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
const SKY_RUNTIME_PATH := "res://addons/feng-sky/feng_sky_runtime.gd"
const SKY_RUNTIME_PROBE_INTERVAL_MSEC := 500
## Optional render-target registry shared by the FRP snapshot consumers.
const SNAPSHOT_WORLDS_PATH := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"

static var _fogs: Dictionary = {} ## instance id -> {node: WeakRef, sequence: int}
static var _debanding_original: Dictionary = {} ## viewport id -> {viewport: WeakRef, enabled: bool}
static var _sun_scans: Dictionary = {} ## world id -> {time: int, light: WeakRef}
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

## Adds the sky model's mean incident radiance independently of the authored
## Fog Inscattering Color and directional sunlight terms.
## Pre-exposure remains solely the height-fog pass's responsibility.
static func _add_sky_ambient(snapshot: Dictionary, world_id: int, sky_snapshot: Variant = null) -> void:
	var sky: Dictionary
	if sky_snapshot is Dictionary:
		sky = sky_snapshot
	else:
		sky = _sky_snapshot_for_world(world_id)
	if sky.is_empty() or not bool(sky.get("affect_height_fog", true)):
		return
	var ambient: Variant = sky.get("ambient_radiance")
	if not ambient is Vector3 or not ambient.is_finite():
		return
	var contribution_scale := _sky_height_fog_contribution_scale(sky)
	# snapshot_fields() owns the local schema and normalizes ambient_scale.
	var ambient_scale: Vector3 = snapshot["sky_atmosphere_ambient_contribution_color_scale"]
	var combined_fog_color: Vector3 = snapshot["fog_color"] + ambient * ambient_scale * contribution_scale
	if combined_fog_color.is_finite():
		snapshot["fog_color"] = combined_fog_color

static func _sky_height_fog_contribution_scale(sky: Dictionary) -> float:
	var scale_value: Variant = sky.get("height_fog_contribution", 1.0)
	if scale_value is int or scale_value is float:
		var authored_scale := float(scale_value)
		if is_finite(authored_scale):
			return maxf(authored_scale, 0.0)
	return 1.0

## Returns post-transmittance illuminance only for the active atmosphere's
## primary sun. Other scene lights still drive the artist directional lobe,
## but do not receive an atmosphere-derived physical-light term.
static func _matched_atmosphere_sun_illuminance(sun: DirectionalLight3D, sky: Dictionary) -> Variant:
	if sun.light_negative or sky.is_empty() or not bool(sky.get("affect_height_fog", true)):
		return null
	var sun_id := sun.get_instance_id()
	if int(sky.get("sun_light_id", 0)) != sun_id:
		return null
	var value: Variant = sky.get("sun_ground_illuminance")
	if not value is Vector3 or not value.is_finite():
		return null
	return value.max(Vector3.ZERO)

## Built-in atmosphere skies publish post-transmittance illuminance for the
## primary sun. Custom skies and unrelated lights retain their authored scene
## light color for the artist directional lobe.
static func _fog_sun_illuminance(sun: DirectionalLight3D, sky: Dictionary, fallback: Vector3) -> Vector3:
	var matched: Variant = _matched_atmosphere_sun_illuminance(sun, sky)
	return matched if matched is Vector3 else fallback

static func register(fog: FengHeightFog) -> void:
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
	var active_viewports: Dictionary = {}
	for selected_world_id in selected:
		var entry: Dictionary = selected[selected_world_id]
		var world: World3D = entry.get("world")
		if world == null or not is_instance_valid(world):
			continue
		var viewports: Dictionary = worlds.viewports_for_world(world)
		for id in viewports:
			var reference: WeakRef = viewports[id]
			var viewport: Viewport = reference.get_ref() if reference != null else null
			if viewport == null or not is_instance_valid(viewport):
				continue
			active_viewports[id] = true
			if not _debanding_original.has(id):
				_debanding_original[id] = {"viewport": weakref(viewport), "enabled": viewport.use_debanding}
			if not viewport.use_debanding:
				viewport.use_debanding = true
	for id in _debanding_original.keys():
		if active_viewports.has(id):
			continue
		var reference: WeakRef = _debanding_original[id]["viewport"]
		var original_viewport: Viewport = reference.get_ref() if reference != null else null
		if original_viewport != null and is_instance_valid(original_viewport):
			_restore_debanding(id, original_viewport)
		else:
			_debanding_original.erase(id)

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

## Prefer the active Feng Sky Atmosphere's primary sun when it is still a
## visible light in this world. Otherwise use the cached scene-light fallback.
static func _sun_for(fog: FengHeightFog, world: World3D, sky: Dictionary = {}) -> DirectionalLight3D:
	if world != null and not sky.is_empty():
		var primary_id := int(sky.get("sun_light_id", 0))
		if primary_id > 0:
			var primary := instance_from_id(primary_id)
			if is_instance_valid(primary) and primary is DirectionalLight3D and primary.is_inside_tree() \
					and primary.is_visible_in_tree() and primary.get_world_3d() == world:
				return primary
	var world_id := world.get_instance_id() if world != null else 0
	var now := Time.get_ticks_msec()
	var scan: Variant = _sun_scans.get(world_id)
	if scan != null and now - int(scan["time"]) < SUN_SCAN_MSEC:
		var cached: DirectionalLight3D = scan["light"].get_ref()
		if is_instance_valid(cached) and cached.is_inside_tree() \
				and cached.is_visible_in_tree() and cached.get_world_3d() == world:
			return cached
		if not bool(scan.get("had_light", false)):
			return null
		# A previously selected light that was removed, hidden, or moved between
		# worlds invalidates the cache immediately. Truly empty worlds keep their
		# TTL so they do not trigger a scene-tree scan every frame.
	var found: DirectionalLight3D = null
	var tree := fog.get_tree()
	if tree != null:
		var stack: Array = [tree.root]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			if node is DirectionalLight3D and node.is_visible_in_tree() and node.get_world_3d() == world:
				found = node
				break
			stack.append_array(node.get_children())
	_sun_scans[world_id] = {
		"time": now,
		"light": weakref(found),
		"world": weakref(world),
		"had_light": found != null,
	}
	if _sun_scans.size() > 16:
		# Worlds churn with editor sub-viewports; drop entries whose world is gone.
		for old_id in _sun_scans.keys():
			var old_world: WeakRef = _sun_scans[old_id].get("world")
			if old_world == null or old_world.get_ref() == null:
				_sun_scans.erase(old_id)
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
		var sky_snapshot := _sky_snapshot_for_world(world_id)
		_add_sky_ambient(snapshot, world_id, sky_snapshot)
		var sun := _sun_for(fog, entry["world"], sky_snapshot)
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
				sun_energy *= sun.light_intensity_lux
			else:
				sun_energy *= PI
			if sun.light_negative:
				sun_energy *= -1.0
			var linear_sun_color := sun.light_color.srgb_to_linear()
			# Godot applies correlated color temperature to physical lights only.
			if use_physical_light_units:
				linear_sun_color *= sun.get_correlated_color().srgb_to_linear()
			var sun_rgb := Vector3(linear_sun_color.r, linear_sun_color.g, linear_sun_color.b) * sun_energy
			var matched_atmosphere_sun: Variant = _matched_atmosphere_sun_illuminance(sun, sky_snapshot)
			# Unreal's artist lobe uses the selected light's raw scene color,
			# independent from the atmosphere's post-transmittance solar input.
			var sun_luminance := sun_rgb.x * 0.2126 + sun_rgb.y * 0.7152 + sun_rgb.z * 0.0722
			var inscattering_color: Vector3 = snapshot["inscattering_color"] * sun_luminance
			if matched_atmosphere_sun is Vector3:
				var contribution_scale := _sky_height_fog_contribution_scale(sky_snapshot)
				var atmosphere_sun_lobe: Vector3 = matched_atmosphere_sun * contribution_scale
				if atmosphere_sun_lobe.is_finite():
					var combined_inscattering := inscattering_color + atmosphere_sun_lobe
					if combined_inscattering.is_finite():
						inscattering_color = combined_inscattering
			snapshot["inscattering_color"] = inscattering_color
		snapshot["world_id"] = world_id
		snapshot["fog_id"] = entry["id"]
		snapshot["render_targets"] = _render_targets(entry["world"])
		result.append(snapshot)
	_mutex.lock()
	_snapshots = result
	_mutex.unlock()
