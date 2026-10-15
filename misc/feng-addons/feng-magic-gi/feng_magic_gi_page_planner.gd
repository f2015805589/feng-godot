@tool
class_name FMagicGIPagePlanner
extends RefCounted
## World aligned sparse management chunks and recursively splittable page cores.

const DEFAULT_MANAGEMENT_BLOCK := 512.0
const DEFAULT_CORE_SIZE := 32.0
const MAX_PAGES := 1000000

static func management_chunks(bounds: AABB, block_size := DEFAULT_MANAGEMENT_BLOCK) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not _valid_bounds(bounds) or not is_finite(block_size) or block_size <= 0.0:
		return result
	var min_x := floori(bounds.position.x / block_size)
	var min_z := floori(bounds.position.z / block_size)
	var max_x := ceili(bounds.end.x / block_size) - 1
	var max_z := ceili(bounds.end.z / block_size) - 1
	if max_x < min_x or max_z < min_z:
		return result
	var count := (max_x - min_x + 1) * (max_z - min_z + 1)
	if count <= 0 or count > MAX_PAGES:
		return result
	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			result.append(Vector2i(x, z))
	return result

static func core_pages(bounds: AABB, block_size := DEFAULT_MANAGEMENT_BLOCK,
		core_size := DEFAULT_CORE_SIZE) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _valid_bounds(bounds) or not is_finite(block_size) or block_size <= 0.0 \
			or not is_finite(core_size) or core_size <= 0.0:
		return result
	var chunks := management_chunks(bounds, block_size)
	if chunks.is_empty():
		return result
	var y_start := bounds.position.y
	var y_end := bounds.end.y
	var y_count := ceili((y_end - y_start) / core_size)
	if y_count <= 0 or chunks.size() * y_count > MAX_PAGES:
		return []
	for chunk in chunks:
		var block_min := Vector2(chunk) * block_size
		var min_x := maxf(bounds.position.x, block_min.x)
		var max_x := minf(bounds.end.x, block_min.x + block_size)
		var min_z := maxf(bounds.position.z, block_min.y)
		var max_z := minf(bounds.end.z, block_min.y + block_size)
		var x_count := ceili((max_x - min_x) / core_size)
		var z_count := ceili((max_z - min_z) / core_size)
		if x_count <= 0 or z_count <= 0 or result.size() + x_count * z_count * y_count > MAX_PAGES:
			return []
		for y_index in y_count:
			var y0 := y_start + float(y_index) * core_size
			var y1 := minf(y_end, y0 + core_size)
			for z_index in z_count:
				var z0 := min_z + float(z_index) * core_size
				var z1 := minf(max_z, z0 + core_size)
				for x_index in x_count:
					var x0 := min_x + float(x_index) * core_size
					var x1 := minf(max_x, x0 + core_size)
					var core := AABB(Vector3(x0, y0, z0), Vector3(x1 - x0, y1 - y0, z1 - z0))
					if not _valid_bounds(core):
						continue
					var key := _page_key(chunk, x0, y0, z0, core_size)
					result.append({
						"page_key": key,
						"chunk_x": chunk.x,
						"chunk_z": chunk.y,
						"core_bounds": core,
					})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.page_key) < str(b.page_key))
	return result

static func support_bounds(core: AABB, probe_spacing: float, minimum_probe_spacing: float,
		clv_cell_size: float, levels := 3) -> AABB:
	if not _valid_bounds(core):
		return AABB()
	var spacing := maxf(probe_spacing, 0.1)
	var fine_spacing := clampf(minimum_probe_spacing, 0.1, spacing)
	# Cover the placement offset, cell interpolation corners, and the largest
	# coarse CLV gather neighborhood without turning a page into a whole volume.
	var base_halo := maxf(spacing, fine_spacing) * 2.0
	var clv_halo := maxf(clv_cell_size, 0.1) \
			* pow(2.0, float(maxi(levels - 1, 0))) * 0.5
	var halo := maxf(base_halo, clv_halo)
	return core.grow(halo)

static func influence_bounds(core: AABB, probe_spacing: float, minimum_probe_spacing: float,
		clv_cell_size: float, bake_distance: float, bake_bounces: int, levels := 3) -> AABB:
	if not is_finite(bake_distance) or bake_distance < 0.0 or bake_bounces < 0:
		return AABB()
	var support := support_bounds(core, probe_spacing, minimum_probe_spacing,
			clv_cell_size, levels)
	if not _valid_bounds(support):
		return AABB()
	# Each bounce can move another finite bake_distance from the previous hit.
	# This is deliberately conservative so chunk edits dirty every page whose
	# traced paths could have sampled geometry in that management chunk.
	return support.grow(bake_distance * float(bake_bounces + 1))

static func intersects_half_open(a: AABB, b: AABB) -> bool:
	return _valid_bounds(a) and _valid_bounds(b) \
			and a.position.x < b.end.x and b.position.x < a.end.x \
			and a.position.y < b.end.y and b.position.y < a.end.y \
			and a.position.z < b.end.z and b.position.z < a.end.z

static func exceeds_page_limits(probe_count: int, grid_dims: Vector3i,
		work_count: int, gpu_bytes: int, cpu_bytes: int,
		gpu_budget := 128 * 1024 * 1024, cpu_budget := 256 * 1024 * 1024) -> bool:
	return probe_count > 32768 or probe_count <= 0 \
			or grid_dims.x > 64 or grid_dims.y > 64 or grid_dims.z > 64 \
			or work_count > 100000000 or gpu_bytes > gpu_budget / 2 \
			or cpu_bytes + gpu_bytes > cpu_budget / 2

static func split_core(core: AABB, minimum_extent := 0.25) -> Array[AABB]:
	var result: Array[AABB] = []
	if not _valid_bounds(core):
		return result
	var axis := 0
	if core.size.y > core.size.x:
		axis = 1
	if core.size.z > core.size[axis]:
		axis = 2
	if core.size[axis] <= minimum_extent:
		return result
	var first_size := core.size
	first_size[axis] = core.size[axis] * 0.5
	var second_size := core.size
	second_size[axis] -= first_size[axis]
	var second_position := core.position
	second_position[axis] += first_size[axis]
	result.append(AABB(core.position, first_size))
	result.append(AABB(second_position, second_size))
	return result

static func core_owner(pages: Array[Dictionary], point: Vector3) -> int:
	var found := -1
	for index in pages.size():
		var bounds: AABB = pages[index].get("core_bounds", AABB())
		if _contains_half_open(bounds, point):
			if found >= 0:
				return -2 # Overlap is a contract error, never choose ambiguous ownership.
			found = index
	return found

static func page_key_for_core(core: AABB, chunk_x: int, chunk_z: int,
		core_size := DEFAULT_CORE_SIZE) -> String:
	if not _valid_bounds(core) or not is_finite(core_size) or core_size <= 0.0:
		return ""
	return _page_key(Vector2i(chunk_x, chunk_z), core.position.x,
		core.position.y, core.position.z, core_size)

static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
			and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0

static func _contains_half_open(bounds: AABB, point: Vector3) -> bool:
	return point.x >= bounds.position.x and point.y >= bounds.position.y \
			and point.z >= bounds.position.z and point.x < bounds.end.x \
			and point.y < bounds.end.y and point.z < bounds.end.z

static func _page_key(chunk: Vector2i, x: float, y: float, z: float, step: float) -> String:
	var ix := roundi(x / step)
	var iy := roundi(y / step)
	var iz := roundi(z / step)
	return "%d,%d/%d,%d,%d" % [chunk.x, chunk.y, ix, iy, iz]
