class_name FFogVolumetricLightmapProvider
extends RefCounted
## Uploads immutable decoded VLM payloads to the main RenderingDevice.
## Textures, samplers, and parameter buffers are provider-owned; returned RIDs
## are borrowed by the fog consumer and must never be freed by it.

const ABI_VERSION := 1
const SET_INDEX := 5
const PARAMS_BYTES := 208
const PARAMS_BINDING := 0
const INDIRECTION_BINDING := 1
const AMBIENT_BINDING := 2
const SH_BINDING_FIRST := 3
const SKY_BENT_BINDING := 9
const DIRECTIONAL_SHADOW_BINDING := 10
const FLAG_VALID := 1
const FLAG_INCLUDES_ENVIRONMENT_RADIANCE := 2
const FLAG_CONTAINS_STATIC_DIRECT_DIRECTIONAL_LIGHTING := 4
const FLAG_HAS_DIRECTIONAL_SHADOW := 8
const FLAG_STATIC_LIGHT_KEY_MATCH := 16
const FLAG_HAS_SKY_BENT_NORMAL := 32
const Volume = preload("fog_volumetric_lightmap.gd")

var _rd: RenderingDevice
var _entries: Dictionary = {} # resource_id -> revision/device/owned texture and UBO RIDs.
var _neutral_entry: Dictionary = {}
var _linear_sampler := RID()
var _nearest_sampler := RID()
var _last_error := ""


## Main-thread boundary. Snapshot arrays are already cached by Resource revision.
static func snapshot_for_rendering(p_resource: Resource) -> Dictionary:
	if p_resource == null or not is_instance_valid(p_resource) \
			or not p_resource.has_method("get_rendering_snapshot"):
		return {}
	var value: Variant = p_resource.call("get_rendering_snapshot")
	if not value is Dictionary or not bool(value.get("valid", false)) \
			or int(value.get("abi_version", 0)) != ABI_VERSION:
		return {}
	return value.duplicate(false)


## Rendering-thread boundary. No Node or Resource methods are called here. The
## optional frame key must come from the same-frame selected directional row.
func get_gpu_inputs(p_snapshot: Dictionary, p_rd: RenderingDevice,
		p_frame: Dictionary = {}) -> Dictionary:
	if p_rd == null or p_rd != RenderingServer.get_rendering_device():
		return _invalid("VLM uploads require the RenderingServer main RenderingDevice.")
	if not _ensure_device(p_rd):
		return _invalid("Could not initialize neutral VLM resources on the main RenderingDevice.")
	if not _snapshot_identity_is_valid(p_snapshot):
		return _neutral_result("No valid immutable VLM snapshot was supplied.")
	var resource_id := int(p_snapshot.get("resource_id", 0))
	var revision := int(p_snapshot.get("revision", 0))
	var existing: Dictionary = _entries.get(resource_id, {})
	var cache_hit := int(existing.get("revision", -1)) == revision \
			and int(existing.get("rendering_device_id", 0)) == p_rd.get_instance_id() \
			and _entry_is_valid(p_rd, existing)
	if not cache_hit:
		if not _snapshot_is_valid(p_snapshot):
			return _neutral_result("VLM snapshot payload failed full structural validation.")
		if not existing.is_empty():
			_free_entry(p_rd, existing)
			_entries.erase(resource_id)
		var created := _create_entry(p_rd, p_snapshot)
		if created.is_empty():
			return _neutral_result("Could not upload all VLM textures and metadata.")
		existing = created
		_entries[resource_id] = existing
	var requested_key := String(p_frame.get("static_directional_light_key", ""))
	var source_key := String(p_snapshot.get("static_directional_light_key", ""))
	var key_matches := not requested_key.is_empty() and requested_key == source_key
	var params: RID = existing["params_match"] if key_matches else existing["params_neutral"]
	return _make_result(p_snapshot, existing, params, key_matches, cache_hit)


func get_neutral_gpu_inputs(p_rd: RenderingDevice) -> Dictionary:
	if p_rd == null or p_rd != RenderingServer.get_rendering_device() \
			or not _ensure_device(p_rd):
		return _invalid("Neutral VLM resources require the main RenderingDevice.")
	return _neutral_result("")


## Uniform-set construction belongs to the consumer because the set is tied to
## its shader RID. This returns values only; the provider keeps ownership.
static func make_set5_uniforms(p_inputs: Dictionary) -> Array[RDUniform]:
	var uniforms: Array[RDUniform] = []
	if not bool(p_inputs.get("valid", false)):
		return uniforms
	var params := RDUniform.new()
	params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params.binding = PARAMS_BINDING
	params.add_id(p_inputs["params_buffer"])
	uniforms.append(params)
	var bindings := [INDIRECTION_BINDING, AMBIENT_BINDING,
		SH_BINDING_FIRST, SH_BINDING_FIRST + 1, SH_BINDING_FIRST + 2,
		SH_BINDING_FIRST + 3, SH_BINDING_FIRST + 4, SH_BINDING_FIRST + 5,
		SKY_BENT_BINDING, DIRECTIONAL_SHADOW_BINDING]
	var textures: Array = p_inputs["textures"]
	for index in textures.size():
		var item: Dictionary = textures[index]
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = bindings[index]
		uniform.add_id(item["sampler"])
		uniform.add_id(item["texture"])
		uniforms.append(uniform)
	return uniforms


## Call only after the consumer has dropped cached set-5 uniform sets and no
## submitted work will reference this resource's textures.
func release_resource(p_resource_id: int) -> void:
	if _rd == null or p_resource_id == 0:
		return
	_free_entry(_rd, _entries.get(p_resource_id, {}))
	_entries.erase(p_resource_id)


func release() -> void:
	if _rd != null:
		for entry in _entries.values():
			_free_entry(_rd, entry)
		_free_entry(_rd, _neutral_entry)
		_free_rid(_rd, _linear_sampler)
		_free_rid(_rd, _nearest_sampler)
	_rd = null
	_entries.clear()
	_neutral_entry.clear()
	_linear_sampler = RID()
	_nearest_sampler = RID()
	_last_error = ""


func get_last_error() -> String:
	return _last_error


static func static_light_key_matches(p_snapshot_key: String, p_frame_key: String) -> bool:
	return not p_snapshot_key.is_empty() and not p_frame_key.is_empty() \
			and p_snapshot_key == p_frame_key


static func compute_source_flags(p_snapshot: Dictionary, p_key_matches: bool,
		p_valid: bool = true) -> int:
	var flags := FLAG_VALID if p_valid else 0
	if bool(p_snapshot.get("includes_environment_radiance", false)):
		flags |= FLAG_INCLUDES_ENVIRONMENT_RADIANCE
	if bool(p_snapshot.get("contains_static_direct_directional_lighting", false)):
		flags |= FLAG_CONTAINS_STATIC_DIRECT_DIRECTIONAL_LIGHTING
	if bool(p_snapshot.get("has_directional_shadowing", false)):
		flags |= FLAG_HAS_DIRECTIONAL_SHADOW
	if p_key_matches:
		flags |= FLAG_STATIC_LIGHT_KEY_MATCH
	if bool(p_snapshot.get("has_sky_bent_normal", false)):
		flags |= FLAG_HAS_SKY_BENT_NORMAL
	return flags


func _ensure_device(p_rd: RenderingDevice) -> bool:
	if _rd != null and _rd != p_rd:
		release()
	_rd = p_rd
	if not _linear_sampler.is_valid():
		_linear_sampler = _create_sampler(p_rd, RenderingDevice.SAMPLER_FILTER_LINEAR)
	if not _nearest_sampler.is_valid():
		_nearest_sampler = _create_sampler(p_rd, RenderingDevice.SAMPLER_FILTER_NEAREST)
	if not _linear_sampler.is_valid() or not _nearest_sampler.is_valid():
		return false
	if _neutral_entry.is_empty() or not _entry_is_valid(p_rd, _neutral_entry):
		_free_entry(p_rd, _neutral_entry)
		_neutral_entry = _create_neutral_entry(p_rd)
	return not _neutral_entry.is_empty() and _entry_is_valid(p_rd, _neutral_entry)


func _create_sampler(p_rd: RenderingDevice, p_filter: int) -> RID:
	var state := RDSamplerState.new()
	state.min_filter = p_filter
	state.mag_filter = p_filter
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return p_rd.sampler_create(state)


func _create_neutral_entry(p_rd: RenderingDevice) -> Dictionary:
	var dims := Vector3i.ONE
	var textures: Array[RID] = []
	var payloads: Array[PackedByteArray] = [
		PackedByteArray([0, 0, 0, 0]), # Invalid indirection w=0.
		_pack_half4(Vector4.ZERO),
		PackedByteArray([128, 128, 128, 128]),
		PackedByteArray([128, 128, 128, 128]),
		PackedByteArray([128, 128, 128, 128]),
		PackedByteArray([128, 128, 128, 128]),
		PackedByteArray([128, 128, 128, 128]),
		PackedByteArray([128, 128, 128, 128]),
		PackedByteArray([128, 128, 255, 255]),
		PackedByteArray([255]),
	]
	for index in payloads.size():
		var format := _texture_format(dims, _format_for_index(index))
		var texture := p_rd.texture_create(format, RDTextureView.new(), [payloads[index]])
		if not texture.is_valid():
			for rid in textures:
				_free_rid(p_rd, rid)
			return {}
		textures.append(texture)
	var invalid_snapshot := {
		"capture_transform": Transform3D.IDENTITY,
		"bounds_local": AABB(Vector3.ZERO, Vector3.ONE),
		"brick_size": 1,
		"indirection_dimensions": dims,
		"brick_atlas_dimensions": dims,
		"baked_exposure": 1.0,
	}
	var params := p_rd.uniform_buffer_create(PARAMS_BYTES, _pack_params(invalid_snapshot, 0))
	if not params.is_valid():
		for rid in textures:
			_free_rid(p_rd, rid)
		return {}
	return {
		"resource_id": 0,
		"revision": 0,
		"rendering_device_id": p_rd.get_instance_id(),
		"rendering_device": p_rd,
		"textures": textures,
		"params_neutral": params,
		"params_match": params,
		"neutral": true,
	}


func _create_entry(p_rd: RenderingDevice, p_snapshot: Dictionary) -> Dictionary:
	var textures: Array[RID] = []
	var payloads: Array[PackedByteArray] = [p_snapshot["indirection_rgba8_uint"],
		p_snapshot["ambient_rgba16f"]]
	for layer in p_snapshot["sh_coefficients_rgba8_unorm"]:
		payloads.append(layer)
	payloads.append(p_snapshot["sky_bent_normal_rgba8_unorm"])
	payloads.append(p_snapshot["directional_shadow_r8_unorm"])
	for index in payloads.size():
		var data: PackedByteArray = payloads[index]
		var dims := _texture_dimensions_for_index(index, p_snapshot)
		var format := _texture_format(dims, _format_for_index(index))
		var texture := p_rd.texture_create(format, RDTextureView.new(), [data])
		if not texture.is_valid():
			for rid in textures:
				_free_rid(p_rd, rid)
			return {}
		textures.append(texture)
	var params_neutral := p_rd.uniform_buffer_create(PARAMS_BYTES,
			_pack_params(p_snapshot, compute_source_flags(p_snapshot, false)))
	var params_match := p_rd.uniform_buffer_create(PARAMS_BYTES,
			_pack_params(p_snapshot, compute_source_flags(p_snapshot, true)))
	if not params_neutral.is_valid() or not params_match.is_valid():
		for rid in textures:
			_free_rid(p_rd, rid)
		_free_rid(p_rd, params_neutral)
		_free_rid(p_rd, params_match)
		return {}
	return {
		"resource_id": int(p_snapshot["resource_id"]),
		"revision": int(p_snapshot["revision"]),
		"rendering_device_id": p_rd.get_instance_id(),
		"rendering_device": p_rd,
		"textures": textures,
		"params_neutral": params_neutral,
		"params_match": params_match,
		"neutral": false,
	}


func _make_result(p_snapshot: Dictionary, p_entry: Dictionary, p_params: RID,
		p_key_matches: bool, p_cache_hit: bool) -> Dictionary:
	var owned_textures: Array = p_entry["textures"]
	var binding_values: Array[Dictionary] = []
	for index in owned_textures.size():
		binding_values.append({
			"binding": _texture_binding(index),
			"sampler": _nearest_sampler if index == 0 else _linear_sampler,
			"texture": owned_textures[index],
		})
	return {
		"valid": true,
		"payload_valid": not bool(p_entry.get("neutral", false)),
		"abi_version": ABI_VERSION,
		"source": "decoded_ue_volumetric_lightmap_v1",
		"resource_id": int(p_snapshot.get("resource_id", 0)),
		"revision": int(p_snapshot.get("revision", 0)),
		"source_revision": int(p_snapshot.get("source_revision", 0)),
		"set_index": SET_INDEX,
		"params_binding": PARAMS_BINDING,
		"params_buffer": p_params,
		"params_buffer_bytes": PARAMS_BYTES,
		"textures": binding_values,
		"uniform_bindings": make_set5_uniforms(_uniform_input_from_values(p_params, binding_values)),
		"indirection_dimensions": p_snapshot["indirection_dimensions"],
		"brick_atlas_dimensions": p_snapshot["brick_atlas_dimensions"],
		"brick_size": int(p_snapshot["brick_size"]),
		"baked_exposure": float(p_snapshot.get("baked_exposure", 1.0)),
		"scene_radiance_scale_contract": "irradiance_over_pi * scene_normalization / baked_exposure * view_pre_exposure (consumer applies P0 once)",
		"includes_environment_radiance": bool(p_snapshot.get("includes_environment_radiance", false)),
		"contains_static_direct_directional_lighting": bool(p_snapshot.get("contains_static_direct_directional_lighting", false)),
		"has_sky_bent_normal": bool(p_snapshot.get("has_sky_bent_normal", false)),
		"has_directional_shadowing": bool(p_snapshot.get("has_directional_shadowing", false)),
		"static_directional_light_key": String(p_snapshot.get("static_directional_light_key", "")),
		"static_light_key_match": p_key_matches,
		"source_flags": compute_source_flags(p_snapshot, p_key_matches),
		"cache_hit": p_cache_hit,
		"texture_ownership": "provider_owned_borrowed_until_revision_replacement_or_release",
		"consumer_owns_textures": false,
		"render_thread_resource_walk": false,
	}


func _neutral_result(p_reason: String) -> Dictionary:
	if _neutral_entry.is_empty() or _rd == null or not _entry_is_valid(_rd, _neutral_entry):
		return _invalid(p_reason if not p_reason.is_empty() else "Neutral VLM resources are unavailable.")
	var inputs := _make_result({
		"resource_id": 0,
		"revision": 0,
		"source_revision": 0,
		"indirection_dimensions": Vector3i.ZERO,
		"brick_atlas_dimensions": Vector3i.ONE,
		"brick_size": 1,
		"baked_exposure": 1.0,
		"includes_environment_radiance": false,
		"contains_static_direct_directional_lighting": false,
		"has_sky_bent_normal": false,
		"has_directional_shadowing": false,
		"static_directional_light_key": "",
	}, _neutral_entry, _neutral_entry["params_neutral"], false, true)
	inputs["valid"] = true
	inputs["payload_valid"] = false
	inputs["source"] = "neutral_invalid_vlm"
	inputs["reason"] = p_reason
	inputs["source_flags"] = 0
	return inputs


func _snapshot_is_valid(p_snapshot: Dictionary) -> bool:
	return bool(Volume.validate_payload(p_snapshot).get("valid", false))


func _snapshot_identity_is_valid(p_snapshot: Dictionary) -> bool:
	if p_snapshot.is_empty() or not bool(p_snapshot.get("valid", false)) \
			or int(p_snapshot.get("abi_version", 0)) != ABI_VERSION:
		return false
	return int(p_snapshot.get("resource_id", 0)) != 0 \
			and int(p_snapshot.get("revision", 0)) > 0


func _entry_is_valid(p_rd: RenderingDevice, p_entry: Dictionary) -> bool:
	if p_entry.is_empty() or int(p_entry.get("rendering_device_id", 0)) != p_rd.get_instance_id():
		return false
	var textures: Array = p_entry.get("textures", [])
	if textures.size() != 10:
		return false
	for texture in textures:
		if not texture is RID or not texture.is_valid() or not p_rd.texture_is_valid(texture):
			return false
	var params_neutral: Variant = p_entry.get("params_neutral", RID())
	var params_match: Variant = p_entry.get("params_match", RID())
	return params_neutral is RID and params_neutral.is_valid() \
			and params_match is RID and params_match.is_valid()


func _texture_format(p_dims: Vector3i, p_data_format: int) -> RDTextureFormat:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = p_dims.x
	format.height = p_dims.y
	format.depth = p_dims.z
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.format = p_data_format
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return format


func _format_for_index(p_index: int) -> int:
	if p_index == 0:
		return RenderingDevice.DATA_FORMAT_R8G8B8A8_UINT
	if p_index == 1:
		return RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	if p_index == 9:
		return RenderingDevice.DATA_FORMAT_R8_UNORM
	return RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM


static func _texture_dimensions_for_index(p_index: int, p_snapshot: Dictionary) -> Vector3i:
	if p_index == 0:
		return p_snapshot.get("indirection_dimensions", Vector3i.ZERO)
	return p_snapshot.get("brick_atlas_dimensions", Vector3i.ZERO)


func _texture_binding(p_index: int) -> int:
	if p_index == 0:
		return INDIRECTION_BINDING
	if p_index == 1:
		return AMBIENT_BINDING
	if p_index == 9:
		return DIRECTIONAL_SHADOW_BINDING
	if p_index == 8:
		return SKY_BENT_BINDING
	return SH_BINDING_FIRST + p_index - 2


func _pack_params(p_snapshot: Dictionary, p_flags: int) -> PackedByteArray:
	var values := PackedFloat32Array()
	var capture: Transform3D = p_snapshot.get("capture_transform", Transform3D.IDENTITY)
	var world_to_capture := capture.affine_inverse()
	var world_direction_to_capture := capture.basis.orthonormalized().transposed()
	values.append_array(_transform_to_column_major(world_to_capture))
	values.append_array(_basis_to_column_major4(world_direction_to_capture))
	var bounds: AABB = p_snapshot.get("bounds_local", AABB(Vector3.ZERO, Vector3.ONE))
	values.append_array(PackedFloat32Array([bounds.position.x, bounds.position.y, bounds.position.z, 0.0]))
	values.append_array(PackedFloat32Array([bounds.size.x, bounds.size.y, bounds.size.z, 0.0]))
	var dims: Vector3i = p_snapshot.get("indirection_dimensions", Vector3i.ZERO)
	var brick_size := int(p_snapshot.get("brick_size", 0))
	var dimensions_lanes := PackedInt32Array([dims.x, dims.y, dims.z, brick_size])
	var atlas: Vector3i = p_snapshot.get("brick_atlas_dimensions", Vector3i.ONE)
	var atlas_lanes := PackedInt32Array([atlas.x, atlas.y, atlas.z, p_flags])
	var output := values.to_byte_array()
	output.append_array(dimensions_lanes.to_byte_array())
	output.append_array(atlas_lanes.to_byte_array())
	var exposure := float(p_snapshot.get("baked_exposure", 1.0))
	output.append_array(PackedFloat32Array([exposure, 0.0, 0.0, 0.0]).to_byte_array())
	return output


static func _transform_to_column_major(p_transform: Transform3D) -> PackedFloat32Array:
	return PackedFloat32Array([
		p_transform.basis.x.x, p_transform.basis.x.y, p_transform.basis.x.z, 0.0,
		p_transform.basis.y.x, p_transform.basis.y.y, p_transform.basis.y.z, 0.0,
		p_transform.basis.z.x, p_transform.basis.z.y, p_transform.basis.z.z, 0.0,
		p_transform.origin.x, p_transform.origin.y, p_transform.origin.z, 1.0,
	])


static func _basis_to_column_major4(p_basis: Basis) -> PackedFloat32Array:
	return PackedFloat32Array([
		p_basis.x.x, p_basis.x.y, p_basis.x.z, 0.0,
		p_basis.y.x, p_basis.y.y, p_basis.y.z, 0.0,
		p_basis.z.x, p_basis.z.y, p_basis.z.z, 0.0,
		0.0, 0.0, 0.0, 1.0,
	])


static func _pack_half4(p_value: Vector4) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_half(0, p_value.x)
	bytes.encode_half(2, p_value.y)
	bytes.encode_half(4, p_value.z)
	bytes.encode_half(6, p_value.w)
	return bytes


func _free_entry(p_rd: RenderingDevice, p_entry: Dictionary) -> void:
	if p_entry.is_empty():
		return
	for texture in p_entry.get("textures", []):
		_free_rid(p_rd, texture)
	_free_rid(p_rd, p_entry.get("params_neutral", RID()))
	var params_match: RID = p_entry.get("params_match", RID())
	if params_match != p_entry.get("params_neutral", RID()):
		_free_rid(p_rd, params_match)


func _free_rid(p_rd: RenderingDevice, p_rid: RID) -> void:
	if p_rid.is_valid():
		p_rd.free_rid(p_rid)


static func _uniform_input_from_values(p_params: RID, p_textures: Array) -> Dictionary:
	return {"valid": true, "params_buffer": p_params, "textures": p_textures}


func _invalid(p_reason: String) -> Dictionary:
	_last_error = p_reason
	return {"valid": false, "abi_version": ABI_VERSION, "source": "decoded_ue_volumetric_lightmap_v1", "reason": p_reason}
