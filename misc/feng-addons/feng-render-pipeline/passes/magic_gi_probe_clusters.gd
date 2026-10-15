@tool
extends RefCounted
## Builds conservative, order-preserving bounds for groups of sparse GI probes.
## The source remains the immutable worker-prepacked index and geometry bundle.

const SCHEMA_VERSION := 1
const SLOTS_PER_CLUSTER := 8
const HEADER_BYTES := 16
const CELL_RANGE_BYTES := 8
const CLUSTER_BYTES := 64
const MAX_CELLS := 262144
const MAX_BYTES := 8 * 1024 * 1024
const NORMAL_BOUND_EPSILON := 0.0005


static func cache_key(data_id: int, generation: int, geometry_revision: int) -> String:
	return "%d:%d:%d" % [data_id, generation, geometry_revision]


static func disabled_payload(signature: String, cell_count := 0) -> Dictionary:
	var bytes := PackedInt32Array([SCHEMA_VERSION, maxi(0, cell_count), 0, 0]).to_byte_array()
	return {"bytes": bytes, "enabled": false, "schema": SCHEMA_VERSION,
		"cell_count": maxi(0, cell_count), "cluster_count": 0,
		"probe_slots": 0, "signature": signature}


static func build(upload: Dictionary, dimensions: Vector3i, probe_count: int,
		signature: String, current_geometry_format := true) -> Dictionary:
	var cells := 0
	if dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0 \
			or dimensions.x > MAX_CELLS or dimensions.y > MAX_CELLS \
			or dimensions.z > MAX_CELLS \
			or dimensions.x > MAX_CELLS / dimensions.y:
		return disabled_payload(signature)
	var xy_cells := dimensions.x * dimensions.y
	if xy_cells > MAX_CELLS / dimensions.z:
		return disabled_payload(signature)
	cells = xy_cells * dimensions.z
	var disabled := disabled_payload(signature, cells)
	if cells <= 0 or probe_count <= 0 \
			or not current_geometry_format \
			or not bool(upload.get("sparse_indices", false)):
		return disabled
	var range_bytes: Variant = upload.get("index_bytes")
	var probe_bytes: Variant = upload.get("index_entries")
	var geometry_value: Variant = upload.get("geometry_image")
	if not range_bytes is PackedByteArray or range_bytes.is_empty() \
			or not probe_bytes is PackedByteArray or probe_bytes.is_empty() \
			or not geometry_value is Image or geometry_value.is_empty():
		return disabled
	var cell_ranges: PackedByteArray = range_bytes
	var probe_indices: PackedByteArray = probe_bytes
	var geometry_image: Image = geometry_value
	if cell_ranges.size() != cells * 8 or probe_indices.size() != probe_count * 4 \
			or geometry_image.get_format() != Image.FORMAT_RGBAF \
			or geometry_image.get_width() != 96 \
			or geometry_image.get_height() * 32 < probe_count:
		return disabled
	var ranges := cell_ranges.to_int32_array()
	var indices := probe_indices.to_int32_array()
	if ranges.size() != cells * 2 or indices.size() != probe_count \
			or probe_count * 4 > MAX_BYTES:
		return disabled
	var maximum_clusters := (MAX_BYTES - HEADER_BYTES - cells * CELL_RANGE_BYTES) / CLUSTER_BYTES
	var expected_first := 0
	var cluster_count := 0
	for cell in cells:
		var source_first := ranges[cell * 2]
		var source_count := ranges[cell * 2 + 1]
		if source_first != expected_first or source_count < 0 \
				or source_first + source_count > indices.size():
			return disabled
		var cell_clusters := (source_count + SLOTS_PER_CLUSTER - 1) / SLOTS_PER_CLUSTER
		if cell_clusters > maximum_clusters - cluster_count:
			return disabled
		cluster_count += cell_clusters
		expected_first += source_count
	if expected_first != indices.size() or indices.size() != probe_count:
		return disabled
	var geometry := geometry_image.get_data().to_float32_array()
	if geometry.size() < probe_count * 12:
		return disabled
	var seen := PackedByteArray()
	seen.resize(probe_count)
	seen.fill(0)
	var packed_ranges := PackedInt32Array()
	packed_ranges.resize(cells * 2)
	var packed_clusters := PackedByteArray()
	expected_first = 0
	cluster_count = 0
	for cell in cells:
		var source_first := ranges[cell * 2]
		var source_count := ranges[cell * 2 + 1]
		if source_first != expected_first or source_count < 0 \
				or source_first + source_count > indices.size():
			return disabled
		packed_ranges[cell * 2] = cluster_count
		packed_ranges[cell * 2 + 1] = ceili(float(source_count) / float(SLOTS_PER_CLUSTER))
		for slot_start in range(0, source_count, SLOTS_PER_CLUSTER):
			var slot_count := mini(SLOTS_PER_CLUSTER, source_count - slot_start)
			var surface_min := Vector3(INF, INF, INF)
			var surface_max := Vector3(-INF, -INF, -INF)
			var normal_min := Vector3(INF, INF, INF)
			var normal_max := Vector3(-INF, -INF, -INF)
			var max_spacing := 0.0
			for cluster_slot in slot_count:
				var probe := indices[source_first + slot_start + cluster_slot]
				if probe < 0 or probe >= probe_count or seen[probe] != 0:
					return disabled
				seen[probe] = 1
				var base := probe * 12
				var surface := Vector3(geometry[base], geometry[base + 1], geometry[base + 2])
				var source_normal := Vector3(geometry[base + 8], geometry[base + 9], geometry[base + 10])
				var local_spacing := geometry[base + 11]
				if not surface.is_finite() or not source_normal.is_finite() \
						or not is_finite(local_spacing) or local_spacing <= 0.0 \
						or source_normal.length_squared() <= 1e-12:
					return disabled
				var normal := source_normal.normalized()
				if not normal.is_finite():
					return disabled
				surface_min = surface_min.min(surface)
				surface_max = surface_max.max(surface)
				normal_min = normal_min.min(normal)
				normal_max = normal_max.max(normal)
				max_spacing = maxf(max_spacing, maxf(local_spacing, 0.001))
			var scale := maxf(1.0, maxf(_max_abs_component(surface_min),
				_max_abs_component(surface_max)))
			var world_margin := maxf(0.00001, scale * 0.000002)
			surface_min -= Vector3.ONE * world_margin
			surface_max += Vector3.ONE * world_margin
			max_spacing += world_margin
			normal_min = (normal_min - Vector3.ONE * NORMAL_BOUND_EPSILON).max(-Vector3.ONE)
			normal_max = (normal_max + Vector3.ONE * NORMAL_BOUND_EPSILON).min(Vector3.ONE)
			packed_clusters.append_array(PackedFloat32Array([
				surface_min.x, surface_min.y, surface_min.z, max_spacing,
				surface_max.x, surface_max.y, surface_max.z, float(slot_count),
				normal_min.x, normal_min.y, normal_min.z, 0.0,
				normal_max.x, normal_max.y, normal_max.z, 0.0,
			]).to_byte_array())
			cluster_count += 1
		expected_first += source_count
	if expected_first != indices.size() or indices.size() != probe_count:
		return disabled
	for probe in probe_count:
		if seen[probe] == 0:
			return disabled
	var byte_count := HEADER_BYTES + packed_ranges.size() * 4 + packed_clusters.size()
	if byte_count > MAX_BYTES or packed_clusters.size() != cluster_count * CLUSTER_BYTES:
		return disabled
	var result := PackedInt32Array([SCHEMA_VERSION, cells, cluster_count, 1]).to_byte_array()
	result.append_array(packed_ranges.to_byte_array())
	result.append_array(packed_clusters)
	return {"bytes": result, "enabled": true, "schema": SCHEMA_VERSION,
		"cell_count": cells, "cluster_count": cluster_count,
		"probe_slots": indices.size(), "signature": signature}


static func _max_abs_component(value: Vector3) -> float:
	return maxf(absf(value.x), maxf(absf(value.y), absf(value.z)))
