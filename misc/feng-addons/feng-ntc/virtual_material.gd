@tool
class_name FengNTCVirtualMaterial
extends ShaderMaterial
## Opt-in tiled opaque UV1 PBR material. See streamer.gd or request_uv_rect for page requests.
const TextureSet = preload("texture_set.gd")
const SHADER = preload("shaders/virtual_material.gdshader")
@export var texture_set: TextureSet:
	set(value):
		texture_set = value
		_generation += 1
		_resolve.call_deferred(_generation)
@export_range(4,16,1) var cache_axis := 8:
	set(value):
		cache_axis = clampi(value,4,16)
		_generation += 1
		_resolve.call_deferred(_generation)
var ntc_error := ""
var _session: RefCounted
var _generation := 0

func _init() -> void:
	shader = SHADER

func _resolve(generation: int) -> void:
	if generation != _generation: return
	ntc_error = ""
	if _session != null: _session.close(); _session = null
	_runtime_parameter("ntc_ready",false)
	if texture_set == null: return
	_session = texture_set.create_virtual_session(cache_axis)
	if _session == null: ntc_error = texture_set.last_error; push_error(ntc_error); return
	_session.changed.connect(_update)
	var data := texture_set.package
	_runtime_parameter("ntc_size",Vector2(data.width,data.height))
	_runtime_parameter("ntc_mips",int(data.mips))
	_runtime_parameter("ntc_has_normal",data.maps.has("normal"))
	_runtime_parameter("ntc_has_orm",data.maps.has("orm"))
	# Bounded default even before a visibility controller is attached.
	_session.request_uv_rect(Rect2(0,0,1,1),0)

func _update() -> void:
	if _session == null: return
	ntc_error = _session.last_error
	if not ntc_error.is_empty() or not _session.ready: return
	for name: String in _session.textures: _runtime_parameter("ntc_"+name,_session.textures[name].get_rid())
	_runtime_parameter("ntc_pages",_session.page_texture.get_rid())
	_runtime_parameter("ntc_ready",true)

func _runtime_parameter(name: String, value: Variant) -> void:
	# Generated GPU resources bypass ShaderMaterial's serialized parameter cache.
	RenderingServer.material_set_param(get_rid(),name,value)

func request_uv_rect(uv_rect: Rect2, mip := 0) -> void:
	if _session != null: _session.request_uv_rect(uv_rect,mip)

func get_runtime_stats() -> Dictionary:
	return _session.stats.duplicate() if _session != null else {}

func _validate_property(property: Dictionary) -> void:
	if property.name.begins_with("shader_parameter/ntc_"):
		property.usage = PROPERTY_USAGE_NONE
