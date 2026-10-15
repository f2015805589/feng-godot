@tool
extends RefCounted
## Render-thread owner of one immutable bake's spherical transfer and relit SH.

const U = preload("../rd/uniforms.gd")
const RelightShader: RDShaderFile = preload("../library/magic-gi/magic_gi_directional_relight.glsl")
var _shader := RID()
var _pipeline := RID()
var _spirv: RDShaderSPIRV
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
var _allocation_tasks: Array[Dictionary] = []
var _allocation_task_index := 0
var _upload_tasks: Array[Dictionary] = []
var _upload_task_index := 0
var _upload_task_offset := 0
var _ready := false
var _failed := false
var _payloads: Dictionary = {}

func create(rd: RenderingDevice, data: Resource) -> bool:
	if not begin_create(rd, data):
		return false
	while has_pending_allocations():
		allocate_step(rd, 8)
	while has_pending_uploads():
		upload_step(rd, 16 * 1024 * 1024)
	return _ready

## Allocate immutable directional resources without transferring the whole bake
## at once. Magic GI page residency feeds upload_step() from its shared frame cap.
func begin_create(rd: RenderingDevice, data: Resource, packed_upload: Dictionary = {}) -> bool:
	_upload_tasks.clear()
	_upload_task_index = 0
	_upload_task_offset = 0
	_allocation_tasks.clear()
	_allocation_task_index = 0
	_failed = false
	_ready = false
	var directional: Resource = data.get("directional")
	if directional == null:
		return false
	probes = int(directional.get("probe_count"))
	emitters = int(directional.get("source_count"))
	var transfer_bytes: PackedByteArray = packed_upload.get("directional_transfer_bytes", PackedByteArray())
	var sky_bytes: PackedByteArray = packed_upload.get("directional_sky_bytes", PackedByteArray())
	var emission_bytes: PackedByteArray = packed_upload.get("directional_emission_bytes", PackedByteArray())
	if transfer_bytes.is_empty():
		transfer_bytes = (directional.get("transfer") as PackedFloat32Array).to_byte_array()
	if sky_bytes.is_empty():
		sky_bytes = (directional.get("sky") as PackedFloat32Array).to_byte_array()
	if emission_bytes.is_empty():
		emission_bytes = (directional.get("emission") as PackedFloat32Array).to_byte_array()
	var normals_bytes: PackedByteArray = packed_upload.get("normal_bytes", PackedByteArray())
	if normals_bytes.is_empty():
		var packed_normals := PackedFloat32Array()
		for normal: Vector3 in data.get("normals"):
			packed_normals.append_array([normal.x, normal.y, normal.z, 0.0])
		normals_bytes = packed_normals.to_byte_array()
	var payloads := {
		"transfer": transfer_bytes,
		"sky": sky_bytes,
		"emission": emission_bytes,
		"normals": normals_bytes,
	}
	_allocation_tasks = [
		{"name": "transfer", "size": maxi(4, transfer_bytes.size())},
		{"name": "sky", "size": maxi(4, sky_bytes.size())},
		{"name": "emission", "size": maxi(4, emission_bytes.size())},
		{"name": "sources", "size": maxi(24, emitters * 24)},
		{"name": "lighting", "size": maxi(4, probes * 20 * 16)},
		{"name": "normals", "size": maxi(4, normals_bytes.size())},
	]
	_source_key.clear()
	_spirv = RelightShader.get_spirv()
	_payloads = payloads
	if _spirv == null or RelightShader.base_error != "" \
			or _spirv.bytecode_compute.is_empty() or _spirv.compile_error_compute != "":
		abort()
		return false
	return true

func has_pending_allocations() -> bool:
	return not _failed and (not _shader.is_valid() or not _pipeline.is_valid() \
		or _allocation_task_index < _allocation_tasks.size())

func allocate_step(rd: RenderingDevice, max_allocations: int) -> int:
	if _failed:
		return -1
	if max_allocations <= 0:
		return 0
	var allocated := 0
	if not _shader.is_valid() and allocated < max_allocations:
		_shader = rd.shader_create_from_spirv(_spirv, "Magic GI Directional Relight")
		if not _shader.is_valid():
			abort()
			return -1
		allocated += 1
	if _shader.is_valid() and not _pipeline.is_valid() and allocated < max_allocations:
		_pipeline = rd.compute_pipeline_create(_shader)
		if not _pipeline.is_valid():
			abort()
			return -1
		allocated += 1
	while has_pending_allocations() and allocated < max_allocations:
		var task: Dictionary = _allocation_tasks[_allocation_task_index]
		var size := int(task["size"])
		var rid := rd.storage_buffer_create(size)
		if not rid.is_valid():
			abort()
			return -1
		match String(task["name"]):
			"transfer": _transfer = rid
			"sky": _sky = rid
			"emission": _emission = rid
			"sources": _sources = rid
			"lighting": lighting = rid
			"normals": _normals = rid
		var payload_key := String(task["name"])
		if payload_key == "normals":
			payload_key = "normals"
		elif payload_key == "sources" or payload_key == "lighting":
			payload_key = ""
		if not payload_key.is_empty():
			_upload_tasks.append({"rid": rid, "bytes": _payloads.get(payload_key, PackedByteArray())})
		_allocation_task_index += 1
		allocated += 1
	if not has_pending_allocations() and _upload_tasks.is_empty():
		_ready = true
	return allocated

func has_pending_uploads() -> bool:
	return not _failed and _upload_task_index < _upload_tasks.size()

func upload_step(rd: RenderingDevice, byte_budget: int) -> int:
	if _failed:
		return -1
	var consumed := 0
	while has_pending_uploads() and byte_budget > 0:
		var task: Dictionary = _upload_tasks[_upload_task_index]
		var bytes: PackedByteArray = task["bytes"]
		var remaining := bytes.size() - _upload_task_offset
		if remaining <= 0:
			_upload_task_index += 1
			_upload_task_offset = 0
			continue
		var count := mini(remaining, byte_budget)
		count -= count % 4
		if count <= 0:
			break
		# Buffer updates may start at any byte offset; keep every transfer bounded
		# by the renderer-wide per-frame upload allowance.
		var slice := bytes.slice(_upload_task_offset, _upload_task_offset + count)
		if rd.buffer_update(task["rid"], _upload_task_offset, count, slice) != OK:
			abort()
			return -1
		_upload_task_offset += count
		byte_budget -= count
		consumed += count
		if _upload_task_offset == bytes.size():
			_upload_task_index += 1
			_upload_task_offset = 0
	_ready = not has_pending_uploads() and not has_pending_allocations()
	if _ready:
		_upload_tasks.clear()
		_upload_task_index = 0
		_upload_task_offset = 0
	return consumed

func is_ready() -> bool:
	return _ready and not _failed

## Stop future work while keeping partial RIDs visible to owned_rids() so the
## pass can release them together with its failed page-ledger admission.
func abort() -> void:
	_failed = true
	_ready = false
	_allocation_tasks.clear()
	_allocation_task_index = 0
	_upload_tasks.clear()
	_upload_task_index = 0
	_upload_task_offset = 0
	_payloads.clear()

func update(rd: RenderingDevice, ubo: RID, snapshot: Dictionary, surface_lighting: RID) -> bool:
	if not _ready:
		return false
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

static func _empty_buffer(rd: RenderingDevice, byte_count: int) -> RID:
	return rd.storage_buffer_create(maxi(4, byte_count))
