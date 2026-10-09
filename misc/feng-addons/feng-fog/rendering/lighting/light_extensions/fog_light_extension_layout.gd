class_name FFogLightExtensionLayout
extends RefCounted
## CPU ABI and mapping helpers for FRP per-light extension records.

const ABI_VERSION := 2
const FRAME_INPUT_ABI_VERSION := 1
const KIND_OMNI := 0
const KIND_SPOT := 1
const KIND_AREA := 2
const KIND_DIRECTIONAL := 3
const KIND_NAMES := ["omni", "spot", "area", "directional"]
const MAPPING_NONE := 0
const MAPPING_DIRECTIONAL_ORTHOGRAPHIC := 1
const MAPPING_SPOT_PERSPECTIVE := 2
const MAPPING_OMNI_DUAL_PARABOLOID := 3
const MAPPING_AREA_PLANE := 4
const SHADOW_INHERIT_NATIVE := 0
const SHADOW_DISABLED := 1
const SHADOW_HARDWARE_RT_OPT_IN := 2
const FEATURE_COOKIE := 1
const RECORD_BYTES := 144
const HEADER_BYTES := 16
const FRAME_SET_INDEX := 3
const RECORDS_BINDING := 0
const COOKIE_TEXTURE_BINDING := 1
const HEADER_BINDING := 2
const COOKIE_SIZE := 256


static func collect_native_rows(p_frame: Dictionary) -> Dictionary:
	if int(p_frame.get("abi_version", 0)) != FRAME_INPUT_ABI_VERSION or not bool(p_frame.get("valid", false)):
		return _invalid("FRP volume frame input is not valid ABI v1.")
	var descriptors := [
		{"kind": KIND_OMNI, "count_key": "omni_light_count", "rids_key": "omni_light_base_rids"},
		{"kind": KIND_SPOT, "count_key": "spot_light_count", "rids_key": "spot_light_base_rids"},
		{"kind": KIND_AREA, "count_key": "area_light_count", "rids_key": "area_light_base_rids"},
		{"kind": KIND_DIRECTIONAL, "count_key": "directional_light_count", "rids_key": "directional_light_base_rids"},
	]
	var rows: Array[Dictionary] = []
	var seen: Dictionary = {}
	for descriptor: Dictionary in descriptors:
		var count := int(p_frame.get(descriptor.count_key, -1))
		var rids: Variant = p_frame.get(descriptor.rids_key)
		if count < 0 or not rids is Array or rids.size() != count:
			return _invalid("Native light RID list/count mismatch for %s." % KIND_NAMES[descriptor.kind])
		for index in rids.size():
			var light_rid: Variant = rids[index]
			if not light_rid is RID or not light_rid.is_valid():
				return _invalid("Native light list contains an invalid RID for %s." % KIND_NAMES[descriptor.kind])
			if seen.has(light_rid):
				return _invalid("Native light RID occurs more than once in the frame.")
			seen[light_rid] = true
			rows.append({
				"light_rid": light_rid,
				"native_kind": descriptor.kind,
				"native_index": index,
				"mapping_type": MAPPING_NONE,
				"mapping_range_m": 0.0,
				"tan_half_spot_angle": 0.0,
				"area_half_size_m": Vector2.ZERO,
				"mapping_scale": Vector2.ONE,
				"mapping_offset": Vector2.ZERO,
				"world_to_light": Transform3D.IDENTITY,
				"barn_door_enabled": false,
				"barn_door_cos_angle": 1.0,
				"barn_door_length_m": 0.0,
				"source_length_m": 0.0,
				"capsule_axis_local": 1,
				"cookie_strength": 0.0,
				"cookie_texture_rd_rid": RID(),
				"cookie_texture_resource_id": 0,
				"cookie_texture_revision": 0,
				"cookie_srgb": true,
				"shadow_policy": SHADOW_INHERIT_NATIVE,
				"source_extension_id": 0,
				"source_revision": 0,
			})
	return {
		"valid": true,
		"abi_version": ABI_VERSION,
		"frame_generation": int(p_frame.get("frame_generation", 0)),
		"native_light_count": rows.size(),
		"native_order": KIND_NAMES.duplicate(),
		"rows": rows,
	}


static func pack_record(p_row: Dictionary, p_cookie_layer: int = -1) -> PackedByteArray:
	var values := PackedFloat32Array()
	values.resize(28)
	values.fill(0.0)
	var transform: Transform3D = p_row.get("world_to_light", Transform3D.IDENTITY)
	var columns := [
		transform.basis.x,
		transform.basis.y,
		transform.basis.z,
		transform.origin,
	]
	for column in 4:
		var vector: Vector3 = columns[column]
		var base := column * 4
		values[base] = vector.x
		values[base + 1] = vector.y
		values[base + 2] = vector.z
		values[base + 3] = 1.0 if column == 3 else 0.0
	var mapping_scale: Vector2 = p_row.get("mapping_scale", Vector2.ONE)
	var mapping_offset: Vector2 = p_row.get("mapping_offset", Vector2.ZERO)
	var area_half_size: Vector2 = p_row.get("area_half_size_m", Vector2.ZERO)
	values[16] = float(p_row.get("mapping_range_m", 0.0))
	values[17] = float(p_row.get("tan_half_spot_angle", 0.0))
	values[18] = area_half_size.x
	values[19] = area_half_size.y
	values[20] = mapping_scale.x
	values[21] = mapping_scale.y
	values[22] = mapping_offset.x
	values[23] = mapping_offset.y
	values[24] = float(p_row.get("barn_door_cos_angle", 1.0))
	values[25] = float(p_row.get("barn_door_length_m", 0.0))
	values[26] = 1.0 if bool(p_row.get("barn_door_enabled", false)) \
			and int(p_row.get("native_kind", -1)) == KIND_AREA else 0.0
	values[27] = clampf(float(p_row.get("cookie_strength", 0.0)), 0.0, 1.0) \
			if p_cookie_layer >= 0 else 0.0
	var bytes := values.to_byte_array()
	var mode_flags := PackedByteArray()
	mode_flags.resize(16)
	mode_flags.encode_u32(0, clampi(int(p_row.get("mapping_type", MAPPING_NONE)), 0, MAPPING_AREA_PLANE))
	mode_flags.encode_u32(4, p_cookie_layer if p_cookie_layer >= 0 else 0xFFFFFFFF)
	mode_flags.encode_u32(8, clampi(int(p_row.get("shadow_policy", SHADOW_INHERIT_NATIVE)), 0, SHADOW_HARDWARE_RT_OPT_IN))
	var features := FEATURE_COOKIE if p_cookie_layer >= 0 and values[27] > 0.0 else 0
	mode_flags.encode_u32(12, features)
	bytes.append_array(mode_flags)
	var capsule_shape := PackedFloat32Array([
			maxf(float(p_row.get("source_length_m", 0.0)), 0.0),
			float(clampi(int(p_row.get("capsule_axis_local", 1)), 0, 2)),
			0.0, 0.0,
	])
	bytes.append_array(capsule_shape.to_byte_array())
	return bytes


static func pack_header(p_record_count: int, p_cookie_layer_count: int,
		p_frame_generation: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(HEADER_BYTES)
	bytes.encode_u32(0, ABI_VERSION)
	bytes.encode_u32(4, maxi(p_record_count, 0))
	bytes.encode_u32(8, maxi(p_cookie_layer_count, 0))
	bytes.encode_u32(12, p_frame_generation & 0xFFFFFFFF)
	return bytes


static func neutral_record() -> PackedByteArray:
	return pack_record({
		"world_to_light": Transform3D.IDENTITY,
		"mapping_type": MAPPING_NONE,
		"mapping_scale": Vector2.ONE,
		"barn_door_cos_angle": 1.0,
		"shadow_policy": SHADOW_INHERIT_NATIVE,
		"source_length_m": 0.0,
		"capsule_axis_local": 1,
	})


static func cookie_uv(p_mapping_type: int, p_local_position: Vector3, p_range_m: float,
		p_tan_half_spot_angle: float, p_area_half_size: Vector2,
		p_scale: Vector2 = Vector2.ONE, p_offset: Vector2 = Vector2.ZERO) -> Dictionary:
	if not p_local_position.is_finite() or not is_finite(p_range_m) or p_range_m <= 0.0 \
			or not p_scale.is_finite() or not p_offset.is_finite():
		return {"valid": false, "reason": "Cookie projection input is invalid."}
	var uv := Vector2.ZERO
	match p_mapping_type:
		MAPPING_DIRECTIONAL_ORTHOGRAPHIC:
			uv = Vector2(p_local_position.x, p_local_position.y) / (2.0 * p_range_m) + Vector2.ONE * 0.5
		MAPPING_SPOT_PERSPECTIVE:
			var depth := -p_local_position.z
			if depth <= 0.0001 or depth > p_range_m or p_tan_half_spot_angle <= 0.0001:
				return {"valid": false, "reason": "Point is outside the spot projection."}
			uv = Vector2(p_local_position.x, p_local_position.y) \
					/ (2.0 * depth * p_tan_half_spot_angle) + Vector2.ONE * 0.5
		MAPPING_OMNI_DUAL_PARABOLOID:
			var distance := p_local_position.length()
			if distance <= 0.0001 or distance > p_range_m:
				return {"valid": false, "reason": "Point is outside the omni range."}
			var direction := p_local_position / distance
			uv = Vector2(direction.x, direction.y) / (1.0 + absf(direction.z)) * 0.5 + Vector2.ONE * 0.5
		MAPPING_AREA_PLANE:
			if p_area_half_size.x <= 0.0001 or p_area_half_size.y <= 0.0001 \
					or -p_local_position.z <= 0.0 or -p_local_position.z > p_range_m:
				return {"valid": false, "reason": "Point is outside the area projection."}
			uv = Vector2(p_local_position.x / (2.0 * p_area_half_size.x),
					-p_local_position.y / (2.0 * p_area_half_size.y)) + Vector2.ONE * 0.5
		_:
			return {"valid": false, "reason": "Cookie mapping is disabled."}
	uv = uv * p_scale + p_offset
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return {"valid": false, "reason": "Projected coordinate is outside the cookie bounds."}
	return {"valid": true, "uv": uv}


static func is_resource_identity_valid(p_id: int) -> bool:
	# Godot Object instance IDs are signed; negative high-bit tagged IDs are valid.
	return p_id != 0


static func _invalid(p_reason: String) -> Dictionary:
	return {"valid": false, "reason": p_reason, "rows": []}

