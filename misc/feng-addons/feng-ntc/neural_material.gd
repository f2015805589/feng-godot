@tool
class_name FengNTCNeuralMaterial
extends ShaderMaterial
## Samples the compressed latent grids. Never allocates a decoded color/normal mip chain.
const TextureSet=preload("texture_set.gd")
const SHADER=preload("shaders/neural_material.gdshader")
const SampleData=preload("sample_gpu_data.gd")
static var _shaders: Dictionary={}
@export var texture_set: TextureSet:
	set(value):
		texture_set=value; _generation+=1; _resolve.call_deferred(_generation)
@export_multiline var compression_info: String:
	get:
		return _compression_text if texture_set!=null else "请选择 NTC 数据。"
var ntc_error := ""
var _session: RefCounted
var _generation := 0
var _shader_wide := false
var _shader_uniform := false
var _compression_text := "正在上传 NTC 压缩数据…"

func _init() -> void: shader=SHADER

func _resolve(generation: int) -> void:
	if generation!=_generation: return
	_compression_text="正在上传 NTC 压缩数据…"
	if _session!=null and _session.changed.is_connected(_update): _session.changed.disconnect(_update)
	_session=null
	_runtime_parameter("ntc_ready",false)
	if texture_set==null: return
	_session=texture_set.get_sample_session()
	if _session==null: ntc_error=texture_set.last_error; push_error(ntc_error); return
	_session.changed.connect(_update)
	var data:=texture_set.package
	_shader_wide=false
	_shader_uniform=false
	shader=_specialized_shader(data)
	_runtime_parameter("ntc_size",Vector2(data.width,data.height))
	_runtime_parameter("ntc_mips",int(data.mips))
	_runtime_parameter("ntc_layers",int(data.layers))
	_runtime_parameter("ntc_outputs",SampleData.output_channels(data))
	_runtime_parameter("ntc_from_space",int(data.constants.decode_s32(81*4)))
	var channels:=Vector3i(-1,-1,-1)
	for i in range(3):
		var name: String=["albedo","normal","orm"][i]
		if data.maps.has(name): channels[i]=data.maps[name].first
	_runtime_parameter("ntc_maps",channels)
	_update()

static func _specialized_shader(data: Dictionary, wide := false, uniform_tensor := false) -> Shader:
	var channels:=Vector3i(-1,-1,-1)
	for i in range(3):
		var name: String=["albedo","normal","orm"][i]
		if data.maps.has(name): channels[i]=data.maps[name].first
	var key := "%d_%d_%s_%d_%s_%s" % [data.layers,SampleData.output_channels(data),str(channels),data.constants.decode_s32(81*4),str(wide),str(uniform_tensor)]
	if not _shaders.has(key):
		var code: String=SHADER.code
		code=code.replace("uniform int ntc_layers = 1;","const int ntc_layers = %d;" % data.layers)
		code=code.replace("uniform int ntc_outputs = 16;","const int ntc_outputs = %d;" % SampleData.output_channels(data))
		code=code.replace("uniform ivec3 ntc_maps = ivec3(0,-1,-1);","const ivec3 ntc_maps = ivec3(%d,%d,%d);" % [channels.x,channels.y,channels.z])
		code=code.replace("uniform int ntc_from_space = 0;","const int ntc_from_space = %d;" % data.constants.decode_s32(81*4))
		code=code.replace("uniform bool ntc_tensor_wide = false;","const bool ntc_tensor_wide = %s;" % str(wide))
		# The packed network offsets depend only on its shape, never on weights.
		var bases := PackedInt32Array()
		var offset: int=data.constants.size()/16
		var rows := [int(data.layers)*2+4,16,12,8]
		var widths := [64,48,32,SampleData.output_channels(data)]
		for layer in range(4):
			bases.append(offset); offset+=(rows[layer]+2)*widths[layer]/4
		code=code.replace("uniform ivec4 ntc_bases = ivec4(0);","const ivec4 ntc_bases = ivec4(%d,%d,%d,%d);" % [bases[0],bases[1],bases[2],bases[3]])
		if uniform_tensor:
			var count: int=ceili(offset*(2 if wide else 1)/64.0)*64
			code=code.replace("uniform sampler2D ntc_tensor : filter_nearest, repeat_disable;","uniform vec4 ntc_network[%d];" % count)
			code=code.replace("return texelFetch(ntc_tensor,ivec2(index%64,index/64),0);","return ntc_network[index];")
		var result:=Shader.new(); result.code=code
		_shaders[key]=result
	return _shaders[key]

func _update() -> void:
	if _session==null: return
	ntc_error=_session.last_error
	if not ntc_error.is_empty(): push_error(ntc_error); return
	if not _session.ready: return
	if _shader_wide!=_session.wide_tensor or _shader_uniform!=_session.uniform_tensor:
		_shader_wide=_session.wide_tensor
		_shader_uniform=_session.uniform_tensor
		shader=_specialized_shader(texture_set.package,_shader_wide,_shader_uniform)
	if _shader_uniform: _runtime_parameter("ntc_network",_session.tensor_values)
	for name: String in _session.textures: _runtime_parameter("ntc_"+name,_session.textures[name].get_rid())
	_runtime_parameter("ntc_bases",_session.layer_bases)
	_runtime_parameter("ntc_tensor_mask",_session.tensor_mask)
	_runtime_parameter("ntc_tensor_wide",_session.wide_tensor)
	_runtime_parameter("ntc_ready",true)
	_compression_text=preload("memory_info.gd").sample_summary(texture_set.package)

func _runtime_parameter(name: String, value: Variant) -> void:
	RenderingServer.material_set_param(get_rid(),name,value)

func get_runtime_stats() -> Dictionary:
	return _session.stats.duplicate() if _session!=null else {}

func _get(property: StringName) -> Variant:
	# ShaderMaterial's native property list caches a zero-filled default for array
	# uniforms even when only RenderingServer owns the live value. Do not write
	# thousands of redundant zeros into each saved material or scene instance.
	if property==&"shader_parameter/ntc_network": return PackedVector4Array()
	return null

func _validate_property(property: Dictionary) -> void:
	if property.name.begins_with("shader_parameter/ntc_"): property.usage=PROPERTY_USAGE_NONE
	if property.name=="shader": property.usage=PROPERTY_USAGE_NONE
	if property.name=="compression_info": property.usage=PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY
