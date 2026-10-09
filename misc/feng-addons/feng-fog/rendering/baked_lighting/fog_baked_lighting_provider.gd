class_name FFogBakedLightingProvider
extends RefCounted
## Uploads immutable LightmapGI probe snapshots for the addon volumetric shader.
## All RenderingDevice RIDs returned here are provider-owned and borrowed by the
## consumer. This provider never frees RIDs owned by its caller.

const ABI_VERSION := 1
const PARAMS_BYTES := 176
const BSP_NODE_STRIDE := 6
const SHADER_SET_INDEX := 2
const PROBE_POSITIONS_BINDING := 0
const PROBE_SH_BINDING := 1
const TETRAHEDRA_BINDING := 2
const BSP_NODES_BINDING := 3
const PARAMS_BINDING := 4
const FLAG_INCLUDES_ENVIRONMENT_RADIANCE := 1
const FLAG_CONTAINS_SURFACE_DIRECT_RADIANCE := 2
const FLAG_SOURCE_INTERIOR := 4
const FLAG_INCLUDES_PROBE_ORIGIN_DIRECT_LIGHTING := 8
const BakedVolume = preload("res://addons/feng-fog/rendering/baked_lighting/fog_baked_lighting_volume.gd")

var _rendering_device: RenderingDevice
var _snapshots: Dictionary = {} # Resource instance ID -> weak resource/revision/immutable snapshot.
var _gpu_entries: Dictionary = {} # Resource instance ID -> revision/device/owned RIDs.
var _next_snapshot_generation := 1


## Main-thread boundary: validate/copy Resource arrays only when its revision
## changes. Render callbacks should carry this returned snapshot, not the
## Resource, and must treat all arrays as immutable.
func snapshot_for_rendering(p_volume: Resource) -> Dictionary:
	if p_volume == null or not is_instance_valid(p_volume):
		return {}
	var resource_id := p_volume.get_instance_id()
	var revision := int(p_volume.get("revision"))
	var cached: Dictionary = _snapshots.get(resource_id, {})
	var cached_reference: WeakRef = cached.get("resource_ref")
	if cached_reference != null and cached_reference.get_ref() == p_volume \
			and int(cached.get("revision", -1)) == revision:
		return (cached.get("snapshot", {}) as Dictionary).duplicate(false)
	var payload: Dictionary = p_volume.call("get_gpu_payload")
	if payload.is_empty():
		_snapshots.erase(resource_id)
		return {}
	var points: PackedVector3Array = payload.get("probe_positions", PackedVector3Array())
	var probe_sh: PackedFloat32Array = payload.get("probe_sh", PackedFloat32Array())
	var tetrahedra: PackedInt32Array = payload.get("tetrahedra", PackedInt32Array())
	var bsp_nodes: PackedInt32Array = payload.get("bsp_nodes", PackedInt32Array())
	var positions_vec4 := PackedFloat32Array()
	positions_vec4.resize(points.size() * 4)
	for index in points.size():
		var point := points[index]
		var offset := index * 4
		positions_vec4[offset] = point.x
		positions_vec4[offset + 1] = point.y
		positions_vec4[offset + 2] = point.z
		positions_vec4[offset + 3] = 0.0
	var capture_bounds: AABB = payload.get("bounds", AABB())
	var world_to_capture: Transform3D = payload.get("world_to_capture", Transform3D.IDENTITY)
	var world_direction_to_capture: Basis = payload.get("world_direction_to_capture", Basis.IDENTITY)
	var snapshot := {
		"abi_version": ABI_VERSION,
		"valid": true,
		"source": "lightmapgi_capture_probes",
		"resource_id": resource_id,
		"revision": revision,
		"snapshot_generation": _next_snapshot_generation,
		"source_revision": int(payload.get("source_revision", 0)),
		"source_lightprobe_hash": int(payload.get("source_lightprobe_hash", 0)),
		"probe_positions_vec4": positions_vec4,
		"probe_sh": probe_sh.duplicate(),
		"tetrahedra": tetrahedra.duplicate(),
		"bsp_nodes": bsp_nodes.duplicate(),
		"probe_count": points.size(),
		"tetrahedron_count": int(tetrahedra.size() / 4),
		"bsp_node_count": int(bsp_nodes.size() / BSP_NODE_STRIDE),
		"capture_bounds": capture_bounds,
		"world_bounds": payload.get("world_bounds", AABB()),
		"world_to_capture_matrix": _transform_to_column_major(world_to_capture),
		"world_direction_to_capture_matrix": _basis_to_column_major4(world_direction_to_capture),
		"baked_exposure": float(payload.get("baked_exposure", 1.0)),
		"includes_environment_radiance": bool(payload.get("includes_environment_radiance", true)),
		"contains_surface_direct_radiance": bool(payload.get("contains_surface_direct_radiance", false)),
		"includes_probe_origin_direct_lighting": bool(payload.get("includes_probe_origin_direct_lighting", false)),
		"source_interior": bool(payload.get("source_interior", false)),
		"bake_mode": String(payload.get("bake_mode", "lightmapgi_capture_probes")),
		"coefficient_domain": String(payload.get("coefficient_domain", "")),
		"coefficient_to_physical_radiance_scale": float(payload.get("coefficient_to_physical_radiance_scale", 0.0)),
		"phase_convolution": String(payload.get("phase_convolution", "")),
		"resource_ref": weakref(p_volume),
	}
	_snapshots[resource_id] = {
		"resource_ref": weakref(p_volume),
		"revision": revision,
		"snapshot": snapshot,
	}
	_next_snapshot_generation += 1
	if _next_snapshot_generation <= 0:
		_next_snapshot_generation = 1
	return snapshot.duplicate(false)


## Rendering boundary: creates/reuses four provider-owned SSBOs and one 176-byte
## std140 UBO by resource/revision/device. No Resource access or array traversal
## occurs on cache hits. The frame dictionary contributes only scalar exposure
## factors; baked exposure remains independent from the uploaded SH coefficients.
func get_gpu_inputs(p_snapshot: Dictionary, p_rd: RenderingDevice,
		p_frame: Dictionary = {}) -> Dictionary:
	if p_snapshot.is_empty() or int(p_snapshot.get("abi_version", 0)) != ABI_VERSION \
			or not bool(p_snapshot.get("valid", false)):
		return _invalid_result("No valid immutable baked probe snapshot was supplied.")
	if p_rd == null or p_rd != RenderingServer.get_rendering_device():
		return _invalid_result("Baked probe uploads must use the RenderingServer main RenderingDevice.")
	if not _ensure_device(p_rd):
		return _invalid_result("Could not attach the baked probe provider to the main RenderingDevice.")
	var resource_id := int(p_snapshot.get("resource_id", 0))
	var revision := int(p_snapshot.get("revision", -1))
	if not _resource_id_is_valid(resource_id) or revision < 0:
		return _invalid_result("Baked probe snapshot has an invalid resource identity or revision.")
	var probe_count := int(p_snapshot.get("probe_count", 0))
	var tetrahedron_count := int(p_snapshot.get("tetrahedron_count", 0))
	var bsp_node_count := int(p_snapshot.get("bsp_node_count", 0))
	var positions: PackedFloat32Array = p_snapshot.get("probe_positions_vec4", PackedFloat32Array())
	var probe_sh: PackedFloat32Array = p_snapshot.get("probe_sh", PackedFloat32Array())
	var tetrahedra: PackedInt32Array = p_snapshot.get("tetrahedra", PackedInt32Array())
	var bsp_nodes: PackedInt32Array = p_snapshot.get("bsp_nodes", PackedInt32Array())
	if probe_count <= 0 or tetrahedron_count <= 0 or bsp_node_count <= 0 \
			or positions.size() != probe_count * 4 or probe_sh.size() != probe_count * 27 \
			or tetrahedra.size() != tetrahedron_count * 4 \
			or bsp_nodes.size() != bsp_node_count * BSP_NODE_STRIDE:
		return _invalid_result("Baked probe snapshot buffers do not match their published counts.")
	var existing: Dictionary = _gpu_entries.get(resource_id, {})
	var cache_hit := int(existing.get("revision", -1)) == revision \
			and int(existing.get("rendering_device_id", 0)) == p_rd.get_instance_id() \
			and _entry_is_valid(existing)
	if not cache_hit:
		_free_entry(existing)
		var created := _create_gpu_entry(p_rd, p_snapshot)
		if created.is_empty():
			_gpu_entries.erase(resource_id)
			return _invalid_result("Could not create all baked probe GPU buffers.")
		existing = created
		_gpu_entries[resource_id] = existing
	return _make_gpu_result(p_snapshot, existing, p_frame, cache_hit)


## Call when the consumer permanently drops the resource snapshot. The consumer
## must stop submitting work that references these borrowed RIDs first.
func release_resource(p_resource_id: int) -> void:
	_free_entry(_gpu_entries.get(p_resource_id, {}))
	_gpu_entries.erase(p_resource_id)
	_snapshots.erase(p_resource_id)


func release() -> void:
	var rd := _rendering_device
	var owned := take_owned_rids()
	if rd != null:
		for rid in owned:
			rd.free_rid(rid)


func get_owned_rids() -> Array[RID]:
	return _collect_owned_rids(false)


func take_owned_rids() -> Array[RID]:
	return _collect_owned_rids(true)


func _collect_owned_rids(p_clear: bool) -> Array[RID]:
	var result: Array[RID] = []
	var seen: Dictionary = {}
	for entry_value in _gpu_entries.values():
		if entry_value is Dictionary:
			_append_owned_rids(result, seen, _entry_owned_rids(entry_value))
	if p_clear:
		_gpu_entries.clear()
		_snapshots.clear()
		_rendering_device = null
	return result


static func _entry_owned_rids(p_entry: Dictionary) -> Array[RID]:
	var result: Array[RID] = []
	var buffers: Dictionary = p_entry.get("buffers", {})
	for value in buffers.values():
		if value is RID and value.is_valid() and not result.has(value):
			result.append(value)
	return result


static func _append_owned_rids(p_target: Array[RID], p_seen: Dictionary,
		p_rids: Array[RID]) -> void:
	for rid in p_rids:
		if rid.is_valid() and not p_seen.has(rid):
			p_seen[rid] = true
			p_target.append(rid)


static func resolve_source_usage(p_sample_valid: bool, p_includes_environment_radiance: bool,
		p_static_lighting_scattering_intensity: float) -> Dictionary:
	return BakedVolume.resolve_source_usage(p_sample_valid,
			p_includes_environment_radiance, p_static_lighting_scattering_intensity)


static func scene_radiance_scale(p_snapshot: Dictionary, p_frame: Dictionary) -> Dictionary:
	var baked_exposure := float(p_snapshot.get("baked_exposure", 0.0))
	var scene_normalization := float(p_frame.get("scene_normalization", 0.0))
	var pre_exposure := float(p_frame.get("pre_exposure", 0.0))
	if not is_finite(baked_exposure) or baked_exposure <= 0.000001 \
			or not is_finite(scene_normalization) or scene_normalization <= 0.0 \
			or not is_finite(pre_exposure) or pre_exposure <= 0.0:
		return {"valid": false, "scale": 0.0}
	return {
		"valid": true,
		"scale": scene_normalization * pre_exposure / baked_exposure,
		"contract": "incident_SH_radiance * PI * g^l * scene_normalization / baked_exposure * pre_exposure * static_intensity",
	}


func _ensure_device(p_rd: RenderingDevice) -> bool:
	if _rendering_device != null and _rendering_device != p_rd:
		for resource_id in _gpu_entries.keys():
			_free_entry(_gpu_entries[resource_id])
		_gpu_entries.clear()
	_rendering_device = p_rd
	return _rendering_device == p_rd


static func _resource_id_is_valid(p_resource_id: int) -> bool:
	# Object.get_instance_id() uses signed IDs; high-bit tagged Object types
	# can legitimately produce negative values. Only zero means absent here.
	return p_resource_id != 0


func _create_gpu_entry(p_rd: RenderingDevice, p_snapshot: Dictionary) -> Dictionary:
	var buffers := {
		"probe_positions_buffer": RID(),
		"probe_sh_buffer": RID(),
		"tetrahedra_buffer": RID(),
		"bsp_nodes_buffer": RID(),
		"params_buffer": RID(),
	}
	var bytes := {
		"probe_positions_buffer": (p_snapshot["probe_positions_vec4"] as PackedFloat32Array).to_byte_array(),
		"probe_sh_buffer": (p_snapshot["probe_sh"] as PackedFloat32Array).to_byte_array(),
		"tetrahedra_buffer": (p_snapshot["tetrahedra"] as PackedInt32Array).to_byte_array(),
		"bsp_nodes_buffer": (p_snapshot["bsp_nodes"] as PackedInt32Array).to_byte_array(),
		"params_buffer": _pack_params(p_snapshot),
	}
	for name in buffers.keys():
		var data: PackedByteArray = bytes[name]
		if data.is_empty() or (name == "params_buffer" and data.size() != PARAMS_BYTES):
			_free_entry({"rendering_device": p_rd, "buffers": buffers})
			return {}
		var buffer := p_rd.uniform_buffer_create(data.size(), data) if name == "params_buffer" \
				else p_rd.storage_buffer_create(data.size(), data)
		if not buffer.is_valid():
			_free_entry({"rendering_device": p_rd, "buffers": buffers})
			return {}
		buffers[name] = buffer
	return {
		"resource_id": int(p_snapshot["resource_id"]),
		"revision": int(p_snapshot["revision"]),
		"rendering_device_id": p_rd.get_instance_id(),
		"rendering_device": p_rd,
		"buffers": buffers,
	}


func _make_gpu_result(p_snapshot: Dictionary, p_entry: Dictionary,
		p_frame: Dictionary, p_cache_hit: bool) -> Dictionary:
	var buffers: Dictionary = p_entry.get("buffers", {})
	var exposure := scene_radiance_scale(p_snapshot, p_frame)
	var includes_environment := bool(p_snapshot.get("includes_environment_radiance", true))
	var source_usage := resolve_source_usage(true, includes_environment,
			float(p_frame.get("static_lighting_scattering_intensity", 1.0)))
	return {
		"valid": true,
		"source": "lightmapgi_capture_probes",
		"resource_id": int(p_snapshot.get("resource_id", 0)),
		"revision": int(p_snapshot.get("revision", 0)),
		"source_revision": int(p_snapshot.get("source_revision", 0)),
		"source_lightprobe_hash": int(p_snapshot.get("source_lightprobe_hash", 0)),
		"probe_positions_buffer": buffers.get("probe_positions_buffer", RID()),
		"probe_sh_buffer": buffers.get("probe_sh_buffer", RID()),
		"tetrahedra_buffer": buffers.get("tetrahedra_buffer", RID()),
		"bsp_nodes_buffer": buffers.get("bsp_nodes_buffer", RID()),
		"params_buffer": buffers.get("params_buffer", RID()),
		"probe_count": int(p_snapshot.get("probe_count", 0)),
		"tetrahedron_count": int(p_snapshot.get("tetrahedron_count", 0)),
		"bsp_node_count": int(p_snapshot.get("bsp_node_count", 0)),
		"params_buffer_bytes": PARAMS_BYTES,
		"shader_binding_layout": {
			"set": SHADER_SET_INDEX,
			"probe_positions": PROBE_POSITIONS_BINDING,
			"probe_sh": PROBE_SH_BINDING,
			"tetrahedra": TETRAHEDRA_BINDING,
			"bsp_nodes": BSP_NODES_BINDING,
			"params": PARAMS_BINDING,
		},
		"capture_bounds": p_snapshot.get("capture_bounds", AABB()),
		"baked_exposure": float(p_snapshot.get("baked_exposure", 1.0)),
		"scene_radiance_scale": float(exposure.get("scale", 0.0)),
		"scene_radiance_scale_valid": bool(exposure.get("valid", false)),
		"coefficient_domain": p_snapshot.get("coefficient_domain", ""),
		"coefficient_to_physical_radiance_scale": float(p_snapshot.get("coefficient_to_physical_radiance_scale", 0.0)),
		"phase_convolution": p_snapshot.get("phase_convolution", ""),
		"includes_environment_radiance": includes_environment,
		"contains_surface_direct_radiance": bool(p_snapshot.get("contains_surface_direct_radiance", false)),
		"includes_probe_origin_direct_lighting": bool(p_snapshot.get("includes_probe_origin_direct_lighting", false)),
		"source_interior": bool(p_snapshot.get("source_interior", false)),
		"bake_mode": p_snapshot.get("bake_mode", ""),
		"source_usage_for_valid_probe": source_usage,
		"cache_hit": p_cache_hit,
		"output_ownership": "provider",
		"consumer_owns_buffers": false,
		"source_arrays_walked_this_call": false,
		"device": "RenderingServer main RenderingDevice",
	}


func _pack_params(p_snapshot: Dictionary) -> PackedByteArray:
	var values := PackedFloat32Array()
	values.append_array(p_snapshot.get("world_to_capture_matrix", PackedFloat32Array()))
	values.append_array(p_snapshot.get("world_direction_to_capture_matrix", PackedFloat32Array()))
	var bounds: AABB = p_snapshot.get("capture_bounds", AABB())
	values.append_array(PackedFloat32Array([
		bounds.position.x, bounds.position.y, bounds.position.z,
		float(p_snapshot.get("baked_exposure", 1.0)),
		bounds.size.x, bounds.size.y, bounds.size.z, 0.0,
	]))
	var flags := 0
	if bool(p_snapshot.get("includes_environment_radiance", true)):
		flags |= FLAG_INCLUDES_ENVIRONMENT_RADIANCE
	if bool(p_snapshot.get("contains_surface_direct_radiance", false)):
		flags |= FLAG_CONTAINS_SURFACE_DIRECT_RADIANCE
	if bool(p_snapshot.get("source_interior", false)):
		flags |= FLAG_SOURCE_INTERIOR
	if bool(p_snapshot.get("includes_probe_origin_direct_lighting", false)):
		flags |= FLAG_INCLUDES_PROBE_ORIGIN_DIRECT_LIGHTING
	var float_bytes := values.to_byte_array()
	var count_flags := PackedInt32Array([
		int(p_snapshot.get("probe_count", 0)),
		int(p_snapshot.get("tetrahedron_count", 0)),
		int(p_snapshot.get("bsp_node_count", 0)),
		flags,
	]).to_byte_array()
	float_bytes.append_array(count_flags)
	return float_bytes


func _entry_is_valid(p_entry: Dictionary) -> bool:
	var buffers: Dictionary = p_entry.get("buffers", {})
	for name in ["probe_positions_buffer", "probe_sh_buffer", "tetrahedra_buffer", "bsp_nodes_buffer", "params_buffer"]:
		var rid: RID = buffers.get(name, RID())
		if not rid.is_valid():
			return false
	return true


func _free_entry(p_entry: Dictionary) -> void:
	var rd: RenderingDevice = p_entry.get("rendering_device")
	if rd == null:
		return
	for rid in _entry_owned_rids(p_entry):
		rd.free_rid(rid)


func _invalid_result(p_reason: String) -> Dictionary:
	return {
		"valid": false,
		"source": "lightmapgi_capture_probes",
		"reason": p_reason,
		"output_ownership": "none",
		"consumer_owns_buffers": false,
	}


static func _transform_to_column_major(p_transform: Transform3D) -> PackedFloat32Array:
	var basis := p_transform.basis
	var origin := p_transform.origin
	return PackedFloat32Array([
		basis.x.x, basis.x.y, basis.x.z, 0.0,
		basis.y.x, basis.y.y, basis.y.z, 0.0,
		basis.z.x, basis.z.y, basis.z.z, 0.0,
		origin.x, origin.y, origin.z, 1.0,
	])


static func _basis_to_column_major4(p_basis: Basis) -> PackedFloat32Array:
	return PackedFloat32Array([
		p_basis.x.x, p_basis.x.y, p_basis.x.z, 0.0,
		p_basis.y.x, p_basis.y.y, p_basis.y.z, 0.0,
		p_basis.z.x, p_basis.z.y, p_basis.z.z, 0.0,
		0.0, 0.0, 0.0, 1.0,
	])
