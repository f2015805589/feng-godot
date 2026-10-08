@tool
class_name FMagicGILighting
extends RefCounted
## Projects dynamic distant sources into world-space SH. Primary SkyLight
## radiance is published separately from the combined secondary lighting.

const Data = preload("feng_magic_gi_data.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const SKY_LIGHT_RUNTIME_PATH := "res://addons/feng-sky/feng_sky_light_runtime.gd"
const SCENE_SCAN_MSEC := 500

var _lights: Array[DirectionalLight3D] = []
var _world: World3D
var _next_scan := 0
var _lighting_signature := 0
var _sky_sh := PackedFloat32Array()
var _cached_result := PackedFloat32Array()
var _sky_light_runtime: Script


func _init() -> void:
	if ResourceLoader.exists(SKY_LIGHT_RUNTIME_PATH):
		_sky_light_runtime = load(SKY_LIGHT_RUNTIME_PATH) as Script

func coefficients(volume: Node3D) -> PackedFloat32Array:
	return coefficient_sets(volume).get("lighting", PackedFloat32Array())

## Returns secondary lighting (SkyLight + DirectionalLight) and the SkyLight-only
## source SH used by v4 primary transport. Both are cached from one world snapshot.
func coefficient_sets(volume: Node3D) -> Dictionary:
	if volume == null or not is_instance_valid(volume):
		return {"lighting": _zero_sh(), "sky_lighting": _zero_sh()}
	var world := volume.get_world_3d()
	var now := Time.get_ticks_msec()
	if world != _world or now >= _next_scan:
		_scan_scene(volume)
		_next_scan = now + SCENE_SCAN_MSEC

	var lights: Array[DirectionalLight3D] = []
	var explicit_light: Variant = volume.get("sun")
	if explicit_light is DirectionalLight3D and explicit_light.get_world_3d() == world:
		lights.append(explicit_light)
	else:
		lights = _lights
	var physical_units := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	var current_lighting_signature := hash([_source_fingerprint(lights, world), physical_units])
	var sky_only := _read_sky_light(world)
	if current_lighting_signature == _lighting_signature and sky_only == _sky_sh and not _cached_result.is_empty():
		return {"lighting": _cached_result, "sky_lighting": _sky_sh}
	_lighting_signature = current_lighting_signature
	_sky_sh = sky_only

	var result := PackedFloat32Array()
	result.resize(27)
	for light in lights:
		if not is_instance_valid(light) or not light.is_inside_tree() or not light.is_visible_in_tree() \
				or light.get_world_3d() != world:
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
	for i in 27:
		result[i] += sky_only[i]
	_cached_result = result
	return {"lighting": _cached_result, "sky_lighting": _sky_sh}

func _read_sky_light(world: World3D) -> PackedFloat32Array:
	if _sky_light_runtime != null and world != null:
		var snapshot: Variant = _sky_light_runtime.call("snapshot_for_world", world.get_instance_id())
		if snapshot is Dictionary and bool(snapshot.get("ready", false)):
			var coefficients: Variant = snapshot.get("radiance_sh")
			if coefficients is PackedFloat32Array and coefficients.size() == 27:
				return coefficients
	return _zero_sh()

func _scan_scene(volume: Node3D) -> void:
	_lights.clear()
	_world = volume.get_world_3d()
	_scan(SceneTracker.scene_root(volume), _world)

func _scan(node: Node, world: World3D) -> void:
	if node is Viewport and node.find_world_3d() != world:
		return
	if node is Node3D and node.get_world_3d() != world:
		return
	if node is DirectionalLight3D:
		_lights.append(node)
	for child in node.get_children():
		_scan(child, world)

static func _source_fingerprint(lights: Array[DirectionalLight3D], world: World3D) -> int:
	var values: Array = []
	for light in lights:
		if not is_instance_valid(light) or not light.is_inside_tree() or light.get_world_3d() != world:
			continue
		values.append([light.global_transform, light.light_color, light.get_correlated_color(), light.light_energy,
				light.light_indirect_energy, light.get("light_intensity_lux"), light.light_negative,
				light.is_visible_in_tree()])
	return hash(values)

static func _zero_sh() -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(27)
	return values

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
