class_name FFogVolumeEnvironmentVisibilityProvider
extends RefCounted
## Uploads a small immutable environment-visibility packet for the current FRP
## frame. Sun ground transmission comes from matching FengSkyRuntime metadata;
## cloud shadow/AO textures are borrowed from the current FRP cloud frame.

const ABI_VERSION := 1
const DESCRIPTOR_SET := 4
const GROUND_BINDING := 0
const CLOUD_VISIBILITY_BINDING := 1
const CLOUD_SHADOW0_BINDING := 2
const CLOUD_SHADOW1_BINDING := 3
const CLOUD_RAW_AO_BINDING := 4
const GROUND_UBO_BYTES := 48
const CLOUD_VISIBILITY_FLOATS := 148
const CLOUD_VISIBILITY_UBO_BYTES := CLOUD_VISIBILITY_FLOATS * 4

var _rd: RenderingDevice
var _ground_and_sun_slots_ubo := RID()
var _cloud_visibility_ubo := RID()
var _sampler := RID()
var _neutral_cloud_texture := RID()
var _last_result: Dictionary = {}
var _last_error := ""


## Call after the native atmosphere and (when available) cloud producers have
## published this frame. `p_sky_metadata` is plain values plus the source sun
## RIDs; it must not contain Resources or textures. Output buffer/sampler/neutral
## texture RIDs are owned by this provider and borrowed until its next update or
## release. Cloud map RIDs are borrowed from ctx and are never freed here.
func update_frame_inputs(p_ctx: FRPPassContext, p_rd: RenderingDevice,
		p_normalized_frame: Dictionary, p_cloud_maps_current: bool,
		p_sky_metadata: Dictionary = {}) -> Dictionary:
	_last_error = ""
	_last_result.clear()
	if p_ctx == null:
		return _invalid_result("No FRP pass context was supplied.")
	if p_rd == null or p_rd != RenderingServer.get_rendering_device():
		return _invalid_result("Environment visibility must use the RenderingServer main RenderingDevice.")
	if not bool(p_normalized_frame.get("valid", false)) \
			or int(p_normalized_frame.get("abi_version", 0)) != 1:
		return _invalid_result("Normalized FRP volume frame input is invalid.")
	if not _ensure_resources(p_rd):
		return _invalid_result(_last_error if not _last_error.is_empty() else "Could not allocate environment visibility resources.")

	var atmosphere_rids: Array[RID] = [p_ctx.get_atmosphere_light_rid(0), p_ctx.get_atmosphere_light_rid(1)]
	var ground_packet := make_ground_packet(p_normalized_frame, p_sky_metadata, atmosphere_rids)
	var cloud_packet := _make_cloud_packet(p_ctx, p_rd, p_cloud_maps_current)
	var slots: PackedInt32Array = ground_packet["sun_slots"]
	slots[2] = 1 if bool(cloud_packet["current"]) else 0
	slots[3] = 1 if bool(ground_packet["metadata_valid"]) else 0
	var ground_bytes: PackedByteArray = ground_packet["ground_values"].to_byte_array()
	ground_bytes.append_array(slots.to_byte_array())
	var cloud_values: PackedFloat32Array = cloud_packet["parameters"]
	if ground_bytes.size() != GROUND_UBO_BYTES or cloud_values.size() * 4 != CLOUD_VISIBILITY_UBO_BYTES:
		return _invalid_result("Packed environment visibility UBO size does not match ABI v1.")
	if p_rd.buffer_update(_ground_and_sun_slots_ubo, 0, GROUND_UBO_BYTES, ground_bytes) != OK:
		return _invalid_result("Could not update the ground-transmittance UBO.")
	if p_rd.buffer_update(_cloud_visibility_ubo, 0, CLOUD_VISIBILITY_UBO_BYTES,
			cloud_values.to_byte_array()) != OK:
		return _invalid_result("Could not update the cloud-visibility UBO.")

	var uniforms := _make_uniforms(cloud_packet)
	if uniforms.size() != 5:
		return _invalid_result("Environment visibility descriptor list is incomplete.")
	_last_result = {
		"valid": true,
		"abi_version": ABI_VERSION,
		"descriptor_set": DESCRIPTOR_SET,
		"ground_binding": GROUND_BINDING,
		"cloud_visibility_binding": CLOUD_VISIBILITY_BINDING,
		"cloud_shadow0_binding": CLOUD_SHADOW0_BINDING,
		"cloud_shadow1_binding": CLOUD_SHADOW1_BINDING,
		"cloud_raw_ao_binding": CLOUD_RAW_AO_BINDING,
		"ground_and_sun_slots_ubo": _ground_and_sun_slots_ubo,
		"ground_and_sun_slots_ubo_bytes": GROUND_UBO_BYTES,
		"cloud_visibility_ubo": _cloud_visibility_ubo,
		"cloud_visibility_ubo_bytes": CLOUD_VISIBILITY_UBO_BYTES,
		"sampler": _sampler,
		"cloud_shadow0_texture": cloud_packet["textures"][0],
		"cloud_shadow1_texture": cloud_packet["textures"][1],
		"cloud_raw_ao_texture": cloud_packet["textures"][2],
		"uniforms": uniforms,
		"atmosphere_sun_directional_indices": PackedInt32Array([slots[0], slots[1]]),
		"metadata_valid": bool(ground_packet["metadata_valid"]),
		"cloud_maps_current": bool(cloud_packet["current"]),
		"cloud_diagnostic": str(cloud_packet["diagnostic"]),
		"sun_metadata_world_id": int(p_sky_metadata.get("world_id", 0)),
		"sun_metadata_provider_id": int(p_sky_metadata.get("provider_id", 0)),
		"sun_metadata_settings_revision": int(p_sky_metadata.get("settings_revision", 0)),
		"resource_ownership": "provider-owned UBO/sampler/neutral texture; all returned RIDs borrowed until next update or release",
		"cloud_texture_ownership": "borrowed from current FRP context; never freed by this provider",
	}
	return _last_result.duplicate(false)


func get_last_error() -> String:
	return _last_error


func release() -> void:
	var rd := _rd
	var owned := take_owned_rids()
	if rd != null:
		for rid in owned:
			_free_rid(rd, rid)
	_last_error = ""


func get_owned_rids() -> Array[RID]:
	return _collect_owned_rids(false)


func take_owned_rids() -> Array[RID]:
	return _collect_owned_rids(true)


func _collect_owned_rids(p_clear: bool) -> Array[RID]:
	var result: Array[RID] = []
	var seen: Dictionary = {}
	for rid in [_ground_and_sun_slots_ubo, _cloud_visibility_ubo, _sampler,
			_neutral_cloud_texture]:
		if rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			result.append(rid)
	if p_clear:
		_rd = null
		_ground_and_sun_slots_ubo = RID()
		_cloud_visibility_ubo = RID()
		_sampler = RID()
		_neutral_cloud_texture = RID()
		_last_result.clear()
		_last_error = ""
	return result


## CPU-verifiable join and packing routine. Ground transmission is accepted only
## if the same sun RID is registered by the current context and occurs exactly
## once in the current native directional-light array.
static func make_ground_packet(p_frame: Dictionary, p_sky_metadata: Dictionary,
		p_atmosphere_light_rids: Array[RID]) -> Dictionary:
	var ground := PackedFloat32Array([
		1.0, 1.0, 1.0, 0.0,
		1.0, 1.0, 1.0, 0.0,
	])
	var slots := PackedInt32Array([-1, -1, 0, 0])
	var metadata_valid := _valid_metadata_header(p_frame, p_sky_metadata)
	var native_rids: Variant = p_frame.get("directional_light_base_rids", [])
	if p_atmosphere_light_rids.size() == 2 and native_rids is Array:
		for atmo_slot in 2:
			var context_sun: RID = p_atmosphere_light_rids[atmo_slot]
			var native_index := _find_unique_rid(native_rids, context_sun)
			if native_index < 0:
				continue
			slots[atmo_slot] = native_index
			if not metadata_valid:
				continue
			var metadata_key := "sun_light_rid" if atmo_slot == 0 else "secondary_sun_light_rid"
			var ground_key := "sun_ground_transmittance" if atmo_slot == 0 else "secondary_sun_ground_transmittance"
			var source_value: Variant = p_sky_metadata.get(metadata_key, RID())
			if not source_value is RID or not context_sun.is_valid() or source_value != context_sun:
				continue
			var transmittance_value: Variant = p_sky_metadata.get(ground_key)
			if not transmittance_value is Vector3 or not transmittance_value.is_finite():
				continue
			var transmittance: Vector3 = transmittance_value.clamp(Vector3.ZERO, Vector3.ONE)
			var base := atmo_slot * 4
			ground[base] = transmittance.x
			ground[base + 1] = transmittance.y
			ground[base + 2] = transmittance.z
			ground[base + 3] = 1.0
	return {
		"ground_values": ground,
		"sun_slots": slots,
		"metadata_valid": metadata_valid,
		"layout": "vec4 primary_ground, vec4 secondary_ground, ivec4 native_directional_indices_cloud_current_metadata_valid",
		"byte_size": GROUND_UBO_BYTES,
	}


## Invalid/non-current cloud data is always neutral. This deliberately does not
## retain a prior frame's matrices or validity bits.
static func normalize_cloud_parameters(p_parameters: Variant, p_cloud_maps_current: bool,
		p_shadow0_valid: bool, p_shadow1_valid: bool, p_raw_ao_valid: bool) -> Dictionary:
	var result := PackedFloat32Array()
	result.resize(CLOUD_VISIBILITY_FLOATS)
	result.fill(0.0)
	result[140] = -1.0
	result[141] = -1.0
	if not p_cloud_maps_current or not p_parameters is PackedFloat32Array \
			or p_parameters.size() != CLOUD_VISIBILITY_FLOATS:
		return {"parameters": result, "current": false, "diagnostic": "Cloud maps are absent, stale, or have an incompatible packet; neutral visibility is used."}
	for index in CLOUD_VISIBILITY_FLOATS:
		if not is_finite(p_parameters[index]):
			return {"parameters": result, "current": false, "diagnostic": "Cloud visibility packet contains a non-finite value; neutral visibility is used."}
	result = p_parameters.duplicate()
	for slot in 2:
		var map_index := 140 + slot
		if result[map_index] < -0.5 or result[map_index] > 1.5:
			result[map_index] = -1.0
		var valid_index := 142 + slot
		var texture_valid := p_shadow0_valid if slot == 0 else p_shadow1_valid
		result[valid_index] = 1.0 if texture_valid and result[valid_index] > 0.5 else 0.0
	if not p_raw_ao_valid:
		result[144] = 0.0
	else:
		result[144] = 1.0 if result[144] > 0.5 else 0.0
	for index in range(145, CLOUD_VISIBILITY_FLOATS):
		result[index] = 0.0
	return {"parameters": result, "current": true, "diagnostic": ""}


static func _valid_metadata_header(p_frame: Dictionary, p_metadata: Dictionary) -> bool:
	var world_id := int(p_metadata.get("world_id", 0))
	var provider_id := int(p_metadata.get("provider_id", 0))
	var settings_revision := int(p_metadata.get("settings_revision", -1))
	# Godot instance IDs may use the signed high bit; only zero is a missing ID.
	if world_id == 0 or provider_id == 0 or settings_revision < 0:
		return false
	if not p_frame.has("world_id") or int(p_frame.get("world_id", 0)) != world_id:
		return false
	return true


static func _find_unique_rid(p_rids: Array, p_target: RID) -> int:
	if not p_target.is_valid():
		return -1
	var found := -1
	for index in p_rids.size():
		var value: Variant = p_rids[index]
		if value is RID and value == p_target:
			if found >= 0:
				return -1
			found = index
	return found


func _make_cloud_packet(p_ctx: FRPPassContext, p_rd: RenderingDevice,
		p_cloud_maps_current: bool) -> Dictionary:
	var neutral := _neutral_cloud_texture
	var textures: Array[RID] = [neutral, neutral, neutral]
	var shadow0_valid := false
	var shadow1_valid := false
	var raw_ao_valid := false
	if p_cloud_maps_current:
		shadow0_valid = _is_sampleable_2d(p_rd, p_ctx.get_cloud_output(3))
		shadow1_valid = _is_sampleable_2d(p_rd, p_ctx.get_cloud_output(4))
		raw_ao_valid = _is_sampleable_2d(p_rd, p_ctx.get_cloud_output(7))
		if shadow0_valid:
			textures[0] = p_ctx.get_cloud_output(3)
		if shadow1_valid:
			textures[1] = p_ctx.get_cloud_output(4)
		if raw_ao_valid:
			textures[2] = p_ctx.get_cloud_output(7)
	var raw_parameters := PackedFloat32Array()
	if p_cloud_maps_current:
		raw_parameters = p_ctx.get_cloud_atmosphere_parameters()
	var normalized := normalize_cloud_parameters(raw_parameters, p_cloud_maps_current,
			shadow0_valid, shadow1_valid, raw_ao_valid)
	if not bool(normalized["current"]):
		textures[0] = neutral
		textures[1] = neutral
		textures[2] = neutral
	return {
		"parameters": normalized["parameters"],
		"current": bool(normalized["current"]),
		"diagnostic": str(normalized["diagnostic"]),
		"textures": textures,
	}


func _make_uniforms(p_cloud_packet: Dictionary) -> Array[RDUniform]:
	var uniforms: Array[RDUniform] = []
	var ground_uniform := RDUniform.new()
	ground_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	ground_uniform.binding = GROUND_BINDING
	ground_uniform.add_id(_ground_and_sun_slots_ubo)
	uniforms.append(ground_uniform)
	var cloud_uniform := RDUniform.new()
	cloud_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	cloud_uniform.binding = CLOUD_VISIBILITY_BINDING
	cloud_uniform.add_id(_cloud_visibility_ubo)
	uniforms.append(cloud_uniform)
	var textures: Array = p_cloud_packet.get("textures", [_neutral_cloud_texture, _neutral_cloud_texture, _neutral_cloud_texture])
	var texture_bindings := [CLOUD_SHADOW0_BINDING, CLOUD_SHADOW1_BINDING, CLOUD_RAW_AO_BINDING]
	for index in 3:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = texture_bindings[index]
		uniform.add_id(_sampler)
		uniform.add_id(textures[index])
		uniforms.append(uniform)
	return uniforms


func _ensure_resources(p_rd: RenderingDevice) -> bool:
	if _rd != null and _rd != p_rd:
		release()
	_rd = p_rd
	if not _ground_and_sun_slots_ubo.is_valid():
		_ground_and_sun_slots_ubo = p_rd.uniform_buffer_create(GROUND_UBO_BYTES)
	if not _cloud_visibility_ubo.is_valid():
		_cloud_visibility_ubo = p_rd.uniform_buffer_create(CLOUD_VISIBILITY_UBO_BYTES)
	if not _sampler.is_valid():
		var sampler_state := RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_sampler = p_rd.sampler_create(sampler_state)
	if not _neutral_cloud_texture.is_valid():
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		format.width = 1
		format.height = 1
		format.depth = 1
		format.array_layers = 1
		format.mipmaps = 1
		format.samples = RenderingDevice.TEXTURE_SAMPLES_1
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		_neutral_cloud_texture = p_rd.texture_create(format, RDTextureView.new(),
				[PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])])
	return _ground_and_sun_slots_ubo.is_valid() and _cloud_visibility_ubo.is_valid() \
			and _sampler.is_valid() and _neutral_cloud_texture.is_valid() \
			and p_rd.texture_is_valid(_neutral_cloud_texture)


func _is_sampleable_2d(p_rd: RenderingDevice, p_texture: RID) -> bool:
	if not p_texture.is_valid() or not p_rd.texture_is_valid(p_texture):
		return false
	var format: RDTextureFormat = p_rd.texture_get_format(p_texture)
	return format != null and format.texture_type == RenderingDevice.TEXTURE_TYPE_2D \
			and format.width > 0 and format.height > 0 \
			and (format.usage_bits & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) != 0


func _invalid_result(p_reason: String) -> Dictionary:
	_last_error = p_reason
	_last_result = {"valid": false, "abi_version": ABI_VERSION, "reason": p_reason}
	return _last_result.duplicate(false)


static func _free_rid(p_rd: RenderingDevice, p_rid: RID) -> void:
	if p_rid.is_valid():
		p_rd.free_rid(p_rid)
