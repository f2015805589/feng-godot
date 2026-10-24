@tool
class_name FMagicGIVolumeSourceChunk
extends Resource
## Versioned free-space transport samples on a regular world-space cell grid.
## This is a separate bake domain from FMagicGIData's surface-offset probes.

const FORMAT_VERSION_DENSE := 1
const FORMAT_VERSION_PACKED := 2
const FORMAT_VERSION_CURRENT := FORMAT_VERSION_PACKED
const SOURCE_SCHEMA_REVISION_CURRENT := 1
const DIRECTIONAL_DATA_REVISION := 1
const LAYOUT_REGULAR_CELL_CENTERS_V1 := "regular_cell_centers_v1"
const CELL_SPACING_M := 0.25
const MOMENT_TEXELS_PER_CELL := 64
const MOMENT_CHANNELS := 2
const MIN_MOMENT_RAYS := 256
const MAX_AXIS := 256
const MAX_CELLS := 262144
const MAX_PAYLOAD_BYTES := 256 * 1024 * 1024
const RELOCATION_STATUS_INVALID := 0
const RELOCATION_STATUS_VALID := 1
const RELOCATION_STATUS_RELOCATED := 2

# Keep the serialized default at v1: older .res files can omit this property.
# Only an explicitly completed lossless pack changes it to v2.
@export_storage var format_version := FORMAT_VERSION_DENSE
@export_storage var source_schema_revision := SOURCE_SCHEMA_REVISION_CURRENT
@export_storage var directional_data_revision := DIRECTIONAL_DATA_REVISION
@export_storage var layout := LAYOUT_REGULAR_CELL_CENTERS_V1
@export_storage var geometry_signature := 0
@export_storage var directional_source_signature := ""
@export_storage var emitter_ids := PackedStringArray()
@export_storage var emitter_static_signatures := PackedInt64Array()
@export_storage var emitter_count := 0
@export_storage var probe_count := 0
@export_storage var spacing_m := CELL_SPACING_M
## Center of cell (0, 0, 0), before its recorded relocation offset.
@export_storage var origin_world := Vector3.ZERO
@export_storage var source_transform_world := Transform3D.IDENTITY
@export_storage var source_size_m := Vector3.ZERO
## Axis-aligned bounds of the original transformed source volume.
@export_storage var source_bounds_world := AABB()
## Exact axis-aligned source-domain bounds used for runtime admission. Ceil-sized
## edge cells whose centers fall outside this AABB remain invalid.
@export_storage var domain_bounds_world := AABB()
@export_storage var dimensions := Vector3i.ZERO
@export_storage var trace_distance_m := 0.0
@export_storage var bake_samples := 0
@export_storage var bake_bounces := 0
@export_storage var moment_rays := 0
@export_storage var maximum_relocation_m := 0.0
## 0=invalid, 1=sampled at the regular cell center, 2=sampled at a recorded offset.
@export_storage var validity := PackedByteArray()
@export_storage var relocation_offset_m := PackedVector3Array()
## v2 maps each logical cell to its packed payload index, or -1 for invalid
## cells. The physical grid, classification, and relocated world anchors remain
## unchanged. Every valid source is retained; no source sampling is discarded.
@export_storage var source_storage_count := 0
@export_storage var source_storage_indices := PackedInt32Array()
@export_storage var source_archive_stats: Dictionary = {}
## [stored source][outgoing SH9][incoming SH9][RGB], incident-radiance transfer.
@export_storage var transfer := PackedFloat32Array()
## [stored source][outgoing SH9][incoming SH9], achromatic sky transfer.
@export_storage var sky := PackedFloat32Array()
## [emitter][stored source][outgoing SH9][base RGB, textured RGB].
@export_storage var emission := PackedFloat32Array()
## [stored source][8x8 octahedral direction][mean distance, second moment], in m and m^2.
## Measurements originate at exactly origin + grid_index * spacing + relocation offset.
@export_storage var receiver_visibility_moments := PackedFloat32Array()

## Cell-aligned, geometry-conditioned transfer operators, prepared at bake time.
## Per row: 27 secondary RGB inputs, 9 achromatic primary-sky inputs, then six
## RGB/base-texture inputs per stable emitter. Four world-aligned CLV lattices.
@export_storage var clv_preparation_revision := 0
@export_storage var clv_preparation_signature := ""
@export_storage var clv_prepared_dimensions := PackedInt32Array()
@export_storage var clv_prepared_offsets := PackedInt32Array()
@export_storage var clv_prepared_validity := PackedByteArray()
@export_storage var clv_prepared_operators := PackedFloat32Array()
@export_storage var clv_preparation_stats: Dictionary = {}

func has_preinterpolated_clv() -> bool:
	if clv_preparation_revision != 1 or clv_preparation_signature != directional_source_signature \
			or clv_prepared_dimensions.size() != 12 or clv_prepared_offsets.size() != 4:
		return false
	var total := 0
	for level in 4:
		var expected := Vector3i((Vector3(dimensions) / float(1 << level)).ceil())
		if clv_prepared_dimensions[level * 3] != expected.x \
				or clv_prepared_dimensions[level * 3 + 1] != expected.y \
				or clv_prepared_dimensions[level * 3 + 2] != expected.z \
				or clv_prepared_offsets[level] != total:
			return false
		total += expected.x * expected.y * expected.z
	return clv_prepared_validity.size() == total \
		and clv_prepared_operators.size() == total * 9 * (36 + emitter_count * 6)

func cell_count() -> int:
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0:
		return 0
	if dimensions.x > MAX_AXIS or dimensions.y > MAX_AXIS or dimensions.z > MAX_AXIS:
		return 0
	var count := dimensions.x * dimensions.y * dimensions.z
	return count if count <= MAX_CELLS else 0

func cell_index(cell: Vector3i) -> int:
	if cell.x < 0 or cell.y < 0 or cell.z < 0 \
			or cell.x >= dimensions.x or cell.y >= dimensions.y or cell.z >= dimensions.z:
		return -1
	return (cell.z * dimensions.y + cell.y) * dimensions.x + cell.x

func cell_coordinates(index: int) -> Vector3i:
	if index < 0 or index >= cell_count():
		return Vector3i(-1, -1, -1)
	var x := index % dimensions.x
	var yz := index / dimensions.x
	return Vector3i(x, yz % dimensions.y, yz / dimensions.y)

func cell_position(index: int, apply_relocation := true) -> Vector3:
	var cell := cell_coordinates(index)
	if cell.x < 0:
		return Vector3.ZERO
	var position := origin_world + Vector3(cell) * spacing_m
	if apply_relocation and relocation_offset_m.size() == cell_count():
		position += relocation_offset_m[index]
	return position

func cell_is_valid(index: int) -> bool:
	return index >= 0 and index < cell_count() \
			and validity.size() == cell_count() \
			and (validity[index] == RELOCATION_STATUS_VALID \
			or validity[index] == RELOCATION_STATUS_RELOCATED)

func storage_probe_count() -> int:
	return source_storage_count if format_version == FORMAT_VERSION_PACKED else cell_count()

func storage_index(logical_cell: int) -> int:
	if logical_cell < 0 or logical_cell >= cell_count():
		return -1
	if format_version == FORMAT_VERSION_PACKED:
		if source_storage_indices.size() != cell_count():
			return -1
		return source_storage_indices[logical_cell]
	return logical_cell

func cell_has_stored_sample(logical_cell: int) -> bool:
	var index := storage_index(logical_cell)
	return cell_is_valid(logical_cell) and index >= 0 and index < storage_probe_count()

func stored_valid_cell_count() -> int:
	return source_storage_count if format_version == FORMAT_VERSION_PACKED else valid_cell_count()

func source_storage_layout() -> String:
	return "packed_valid_cells_v2" if format_version == FORMAT_VERSION_PACKED else "dense_grid_v1"

func valid_cell_count() -> int:
	var count := 0
	for state in validity:
		if state == RELOCATION_STATUS_VALID or state == RELOCATION_STATUS_RELOCATED:
			count += 1
	return count

func relocated_cell_count() -> int:
	var count := 0
	for state in validity:
		if state == RELOCATION_STATUS_RELOCATED:
			count += 1
	return count

func estimated_payload_bytes() -> int:
	var cells := cell_count()
	if cells <= 0 or emitter_count < 0:
		return 0
	var stored := storage_probe_count()
	var float_count := stored * (243 + 81 + emitter_count * 54 + MOMENT_TEXELS_PER_CELL * MOMENT_CHANNELS)
	return float_count * 4 + cells * 13 + source_storage_indices.size() * 4 \
		+ clv_prepared_operators.size() * 4 \
		+ clv_prepared_validity.size() + (clv_prepared_dimensions.size() + clv_prepared_offsets.size()) * 4

## Includes the small live emission_sources buffer held beside the
## immutable source payload by a resident streamed page (six float32 values per
## stable emitter binding).
func estimated_cpu_resident_bytes() -> int:
	var payload_bytes := estimated_payload_bytes()
	if payload_bytes <= 0:
		return 0
	return payload_bytes + emitter_count * 6 * 4

## Immutable GPU input buffers consumed by the dynamic cache. The estimate includes
## transfer/sky/emission float arrays, 128 moment floats and three relocation floats
## per cell, plus validity expanded to one int32 per cell. Output textures, live
## emitter values and parameter buffers are accounted by the runtime cache.
func estimated_gpu_payload_bytes() -> int:
	var cells := cell_count()
	if cells <= 0 or emitter_count < 0:
		return 0
	if has_preinterpolated_clv():
		return clv_prepared_operators.size() * 4
	return cells * (243 + 81 + emitter_count * 54 \
			+ MOMENT_TEXELS_PER_CELL * MOMENT_CHANNELS + 3 + 1) * 4

func allocate(cell_dimensions: Vector3i, source_ids: PackedStringArray) -> bool:
	format_version = FORMAT_VERSION_DENSE
	source_storage_count = 0
	source_storage_indices.clear()
	source_archive_stats.clear()
	_clear_clv_preparation()
	validity.clear()
	relocation_offset_m.clear()
	transfer.clear()
	sky.clear()
	emission.clear()
	receiver_visibility_moments.clear()
	emitter_static_signatures.clear()
	dimensions = cell_dimensions
	emitter_ids = source_ids.duplicate()
	emitter_count = emitter_ids.size()
	probe_count = cell_count()
	if probe_count <= 0 or emitter_count > 32 \
			or estimated_payload_bytes() > MAX_PAYLOAD_BYTES:
		_clear_allocation()
		return false
	validity.resize(probe_count)
	validity.fill(RELOCATION_STATUS_INVALID)
	relocation_offset_m.resize(probe_count)
	relocation_offset_m.fill(Vector3.ZERO)
	transfer.resize(probe_count * 243)
	transfer.fill(0.0)
	sky.resize(probe_count * 81)
	sky.fill(0.0)
	emission.resize(emitter_count * probe_count * 54)
	emission.fill(0.0)
	receiver_visibility_moments.resize(probe_count * MOMENT_TEXELS_PER_CELL * MOMENT_CHANNELS)
	receiver_visibility_moments.fill(0.0)
	emitter_static_signatures.resize(emitter_count)
	return true

func _clear_allocation() -> void:
	source_storage_count = 0
	source_storage_indices.clear()
	source_archive_stats.clear()
	_clear_clv_preparation()
	dimensions = Vector3i.ZERO
	emitter_ids = PackedStringArray()
	emitter_static_signatures = PackedInt64Array()
	emitter_count = 0
	probe_count = 0
	validity.clear()
	relocation_offset_m.clear()
	transfer.clear()
	sky.clear()
	emission.clear()
	receiver_visibility_moments.clear()

func _clear_clv_preparation() -> void:
	clv_preparation_revision = 0
	clv_preparation_signature = ""
	clv_prepared_dimensions.clear()
	clv_prepared_offsets.clear()
	clv_prepared_validity.clear()
	clv_prepared_operators.clear()
	clv_preparation_stats.clear()

func padded_grid_bounds_world() -> AABB:
	if cell_count() <= 0:
		return AABB()
	return AABB(origin_world - Vector3.ONE * (spacing_m * 0.5),
			Vector3(dimensions) * spacing_m)

func is_header_valid(expected_geometry_signature := 0,
		expected_emitter_ids := PackedStringArray(),
		expected_emitter_static_signatures := PackedInt64Array()) -> bool:
	var cells := cell_count()
	if not _storage_version_is_valid() \
			or source_schema_revision != SOURCE_SCHEMA_REVISION_CURRENT \
			or directional_data_revision != DIRECTIONAL_DATA_REVISION \
			or layout != LAYOUT_REGULAR_CELL_CENTERS_V1 \
			or cells <= 0 or probe_count != cells \
			or emitter_count != emitter_ids.size() \
			or emitter_count > 32 \
			or emitter_static_signatures.size() != emitter_count \
			or (expected_geometry_signature != 0 and geometry_signature != expected_geometry_signature) \
			or (not expected_emitter_ids.is_empty() and emitter_ids != expected_emitter_ids) \
			or (not expected_emitter_static_signatures.is_empty() \
				and emitter_static_signatures != expected_emitter_static_signatures):
		return false
	if not _spacing_is_valid() \
			or not source_transform_world.is_finite() \
			or absf(source_transform_world.basis.determinant()) < 0.00000001 \
			or not source_size_m.is_finite() \
			or minf(source_size_m.x, minf(source_size_m.y, source_size_m.z)) <= 0.0 \
			or not source_bounds_world.position.is_finite() \
			or not source_bounds_world.size.is_finite() \
			or minf(source_bounds_world.size.x, minf(source_bounds_world.size.y, \
					source_bounds_world.size.z)) <= 0.0 \
			or not domain_bounds_world.position.is_finite() \
			or not domain_bounds_world.size.is_finite() \
			or minf(domain_bounds_world.size.x, minf(domain_bounds_world.size.y,
					domain_bounds_world.size.z)) <= 0.0 \
			or not origin_world.is_finite() \
			or origin_world.distance_to(domain_bounds_world.position \
					+ Vector3.ONE * (spacing_m * 0.5)) > 0.0001:
		return false
	if source_bounds_world.position.distance_to(domain_bounds_world.position) > 0.0001 \
			or source_bounds_world.size.distance_to(domain_bounds_world.size) > 0.0001:
		return false
	var expected_source_bounds := source_transform_world * AABB(-source_size_m * 0.5, source_size_m)
	if (source_bounds_world.position - expected_source_bounds.position).length() > 0.0001 \
			or (source_bounds_world.size - expected_source_bounds.size).length() > 0.0001:
		return false
	var expected_dimensions := Vector3i((domain_bounds_world.size / spacing_m).ceil())
	if dimensions != expected_dimensions or dimensions.x > MAX_AXIS \
			or dimensions.y > MAX_AXIS or dimensions.z > MAX_AXIS \
			or expected_dimensions.x <= 0 or expected_dimensions.y <= 0 \
			or expected_dimensions.z <= 0:
		return false
	if not is_finite(trace_distance_m) or trace_distance_m <= 0.0 \
			or trace_distance_m > 4096.0 \
			or bake_samples <= 0 or bake_samples > 65536 \
			or bake_bounces <= 0 or bake_bounces > 8 \
			or moment_rays < MIN_MOMENT_RAYS or moment_rays > 65536 \
			or not is_finite(maximum_relocation_m) \
			or maximum_relocation_m < 0.0 or maximum_relocation_m > spacing_m * 0.2:
		return false
	var stored := storage_probe_count()
	if format_version == FORMAT_VERSION_PACKED:
		if stored <= 0 or stored > cells or source_storage_indices.size() != cells \
				or not has_preinterpolated_clv():
			return false
	elif source_storage_count != 0 or not source_storage_indices.is_empty():
		return false
	if validity.size() != cells or relocation_offset_m.size() != cells \
			or transfer.size() != stored * 243 or sky.size() != stored * 81 \
			or emission.size() != emitter_count * stored * 54 \
			or receiver_visibility_moments.size() != stored * MOMENT_TEXELS_PER_CELL * MOMENT_CHANNELS \
			or estimated_payload_bytes() > MAX_PAYLOAD_BYTES:
		return false
	if directional_source_signature.is_empty():
		return false
	if clv_preparation_revision != 0 and not has_preinterpolated_clv():
		return false
	var seen_emitters: Dictionary = {}
	for emitter_id in emitter_ids:
		if emitter_id.is_empty() or seen_emitters.has(emitter_id):
			return false
		seen_emitters[emitter_id] = true
	return true

func _storage_version_is_valid() -> bool:
	return format_version in [FORMAT_VERSION_DENSE, FORMAT_VERSION_PACKED]

func _spacing_is_valid() -> bool:
	return is_finite(spacing_m) and absf(spacing_m - CELL_SPACING_M) <= 0.000001

## Full coefficient validation. Call once on a worker during immutable page
## preparation, never from per-frame admission/status code.
func is_valid(expected_geometry_signature := 0,
		expected_emitter_ids := PackedStringArray(),
		expected_emitter_static_signatures := PackedInt64Array()) -> bool:
	if not is_header_valid(expected_geometry_signature, expected_emitter_ids,
			expected_emitter_static_signatures):
		return false
	if clv_preparation_revision != 0:
		if not has_preinterpolated_clv():
			return false
		var row_bound := float(clv_preparation_stats.get("maximum_operator_row_l1", 0.0))
		if not is_finite(row_bound) or row_bound < 0.0: return false
		var row_l1 := 0.0
		var column := 0
		var columns := 36 + emitter_count * 6
		for value in clv_prepared_operators:
			if not is_finite(value): return false
			if row_bound > 0.0:
				row_l1 += absf(value)
				column += 1
				if column == columns:
					if row_l1 > row_bound * 1.000001: return false
					row_l1 = 0.0
					column = 0
		for state in clv_prepared_validity:
			if state != 0 and state != 1: return false
	var cells := cell_count()
	var stored := storage_probe_count()
	var source_inverse := source_transform_world.affine_inverse()
	var half_size := source_size_m * 0.5
	var valid_cells := 0
	for cell in cells:
		var state := int(validity[cell])
		if state < RELOCATION_STATUS_INVALID or state > RELOCATION_STATUS_RELOCATED:
			return false
		var offset := relocation_offset_m[cell]
		if not offset.is_finite() or offset.length() > maximum_relocation_m + 0.000001:
			return false
		var world_center := origin_world + Vector3(cell_coordinates(cell)) * spacing_m
		var center_local := source_inverse * world_center
		var sample_local := source_inverse * (world_center + offset)
		var center_inside_obb := absf(center_local.x) <= half_size.x + 0.000001 \
				and absf(center_local.y) <= half_size.y + 0.000001 \
				and absf(center_local.z) <= half_size.z + 0.000001
		var sample_inside_obb := absf(sample_local.x) <= half_size.x + 0.000001 \
				and absf(sample_local.y) <= half_size.y + 0.000001 \
				and absf(sample_local.z) <= half_size.z + 0.000001
		if state == RELOCATION_STATUS_INVALID and center_inside_obb \
				and not offset.is_zero_approx():
			return false
		if state != RELOCATION_STATUS_INVALID and (not center_inside_obb or not sample_inside_obb):
			return false
		if state == RELOCATION_STATUS_VALID and offset.length_squared() > 0.0000000001:
			return false
		if state == RELOCATION_STATUS_RELOCATED and offset.length_squared() <= 0.0000000001:
			return false
		var payload_index := storage_index(cell)
		if format_version == FORMAT_VERSION_PACKED:
			if state == RELOCATION_STATUS_INVALID:
				if payload_index != -1 or not offset.is_zero_approx():
					return false
				continue
			# Packing is canonical and one-to-one; this also rejects holes,
			# duplicate aliases, and out-of-bounds reads before payload access.
			if payload_index != valid_cells or payload_index >= stored:
				return false
		var matrix_start := payload_index * 243
		for coefficient in range(matrix_start, matrix_start + 243):
			if not is_finite(transfer[coefficient]):
				return false
		var sky_start := payload_index * 81
		for coefficient in range(sky_start, sky_start + 81):
			if not is_finite(sky[coefficient]):
				return false
		var moment_start := payload_index * MOMENT_TEXELS_PER_CELL * MOMENT_CHANNELS
		for coefficient in range(moment_start, moment_start + MOMENT_TEXELS_PER_CELL * MOMENT_CHANNELS):
			var value := receiver_visibility_moments[coefficient]
			if not is_finite(value) or value < 0.0:
				return false
		if state == RELOCATION_STATUS_INVALID:
			if offset.length_squared() > 0.0000000001:
				return false
			for coefficient in range(matrix_start, matrix_start + 243):
				if transfer[coefficient] != 0.0:
					return false
			for coefficient in range(sky_start, sky_start + 81):
				if sky[coefficient] != 0.0:
					return false
			for emitter in emitter_count:
				var emission_start := (emitter * stored + payload_index) * 54
				for coefficient in range(emission_start, emission_start + 54):
					if emission[coefficient] != 0.0:
						return false
			for coefficient in range(moment_start, moment_start + MOMENT_TEXELS_PER_CELL * MOMENT_CHANNELS):
				if receiver_visibility_moments[coefficient] != 0.0:
					return false
			continue
		valid_cells += 1
		for emitter in emitter_count:
			var emission_start := (emitter * stored + payload_index) * 54
			for coefficient in range(emission_start, emission_start + 54):
				if not is_finite(emission[coefficient]):
					return false
		for texel in MOMENT_TEXELS_PER_CELL:
			var base := moment_start + texel * MOMENT_CHANNELS
			var mean := receiver_visibility_moments[base]
			var second := receiver_visibility_moments[base + 1]
			if mean <= 0.0 or second <= 0.0 \
					or mean > trace_distance_m + 0.001 \
					or second > trace_distance_m * trace_distance_m + 0.01 \
					or second + maxf(0.0001, mean * mean * 0.0001) < mean * mean:
				return false
	return valid_cells > 0 \
		and (format_version != FORMAT_VERSION_PACKED or valid_cells == stored) \
		and directional_source_signature == make_directional_source_signature()

func make_directional_source_signature() -> String:
	var payload := [source_schema_revision, directional_data_revision, layout,
		geometry_signature, emitter_ids, emitter_static_signatures, spacing_m,
		dimensions, origin_world, source_transform_world, source_size_m,
		source_bounds_world, domain_bounds_world, trace_distance_m,
		bake_samples, bake_bounces, moment_rays, maximum_relocation_m]
	var low := int(hash(payload)) & 0xffffffff
	var high := int(hash([payload, "free-space-volume-source-v1"])) & 0xffffffff
	return "%08x%08x" % [high, low]
