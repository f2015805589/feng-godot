@tool
class_name FengSkyAtmosphere
extends WorldEnvironment
## World-scoped spherical Earth-like single-scattering sky provider.

const FengSkyOpticalLut = preload("res://addons/feng-sky/feng_sky_optical_lut.gd")
const FengSkyRuntime = preload("res://addons/feng-sky/feng_sky_runtime.gd")
const NON_PHYSICAL_SUN_IRRADIANCE := PI
const MAX_SOLAR_IRRADIANCE := 10000000.0
const MAX_SKY_RADIANCE := 60000.0
const AMBIENT_ZENITH_STEP_DEG := 2.0

@export_storage var _owned_environment: Environment
var _owned_sky: Sky
var _atmosphere_sky: Sky
@export_storage var _custom_sky: Sky
@export_storage var _saved_non_atmosphere_background_intensity: float = 30000.0
@export_storage var _atmosphere_background_intensity_override := false
var _atmosphere_enabled := true
var _initializing := true
var _bound_world_id := 0
var _auto_sun: DirectionalLight3D
var _next_auto_sun_scan_msec := 0
var _ambient_cache: Dictionary = {}
var _ambient_cache_miss_count := 0
var _ambient_cache_evaluation_count := 0
var _ambient_last_compute_usec := 0
var _ambient_total_compute_usec := 0
var _last_atmosphere_signature: Dictionary = {}
var _last_material_signature: Array = []
var _last_material_settings_signature: Array = []
var _last_snapshot_signature: Array = []
var _settings_dirty := true
var _settings_revision := 0
var _settings_sanitize_count := 0
var _checked_shader: Shader
var _reference_shader: Shader
var _shader_identity_dirty := true
var _shader_identity_matches := false
var _shader_identity_check_count := 0
var _optical_lut: ImageTexture
var _optical_lut_signature: Array = []
var _optical_lut_build_count := 0
var _snapshot_publish_count := 0
var _material_update_count := 0

@export_group("Sky")
## New nodes use the integrated Earth-like model. Assigning a non-atmosphere Sky
## switches this off; older scenes containing another Sky keep that Sky intact.
@export var atmosphere_enabled: bool:
	get:
		return _atmosphere_enabled
	set(value):
		if value and not _atmosphere_enabled:
			_remember_current_background_intensity()
		_atmosphere_enabled = value
		if not _initializing:
			_apply_selected_sky()
			_refresh_world_binding()

## A replaceable, privately copied Sky. An assigned non-atmosphere resource is
## retained as the custom mode and is never rewritten by atmospheric settings.
@export var sky: Sky:
	get:
		return environment.sky if environment != null else null
	set(value):
		if environment == null:
			_ensure_private_environment()
		if _is_atmosphere_sky(value):
			if not _atmosphere_enabled:
				_remember_current_background_intensity()
			_atmosphere_sky = _make_local_sky(value)
			_atmosphere_enabled = true
		else:
			_custom_sky = _make_local_sky(value)
			_atmosphere_enabled = false
		_apply_selected_sky()
		_refresh_world_binding()

## Optional explicit sun. If empty, the first visible Sky-compatible directional
## light in this World3D is selected (Light Only lights are skipped).
@export var sun_light: DirectionalLight3D
## Publish atmosphere-derived ambient radiance to Feng Fog for this World3D.
@export var affect_height_fog: bool = true
@export_range(0.0, 8.0, 0.01, "or_greater") var height_fog_contribution: float = 1.0

@export_group("Earth Atmosphere")
## All lengths and coefficients are in km and km^-1. `planet_center_m` is in
## Godot world metres; its default puts world origin at sea level.
@export_range(6000.0, 7000.0, 1.0, "suffix:km") var planet_radius_km: float = 6360.0:
	set(value):
		planet_radius_km = value
		_settings_dirty = true
@export_range(1.0, 120.0, 1.0, "suffix:km") var atmosphere_height_km: float = 60.0:
	set(value):
		atmosphere_height_km = value
		_settings_dirty = true
@export_range(1.0, 30.0, 0.1, "suffix:km") var rayleigh_scale_height_km: float = 8.0:
	set(value):
		rayleigh_scale_height_km = value
		_settings_dirty = true
@export_range(0.1, 10.0, 0.1, "suffix:km") var mie_scale_height_km: float = 1.2:
	set(value):
		mie_scale_height_km = value
		_settings_dirty = true
@export var rayleigh_scattering_per_km: Vector3 = Vector3(0.005802, 0.013558, 0.0331):
	set(value):
		rayleigh_scattering_per_km = value
		_settings_dirty = true
@export_range(0.0, 1.0, 0.00001, "suffix:km^-1") var mie_scattering_per_km: float = 0.003996:
	set(value):
		mie_scattering_per_km = value
		_settings_dirty = true
@export_range(0.0, 1.0, 0.00001, "suffix:km^-1") var mie_extinction_per_km: float = 0.00444:
	set(value):
		mie_extinction_per_km = value
		_settings_dirty = true
@export_range(-0.95, 0.95, 0.01) var mie_asymmetry: float = 0.8:
	set(value):
		mie_asymmetry = value
		_settings_dirty = true
@export var planet_center_m: Vector3 = Vector3(0.0, -6360000.0, 0.0):
	set(value):
		planet_center_m = value
		_settings_dirty = true
@export var ground_albedo: Vector3 = Vector3(0.1, 0.1, 0.1):
	set(value):
		ground_albedo = value
		_settings_dirty = true
@export_range(0.01, 2.0, 0.001, "suffix:deg") var sun_angular_radius_deg: float = 0.2666:
	set(value):
		sun_angular_radius_deg = value
		_settings_dirty = true


func _init() -> void:
	var default_environment := Environment.new()
	default_environment.resource_local_to_scene = true
	_owned_environment = default_environment
	environment = default_environment
	_atmosphere_sky = _make_atmosphere_sky()
	_owned_sky = _atmosphere_sky
	environment.sky = _owned_sky
	environment.background_mode = Environment.BG_SKY
	_update_background_intensity_mode()
	_initializing = false


func _enter_tree() -> void:
	_sync_environment()
	set_process(true)


func _ready() -> void:
	_sync_environment()
	_refresh_world_binding()


func _exit_tree() -> void:
	FengSkyRuntime.remove_snapshot(self, _bound_world_id)
	_bound_world_id = 0
	_last_snapshot_signature.clear()
	set_process(false)


func _process(_delta: float) -> void:
	# The inherited environment has no setter hook. Keep the editor workflow
	# compatible with direct Inspector edits while runtime values are polled only
	# to detect changes; the CPU atmosphere integration itself is cached.
	if Engine.is_editor_hint() and (
		environment != _owned_environment
		or (
			environment != null
			and (environment.sky != _owned_sky or environment.background_mode != Environment.BG_SKY)
		)
	):
		_sync_environment()
	_update_background_intensity_mode()
	_refresh_atmosphere_cache()
	_refresh_world_binding()


func _sync_environment() -> void:
	_ensure_private_environment()
	_enforce_sky_background()
	_apply_selected_sky()


func _ensure_private_environment() -> void:
	if environment == null:
		var created := Environment.new()
		created.resource_local_to_scene = true
		_owned_environment = created
		_owned_sky = null
		environment = created
		_apply_selected_sky()
		return

	if environment == _owned_environment:
		if environment.sky != _owned_sky:
			if not _atmosphere_background_intensity_override:
				_remember_current_background_intensity()
			_adopt_sky(environment.sky)
		return

	var source := environment
	_saved_non_atmosphere_background_intensity = source.background_intensity
	var local_environment := source.duplicate(true) as Environment
	if local_environment == null:
		push_error("FengSkyAtmosphere could not duplicate its Environment resource.")
		local_environment = Environment.new()
	local_environment.resource_local_to_scene = true
	if source.sky != null:
		_adopt_sky(source.sky)
	_owned_environment = local_environment
	environment = local_environment
	_apply_selected_sky()


func _adopt_sky(source: Sky) -> void:
	if _is_atmosphere_sky(source):
		_atmosphere_sky = _make_local_sky(source)
		_atmosphere_enabled = true
	else:
		_custom_sky = _make_local_sky(source)
		_atmosphere_enabled = false


func _apply_selected_sky() -> void:
	if environment == null:
		return
	if _atmosphere_enabled:
		if _atmosphere_sky == null:
			_atmosphere_sky = _make_atmosphere_sky()
		_owned_sky = _atmosphere_sky
	else:
		if _custom_sky == null:
			_custom_sky = _make_legacy_default_sky()
		_owned_sky = _custom_sky
	environment.sky = _owned_sky
	_enforce_sky_background()
	_update_background_intensity_mode()


func _update_background_intensity_mode() -> void:
	if environment == null:
		return
	if _has_selected_atmosphere_sky():
		if not _atmosphere_background_intensity_override:
			_remember_current_background_intensity()
			_atmosphere_background_intensity_override = true
		if not is_equal_approx(environment.background_intensity, 1.0):
			environment.background_intensity = 1.0
	elif _atmosphere_background_intensity_override:
		environment.background_intensity = _saved_non_atmosphere_background_intensity
		_atmosphere_background_intensity_override = false
	else:
		_remember_current_background_intensity()


func _remember_current_background_intensity() -> void:
	if environment != null and is_finite(environment.background_intensity):
		_saved_non_atmosphere_background_intensity = environment.background_intensity


func _enforce_sky_background() -> void:
	if environment != null and environment.background_mode != Environment.BG_SKY:
		environment.background_mode = Environment.BG_SKY


func _make_atmosphere_sky() -> Sky:
	var result := Sky.new()
	result.resource_local_to_scene = true
	result.process_mode = Sky.PROCESS_MODE_REALTIME
	var material := ShaderMaterial.new()
	material.resource_local_to_scene = true
	var shared_shader := FengSkyRuntime.atmosphere_shader()
	if shared_shader != null:
		var local_shader := shared_shader.duplicate(true) as Shader
		local_shader.resource_local_to_scene = true
		material.shader = local_shader
	else:
		push_error("FengSkyAtmosphere could not load its atmosphere shader.")
	result.sky_material = material
	return result


func _make_legacy_default_sky() -> Sky:
	var result := Sky.new()
	result.resource_local_to_scene = true
	var material := PhysicalSkyMaterial.new()
	material.resource_local_to_scene = true
	result.sky_material = material
	return result


func _make_local_sky(source: Sky) -> Sky:
	if source == null:
		return null

	var local_sky := source.duplicate(true) as Sky
	if local_sky == null:
		push_error("FengSkyAtmosphere could not duplicate its Sky resource.")
		return null
	local_sky.resource_local_to_scene = true

	var source_material := source.sky_material
	if source_material != null:
		var local_material := local_sky.sky_material
		if local_material == source_material:
			local_material = source_material.duplicate(true) as Material
			local_sky.sky_material = local_material
		if local_material == null:
			push_error("FengSkyAtmosphere could not duplicate its Sky material.")
			return local_sky
		local_material.resource_local_to_scene = true
		if local_material is ShaderMaterial and local_material.shader != null:
			var local_shader := local_material.shader.duplicate(true) as Shader
			if local_shader == null:
				push_error("FengSkyAtmosphere could not duplicate its Sky shader.")
				local_material.shader = null
			else:
				local_shader.resource_local_to_scene = true
				local_material.shader = local_shader

	return local_sky


func _is_atmosphere_sky(candidate: Sky) -> bool:
	if candidate == null or not candidate.sky_material is ShaderMaterial:
		return false
	var material := candidate.sky_material as ShaderMaterial
	var shader := material.shader
	if shader != _checked_shader:
		if _checked_shader != null:
			_checked_shader.changed.disconnect(_invalidate_shader_identity)
		_checked_shader = shader
		if _checked_shader != null:
			_checked_shader.changed.connect(_invalidate_shader_identity)
		_invalidate_shader_identity()
	if _shader_identity_dirty:
		if _reference_shader == null:
			_reference_shader = FengSkyRuntime.atmosphere_shader()
			if _reference_shader != null:
				_reference_shader.changed.connect(_invalidate_reference_shader_identity)
		_shader_identity_matches = shader != null and _reference_shader != null and shader.code == _reference_shader.code
		_shader_identity_dirty = false
		_shader_identity_check_count += 1
	return _shader_identity_matches


func _invalidate_reference_shader_identity() -> void:
	# The editor may hot-reload the original asset while private scene copies
	# stay alive. Its source is part of identity, just like the selected shader.
	_invalidate_shader_identity()


func _invalidate_shader_identity() -> void:
	_shader_identity_dirty = true
	_last_material_signature.clear()
	_last_material_settings_signature.clear()
	_last_snapshot_signature.clear()


func _has_selected_atmosphere_sky() -> bool:
	return (
		_atmosphere_enabled
		and environment != null
		and _owned_sky != null
		and environment.sky == _owned_sky
		and _is_atmosphere_sky(environment.sky)
	)


func _current_world() -> World3D:
	var viewport := get_viewport()
	return viewport.find_world_3d() if viewport != null else null


func _refresh_world_binding() -> void:
	var world := _current_world()
	var active := world != null and environment != null and world.get_environment() == environment
	if not active or not _has_selected_atmosphere_sky():
		_last_material_signature.clear()
		_last_snapshot_signature.clear()
		FengSkyRuntime.remove_snapshot(self, _bound_world_id)
		_bound_world_id = 0
		return

	var world_id := world.get_instance_id()
	if _bound_world_id != world_id:
		_last_snapshot_signature.clear()
		FengSkyRuntime.remove_snapshot(self, _bound_world_id)
		_bound_world_id = world_id

	var selected_sun := _resolve_sun(world)
	var sun_direction := Vector3.UP
	var sun_color := Vector3.ZERO
	var sun_irradiance := 0.0
	var sun_light_id := 0
	if selected_sun != null:
		sun_direction = FengSkyRuntime.sanitize_sun_direction(selected_sun.global_transform.basis.z)
		sun_color = _sun_linear_color(selected_sun)
		sun_irradiance = _sun_irradiance(selected_sun)
		sun_light_id = selected_sun.get_instance_id()

	_update_sky_shader(sun_direction, sun_color, sun_irradiance)
	if not affect_height_fog:
		_last_snapshot_signature.clear()
		FengSkyRuntime.remove_snapshot(self, _bound_world_id)
		_bound_world_id = 0
		return
	var sky_gain := _background_energy_gain()
	var physical_units := _uses_physical_light_units()
	var snapshot_signature: Array = [world_id, sun_light_id, sun_direction, sun_color,
		sun_irradiance, sky_gain, height_fog_contribution, physical_units, _settings_revision]
	if snapshot_signature == _last_snapshot_signature:
		return
	var ambient := Vector3.ZERO
	var ground_illuminance := Vector3.ZERO
	if selected_sun != null and sun_irradiance > 0.0 and sun_color.max(Vector3.ZERO).length_squared() > 0.0:
		var cache := _ambient_entry_for_sun(sun_direction)
		ambient = (cache["ambient_unit_sun"] as Vector3) * sun_irradiance * sun_color.max(Vector3.ZERO) * sky_gain
		ambient = ambient.min(Vector3.ONE * MAX_SKY_RADIANCE)
		ground_illuminance = (cache["ground_transmittance"] as Vector3) * sun_irradiance * sun_color.max(Vector3.ZERO)
	FengSkyRuntime.publish_snapshot(self, world_id, {
		"world_id": world_id,
		"provider_id": get_instance_id(),
		"sun_light_id": sun_light_id,
		"sun_direction": sun_direction,
		"sun_ground_illuminance": _finite_nonnegative(ground_illuminance),
		"sun_irradiance_unit": "lux" if physical_units else "frp_normalized",
		"ambient_radiance": _finite_nonnegative(ambient),
		"height_fog_contribution": maxf(height_fog_contribution, 0.0),
	})
	_last_snapshot_signature = snapshot_signature
	_snapshot_publish_count += 1


func _feng_sky_runtime_is_active(world_id: int) -> bool:
	if (
		not is_inside_tree()
		or not _has_selected_atmosphere_sky()
		or not affect_height_fog
	):
		_last_snapshot_signature.clear()
		return false
	var world := _current_world()
	var active := world != null and world.get_instance_id() == world_id and world.get_environment() == environment
	if not active:
		_last_snapshot_signature.clear()
	return active


func _resolve_sun(world: World3D) -> DirectionalLight3D:
	if sun_light != null:
		return sun_light if _sun_is_compatible(sun_light, world) else null
	var now := Time.get_ticks_msec()
	if _sun_is_compatible(_auto_sun, world) and now < _next_auto_sun_scan_msec:
		return _auto_sun
	if now < _next_auto_sun_scan_msec:
		return null
	_next_auto_sun_scan_msec = now + 500
	_auto_sun = null
	var tree := get_tree()
	if tree == null:
		return null
	for node in tree.root.find_children("*", "DirectionalLight3D", true, false):
		if node is DirectionalLight3D and _sun_is_compatible(node, world):
			_auto_sun = node
			break
	return _auto_sun


func _sun_is_compatible(candidate: DirectionalLight3D, world: World3D) -> bool:
	return (
		candidate != null
		and is_instance_valid(candidate)
		and candidate.is_inside_tree()
		and candidate.is_visible_in_tree()
		and candidate.get_world_3d() == world
		and candidate.sky_mode != DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	)


func _sun_linear_color(light: DirectionalLight3D) -> Vector3:
	var color := light.light_color.srgb_to_linear()
	if _uses_physical_light_units():
		color *= light.get_correlated_color().srgb_to_linear()
	return _finite_nonnegative(Vector3(color.r, color.g, color.b))


func _sun_irradiance(light: DirectionalLight3D) -> float:
	if light.light_negative or not is_finite(light.light_energy):
		return 0.0
	var renderer_irradiance := NON_PHYSICAL_SUN_IRRADIANCE
	if _uses_physical_light_units():
		if not is_finite(light.light_intensity_lux):
			return 0.0
		renderer_irradiance = maxf(light.light_intensity_lux, 0.0)
	# Keep the addon in the same normalized scale as FRP surface direct lighting
	# when physical units are off; the 10 MLux-equivalent ceiling bounds HDR work.
	return minf(renderer_irradiance * maxf(light.light_energy, 0.0), MAX_SOLAR_IRRADIANCE)


func _uses_physical_light_units() -> bool:
	return ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)


func _refresh_atmosphere_cache() -> void:
	if not _settings_dirty:
		return
	_settings_dirty = false
	_settings_sanitize_count += 1
	var signature := _sanitize_current_settings()
	if signature != _last_atmosphere_signature:
		_ambient_cache.clear()
		_last_atmosphere_signature = signature
		_settings_revision += 1


func _atmosphere_settings() -> Dictionary:
	_refresh_atmosphere_cache()
	return _last_atmosphere_signature


func _sanitize_current_settings() -> Dictionary:
	return FengSkyRuntime.sanitize_atmosphere_settings({
		"planet_radius_km": planet_radius_km,
		"atmosphere_height_km": atmosphere_height_km,
		"rayleigh_scale_height_km": rayleigh_scale_height_km,
		"mie_scale_height_km": mie_scale_height_km,
		"rayleigh_scattering_per_km": rayleigh_scattering_per_km,
		"mie_scattering_per_km": mie_scattering_per_km,
		"mie_extinction_per_km": mie_extinction_per_km,
		"mie_asymmetry": mie_asymmetry,
		"planet_center_m": planet_center_m,
		"ground_albedo": ground_albedo,
		"sun_angular_radius_deg": sun_angular_radius_deg,
	})


func _ambient_entry_for_sun(sun_direction: Vector3) -> Dictionary:
	var up := _surface_up()
	var normalized_sun := sun_direction.normalized()
	var sun_elevation_cosine := up.dot(normalized_sun)
	var zenith_deg := rad_to_deg(acos(clampf(sun_elevation_cosine, -1.0, 1.0)))
	var position := clampf(zenith_deg / AMBIENT_ZENITH_STEP_DEG, 0.0, 180.0 / AMBIENT_ZENITH_STEP_DEG)
	var lower_bin := floori(position)
	var upper_bin := mini(lower_bin + 1, int(180.0 / AMBIENT_ZENITH_STEP_DEG))
	var blend := position - float(lower_bin)
	var lower := _ambient_cache_bin(lower_bin, up)
	var result := lower
	if upper_bin != lower_bin:
		var upper := _ambient_cache_bin(upper_bin, up)
		result = {
			"ambient_unit_sun": (lower["ambient_unit_sun"] as Vector3).lerp(upper["ambient_unit_sun"], blend),
			"ground_transmittance": (lower["ground_transmittance"] as Vector3).lerp(upper["ground_transmittance"], blend),
		}
	if sun_elevation_cosine <= 0.0:
		result = result.duplicate()
		result["ground_transmittance"] = Vector3.ZERO
	return result


func _ambient_cache_bin(zenith_bin: int, up: Vector3) -> Dictionary:
	if _ambient_cache.has(zenith_bin):
		return _ambient_cache[zenith_bin]
	var zenith_rad := deg_to_rad(float(zenith_bin) * AMBIENT_ZENITH_STEP_DEG)
	var east := Vector3.RIGHT - up * up.dot(Vector3.RIGHT)
	if east.length_squared() < 0.001:
		east = Vector3.FORWARD - up * up.dot(Vector3.FORWARD)
	east = east.normalized()
	var representative_sun := (up * cos(zenith_rad) + east * sin(zenith_rad)).normalized()
	var compute_start_usec := Time.get_ticks_usec()
	var computed := FengSkyRuntime.compute_atmosphere_sample(_atmosphere_settings(), representative_sun, 1.0, Vector3.ONE)
	_ambient_last_compute_usec = Time.get_ticks_usec() - compute_start_usec
	_ambient_total_compute_usec += _ambient_last_compute_usec
	_ambient_cache_miss_count += 1
	_ambient_cache_evaluation_count += int(computed.get("ambient_sample_count", 0))
	var entry := {
		"ambient_unit_sun": computed["ambient_unit_sun"],
		"ground_transmittance": computed["ground_transmittance"],
	}
	_ambient_cache[zenith_bin] = entry
	return entry


func atmosphere_cache_stats() -> Dictionary:
	## Read-only counters for profiling cache misses without exposing mutable LUT data.
	return {
		"cached_sun_zenith_bins": _ambient_cache.size(),
		"cache_misses": _ambient_cache_miss_count,
		"evaluated_sky_directions": _ambient_cache_evaluation_count,
		"last_miss_usec": _ambient_last_compute_usec,
		"total_miss_usec": _ambient_total_compute_usec,
		"rays_per_miss": FengSkyRuntime.AMBIENT_SAMPLE_COUNT,
		"settings_sanitizations": _settings_sanitize_count,
		"shader_identity_checks": _shader_identity_check_count,
		"optical_lut_updates": _optical_lut_build_count,
		"snapshot_publications": _snapshot_publish_count,
		"material_updates": _material_update_count,
	}


func _surface_up() -> Vector3:
	var center: Vector3 = _atmosphere_settings()["planet_center_m"]
	var surface_origin := -center / 1000.0
	return surface_origin.normalized() if surface_origin.length_squared() > 0.001 else Vector3.UP


func _update_sky_shader(sun_direction: Vector3, sun_color: Vector3, sun_irradiance: float) -> void:
	if not _has_selected_atmosphere_sky():
		return
	var material := environment.sky.sky_material as ShaderMaterial
	var settings := _atmosphere_settings()
	var settings_signature: Array = [material.get_instance_id(), material.shader.get_instance_id(), _settings_revision]
	if settings_signature != _last_material_settings_signature:
		var lut_signature := FengSkyOpticalLut.geometry_signature(settings)
		var use_lut := FengSkyOpticalLut.supports_settings(settings)
		if use_lut and (_optical_lut == null or lut_signature != _optical_lut_signature):
			# A fresh private image/texture cannot be edited through another world.
			_optical_lut = ImageTexture.create_from_image(FengSkyOpticalLut.make_image(settings))
			_optical_lut.resource_local_to_scene = true
			_optical_lut_signature = lut_signature
			_optical_lut_build_count += 1
		for setting_name in settings:
			material.set_shader_parameter(setting_name, settings[setting_name])
		material.set_shader_parameter("optical_column_lut", _optical_lut)
		material.set_shader_parameter("use_optical_column_lut", use_lut)
		_last_material_settings_signature = settings_signature
	var sky_gain := _background_energy_gain()
	var material_signature: Array = [material.get_instance_id(), material.shader.get_instance_id(),
		_settings_revision, sun_direction, sun_color, sun_irradiance, sky_gain]
	if material_signature == _last_material_signature:
		return
	var sky_radiance_limit := 0.0
	if sky_gain > 0.0:
		sky_radiance_limit = MAX_SKY_RADIANCE / maxf(sky_gain, 0.000001)
	material.set_shader_parameter("sun_direction", FengSkyRuntime.sanitize_sun_direction(sun_direction))
	material.set_shader_parameter("sun_color_linear", sun_color.max(Vector3.ZERO))
	material.set_shader_parameter("sun_irradiance", minf(maxf(sun_irradiance, 0.0), MAX_SOLAR_IRRADIANCE))
	material.set_shader_parameter("sky_radiance_limit", sky_radiance_limit)
	_last_material_signature = material_signature
	_material_update_count += 1


func _finite_nonnegative(value: Vector3) -> Vector3:
	if not is_finite(value.x) or not is_finite(value.y) or not is_finite(value.z):
		return Vector3.ZERO
	return value.max(Vector3.ZERO)


func _background_energy_gain() -> float:
	if environment == null or not is_finite(environment.background_energy_multiplier):
		return 0.0
	return maxf(environment.background_energy_multiplier, 0.0)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if environment == null:
		warnings.append("FengSkyAtmosphere needs an Environment resource.")
	elif environment.sky == null:
		warnings.append("No Sky is assigned; the world background will use the Environment fallback color.")
	if not is_inside_tree():
		return warnings
	var world := _current_world()
	if world != null and environment != null and world.get_environment() != environment:
		warnings.append("Another WorldEnvironment is first in this World3D, so FengSkyAtmosphere does not affect it.")
	return warnings
