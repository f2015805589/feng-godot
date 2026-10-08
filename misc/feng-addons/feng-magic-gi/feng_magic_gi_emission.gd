@tool
class_name FMagicGIEmission
extends RefCounted
## Resolves baked stable emitter bindings to current StandardMaterial3D values.
## Geometry and texture response stay baked; color, intensity, operator and the
## enabled switch are evaluated live on the main thread.

const Data = preload("feng_magic_gi_data.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const Binding = preload("feng_magic_gi_emitter_binding.gd")

var warning := ""
var identity := ""
var payload := PackedFloat32Array()
var revision := 0
var _source_values := PackedFloat32Array()
var _static_signature_cache: Dictionary = {}
var _data_cache_token := ""
var _current_keys: Dictionary = {}

## Source diagnostics may refresh independently; only publication changes the payload.
func update_snapshot(volume: Node3D, data: Data) -> bool:
	var values := read_source_values(volume, data)
	if identity == _data_cache_token and values == _source_values:
		return false
	payload = data.compose_emission(values)
	identity = _data_cache_token
	_source_values = values
	return true

## Returns six non-negative RGB weights per persisted emitter binding:
## [color term RGB, texture term RGB]. ADD uses [color*energy, energy];
## MULTIPLY uses [0, color*energy].
func read_source_values(volume: Node3D, data: FMagicGIData) -> PackedFloat32Array:
	var data_token := "%d:%d:%d" % [volume.get_instance_id(), data.get_instance_id(), data.bake_version]
	if data_token != _data_cache_token:
		_data_cache_token = data_token
		_static_signature_cache.clear()
	var result := PackedFloat32Array()
	result.resize(data.emitter_count() * 6)
	result.fill(0.0)
	var warnings := PackedStringArray()
	if data.format_version == Data.LEGACY_FORMAT_VERSION:
		if not _current_emitter_keys(volume).is_empty():
			warnings.append("This format-2 bake has no emissive-surface transport; rebake to include Magic GI emitters.")
		warning = "; ".join(warnings)
		return result
	var root := SceneTracker.scene_root(volume)
	var baked_keys: Dictionary = {}
	for emitter in data.emitter_count():
		var key: String = data.emitter_keys[emitter]
		baked_keys[key] = true
		var binding := Binding.resolve_binding(root, key)
		if binding.is_empty():
			warnings.append("Baked emissive surface '%s' no longer exists; re-bake Magic GI emitters." % key)
			continue
		var node: MeshInstance3D = binding.node
		var surface: int = binding.surface
		var material := node.get_active_material(surface)
		if not material is BaseMaterial3D or material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			warnings.append("Baked emissive surface '%s' no longer has a supported opaque StandardMaterial3D; re-bake." % key)
			continue
		if _current_static_signature(key, node, surface, material) != data.emitter_static_signatures[emitter]:
			warnings.append("Static emission texture, UV mapping, or sidedness changed for '%s'; re-bake that Magic GI source." % key)
			continue
		if not material.emission_enabled:
			continue
		var energy: float = material.emission_energy_multiplier
		if bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
			energy *= material.emission_intensity
		if not is_finite(energy) or energy <= 0.0:
			continue
		var emission_color: Color = material.emission.srgb_to_linear()
		var linear_color := Vector3(emission_color.r, emission_color.g, emission_color.b)
		if not linear_color.is_finite() or linear_color.x < 0.0 or linear_color.y < 0.0 or linear_color.z < 0.0:
			warnings.append("Non-finite or negative emission color on '%s' was ignored." % key)
			continue
		var color_weight: Vector3 = linear_color * energy
		if not color_weight.is_finite():
			warnings.append("Emission intensity overflow on '%s' was ignored." % key)
			continue
		var base := emitter * 6
		if material.emission_operator == BaseMaterial3D.EMISSION_OP_ADD:
			result[base] = color_weight.x
			result[base + 1] = color_weight.y
			result[base + 2] = color_weight.z
			result[base + 3] = energy
			result[base + 4] = energy
			result[base + 5] = energy
		else:
			result[base + 3] = color_weight.x
			result[base + 4] = color_weight.y
			result[base + 5] = color_weight.z
	for current_key in _current_emitter_keys(volume):
		if not baked_keys.has(current_key):
			warnings.append("Emissive surface '%s' was enabled or added after the bake; re-bake Magic GI emitters." % current_key)
	# Packing can overflow even when the source GDScript float was finite.
	for value in result:
		if not is_finite(value):
			result.fill(0.0)
			warnings.append("Magic GI emissive values were non-finite and have been disabled.")
			break
	warning = "; ".join(warnings)
	return result

func get_warning() -> String:
	return warning

func _current_emitter_keys(volume: Node3D) -> PackedStringArray:
	var volume_id := volume.get_instance_id()
	var now := Time.get_ticks_msec()
	if _current_keys.get("volume_id", 0) != volume_id or now >= int(_current_keys.get("expires", 0)):
		_current_keys = {"volume_id": volume_id, "expires": now + 500, "keys": Binding.current_keys(volume)}
	return _current_keys["keys"]

func _current_static_signature(key: String, node: MeshInstance3D, surface: int,
		material: BaseMaterial3D) -> int:
	var cheap_fingerprint := Binding.runtime_fingerprint(node, surface, material)
	var cached: Dictionary = _static_signature_cache.get(key, {})
	if not cached.is_empty() and int(cached.fingerprint) == cheap_fingerprint:
		return int(cached.signature)
	var signature := Binding.static_signature(node, surface, material)
	_static_signature_cache[key] = {"fingerprint": cheap_fingerprint, "signature": signature}
	return signature
