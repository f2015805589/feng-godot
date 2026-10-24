@tool
class_name FMagicGIData
extends Resource
## Immutable v6 surface PRT transport. Primary sky visibility stays separate
## from secondary transport so a current SkyLight can be replaced without
## baking its radiance into the geometry response.

const Visibility = preload("feng_magic_gi_visibility.gd")
const SHFilter = preload("feng_magic_gi_sh_filter.gd")
const DirectionalData = preload("feng_magic_gi_directional_data.gd")
const FORMAT_VERSION := 6
const MOMENT_FORMAT_VERSION := 5
const PRIMARY_SKY_FORMAT_VERSION := 4
const EMITTER_FORMAT_VERSION := 3
const LEGACY_FORMAT_VERSION := 2
const SAMPLER_REVISION := 5
const MAX_GRID_AXIS := 64
const MAX_EMITTERS := 32
const ATLAS_COLUMNS := 32
const TRANSFER_TEXELS_PER_POINT := 7
const PRIMARY_SKY_TEXELS_PER_POINT := 3
const GEOMETRY_TEXELS_PER_POINT := 3
const VISIBILITY_TILE_SIZE := 8
const VISIBILITY_MOMENT_CHANNELS := 2
const VISIBILITY_TEXELS_PER_PROBE := VISIBILITY_TILE_SIZE * VISIBILITY_TILE_SIZE
const CELL_CAPACITY := 8
const CELL_BOUNDARY_EPSILON := 0.00001
const SH_Y00 := 0.2820947918
## Revision 2 stores the complete diffuse incident field: secondary transfer
## plus visibility-filtered primary Sky. Direct DirectionalLight remains live.
const BAKED_INDIRECT_SH_REVISION := 2
## Algorithm metadata distinguishes old rev-2 SH9 directional projection from the
## bake-only exact directional-secondary estimator without changing the payload.
const BAKED_INDIRECT_SH_ALGORITHM_LEGACY := "legacy_sh9_directional_v2"
const BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE := "exact_directional_secondary_nee_v1"
const BAKED_DIRECTIONAL_SOURCE_SCHEMA_VERSION := 1
const BAKED_BOUNDARY_TENSOR_SCHEMA_VERSION := 1
const BAKED_BOUNDARY_TENSOR_ALGORITHM := "closed_mesh_boundary_tensor_v1"
const BAKED_BOUNDARY_TENSOR_LAYOUT_VERSION := 17
const BAKED_BOUNDARY_TENSOR_LEVEL_COUNT := 3
const BAKED_BOUNDARY_TENSOR_TERMS := 9
const BAKED_BOUNDARY_TENSOR_VALUES_PER_RECORD := BAKED_BOUNDARY_TENSOR_TERMS * 3

@export_storage var format_version := 0
@export_storage var grid_dims := Vector3i.ZERO
@export_storage var volume_transform := Transform3D.IDENTITY
@export_storage var world_to_grid := Transform3D.IDENTITY
@export_storage var volume_size := Vector3.ZERO
# Keep the legacy storage default: older 1 m bakes omit this field in .tscn files.
@export_storage var spacing := 1.0
@export_storage var adaptive_placement := false
@export_storage var minimum_probe_spacing := 0.25
@export_storage var probe_spacings := PackedFloat32Array()
## Adaptive cells store [offset, count] into the packed cell_indices list.
@export_storage var cell_ranges := PackedInt32Array()
@export_storage var surface_offset := 0.03
@export_storage var bake_samples := 0
@export_storage var bake_bounces := 0
@export_storage var bake_distance := 0.0
@export_storage var terrain_reflectance := 0.0
@export_storage var material_reflectance := 0.0
@export_storage var scene_signature := 0
## Probe-placement algorithm version. Missing legacy storage defaults to zero.
@export_storage var placement_layout_revision := 0
## Fingerprint of transport-relevant static source content, captured at bake
## and load-validation boundaries. Ordinary polling uses a separate quick
## signature. Older resources omit this and keep their legacy staleness path.
@export_storage var scene_watch_signature := 0
## 0 is legacy absolute-path signature; 1 is relative to the scene root.
## Older resources omit this field and retain the legacy validation path.
@export_storage var scene_watch_signature_schema_version := 0
@export_storage var positions := PackedVector3Array()
## Optional stable world-surface identities used by streamed pages. Legacy v2-v6
## resources omit this and keep their original index-based sampler sequence.
@export_storage var stable_probe_ids := PackedInt64Array()
## Exact world-space surface anchors; positions stores the actual sample centers.
@export_storage var surface_positions := PackedVector3Array()
@export_storage var normals := PackedVector3Array()
@export_storage var transfer := PackedFloat32Array()
## Probe-major SH9 coefficients for the first-ray sky visibility/irradiance.
## These are independent of radiance and have been present since v4 bakes.
@export_storage var primary_sky_visibility := PackedFloat32Array()
## Probe-major 8x8 octahedral first and second radial hit-distance moments.
@export_storage var visibility_moments := PackedFloat32Array()
## Depth-first static geometry BVH: two vec4s per node, three per triangle.
@export_storage var visibility_nodes := PackedFloat32Array()
@export_storage var visibility_triangles := PackedFloat32Array()
## Stable root-relative NodePath + surface-index bindings, in transport order.
@export_storage var emitter_keys := PackedStringArray()
## Static texture/UV/geometry mapping fingerprints; live emission values are excluded.
@export_storage var emitter_static_signatures := PackedInt64Array()
## Emitter-major: (emitter * probe_count + probe) * 6 + term * 3 + channel.
## term 0 is uniform source radiance; term 1 is static emission-texture modulation.
@export_storage var emitter_transport := PackedFloat32Array()
## Persistent total baked indirect incident-radiance SH9 RGB field. Probe-major,
## world-axis, linear HDR radiance, 27 floats per probe. Revision 2 combines
## secondary transport with geometry-visibility-filtered primary Sky. Direct
## DirectionalLight and the Sky background remain live in the renderer.
@export_storage var baked_indirect_sh_revision := 0
@export_storage var baked_indirect_sh := PackedFloat32Array()
## Empty means a legacy revision-2 SH9-directional bake. Runtime consumes the
## same 27-float payload for either recognized algorithm.
@export_storage var baked_indirect_sh_algorithm := ""
@export_storage var baked_indirect_directional_source_signature := ""
@export_storage var baked_indirect_directional_source_provenance: Dictionary = {}
## Optional sparse layout-17 boundary tensor overrides. Keys are packed as
## [level, logical_x, logical_y, logical_z]; values are 9 RGB terms per key
## in [Ex,Ey,Ez,Lx,Ly,Lz,Qxy,Qyz,Qxz] order. Missing legacy fields mean no overrides.
@export_storage var baked_boundary_tensor_schema_version := 0
@export_storage var baked_boundary_tensor_keys := PackedInt32Array()
@export_storage var baked_boundary_tensor_coefficients := PackedFloat32Array()
@export_storage var baked_boundary_tensor_provenance: Dictionary = {}
@export_storage var baked_boundary_tensor_signature := ""
var _baked_boundary_tensor_validation_cached := false
var _baked_boundary_tensor_validation_result := false
## Bake-time primary Sky provenance. Kept separate from geometry validation so
## legacy resources remain readable, but backend-1 upload requires valid data.
@export_storage var baked_indirect_sky_provenance: Dictionary = {}
var _sky_provenance_validation_cached := false
var _sky_provenance_validation_result := false
var _baked_indirect_sh_validation_cached := false
var _baked_indirect_sh_validation_result := false
var _baked_indirect_payload_validation_cached := false
var _baked_indirect_payload_validation_result := false
var _baked_directional_provenance_validation_cached := false
var _baked_directional_provenance_validation_result := false
## Worker-only scratch; intentionally not exported or serialized.
var bake_exact_directional_secondary := PackedFloat32Array()
var bake_exact_directional_secondary_valid := false
var _bake_exact_directional_probe_complete := PackedByteArray()
## Bake-time radiance snapshots are diagnostic only; changes request rebake,
## but never invalidate the field or trigger runtime relighting.
@export_storage var baked_indirect_lighting_signature := 0
@export_storage var baked_indirect_emission_signature := 0
@export_storage var cell_indices := PackedInt32Array()
@export_storage var bake_version := 0
## Optional independently versioned spherical transfer. Absent in saved surface
## bakes; those keep their exact surface gather instead of fabricated SH data.
@export_storage var directional: Resource

# Old names are retained only so legacy .tres files still deserialize. Their
# radiance values never masquerade as geometry-only transport.
@export_storage var sh := PackedFloat32Array()
@export_storage var slot_of_probe := PackedInt32Array()

static func sh_basis(dir: Vector3) -> PackedFloat32Array:
	var c := PackedFloat32Array()
	c.resize(9)
	c[0] = SH_Y00
	c[1] = 0.4886025119 * dir.y
	c[2] = 0.4886025119 * dir.z
	c[3] = 0.4886025119 * dir.x
	c[4] = 1.0925484306 * dir.x * dir.y
	c[5] = 1.0925484306 * dir.y * dir.z
	c[6] = 0.3153915653 * (3.0 * dir.z * dir.z - 1.0)
	c[7] = 1.0925484306 * dir.x * dir.z
	c[8] = 0.5462742153 * (dir.x * dir.x - dir.y * dir.y)
	return c

## Wraps the 32-bit geometry fingerprint with the persisted sampler revision.
static func signature_for_geometry(geometry_signature: int) -> int:
	return (SAMPLER_REVISION << 32) | (geometry_signature & 0xffffffff)

## The upper word records the sampler revision. The lower word remains the
## persisted placement fingerprint, so compatible older bakes can be checked
## against current geometry without expiring only because the sampler changed.
static func geometry_signature_matches(saved_signature: int, geometry_signature: int) -> bool:
	return (saved_signature & 0xffffffff) == (geometry_signature & 0xffffffff)

static func sampler_revision_for_signature(saved_signature: int) -> int:
	return (saved_signature >> 32) & 0xffffffff

func probe_count() -> int:
	return positions.size()

func _invalidate_baked_indirect_sh_validation_cache() -> void:
	_sky_provenance_validation_cached = false
	_sky_provenance_validation_result = false
	_baked_indirect_sh_validation_cached = false
	_baked_indirect_sh_validation_result = false
	_baked_indirect_payload_validation_cached = false
	_baked_indirect_payload_validation_result = false
	_baked_directional_provenance_validation_cached = false
	_baked_directional_provenance_validation_result = false
	# Resource assignment and changed() also use this invalidator. Preserve serialized
	# sidecars and revalidate their SH/trace hashes lazily at the next bake/cache boundary.
	_invalidate_baked_boundary_tensor_validation_cache()

func has_baked_indirect_sh() -> bool:
	if not _baked_indirect_sh_validation_cached:
		_baked_indirect_sh_validation_result = probe_count() > 0 \
				and baked_indirect_sh_revision == BAKED_INDIRECT_SH_REVISION \
				and baked_indirect_sh.size() == probe_count() * 27 \
				and baked_indirect_sh_is_valid() \
				and baked_indirect_sky_provenance_is_valid() \
				and baked_indirect_directional_provenance_is_valid()
		_baked_indirect_sh_validation_cached = true
	return _baked_indirect_sh_validation_result \
			and baked_indirect_sh_revision == BAKED_INDIRECT_SH_REVISION \
			and baked_indirect_sh.size() == probe_count() * 27

func set_baked_boundary_tensor_records(payload: Dictionary) -> bool:
	var input := payload.duplicate(true)
	var provenance_value: Variant = input.get("provenance", null)
	if not provenance_value is Dictionary:
		_clear_baked_boundary_tensor_records()
		return false
	var provenance: Dictionary = provenance_value.duplicate(true)
	var expected_placement_signature := int(scene_signature) & 0xffffffff
	if int(provenance.get("placement_scene_signature_u32", -1)) != expected_placement_signature:
		_clear_baked_boundary_tensor_records()
		return false
	var expected_trace_geometry_sha256 := _sha256_packed_float32(visibility_triangles)
	if expected_trace_geometry_sha256.is_empty() \
			or String(provenance.get("trace_geometry_sha256", "")) != expected_trace_geometry_sha256:
		_clear_baked_boundary_tensor_records()
		return false
	input["provenance"] = provenance
	input["schema_version"] = int(provenance.get("schema_version", 0))
	var parsed := _parse_baked_boundary_tensor_payload(input)
	if not bool(parsed.get("valid", false)):
		_clear_baked_boundary_tensor_records()
		return false
	baked_boundary_tensor_schema_version = BAKED_BOUNDARY_TENSOR_SCHEMA_VERSION
	baked_boundary_tensor_keys = parsed["keys"]
	baked_boundary_tensor_coefficients = parsed["coefficients"]
	baked_boundary_tensor_provenance = parsed["provenance"]
	baked_boundary_tensor_signature = _baked_boundary_tensor_payload_signature(
		baked_boundary_tensor_keys, baked_boundary_tensor_coefficients,
		baked_boundary_tensor_provenance)
	_invalidate_baked_boundary_tensor_validation_cache()
	return has_baked_boundary_tensor_records()

func has_baked_boundary_tensor_records() -> bool:
	if not _baked_boundary_tensor_validation_cached:
		_baked_boundary_tensor_validation_result = _validate_baked_boundary_tensor_records()
		_baked_boundary_tensor_validation_cached = true
	return _baked_boundary_tensor_validation_result

func get_baked_boundary_tensor_records_for_runtime() -> Dictionary:
	if not has_baked_boundary_tensor_records():
		return {"valid": false, "reason": "boundary_tensor_sidecar_unavailable"}
	return {"valid": true, "schema_version": baked_boundary_tensor_schema_version,
		"keys": baked_boundary_tensor_keys, "coefficients": baked_boundary_tensor_coefficients,
		"provenance": baked_boundary_tensor_provenance,
		"signature": baked_boundary_tensor_signature}

func _invalidate_baked_boundary_tensor_validation_cache() -> void:
	_baked_boundary_tensor_validation_cached = false
	_baked_boundary_tensor_validation_result = false

## Call before replacing baked SH or trace geometry on an existing Resource.
## Published runtime Data is otherwise immutable; clearing the record set makes
## the next cache update restore ordinary gather values across the current window.
func invalidate_baked_boundary_tensor_records() -> void:
	_clear_baked_boundary_tensor_records()

func _clear_baked_boundary_tensor_records() -> void:
	baked_boundary_tensor_schema_version = 0
	baked_boundary_tensor_keys.clear()
	baked_boundary_tensor_coefficients.clear()
	baked_boundary_tensor_provenance.clear()
	baked_boundary_tensor_signature = ""
	_invalidate_baked_boundary_tensor_validation_cache()

func _validate_baked_boundary_tensor_records() -> bool:
	var parsed := _parse_baked_boundary_tensor_payload({
		"schema_version": baked_boundary_tensor_schema_version,
		"keys": baked_boundary_tensor_keys,
		"coefficients": baked_boundary_tensor_coefficients,
		"provenance": baked_boundary_tensor_provenance})
	if not bool(parsed.get("valid", false)):
		return false
	return baked_boundary_tensor_signature == _baked_boundary_tensor_payload_signature(
		baked_boundary_tensor_keys, baked_boundary_tensor_coefficients,
		baked_boundary_tensor_provenance)

func _parse_baked_boundary_tensor_payload(payload: Dictionary) -> Dictionary:
	if int(payload.get("schema_version", 0)) != BAKED_BOUNDARY_TENSOR_SCHEMA_VERSION:
		return {"valid": false, "reason": "unsupported_schema"}
	var keys_value: Variant = payload.get("keys", null)
	var coefficients_value: Variant = payload.get("coefficients", null)
	var provenance_value: Variant = payload.get("provenance", null)
	if not keys_value is PackedInt32Array or not coefficients_value is PackedFloat32Array \
			 or not provenance_value is Dictionary:
		return {"valid": false, "reason": "invalid_payload_types"}
	var keys: PackedInt32Array = keys_value
	var coefficients: PackedFloat32Array = coefficients_value
	var provenance: Dictionary = provenance_value
	var record_count := keys.size() / 4
	if keys.size() % 4 != 0 or coefficients.size() != record_count * BAKED_BOUNDARY_TENSOR_VALUES_PER_RECORD:
		return {"valid": false, "reason": "record_shape_mismatch"}
	if not _baked_boundary_tensor_provenance_matches(provenance):
		return {"valid": false, "reason": "provenance_mismatch"}
	var dedup_keys := PackedInt32Array()
	var dedup_coefficients := PackedFloat32Array()
	var seen: Dictionary = {}
	for record_index in record_count:
		var offset := record_index * 4
		var level := keys[offset]
		var x := keys[offset + 1]
		var y := keys[offset + 2]
		var z := keys[offset + 3]
		if level < 0 or level >= BAKED_BOUNDARY_TENSOR_LEVEL_COUNT:
			return {"valid": false, "reason": "record_level_out_of_range"}
		var key := Vector4i(x, y, z, level)
		var value_offset := record_index * BAKED_BOUNDARY_TENSOR_VALUES_PER_RECORD
		for lane in BAKED_BOUNDARY_TENSOR_VALUES_PER_RECORD:
			if not is_finite(coefficients[value_offset + lane]):
				return {"valid": false, "reason": "record_nonfinite"}
		if seen.has(key):
			var previous_offset: int = int(seen[key])
			for lane in BAKED_BOUNDARY_TENSOR_VALUES_PER_RECORD:
				var previous := dedup_coefficients[previous_offset + lane]
				var current := coefficients[value_offset + lane]
				var tolerance := 1e-5 * maxf(1.0, maxf(absf(previous), absf(current)))
				if absf(previous - current) > tolerance:
					return {"valid": false, "reason": "conflicting_duplicate_record"}
			continue
		seen[key] = dedup_coefficients.size()
		dedup_keys.append_array(PackedInt32Array([level, x, y, z]))
		for lane in BAKED_BOUNDARY_TENSOR_VALUES_PER_RECORD:
			dedup_coefficients.append(coefficients[value_offset + lane])
	return {"valid": true, "keys": dedup_keys, "coefficients": dedup_coefficients,
		"provenance": provenance.duplicate(true)}

func _baked_boundary_tensor_provenance_matches(provenance: Dictionary) -> bool:
	var source_data_path_value: Variant = provenance.get("source_data_path", null)
	var scene_sha256_value: Variant = provenance.get("scene_sha256", null)
	if not source_data_path_value is String or not scene_sha256_value is String:
		return false
	var scene_sha256 := String(scene_sha256_value)
	if not scene_sha256.is_empty() and not _is_sha256_hex(scene_sha256):
		return false
	if int(provenance.get("schema_version", 0)) != BAKED_BOUNDARY_TENSOR_SCHEMA_VERSION \
			 or String(provenance.get("algorithm", "")) != BAKED_BOUNDARY_TENSOR_ALGORITHM \
			 or int(provenance.get("layout_version", 0)) != BAKED_BOUNDARY_TENSOR_LAYOUT_VERSION \
			 or int(provenance.get("source_sh_revision", 0)) != BAKED_INDIRECT_SH_REVISION \
			 or int(provenance.get("placement_scene_signature_u32", -1)) < 0 \
			 or int(provenance.get("placement_scene_signature_u32", -1)) \
				!= (int(scene_signature) & 0xffffffff) \
			 or int(provenance.get("level_count", 0)) != BAKED_BOUNDARY_TENSOR_LEVEL_COUNT \
			 or String(provenance.get("input_signature", "")).is_empty() \
			 or not _is_sha256_hex(String(provenance.get("input_signature", ""))) \
			 or not _is_sha256_hex(String(provenance.get("source_sh_sha256", ""))) \
			 or not _is_sha256_hex(String(provenance.get("geometry_signature", ""))) \
			 or not _is_sha256_hex(String(provenance.get("geometry_triangles_sha256", ""))) \
			 or not _is_sha256_hex(String(provenance.get("trace_geometry_sha256", ""))):
		return false
	var spacing_value := float(provenance.get("base_spacing_m", NAN))
	if not is_finite(spacing_value) or not is_equal_approx(spacing_value, spacing):
		return false
	var levels_value: Variant = provenance.get("level_steps_m", null)
	var phase_value: Variant = provenance.get("phase_cells", null)
	if not levels_value is PackedFloat32Array or levels_value.size() != BAKED_BOUNDARY_TENSOR_LEVEL_COUNT \
			 or not phase_value is PackedInt32Array or phase_value != PackedInt32Array([0, 0, 0]):
		return false
	for level in BAKED_BOUNDARY_TENSOR_LEVEL_COUNT:
		if not is_equal_approx(float(levels_value[level]), spacing * float(1 << level)):
			return false
	return String(provenance.get("input_signature", "")) \
			== _baked_boundary_tensor_input_signature(provenance) \
			and String(provenance.get("source_sh_sha256", "")) == _sha256_packed_float32(baked_indirect_sh) \
			 and String(provenance.get("trace_geometry_sha256", "")) \
				== _sha256_packed_float32(visibility_triangles)

static func _is_sha256_hex(value: String) -> bool:
	if value.length() != 64:
		return false
	for index in value.length():
		if "0123456789abcdef".find(value.substr(index, 1)) < 0:
			return false
	return true

static func _baked_boundary_tensor_input_signature(provenance: Dictionary) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update("MagicGI boundary tensor build input v1".to_utf8_buffer())
	var text_keys := ["algorithm", "scene_sha256", "source_sh_sha256", "source_data_path",
		"geometry_signature", "geometry_triangles_sha256", "trace_geometry_sha256"]
	for key in text_keys:
		var value := String(provenance.get(key, ""))
		var encoded := value.to_utf8_buffer()
		context.update(PackedInt32Array([encoded.size()]).to_byte_array())
		if not encoded.is_empty():
			context.update(encoded)
	var floats := PackedFloat32Array([float(provenance.get("base_spacing_m", NAN))])
	var steps_value: Variant = provenance.get("level_steps_m", null)
	if not steps_value is PackedFloat32Array:
		return ""
	floats.append_array(steps_value)
	var phase_value: Variant = provenance.get("phase_cells", null)
	if not phase_value is PackedInt32Array:
		return ""
	context.update(PackedInt32Array([int(provenance.get("schema_version", 0)),
		int(provenance.get("layout_version", 0)),
		int(provenance.get("source_sh_revision", 0)),
		int(provenance.get("placement_scene_signature_u32", -1)),
		int(provenance.get("level_count", 0))]).to_byte_array())
	context.update(floats.to_byte_array())
	context.update(phase_value.to_byte_array())
	return context.finish().hex_encode()

static func _sha256_packed_float32(values: PackedFloat32Array) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var bytes := values.to_byte_array()
	if not bytes.is_empty():
		context.update(bytes)
	return context.finish().hex_encode()

static func _baked_boundary_tensor_payload_signature(keys: PackedInt32Array,
		coefficients: PackedFloat32Array, provenance: Dictionary) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update("MagicGI boundary tensor records v1".to_utf8_buffer())
	context.update(PackedInt32Array([BAKED_BOUNDARY_TENSOR_SCHEMA_VERSION,
		BAKED_BOUNDARY_TENSOR_LAYOUT_VERSION, keys.size(), coefficients.size()]).to_byte_array())
	var key_bytes := keys.to_byte_array()
	if not key_bytes.is_empty():
		context.update(key_bytes)
	var coefficient_bytes := coefficients.to_byte_array()
	if not coefficient_bytes.is_empty():
		context.update(coefficient_bytes)
	var provenance_keys := ["algorithm", "input_signature", "scene_sha256", "source_data_path",
		"source_sh_sha256", "geometry_signature", "geometry_triangles_sha256",
		"trace_geometry_sha256"]
	for key in provenance_keys:
		var value := String(provenance.get(key, "")).to_utf8_buffer()
		context.update(PackedInt32Array([value.size()]).to_byte_array())
		if not value.is_empty():
			context.update(value)
	var numeric := PackedFloat32Array([float(provenance.get("base_spacing_m", NAN))])
	context.update(numeric.to_byte_array())
	context.update(PackedInt32Array([int(provenance.get("schema_version", 0)),
		int(provenance.get("layout_version", 0)), int(provenance.get("source_sh_revision", 0)),
		int(provenance.get("placement_scene_signature_u32", -1)),
		int(provenance.get("level_count", 0))]).to_byte_array())
	context.update(PackedFloat32Array(provenance.get("level_steps_m", PackedFloat32Array())).to_byte_array())
	context.update(PackedInt32Array(provenance.get("phase_cells", PackedInt32Array())).to_byte_array())
	return context.finish().hex_encode()

func has_legacy_baked_indirect_sh_payload() -> bool:
	return _resolved_baked_indirect_sh_algorithm() == BAKED_INDIRECT_SH_ALGORITHM_LEGACY \
			and baked_indirect_sh_revision == BAKED_INDIRECT_SH_REVISION \
			and baked_indirect_sh.size() == probe_count() * 27 and baked_indirect_sh_is_valid()

func _resolved_baked_indirect_sh_algorithm() -> String:
	return BAKED_INDIRECT_SH_ALGORITHM_LEGACY if baked_indirect_sh_algorithm.is_empty() \
			else baked_indirect_sh_algorithm

func baked_indirect_directional_provenance_is_valid() -> bool:
	if not _baked_directional_provenance_validation_cached:
		_baked_directional_provenance_validation_result = is_valid_baked_indirect_directional_provenance(
				_resolved_baked_indirect_sh_algorithm(), baked_indirect_directional_source_signature,
				baked_indirect_directional_source_provenance)
		_baked_directional_provenance_validation_cached = true
	return _baked_directional_provenance_validation_result

static func is_valid_baked_indirect_directional_provenance(algorithm: String,
		signature: String, provenance: Dictionary) -> bool:
	if algorithm == BAKED_INDIRECT_SH_ALGORITHM_LEGACY:
		return signature.is_empty() and provenance.is_empty()
	if algorithm != BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE \
			or int(provenance.get("schema_version", 0)) != BAKED_DIRECTIONAL_SOURCE_SCHEMA_VERSION:
		return false
	var physical_units: Variant = provenance.get("physical_units", null)
	var sources_value: Variant = provenance.get("sources", null)
	if typeof(physical_units) != TYPE_BOOL or typeof(sources_value) != TYPE_ARRAY \
			or String(provenance.get("source_scale_convention", "")) \
			!= "godot_directional_nee_q_v1" \
			or String(provenance.get("visibility_contract", "")) \
			!= "all_collected_static_triangles_v1" \
			or String(provenance.get("angular_source_contract", "")) \
			!= "collimated_directional_v1" \
			or String(provenance.get("light_masks_contract", "")) \
			!= "recorded_not_applied_to_bvh_v1":
		return false
	var sources: Array = sources_value
	if signature.is_empty() or signature != baked_directional_source_signature(sources, physical_units):
		return false
	var previous_path := ""
	for source_value in sources:
		if not source_value is Dictionary:
			return false
		var source: Dictionary = source_value
		var path := String(source.get("path", ""))
		var direction_value: Variant = source.get("direction_world", null)
		var radiance_value: Variant = source.get("radiance_rgb", null)
		var sky_mode := int(source.get("sky_mode", -1))
		if typeof(direction_value) != TYPE_VECTOR3 or typeof(radiance_value) != TYPE_VECTOR3:
			return false
		var direction: Vector3 = direction_value
		var radiance: Vector3 = radiance_value
		if path.is_empty() or (not previous_path.is_empty() and path <= previous_path) \
				or not direction.is_finite() or direction.length_squared() < 0.999 \
				or direction.length_squared() > 1.001 or not radiance.is_finite() \
				or sky_mode < DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY \
				or sky_mode > DirectionalLight3D.SKY_MODE_SKY_ONLY:
			return false
		if typeof(source.get("light_negative", null)) != TYPE_BOOL \
				or typeof(source.get("shadow_enabled", null)) != TYPE_BOOL \
				or typeof(source.get("light_cull_mask", null)) != TYPE_INT \
				or typeof(source.get("shadow_caster_mask", null)) != TYPE_INT \
				or typeof(source.get("bake_mode", null)) != TYPE_INT \
				or typeof(source.get("physical_units", null)) != TYPE_BOOL \
				or bool(source.get("physical_units", false)) != physical_units:
			return false
		previous_path = path
	return true

static func baked_directional_source_signature(sources: Array, physical_units: bool) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update("MagicGI directional source snapshot v1".to_utf8_buffer())
	context.update(PackedInt32Array([BAKED_DIRECTIONAL_SOURCE_SCHEMA_VERSION,
			1 if physical_units else 0, sources.size()]).to_byte_array())
	var previous_path := ""
	for source_value in sources:
		if not source_value is Dictionary:
			return ""
		var source: Dictionary = source_value
		var path := String(source.get("path", ""))
		var direction_value: Variant = source.get("direction_world", null)
		var radiance_value: Variant = source.get("radiance_rgb", null)
		if typeof(direction_value) != TYPE_VECTOR3 or typeof(radiance_value) != TYPE_VECTOR3:
			return ""
		var direction: Vector3 = direction_value
		var radiance: Vector3 = radiance_value
		if path.is_empty() or (not previous_path.is_empty() and path <= previous_path) \
				or not direction.is_finite() or not radiance.is_finite():
			return ""
		previous_path = path
		var path_bytes := path.to_utf8_buffer()
		context.update(PackedInt32Array([path_bytes.size()]).to_byte_array())
		context.update(path_bytes)
		var color_value: Variant = source.get("color_linear", null)
		var temperature_value: Variant = source.get("temperature_linear", null)
		var energy := float(source.get("light_energy", NAN))
		var indirect_energy := float(source.get("light_indirect_energy", NAN))
		var intensity_lux := float(source.get("intensity_lux", NAN))
		var angular_distance := float(source.get("angular_distance", NAN))
		if typeof(color_value) != TYPE_VECTOR3 or typeof(temperature_value) != TYPE_VECTOR3:
			return ""
		var color_linear: Vector3 = color_value
		var temperature_linear: Vector3 = temperature_value
		if not color_linear.is_finite() or not temperature_linear.is_finite() \
				or not is_finite(energy) or not is_finite(indirect_energy) \
				or not is_finite(intensity_lux) or not is_finite(angular_distance):
			return ""
		for key in ["light_negative", "sky_mode", "light_cull_mask", "shadow_caster_mask", "shadow_enabled", "bake_mode"]:
			if not source.has(key):
				return ""
		var values := PackedFloat32Array([
			direction.x, direction.y, direction.z,
			radiance.x, radiance.y, radiance.z,
			color_linear.x, color_linear.y, color_linear.z,
			temperature_linear.x, temperature_linear.y, temperature_linear.z,
			energy, indirect_energy, intensity_lux, angular_distance])
		for value in values:
			if not is_finite(value):
				return ""
		context.update(values.to_byte_array())
		var flags := PackedInt32Array([
			int(source.get("light_negative", false)),
			int(source.get("sky_mode", -1)),
			int(source.get("light_cull_mask", -1)),
			int(source.get("shadow_caster_mask", -1)),
			int(source.get("shadow_enabled", false)),
			int(source.get("bake_mode", -1)),
			int(source.get("physical_units", false))])
		context.update(flags.to_byte_array())
	return context.finish().hex_encode()

func prepare_bake_exact_directional_secondary() -> void:
	bake_exact_directional_secondary.resize(probe_count() * 27)
	bake_exact_directional_secondary.fill(0.0)
	bake_exact_directional_secondary_valid = false
	_bake_exact_directional_probe_complete.resize(probe_count())
	_bake_exact_directional_probe_complete.fill(0)

func validate_bake_exact_directional_secondary() -> bool:
	if bake_exact_directional_secondary.size() != probe_count() * 27 \
			or _bake_exact_directional_probe_complete.size() != probe_count():
		bake_exact_directional_secondary_valid = false
		return false
	for probe in probe_count():
		if _bake_exact_directional_probe_complete[probe] != 1:
			bake_exact_directional_secondary_valid = false
			return false
	for value in bake_exact_directional_secondary:
		if not is_finite(value):
			bake_exact_directional_secondary_valid = false
			return false
	bake_exact_directional_secondary_valid = true
	return true

func clear_bake_exact_directional_secondary() -> void:
	bake_exact_directional_secondary.clear()
	bake_exact_directional_secondary_valid = false
	_bake_exact_directional_probe_complete.clear()

func baked_indirect_sky_provenance_is_valid(provenance: Dictionary = {}) -> bool:
	if not provenance.is_empty():
		return is_valid_baked_indirect_sky_provenance(provenance)
	if not _sky_provenance_validation_cached:
		_sky_provenance_validation_result = is_valid_baked_indirect_sky_provenance(
				baked_indirect_sky_provenance)
		_sky_provenance_validation_cached = true
	return _sky_provenance_validation_result

static func is_valid_baked_indirect_sky_provenance(provenance: Dictionary) -> bool:
	if int(provenance.get("schema_version", 0)) != 1:
		return false
	var status := String(provenance.get("status", ""))
	if status != "explicit_no_sky" and status != "verified_ready_sky":
		return false
	if String(provenance.get("radiance_unit", "")) != "scene_linear_radiance":
		return false
	var radiance: Variant = provenance.get("radiance_sh")
	if not radiance is PackedFloat32Array or radiance.size() != 27:
		return false
	for value in radiance:
		if not is_finite(value):
			return false
	var energy := float(provenance.get("radiance_energy", NAN))
	if not is_finite(energy) or energy < 0.0:
		return false
	var signature := String(provenance.get("input_signature", ""))
	if signature.is_empty() or signature != baked_sky_input_signature(radiance, energy):
		return false
	if status == "explicit_no_sky":
		if String(provenance.get("source", "")) != "none" \
				or int(provenance.get("source_mode", -1)) != -1 \
				or energy != 0.0:
			return false
		for value in radiance:
			if value != 0.0:
				return false
	else:
		if String(provenance.get("source", "")).is_empty() \
				or int(provenance.get("source_mode", -1)) < 0 \
				or int(provenance.get("source_revision", -1)) < 0:
			return false
	return true

static func baked_sky_input_signature(radiance: PackedFloat32Array, energy: float) -> String:
	if radiance.size() != 27 or not is_finite(energy) or energy < 0.0:
		return ""
	var values := PackedFloat32Array()
	values.resize(28)
	values[0] = energy
	for i in 27:
		if not is_finite(radiance[i]):
			return ""
		values[i + 1] = radiance[i]
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(values.to_byte_array())
	return context.finish().hex_encode()

func baked_indirect_sh_is_valid() -> bool:
	if not _baked_indirect_payload_validation_cached:
		_baked_indirect_payload_validation_result = true
		if baked_indirect_sh_revision == 0:
			_baked_indirect_payload_validation_result = baked_indirect_sh.is_empty()
		elif baked_indirect_sh_revision < 0 \
				or baked_indirect_sh_revision > BAKED_INDIRECT_SH_REVISION \
				or baked_indirect_sh.size() != probe_count() * 27:
			_baked_indirect_payload_validation_result = false
		else:
			for value in baked_indirect_sh:
				if not is_finite(value):
					_baked_indirect_payload_validation_result = false
					break
		_baked_indirect_payload_validation_cached = true
	# Published Data resources are immutable. Keep cheap shape/revision guards
	# live while reusing the one-time finite scan for backend readiness/status.
	if baked_indirect_sh_revision == 0:
		return _baked_indirect_payload_validation_result and baked_indirect_sh.is_empty()
	return _baked_indirect_payload_validation_result \
			and baked_indirect_sh_revision > 0 \
			and baked_indirect_sh_revision <= BAKED_INDIRECT_SH_REVISION \
			and baked_indirect_sh.size() == probe_count() * 27

## Packs revision-2 probe-major SH9 RGB into seven vec4s per probe for the
## block producer. The final lane is zero padding; the persisted resource stays
## compact at 27 floats per probe.
func make_baked_indirect_sh_upload_bytes() -> PackedByteArray:
	if not has_baked_indirect_sh() or not baked_indirect_sh_is_valid() \
			or not is_valid_baked_indirect_sky_provenance(baked_indirect_sky_provenance):
		return PackedByteArray()
	var packed := PackedFloat32Array()
	packed.resize(probe_count() * 28)
	for probe in probe_count():
		for scalar in 27:
			packed[probe * 28 + scalar] = baked_indirect_sh[probe * 27 + scalar]
	return packed.to_byte_array()

## Conservative CPU residency estimate for the packed arrays owned by this
## resource. Resource/file compression is deliberately not used as a proxy for
## resident memory.
func estimate_cpu_bytes() -> int:
	var bytes := 1024
	bytes += positions.size() * 12 + surface_positions.size() * 12 + normals.size() * 12
	bytes += stable_probe_ids.size() * 8 + probe_spacings.size() * 4
	bytes += transfer.size() * 4 + primary_sky_visibility.size() * 4
	bytes += visibility_moments.size() * 4 + visibility_nodes.size() * 4
	bytes += visibility_triangles.size() * 4 + cell_ranges.size() * 4 + cell_indices.size() * 4
	bytes += baked_indirect_sh.size() * 4
	if not baked_indirect_sky_provenance.is_empty():
		bytes += 384 # Small dictionary metadata plus the 27-float captured Sky SH.
	if not baked_indirect_directional_source_provenance.is_empty():
		bytes += 256 + baked_indirect_directional_source_signature.to_utf8_buffer().size()
		var source_values: Variant = baked_indirect_directional_source_provenance.get("sources", [])
		if source_values is Array:
			for source_value in source_values:
				bytes += 1024 # Conservative Variant/Dictionary storage for one source record.
				if source_value is Dictionary:
					bytes += String(source_value.get("path", "")).to_utf8_buffer().size()
	bytes += emitter_static_signatures.size() * 8 + emitter_transport.size() * 4
	for key in emitter_keys:
		bytes += key.to_utf8_buffer().size() + 32
	if directional != null and directional is DirectionalData:
		bytes += directional.transfer.size() * 4 + directional.sky.size() * 4
		bytes += directional.emission.size() * 4
	return bytes

## Conservative per-page GPU residency estimate, including rounded atlas rows,
## runtime relight outputs, normals, lookup buffers, and persisted BVH buffers.
## Images are counted at their actual uncompressed texel format.
func estimate_gpu_bytes() -> int:
	var count := probe_count()
	if count <= 0:
		return 0
	var atlas_rows := ceili(float(count) / float(ATLAS_COLUMNS))
	var bytes := 0
	bytes += ATLAS_COLUMNS * TRANSFER_TEXELS_PER_POINT * atlas_rows * 16
	bytes += ATLAS_COLUMNS * PRIMARY_SKY_TEXELS_PER_POINT * atlas_rows * 16
	bytes += ATLAS_COLUMNS * GEOMETRY_TEXELS_PER_POINT * atlas_rows * 16
	bytes += ATLAS_COLUMNS * VISIBILITY_TILE_SIZE * atlas_rows * VISIBILITY_TILE_SIZE * 8
	bytes += ATLAS_COLUMNS * atlas_rows * 16 # Dynamic emission atlas.
	bytes += (visibility_nodes.size() + visibility_triangles.size()) * 4
	bytes += (cell_ranges.size() + cell_indices.size()) * 4
	if adaptive_placement:
		bytes += count * 4 # Renderer probe-index indirection.
	else:
		bytes += 4 # Empty adaptive indirection buffer used by the current upload contract.
	if directional != null and directional is DirectionalData:
		bytes += (directional.transfer.size() + directional.sky.size()
				+ directional.emission.size()) * 4
	if baked_indirect_sh_revision == BAKED_INDIRECT_SH_REVISION \
			and baked_indirect_sh.size() == probe_count() * 27:
		bytes += probe_count() * 7 * 16 # Runtime packed source SSBO.
	bytes += count * 16 # Runtime normal buffer.
	bytes += count * 32 # Surface relight result.
	if directional != null:
		bytes += count * 320 # Directional relight result.
	return bytes

## Reports whether any geometry transport coefficient contributes. Volumes
## cache this O(coefficients) scan alongside full resource validation.
func has_nonzero_transfer() -> bool:
	for coefficients in [transfer, primary_sky_visibility, emitter_transport, baked_indirect_sh]:
		for value in coefficients:
			if value != 0.0:
				return true
	return false

func emitter_count() -> int:
	return emitter_keys.size()

func supports_format() -> bool:
	return format_version == LEGACY_FORMAT_VERSION \
		or format_version == EMITTER_FORMAT_VERSION \
		or format_version == PRIMARY_SKY_FORMAT_VERSION \
		or format_version == MOMENT_FORMAT_VERSION \
		or format_version == FORMAT_VERSION

## Full validation is O(points + grid cells). Volumes cache the result by
## resource identity and bake_version; render-frame layout checks stay O(1).
func is_valid() -> bool:
	if not supports_format() or bake_version <= 0:
		return false
	if directional != null and (not directional is DirectionalData \
			or not directional.is_valid(probe_count(), emitter_count())):
		return false
	if probe_count() == 0 or normals.size() != probe_count() or \
			(not stable_probe_ids.is_empty() and stable_probe_ids.size() != probe_count()):
		return false
	if transfer.size() != probe_count() * 27:
		return false
	if format_version == LEGACY_FORMAT_VERSION:
		# v2 has only far-field SH transport. It remains a valid legacy bake.
		if not emitter_keys.is_empty() or not emitter_static_signatures.is_empty() \
				or not emitter_transport.is_empty() or not primary_sky_visibility.is_empty():
			return false
	else:
		var source_count := emitter_count()
		if source_count > MAX_EMITTERS or emitter_static_signatures.size() != source_count \
				or emitter_transport.size() != probe_count() * source_count * 6:
			return false
		var seen_keys: Dictionary = {}
		for key in emitter_keys:
			if key.is_empty() or seen_keys.has(key):
				return false
			seen_keys[key] = true
		for value in emitter_transport:
			if not is_finite(value) or value < 0.0:
				return false
		if format_version >= PRIMARY_SKY_FORMAT_VERSION:
			if primary_sky_visibility.size() != probe_count() * 9:
				return false
			for value in primary_sky_visibility:
				if not is_finite(value):
					return false
		elif not primary_sky_visibility.is_empty():
			return false
	if format_version >= MOMENT_FORMAT_VERSION:
		if surface_positions.size() != probe_count() \
				or visibility_moments.size() != probe_count() * VISIBILITY_TEXELS_PER_PROBE * VISIBILITY_MOMENT_CHANNELS:
			return false
		for i in probe_count():
			if not surface_positions[i].is_finite():
				return false
		for value in visibility_moments:
			if not is_finite(value) or value < 0.0:
				return false
		for probe in probe_count():
			for texel in VISIBILITY_TEXELS_PER_PROBE:
				var base := (probe * VISIBILITY_TEXELS_PER_PROBE + texel) * VISIBILITY_MOMENT_CHANNELS
				var mean := visibility_moments[base]
				var second_moment := visibility_moments[base + 1]
				if mean > bake_distance + 0.001 \
						or second_moment > bake_distance * bake_distance + 0.01 \
						or second_moment + maxf(0.0001, mean * mean * 0.0001) < mean * mean:
					return false
	elif not surface_positions.is_empty() or not visibility_moments.is_empty():
		return false
	if format_version == FORMAT_VERSION:
		if not Visibility.validate(visibility_nodes, visibility_triangles):
			return false
	elif not visibility_nodes.is_empty() or not visibility_triangles.is_empty():
		return false
	if grid_dims.x <= 0 or grid_dims.y <= 0 or grid_dims.z <= 0:
		return false
	if grid_dims.x > MAX_GRID_AXIS or grid_dims.y > MAX_GRID_AXIS or grid_dims.z > MAX_GRID_AXIS:
		return false
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	if adaptive_placement:
		if cell_ranges.size() != cells * 2 or cell_indices.size() != probe_count() \
				or probe_spacings.size() != probe_count() or not is_finite(minimum_probe_spacing) \
				or minimum_probe_spacing < 0.1 or minimum_probe_spacing > spacing:
			return false
		var offset := 0
		for cell in cells:
			if cell_ranges[cell * 2] != offset or cell_ranges[cell * 2 + 1] < 0:
				return false
			offset += cell_ranges[cell * 2 + 1]
		if offset != probe_count():
			return false
		for value in probe_spacings:
			if not is_finite(value) or value < minimum_probe_spacing or value > spacing:
				return false
	elif cell_indices.size() != cells * CELL_CAPACITY or not cell_ranges.is_empty() \
			or not probe_spacings.is_empty():
		return false
	if not volume_size.is_finite() or minf(volume_size.x, minf(volume_size.y, volume_size.z)) <= 0.0:
		return false
	if not volume_transform.is_finite() or not world_to_grid.is_finite():
		return false
	if absf(volume_transform.basis.determinant()) < 0.00000001 or absf(world_to_grid.basis.determinant()) < 0.00000001:
		return false
	if not is_finite(spacing) or spacing <= 0.0 or spacing > 4096.0:
		return false
	if not is_finite(surface_offset) or surface_offset <= 0.0 or surface_offset > 5.0:
		return false
	if not is_finite(bake_distance) or bake_distance <= 0.0 or bake_distance > 4096.0:
		return false
	if bake_samples <= 0 or bake_samples > 65536 or bake_bounces <= 0 or bake_bounces > 8:
		return false
	if not is_finite(terrain_reflectance) or terrain_reflectance < 0.0 or terrain_reflectance > 1.0:
		return false
	if not is_finite(material_reflectance) or material_reflectance < 0.0 or material_reflectance > 1.0:
		return false
	for i in probe_count():
		if not positions[i].is_finite() or not normals[i].is_finite():
			return false
		if absf(normals[i].length_squared() - 1.0) > 0.02:
			return false
	for value in transfer:
		if not is_finite(value):
			return false
	var mapped := PackedByteArray()
	mapped.resize(probe_count())
	mapped.fill(0)
	for index in cell_indices:
		if index < -1 or index >= probe_count():
			return false
		if index >= 0:
			mapped[index] = 1
	for present in mapped:
		if present == 0:
			return false
	return true

func matches_layout(
		size: Vector3,
		probe_spacing: float,
		probe_offset: float,
		transform: Transform3D,
		samples: int,
		bounces: int,
		distance: float,
		terrain_albedo: float,
		fallback_albedo: float) -> bool:
	return format_version == FORMAT_VERSION \
		and volume_size.is_equal_approx(size) \
		and is_equal_approx(spacing, probe_spacing) \
		and is_equal_approx(surface_offset, probe_offset) \
		and volume_transform.is_equal_approx(transform) \
		and bake_samples == samples \
		and bake_bounces == bounces \
		and is_equal_approx(bake_distance, distance) \
		and is_equal_approx(terrain_reflectance, terrain_albedo) \
		and is_equal_approx(material_reflectance, fallback_albedo)

static func cell_coordinates(grid: Vector3, dimensions: Vector3i) -> Vector3i:
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0 or not grid.is_finite():
		return Vector3i(-1, -1, -1)
	var upper := Vector3(dimensions)
	if grid.x < -CELL_BOUNDARY_EPSILON or grid.y < -CELL_BOUNDARY_EPSILON or grid.z < -CELL_BOUNDARY_EPSILON:
		return Vector3i(-1, -1, -1)
	if grid.x > upper.x + CELL_BOUNDARY_EPSILON or grid.y > upper.y + CELL_BOUNDARY_EPSILON or grid.z > upper.z + CELL_BOUNDARY_EPSILON:
		return Vector3i(-1, -1, -1)
	# The positive face belongs to the final cell, matching the placement sampler.
	return Vector3i(grid.floor()).clamp(Vector3i.ZERO, dimensions - Vector3i.ONE)

func build_cell_indices() -> bool:
	if grid_dims.x <= 0 or grid_dims.y <= 0 or grid_dims.z <= 0 \
			or grid_dims.x > MAX_GRID_AXIS or grid_dims.y > MAX_GRID_AXIS or grid_dims.z > MAX_GRID_AXIS:
		cell_indices.clear()
		return false
	if adaptive_placement:
		return _build_adaptive_indices()
	cell_indices.resize(grid_dims.x * grid_dims.y * grid_dims.z * CELL_CAPACITY)
	cell_indices.fill(-1)
	var cell_counts := PackedByteArray()
	cell_counts.resize(grid_dims.x * grid_dims.y * grid_dims.z)
	cell_counts.fill(0)
	for i in probe_count():
		var surface := surface_positions[i] if format_version >= MOMENT_FORMAT_VERSION \
				else positions[i] - normals[i] * surface_offset
		var grid := world_to_grid * surface
		var cell_coord := cell_coordinates(grid, grid_dims)
		if cell_coord.x < 0:
			cell_indices.clear()
			return false
		var cell := cell_coord.x + cell_coord.y * grid_dims.x + cell_coord.z * grid_dims.x * grid_dims.y
		var slot := int(cell_counts[cell])
		if slot >= CELL_CAPACITY:
			cell_indices.clear()
			return false
		cell_indices[cell * CELL_CAPACITY + slot] = i
		cell_counts[cell] = slot + 1
	return true

func _build_adaptive_indices() -> bool:
	var count := grid_dims.x * grid_dims.y * grid_dims.z
	var buckets: Dictionary = {}
	for probe in probe_count():
		var cell := cell_coordinates(world_to_grid * surface_positions[probe], grid_dims)
		if cell.x < 0:
			return false
		var key := cell.x + cell.y * grid_dims.x + cell.z * grid_dims.x * grid_dims.y
		var entries: Array = buckets.get(key, [])
		entries.append(probe)
		buckets[key] = entries
	cell_ranges.resize(count * 2)
	cell_indices.clear()
	for cell in count:
		var entries: Array = buckets.get(cell, [])
		cell_ranges[cell * 2] = cell_indices.size()
		cell_ranges[cell * 2 + 1] = entries.size()
		for probe: int in entries:
			cell_indices.append(probe)
	return true

func evaluate(index: int, lighting: PackedFloat32Array,
		sky_lighting: PackedFloat32Array = PackedFloat32Array()) -> Vector3:
	if index < 0 or index >= probe_count() or lighting.size() != 27:
		return Vector3.ZERO
	var secondary := Vector3.ZERO
	for k in 9:
		for channel in 3:
			secondary[channel] += transfer[index * 27 + k * 3 + channel] * lighting[k * 3 + channel]
	var primary := Vector3.ZERO
	if format_version >= PRIMARY_SKY_FORMAT_VERSION and primary_sky_visibility.size() == probe_count() * 9 \
			and sky_lighting.size() == 27:
		for k in 9:
			for channel in 3:
				# Primary coefficients integrate irradiance, unlike secondary radiance transport.
				primary[channel] += primary_sky_visibility[index * 9 + k] * sky_lighting[k * 3 + channel] / PI
	# Clamp each transport family independently so a negative truncated-SH lobe
	# in one family cannot cancel positive light from the other.
	return secondary.max(Vector3.ZERO) + primary.max(Vector3.ZERO)

## Evaluates the baked geometry response to a unit directional source.
func transport_response(index: int, dir: Vector3) -> Vector3:
	if index < 0 or index >= probe_count():
		return Vector3.ZERO
	var y := sh_basis(dir.normalized())
	var result := Vector3.ZERO
	for k in 9:
		for channel in 3:
			result[channel] += transfer[index * 27 + k * 3 + channel] * y[k]
	return result

func transport_preview_color(index: int) -> Color:
	var value := transport_response(index, Vector3.UP).max(Vector3.ZERO)
	return Color(value.x, value.y, value.z, 1.0)

static func octahedral_encode(direction: Vector3) -> Vector2:
	var unit := direction.normalized()
	var denominator := absf(unit.x) + absf(unit.y) + absf(unit.z)
	if denominator <= 0.000001:
		return Vector2(0.5, 0.5)
	var p := Vector2(unit.x, unit.y) / denominator
	if unit.z < 0.0:
		p = Vector2((1.0 - absf(p.y)) * _sign_not_zero(p.x),
				(1.0 - absf(p.x)) * _sign_not_zero(p.y))
	return p * 0.5 + Vector2(0.5, 0.5)

static func octahedral_decode(uv: Vector2) -> Vector3:
	var p := uv * 2.0 - Vector2.ONE
	var direction := Vector3(p.x, p.y, 1.0 - absf(p.x) - absf(p.y))
	if direction.z < 0.0:
		var original_x := direction.x
		direction.x = (1.0 - absf(direction.y)) * _sign_not_zero(original_x)
		direction.y = (1.0 - absf(original_x)) * _sign_not_zero(direction.y)
	return direction.normalized()

static func _sign_not_zero(value: float) -> float:
	return -1.0 if value < 0.0 else 1.0

static func fold_visibility_texel(texel: Vector2i) -> Vector2i:
	var size := VISIBILITY_TILE_SIZE
	var folded := texel
	# Bilinear filtering can request only the immediate one-texel border. Mirror
	# the integer octahedral edge and flip the orthogonal axis at each fold. This
	# keeps the CPU sampler identical to the shader without decoding out-of-range
	# oct coordinates, whose extension is not the defined octahedral map.
	for _iteration in 4:
		if folded.x < 0:
			folded = Vector2i(-folded.x - 1, size - 1 - folded.y)
		elif folded.x >= size:
			folded = Vector2i(size * 2 - 1 - folded.x, size - 1 - folded.y)
		if folded.y < 0:
			folded = Vector2i(size - 1 - folded.x, -folded.y - 1)
		elif folded.y >= size:
			folded = Vector2i(size - 1 - folded.x, size * 2 - 1 - folded.y)
		if folded.x >= 0 and folded.x < size and folded.y >= 0 and folded.y < size:
			return folded
	return folded.clamp(Vector2i.ZERO, Vector2i.ONE * (size - 1))

func sample_visibility_moments(probe: int, direction: Vector3) -> Vector2:
	if format_version < MOMENT_FORMAT_VERSION or probe < 0 or probe >= probe_count() \
			or visibility_moments.size() != probe_count() * VISIBILITY_TEXELS_PER_PROBE * VISIBILITY_MOMENT_CHANNELS \
			or direction.length_squared() < 0.000001:
		return Vector2.ZERO
	var texel_position := octahedral_encode(direction) * float(VISIBILITY_TILE_SIZE) - Vector2(0.5, 0.5)
	var texel_base := Vector2i(floori(texel_position.x), floori(texel_position.y))
	var fraction := texel_position - Vector2(texel_base)
	var result := Vector2.ZERO
	for dy in 2:
		for dx in 2:
			var weight := (fraction.x if dx == 1 else 1.0 - fraction.x) \
					* (fraction.y if dy == 1 else 1.0 - fraction.y)
			var folded := fold_visibility_texel(texel_base + Vector2i(dx, dy))
			var base := (probe * VISIBILITY_TEXELS_PER_PROBE \
					+ folded.y * VISIBILITY_TILE_SIZE + folded.x) * VISIBILITY_MOMENT_CHANNELS
			result += Vector2(visibility_moments[base], visibility_moments[base + 1]) * weight
	return result

static func one_sided_chebyshev_bound(mean: float, second_moment: float, distance: float,
		variance_floor: float) -> float:
	if not is_finite(mean) or not is_finite(second_moment) or not is_finite(distance) \
			or not is_finite(variance_floor) or mean < 0.0 or second_moment < 0.0 or distance < 0.0:
		return 0.0
	var safe_mean := maxf(mean, 0.0)
	var delta := distance - safe_mean
	if delta <= 0.0:
		return 1.0
	var variance := maxf(second_moment - safe_mean * safe_mean, maxf(variance_floor, 0.0))
	var delta_squared := delta * delta
	var denominator := variance + delta_squared
	return clampf(variance / denominator, 0.0, 1.0) if denominator > 0.0 else 0.0

## The runtime squares the one-sided bound to reduce the remaining light leak.
static func chebyshev_visibility(mean: float, second_moment: float, distance: float,
		variance_floor: float) -> float:
	var bound := one_sided_chebyshev_bound(mean, second_moment, distance, variance_floor)
	return bound * bound

func make_atlas_image() -> Image:
	return _make_atlas_image(false)

## Builds the runtime lookup atlas with a per-probe/channel positivity filter.
## Serialized transfer remains untouched: only l>=1 is scaled when the SH9
## reconstruction could go negative. The DC term, and therefore response to
## uniform lighting, is preserved exactly. This conservative window reduces
## directional contrast and sharpness while avoiding negative lobes.
func make_runtime_atlas_image() -> Image:
	return _make_atlas_image(true)

## Validates a saved bake once and creates all immutable textures/bytes needed by
## the renderer. The public individual packers retain their own validation.
func make_render_upload() -> Dictionary:
	if format_version < MOMENT_FORMAT_VERSION or not is_valid():
		return {}
	var surface_bounds := surface_sample_bounds(surface_positions)
	if not _valid_surface_sample_bounds(surface_bounds):
		return {}
	# A stale v5 remains a diagnostic preview with its original moment weighting.
	# Matching v5 resources are upgraded before publication. These empty traversal
	# buffers are upload-only and never pretend to be persisted v6 geometry.
	var node_bytes := visibility_nodes.to_byte_array() if format_version == FORMAT_VERSION \
			else PackedFloat32Array([0, 0, 0, 1, 0, 0, 0, 0]).to_byte_array()
	var triangle_bytes := visibility_triangles.to_byte_array() if format_version == FORMAT_VERSION \
			else PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).to_byte_array()
	var transfer_image := _pack_atlas_image(true)
	var primary_sky_image := _pack_primary_sky_image()
	var geometry_image := _pack_geometry_image()
	var visibility_moment_image := _pack_visibility_moment_image()
	var index_bytes := cell_ranges.to_byte_array() if adaptive_placement else cell_indices.to_byte_array()
	var emission_image := make_emission_atlas_image(PackedFloat32Array())
	if transfer_image == null or primary_sky_image == null or geometry_image == null \
			or visibility_moment_image == null or index_bytes.is_empty() \
			or emission_image == null:
		return {}
	return {
		"transfer_image": transfer_image,
		"primary_sky_image": primary_sky_image,
		"geometry_image": geometry_image,
		"visibility_moment_image": visibility_moment_image,
		"visibility_node_bytes": node_bytes,
		"visibility_triangle_bytes": triangle_bytes,
		"index_bytes": index_bytes,
		"sparse_indices": adaptive_placement,
		"index_entries": cell_indices.to_byte_array() if adaptive_placement else PackedInt32Array([0]).to_byte_array(),
		"emission_image": emission_image,
		"baked_indirect_sh_bytes": make_baked_indirect_sh_upload_bytes(),
		"surface_bounds": surface_bounds
	}

## Exact bounds of the persisted world-space surface anchors. This is computed
## while the immutable upload bundle is prepared, so the render-thread uploader
## never walks probe arrays or mistakes a streamed support halo for page bounds.
static func surface_sample_bounds(samples: PackedVector3Array) -> AABB:
	if samples.is_empty() or not samples[0].is_finite():
		return AABB(Vector3.ZERO, Vector3.ONE * -1.0)
	var bounds := AABB(samples[0], Vector3.ZERO)
	for index in range(1, samples.size()):
		var sample := samples[index]
		if not sample.is_finite():
			return AABB(Vector3.ZERO, Vector3.ONE * -1.0)
		bounds = bounds.expand(sample)
	return bounds

static func _valid_surface_sample_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
			and bounds.size.x >= 0.0 and bounds.size.y >= 0.0 and bounds.size.z >= 0.0

## Packs already-composed per-probe RGB emission into one RGBAF texel per probe.
## An empty payload is an all-zero atlas, which also covers legacy v2 resources.
func make_emission_atlas_image(payload: PackedFloat32Array) -> Image:
	if probe_count() <= 0:
		return null
	var expected := probe_count() * 3
	if not payload.is_empty() and payload.size() != expected:
		return null
	for value in payload:
		if not is_finite(value) or value < 0.0:
			return null
	var image := Image.create_empty(ATLAS_COLUMNS,
			ceili(float(probe_count()) / ATLAS_COLUMNS), false, Image.FORMAT_RGBAF)
	for p in probe_count():
		var color := Color(0.0, 0.0, 0.0, 0.0)
		if not payload.is_empty():
			color.r = payload[p * 3]
			color.g = payload[p * 3 + 1]
			color.b = payload[p * 3 + 2]
		image.set_pixel(p % ATLAS_COLUMNS, p / ATLAS_COLUMNS, color)
	return image

## Composes dynamic source weights with the immutable per-emitter transport.
## The returned RGB values are outgoing indirect radiance before receiver albedo.
func compose_emission(source_values: PackedFloat32Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(probe_count() * 3)
	result.fill(0.0)
	if source_values.size() != emitter_count() * 6 \
			or emitter_transport.size() != probe_count() * emitter_count() * 6:
		return result
	for value in source_values:
		if not is_finite(value) or value < 0.0:
			return result
	for emitter in emitter_count():
		for probe in probe_count():
			var transport_base := (emitter * probe_count() + probe) * 6
			var output_base := probe * 3
			var source_base := emitter * 6
			for channel in 3:
				result[output_base + channel] += emitter_transport[transport_base + channel] \
						* source_values[source_base + channel] \
						+ emitter_transport[transport_base + 3 + channel] \
						* source_values[source_base + 3 + channel]
	for value in result:
		if not is_finite(value) or value < 0.0:
			result.fill(0.0)
			return result
	return result

func _make_atlas_image(regularize_transport: bool) -> Image:
	if not is_valid():
		return null
	return _pack_atlas_image(regularize_transport)

func _pack_atlas_image(regularize_transport: bool) -> Image:
	var image := Image.create_empty(ATLAS_COLUMNS * TRANSFER_TEXELS_PER_POINT,
			ceili(float(probe_count()) / ATLAS_COLUMNS), false, Image.FORMAT_RGBAF)
	for p in probe_count():
		var x0 := (p % ATLAS_COLUMNS) * TRANSFER_TEXELS_PER_POINT
		var y := p / ATLAS_COLUMNS
		var high_band_scale := _runtime_high_band_scale(p) if regularize_transport else Vector3.ONE
		for t in TRANSFER_TEXELS_PER_POINT:
			var texel := Color(0.0, 0.0, 0.0, 0.0)
			for channel in 4:
				var coefficient := t * 4 + channel
				if coefficient < 27:
					var value := transfer[p * 27 + coefficient]
					if regularize_transport and coefficient >= 3:
						value *= high_band_scale[coefficient % 3]
					texel[channel] = value
			image.set_pixel(x0 + t, y, texel)
	return image

func _pack_primary_sky_image() -> Image:
	var image := Image.create_empty(ATLAS_COLUMNS * PRIMARY_SKY_TEXELS_PER_POINT,
			ceili(float(probe_count()) / ATLAS_COLUMNS), false, Image.FORMAT_RGBAF)
	if format_version < PRIMARY_SKY_FORMAT_VERSION:
		return image
	for probe in probe_count():
		var x0 := (probe % ATLAS_COLUMNS) * PRIMARY_SKY_TEXELS_PER_POINT
		var y := probe / ATLAS_COLUMNS
		for texel_index in PRIMARY_SKY_TEXELS_PER_POINT:
			var texel := Color(0.0, 0.0, 0.0, 0.0)
			for lane in 4:
				var coefficient := texel_index * 4 + lane
				if coefficient < 9:
					texel[lane] = primary_sky_visibility[probe * 9 + coefficient]
			image.set_pixel(x0 + texel_index, y, texel)
	return image

func _runtime_high_band_scale(probe: int) -> Vector3:
	return SHFilter.high_band_scale(transfer, probe * 27)

func make_geometry_image() -> Image:
	if format_version < MOMENT_FORMAT_VERSION or not is_valid():
		return null
	return _pack_geometry_image()

func _pack_geometry_image() -> Image:
	var image := Image.create_empty(ATLAS_COLUMNS * GEOMETRY_TEXELS_PER_POINT,
			ceili(float(probe_count()) / ATLAS_COLUMNS), false, Image.FORMAT_RGBAF)
	for p in probe_count():
		var x := (p % ATLAS_COLUMNS) * GEOMETRY_TEXELS_PER_POINT
		var y := p / ATLAS_COLUMNS
		var surface := surface_positions[p]
		var position := positions[p]
		var normal := normals[p]
		var patch := Visibility.surface_patch(visibility_nodes, visibility_triangles, surface) \
				if format_version >= FORMAT_VERSION else 0
		image.set_pixel(x, y, Color(surface.x, surface.y, surface.z, float(patch)))
		image.set_pixel(x + 1, y, Color(position.x, position.y, position.z, 1.0))
		image.set_pixel(x + 2, y, Color(normal.x, normal.y, normal.z, probe_spacings[p] if adaptive_placement else spacing))
	return image

func make_visibility_moment_image() -> Image:
	if format_version < MOMENT_FORMAT_VERSION or not is_valid():
		return null
	return _pack_visibility_moment_image()

func _pack_visibility_moment_image() -> Image:
	var rows := ceili(float(probe_count()) / ATLAS_COLUMNS)
	var image := Image.create_empty(ATLAS_COLUMNS * VISIBILITY_TILE_SIZE,
			rows * VISIBILITY_TILE_SIZE, false, Image.FORMAT_RGF)
	for probe in probe_count():
		var tile_x := (probe % ATLAS_COLUMNS) * VISIBILITY_TILE_SIZE
		var tile_y := (probe / ATLAS_COLUMNS) * VISIBILITY_TILE_SIZE
		for y in VISIBILITY_TILE_SIZE:
			for x in VISIBILITY_TILE_SIZE:
				var base := (probe * VISIBILITY_TEXELS_PER_PROBE
						+ y * VISIBILITY_TILE_SIZE + x) * VISIBILITY_MOMENT_CHANNELS
				image.set_pixel(tile_x + x, tile_y + y,
						Color(visibility_moments[base], visibility_moments[base + 1], 0.0, 1.0))
	return image

func make_index_bytes() -> PackedByteArray:
	if not is_valid():
		return PackedByteArray()
	return cell_indices.to_byte_array()
