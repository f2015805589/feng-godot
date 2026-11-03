@tool
extends RefCounted
## Read-only textures carrying exact GenericInt8 words for a spatial material.
## No decoded albedo/normal images, no RGBA cache, no SDK at runtime.
var rids: Dictionary={}
var last_error := ""
var gpu_bytes := 0
var layer_bases := Vector4i.ZERO
var tensor_mask := Vector4i.ZERO
var wide_tensor := false
var uniform_tensor := false
var tensor_values := PackedVector4Array()
var _rd: RenderingDevice

static func footprint(data: Dictionary) -> Dictionary:
	var latent_bytes := 0
	for i in range(0,data.layout.size(),4): latent_bytes+=int(data.layout[i+1])*int(data.layout[i+2])*2
	var encoding := encode_tensor(data)
	var tensor_bytes: int=encoding.bytes.size()
	return {"latent_bytes":latent_bytes,"network_bytes":tensor_bytes,"total_bytes":latent_bytes+tensor_bytes}

static func output_channels(data: Dictionary) -> int:
	var count := 0
	for map: Dictionary in data.maps.values(): count=maxi(count,int(map.first)+int(map.count))
	return ceili(count/4.0)*4

static func encode_tensor(data: Dictionary) -> Dictionary:
	var tensor: PackedByteArray=data.constants.duplicate()
	var bases := Vector4i.ZERO
	var weights: PackedByteArray=data.weights
	var widths := [48,64,48,32]
	var outputs := [64,48,32,output_channels(data)]
	for layer in range(4):
		bases[layer]=tensor.size()/16
		var weight_start: int=data.constants.decode_s32((64+layer)*4)
		var bias_start: int=data.constants.decode_s32((68+layer)*4)
		var scale_start: int=data.constants.decode_s32((72+layer)*4)
		for column in range(0,outputs[layer],4):
			for row in range(0,widths[layer],4):
				# Absent latent layers contribute exact zero. Remove those weight rows.
				if layer==0 and row<32 and (row/4)%4>=int(data.layers): continue
				for j in range(4): tensor.append_array(weights.slice(weight_start+(column+j)*widths[layer]+row,weight_start+(column+j)*widths[layer]+row+4))
			tensor.append_array(weights.slice(bias_start+column*4,bias_start+(column+4)*4))
			tensor.append_array(weights.slice(scale_start+column*4,scale_start+(column+4)*4))
	# Godot's public material textures are floating point. Choose an XOR exponent
	# mask so all reinterpreted words are normal finite FP32 values (no NaN/FTZ).
	# The shader reverses the mask after a point fetch, preserving every weight bit.
	var used := [PackedByteArray(),PackedByteArray(),PackedByteArray(),PackedByteArray()]
	for component in range(4): used[component].resize(256)
	for i in range(0,tensor.size(),4): used[(i/4)%4][(tensor.decode_u32(i)>>23)&255]=1
	var mask := Vector4i.ZERO
	var wide := false
	for component in range(4):
		var found := false
		for candidate in range(1,255):
			if used[component][candidate]==0 and used[component][candidate^255]==0:
				mask[component]=candidate<<23; found=true; break
		if not found: wide=true
	if wide:
		# Every possible input still has an exact representation if no mask fits.
		var exact := PackedFloat32Array()
		for i in range(0,tensor.size(),4):
			var word := tensor.decode_u32(i)
			exact.append(word&65535); exact.append(word>>16)
		tensor=exact.to_byte_array()
	else:
		for i in range(0,tensor.size(),4): tensor.encode_u32(i,tensor.decode_u32(i)^mask[(i/4)%4])
	var height := ceili(tensor.size()/1024.0)
	tensor.resize(height*1024)
	return {"bytes":tensor,"height":height,"bases":bases,"mask":mask,"wide":wide}

func initialize(rd: RenderingDevice, data: Dictionary) -> bool:
	_rd=rd
	var encoding := encode_tensor(data)
	var tensor: PackedByteArray=encoding.bytes
	layer_bases=encoding.bases; tensor_mask=encoding.mask; wide_tensor=encoding.wide
	# These small, immutable weights are coherent across all pixels. Uniform
	# reads avoid texture address/filter machinery. Reserve room for material
	# parameters and retain the texture carrier on smaller uniform-buffer limits.
	uniform_tensor=tensor.size()+512<=rd.limit_get(RenderingDevice.LIMIT_MAX_UNIFORM_BUFFER_SIZE)
	if uniform_tensor:
		var values:=tensor.to_float32_array()
		for i in range(0,values.size(),4): tensor_values.append(Vector4(values[i],values[i+1],values[i+2],values[i+3]))
	var format := RDTextureFormat.new()
	format.width=64; format.height=encoding.height
	format.format=RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	if not uniform_tensor: rids.tensor=rd.texture_create(format,RDTextureView.new(),[tensor])
	gpu_bytes=tensor.size()
	# Array layers and native mip dimensions follow the SDK latent layout.
	var layers: Array[PackedByteArray]=[]
	var latent_width: int=data.layout[1]
	var latent_height: int=data.layout[2]
	for layer in range(int(data.layers)):
		var bytes := PackedByteArray()
		for mip in range(int(data.latent_mips)):
			var index: int=(mip*int(data.layers)+layer)*4
			var w: int=data.layout[index+1]
			var h: int=data.layout[index+2]
			if w!=maxi(1,latent_width>>mip) or h!=maxi(1,latent_height>>mip):
				last_error="Unsupported irregular NTC latent mip chain"; return false
			for row in range(h):
				var offset: int=data.layout[index]+row*data.layout[index+3]
				bytes.append_array(data.latents.slice(offset,offset+w*2))
		layers.append(bytes)
		gpu_bytes+=bytes.size()
	format=RDTextureFormat.new()
	format.texture_type=RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format.width=latent_width; format.height=latent_height
	format.array_layers=int(data.layers); format.mipmaps=int(data.latent_mips)
	format.format=RenderingDevice.DATA_FORMAT_R8G8_UNORM
	format.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	rids.latents=rd.texture_create(format,RDTextureView.new(),layers)
	if (not uniform_tensor and not rids.tensor.is_valid()) or not rids.latents.is_valid():
		last_error="Cannot allocate NTC compressed sampling textures"; return false
	return true

func dispose() -> void:
	if _rd!=null:
		for rid: RID in rids.values():
			if rid.is_valid(): _rd.free_rid(rid)
	rids.clear(); tensor_values.clear(); _rd=null
