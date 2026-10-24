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
## Normal-independent, uncalibrated directional SH sidecar for the layout-14 V0 field.
## The existing calibrated `lighting` buffer and its 20-vec4 stride are unchanged.
var raw_lighting := RID()
var raw_lighting_bytes := 0
## Static revision-2 total indirect SH9 used by the layout-16 block producer.
## Stride is seven vec4s per probe (27 coefficient lanes + zero padding).
var baked_indirect_lighting := RID()
var baked_indirect_lighting_bytes := 0
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
var _raw_source_key: Array = []
var _clv_input_key: Array = []
var _clv_input_revision := 0
var _clv_sources_ready := false

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
	var baked_lighting_bytes: PackedByteArray = packed_upload.get(
		"baked_indirect_sh_bytes", PackedByteArray())
	var has_baked_indirect := data.has_method("has_baked_indirect_sh") \
			and bool(data.call("has_baked_indirect_sh"))
	if has_baked_indirect and baked_lighting_bytes.is_empty() \
			and data.has_method("make_baked_indirect_sh_upload_bytes"):
		baked_lighting_bytes = data.call("make_baked_indirect_sh_upload_bytes")
	if has_baked_indirect and baked_lighting_bytes.size() != probes * 28 * 4:
		return false
	baked_indirect_lighting_bytes = baked_lighting_bytes.size() if has_baked_indirect else 0
	var payloads := {
		"transfer": transfer_bytes,
		"sky": sky_bytes,
		"emission": emission_bytes,
		"normals": normals_bytes,
		"baked_indirect_lighting": baked_lighting_bytes,
	}
	_allocation_tasks = [
		{"name": "transfer", "size": maxi(4, transfer_bytes.size())},
		{"name": "sky", "size": maxi(4, sky_bytes.size())},
		{"name": "emission", "size": maxi(4, emission_bytes.size())},
		{"name": "sources", "size": maxi(24, emitters * 24)},
		{"name": "lighting", "size": maxi(4, probes * 20 * 16)},
		{"name": "normals", "size": maxi(4, normals_bytes.size())},
	]
	if has_baked_indirect:
		_allocation_tasks.append({"name": "baked_indirect_lighting",
			"size": baked_lighting_bytes.size()})
	raw_lighting_bytes = maxi(4, probes * 18 * 16)
	_source_key.clear()
	_raw_source_key.clear()
	_clv_input_key.clear()
	_clv_input_revision = 0
	_clv_sources_ready = false
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
			"baked_indirect_lighting": baked_indirect_lighting = rid
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

## Allocate the normal-independent sidecar only when the private layout-14 test
## is selected. Authored backends keep the original memory footprint.
func ensure_raw_sidecar(rd: RenderingDevice) -> bool:
	if not _ready or probes <= 0:
		return false
	if raw_lighting.is_valid():
		return true
	raw_lighting = rd.storage_buffer_create(raw_lighting_bytes)
	return raw_lighting.is_valid()

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

func update(rd: RenderingDevice, ubo: RID, snapshot: Dictionary, surface_lighting: RID,
		write_raw_sidecar := false) -> bool:
	if not _ready or (write_raw_sidecar and not ensure_raw_sidecar(rd)):
		return false
	var sources: PackedFloat32Array = snapshot.get("emission_sources", PackedFloat32Array())
	if sources.size() != emitters * 6:
		return false
	var key := [snapshot.get("lighting"), snapshot.get("sky_lighting"), sources, snapshot.get("emission_revision", 0)]
	if key == _source_key and (not write_raw_sidecar or key == _raw_source_key):
		return true
	var raw_output := raw_lighting if write_raw_sidecar else lighting
	if not raw_output.is_valid():
		return false
	if not sources.is_empty():
		var bytes := sources.to_byte_array()
		if rd.buffer_update(_sources, 0, bytes.size(), bytes) != OK:
			return false
	var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [
		U.storage_buffer(0, _transfer), U.storage_buffer(1, _sky), U.storage_buffer(2, _emission),
		U.storage_buffer(3, _sources), U.uniform_buffer(4, ubo), U.storage_buffer(5, lighting), U.storage_buffer(6, _normals),
		U.storage_buffer(7, surface_lighting), U.storage_buffer(8, raw_output)])
	if not uniforms.is_valid():
		return false
	var push := PackedInt32Array([probes, emitters, 1 if write_raw_sidecar else 0]).to_byte_array()
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (probes + 63) / 64, 1, 1)
	rd.compute_list_end()
	_source_key = key.duplicate(true)
	_raw_source_key = key.duplicate(true) if write_raw_sidecar else []
	epoch += 1
	return true

## Keep the immutable transfer resources and update only the live emitter inputs.
## Directional/sky SH stay in the per-view GI UBO; this revision tracks their
## signature together with the source payload so CLV blocks use one coherent epoch.
func update_clv_inputs(rd: RenderingDevice, snapshot: Dictionary) -> bool:
	if not _ready or _failed or not _transfer.is_valid() or not _sky.is_valid() \
			or not _emission.is_valid() or not _sources.is_valid():
		return false
	var sources: PackedFloat32Array = snapshot.get("emission_sources", PackedFloat32Array())
	if sources.size() != emitters * 6:
		return false
	var key := [snapshot.get("lighting"), snapshot.get("sky_lighting"), sources,
		snapshot.get("emission_revision", 0)]
	if key == _clv_input_key:
		return true
	if not sources.is_empty():
		var bytes := sources.to_byte_array()
		if rd.buffer_update(_sources, 0, bytes.size(), bytes) != OK:
			return false
	_clv_input_key = key.duplicate(true)
	_clv_input_revision += 1
	_clv_sources_ready = true
	return true

func get_clv_transfer_bindings() -> Dictionary:
	return {
		"transfer": _transfer,
		"sky": _sky,
		"emission": _emission,
		"sources": _sources,
		"probes": probes,
		"emitters": emitters,
		"lighting_revision": _clv_input_revision,
		"sources_ready": _clv_sources_ready,
	}

func get_clv_input_revision() -> int:
	return _clv_input_revision

func get_clv_input_state() -> Dictionary:
	return {"lighting_revision": _clv_input_revision,
		"sources_ready": _clv_sources_ready, "probes": probes, "emitters": emitters}

func raw_sidecar_matches(snapshot: Dictionary) -> bool:
	if not raw_lighting.is_valid():
		return false
	var sources: PackedFloat32Array = snapshot.get("emission_sources", PackedFloat32Array())
	if sources.size() != emitters * 6:
		return false
	var key := [snapshot.get("lighting"), snapshot.get("sky_lighting"), sources,
		snapshot.get("emission_revision", 0)]
	return key == _raw_source_key

func owned_rids() -> Array[RID]:
	return [_pipeline, _shader, _transfer, _sky, _emission, _sources, _normals,
		lighting, raw_lighting, baked_indirect_lighting]

static func _buffer(rd: RenderingDevice, values: PackedFloat32Array) -> RID:
	var bytes := values.to_byte_array()
	return rd.storage_buffer_create(bytes.size(), bytes) if not bytes.is_empty() else rd.storage_buffer_create(4)

static func _empty_buffer(rd: RenderingDevice, byte_count: int) -> RID:
	return rd.storage_buffer_create(maxi(4, byte_count))
