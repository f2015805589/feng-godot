@tool
extends RefCounted
## Called ONLY on the owning RenderingDevice thread. Runtime has no native SDK dependency.
const SHADER_PATH := "res://addons/feng-ntc/shaders/decode.glsl"
const MAPS := ["albedo", "normal", "orm"]
var rd: RenderingDevice
var package: Dictionary
var textures: Dictionary = {}
var last_error := ""
var dispatch_count := 0
var decoded_texels := 0
var _owned: Array[RID] = []
var _shader := RID()
var _pipeline := RID()
var _sets: Array[RID] = []
var _size := Vector2i.ZERO
var _mips := 1
var _stream_latents := false
var _buffers: Array[RID] = []
var gpu_compressed_bytes := 0
const PAGE_BUFFER_BYTES := 128 * 1024


static func validate(data: Dictionary) -> String:
	if data.get("version", 0) != 1: return "Unsupported portable NTC version"
	for name in ["constants", "weights", "latents"]:
		if not data.get(name) is PackedByteArray: return "Missing NTC buffer: " + name
	if not data.get("layout") is PackedInt32Array or not data.get("maps") is Dictionary: return "Invalid NTC layout"
	var width := int(data.get("width", 0)); var height := int(data.get("height", 0))
	var mips := int(data.get("mips", 0)); var layers := int(data.get("layers", 0))
	var latent_mips := int(data.get("latent_mips", 0))
	if width < 4 or height < 4 or width > 8192 or height > 8192 or width & (width - 1) or height & (height - 1): return "Invalid NTC dimensions"
	if mips != int(log(maxi(width, height)) / log(2)) + 1 or layers < 1 or layers > 4 or latent_mips < 2 or latent_mips > 16: return "Invalid NTC mip layout"
	if data.constants.size() != 336 or data.weights.size() < 8192 or data.weights.size() > 65536 or data.weights.size() % 4: return "Invalid NTC network buffers"
	if data.latents.is_empty() or data.latents.size() > 128 * 1024 * 1024 or data.latents.size() % 4: return "Invalid NTC latent buffer"
	if data.layout.size() != layers * latent_mips * 4: return "Incomplete NTC latent layout"
	for i in range(0, data.layout.size(), 4):
		var offset: int = data.layout[i]; var w: int = data.layout[i+1]; var h: int = data.layout[i+2]; var pitch: int = data.layout[i+3]
		if offset < 0 or offset % 4 or w < 1 or h < 1 or pitch < w*2 or pitch % 2 or offset + pitch*h > data.latents.size(): return "NTC latent range exceeds buffer"
	for i in range(mips):
		var neural: int = data.constants.decode_s32(i*16)
		if neural < 0 or neural+1 >= latent_mips: return "NTC neural mip out of range"
	for i in range(3):
		if data.constants.decode_s32((76+i)*4) != [width,height,mips][i]: return "NTC dimensions disagree"
	for i in range(4):
		for spec in [[64, [48,64,48,32][i]*[64,48,32,16][i]], [68,[64,48,32,16][i]*4], [72,[64,48,32,16][i]*4]]:
			var offset: int = data.constants.decode_s32((spec[0]+i)*4)
			if offset < 0 or offset % 4 or offset+spec[1] > data.weights.size(): return "NTC weight range exceeds buffer"
	var terrain: bool = data.get("kind", "") == "terrain_vt"
	if terrain:
		if data.maps.size() != 3 or not data.maps.has_all(["albedo_height", "normal_roughness", "params"]): return "Incomplete terrain VT channels"
	elif not data.maps.has("albedo"): return "Missing NTC albedo map"
	for name: String in data.maps:
		var item: Variant = data.maps[name]
		if name not in (["albedo_height", "normal_roughness", "params"] if terrain else MAPS) or not item is Dictionary: return "Unknown NTC map"
		var count := 4 if terrain or name == "albedo" else 3
		if item.get("count", 0) != count or int(item.get("first", -1)) < 0 or int(item.first)+count > 16: return "Invalid NTC channels"
		if int(item.get("rgb_space", -1)) not in [0,1] or int(item.get("alpha_space", -1)) not in [0,1]: return "Unsupported NTC output color space"
	return ""


func initialize(device: RenderingDevice, data: Dictionary, size: Vector2i, mip_levels := 1, stream_latents := false) -> bool:
	last_error = validate(data)
	if not last_error.is_empty(): return false
	if data.get("kind", "") == "terrain_vt":
		last_error = "Terrain VT packages require the terrain VT decoder"
		return false
	if device == null:
		last_error = "Feng NTC requires a RenderingDevice renderer (Vulkan, D3D12 or Metal); Compatibility/WebGL has no compute backend."
		return false
	rd = device; package = data.duplicate(); _size = size; _mips = mip_levels
	_stream_latents = stream_latents
	var source := RDShaderSource.new()
	# Raw fallback allows isolated tests before the editor import scan. Export includes the source via export_plugin.gd.
	source.source_compute = FileAccess.get_file_as_string(SHADER_PATH).replace("#[compute]", "")
	if source.source_compute.is_empty(): last_error = "Missing NTC compute shader"; return false
	var outputs := 0
	for map: Dictionary in data.maps.values(): outputs=maxi(outputs,int(map.first)+int(map.count))
	# Specialize only the network shape. The source weights and quantization stay
	# unchanged; absent latent inputs and unused output channels are exact zeros.
	source.source_compute=source.source_compute.replace("#define NTC_LATENT_LAYERS 4","#define NTC_LATENT_LAYERS %d" % int(data.layers))
	source.source_compute=source.source_compute.replace("#define NTC_OUTPUT_CHANNELS 16","#define NTC_OUTPUT_CHANNELS %d" % (ceili(outputs/4.0)*4))
	var spirv := rd.shader_compile_spirv_from_source(source)
	last_error = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not last_error.is_empty(): return false
	_shader = _keep(rd.shader_create_from_spirv(spirv))
	if not _shader.is_valid(): last_error = "Cannot create NTC shader"; return false
	_pipeline = _keep(rd.compute_pipeline_create(_shader))
	var layout := PackedInt32Array()
	for i in range(0,data.layout.size(),4):
		layout.append_array(data.layout.slice(i,i+4))
		layout.append_array(PackedInt32Array([0,0,data.layout[i+1],data.layout[i+2]]))
	var buffers: Array[PackedByteArray] = [data.constants,data.weights,data.latents,layout.to_byte_array()]
	if stream_latents:
		buffers[2] = PackedByteArray(); buffers[2].resize(PAGE_BUFFER_BYTES)
		buffers[3] = PackedByteArray(); buffers[3].resize(2*int(data.layers)*32)
	for bytes: PackedByteArray in buffers:
		_buffers.append(_keep(rd.storage_buffer_create(bytes.size(), bytes)))
		gpu_compressed_bytes += bytes.size()
	for name: String in MAPS:
		var format := RDTextureFormat.new()
		format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		format.width = size.x if data.maps.has(name) else 1
		format.height = size.y if data.maps.has(name) else 1
		format.mipmaps = mip_levels if data.maps.has(name) else 1
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
		format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB)
		if not rd.texture_is_format_supported_for_usage(format.format, format.usage_bits): last_error = "GPU lacks RGBA8 storage/sampling"; return false
		textures[name] = _keep(rd.texture_create(format, RDTextureView.new()))
		if not textures[name].is_valid(): last_error = "Cannot allocate NTC output cache"; return false
	for mip in range(mip_levels):
		var uniforms: Array[RDUniform] = []
		for binding in range(4): uniforms.append(_uniform(binding, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, _buffers[binding]))
		for i in range(3):
			var texture: RID = textures[MAPS[i]]
			if data.maps.has(MAPS[i]) and mip_levels > 1:
				texture = _keep(rd.texture_create_shared_from_slice(RDTextureView.new(), texture, 0, mip, 1))
			uniforms.append(_uniform(4+i, RenderingDevice.UNIFORM_TYPE_IMAGE, texture))
		_sets.append(_keep(rd.uniform_set_create(uniforms, _shader, 0)))
	return _pipeline.is_valid()


func dispatch(source: Rect2i, destination: Vector2i, source_mip: int, output_mip := 0) -> bool:
	if source.size.x < 1 or source.size.y < 1 or source_mip < 0 or source_mip >= int(package.mips) or output_mip < 0 or output_mip >= _mips: return false
	var bounds := Vector2i(maxi(1,_size.x>>output_mip), maxi(1,_size.y>>output_mip))
	if destination.x < 0 or destination.y < 0 or destination.x+source.size.x > bounds.x or destination.y+source.size.y > bounds.y: return false
	if _stream_latents and not _stage_page(source,source_mip): return false
	var params := PackedInt32Array([source.position.x,source.position.y,source.size.x,source.size.y,destination.x,destination.y,source_mip,int(package.layers),-1,-1,-1,0,0,0,0,0])
	var spaces := 0
	for i in range(3):
		if not package.maps.has(MAPS[i]): continue
		var map: Dictionary = package.maps[MAPS[i]]
		params[8+i] = map.first
		for ch in range(map.count): spaces |= int(map.rgb_space if ch<3 else map.alpha_space) << ((int(map.first)+ch)*2)
	params[12] = spaces
	var bytes := params.to_byte_array()
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, _sets[output_mip], 0)
	rd.compute_list_set_push_constant(list, bytes, bytes.size())
	rd.compute_list_dispatch(list, ceili(source.size.x/8.0), ceili(source.size.y/8.0), 1)
	rd.compute_list_end()
	dispatch_count += 1
	decoded_texels += source.size.x*source.size.y
	return true


func _stage_page(source: Rect2i, mip: int) -> bool:
	var window := page_window(package, source, mip)
	if not window.get("ok", false):
		last_error = window.get("error", "Invalid feature window")
		return false
	var constants: PackedByteArray = window.constants
	var bytes: PackedByteArray = window.latents
	var layout: PackedByteArray = window.layout
	rd.buffer_update(_buffers[0], 0, constants.size(), constants)
	rd.buffer_update(_buffers[2], 0, bytes.size(), bytes)
	rd.buffer_update(_buffers[3], 0, layout.size(), layout)
	return true


static func page_window(data: Dictionary, source: Rect2i, mip: int, max_bytes := PAGE_BUFFER_BYTES) -> Dictionary:
	var bytes := PackedByteArray()
	var layout := PackedInt32Array()
	var neural: int = data.constants.decode_s32(mip*16)
	var size := Vector2(maxi(1,int(data.width)>>mip),maxi(1,int(data.height)>>mip))
	for level in range(2):
		for layer in range(int(data.layers)):
			var i: int = ((neural+level)*int(data.layers)+layer)*4
			var offset: int = data.layout[i]
			var grid := Vector2i(data.layout[i+1],data.layout[i+2])
			var source_pitch: int = data.layout[i+3]
			var scale := Vector2(grid)/size
			var begin := Vector2i(((Vector2(source.position)+Vector2.ONE*0.5)*scale-Vector2.ONE*0.5).floor())
			var end := Vector2i(((Vector2(source.end)-Vector2.ONE*0.5)*scale-Vector2.ONE*0.5).floor())+Vector2i(2,2)
			var extent := (end-begin).min(grid)
			if extent.x==grid.x: begin.x=0
			if extent.y==grid.y: begin.y=0
			begin=Vector2i(posmod(begin.x,grid.x),posmod(begin.y,grid.y))
			var pitch := (extent.x*2+3)&~3
			var base := bytes.size()
			if base+pitch*extent.y>max_bytes:
				return {"ok":false,"error":"NTC feature window exceeds page staging capacity"}
			var sx := posmod(begin.x,grid.x)
			var first := mini(extent.x,grid.x-sx)
			for y in range(extent.y):
				var src := offset+posmod(begin.y+y,grid.y)*source_pitch
				var row: PackedByteArray = data.latents.slice(src+sx*2,src+(sx+first)*2)
				if first<extent.x: row.append_array(data.latents.slice(src,src+(extent.x-first)*2))
				# Bulk row copies avoid per-texel GDScript loops.
				row.resize(pitch)
				bytes.append_array(row)
			layout.append_array(PackedInt32Array([base,grid.x,grid.y,pitch,begin.x,begin.y,extent.x,extent.y]))
	var constants: PackedByteArray = data.constants.duplicate()
	constants.encode_s32(mip*16,0)
	return {"ok":true,"constants":constants,"latents":bytes,"layout":layout.to_byte_array()}


func read_images() -> Dictionary:
	# Diagnostic/export operation only: never used in the runtime rendering path.
	var images := {}
	for name: String in package.maps:
		images[name] = Image.create_from_data(_size.x,_size.y,_mips>1,Image.FORMAT_RGBA8,rd.texture_get_data(textures[name],0))
	return images


func dispose() -> void:
	if rd != null:
		for i in range(_owned.size()-1,-1,-1):
			if _owned[i].is_valid(): rd.free_rid(_owned[i])
	_owned.clear(); textures.clear(); _sets.clear(); _buffers.clear(); package.clear()
	rd = null


func release_network() -> void:
	# Full decode retains only output textures. VT keeps its network for future misses.
	var keep: Array[RID] = []
	for i in range(_owned.size()-1,-1,-1):
		var rid := _owned[i]
		if rid in textures.values(): keep.append(rid)
		elif rid.is_valid(): rd.free_rid(rid)
	_owned = keep
	_sets.clear(); _buffers.clear(); _pipeline = RID(); _shader = RID(); gpu_compressed_bytes=0


func _keep(rid: RID) -> RID:
	_owned.append(rid)
	return rid


static func _uniform(binding: int, type: int, rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.binding = binding; uniform.uniform_type = type; uniform.add_id(rid)
	return uniform
