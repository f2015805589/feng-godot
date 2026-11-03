@tool
extends RefCounted
signal changed
const Runtime=preload("runtime.gd")
const GPUData=preload("sample_gpu_data.gd")
const Allocation=preload("gpu_allocation.gd")
const GPUTexture=preload("gpu_texture.gd")
const ArrayTexture=preload("gpu_array_texture.gd")
var package: Dictionary
var ready := false
var virtual := false
var textures: Dictionary={}
var last_error := ""
var stats := {"mode":"inference_on_sample","gpu_compressed_bytes":0,"texture_bytes":0,"decoded_texels":0,"dispatches":0}
var layer_bases := Vector4i.ZERO
var tensor_mask := Vector4i.ZERO
var wide_tensor := false
var uniform_tensor := false
var tensor_values := PackedVector4Array()
var _data: RefCounted
var _allocation: RefCounted
var _inflight := false
var _closed := false

func start(data: Dictionary) -> void:
	package=data
	if RenderingServer.get_rendering_device()==null:
		last_error="NTC neural sampling requires a RenderingDevice renderer."; return
	Runtime.register(self)

func tick() -> bool:
	if _closed or _inflight or ready or not last_error.is_empty(): return false
	_inflight=true
	RenderingServer.call_on_render_thread(_upload)
	return true

func _upload() -> void:
	var allocation := Allocation.new()
	var data := GPUData.new()
	allocation.decoder=data
	data.initialize(RenderingServer.get_rendering_device(),package)
	_complete.call_deferred(allocation,data)

func _complete(allocation: RefCounted, data: RefCounted) -> void:
	if _closed: return
	_inflight=false
	_allocation=allocation; _data=data
	last_error=data.last_error
	if not last_error.is_empty(): changed.emit(); return
	var latents := ArrayTexture.new(); latents.allocation=allocation; latents.texture_rd_rid=data.rids.latents
	textures={"latents":latents}
	if data.rids.has("tensor"):
		var tensor := GPUTexture.new(); tensor.allocation=allocation; tensor.texture_rd_rid=data.rids.tensor
		textures.tensor=tensor
	layer_bases=data.layer_bases
	tensor_mask=data.tensor_mask; wide_tensor=data.wide_tensor
	uniform_tensor=data.uniform_tensor; tensor_values=data.tensor_values
	stats.uniform_tensor=uniform_tensor
	stats.wide_tensor=wide_tensor
	stats.gpu_compressed_bytes=data.gpu_bytes
	ready=true; changed.emit()

func close() -> void:
	if _closed: return
	_closed=true
	textures.clear(); tensor_values.clear(); _allocation=null; _data=null
