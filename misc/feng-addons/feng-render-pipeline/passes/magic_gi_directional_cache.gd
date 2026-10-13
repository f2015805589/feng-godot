@tool
extends RefCounted
## Render-thread owner of one immutable bake's spherical transfer and relit SH.

const U = preload("../rd/uniforms.gd")
const RelightShader: RDShaderFile = preload("../library/magic-gi/magic_gi_directional_relight.glsl")
var _shader := RID()
var _pipeline := RID()
var _transfer := RID()
var _sky := RID()
var _emission := RID()
var _sources := RID()
var _normals := RID()
var lighting := RID()
var probes := 0
var emitters := 0
var epoch := 0
var _source_key: Array = []

func create(rd: RenderingDevice, data: Resource) -> bool:
	var directional: Resource = data.get("directional")
	if directional == null:
		return false
	probes = int(directional.get("probe_count"))
	emitters = int(directional.get("source_count"))
	_transfer = _buffer(rd, directional.get("transfer"))
	_sky = _buffer(rd, directional.get("sky"))
	_emission = _buffer(rd, directional.get("emission"))
	_sources = rd.storage_buffer_create(maxi(24, emitters * 24))
	lighting = rd.storage_buffer_create(probes * 20 * 16)
	var packed_normals := PackedFloat32Array()
	for normal: Vector3 in data.get("normals"):
		packed_normals.append_array([normal.x, normal.y, normal.z, 0.0])
	_normals = _buffer(rd, packed_normals)
	_shader = rd.shader_create_from_spirv(RelightShader.get_spirv(), "Magic GI Directional Relight")
	if _shader.is_valid():
		_pipeline = rd.compute_pipeline_create(_shader)
	for rid in owned_rids():
		if not rid.is_valid():
			return false
	return true

func update(rd: RenderingDevice, ubo: RID, snapshot: Dictionary, surface_lighting: RID) -> bool:
	var sources: PackedFloat32Array = snapshot.get("emission_sources", PackedFloat32Array())
	if sources.size() != emitters * 6:
		return false
	var key := [snapshot.get("lighting"), snapshot.get("sky_lighting"), sources, snapshot.get("emission_revision", 0)]
	if key == _source_key:
		return true
	if not sources.is_empty():
		var bytes := sources.to_byte_array()
		if rd.buffer_update(_sources, 0, bytes.size(), bytes) != OK:
			return false
	var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [
		U.storage_buffer(0, _transfer), U.storage_buffer(1, _sky), U.storage_buffer(2, _emission),
		U.storage_buffer(3, _sources), U.uniform_buffer(4, ubo), U.storage_buffer(5, lighting), U.storage_buffer(6, _normals),
		U.storage_buffer(7, surface_lighting)])
	if not uniforms.is_valid():
		return false
	var push := PackedInt32Array([probes, emitters]).to_byte_array()
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (probes + 63) / 64, 1, 1)
	rd.compute_list_end()
	_source_key = key.duplicate(true)
	epoch += 1
	return true

func owned_rids() -> Array[RID]:
	return [_pipeline, _shader, _transfer, _sky, _emission, _sources, _normals, lighting]

static func _buffer(rd: RenderingDevice, values: PackedFloat32Array) -> RID:
	var bytes := values.to_byte_array()
	return rd.storage_buffer_create(bytes.size(), bytes) if not bytes.is_empty() else rd.storage_buffer_create(4)
