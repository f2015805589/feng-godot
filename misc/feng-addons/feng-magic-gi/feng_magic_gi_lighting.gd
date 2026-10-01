@tool
class_name FMagicGILighting
extends RefCounted
## Projects dynamic distant sources into world-space SH. Geometry transport
## remains immutable; camera-specific exposure is outside this world snapshot.

const Data = preload("feng_magic_gi_data.gd")
const SKY_PANORAMA_SIZE := Vector2i(64, 32)
const SKY_REFRESH_MSEC := 250
const SCENE_SCAN_MSEC := 500

var _lights: Array[DirectionalLight3D] = []
var _world: World3D
var _next_scan := 0
var _next_sky_update := 0
var _environment_signature := 0
var _source_signature := 0
var _lighting_signature := 0
var _sky_sh := PackedFloat32Array()
var _sky_dirty := true
var _environment: Environment
var _sky: Sky
var _sky_material: Material
var _cached_result := PackedFloat32Array()
var _result_dirty := true

func coefficients(volume: Node3D) -> PackedFloat32Array:
	var now := Time.get_ticks_msec()
	if now >= _next_scan:
		_scan_scene(volume)
		_scan_environment(_resolve_environment(volume))
		_next_scan = now + SCENE_SCAN_MSEC

	var environment := _resolve_environment(volume)
	_track_environment(environment)
	var lights: Array[DirectionalLight3D] = []
	var explicit_light = volume.get("sun")
	if explicit_light is DirectionalLight3D and explicit_light.get_world_3d() == volume.get_world_3d():
		lights.append(explicit_light)
	else:
		lights = _lights
	var sky_sources := _lights.duplicate()
	if explicit_light is DirectionalLight3D and not sky_sources.has(explicit_light):
		sky_sources.append(explicit_light)
	var physical_units := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	var current_source_signature := hash([_source_fingerprint(sky_sources, _world), physical_units])
	if current_source_signature != _source_signature:
		_source_signature = current_source_signature
		_sky_dirty = true
		_result_dirty = true
	# The panorama sees all scene lights, while an explicit sun selects only one
	# direct SH source. Track that selection separately: switching between already
	# scanned lights leaves the panorama fingerprint unchanged.
	var current_lighting_signature := hash([_source_fingerprint(lights, volume.get_world_3d()), physical_units])
	if current_lighting_signature != _lighting_signature:
		_lighting_signature = current_lighting_signature
		_result_dirty = true
	if environment != null and _update_sky(environment, now):
		_result_dirty = true
	if not _result_dirty:
		return _cached_result
	_result_dirty = false
	var result := PackedFloat32Array()
	result.resize(27)
	for light in lights:
		if not is_instance_valid(light) or not light.is_inside_tree() or not light.is_visible_in_tree() \
				or light.get_world_3d() != volume.get_world_3d():
			continue
		# Godot's renderer uses local +Z as the source direction, which is also
		# the receiver-to-source direction expected by the transport SH.
		var source_direction := light.global_basis.z.normalized()
		var color: Color = light.light_color.srgb_to_linear()
		var energy := light.light_energy * light.light_indirect_energy
		if physical_units:
			energy *= float(light.get("light_intensity_lux"))
			color *= light.get_correlated_color().srgb_to_linear()
		else:
			energy *= PI # Matches light_storage.cpp's non-physical DirectionalLightData scale.
		if light.light_negative:
			energy *= -1.0
		var basis := Data.sh_basis(source_direction)
		for k in 9:
			result[k * 3] += color.r * energy * basis[k]
			result[k * 3 + 1] += color.g * energy * basis[k]
			result[k * 3 + 2] += color.b * energy * basis[k]

	if _sky_sh.size() == 27:
		for i in 27:
			result[i] += _sky_sh[i]
	_cached_result = result
	return _cached_result

func _resolve_environment(volume: Node3D) -> Environment:
	var explicit: Environment = volume.get("lighting_environment")
	if explicit != null:
		return explicit
	var world := volume.get_world_3d()
	if world != null:
		if world.environment != null:
			return world.environment
		return world.get_fallback_environment()
	return null

func _scan_scene(volume: Node3D) -> void:
	_lights.clear()
	_world = volume.get_world_3d()
	var root: Node = volume
	while root.get_parent() != null and not root.get_parent() is Viewport:
		root = root.get_parent()
	_scan(root, _world)

func _scan(node: Node, world: World3D) -> void:
	if node is Viewport and node.find_world_3d() != world:
		return
	if node is Node3D and node.get_world_3d() != world:
		return
	if node is DirectionalLight3D:
		_lights.append(node)
	for child in node.get_children():
		_scan(child, world)

## Cheap per-frame check: only object identities are compared and the `changed`
## signal wiring is maintained. The deep property scan lives in
## _scan_environment and runs at the scene-scan cadence instead.
func _track_environment(environment: Environment) -> void:
	var sky: Sky = environment.sky if environment != null else null
	var material: Material = sky.sky_material if sky != null else null
	if environment == _environment and sky == _sky and material == _sky_material:
		return
	for resource in [_environment, _sky, _sky_material]:
		if resource != null and resource.changed.is_connected(_on_sky_changed):
			resource.changed.disconnect(_on_sky_changed)
	_environment = environment
	_sky = sky
	_sky_material = material
	for resource in [_environment, _sky, _sky_material]:
		if resource != null and not resource.changed.is_connected(_on_sky_changed):
			resource.changed.connect(_on_sky_changed)
	_sky_sh.clear()
	_sky_dirty = true
	_result_dirty = true

## Deep environment signature; expensive material property reflection runs at
## SCENE_SCAN_MSEC cadence rather than every frame.
func _scan_environment(environment: Environment) -> void:
	var sky: Sky = environment.sky if environment != null else null
	var material: Material = sky.sky_material if sky != null else null
	var material_state: Array = []
	if material != null:
		for property in material.get_property_list():
			if int(property.usage) & PROPERTY_USAGE_STORAGE:
				if property.name in ["resource_name", "resource_path", "resource_local_to_scene"]:
					continue
			material_state.append([property.name, material.get(property.name)])
	var signature := hash([
		environment.get_instance_id() if environment != null else 0,
		environment.ambient_light_source if environment != null else -1,
		environment.background_mode if environment != null else -1,
		environment.ambient_light_color if environment != null else Color.BLACK,
		environment.ambient_light_energy if environment != null else 0.0,
		environment.ambient_light_sky_contribution if environment != null else 0.0,
		environment.background_color if environment != null else Color.BLACK,
		environment.background_energy_multiplier if environment != null else 0.0,
		environment.sky_rotation if environment != null else Vector3.ZERO,
		sky.get_instance_id() if sky != null else 0,
		material.get_instance_id() if material != null else 0,
		material_state,
	])
	if signature != _environment_signature:
		_environment_signature = signature
		_sky_dirty = true
		_result_dirty = true

## Returns true when the sky SH changed, so callers can invalidate cached
## coefficient results.
func _update_sky(environment: Environment, now: int) -> bool:
	if not _sky_dirty or now < _next_sky_update:
		return false
	_next_sky_update = now + SKY_REFRESH_MSEC
	var image := RenderingServer.environment_bake_panorama(
			environment.get_rid(), false, SKY_PANORAMA_SIZE)
	if image == null or image.is_empty():
		_sky_sh.clear()
		_sky_dirty = false
		return true
	_sky_sh = project_panorama(image, Basis.from_euler(environment.sky_rotation))
	_sky_dirty = false
	return true

func _on_sky_changed() -> void:
	_sky_dirty = true

static func _source_fingerprint(lights: Array[DirectionalLight3D], world: World3D) -> int:
	var values: Array = []
	for light in lights:
		if not is_instance_valid(light) or not light.is_inside_tree() or light.get_world_3d() != world:
			continue
		values.append([light.global_transform, light.light_color, light.get_correlated_color(), light.light_energy,
				light.light_indirect_energy, light.get("light_intensity_lux"), light.light_negative,
				light.is_visible_in_tree()])
	return hash(values)

static func project_panorama(image: Image, local_to_world := Basis.IDENTITY) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(27)
	if image == null or image.is_empty():
		return result
	var width := image.get_width()
	var height := image.get_height()
	var total := 0.0
	for y in height:
		var theta := PI * (y + 0.5) / height
		var row_weight := sin(theta) * PI * TAU / (width * height)
		total += row_weight * width
		for x in width:
			var phi := TAU * (x + 0.5) / width
			# Matches Godot SkyRD::Sky::bake_panorama's equirectangular direction.
			var local_direction := Vector3(
					-sin(phi) * sin(theta),
					cos(theta),
					-cos(phi) * sin(theta))
			var world_direction := (local_to_world * local_direction).normalized()
			var basis := Data.sh_basis(world_direction)
			var color := image.get_pixel(x, y)
			for k in 9:
				for channel in 3:
					result[k * 3 + channel] += color[channel] * basis[k] * row_weight
	if total > 0.0:
		var normalization := 4.0 * PI / total
		for i in 27:
			result[i] *= normalization
	return result
