@tool
extends Resource
## Offline probe positions retained by the bounded multiresolution baker.
## Contains no transport arrays and is never loaded by the rendering pipeline.
const Chunk = preload("feng_magic_gi_volume_source_chunk.gd")
const MAX_PROBES := 262144
@export_storage var probe_exclusions: Array[Transform3D] = []
@export_storage var layout := "multires_source_probe_layout_v1"
@export_storage var dimensions := Vector3i.ZERO
@export_storage var origin_world := Vector3.ZERO
@export_storage var spacing_m := 0.25
@export_storage var source_lod := 0
@export_storage var global_cell_origin := Vector3i.ZERO
@export_storage var prepared_level_count := 0
@export_storage var level_offsets := PackedInt32Array()
@export_storage var probe_count := 0
@export_storage var validity := PackedByteArray()
@export_storage var relocation_offset_m := PackedVector3Array()
@export_storage var geometry_signature := 0
@export_storage var geometry_triangles_sha256 := ""
@export_storage var directional_source_signature := ""
@export_storage var source_transform_world := Transform3D.IDENTITY
@export_storage var source_size_m := Vector3.ZERO
@export_storage var source_bounds_world := AABB()
@export_storage var domain_bounds_world := AABB()
@export_storage var trace_distance_m := 0.0
@export_storage var bake_bounces := 0
@export_storage var olv_probe_domain_payload: Resource

func allocate(grid: Vector3i, levels: int) -> bool:
	if grid.x <= 0 or grid.y <= 0 or grid.z <= 0 or levels < 1 or levels > 10: return false
	var count := 0
	var offsets := PackedInt32Array()
	for level in levels:
		var dims := Vector3i((Vector3(grid) / float(1 << level)).ceil())
		if float(count) + float(dims.x) * dims.y * dims.z > MAX_PROBES: return false
		offsets.append(count)
		count += dims.x * dims.y * dims.z
	offsets.append(count)
	dimensions = grid
	prepared_level_count = levels
	level_offsets = offsets
	probe_count = count
	validity.resize(count)
	validity.fill(0)
	relocation_offset_m.resize(count)
	relocation_offset_m.fill(Vector3.ZERO)
	return true

func level_dimensions(level: int) -> Vector3i:
	return Vector3i((Vector3(dimensions) / float(1 << level)).ceil())

func cell_count() -> int:
	return level_offsets[-1] if level_offsets.size() == prepared_level_count + 1 else 0

func olv_cell_lod(index: int) -> int:
	if index < 0 or index >= probe_count: return -1
	for level in range(prepared_level_count - 1, -1, -1):
		if index >= level_offsets[level]: return level
	return -1

func cell_coordinates(index: int) -> Vector3i:
	var level := olv_cell_lod(index)
	if level < 0: return Vector3i(-1, -1, -1)
	var dims := level_dimensions(level)
	var local_index := index - level_offsets[level]
	var yz := local_index / dims.x
	return Vector3i(local_index % dims.x, yz % dims.y, yz / dims.y)

func cell_position(index: int, apply_relocation := true) -> Vector3:
	var level := olv_cell_lod(index)
	if level < 0: return Vector3.ZERO
	var point := origin_world + Vector3(cell_coordinates(index)) * spacing_m * float(1 << level)
	return point + relocation_offset_m[index] if apply_relocation else point

func cell_is_valid(index: int) -> bool:
	return index >= 0 and index < probe_count and validity.size() == probe_count \
		and validity[index] in [Chunk.RELOCATION_STATUS_VALID, Chunk.RELOCATION_STATUS_RELOCATED]

func valid_cell_count() -> int:
	var count := 0
	for state in validity:
		if state in [Chunk.RELOCATION_STATUS_VALID, Chunk.RELOCATION_STATUS_RELOCATED]: count += 1
	return count

func copy_tile(source: Resource, core_origin: Vector3i, core_dimensions: Vector3i) -> void:
	var level: int = source.source_lod
	var dims := level_dimensions(level)
	for z in core_dimensions.z:
		for y in core_dimensions.y:
			for x in core_dimensions.x:
				var cell := core_origin + Vector3i(x,y,z)
				var source_index: int = source.cell_index(cell - source.global_cell_origin)
				var index := level_offsets[level] + (cell.z * dims.y + cell.y) * dims.x + cell.x
				validity[index] = source.validity[source_index]
				relocation_offset_m[index] = source.relocation_offset_m[source_index]

func is_source_data_valid() -> bool:
	if layout != "multires_source_probe_layout_v1" or prepared_level_count < 1 or prepared_level_count > 10 \
			or source_lod != 0 or global_cell_origin != Vector3i.ZERO \
			or dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0 \
			or probe_count <= 0 or probe_count > MAX_PROBES or cell_count() != probe_count \
			or validity.size() != probe_count or relocation_offset_m.size() != probe_count \
			or not is_finite(spacing_m) or spacing_m <= 0.0 or not origin_world.is_finite() \
			or not source_transform_world.is_finite() or not source_size_m.is_finite() \
			or geometry_triangles_sha256.length() != 64 or directional_source_signature.is_empty(): return false
	var expected := 0
	for level in prepared_level_count:
		if level_offsets[level] != expected: return false
		var dims := level_dimensions(level)
		expected += dims.x * dims.y * dims.z
	if expected != probe_count: return false
	for index in probe_count:
		if validity[index] > Chunk.RELOCATION_STATUS_RELOCATED or not relocation_offset_m[index].is_finite(): return false
	return true

func matches_manifest(manifest: Resource) -> bool:
	return manifest != null and geometry_signature == manifest.bake_geometry_signature \
		and dimensions == Vector3i((manifest.world_bounds.size / manifest.prepared_source_spacing_m).ceil()) \
		and directional_source_signature == manifest.prepared_source_signature \
		and is_equal_approx(spacing_m, manifest.prepared_source_spacing_m) \
		and origin_world.is_equal_approx(manifest.prepared_source_origin_world) \
		and source_transform_world.is_equal_approx(manifest.prepared_source_transform_world) \
		and source_size_m.is_equal_approx(manifest.prepared_source_size_m) \
		and domain_bounds_world.is_equal_approx(manifest.world_bounds) \
		and prepared_level_count == manifest.prepared_level_count
