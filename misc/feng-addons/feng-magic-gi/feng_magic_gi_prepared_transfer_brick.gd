@tool
class_name FMagicGIPreparedTransferBrick
extends Resource
## One immutable, world-lattice-aligned page of linear SH9 transfer operators.
## Core cells have unique ownership; the one-cell support border is an exact
## copy of neighboring lattice samples, never a separately fitted light field.
const MAX_LEVELS := 10
const MAX_AXIS := 66
const MAX_PAYLOAD_BYTES := 64 * 1024 * 1024
const SOURCE_SPACING_M := 0.25

@export_storage var format_version := 1
@export_storage var source_origin_world := Vector3.ZERO
@export_storage var source_spacing_m := SOURCE_SPACING_M
@export_storage var level := 0
@export_storage var cell_origin := Vector3i.ZERO
@export_storage var dimensions := Vector3i.ZERO
@export_storage var core_cell_origin := Vector3i.ZERO
@export_storage var core_dimensions := Vector3i.ZERO
@export_storage var operators := PackedFloat32Array()
@export_storage var validity := PackedByteArray()
@export_storage var source_transform_world := Transform3D.IDENTITY
@export_storage var source_size_m := Vector3.ZERO
@export_storage var domain_bounds_world := AABB()
@export_storage var emitter_count := 0
@export_storage var emitter_ids := PackedStringArray()
@export_storage var emitter_static_signatures := PackedInt64Array()
@export_storage var geometry_signature := 0
@export_storage var directional_source_signature := ""
@export_storage var maximum_operator_row_l1 := 0.0
@export_storage var probe_count := 0

func spacing_m() -> float:
	return source_spacing_m * float(1 << level)

func operator_stride() -> int:
	return 9 * (36 + 6 * emitter_count)

func cell_count() -> int:
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0 \
			or dimensions.x > MAX_AXIS or dimensions.y > MAX_AXIS or dimensions.z > MAX_AXIS:
		return 0
	return dimensions.x * dimensions.y * dimensions.z

func cell_index(global_cell: Vector3i) -> int:
	var local := global_cell - cell_origin
	if local.x < 0 or local.y < 0 or local.z < 0 \
			or local.x >= dimensions.x or local.y >= dimensions.y or local.z >= dimensions.z:
		return -1
	return (local.z * dimensions.y + local.y) * dimensions.x + local.x

func cell_position(global_cell: Vector3i) -> Vector3:
	return source_origin_world + Vector3(global_cell) * spacing_m()

func core_bounds() -> AABB:
	return AABB(cell_position(core_cell_origin) - Vector3.ONE * spacing_m() * 0.5,
			Vector3(core_dimensions) * spacing_m())

func support_bounds() -> AABB:
	return AABB(cell_position(cell_origin) - Vector3.ONE * spacing_m() * 0.5,
			Vector3(dimensions) * spacing_m())

func estimated_payload_bytes() -> int:
	return operators.size() * 4 + validity.size()

func estimated_cpu_resident_bytes() -> int:
	return estimated_payload_bytes() + emitter_count * 6 * 4

func estimated_gpu_payload_bytes() -> int:
	return operators.size() * 4

func is_header_valid(expected_geometry := 0, expected_ids := PackedStringArray(),
		expected_signatures := PackedInt64Array()) -> bool:
	var count := cell_count()
	if format_version != 1 or count <= 0 or probe_count != count \
			or level < 0 or level >= MAX_LEVELS or source_spacing_m != SOURCE_SPACING_M \
			or not source_origin_world.is_finite() or not source_transform_world.is_finite() \
			or absf(source_transform_world.basis.determinant()) < 0.00000001 \
			or not _positive(source_size_m) or not _positive(domain_bounds_world.size) \
			or not domain_bounds_world.position.is_finite() or directional_source_signature.is_empty() \
			or emitter_count < 0 or emitter_count > 32 or emitter_ids.size() != emitter_count \
			or emitter_static_signatures.size() != emitter_count \
			or not is_finite(maximum_operator_row_l1) or maximum_operator_row_l1 < 0.0 \
			or validity.size() != count or operators.size() != count * operator_stride() \
			or estimated_payload_bytes() > MAX_PAYLOAD_BYTES:
		return false
	if (expected_geometry != 0 and geometry_signature != expected_geometry) \
			or (not expected_ids.is_empty() and emitter_ids != expected_ids) \
			or (not expected_signatures.is_empty() and emitter_static_signatures != expected_signatures):
		return false
	for axis in 3:
		if core_dimensions[axis] <= 0 or core_cell_origin[axis] < cell_origin[axis] \
				or core_cell_origin[axis] + core_dimensions[axis] > cell_origin[axis] + dimensions[axis] \
				or core_cell_origin[axis] - cell_origin[axis] > 1 \
				or cell_origin[axis] + dimensions[axis] - core_cell_origin[axis] - core_dimensions[axis] > 1:
			return false
	var expected := source_transform_world * AABB(-source_size_m * 0.5, source_size_m)
	return expected.position.is_equal_approx(domain_bounds_world.position) \
		and expected.size.is_equal_approx(domain_bounds_world.size)

func is_valid(expected_geometry := 0, expected_ids := PackedStringArray(),
		expected_signatures := PackedInt64Array()) -> bool:
	if not is_header_valid(expected_geometry, expected_ids, expected_signatures): return false
	var columns := 36 + 6 * emitter_count
	for cell in cell_count():
		if validity[cell] > 1: return false
		for row in 9:
			var row_l1 := 0.0
			for column in columns:
				var value := operators[(cell * 9 + row) * columns + column]
				if not is_finite(value) or (validity[cell] == 0 and value != 0.0): return false
				row_l1 += absf(value)
			if maximum_operator_row_l1 > 0.0 and row_l1 > maximum_operator_row_l1 * 1.000001: return false
	return true

static func _positive(value: Vector3) -> bool:
	return value.is_finite() and value.x > 0 and value.y > 0 and value.z > 0
