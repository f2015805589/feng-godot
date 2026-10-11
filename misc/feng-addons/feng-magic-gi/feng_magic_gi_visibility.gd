@tool
extends RefCounted
## Static, two-sided segment blockers. Nodes are depth-first with escape links,
## so the shader needs no traversal stack and cannot overflow a stack silently.

const LEAF_SIZE := 4
const MAX_NODE_VISITS := 256
const MAX_TRIANGLES := 250000
const SPLIT_BINS := 8

static func build(faces: PackedVector3Array) -> Dictionary:
	if faces.is_empty() or faces.size() % 3 != 0 or faces.size() / 3 > MAX_TRIANGLES:
		return {}
	var entries: Array[Dictionary] = []
	for offset in range(0, faces.size(), 3):
		var a := faces[offset]
		var b := faces[offset + 1]
		var c := faces[offset + 2]
		if not a.is_finite() or not b.is_finite() or not c.is_finite():
			return {}
		var bounds := AABB(a, Vector3.ZERO).expand(b).expand(c)
		entries.append({"a": a, "b": b, "c": c, "bounds": bounds, "center": bounds.get_center()})
	_assign_surface_patches(entries)
	var nodes := PackedFloat32Array()
	var triangles := PackedFloat32Array()
	_append_node(entries, nodes, triangles)
	return {"nodes": nodes, "triangles": triangles}

static func _append_node(entries: Array[Dictionary], nodes: PackedFloat32Array,
		triangles: PackedFloat32Array, depth := 0) -> void:
	var bounds: AABB = entries[0].bounds
	for entry in entries:
		bounds = bounds.merge(entry.bounds)
	var offset := nodes.size()
	nodes.resize(offset + 8)
	var upper := bounds.end
	for axis in 3:
		nodes[offset + axis] = bounds.position[axis]
		nodes[offset + 4 + axis] = upper[axis]
	if entries.size() <= LEAF_SIZE:
		# One exactly representable integer packs first triangle and leaf count.
		nodes[offset + 7] = (triangles.size() / 12 + 1) * 8 + entries.size()
		for entry in entries:
			var edge1: Vector3 = entry.b - entry.a
			var edge2: Vector3 = entry.c - entry.a
			var metadata := [edge1.cross(edge2).length(), 1e-8 * maxf(edge1.length() * edge2.length(), 1e-8), float(entry.patch)]
			for lane in 3:
				var vector: Vector3 = [entry.a, edge1, edge2][lane]
				triangles.append_array(PackedFloat32Array([vector.x, vector.y, vector.z, metadata[lane]]))
	else:
		# Surface-area splits keep large room faces separate from dense small meshes.
		# Limit unbalanced recursion; median splits bound the remaining tree depth.
		var halves := _partition(entries) if depth < 32 else []
		if halves.is_empty():
			var axis := bounds.size.max_axis_index()
			entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return a.center[axis] < b.center[axis])
			var middle := entries.size() / 2
			halves = [entries.slice(0, middle), entries.slice(middle)]
		_append_node(halves[0], nodes, triangles, depth + 1)
		_append_node(halves[1], nodes, triangles, depth + 1)
	nodes[offset + 3] = nodes.size() / 8

static func _surface_area(bounds: AABB) -> float:
	var size := bounds.size
	return 2.0 * (size.x * size.y + size.y * size.z + size.z * size.x)

static func _partition(entries: Array[Dictionary]) -> Array:
	var centers := AABB(entries[0].center, Vector3.ZERO)
	for entry in entries:
		centers = centers.expand(entry.center)
	var best_cost := INF
	var best_axis := -1
	var best_bin := -1
	for axis in 3:
		if centers.size[axis] <= 1e-8:
			continue
		var scale := float(SPLIT_BINS) / centers.size[axis]
		var counts := PackedInt32Array()
		counts.resize(SPLIT_BINS)
		var bounds: Array[AABB] = []
		for bin in SPLIT_BINS:
			bounds.append(AABB())
		for entry in entries:
			var bin := clampi(int((entry.center[axis] - centers.position[axis]) * scale), 0, SPLIT_BINS - 1)
			bounds[bin] = entry.bounds if counts[bin] == 0 else bounds[bin].merge(entry.bounds)
			counts[bin] += 1
		var right_cost := PackedFloat64Array()
		right_cost.resize(SPLIT_BINS)
		var accumulated := AABB()
		var count := 0
		for bin in range(SPLIT_BINS - 1, -1, -1):
			if counts[bin] > 0:
				accumulated = bounds[bin] if count == 0 else accumulated.merge(bounds[bin])
				count += counts[bin]
			right_cost[bin] = _surface_area(accumulated) * count
		count = 0
		for bin in SPLIT_BINS - 1:
			if counts[bin] > 0:
				accumulated = bounds[bin] if count == 0 else accumulated.merge(bounds[bin])
				count += counts[bin]
			if count == 0 or count == entries.size():
				continue
			var cost := _surface_area(accumulated) * count + right_cost[bin + 1]
			if cost < best_cost:
				best_cost = cost
				best_axis = axis
				best_bin = bin
	if best_axis < 0:
		return []
	var left: Array[Dictionary] = []
	var right: Array[Dictionary] = []
	var scale := float(SPLIT_BINS) / centers.size[best_axis]
	for entry in entries:
		var bin := clampi(int((entry.center[best_axis] - centers.position[best_axis]) * scale), 0, SPLIT_BINS - 1)
		if bin <= best_bin:
			left.append(entry)
		else:
			right.append(entry)
	return [left, right]

static func _patch_root(parents: PackedInt32Array, triangle: int) -> int:
	while parents[triangle] != triangle:
		parents[triangle] = parents[parents[triangle]]
		triangle = parents[triangle]
	return triangle

static func _assign_surface_patches(entries: Array[Dictionary]) -> void:
	# Only shared edges with continuous, same-facing geometric normals connect.
	# Proximity or a common MeshInstance is not proof of a continuous surface.
	var parents := PackedInt32Array()
	parents.resize(entries.size())
	var normals := PackedVector3Array()
	var vertices: Dictionary = {}
	var shared_edges: Dictionary = {}
	for triangle in entries.size():
		parents[triangle] = triangle
		var entry: Dictionary = entries[triangle]
		var normal: Vector3 = (entry.b - entry.a).cross(entry.c - entry.a)
		normals.append(normal.normalized() if normal.length_squared() > 1e-20 else Vector3.ZERO)
		var corners := PackedInt32Array()
		for vertex: Vector3 in [entry.a, entry.b, entry.c]:
			if not vertices.has(vertex):
				vertices[vertex] = vertices.size()
			corners.append(vertices[vertex])
		for corner in 3:
			var first := corners[corner]
			var second := corners[(corner + 1) % 3]
			if first == second:
				continue
			var edge := (mini(first, second) << 32) | maxi(first, second)
			var neighbors: Array = shared_edges.get(edge, [])
			for neighbor: int in neighbors:
				if normals[triangle].dot(normals[neighbor]) > 0.9:
					var left := _patch_root(parents, triangle)
					var right := _patch_root(parents, neighbor)
					parents[maxi(left, right)] = mini(left, right)
			neighbors.append(triangle)
			shared_edges[edge] = neighbors
	for triangle in entries.size():
		entries[triangle].patch = _patch_root(parents, triangle) + 1

## Identifies an anchor's connected surface once when packing a GPU upload.
## Unknown, ambiguous or budget-exhausted anchors cannot authorize curved reuse.
static func surface_patch(nodes: PackedFloat32Array, triangles: PackedFloat32Array, point: Vector3) -> int:
	var node := 0
	var visits := 0
	var patch := 0
	while node < nodes.size() / 8 and visits < MAX_NODE_VISITS:
		visits += 1
		var offset := node * 8
		var contains := true
		for axis in 3:
			if point[axis] < nodes[offset + axis] - 0.00001 or point[axis] > nodes[offset + 4 + axis] + 0.00001:
				contains = false
		if not contains:
			node = int(nodes[offset + 3])
			continue
		var packed := int(nodes[offset + 7])
		if packed > 0:
			for triangle in range(packed / 8 - 1, packed / 8 - 1 + packed % 8):
				var base := triangle * 12
				var a := Vector3(triangles[base], triangles[base + 1], triangles[base + 2])
				var e1 := Vector3(triangles[base + 4], triangles[base + 5], triangles[base + 6])
				var e2 := Vector3(triangles[base + 8], triangles[base + 9], triangles[base + 10])
				var normal := e1.cross(e2)
				var from_a := point - a
				var denominator := normal.length_squared()
				if denominator < 1e-20 or absf(from_a.dot(normal)) > 0.00001 * sqrt(denominator):
					continue
				var u := from_a.cross(e2).dot(normal) / denominator
				var v := e1.cross(from_a).dot(normal) / denominator
				if u >= -1e-6 and v >= -1e-6 and u + v <= 1.000001:
					var candidate := int(triangles[base + 11])
					if patch != 0 and patch != candidate:
						return 0
					patch = candidate
		node += 1
	return patch if node >= nodes.size() / 8 else 0

static func validate(nodes: PackedFloat32Array, triangles: PackedFloat32Array) -> bool:
	if nodes.is_empty() or nodes.size() % 8 != 0 or triangles.is_empty() \
			or triangles.size() % 12 != 0 or triangles.size() / 12 > MAX_TRIANGLES:
		return false
	for values in [nodes, triangles]:
		for value in values:
			if not is_finite(value):
				return false
	var node_count := nodes.size() / 8
	var triangle_count := triangles.size() / 12
	if int(nodes[3]) != node_count:
		return false
	var leaf_triangles := 0
	for node in node_count:
		var offset := node * 8
		var escape := int(nodes[offset + 3])
		var packed := int(nodes[offset + 7])
		if nodes[offset + 3] != float(escape) or nodes[offset + 7] != float(packed) \
				or escape <= node or escape > node_count or packed < 0:
			return false
		for axis in 3:
			if nodes[offset + axis] > nodes[offset + 4 + axis]:
				return false
		if packed == 0:
			if escape < node + 3:
				return false
			var left := node + 1
			var right := int(nodes[left * 8 + 3])
			if right <= left or right >= escape or int(nodes[right * 8 + 3]) != escape:
				return false
			for child in [left, right]:
				for axis in 3:
					var tolerance := maxf(0.00001, maxf(absf(nodes[offset + axis]),
							absf(nodes[offset + 4 + axis])) * 0.000001)
					if nodes[child * 8 + axis] < nodes[offset + axis] - tolerance \
							or nodes[child * 8 + 4 + axis] > nodes[offset + 4 + axis] + tolerance:
						return false
		else:
			var first := packed / 8 - 1
			var count := packed % 8
			if first != leaf_triangles or count < 1 or count > LEAF_SIZE \
					or first + count > triangle_count or escape != node + 1:
				return false
			for triangle in range(first, first + count):
				if triangles[triangle * 12 + 3] < 0.0 or triangles[triangle * 12 + 7] <= 0.0:
					return false
				var patch := triangles[triangle * 12 + 11]
				if patch < 1.0 or patch > float(triangle_count) or patch != floorf(patch):
					return false
				for axis in 3:
					var a := triangles[triangle * 12 + axis]
					var b := a + triangles[triangle * 12 + 4 + axis]
					var c := a + triangles[triangle * 12 + 8 + axis]
					var tolerance := maxf(0.00001, maxf(absf(a), maxf(absf(b), absf(c))) * 0.000001)
					if minf(a, minf(b, c)) < nodes[offset + axis] - tolerance \
							or maxf(a, maxf(b, c)) > nodes[offset + 4 + axis] + tolerance:
						return false
			leaf_triangles += count
	return leaf_triangles == triangle_count

## Reference traversal used by regression tests and offline inspection. A budget
## exhaustion is blocked, matching the GPU; it must never turn into visibility.
static func segment_blocked(nodes: PackedFloat32Array, triangles: PackedFloat32Array,
		origin: Vector3, target: Vector3, visit_limit := MAX_NODE_VISITS) -> bool:
	var delta := target - origin
	var length := delta.length()
	if length <= 0.00002:
		return false
	var direction := delta / length
	var node := 0
	var visits := 0
	while node < nodes.size() / 8 and visits < visit_limit:
		visits += 1
		var offset := node * 8
		var lower := Vector3(nodes[offset], nodes[offset + 1], nodes[offset + 2])
		var upper := Vector3(nodes[offset + 4], nodes[offset + 5], nodes[offset + 6])
		var near := 0.00001
		var far := length - 0.00001
		var intersects := true
		for axis in 3:
			if absf(direction[axis]) < 1e-8:
				if origin[axis] < lower[axis] - 0.00001 or origin[axis] > upper[axis] + 0.00001:
					intersects = false
			else:
				var t0 := (lower[axis] - 0.00001 - origin[axis]) / direction[axis]
				var t1 := (upper[axis] + 0.00001 - origin[axis]) / direction[axis]
				near = maxf(near, minf(t0, t1))
				far = minf(far, maxf(t0, t1))
		if not intersects or near > far:
			node = int(nodes[offset + 3])
			continue
		var packed := int(nodes[offset + 7])
		if packed > 0:
			for triangle in range(packed / 8 - 1, packed / 8 - 1 + packed % 8):
				var base := triangle * 12
				var a := Vector3(triangles[base], triangles[base + 1], triangles[base + 2])
				var edge1 := Vector3(triangles[base + 4], triangles[base + 5], triangles[base + 6])
				var edge2 := Vector3(triangles[base + 8], triangles[base + 9], triangles[base + 10])
				var p := direction.cross(edge2)
				var determinant := edge1.dot(p)
				if absf(determinant) < triangles[base + 7]:
					continue
				var from_a := origin - a
				var u := from_a.dot(p) / determinant
				var q := from_a.cross(edge1)
				var v := direction.dot(q) / determinant
				var distance := edge2.dot(q) / determinant
				# A length trim alone fails for grazing rays: micrometer normal
				# reconstruction errors become millimeters along the segment.
				if absf(length - distance) * absf(determinant) <= 0.00001 * triangles[base + 3]:
					continue
				if u >= -1e-6 and v >= -1e-6 and u + v <= 1.000001 \
						and distance > 0.00001 and distance < length - 0.00001:
					return true
		node += 1
	return node < nodes.size() / 8
