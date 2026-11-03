@tool
class_name FengNTCMaterial
extends StandardMaterial3D
## Normal Godot material; the small NTC payload is stored, decoded textures are not serialized.

signal ntc_ready(success: bool)
const TextureSet = preload("texture_set.gd")
const GENERATED_TEXTURES := ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture", "ao_texture"]
@export var texture_set: TextureSet:
	set(value):
		texture_set = value
		_generation += 1
		_resolve.call_deferred(_generation)
var ntc_error := ""
var _generation := 0
var _session: RefCounted


func _validate_property(property: Dictionary) -> void:
	if property.name in GENERATED_TEXTURES:
		property.usage = (int(property.usage) & ~PROPERTY_USAGE_STORAGE) | PROPERTY_USAGE_READ_ONLY


func _resolve(generation: int) -> void:
	if generation != _generation: return
	if _session != null and _session.changed.is_connected(_update): _session.changed.disconnect(_update)
	_session = null
	if texture_set == null:
		for name: String in GENERATED_TEXTURES: set(name, null)
		return
	_session = texture_set.get_session()
	if _session == null:
		ntc_error = texture_set.last_error
		push_error("Feng NTC: " + ntc_error)
		ntc_ready.emit(false)
		return
	# Signal delivery is dropped automatically if the material is released during loading.
	_session.changed.connect(_update)
	_update()


func _update() -> void:
	if _session == null: return
	if not _session.last_error.is_empty():
		ntc_error = _session.last_error
		push_error("Feng NTC: " + ntc_error)
		ntc_ready.emit(false)
		return
	if not _session.ready: return
	if _session.changed.is_connected(_update): _session.changed.disconnect(_update)
	var textures: Dictionary = _session.textures
	albedo_texture = textures.get("albedo")
	normal_texture = textures.get("normal")
	var orm: Texture2D = textures.get("orm")
	ao_texture = orm
	ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	roughness_texture = orm
	roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	metallic_texture = orm
	metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	ntc_error = ""
	ntc_ready.emit(true)
