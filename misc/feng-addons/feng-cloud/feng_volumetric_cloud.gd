@tool
class_name FengVolumetricCloud
extends Node3D
## World-scoped UE-style volumetric cloud component for the Feng Render Pipeline.
## Distances in the Inspector use kilometres; snapshots convert them to metres.

const Runtime = preload("feng_cloud_runtime.gd")

enum MaxDistanceMode { ENTRY_POINT, CAMERA_POSITION }

@export_group("Cloud")
@export var enabled := true:
	set(value):
		if enabled == value:
			return
		enabled = value
		_refresh_runtime_registration()
@export var cloud_material: FengCloudMaterial:
	set(value):
		if cloud_material == value:
			return
		if cloud_material != null and is_instance_valid(cloud_material) \
				and cloud_material.changed.is_connected(_on_material_changed):
			cloud_material.changed.disconnect(_on_material_changed)
		cloud_material = value
		if cloud_material != null and is_instance_valid(cloud_material) \
				and not cloud_material.changed.is_connected(_on_material_changed):
			cloud_material.changed.connect(_on_material_changed)
		_refresh_runtime_registration()
@export var planet_source: FengSkyAtmosphere:
	set(value):
		planet_source = value
		_refresh_runtime_snapshot()
@export_range(1.0, 100000.0, 1.0, "or_greater", "suffix:km") var planet_radius_km := 6360.0:
	set(value):
		planet_radius_km = _finite_range(value, 6360.0, 1.0, 100000.0)
		_refresh_runtime_snapshot()

## The fallback origin is the ground point at altitude zero. The planet centre
## follows the current radius along -Y, so changing radius keeps the ground at
## the same world position. An active FengSkyAtmosphere supplies its own centre.
@export var fallback_planet_ground_origin_m := Vector3.ZERO:
	set(value):
		fallback_planet_ground_origin_m = value if value.is_finite() else Vector3.ZERO
		_refresh_runtime_snapshot()

@export_group("Cloud Layer")
@export_range(-100.0, 100.0, 0.01, "or_greater", "or_less", "suffix:km") var layer_bottom_altitude_km := 5.0:
	set(value):
		layer_bottom_altitude_km = _finite_range(value, 5.0, -100000.0, 100000.0)
		_refresh_runtime_snapshot()
@export_range(0.001, 100.0, 0.01, "or_greater", "suffix:km") var layer_height_km := 10.0:
	set(value):
		layer_height_km = _finite_range(value, 10.0, 0.001, 100000.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:km") var tracing_start_max_distance_km := 350.0:
	set(value):
		tracing_start_max_distance_km = _finite_range(value, 350.0, 0.0, 10000000.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:km") var tracing_start_distance_from_camera_km := 0.0:
	set(value):
		tracing_start_distance_from_camera_km = _finite_range(value, 0.0, 0.0, 10000000.0)
		_refresh_runtime_snapshot()
@export_enum("Entry Point", "Camera Position") var tracing_max_distance_mode: int = MaxDistanceMode.ENTRY_POINT:
	set(value):
		tracing_max_distance_mode = clampi(value, 0, 1)
		_refresh_runtime_snapshot()
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:km") var tracing_max_distance_km := 50.0:
	set(value):
		tracing_max_distance_km = _finite_range(value, 50.0, 0.0, 10000000.0)
		_refresh_runtime_snapshot()

@export_group("Lighting")
@export_custom(PROPERTY_HINT_COLOR_NO_ALPHA, "") var ground_albedo_linear := Color(0.4, 0.4, 0.4):
	set(value):
		ground_albedo_linear = _finite_color(value, Color(0.4, 0.4, 0.4))
		_refresh_runtime_snapshot()
@export var primary_sun: DirectionalLight3D:
	set(value):
		primary_sun = value
		_refresh_runtime_snapshot()
@export var secondary_sun: DirectionalLight3D:
	set(value):
		secondary_sun = value
		_refresh_runtime_snapshot()
@export var per_sample_atmosphere_transmittance := false:
	set(value):
		per_sample_atmosphere_transmittance = value
		_refresh_runtime_snapshot()
@export_range(0.0, 1.0, 0.001) var sky_light_cloud_bottom_occlusion := 0.5:
	set(value):
		sky_light_cloud_bottom_occlusion = clampf(_finite(value, 0.5), 0.0, 1.0)
		_refresh_runtime_snapshot()

@export_subgroup("Sample Scales")
@export_range(0.0, 8.0, 0.01, "or_greater") var view_sample_count_scale := 1.0:
	set(value):
		view_sample_count_scale = maxf(_finite(value, 1.0), 0.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 8.0, 0.01, "or_greater") var reflection_view_sample_count_scale := 1.0:
	set(value):
		reflection_view_sample_count_scale = maxf(_finite(value, 1.0), 0.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 8.0, 0.01, "or_greater") var shadow_view_sample_count_scale := 1.0:
	set(value):
		shadow_view_sample_count_scale = maxf(_finite(value, 1.0), 0.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 8.0, 0.01, "or_greater") var shadow_reflection_view_sample_count_scale := 1.0:
	set(value):
		shadow_reflection_view_sample_count_scale = maxf(_finite(value, 1.0), 0.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:km") var shadow_tracing_distance_km := 15.0:
	set(value):
		shadow_tracing_distance_km = _finite_range(value, 15.0, 0.0, 10000000.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 1.0, 0.001) var stop_tracing_transmittance_threshold := 0.005:
	set(value):
		stop_tracing_transmittance_threshold = clampf(_finite(value, 0.005), 0.0, 1.0)
		_refresh_runtime_snapshot()

@export_subgroup("Aerial Perspective")
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:km") var rayleigh_aerial_perspective_start_km := 0.0:
	set(value):
		rayleigh_aerial_perspective_start_km = _finite_range(value, 0.0, 0.0, 10000000.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:km") var rayleigh_aerial_perspective_fade_km := 0.0:
	set(value):
		rayleigh_aerial_perspective_fade_km = _finite_range(value, 0.0, 0.0, 10000000.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:km") var mie_aerial_perspective_start_km := 0.0:
	set(value):
		mie_aerial_perspective_start_km = _finite_range(value, 0.0, 0.0, 10000000.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 100000.0, 0.1, "or_greater", "suffix:km") var mie_aerial_perspective_fade_km := 0.0:
	set(value):
		mie_aerial_perspective_fade_km = _finite_range(value, 0.0, 0.0, 10000000.0)
		_refresh_runtime_snapshot()

@export_group("Visibility")
@export var holdout := false:
	set(value):
		holdout = value
		_refresh_runtime_snapshot()
@export var render_in_main_pass := true:
	set(value):
		render_in_main_pass = value
		_refresh_runtime_snapshot()
@export var visible_in_realtime_sky_captures := true:
	set(value):
		visible_in_realtime_sky_captures = value
		_refresh_runtime_snapshot()

var _registered_world_id := 0
var _registered_viewport_ref: WeakRef
var _last_snapshot_signature: Array = []
var _watched_shadow_settings: Dictionary = {} # Resource instance id -> WeakRef.

@export_group("Cloud Shadowing")
@export var cloud_shadow_settings: FengCloudShadowSettings = FengCloudShadowSettings.create_default():
	set(value):
		if cloud_shadow_settings == value:
			return
		cloud_shadow_settings = value
		_sync_shadow_settings_connections()
		_refresh_runtime_registration()
@export var primary_sun_cloud_shadow_settings: FengCloudShadowSettings:
	set(value):
		if primary_sun_cloud_shadow_settings == value:
			return
		primary_sun_cloud_shadow_settings = value
		_sync_shadow_settings_connections()
		_refresh_runtime_registration()
@export var secondary_sun_cloud_shadow_settings: FengCloudShadowSettings:
	set(value):
		if secondary_sun_cloud_shadow_settings == value:
			return
		secondary_sun_cloud_shadow_settings = value
		_sync_shadow_settings_connections()
		_refresh_runtime_registration()
@export var primary_sun_cast_shadows_on_clouds := false:
	set(value):
		primary_sun_cast_shadows_on_clouds = value
		_refresh_runtime_snapshot()
@export var secondary_sun_cast_shadows_on_clouds := false:
	set(value):
		secondary_sun_cast_shadows_on_clouds = value
		_refresh_runtime_snapshot()
@export var primary_sun_cast_cloud_shadows := false:
	set(value):
		primary_sun_cast_cloud_shadows = value
		_refresh_runtime_snapshot()
@export var secondary_sun_cast_cloud_shadows := false:
	set(value):
		secondary_sun_cast_cloud_shadows = value
		_refresh_runtime_snapshot()

@export_group("Cloud Sky AO")
@export var sky_ao_enabled := false:
	set(value):
		sky_ao_enabled = value
		_refresh_runtime_snapshot()
@export_range(1.0, 10000.0, 1.0, "or_greater", "suffix:km") var sky_ao_extent_km := 150.0:
	set(value):
		sky_ao_extent_km = maxf(_finite(value, 150.0), 1.0)
		_refresh_runtime_snapshot()
@export_range(0.25, 8.0, 0.01, "or_greater") var sky_ao_resolution_scale := 1.0:
	set(value):
		sky_ao_resolution_scale = clampf(_finite(value, 1.0), 0.25, 8.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 1.0, 0.001) var sky_ao_strength := 1.0:
	set(value):
		sky_ao_strength = clampf(_finite(value, 1.0), 0.0, 1.0)
		_refresh_runtime_snapshot()
@export_range(0.0, 1.0, 0.001) var sky_ao_aperture := 0.05:
	set(value):
		sky_ao_aperture = clampf(_finite(value, 0.05), 0.0, 1.0)
		_refresh_runtime_snapshot()
@export_range(1, 256, 1) var sky_ao_sample_count := 10:
	set(value):
		sky_ao_sample_count = clampi(value, 1, 256)
		_refresh_runtime_snapshot()
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:km") var sky_ao_snap_length_km := 20.0:
	set(value):
		sky_ao_snap_length_km = maxf(_finite(value, 20.0), 0.0)
		_refresh_runtime_snapshot()


func _init() -> void:
	if cloud_material == null:
		cloud_material = FengCloudMaterial.create_default()
	_sync_shadow_settings_connections()


func _enter_tree() -> void:
	set_notify_transform(true)
	set_process(true)
	_sync_shadow_settings_connections()
	_refresh_runtime_registration()


func _ready() -> void:
	_refresh_runtime_registration()


func _exit_tree() -> void:
	_sync_viewport_registration(false)
	if cloud_material != null and is_instance_valid(cloud_material) \
			and cloud_material.changed.is_connected(_on_material_changed):
		cloud_material.changed.disconnect(_on_material_changed)
	Runtime.unregister_cloud(self, _registered_world_id)
	_registered_world_id = 0
	_last_snapshot_signature.clear()
	_clear_shadow_settings_connections()


func _process(_delta: float) -> void:
	if not is_inside_tree():
		return
	_refresh_runtime_registration()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED or what == NOTIFICATION_ENTER_WORLD or what == NOTIFICATION_EXIT_WORLD:
		_refresh_runtime_registration()


func _feng_cloud_runtime_is_active(world_id: int) -> bool:
	if not enabled or cloud_material == null or not is_instance_valid(cloud_material) \
			or not cloud_material.has_density_source() or not is_inside_tree():
		return false
	var world := get_world_3d()
	return world != null and is_instance_valid(world) and world.get_instance_id() == world_id


func _refresh_runtime_registration() -> void:
	if not is_inside_tree() or not enabled or cloud_material == null \
			or not is_instance_valid(cloud_material) or not cloud_material.has_density_source():
		_sync_viewport_registration(false)
		if _registered_world_id != 0:
			Runtime.unregister_cloud(self, _registered_world_id)
			_registered_world_id = 0
			_last_snapshot_signature.clear()
		return
	_sync_viewport_registration(true)
	var world := get_world_3d()
	var world_id := world.get_instance_id() if world != null and is_instance_valid(world) else 0
	if world_id != _registered_world_id:
		Runtime.unregister_cloud(self, _registered_world_id)
		_registered_world_id = Runtime.register_cloud(self, world) if world_id != 0 else 0
		_last_snapshot_signature.clear()
	if _registered_world_id != 0:
		var signature := _snapshot_signature()
		if signature != _last_snapshot_signature:
			_last_snapshot_signature = signature
			_publish_snapshot()


func _sync_viewport_registration(should_register: bool) -> void:
	var desired_viewport := get_viewport() if should_register and is_inside_tree() else null
	var previous_viewport: Viewport = _registered_viewport_ref.get_ref() if _registered_viewport_ref != null else null
	if previous_viewport == desired_viewport:
		return
	if previous_viewport != null and is_instance_valid(previous_viewport):
		Runtime.unregister_viewport(previous_viewport, self)
	_registered_viewport_ref = null
	if desired_viewport != null and is_instance_valid(desired_viewport):
		Runtime.register_viewport(desired_viewport, self)
		_registered_viewport_ref = weakref(desired_viewport)


func _refresh_runtime_snapshot() -> void:
	if is_inside_tree():
		_refresh_runtime_registration()


func _on_material_changed() -> void:
	_refresh_runtime_registration()


func _publish_snapshot() -> void:
	var world := get_world_3d()
	if world == null or not is_instance_valid(world) or _registered_world_id == 0:
		return
	var snapshot := _build_snapshot(world)
	if not snapshot.is_empty():
		Runtime.publish_cloud(self, _registered_world_id, snapshot)


func _build_snapshot(world: World3D) -> Dictionary:
	var material_snapshot := cloud_material.rendering_snapshot() if cloud_material != null else {}
	if material_snapshot.is_empty():
		return {}
	var world_id := world.get_instance_id()
	var sky_snapshot := _effective_sky_snapshot(world)
	var settings: Dictionary = sky_snapshot.get("settings", {})
	var radius_km := float(settings.get("planet_radius_km", planet_radius_km))
	var fallback_center := fallback_planet_ground_origin_m - Vector3.UP * radius_km * 1000.0
	var planet_center: Vector3 = settings.get("planet_center_m", fallback_center)
	var suns := _resolve_sun_inputs(sky_snapshot)
	return {
		"provider_id": get_instance_id(),
		"world_id": world_id,
		"component_transform": global_transform,
		"planet_center_m": planet_center,
		"planet_radius_m": radius_km * 1000.0,
		"planet_source_id": int(sky_snapshot.get("provider_id", 0)),
		"atmosphere_revision": int(sky_snapshot.get("settings_revision", -1)),
		"sky_rendering_signature": [sky_snapshot],
		"atmosphere_snapshot": sky_snapshot,
		"layer_bottom_m": layer_bottom_altitude_km * 1000.0,
		"layer_height_m": layer_height_km * 1000.0,
		"tracing_start_max_distance_m": tracing_start_max_distance_km * 1000.0,
		"tracing_start_distance_from_camera_m": tracing_start_distance_from_camera_km * 1000.0,
		"tracing_max_distance_mode": tracing_max_distance_mode,
		"tracing_max_distance_m": tracing_max_distance_km * 1000.0,
		"shadow_tracing_distance_m": shadow_tracing_distance_km * 1000.0,
		"stop_tracing_transmittance_threshold": stop_tracing_transmittance_threshold,
		"ground_albedo_linear": Vector3(ground_albedo_linear.r, ground_albedo_linear.g, ground_albedo_linear.b),
		"per_sample_atmosphere_transmittance": per_sample_atmosphere_transmittance,
		"sky_light_cloud_bottom_occlusion": sky_light_cloud_bottom_occlusion,
		"view_sample_count_scale": view_sample_count_scale,
		"reflection_view_sample_count_scale": reflection_view_sample_count_scale,
		"shadow_view_sample_count_scale": shadow_view_sample_count_scale,
		"shadow_reflection_view_sample_count_scale": shadow_reflection_view_sample_count_scale,
		"rayleigh_aerial_perspective_start_m": rayleigh_aerial_perspective_start_km * 1000.0,
		"rayleigh_aerial_perspective_fade_m": rayleigh_aerial_perspective_fade_km * 1000.0,
		"mie_aerial_perspective_start_m": mie_aerial_perspective_start_km * 1000.0,
		"mie_aerial_perspective_fade_m": mie_aerial_perspective_fade_km * 1000.0,
		"holdout": holdout,
		"render_in_main_pass": render_in_main_pass,
		"visible_in_realtime_sky_captures": visible_in_realtime_sky_captures,
		"cloud_shadow": _cloud_shadow_snapshot(cloud_shadow_settings, suns),
		"sky_ao": {
			"enabled": sky_ao_enabled,
			"extent_km": sky_ao_extent_km,
			"resolution": mini(int(round(512.0 * sky_ao_resolution_scale)), 2048),
			"strength": sky_ao_strength,
			"aperture": sky_ao_aperture,
			"sample_count": sky_ao_sample_count,
			"snap_length_km": sky_ao_snap_length_km,
		},
		"sun_inputs": suns,
		"kernel_layout": material_snapshot.get("kernel_layout", "builtin"),
		"material": material_snapshot,
	}


func _resolve_sun_inputs(sky_snapshot: Dictionary) -> Array[Dictionary]:
	# Preserve the sun slot indices even when only the secondary light is active;
	# cloud shadow map controls are per-sun.
	var result: Array[Dictionary] = []
	for index in 2:
		var sun := _sun_from_light(primary_sun if index == 0 else secondary_sun)
		if sun.is_empty():
			sun = _sun_from_atmosphere(sky_snapshot, index == 1)
		if index == 1 and not result[0].is_empty() and sun.get("light_rid", RID()) == result[0].get("light_rid", RID()):
			sun = {} # One directional light cannot occupy both slots.
		result.append(_build_sun_input(sun, index, sky_snapshot) if not sun.is_empty() else {})
	return result


func _build_sun_input(sun: Dictionary, index: int, sky_snapshot: Dictionary) -> Dictionary:
	var result := _attach_ground_transmittance(sun, sky_snapshot)
	result["cast_shadows_on_clouds"] = primary_sun_cast_shadows_on_clouds if index == 0 else secondary_sun_cast_shadows_on_clouds
	result["cast_cloud_shadows"] = primary_sun_cast_cloud_shadows if index == 0 else secondary_sun_cast_cloud_shadows
	var override_settings := primary_sun_cloud_shadow_settings if index == 0 else secondary_sun_cloud_shadow_settings
	if override_settings != null and is_instance_valid(override_settings):
		result["cloud_shadow"] = override_settings.rendering_snapshot()
	return result


func _cloud_shadow_snapshot(settings: FengCloudShadowSettings, sun_inputs: Array[Dictionary]) -> Dictionary:
	var result := settings.rendering_snapshot() if settings != null and is_instance_valid(settings) else FengCloudShadowSettings.create_default().rendering_snapshot()
	var any_sun_enabled := false
	for item in sun_inputs:
		var light_rid: Variant = item.get("light_rid", RID())
		if bool(item.get("cast_cloud_shadows", false)) and light_rid is RID and light_rid.is_valid():
			any_sun_enabled = true
			break
	result["enabled"] = any_sun_enabled
	return result


func _sun_from_light(light: DirectionalLight3D) -> Dictionary:
	if light == null or not is_instance_valid(light) or not light.is_inside_tree() or not light.is_visible_in_tree():
		return {}
	var light_world := light.get_world_3d()
	var cloud_world := get_world_3d()
	if light_world == null or cloud_world == null or light_world != cloud_world:
		return {}
	return {
		"instance_id": light.get_instance_id(),
		"light_rid": light.get_base(),
		"direction_world": light.global_transform.basis.z.normalized(),
	}


func _sun_from_atmosphere(snapshot: Dictionary, secondary: bool) -> Dictionary:
	var prefix := "secondary_sun_" if secondary else "sun_"
	var light_rid: Variant = snapshot.get(prefix + "light_rid", RID())
	if not light_rid is RID or not light_rid.is_valid():
		return {}
	return {
		"instance_id": int(snapshot.get(prefix + "light_instance_id", 0)),
		"light_rid": light_rid,
		"direction_world": _vector3(snapshot.get(prefix + "direction", Vector3.UP), Vector3.UP).normalized(),
	}


func _attach_ground_transmittance(sun: Dictionary, sky_snapshot: Dictionary) -> Dictionary:
	var result := sun.duplicate()
	result["ground_transmittance"] = Vector3.ONE
	var light_rid: Variant = result.get("light_rid", RID())
	if not light_rid is RID or not light_rid.is_valid():
		return result
	for prefix in ["sun_", "secondary_sun_"]:
		if light_rid != sky_snapshot.get(prefix + "light_rid", RID()):
			continue
		var transmittance: Variant = sky_snapshot.get(prefix + "ground_transmittance", Vector3.ONE)
		if transmittance is Vector3 and transmittance.is_finite():
			result["ground_transmittance"] = transmittance.max(Vector3.ZERO).min(Vector3.ONE)
		break
	return result


func _effective_sky_snapshot(world: World3D) -> Dictionary:
	var snapshot := Runtime.sky_rendering_snapshot_for_world(world.get_instance_id())
	if planet_source == null:
		return snapshot
	if not is_instance_valid(planet_source):
		return {}
	if int(snapshot.get("provider_id", 0)) == planet_source.get_instance_id():
		return snapshot
	return planet_source.rendering_snapshot(world)


func _snapshot_signature() -> Array:
	var world := get_world_3d()
	var sky_snapshot := _effective_sky_snapshot(world) \
			if world != null and is_instance_valid(world) else {}
	var signature: Array = [
		enabled, world, global_transform, planet_source,
		sky_snapshot, Runtime.viewport_generation_for_world(world) if world != null else -1,
		planet_radius_km, fallback_planet_ground_origin_m,
		layer_bottom_altitude_km, layer_height_km,
		tracing_start_max_distance_km, tracing_start_distance_from_camera_km,
		tracing_max_distance_mode, tracing_max_distance_km, ground_albedo_linear,
		primary_sun, secondary_sun, per_sample_atmosphere_transmittance,
		sky_light_cloud_bottom_occlusion, view_sample_count_scale,
		reflection_view_sample_count_scale, shadow_view_sample_count_scale,
		shadow_reflection_view_sample_count_scale, shadow_tracing_distance_km,
		stop_tracing_transmittance_threshold, rayleigh_aerial_perspective_start_km,
		rayleigh_aerial_perspective_fade_km, mie_aerial_perspective_start_km,
		mie_aerial_perspective_fade_km, holdout, render_in_main_pass,
		visible_in_realtime_sky_captures,
		primary_sun_cast_shadows_on_clouds,
		secondary_sun_cast_shadows_on_clouds, primary_sun_cast_cloud_shadows,
		secondary_sun_cast_cloud_shadows, sky_ao_enabled, sky_ao_extent_km,
		sky_ao_resolution_scale, sky_ao_strength, sky_ao_aperture,
		sky_ao_sample_count, sky_ao_snap_length_km,
	]
	for light in [primary_sun, secondary_sun]:
		if light != null and is_instance_valid(light):
			var sun := _sun_from_light(light)
			signature.append_array([
				light.get_base(), light.is_visible_in_tree(),
				sun.get("direction_world", Vector3.ZERO),
			])
	if cloud_material != null and is_instance_valid(cloud_material):
		signature.append_array([cloud_material.get_instance_id(), cloud_material.get_revision()])
	for settings in [cloud_shadow_settings, primary_sun_cloud_shadow_settings, secondary_sun_cloud_shadow_settings]:
		if settings != null and is_instance_valid(settings):
			signature.append_array([settings.get_instance_id(), settings.get_revision()])
	return signature


func _sync_shadow_settings_connections() -> void:
	var desired: Dictionary = {}
	for resource in [cloud_shadow_settings, primary_sun_cloud_shadow_settings, secondary_sun_cloud_shadow_settings]:
		if resource != null and is_instance_valid(resource):
			desired[resource.get_instance_id()] = resource
	for id in _watched_shadow_settings.keys():
		if desired.has(id):
			continue
		var old_reference: WeakRef = _watched_shadow_settings[id]
		var old_resource: FengCloudShadowSettings = old_reference.get_ref() if old_reference != null else null
		if old_resource != null and is_instance_valid(old_resource) and old_resource.changed.is_connected(_on_shadow_settings_changed):
			old_resource.changed.disconnect(_on_shadow_settings_changed)
		_watched_shadow_settings.erase(id)
	for id in desired:
		var resource: FengCloudShadowSettings = desired[id]
		if not _watched_shadow_settings.has(id):
			if not resource.changed.is_connected(_on_shadow_settings_changed):
				resource.changed.connect(_on_shadow_settings_changed)
			_watched_shadow_settings[id] = weakref(resource)


func _clear_shadow_settings_connections() -> void:
	for reference_value in _watched_shadow_settings.values():
		var reference: WeakRef = reference_value
		var resource: FengCloudShadowSettings = reference.get_ref() if reference != null else null
		if resource != null and is_instance_valid(resource) and resource.changed.is_connected(_on_shadow_settings_changed):
			resource.changed.disconnect(_on_shadow_settings_changed)
	_watched_shadow_settings.clear()


func _on_shadow_settings_changed() -> void:
	_refresh_runtime_registration()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if enabled and cloud_material != null and is_instance_valid(cloud_material) \
			and not cloud_material.has_density_source():
		warnings.append("The assigned FengCloudMaterial has neither a texture or custom scattering-density source nor emissive radiance; this component publishes no cloud work.")
	if layer_height_km <= 0.0:
		warnings.append("Cloud layer height must be greater than zero.")
	return warnings


static func _finite(value: float, fallback: float) -> float:
	return value if is_finite(value) else fallback


static func _vector3(value: Variant, fallback: Vector3) -> Vector3:
	return value if value is Vector3 and value.is_finite() else fallback


static func _finite_range(value: float, fallback: float, minimum: float, maximum: float) -> float:
	return clampf(_finite(value, fallback), minimum, maximum)


static func _finite_color(value: Color, fallback: Color) -> Color:
	if not is_finite(value.r) or not is_finite(value.g) or not is_finite(value.b):
		return fallback
	return Color(value.r, value.g, value.b, 1.0)
