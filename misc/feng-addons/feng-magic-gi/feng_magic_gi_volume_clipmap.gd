@tool
class_name FMagicGIVolumeClipmap
extends RefCounted
## Pure camera-to-source lattice mapping for resident free-space CLV windows.
## This class performs no resource allocation, tracing, relighting, or RenderingDevice work.

const SOURCE_SPACING_M := 0.25
const RESOLUTION := 16
const MIN_LOD_COUNT := 3
const MAX_LOD_COUNT := 4
const MAX_SOURCE_AXIS := 256
const MAX_SOURCE_CELLS := 262144
const STATUS_INVALID := 0
const STATUS_VALID := 1
const STATUS_RELOCATED := 2
const SNAP_EPSILON := 0.000001


static func build_layout(source: Resource, camera_world: Vector3,
		resolution := 16, lod_count := 3,
		previous_state: Dictionary = {}) -> Dictionary:
	# The legacy layout-4 response volume keeps its original fixed-size contract.
	if resolution != RESOLUTION:
		return {"valid": false, "error": "current_dynamic_clv_requires_resolution_16"}
	return _build_layout(source, camera_world, resolution, lod_count, previous_state)


static func build_prepared_layout(source: Resource, camera_world: Vector3,
		resolution := 16, previous_state: Dictionary = {}) -> Dictionary:
	if resolution not in [16, 24, 32]:
		return {"valid": false, "error": "prepared_clv_resolution_must_be_16_24_or_32"}
	return _build_layout(source, camera_world, resolution, MAX_LOD_COUNT, previous_state)


static func _build_layout(source: Resource, camera_world: Vector3,
		resolution: int, lod_count: int, previous_state: Dictionary) -> Dictionary:
	var header := _read_source_header(source)
	if not bool(header.get("valid", false)):
		return {"valid": false, "error": str(header.get("error", "invalid_source"))}
	if not camera_world.is_finite():
		return {"valid": false, "error": "camera_world_non_finite"}
	if lod_count < MIN_LOD_COUNT or lod_count > MAX_LOD_COUNT:
		return {"valid": false, "error": "lod_count_must_be_3_or_4"}

	var source_key: Dictionary = header.source_key
	var old_state_valid := _previous_state_matches(previous_state,
			source_key, resolution, lod_count)
	var previous_lods: Array = previous_state.get("lods", []) if old_state_valid else []
	var source_origin: Vector3 = header.origin_world
	var source_dimensions: Vector3i = header.dimensions
	var source_spacing: float = header.spacing_m
	var lod_layouts: Array[Dictionary] = []
	var next_lod_states: Array[Dictionary] = []

	for lod in range(lod_count):
		var stride := 1 << lod
		var previous_lod: Dictionary = previous_lods[lod] if lod < previous_lods.size() else {}
		var has_previous_lod := old_state_valid and not previous_lod.is_empty()
		var previous_center: Vector3i = previous_lod.get("center_source_index", Vector3i.ZERO)
		var center_source_index := Vector3i(
				_snap_source_index(camera_world.x, source_origin.x, source_spacing,
						stride, previous_center.x, has_previous_lod),
				_snap_source_index(camera_world.y, source_origin.y, source_spacing,
						stride, previous_center.y, has_previous_lod),
				_snap_source_index(camera_world.z, source_origin.z, source_spacing,
						stride, previous_center.z, has_previous_lod))
		var half_extent_source_cells := (resolution >> 1) * stride
		var logical_origin_source_index := center_source_index \
				- Vector3i.ONE * half_extent_source_cells
		var logical_delta := Vector3i.ZERO
		var ring_offset := Vector3i.ZERO
		var dirty_full := not has_previous_lod
		if has_previous_lod:
			var previous_origin: Vector3i = previous_lod.get(
					"logical_origin_source_index", logical_origin_source_index)
			var origin_delta := logical_origin_source_index - previous_origin
			logical_delta = Vector3i(
					int(origin_delta.x / stride),
					int(origin_delta.y / stride),
					int(origin_delta.z / stride))
			if origin_delta.x % stride != 0 or origin_delta.y % stride != 0 \
					or origin_delta.z % stride != 0:
				dirty_full = true
			if abs(logical_delta.x) >= resolution or abs(logical_delta.y) >= resolution \
					or abs(logical_delta.z) >= resolution:
				dirty_full = true
			var old_ring: Vector3i = previous_lod.get("ring_offset_mod", Vector3i.ZERO)
			ring_offset = Vector3i(
					_positive_mod(old_ring.x + logical_delta.x, resolution),
					_positive_mod(old_ring.y + logical_delta.y, resolution),
					_positive_mod(old_ring.z + logical_delta.z, resolution))

		var slabs := _build_disjoint_dirty_slabs(logical_delta, resolution, dirty_full)
		var cells_to_update := _flatten_slab_cells(slabs, resolution)
		var origin_world := source_origin + Vector3(logical_origin_source_index) * source_spacing
		var lod_spacing := source_spacing * stride
		var clip_bounds := AABB(origin_world - Vector3.ONE * (lod_spacing * 0.5),
				Vector3.ONE * (resolution * lod_spacing))
		var axis_coverage := Vector3i(
				_count_source_axis_samples(logical_origin_source_index.x, stride,
						resolution, source_dimensions.x),
				_count_source_axis_samples(logical_origin_source_index.y, stride,
						resolution, source_dimensions.y),
				_count_source_axis_samples(logical_origin_source_index.z, stride,
						resolution, source_dimensions.z))
		var lod_layout := {
			"lod": lod,
			"resolution": resolution,
			"stride": stride,
			"spacing_m": lod_spacing,
			"source_spacing_m": source_spacing,
			"source_dimensions": source_dimensions,
			"source_origin_world": source_origin,
			"source_key": source_key,
			"source_instance_id": source.get_instance_id(),
			"center_source_index": center_source_index,
			"logical_origin_source_index": logical_origin_source_index,
			"origin_world": origin_world,
			"clip_bounds_world": clip_bounds,
			"source_axis_sample_coverage": axis_coverage,
			"ring_offset_mod": ring_offset,
			"delta_cells": logical_delta,
			"dirty_full": dirty_full,
			"entering_slabs": slabs,
			"dirty_cell_count": cells_to_update.size(),
			"cells_to_update": cells_to_update,
		}
		lod_layouts.append(lod_layout)
		next_lod_states.append({
			"center_source_index": center_source_index,
			"logical_origin_source_index": logical_origin_source_index,
			"ring_offset_mod": ring_offset,
		})

	var next_state := {
		"source_key": source_key,
		"resolution": resolution,
		"lod_count": lod_count,
		"lods": next_lod_states,
	}
	return {
		"valid": true,
		"error": "",
		"source_key": source_key,
		"source_origin_world": source_origin,
		"source_dimensions": source_dimensions,
		"source_spacing_m": source_spacing,
		"source_domain_bounds_world": header.domain_bounds_world,
		"resolution": resolution,
		"lod_count": lod_count,
		"lods": lod_layouts,
		"state": next_state,
	}


static func map_logical_cell(source: Resource, lod_layout: Dictionary,
		logical_cell: Vector3i) -> Dictionary:
	var resolution := int(lod_layout.get("resolution", 0))
	var stride := int(lod_layout.get("stride", 0))
	if resolution <= 0 or stride <= 0 \
			or logical_cell.x < 0 or logical_cell.y < 0 or logical_cell.z < 0 \
			or logical_cell.x >= resolution or logical_cell.y >= resolution \
			or logical_cell.z >= resolution:
		return {"valid": false, "error": "logical_cell_out_of_range"}
	if source == null or not is_instance_valid(source):
		return {"valid": false, "error": "source_missing"}
	if not source.has_method("cell_index") or not source.has_method("cell_position") \
			or not source.has_method("cell_is_valid"):
		return {"valid": false, "error": "source_cell_api_missing"}
	var source_key_value: Variant = lod_layout.get("source_key")
	var ring_value: Variant = lod_layout.get("ring_offset_mod")
	if not source_key_value is Dictionary or not ring_value is Vector3i:
		return {"valid": false, "error": "lod_layout_header_invalid"}
	if int(lod_layout.get("source_instance_id", 0)) != source.get_instance_id() \
			or source.get("origin_world") != lod_layout.get("source_origin_world") \
			or source.get("dimensions") != lod_layout.get("source_dimensions") \
			or float(source.get("spacing_m")) != float(lod_layout.get("source_spacing_m", 0.0)) \
			or int(source.get("geometry_signature")) != int(source_key_value.get("geometry_signature", 0)) \
			or str(source.get("directional_source_signature")) \
			!= str(source_key_value.get("directional_source_signature", "")):
		return {"valid": false, "error": "source_identity_mismatch"}

	var source_index_origin: Vector3i = lod_layout.get(
			"logical_origin_source_index", Vector3i.ZERO)
	var source_cell := source_index_origin + logical_cell * stride
	var source_dimensions: Vector3i = lod_layout.get("source_dimensions", Vector3i.ZERO)
	var in_bounds := source_cell.x >= 0 and source_cell.y >= 0 and source_cell.z >= 0 \
			and source_cell.x < source_dimensions.x \
			and source_cell.y < source_dimensions.y \
			and source_cell.z < source_dimensions.z
	var source_flat_index := -1
	var state := STATUS_INVALID
	var relocation := Vector3.ZERO
	var source_origin: Vector3 = lod_layout.get("source_origin_world", Vector3.ZERO)
	var source_spacing := float(lod_layout.get("source_spacing_m", SOURCE_SPACING_M))
	var actual_center := source_origin + Vector3(source_cell) * source_spacing
	if in_bounds:
		source_flat_index = int(source.call("cell_index", source_cell))
		var validity_value: Variant = source.get("validity")
		var relocation_value: Variant = source.get("relocation_offset_m")
		if validity_value is PackedByteArray and source_flat_index >= 0 \
				and source_flat_index < validity_value.size():
			state = int(validity_value[source_flat_index])
		if relocation_value is PackedVector3Array and source_flat_index >= 0 \
				and source_flat_index < relocation_value.size():
			relocation = relocation_value[source_flat_index]
		actual_center = source.call("cell_position", source_flat_index, true)
	# Dirty cells outside the baked source or marked invalid are deliberately returned as
	# invalid samples; callers must clear their resident slot rather than retain stale data.
	var sample_valid := in_bounds and source_flat_index >= 0 \
			and (state == STATUS_VALID or state == STATUS_RELOCATED) \
			and bool(source.call("cell_is_valid", source_flat_index))
	return {
		"valid": sample_valid,
		"source_index": source_cell,
		"source_flat_index": source_flat_index,
		"source_validity": state if in_bounds else STATUS_INVALID,
		"relocation_offset_m": relocation,
		"nominal_center_world": source_origin + Vector3(source_cell) * source_spacing,
		"actual_center_world": actual_center,
		"transfer_and_moment_center_world": actual_center,
		"ring_index": Vector3i(
				_positive_mod(logical_cell.x + ring_value.x, resolution),
				_positive_mod(logical_cell.y + ring_value.y, resolution),
				_positive_mod(logical_cell.z + ring_value.z, resolution)),
	}


static func _read_source_header(source: Resource) -> Dictionary:
	if source == null or not is_instance_valid(source):
		return {"valid": false, "error": "source_missing"}
	var origin_value: Variant = source.get("origin_world")
	var dimensions_value: Variant = source.get("dimensions")
	var domain_value: Variant = source.get("domain_bounds_world")
	var spacing := float(source.get("spacing_m"))
	var validity_value: Variant = source.get("validity")
	var relocation_value: Variant = source.get("relocation_offset_m")
	var transfer_value: Variant = source.get("transfer")
	var sky_value: Variant = source.get("sky")
	var emission_value: Variant = source.get("emission")
	var moments_value: Variant = source.get("receiver_visibility_moments")
	if not origin_value is Vector3 or not dimensions_value is Vector3i \
			or not domain_value is AABB or not validity_value is PackedByteArray \
			or not relocation_value is PackedVector3Array \
			or not transfer_value is PackedFloat32Array \
			or not sky_value is PackedFloat32Array \
			or not emission_value is PackedFloat32Array \
			or not moments_value is PackedFloat32Array:
		return {"valid": false, "error": "source_header_types_invalid"}
	var origin: Vector3 = origin_value
	var dimensions: Vector3i = dimensions_value
	var domain_bounds: AABB = domain_value
	if not origin.is_finite() or not domain_bounds.position.is_finite() \
			or not domain_bounds.size.is_finite() or not is_finite(spacing) \
			or absf(spacing - SOURCE_SPACING_M) > SNAP_EPSILON:
		return {"valid": false, "error": "source_spacing_or_bounds_invalid"}
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0:
		return {"valid": false, "error": "source_dimensions_invalid"}
	var cell_count := dimensions.x * dimensions.y * dimensions.z
	var format_version := int(source.get("format_version"))
	var storage_count := cell_count
	if format_version == 2:
		# Packed source payloads retain the same logical .25 m lattice. Layout 5
		# maps prepared operators, not offsets into the source archive arrays.
		if not source.has_method("storage_probe_count") \
				or not source.has_method("is_header_valid") \
				or not bool(source.call("is_header_valid")):
			return {"valid": false, "error": "packed_source_header_invalid"}
		storage_count = int(source.call("storage_probe_count"))
	if dimensions.x > MAX_SOURCE_AXIS or dimensions.y > MAX_SOURCE_AXIS \
			or dimensions.z > MAX_SOURCE_AXIS or cell_count <= 0 \
			or cell_count > MAX_SOURCE_CELLS or validity_value.size() != cell_count \
			or relocation_value.size() != cell_count \
			or storage_count <= 0 or storage_count > cell_count \
			or transfer_value.size() != storage_count * 243 \
			or sky_value.size() != storage_count * 81 \
			or moments_value.size() != storage_count * 128:
		return {"valid": false, "error": "source_cell_arrays_mismatch"}
	if minf(domain_bounds.size.x, minf(domain_bounds.size.y, domain_bounds.size.z)) <= 0.0 \
			or origin.distance_to(domain_bounds.position + Vector3.ONE * spacing * 0.5) > SNAP_EPSILON:
		return {"valid": false, "error": "source_origin_domain_mismatch"}
	var expected_dimensions := Vector3i((domain_bounds.size / spacing).ceil())
	if dimensions != expected_dimensions:
		return {"valid": false, "error": "source_domain_dimensions_mismatch"}
	var signature := str(source.get("directional_source_signature"))
	var geometry_signature := int(source.get("geometry_signature"))
	var source_schema_revision := int(source.get("source_schema_revision"))
	var layout := str(source.get("layout"))
	var emitter_ids_value: Variant = source.get("emitter_ids")
	var emitter_static_value: Variant = source.get("emitter_static_signatures")
	var emitter_count := int(source.get("emitter_count"))
	var probe_count := int(source.get("probe_count"))
	if format_version not in [1, 2] or source_schema_revision != 1 \
			or layout != "regular_cell_centers_v1" or signature.is_empty() \
			or probe_count != cell_count or emitter_count < 0 or emitter_count > 32 \
			or not emitter_ids_value is PackedStringArray \
			or not emitter_static_value is PackedInt64Array \
			or emitter_ids_value.size() != emitter_count \
			or emitter_static_value.size() != emitter_count \
			or emission_value.size() != storage_count * emitter_count * 54:
		return {"valid": false, "error": "source_identity_header_invalid"}
	var source_key := {
		"source_instance_id": source.get_instance_id(),
		"format_version": format_version,
		"source_schema_revision": source_schema_revision,
		"layout": layout,
		"geometry_signature": geometry_signature,
		"directional_source_signature": signature,
		"origin_world": origin,
		"dimensions": dimensions,
		"spacing_m": spacing,
		"domain_bounds_world": domain_bounds,
		"source_transform_world": source.get("source_transform_world"),
		"source_size_m": source.get("source_size_m"),
		"trace_distance_m": float(source.get("trace_distance_m")),
		"bake_samples": int(source.get("bake_samples")),
		"bake_bounces": int(source.get("bake_bounces")),
		"moment_rays": int(source.get("moment_rays")),
		"emitter_ids": emitter_ids_value.duplicate(),
		"emitter_static_signatures": emitter_static_value.duplicate(),
	}
	return {
		"valid": true,
		"error": "",
		"origin_world": origin,
		"dimensions": dimensions,
		"spacing_m": spacing,
		"domain_bounds_world": domain_bounds,
		"source_key": source_key,
	}


static func _previous_state_matches(previous_state: Dictionary,
		source_key: Dictionary, resolution: int, lod_count: int) -> bool:
	if previous_state.is_empty() or previous_state.get("source_key") != source_key \
			or int(previous_state.get("resolution", 0)) != resolution \
			or int(previous_state.get("lod_count", 0)) != lod_count:
		return false
	var previous_lods: Variant = previous_state.get("lods")
	if not previous_lods is Array or previous_lods.size() != lod_count:
		return false
	for previous_lod_value in previous_lods:
		if not previous_lod_value is Dictionary \
				or not previous_lod_value.get("center_source_index") is Vector3i \
				or not previous_lod_value.get("logical_origin_source_index") is Vector3i \
				or not previous_lod_value.get("ring_offset_mod") is Vector3i:
			return false
	return true


static func _snap_source_index(camera_coordinate: float, source_origin: float,
		source_spacing: float, stride: int, previous_center_index: int,
		has_previous: bool) -> int:
	var source_coordinate := (camera_coordinate - source_origin) / source_spacing
	var lattice_coordinate := source_coordinate / float(stride)
	var lower := floori(lattice_coordinate)
	var fraction := lattice_coordinate - float(lower)
	var snapped_lattice := 0
	if absf(fraction - 0.5) <= SNAP_EPSILON:
		var lower_source_index := lower * stride
		var upper_source_index := (lower + 1) * stride
		# Preserve the existing side of an exact half-cell tie. Re-evaluating the
		# tie against only source_coordinate > previous_center_index alternates
		# between its lower and upper neighbors when the previous center is one
		# of those neighbors. With no previous state, pick the upper neighbor as
		# a deterministic initial convention; otherwise retain the prior choice
		# or move away from it if neither neighbor was selected yet.
		if has_previous and (previous_center_index == lower_source_index \
				or previous_center_index == upper_source_index):
			return previous_center_index
		if not has_previous or source_coordinate > float(previous_center_index):
			snapped_lattice = lower + 1
		else:
			snapped_lattice = lower
	else:
		snapped_lattice = floori(lattice_coordinate + 0.5)
	return snapped_lattice * stride


static func _build_disjoint_dirty_slabs(delta: Vector3i,
		resolution: int, dirty_full: bool) -> Array[Dictionary]:
	var slabs: Array[Dictionary] = []
	if dirty_full:
		slabs.append({"full": true, "logical_origin": Vector3i.ZERO,
				"extent": Vector3i.ONE * resolution, "axis": -1,
				"first": 0, "count": resolution, "sign": 0})
		return slabs

	var entering: Array[Vector2i] = []
	var retained: Array[Vector2i] = []
	for axis in range(3):
		var component := _axis_component(delta, axis)
		var amount := abs(component)
		if component > 0:
			entering.append(Vector2i(resolution - amount, amount))
			retained.append(Vector2i(0, resolution - amount))
		elif component < 0:
			entering.append(Vector2i(0, amount))
			retained.append(Vector2i(amount, resolution - amount))
		else:
			entering.append(Vector2i(0, 0))
			retained.append(Vector2i(0, resolution))

	if entering[0].y > 0:
		slabs.append({"full": false, "logical_origin": Vector3i(entering[0].x, 0, 0),
				"extent": Vector3i(entering[0].y, resolution, resolution),
				"axis": 0, "first": entering[0].x, "count": entering[0].y,
				"sign": 1 if delta.x > 0 else -1})
	if entering[1].y > 0 and retained[0].y > 0:
		slabs.append({"full": false,
				"logical_origin": Vector3i(retained[0].x, entering[1].x, 0),
				"extent": Vector3i(retained[0].y, entering[1].y, resolution),
				"axis": 1, "first": entering[1].x, "count": entering[1].y,
				"sign": 1 if delta.y > 0 else -1})
	if entering[2].y > 0 and retained[0].y > 0 and retained[1].y > 0:
		slabs.append({"full": false,
				"logical_origin": Vector3i(retained[0].x, retained[1].x, entering[2].x),
				"extent": Vector3i(retained[0].y, retained[1].y, entering[2].y),
				"axis": 2, "first": entering[2].x, "count": entering[2].y,
				"sign": 1 if delta.z > 0 else -1})
	return slabs


static func _flatten_slab_cells(slabs: Array[Dictionary], resolution: int) -> PackedInt32Array:
	var cells := PackedInt32Array()
	for slab in slabs:
		var origin: Vector3i = slab.logical_origin
		var extent: Vector3i = slab.extent
		for z in range(origin.z, origin.z + extent.z):
			for y in range(origin.y, origin.y + extent.y):
				for x in range(origin.x, origin.x + extent.x):
					cells.append((z * resolution + y) * resolution + x)
	return cells


static func logical_cell_from_flat(flat_index: int, resolution := RESOLUTION) -> Vector3i:
	if resolution <= 0 or flat_index < 0 or flat_index >= resolution * resolution * resolution:
		return Vector3i(-1, -1, -1)
	var x := flat_index % resolution
	var yz := flat_index / resolution
	return Vector3i(x, yz % resolution, yz / resolution)


static func _positive_mod(value: int, modulus: int) -> int:
	return ((value % modulus) + modulus) % modulus


static func _count_source_axis_samples(origin_index: int, stride: int,
		resolution: int, source_extent: int) -> int:
	var first_inside := maxi(0, origin_index)
	var after_last_inside := mini(source_extent, origin_index + resolution * stride)
	if after_last_inside <= first_inside:
		return 0
	var first_aligned := origin_index + maxi(0, ceili(float(first_inside - origin_index) / stride)) * stride
	if first_aligned >= after_last_inside:
		return 0
	return ceili(float(after_last_inside - first_aligned) / stride)


static func _axis_component(value: Vector3i, axis: int) -> int:
	match axis:
		0:
			return value.x
		1:
			return value.y
		_:
			return value.z
