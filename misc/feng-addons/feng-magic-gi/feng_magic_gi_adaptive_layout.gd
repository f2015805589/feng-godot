@tool
extends RefCounted
## Finds coarse world cells that need local adaptive surface refinement.

const ProbeLayout = preload("feng_magic_gi_probe_layout.gd")
const MAX_REFINEMENT_CELLS := 524288
const MAX_FEATURE_RAY_QUERIES := 1000000
const MAX_FEATURE_EDGE_SAMPLES := 2000000
const MIN_WORLD_CELL := -2147483648
const MAX_WORLD_CELL := 2147483647
const SHARP_EDGE_NORMAL_DOT := 0.98
const SMALL_ISOLATED_TRIANGLE_AREA_RATIO := 0.25

static func mark_refinement_cells(candidate_cells: Dictionary,
		trace_query: Callable, trace_scene: RefCounted, placement_bounds: AABB,
		base_spacing: float, minimum_spacing: float) -> Dictionary:
	var result := {"cells": {}, "error": ""}
	if minimum_spacing >= base_spacing or base_spacing <= 0.0:
		return result
	if not trace_query.is_valid():
		result["error"] = "Adaptive feature tracing has no geometry-only query."
		return result
	var ray_queries := 0
	var sorted_cells: Array[Vector3i] = []
	for cell_value in candidate_cells:
		sorted_cells.append(cell_value)
	sorted_cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z)
	for world_cell in sorted_cells:
		var cell_bucket: Dictionary = candidate_cells[world_cell]
		var domains: Dictionary = cell_bucket["domains"]
		var sorted_domains: Array[String] = []
		for domain_key in domains:
			sorted_domains.append(String(domain_key))
		sorted_domains.sort()
		for domain_key in sorted_domains:
			var domain_bucket: Dictionary = domains[domain_key]
			for candidate in domain_bucket["candidates"]:
				var normal: Vector3 = candidate["normal"]
				var origin: Vector3 = candidate["center"]
				var tangent := normal.cross(Vector3.UP if absf(normal.y) < 0.99 \
						else Vector3.RIGHT).normalized()
				var bitangent := normal.cross(tangent)
				for direction in [tangent, -tangent, bitangent, -bitangent, normal]:
					ray_queries += 1
					if ray_queries > MAX_FEATURE_RAY_QUERIES:
						result["error"] = "Adaptive feature tracing exceeds its bounded query budget."
						return result
					var hit: Dictionary = trace_query.call(origin, direction, base_spacing)
					if hit.is_empty() or normal.dot(hit.normal) >= 0.95:
						continue
					if not _add_cell_with_halo(result,
							ProbeLayout.world_cell(origin, base_spacing)) \
							or not _add_cell_with_halo(result,
							ProbeLayout.world_cell(hit.position, base_spacing)):
						return result
				# Opposite faces of a thin wall can share one world cell. Every staged
				# surface domain is queried before refinement, so both sides are marked.
				var anchor: Vector3 = candidate["surface"]
				var inside := anchor - normal * minf(0.0001, minimum_spacing * 0.001)
				ray_queries += 1
				if ray_queries > MAX_FEATURE_RAY_QUERIES:
					result["error"] = "Adaptive feature tracing exceeds its bounded query budget."
					return result
				var opposite: Dictionary = trace_query.call(inside, -normal, base_spacing * 0.5)
				if not opposite.is_empty():
					if not _add_cell_with_halo(result,
							ProbeLayout.world_cell(anchor, base_spacing)) \
							or not _add_cell_with_halo(result,
							ProbeLayout.world_cell(opposite.position, base_spacing)):
						return result
	_mark_canonical_triangle_features(trace_scene, placement_bounds,
				base_spacing, result)
	return result

static func _mark_canonical_triangle_features(trace_scene: RefCounted,
		placement_bounds: AABB, base_spacing: float, result: Dictionary) -> void:
	if trace_scene == null:
		return
	var canonical_faces: PackedVector3Array = trace_scene.faces
	if canonical_faces.size() < 3 or canonical_faces.size() % 3 != 0:
		return
	var face_count := int(canonical_faces.size() / 3)
	var face_normals := PackedVector3Array()
	face_normals.resize(face_count)
	var edge_faces: Dictionary = {}
	var edge_points: Dictionary = {}
	var shared_edge_counts := PackedInt32Array()
	shared_edge_counts.resize(face_count)
	for face_index in face_count:
		var base := face_index * 3
		var a: Vector3 = canonical_faces[base]
		var b: Vector3 = canonical_faces[base + 1]
		var c: Vector3 = canonical_faces[base + 2]
		var face_bounds := AABB(a, Vector3.ZERO).expand(b).expand(c)
		if not face_bounds.intersects(placement_bounds):
			continue
		var face_normal := (c - a).cross(b - a).normalized()
		if face_normal.length_squared() < 0.5:
			continue
		face_normals[face_index] = face_normal
		var points := [a, b, c]
		for edge_index in 3:
			var first: Vector3 = points[edge_index]
			var second: Vector3 = points[(edge_index + 1) % 3]
			var first_key := _canonical_vertex_key(first)
			var second_key := _canonical_vertex_key(second)
			var edge_key := first_key + "|" + second_key if first_key < second_key \
					else second_key + "|" + first_key
			var adjacent: Array = edge_faces.get(edge_key, [])
			adjacent.append(face_index)
			edge_faces[edge_key] = adjacent
			if not edge_points.has(edge_key):
				edge_points[edge_key] = [first, second]
	var edge_sample_work := 0
	for edge_key in edge_faces:
		var adjacent: Array = edge_faces[edge_key]
		if adjacent.size() < 2:
			continue
		for face_index in adjacent:
			shared_edge_counts[int(face_index)] += 1
		var sharp := false
		var reference_normal: Vector3 = face_normals[int(adjacent[0])]
		for adjacent_index in range(1, adjacent.size()):
			var other_normal: Vector3 = face_normals[int(adjacent[adjacent_index])]
			if absf(reference_normal.dot(other_normal)) < SHARP_EDGE_NORMAL_DOT:
				sharp = true
				break
		if not sharp:
			continue
		var points: Array = edge_points[edge_key]
		var start: Vector3 = points[0]
		var finish: Vector3 = points[1]
		var clipped_edge := _clip_segment_to_aabb(start, finish,
				placement_bounds.grow(base_spacing))
		if clipped_edge.is_empty():
			continue
		start = clipped_edge[0]
		finish = clipped_edge[1]
		var edge_length := start.distance_to(finish)
		var steps := maxi(1, ceili(edge_length / maxf(base_spacing * 0.5, 0.0001)))
		for step in steps + 1:
			edge_sample_work += 1
			if edge_sample_work > MAX_FEATURE_EDGE_SAMPLES:
				result["error"] = "Adaptive sharp-edge analysis exceeds its bounded sample budget."
				return
			if not _add_cell_with_halo(result, ProbeLayout.world_cell(
					start.lerp(finish, float(step) / float(steps)), base_spacing)):
				return
	for face_index in face_count:
		var base := face_index * 3
		var a: Vector3 = canonical_faces[base]
		var b: Vector3 = canonical_faces[base + 1]
		var c: Vector3 = canonical_faces[base + 2]
		if face_normals[face_index].length_squared() < 0.5:
			continue
		if shared_edge_counts[face_index] > 0:
			continue
		var area := (b - a).cross(c - a).length() * 0.5
		if area > base_spacing * base_spacing * SMALL_ISOLATED_TRIANGLE_AREA_RATIO:
			continue
		# A tiny disconnected triangle can fall between every coarse grid point.
		# Mark its centroid and vertices so the local min-spacing pass can recover it.
		if not _add_cell_with_halo(result, ProbeLayout.world_cell(
				(a + b + c) / 3.0, base_spacing)) \
				or not _add_cell_with_halo(result, ProbeLayout.world_cell(a, base_spacing)) \
				or not _add_cell_with_halo(result, ProbeLayout.world_cell(b, base_spacing)) \
				or not _add_cell_with_halo(result, ProbeLayout.world_cell(c, base_spacing)):
			return

static func _add_cell_with_halo(result: Dictionary, center: Vector3i) -> bool:
	var marked: Dictionary = result["cells"]
	if center.x <= MIN_WORLD_CELL + 1 or center.y <= MIN_WORLD_CELL + 1 \
			or center.z <= MIN_WORLD_CELL + 1 or center.x >= MAX_WORLD_CELL - 1 \
			or center.y >= MAX_WORLD_CELL - 1 or center.z >= MAX_WORLD_CELL - 1:
		result["error"] = "Adaptive feature cells exceed the supported signed world-cell range."
		return false
	for z in range(-1, 2):
		for y in range(-1, 2):
			for x in range(-1, 2):
				var cell := center + Vector3i(x, y, z)
				if marked.has(cell):
					continue
				if marked.size() >= MAX_REFINEMENT_CELLS:
					result["error"] = "Adaptive feature regions exceed the bounded refinement-cell budget."
					return false
				marked[cell] = true
	return true

static func _clip_segment_to_aabb(start: Vector3, finish: Vector3,
		bounds: AABB) -> PackedVector3Array:
	var direction := finish - start
	var minimum_t := 0.0
	var maximum_t := 1.0
	for axis in 3:
		if absf(direction[axis]) < 0.0000001:
			if start[axis] < bounds.position[axis] or start[axis] > bounds.end[axis]:
				return PackedVector3Array()
			continue
		var first_t := (bounds.position[axis] - start[axis]) / direction[axis]
		var second_t := (bounds.end[axis] - start[axis]) / direction[axis]
		if first_t > second_t:
			var swap := first_t
			first_t = second_t
			second_t = swap
		minimum_t = maxf(minimum_t, first_t)
		maximum_t = minf(maximum_t, second_t)
		if minimum_t > maximum_t:
			return PackedVector3Array()
	return PackedVector3Array([start + direction * minimum_t,
			start + direction * maximum_t])

static func _canonical_vertex_key(point: Vector3) -> String:
	return "%d,%d,%d" % [roundi(point.x * 10000.0), roundi(point.y * 10000.0),
			roundi(point.z * 10000.0)]

