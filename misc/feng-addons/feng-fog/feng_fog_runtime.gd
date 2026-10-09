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
const SKY_LIGHT_RUNTIME_PATH := "res://addons/feng-sky/feng_sky_light_runtime.gd"
const SKY_LIGHT_RUNTIME_PROBE_INTERVAL_MSEC := 500
const BAKED_LIGHTING_PROVIDER_PATH := "res://addons/feng-fog/rendering/baked_lighting/fog_baked_lighting_provider.gd"
const VOLUMETRIC_LIGHTMAP_PROVIDER_PATH := "res://addons/feng-fog/rendering/baked_lighting/volumetric_lightmap/fog_volumetric_lightmap_provider.gd"
const BAKED_SOURCE_LIGHTMAP_GI_PROBES := "lightmap_gi_probe_tetra"
const BAKED_SOURCE_UE_VOLUMETRIC_BRICKS := "ue_volumetric_lightmap_bricks"
const LIGHT_EXTENSION_REGISTRY_PATH := "res://addons/feng-fog/rendering/lighting/light_extensions/fog_light_extension_registry.gd"
const RAY_GEOMETRY_REGISTRY_PATH := "res://addons/feng-fog/rendering/raytracing/fog_rt_geometry_registry.gd"
## Optional render-target registry shared by the FRP snapshot consumers.
const SNAPSHOT_WORLDS_PATH := "res://addons/feng-render-pipeline/passes/snapshot_worlds.gd"

static var _fogs: Dictionary = {} ## registration-ordered instance id -> WeakRef
static var _volumes: Dictionary = {} ## local medium instance id -> WeakRef
static var _debanding_original: Dictionary = {} ## viewport id -> {viewport: WeakRef, enabled: bool}
static var _sun_scans: Dictionary = {} ## world id -> {time: int, light: WeakRef}
static var _snapshots: Array[Dictionary] = []
static var _mutex := Mutex.new()
static var _last_frame := -1
static var _worlds_queried := false
static var _worlds: GDScript = null
static var _viewport_owner := RefCounted.new() ## Lease for public calls without an explicit owner
static var _next_sky_runtime_probe_msec := 0
static var _sky_runtime: GDScript = null
static var _next_sky_light_runtime_probe_msec := 0
static var _sky_light_runtime: GDScript = null
static var _baked_payload_cache: Dictionary = {} ## resource instance id -> weak source, revision, immutable payload
static var _baked_snapshot_provider: RefCounted
static var _light_extension_registry: GDScript
static var _ray_geometry_registry_script: GDScript
static var _ray_geometry_registries: Dictionary = {} ## world id -> registry + weak world/root

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


## Carries only plain values from FengSkyLight's explicit provider. This
## metadata accessor does not request the CPU SH or read back the GPU map.
static func _sky_volumetric_metadata_for_world(world_id: int) -> Dictionary:
	if _sky_light_runtime == null:
		var now := Time.get_ticks_msec()
		if now < _next_sky_light_runtime_probe_msec:
			return {}
		_next_sky_light_runtime_probe_msec = now + SKY_LIGHT_RUNTIME_PROBE_INTERVAL_MSEC
		if ResourceLoader.exists(SKY_LIGHT_RUNTIME_PATH):
			var loaded: Variant = load(SKY_LIGHT_RUNTIME_PATH)
			if loaded is GDScript and loaded.has_method("volumetric_metadata_for_world"):
				_sky_light_runtime = loaded
	if _sky_light_runtime == null or not _sky_light_runtime.has_method("volumetric_metadata_for_world"):
		return {}
	var result: Variant = _sky_light_runtime.call("volumetric_metadata_for_world", world_id)
	if not result is Dictionary or result.is_empty():
		return {}
	var metadata: Dictionary = result.duplicate(false)
	if int(metadata.get("world_id", world_id)) != world_id:
		return {}
	return metadata


## Main-thread value-only metadata for the volumetric direct-light consumer.
## It reads the cached rendering snapshot; no atmosphere LUT is sampled here.
static func _volumetric_environment_metadata_for_world(world_id: int) -> Dictionary:
	if world_id == 0:
		return {}
	if _sky_runtime == null:
		_sky_snapshot_for_world(world_id)
	if _sky_runtime == null or not _sky_runtime.has_method("rendering_snapshot_for_world"):
		return {}
	var raw: Variant = _sky_runtime.call("rendering_snapshot_for_world", world_id)
	if not raw is Dictionary or int(raw.get("world_id", 0)) != world_id:
		return {}
	var primary_rid: Variant = raw.get("sun_light_rid", RID())
	var secondary_rid: Variant = raw.get("secondary_sun_light_rid", RID())
	var primary_ground: Variant = raw.get("sun_ground_transmittance", Vector3.ONE)
	var secondary_ground: Variant = raw.get("secondary_sun_ground_transmittance", Vector3.ONE)
	if not primary_rid is RID or not secondary_rid is RID:
		return {}
	if not primary_ground is Vector3 or not primary_ground.is_finite():
		primary_ground = Vector3.ONE
	if not secondary_ground is Vector3 or not secondary_ground.is_finite():
		secondary_ground = Vector3.ONE
	return {
		"world_id": world_id,
		"provider_id": int(raw.get("provider_id", 0)),
		"settings_revision": int(raw.get("settings_revision", 0)),
		"sun_light_rid": primary_rid,
		"secondary_sun_light_rid": secondary_rid,
		"sun_ground_transmittance": primary_ground.clamp(Vector3.ZERO, Vector3.ONE),
		"secondary_sun_ground_transmittance": secondary_ground.clamp(Vector3.ZERO, Vector3.ONE),
	}


## The extension registry performs the SceneTree-facing join on the main thread.
## The returned snapshot contains only light RIDs and plain values.
static func _light_extension_metadata_for_world(world_id: int) -> Dictionary:
	if world_id == 0:
		return {}
	if _light_extension_registry == null:
		if not ResourceLoader.exists(LIGHT_EXTENSION_REGISTRY_PATH):
			return {}
		var loaded: Variant = load(LIGHT_EXTENSION_REGISTRY_PATH)
		if not loaded is GDScript or not loaded.has_method("snapshot_metadata_for_world"):
			return {}
		_light_extension_registry = loaded
	var raw: Variant = _light_extension_registry.call("snapshot_metadata_for_world", world_id)
	if not raw is Dictionary or not bool(raw.get("valid", false)) \
			or int(raw.get("world_id", 0)) != world_id:
		return {}
	return raw.duplicate(false)


## The triangle registry is kept on the main thread and refreshed once per
## runtime publication. Its initial SceneTree walk happens only when this
## world's RT opt-in first becomes active; the render service receives only
## the immutable geometry snapshot.
static func _ray_geometry_snapshot_for_world(world_id: int, world: World3D,
		root: Node) -> Dictionary:
	if world_id == 0 or world == null or root == null or not root.is_inside_tree():
		return {}
	if _ray_geometry_registry_script == null:
		if not ResourceLoader.exists(RAY_GEOMETRY_REGISTRY_PATH):
			return {}
		var loaded: Variant = load(RAY_GEOMETRY_REGISTRY_PATH)
		if not loaded is GDScript or not loaded.has_method("new"):
			return {}
		_ray_geometry_registry_script = loaded
	var entry_value: Variant = _ray_geometry_registries.get(world_id)
	var registry: Variant
	if entry_value is Dictionary:
		var old_world_ref: WeakRef = entry_value.get("world")
		var old_root_ref: WeakRef = entry_value.get("root")
		var old_world: Object = old_world_ref.get_ref() if old_world_ref != null else null
		var old_root: Object = old_root_ref.get_ref() if old_root_ref != null else null
		registry = entry_value.get("registry")
		if old_world != world or old_root != root:
			if registry != null and registry.has_method("detach"):
				registry.call("detach")
			registry = null
	if registry == null:
		var created: Variant = _ray_geometry_registry_script.new()
		if not created is RefCounted or not created.has_method("attach"):
			return {}
		registry = created
		if not bool(registry.call("attach", root, world)):
			registry.call("detach")
			return {}
	_ray_geometry_registries[world_id] = {
		"registry": registry,
		"world": weakref(world),
		"root": weakref(root),
	}
	var raw_snapshot: Variant = registry.call("get_snapshot")
	if not raw_snapshot is Dictionary or int(raw_snapshot.get("abi_version", 0)) != 1:
		return {}
	return raw_snapshot.duplicate(false)


static func _prune_ray_geometry_registries(active_worlds: Dictionary) -> void:
	for world_id in _ray_geometry_registries.keys():
		if active_worlds.has(world_id):
			continue
		var entry_value: Variant = _ray_geometry_registries[world_id]
		if entry_value is Dictionary:
			var registry: Variant = entry_value.get("registry")
			if registry != null and registry.has_method("detach"):
				registry.call("detach")
		_ray_geometry_registries.erase(world_id)

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

## Convert the optional baked resource into a value-only snapshot on the main
## thread. GPU work receives the cached arrays and transforms, never a Resource
## whose properties could change while rendering is in flight.
static func _baked_payload_snapshot(value: Variant) -> Dictionary:
	if not value is Resource or not is_instance_valid(value):
		return {}
	var revision_value: Variant = value.get("revision")
	if not (revision_value is int or revision_value is float) \
			or not is_finite(float(revision_value)):
		return {}
	var resource_id: int = value.get_instance_id()
	var revision := int(revision_value)
	var cached: Variant = _baked_payload_cache.get(resource_id)
	if cached is Dictionary:
		var reference: WeakRef = cached.get("resource")
		if reference != null and reference.get_ref() == value \
				and int(cached.get("revision", -1)) == revision:
			var payload: Variant = cached.get("payload", {})
			return payload if payload is Dictionary else {}
	var source_mode := BAKED_SOURCE_LIGHTMAP_GI_PROBES
	var raw_payload: Variant
	if value.has_method("get_rendering_snapshot"):
		# The UE VLM resource owns a revision-cached, immutable-by-convention
		# rendering snapshot. Keep the resource on the main-thread side only.
		source_mode = BAKED_SOURCE_UE_VOLUMETRIC_BRICKS
		if not ResourceLoader.exists(VOLUMETRIC_LIGHTMAP_PROVIDER_PATH):
			return {}
		var vlm_provider_script: Variant = load(VOLUMETRIC_LIGHTMAP_PROVIDER_PATH)
		if not vlm_provider_script is GDScript \
				or not vlm_provider_script.has_method("snapshot_for_rendering"):
			return {}
		raw_payload = vlm_provider_script.call("snapshot_for_rendering", value)
	else:
		if not value.has_method("get_gpu_payload"):
			return {}
		if _baked_snapshot_provider == null:
			if not ResourceLoader.exists(BAKED_LIGHTING_PROVIDER_PATH):
				return {}
			var provider_script: Variant = load(BAKED_LIGHTING_PROVIDER_PATH)
			if not provider_script is Script:
				return {}
			var provider_instance: Variant = provider_script.new()
			if not provider_instance is RefCounted:
				return {}
			_baked_snapshot_provider = provider_instance
		raw_payload = _baked_snapshot_provider.call("snapshot_for_rendering", value)
	var payload_snapshot: Dictionary = raw_payload.duplicate(false) if raw_payload is Dictionary else {}
	if payload_snapshot.is_empty():
		_baked_payload_cache.erase(resource_id)
		return {}
	# The published renderer packet is values-only. The provider keeps its own
	# weak resource reference and revision cache on the main-thread side.
	payload_snapshot.erase("resource_ref")
	payload_snapshot["source_mode"] = source_mode
	payload_snapshot["resource_id"] = resource_id
	payload_snapshot["revision"] = revision
	_baked_payload_cache[resource_id] = {
		"resource": weakref(value),
		"revision": revision,
		"payload": payload_snapshot,
	}
	return payload_snapshot

static func _prune_baked_payload_cache() -> void:
	for resource_id in _baked_payload_cache.keys():
		var cached: Dictionary = _baked_payload_cache[resource_id]
		var reference: WeakRef = cached.get("resource")
		if reference == null or reference.get_ref() == null:
			_baked_payload_cache.erase(resource_id)
			var payload: Variant = cached.get("payload", {})
			var source_mode := String(payload.get("source_mode", "")) \
					if payload is Dictionary else ""
			if source_mode == BAKED_SOURCE_LIGHTMAP_GI_PROBES \
					and _baked_snapshot_provider != null \
					and _baked_snapshot_provider.has_method("release_resource"):
				_baked_snapshot_provider.call("release_resource", int(resource_id))

static func register(fog: Variant) -> void:
	# Replacing an existing key keeps its original registration order.
	_fogs[fog.get_instance_id()] = weakref(fog)
	register_viewport(fog.get_viewport(), fog)

static func unregister(fog: Variant) -> void:
	var worlds := _snapshot_worlds()
	if worlds != null:
		worlds.unregister_owner(fog)
	_fogs.erase(fog.get_instance_id())
	_publish()

static func register_volume(volume: Variant) -> void:
	_volumes[volume.get_instance_id()] = weakref(volume)
	register_viewport(volume.get_viewport(), volume)
	_publish()

static func unregister_volume(volume: Variant) -> void:
	var worlds := _snapshot_worlds()
	if worlds != null:
		worlds.unregister_owner(volume)
	_volumes.erase(volume.get_instance_id())
	_publish()

static func publish_volume(volume: Variant) -> void:
	if volume.is_inside_tree():
		register_volume(volume)

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
		var fog: Variant = selected[selected_world_id]
		var world: World3D = fog.get_world_3d()
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

static func publish(fog: Variant) -> void:
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
static func _sun_for(fog: Variant, world: World3D, sky: Dictionary = {}) -> DirectionalLight3D:
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
	var tree: SceneTree = fog.get_tree()
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
	_prune_baked_payload_cache()
	var selected: Dictionary = {} ## world id -> latest registered enabled fog
	for id in _fogs.keys():
		var fog: Variant = _fogs[id].get_ref()
		if fog == null:
			_fogs.erase(id)
			continue
		if not fog.is_inside_tree() or not fog.enabled:
			continue
		var world: World3D = fog.get_world_3d()
		if world == null:
			continue
		var world_id: int = world.get_instance_id()
		selected[world_id] = fog
	var selected_volumes: Dictionary = {} ## world id -> immutable local-volume dictionaries
	var volume_worlds: Dictionary = {} ## world id -> WeakRef
	for id in _volumes.keys():
		var volume: Variant = _volumes[id].get_ref()
		if volume == null:
			_volumes.erase(id)
			continue
		if not volume.is_inside_tree() or not volume.enabled:
			continue
		var volume_world: World3D = volume.get_world_3d()
		if volume_world == null:
			continue
		var volume_world_id: int = volume_world.get_instance_id()
		if not selected_volumes.has(volume_world_id):
			selected_volumes[volume_world_id] = []
		selected_volumes[volume_world_id].append(volume.snapshot_fields())
		volume_worlds[volume_world_id] = weakref(volume_world)
	_sync_debanding(selected)
	var result: Array[Dictionary] = []
	var world_ids: Dictionary = {}
	var active_ray_worlds: Dictionary = {}
	for world_id in selected.keys():
		world_ids[world_id] = true
	for world_id in selected_volumes.keys():
		world_ids[world_id] = true
	for world_id in world_ids.keys():
		var fog: Variant = selected.get(world_id)
		var world: World3D
		var snapshot: Dictionary
		if fog != null:
			world = fog.get_world_3d()
			snapshot = fog.snapshot_fields()
			snapshot["baked_irradiance"] = _baked_payload_snapshot(
					snapshot.get("baked_irradiance"))
			snapshot["volumetric_sky_metadata"] = _sky_volumetric_metadata_for_world(world_id)
			var sky_snapshot := _sky_snapshot_for_world(world_id)
			_add_sky_ambient(snapshot, world_id, sky_snapshot)
			var sun := _sun_for(fog, world, sky_snapshot)
			# The volume service matches this selected component sun to the directional
			# light buffer's base-RID list. It must not inject every directional light.
			snapshot["volumetric_selected_sun_rid"] = sun.get_base() if sun != null else RID()
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
		else:
			var volume_world: WeakRef = volume_worlds.get(world_id)
			world = volume_world.get_ref() if volume_world != null else null
			snapshot = _empty_fog_snapshot()
			snapshot["volumetric_sky_metadata"] = _sky_volumetric_metadata_for_world(world_id)
		snapshot["local_volumes"] = selected_volumes.get(world_id, [])
		snapshot["world_id"] = world_id
		var ray_enabled := false
		var volume_settings: Variant = snapshot.get("volumetric_fog", {})
		if volume_settings is Dictionary:
			ray_enabled = bool(volume_settings.get("enabled", false)) \
					and bool(volume_settings.get("ray_traced_shadows_enabled", false))
		if ray_enabled and fog != null and world != null:
			var tree: SceneTree = fog.get_tree()
			if tree != null and tree.root != null:
				snapshot["ray_tracing_geometry"] = _ray_geometry_snapshot_for_world(
						world_id, world, tree.root)
				active_ray_worlds[world_id] = true
		else:
			snapshot["ray_tracing_geometry"] = {}
		snapshot["volumetric_environment_metadata"] = \
				_volumetric_environment_metadata_for_world(world_id)
		snapshot["light_extension_metadata"] = _light_extension_metadata_for_world(world_id)
		snapshot["fog_id"] = fog.get_instance_id() if fog != null else 0
		snapshot["render_targets"] = _render_targets(world)
		result.append(snapshot)
	_prune_ray_geometry_registries(active_ray_worlds)
	_mutex.lock()
	_snapshots = result
	_mutex.unlock()

static func _empty_fog_snapshot() -> Dictionary:
	return {
		"fog_density": 0.0, "fog_height_falloff": 0.0, "fog_height": 0.0,
		"second_fog_density": 0.0, "second_fog_height_falloff": 0.0,
		"second_fog_height": 0.0, "fog_color": Vector3.ZERO,
		"artist_fog_inscattering_color": Vector3.ZERO,
		"sky_atmosphere_ambient_contribution_color_scale": Vector3.ONE,
		"min_opacity": 0.0, "start_distance": 0.0, "cutoff_distance": 0.0,
		"sun_direction": Vector3.ZERO, "inscattering_color": Vector3.ZERO,
		"inscattering_start": -1.0, "inscattering_exponent": 4.0,
		"volumetric_fog": {}, "screen_space_scattering": {}, "baked_irradiance": {},
		"volumetric_sky_metadata": {},
		"volumetric_environment_metadata": {}, "light_extension_metadata": {},
		"ray_tracing_geometry": {},
		"volumetric_selected_sun_rid": RID(),
	}
