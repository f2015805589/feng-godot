@tool
extends RefCounted
## CPU-side, resumable geometry index and full-domain BVH enumeration for CLV ABI 13.
## This script is Temp-only until its contract and fixture are reviewed.

const LAYOUT_VERSION := 13
const MAX_CHART_SLOTS := 3
const TRIANGLE_FLOATS := 12
const BVH_NODE_FLOATS := 8
const BVH_LEAF_SIZE := 4
const MAX_EXACT_FLOAT32_UINT := 16777216

var geometry_key := ""
var ready := false
var failed := false
var failure_reason := ""
var phase := "idle"
var triangle_count := 0
var node_count := 0
var work_completed := 0

var _nodes := PackedFloat32Array()
var _triangles := PackedFloat32Array()
var _validate_cursor := 0
var _validated_leaf_triangles := 0
var _node_margin_cursor := -1
var _node_query_margin: Array[Vector3] = []
var _triangle_cursor := 0
var _edge_keys: Array[int] = []
var _edge_records: Dictionary = {}
var _face_owners: Dictionary = {}
var _edge_cursor := 0
var _component_seed_cursor := 0
var _component_seed := -1
var _component_queue: Array[int] = []
var _component_queue_head := 0
var _component_sizes: Array[int] = []
var _exact_shared_edge_count := 0
var _boundary_edge_count := 0
var _nonmanifold_edge_count := 0

var _exact_vertices: Dictionary = {}
var _vertex_positions: Array[Vector3] = []
var _triangle_vertex_ids := PackedInt32Array()
var _triangle_normals := PackedVector3Array()
var _triangle_patches := PackedInt32Array()
var _triangle_bounds: Array[AABB] = []
var _triangle_valid := PackedByteArray()
var _triangle_nonmanifold := PackedByteArray()
var _adjacency: Array = []
var _component_ids := PackedInt32Array()

var _queries: Dictionary = {}


func begin_geometry_epoch(new_geometry_key: String, nodes: PackedFloat32Array,
		triangles: PackedFloat32Array) -> bool:
	_reset()
	if new_geometry_key.is_empty():
		return _fail("empty_geometry_key")
	if nodes.is_empty() or nodes.size() % BVH_NODE_FLOATS != 0:
		return _fail("invalid_bvh_node_array_shape")
	if triangles.is_empty() or triangles.size() % TRIANGLE_FLOATS != 0:
		return _fail("invalid_triangle_array_shape")
	_nodes = nodes
	_triangles = triangles
	node_count = nodes.size() / BVH_NODE_FLOATS
	triangle_count = triangles.size() / TRIANGLE_FLOATS
	if triangle_count > MAX_EXACT_FLOAT32_UINT:
		return _fail("triangle_id_exceeds_exact_float32_record_range")
	geometry_key = new_geometry_key
	# Per-node/per-triangle tables grow as their budgeted validation/index phases visit
	# each item, avoiding a full-scene resize/initialization spike here.
	phase = "validate_bvh"
	return true


## Call with a bounded amount of work each frame. BVH validation, edge-index construction,
## adjacency materialization, and global component labeling are all resumable. No step
## truncates a valid tree or publishes a partially-built index as ready.
func advance_geometry_index(work_budget: int) -> Dictionary:
	if failed:
		return _progress()
	var remaining := maxi(work_budget, 0)
	while remaining > 0 and not ready and not failed:
		var did_work := false
		match phase:
			"validate_bvh":
				if _validate_cursor >= node_count:
					if _validated_leaf_triangles != triangle_count:
						_fail("bvh_leaf_triangle_count_mismatch")
					else:
						_node_margin_cursor = node_count - 1
						phase = "compute_bvh_query_margins"
					continue
				if not _validate_bvh_node(_validate_cursor):
					_fail("invalid_bvh_node_%d" % _validate_cursor)
					continue
				_node_query_margin.append(Vector3.ZERO)
				_validate_cursor += 1
				did_work = true
			"compute_bvh_query_margins":
				if _node_margin_cursor < 0:
					phase = "index_triangles"
					continue
				_node_query_margin[_node_margin_cursor] = _compute_node_query_margin(_node_margin_cursor)
				_node_margin_cursor -= 1
				did_work = true
			"index_triangles":
				if _triangle_cursor >= triangle_count:
					phase = "materialize_edges"
					continue
				if not _index_triangle(_triangle_cursor):
					_fail("invalid_triangle_%d" % _triangle_cursor)
					continue
				_triangle_cursor += 1
				did_work = true
			"materialize_edges":
				if _edge_cursor >= _edge_keys.size():
					phase = "label_components"
					continue
				_materialize_edge(_edge_keys[_edge_cursor])
				_edge_cursor += 1
				did_work = true
			"label_components":
				if _component_queue_head >= _component_queue.size():
					if _component_seed >= 0:
						_component_sizes.append(_component_queue.size())
					_component_queue.clear()
					_component_queue_head = 0
					_component_seed = -1
					if _component_seed_cursor >= triangle_count:
						phase = "ready"
						ready = true
						continue
					var seed := _component_seed_cursor
					_component_seed_cursor += 1
					var found_seed := _triangle_valid[seed] != 0 \
							and _triangle_nonmanifold[seed] == 0 \
							and _component_ids[seed] == 0
					if found_seed:
						_component_seed = seed
						_component_ids[seed] = seed + 1
						_component_queue.append(seed)
				if _component_queue_head < _component_queue.size():
					var current: int = _component_queue[_component_queue_head]
					_component_queue_head += 1
					for neighbor_value in _adjacency[current]:
						var neighbor := int(neighbor_value)
						if _triangle_valid[neighbor] != 0 and _triangle_nonmanifold[neighbor] == 0 \
								and _component_ids[neighbor] == 0:
							_component_ids[neighbor] = _component_seed + 1
							_component_queue.append(neighbor)
				did_work = true
			"ready":
				ready = true
			_:
				_fail("invalid_index_phase_%s" % phase)
		if not did_work:
			continue
		remaining -= 1
		work_completed += 1
	return _progress()


## Starts a full D_i AABB-overlap traversal. half_extent must already include the
## approved D_i radius and geometry margin. The query state survives between frames.
func begin_cell_query(query_key: String, center: Vector3, half_extent: Vector3) -> bool:
	if not ready or failed or query_key.is_empty() or not center.is_finite() \
			or not half_extent.is_finite() or half_extent.x <= 0.0 \
			or half_extent.y <= 0.0 or half_extent.z <= 0.0:
		return false
	_queries[query_key] = {
		"phase": "bvh", "center": center, "half_extent": half_extent,
		"node_cursor": 0, "node_visits": 0, "candidate_ids": [], "candidate_set": {},
		"candidate_duplicates": 0, "partition_cursor": 0, "remaining": {},
		"seed_order": [], "seed_cursor": 0, "candidate_seed_cursor": 0,
		"invalid_candidate_ids": [],
		"local_edge_tests": 0, "domain_triangle_tests": 0,
		"active_seed": -1, "active_normal": Vector3.ZERO, "active_patch": -1,
		"active_anchor": Vector3.ZERO, "active_plane_halfwidth": 0.0,
		"active_component": -1, "queue": [], "queue_head": 0,
		"members": [], "components": [], "invalid_component_ids": {},
		"domain_attempts": [], "domain_prefilter_rejections": [],
		"domain_attempt_index": -1
	}
	return true


## Advance a query using a node-visit budget. It reaches the BVH escape index only
## after visiting every overlapping branch. An invalid escape or repeated leaf ID
## fails the query instead of returning a partial candidate set.
func advance_cell_query(query_key: String, node_budget: int) -> Dictionary:
	if not _queries.has(query_key):
		return {"valid": false, "ready": false, "reason": "unknown_query"}
	var query: Dictionary = _queries[query_key]
	var query_phase := str(query.get("phase", ""))
	if query_phase == "failed" or query_phase == "partition" \
			or query_phase == "components_ready":
		return _query_progress(query)
	var remaining := maxi(node_budget, 0)
	var bounds := AABB(query.center - query.half_extent, query.half_extent * 2.0)
	while remaining > 0 and query_phase != "failed" \
			and query_phase != "partition" and query_phase != "components_ready":
		match query_phase:
			"bvh":
				if int(query.node_cursor) >= node_count:
					query_phase = "prepare_seed_order"
					query.phase = query_phase
					continue
				var node := int(query.node_cursor)
				var offset := node * BVH_NODE_FLOATS
				var lower := Vector3(_nodes[offset], _nodes[offset + 1], _nodes[offset + 2])
				var upper := Vector3(_nodes[offset + 4], _nodes[offset + 5], _nodes[offset + 6])
				var traversal_margin: Vector3 = _node_query_margin[node]
				var escape := int(_nodes[offset + 3])
				if not _aabb_overlaps(bounds.position, bounds.end,
						lower - traversal_margin, upper + traversal_margin):
					query.node_cursor = escape
				else:
					var packed := int(_nodes[offset + 7])
					if packed > 0:
						var first := (packed >> 3) - 1
						var count := packed & 7
						if first < 0 or count < 1 or first + count > triangle_count:
							query_phase = "failed"
							query.reason = "invalid_leaf_range"
							break
						for triangle in range(first, first + count):
							var triangle_bounds: AABB = _triangle_bounds[triangle]
							if not _aabb_overlaps(bounds.position, bounds.end,
									triangle_bounds.position, triangle_bounds.end):
								continue
							if query.candidate_set.has(triangle):
								query.candidate_duplicates = int(query.candidate_duplicates) + 1
								query_phase = "failed"
								query.reason = "duplicate_bvh_candidate_id"
								break
							query.candidate_set[triangle] = true
							query.candidate_ids.append(triangle)
						if query_phase == "failed": break
					if query_phase == "failed": break
					query.node_cursor = node + 1
				query.node_visits = int(query.node_visits) + 1
				remaining -= 1
			"prepare_seed_order":
				var seed_cursor := int(query.candidate_seed_cursor)
				if seed_cursor >= query.candidate_ids.size():
					_start_budgeted_seed_sort(query, "seed_order", "phase", "partition", "seed_sort")
					query_phase = str(query.phase)
					continue
				var triangle := int(query.candidate_ids[seed_cursor])
				query.candidate_seed_cursor = seed_cursor + 1
				if _triangle_valid[triangle] == 0:
					query.invalid_candidate_ids.append(triangle)
					query_phase = "failed"
					query.reason = "invalid_candidate_triangle_%d" % triangle
					break
				if _triangle_nonmanifold[triangle] == 0:
					query.remaining[triangle] = true
					var tri := get_triangle(triangle)
					var closest: Vector3 = _closest_point_triangle(query.center, tri.a, tri.b, tri.c)
					query.seed_order.append({"triangle_id": triangle,
						"distance_squared": query.center.distance_squared_to(closest),
						"anchor": closest})
				remaining -= 1
			"seed_sort":
				_advance_budgeted_seed_sort(query)
				query_phase = str(query.phase)
				remaining -= 1
			_:
				query_phase = "failed"
				query.reason = "invalid_cell_query_phase_%s" % query_phase
				break
		query.phase = query_phase
	_queries[query_key] = query
	return _query_progress(query)


## Builds candidate-local connected components incrementally. Components are formed
## only along unique, same-patch edges and remain inside the seed normal cone. This is
## deliberately not the bake-wide patch ID used as a chart identity.
func advance_local_components(query_key: String, edge_budget: int, step: float,
		plane_tolerance: float, seed_normal_cos := 0.7) -> Dictionary:
	if not _queries.has(query_key):
		return {"valid": false, "ready": false, "reason": "unknown_query"}
	var query: Dictionary = _queries[query_key]
	if str(query.get("phase", "")) == "bvh" \
			or str(query.get("phase", "")) == "prepare_seed_order" \
			or str(query.get("phase", "")) == "seed_sort":
		return {"valid": false, "ready": false, "reason": "candidate_query_incomplete"}
	if str(query.get("phase", "")) == "failed":
		return _query_progress(query)
	if not is_finite(step) or step <= 0.0 or not is_finite(plane_tolerance) \
			or plane_tolerance < 0.0 or not is_finite(seed_normal_cos) \
			or seed_normal_cos < -1.0 or seed_normal_cos > 1.0:
		query.phase = "failed"
		query.reason = "invalid_local_component_tolerance"
		_queries[query_key] = query
		return _query_progress(query)
	if query.has("local_step") and (not is_equal_approx(float(query.local_step), step) \
			or not is_equal_approx(float(query.plane_tolerance), plane_tolerance) \
			or not is_equal_approx(float(query.seed_normal_cos), seed_normal_cos)):
		query.phase = "failed"
		query.reason = "local_component_contract_changed_mid_query"
		_queries[query_key] = query
		return _query_progress(query)
	query["local_step"] = step
	query["plane_tolerance"] = plane_tolerance
	query["seed_normal_cos"] = seed_normal_cos
	query["local_plane_halfwidth"] = 0.45 * step + plane_tolerance
	var remaining := maxi(edge_budget, 0)
	while remaining > 0 and str(query.phase) == "partition":
		if int(query.queue_head) >= query.queue.size():
			if int(query.active_seed) >= 0:
				query.components.append({
					"triangle_ids": query.members,
					"seed_triangle": int(query.active_seed),
					"seed_normal": query.active_normal,
					"anchor": query.active_anchor,
					"local_eligible": bool(query.active_local_eligible),
					"patch_id": int(query.active_patch),
					"component_id": int(query.active_component)
				})
				query.members = []
				query.queue.clear()
				query.queue_head = 0
				query.active_seed = -1
			var seed_info := _next_remaining_candidate_info(query)
			if seed_info.is_empty():
				if int(query.seed_cursor) >= query.seed_order.size():
					query.phase = "components_ready"
					break
				remaining -= 1
				continue
			if bool(seed_info.get("skipped", false)):
				remaining -= 1
				continue
			if not bool(seed_info.get("valid", false)):
				query.phase = "failed"
				query.reason = str(seed_info.get("reason", "invalid_seed_candidate"))
				break
			var seed := int(seed_info.triangle_id)
			query.active_seed = seed
			query.active_normal = _triangle_normals[seed]
			query.active_patch = _triangle_patches[seed]
			query.active_component = _component_ids[seed]
			query.active_anchor = seed_info.anchor
			query.active_plane_halfwidth = float(query.local_plane_halfwidth)
			query.remaining.erase(seed)
			var seed_tri := get_triangle(seed)
			# Domain-sweep revision: the seed-plane slab was an old planar-chart heuristic
			# that split connected curved surfaces. Membership remains constrained by exact
			# shared-edge adjacency, bake patch/component identity, and the normal cone.
			query.active_local_eligible = not seed_tri.is_empty()
			if query.active_local_eligible:
				query.queue.append(seed)
			else:
				query.active_seed = -1
			remaining -= 1
			continue
		var current := int(query.queue[query.queue_head])
		query.queue_head = int(query.queue_head) + 1
		query.members.append(current)
		for neighbor_value in _adjacency[current]:
			query.local_edge_tests = int(query.local_edge_tests) + 1
			var neighbor := int(neighbor_value)
			if not query.remaining.has(neighbor):
				continue
			if _triangle_patches[neighbor] != int(query.active_patch) \
					or _component_ids[neighbor] != int(query.active_component) \
					or _triangle_normals[neighbor].dot(query.active_normal) < seed_normal_cos:
				continue
			var neighbor_tri := get_triangle(neighbor)
			if neighbor_tri.is_empty():
				continue
			query.remaining.erase(neighbor)
			query.queue.append(neighbor)
		remaining -= 1
	_queries[query_key] = query
	return _query_progress(query)


func get_query_components(query_key: String) -> Array:
	if not _queries.has(query_key):
		return []
	var query: Dictionary = _queries[query_key]
	if str(query.get("phase", "")) != "components_ready":
		return []
	return query.components.duplicate(true)


## CPU-only domain revision sweep. This intentionally uses a different policy from
## the frozen layout-11 shader: full D_i participation, curved local components,
## geometry-derived R/H, and normal-cone-aware competing-chart separation.
func begin_chart_domains_sweep(query_key: String, level: int) -> bool:
	if not _queries.has(query_key) or level < 0 or level >= 3:
		return false
	var query: Dictionary = _queries[query_key]
	if str(query.get("phase", "")) != "components_ready":
		return false
	var step := float(query.local_step)
	var center: Vector3 = query.center
	var half_extent: Vector3 = query.half_extent
	var box_margin := maxf(0.00001,
		maxf(step, maxf(absf(center.x), maxf(absf(center.y), absf(center.z)))) \
		* 1.9073486328125e-6)
	var plane_tolerance := maxf(0.00001, step * 0.0001) + box_margin
	query["level"] = level
	query["step"] = step
	query["box_margin"] = box_margin
	query["plane_tolerance"] = plane_tolerance
	query["member_normal_cos"] = 0.55
	query["consumer_normal_cos"] = 0.72
	query["normal_cone_disjoint_dot"] = 2.0 * 0.72 * 0.72 - 1.0
	query["domain_candidate_order"] = []
	query["domain_component_cursor"] = 0
	query["domain_sort_source"] = []
	query["domain_sort_target"] = []
	query["domain_sort_width"] = 0
	query["domain_sort_start"] = 0
	query["domain_sort_left"] = 0
	query["domain_sort_mid"] = 0
	query["domain_sort_right"] = 0
	query["domain_sort_end"] = 0
	query["domain_sort_out"] = 0
	query["domain_prefilter_rejections"] = []
	query["domain_attempts"] = []
	query["domain_accepts"] = []
	query["domain_triangle_tests"] = 0
	query["domain_phase"] = "collect_candidates"
	query["sweep_candidate_cursor"] = 0
	query["sweep_active"] = {}
	query["complete_no_receiver"] = query.candidate_ids.is_empty()
	_queries[query_key] = query
	return true


## Runs one complete uncapped CPU cell solve. Every triangle in the validated D_i
## overlap set is tested; incomplete geometry never publishes a chart.
func advance_chart_domains_sweep(query_key: String, triangle_test_budget: int) -> Dictionary:
	if not _queries.has(query_key):
		return {"valid": false, "ready": false, "reason": "unknown_query"}
	var query: Dictionary = _queries[query_key]
	var domain_phase := str(query.get("domain_phase", ""))
	if domain_phase == "ready" or domain_phase == "failed":
		return _domain_progress(query)
	if domain_phase != "collect_candidates" and domain_phase != "sort_candidates" \
			and domain_phase != "sweep" and domain_phase != "collect_members" \
			and domain_phase != "check_competitors":
		return {"valid": false, "ready": false, "reason": "domain_phase_not_sweep"}
	var remaining := maxi(triangle_test_budget, 0)
	var center: Vector3 = query.center
	var half_extent: Vector3 = query.half_extent
	var plane_tolerance := float(query.plane_tolerance)
	var box_margin := float(query.box_margin)
	var cone_cos := float(query.consumer_normal_cos)
	var disjoint_dot := float(query.normal_cone_disjoint_dot)
	while remaining > 0 and domain_phase != "ready" and domain_phase != "failed":
		match domain_phase:
			"collect_candidates":
				var component_cursor := int(query.domain_component_cursor)
				if component_cursor >= query.components.size():
					_start_budgeted_seed_sort(query, "domain_candidate_order",
						"domain_phase", "sweep", "sort_candidates")
					domain_phase = str(query.domain_phase)
					continue
				var component: Dictionary = query.components[component_cursor]
				query.domain_component_cursor = component_cursor + 1
				var seed := int(component.get("seed_triangle", -1))
				var seed_tri := get_triangle(seed)
				if seed_tri.is_empty() or bool(seed_tri.get("nonmanifold", true)):
					domain_phase = "failed"
					query.domain_reason = "invalid_or_nonmanifold_seed_%d" % seed
					break
				var seed_points := _clip_triangle_vertices_to_box(seed_tri, center, half_extent)
				if seed_points.is_empty():
					query.domain_prefilter_rejections.append({"triangle_id": seed,
						"prefilter_reason": "seed_has_no_geometry_in_D_i"})
					remaining -= 1
					continue
				var anchor := _closest_point_polygon(center, seed_points)
				var anchor_delta := anchor - center
				if absf(anchor_delta.x) > half_extent.x + box_margin \
						or absf(anchor_delta.y) > half_extent.y + box_margin \
						or absf(anchor_delta.z) > half_extent.z + box_margin:
					domain_phase = "failed"
					query.domain_reason = "clipped_seed_anchor_outside_D_i_%d" % seed
					break
				if not anchor.is_finite() or not seed_tri.normal.is_finite() \
						or seed_tri.normal.length_squared() <= 1e-12:
					domain_phase = "failed"
					query.domain_reason = "invalid_seed_geometry_%d" % seed
					break
				query.domain_candidate_order.append({"component": component,
				"triangle_id": seed, "anchor": anchor, "normal": seed_tri.normal,
				"distance_squared": center.distance_squared_to(anchor)})
				remaining -= 1
			"sort_candidates":
				_advance_budgeted_seed_sort(query)
				domain_phase = str(query.domain_phase)
				remaining -= 1
			"sweep":
				if int(query.get("sweep_candidate_cursor", 0)) >= query.domain_candidate_order.size() \
						or query.domain_accepts.size() >= MAX_CHART_SLOTS:
					domain_phase = "ready"
					break
				var sweep_candidate: Dictionary = query.domain_candidate_order[int(query.sweep_candidate_cursor)]
				var sweep_component: Dictionary = sweep_candidate.component
				var sweep_normal: Vector3 = Vector3(sweep_candidate.normal).normalized()
				if sweep_normal.length_squared() <= 1e-12 or not sweep_normal.is_finite():
					query.domain_attempts.append({"triangle_id": int(sweep_candidate.triangle_id),
						"outcome": "invalid_seed_normal"})
					query.sweep_candidate_cursor = int(query.sweep_candidate_cursor) + 1
					remaining -= 1
					continue
				query.sweep_active = {"candidate": sweep_candidate, "component": sweep_component,
					"seed": int(sweep_candidate.triangle_id), "normal": sweep_normal,
					"member_set": {}, "member_cursor": 0, "member_points": [],
					"radius": box_margin, "member_height": 2.0 * plane_tolerance,
					"tube_bounds": AABB(), "competitor_cursor": 0,
					"capped_heights": [], "conflict_id": -1, "conflict_reason": ""}
				domain_phase = "collect_members"
				remaining -= 1
			"collect_members":
				var active_members: Dictionary = query.sweep_active
				var member_component: Dictionary = active_members.component
				if int(active_members.member_cursor) >= member_component.triangle_ids.size():
					if active_members.member_points.is_empty():
						query.domain_attempts.append({"triangle_id": int(active_members.seed),
							"outcome": "empty_local_component_in_D_i"})
						query.sweep_candidate_cursor = int(query.sweep_candidate_cursor) + 1
						domain_phase = "sweep"
						remaining -= 1
						continue
					active_members.tube_bounds = _tube_world_aabb(active_members.candidate.anchor,
						active_members.normal, float(active_members.radius),
						float(active_members.member_height), box_margin)
					# Distinct slots may overlap only if their consumer normal cones are
					# mathematically disjoint. Otherwise preserve source fallback.
					var overlaps_accepted := false
					for accepted_value in query.domain_accepts:
						var accepted_chart: Dictionary = accepted_value
						var accepted_normal := Vector3(accepted_chart.normal).normalized()
						if _aabbs_overlap(active_members.tube_bounds,
								accepted_chart.tube_bounds) \
								and active_members.normal.dot(accepted_normal) >= disjoint_dot - 1e-5:
							overlaps_accepted = true
							break
					if overlaps_accepted:
						query.domain_attempts.append({"triangle_id": int(active_members.seed),
							"outcome": "accepted_chart_tube_overlap_with_compatible_normal"})
						query.sweep_candidate_cursor = int(query.sweep_candidate_cursor) + 1
						domain_phase = "sweep"
						remaining -= 1
						continue
					query.sweep_active = active_members
					domain_phase = "check_competitors"
					remaining -= 1
					continue
				var member_id := int(member_component.triangle_ids[int(active_members.member_cursor)])
				var member_tri := get_triangle(member_id)
				if member_tri.is_empty():
					domain_phase = "failed"
					query.domain_reason = "invalid_member_triangle_%d" % member_id
					break
				var clipped_member := _clip_triangle_vertices_to_box(member_tri, center, half_extent)
				active_members.member_set[member_id] = true
				for point_value in clipped_member:
					var point: Vector3 = point_value
					active_members.member_points.append(point)
					var delta: Vector3 = point - active_members.candidate.anchor
					var member_normal: Vector3 = active_members.normal
					var plane: float = delta.dot(member_normal)
					var tangent: Vector3 = delta - member_normal * plane
					active_members.radius = maxf(float(active_members.radius), tangent.length() + box_margin)
					active_members.member_height = maxf(float(active_members.member_height), absf(plane) + plane_tolerance)
				active_members.member_cursor = int(active_members.member_cursor) + 1
				query.sweep_active = active_members
				remaining -= 1
			"check_competitors":
				var active_competitors: Dictionary = query.sweep_active
				var competitor_candidate: Dictionary = active_competitors.candidate
				var competitor_component: Dictionary = active_competitors.component
				if int(active_competitors.competitor_cursor) >= query.candidate_ids.size():
					var accepted_seed := int(active_competitors.seed)
					var accepted_chart := {"triangle_id": accepted_seed, "triangle_id_plus_one": accepted_seed + 1,
						"anchor": competitor_candidate.anchor, "normal": active_competitors.normal,
						"patch_id": int(competitor_component.patch_id), "component_id": int(competitor_component.component_id),
						"radius": float(active_competitors.radius), "half_height": float(active_competitors.member_height),
						"normal_cos": cone_cos,
						"member_triangle_count": competitor_component.triangle_ids.size(),
						"tube_bounds": active_competitors.tube_bounds,
						"distance_squared": float(competitor_candidate.distance_squared)}
					query.domain_attempts.append({"triangle_id": accepted_seed,
						"patch_id": int(competitor_component.patch_id), "component_id": int(competitor_component.component_id),
						"anchor": _vector3_array(competitor_candidate.anchor),
						"normal": _vector3_array(active_competitors.normal), "R_m": float(active_competitors.radius),
						"H_m": float(active_competitors.member_height),
						"member_triangle_count": competitor_component.triangle_ids.size(),
						"normal_cone_cos": cone_cos,
						"competitor_half_gap_limits": active_competitors.capped_heights,
						"outcome": "certified", "accepted_slot": query.domain_accepts.size()})
					query.domain_accepts.append(accepted_chart)
					query.sweep_candidate_cursor = int(query.sweep_candidate_cursor) + 1
					domain_phase = "sweep"
					remaining -= 1
					continue
				var triangle_id := int(query.candidate_ids[int(active_competitors.competitor_cursor)])
				active_competitors.competitor_cursor = int(active_competitors.competitor_cursor) + 1
				query.domain_triangle_tests = int(query.domain_triangle_tests) + 1
				remaining -= 1
				if active_competitors.member_set.has(triangle_id):
					query.sweep_active = active_competitors
					continue
				var tri := get_triangle(triangle_id)
				if tri.is_empty():
					domain_phase = "failed"
					query.domain_reason = "invalid_competitor_triangle_%d" % triangle_id
					break
				var clipped := _clip_triangle_vertices_to_box(tri, center, half_extent)
				if clipped.is_empty() or not _aabbs_overlap(active_competitors.tube_bounds, _points_aabb(clipped)):
					query.sweep_active = active_competitors
					continue
				if bool(tri.get("nonmanifold", false)):
					active_competitors.conflict_id = triangle_id
					active_competitors.conflict_reason = "nonmanifold_competitor_overlaps_chart_domain"
					query.domain_attempts.append({"triangle_id": int(active_competitors.seed),
						"patch_id": int(competitor_component.patch_id), "component_id": int(competitor_component.component_id),
						"outcome": str(active_competitors.conflict_reason), "conflict_triangle_id": triangle_id})
					query.sweep_candidate_cursor = int(query.sweep_candidate_cursor) + 1
					domain_phase = "sweep"
					query.sweep_active = {}
					continue
				var normal_dot := Vector3(active_competitors.normal).dot(Vector3(tri.normal).normalized())
				if normal_dot >= disjoint_dot - 1e-5:
					var min_signed := INF
					var max_signed := -INF
					for point_value in clipped:
						var point: Vector3 = point_value
						var signed := Vector3(active_competitors.normal).dot(point - competitor_candidate.anchor)
						min_signed = minf(min_signed, signed)
						max_signed = maxf(max_signed, signed)
					var separation := 0.0
					if min_signed > plane_tolerance:
						separation = min_signed
					elif max_signed < -plane_tolerance:
						separation = -max_signed
					var h_limit := 0.5 * separation - plane_tolerance
					active_competitors.capped_heights.append({"triangle_id": triangle_id,
						"normal_dot": normal_dot, "signed_min_m": min_signed,
						"signed_max_m": max_signed, "separation_m": separation,
						"half_gap_H_limit_m": h_limit})
					if separation <= 0.0 or float(active_competitors.member_height) > h_limit:
						active_competitors.conflict_id = triangle_id
						active_competitors.conflict_reason = "normal_compatible_competitor_no_safe_midplane"
						query.domain_attempts.append({"triangle_id": int(active_competitors.seed),
							"patch_id": int(competitor_component.patch_id), "component_id": int(competitor_component.component_id),
							"anchor": _vector3_array(competitor_candidate.anchor),
							"R_m": float(active_competitors.radius), "member_H_m": float(active_competitors.member_height),
							"outcome": str(active_competitors.conflict_reason),
							"conflict_triangle_id": triangle_id,
							"competitor_half_gap_limits": active_competitors.capped_heights})
						query.sweep_candidate_cursor = int(query.sweep_candidate_cursor) + 1
						domain_phase = "sweep"
						query.sweep_active = {}
						continue
				query.sweep_active = active_competitors
			_:
				domain_phase = "failed"
				query.domain_reason = "invalid_domain_phase_%s" % domain_phase
				break
		query.domain_phase = domain_phase
	if domain_phase == "ready":
		query.domain_reason = "certified_%d_geometry_chart(s)" % query.domain_accepts.size() \
				if query.domain_accepts.size() > 0 else "no_safe_geometry_chart"
	query.domain_phase = domain_phase
	_queries[query_key] = query
	return _domain_progress(query)
func _chart_slot_stable_less(a: Dictionary, b: Dictionary) -> bool:
	var ap := int(a.get("patch_id", -1))
	var bp := int(b.get("patch_id", -1))
	if ap != bp: return ap < bp
	var ac := int(a.get("component_id", -1))
	var bc := int(b.get("component_id", -1))
	if ac != bc: return ac < bc
	var an: Vector3 = a.get("normal", Vector3.ZERO)
	var bn: Vector3 = b.get("normal", Vector3.ZERO)
	for axis in 3:
		var aq := roundi(an[axis] * 4096.0)
		var bq := roundi(bn[axis] * 4096.0)
		if aq != bq: return aq < bq
	return int(a.get("triangle_id", -1)) < int(b.get("triangle_id", -1))

func _clip_triangle_vertices_to_box(triangle: Dictionary, center: Vector3,
		half_extent: Vector3) -> Array[Vector3]:
	if triangle.is_empty():
		return []
	var polygon: Array[Vector3] = [triangle.a, triangle.b, triangle.c]
	var lower := center - half_extent
	var upper := center + half_extent
	for axis in 3:
		polygon = _clip_polygon_axis(polygon, axis, lower[axis], true)
		if polygon.is_empty(): return []
		polygon = _clip_polygon_axis(polygon, axis, upper[axis], false)
		if polygon.is_empty(): return []
	return polygon


func _clip_polygon_axis(polygon: Array[Vector3], axis: int, bound: float,
		keep_greater: bool) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if polygon.is_empty(): return out
	var previous: Vector3 = polygon[polygon.size() - 1]
	var previous_inside := previous[axis] >= bound if keep_greater else previous[axis] <= bound
	for current_value in polygon:
		var current: Vector3 = current_value
		var current_inside := current[axis] >= bound if keep_greater else current[axis] <= bound
		if current_inside != previous_inside:
			var denominator := current[axis] - previous[axis]
			if absf(denominator) > 1e-20:
				var t := (bound - previous[axis]) / denominator
				out.append(previous.lerp(current, clampf(t, 0.0, 1.0)))
		if current_inside:
			out.append(current)
		previous = current
		previous_inside = current_inside
	return out


func _closest_point_polygon(point: Vector3, polygon: Array[Vector3]) -> Vector3:
	if polygon.is_empty(): return Vector3.ZERO
	if polygon.size() == 1: return polygon[0]
	var best := polygon[0]
	var best_distance := point.distance_squared_to(best)
	for i in range(1, polygon.size() - 1):
		var candidate := _closest_point_triangle(point, polygon[0], polygon[i], polygon[i + 1])
		var distance := point.distance_squared_to(candidate)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best


func _points_aabb(points: Array[Vector3]) -> AABB:
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return AABB(minimum, maximum - minimum)


## Starts the exact layout-11 conservative domain certification. The margin formulas
## are shared with the frozen shader contract; callers cannot supply policy values.
func begin_chart_domains(query_key: String, level: int) -> bool:
	if not _queries.has(query_key) or level < 0 or level >= 3:
		return false
	var query: Dictionary = _queries[query_key]
	if str(query.get("phase", "")) != "components_ready":
		return false
	var step := float(query.local_step)
	var center: Vector3 = query.center
	var box_margin := maxf(0.00001,
		maxf(step, maxf(absf(center.x), maxf(absf(center.y), absf(center.z)))) \
		* 1.9073486328125e-6)
	var plane_tolerance := maxf(0.00001, step * 0.0001) + box_margin
	query["domain_phase"] = "start_candidate"
	query["level"] = level
	query["step"] = step
	query["box_margin"] = box_margin
	query["plane_tolerance"] = plane_tolerance
	query["radius_scales"] = PackedFloat32Array([1.5, 1.0, 0.75, 0.5, 0.25])
	query["normal_cone_cos"] = 0.7
	query["front_side_epsilon"] = -0.00001
	query["domain_candidate_cursor"] = 0
	query["domain_radius_cursor"] = 0
	query["domain_triangle_cursor"] = 0
	query["domain_candidate"] = {}
	query["domain_member_set"] = {}
	query["domain_accepts"] = []
	query["domain_candidate_order"] = []
	query["domain_attempts"] = []
	query["domain_prefilter_rejections"] = []
	query["domain_attempt_index"] = -1
	query["domain_reason"] = "no_certified_component"
	query["complete_no_receiver"] = query.candidate_ids.is_empty()
	for component in query.components:
		var seed := int(component.seed_triangle)
		var tri := get_triangle(seed)
		var anchor: Vector3 = component.anchor
		var distance_squared := center.distance_squared_to(anchor)
		var side: float = tri.normal.dot(center - anchor) if not tri.is_empty() else -INF
		var in_search_radius := distance_squared <= (1.5 * step) * (1.5 * step)
		var front_side: bool = side >= float(query.front_side_epsilon)
		var summary := {"triangle_id": seed, "patch_id": int(component.patch_id),
			"component_id": int(component.component_id), "anchor": _vector3_array(anchor),
			"normal": _vector3_array(component.seed_normal), "distance_squared": distance_squared,
			"distance_m": sqrt(maxf(distance_squared, 0.0)), "side_dot": side,
			"local_eligible": bool(component.local_eligible),
			"local_triangle_count": component.triangle_ids.size(),
			"within_1_5_step_search_radius": in_search_radius,
			"front_side_gate": front_side}
		if bool(component.local_eligible) and not tri.is_empty() and in_search_radius and front_side:
			var candidate := {"component": component,
				"triangle_id": seed, "anchor": anchor, "normal": tri.normal,
				"distance_squared": distance_squared}
			query.domain_candidate_order.append(candidate)
		else:
			var rejected := summary.duplicate(true)
			if not bool(component.local_eligible): rejected["prefilter_reason"] = "local_component_ineligible"
			elif tri.is_empty(): rejected["prefilter_reason"] = "invalid_seed_triangle"
			elif not in_search_radius: rejected["prefilter_reason"] = "outside_anchor_search_radius"
			else: rejected["prefilter_reason"] = "front_side_cell_center_rejected"
			query.domain_prefilter_rejections.append(rejected)
	query.domain_candidate_order.sort_custom(_seed_candidate_less)
	_queries[query_key] = query
	return true


## Each budget unit evaluates one complete-D_i candidate triangle against one trial
## domain. AABB false positives reject a trial but cannot certify a crossing surface.
func advance_chart_domains(query_key: String, triangle_test_budget: int) -> Dictionary:
	if not _queries.has(query_key):
		return {"valid": false, "ready": false, "reason": "unknown_query"}
	var query: Dictionary = _queries[query_key]
	var domain_phase := str(query.get("domain_phase", ""))
	if domain_phase == "ready" or domain_phase == "failed":
		return _domain_progress(query)
	if domain_phase.is_empty():
		return {"valid": false, "ready": false, "reason": "domain_phase_not_started"}
	var remaining := maxi(triangle_test_budget, 0)
	while remaining > 0 and domain_phase != "ready" and domain_phase != "failed":
		match domain_phase:
			"start_candidate":
				if int(query.domain_candidate_cursor) >= query.domain_candidate_order.size() \
						or query.domain_accepts.size() >= MAX_CHART_SLOTS:
					domain_phase = "ready"
					query.domain_phase = domain_phase
					break
				query.domain_candidate = query.domain_candidate_order[int(query.domain_candidate_cursor)]
				query.domain_member_set = {}
				var component: Dictionary = query.domain_candidate.component
				for member_value in component.triangle_ids:
					query.domain_member_set[int(member_value)] = true
				var attempt := _public_domain_candidate(query.domain_candidate)
				attempt["radius_trials"] = []
				attempt["outcome"] = "in_progress"
				query.domain_attempts.append(attempt)
				query.domain_attempt_index = query.domain_attempts.size() - 1
				query.domain_radius_cursor = 0
				query.domain_triangle_cursor = 0
				domain_phase = "test_candidate"
				query.domain_phase = domain_phase
				continue
			"test_candidate":
				var candidate: Dictionary = query.domain_candidate
				var current_radius := float(query.radius_scales[int(query.domain_radius_cursor)]) \
						* float(query.step) + float(query.box_margin)
				var half_height := 0.45 * float(query.step) + float(query.plane_tolerance)
				var anchor: Vector3 = candidate.anchor
				var normal: Vector3 = candidate.normal
				var tube_bounds := _tube_world_aabb(anchor, normal, current_radius,
						half_height, float(query.box_margin))
				var conflict := false
				var conflict_reason := ""
				var conflict_triangle_id := -1
				var conflict_accepted_slot := -1
				var tested := 0
				for accepted_slot in query.domain_accepts.size():
					var accepted_value: Dictionary = query.domain_accepts[accepted_slot]
					var accepted: Dictionary = accepted_value
					if _aabbs_overlap(tube_bounds, accepted.tube_bounds):
						conflict = true
						conflict_reason = "accepted_chart_tube_aabb_overlap"
						conflict_accepted_slot = accepted_slot
						break
				if not conflict:
					while int(query.domain_triangle_cursor) < query.candidate_ids.size() \
							and tested < remaining:
						var triangle := int(query.candidate_ids[int(query.domain_triangle_cursor)])
						query.domain_triangle_cursor = int(query.domain_triangle_cursor) + 1
						tested += 1
						query.domain_triangle_tests = int(query.domain_triangle_tests) + 1
						if query.domain_member_set.has(triangle):
							continue
						if _aabb_overlaps(tube_bounds.position, tube_bounds.end,
								_triangle_bounds[triangle].position, _triangle_bounds[triangle].end):
							conflict = true
							conflict_reason = "nonmember_D_i_triangle_aabb_overlap"
							conflict_triangle_id = triangle
							break
				var attempt_index := int(query.domain_attempt_index)
				if attempt_index >= 0 and attempt_index < query.domain_attempts.size():
					var current_attempt: Dictionary = query.domain_attempts[attempt_index]
					var trial := {"R_m": current_radius, "H_m": half_height,
						"nonmember_triangles_tested": tested,
						"all_nonmember_D_i_candidates_checked": not conflict \
								and int(query.domain_triangle_cursor) >= query.candidate_ids.size(),
						"conflict": conflict, "conflict_reason": conflict_reason,
						"conflict_triangle_id": conflict_triangle_id,
						"conflict_accepted_slot": conflict_accepted_slot}
					current_attempt.radius_trials.append(trial)
					query.domain_attempts[attempt_index] = current_attempt
				remaining -= tested
				if not conflict and int(query.domain_triangle_cursor) < query.candidate_ids.size():
					query.domain_phase = domain_phase
					_queries[query_key] = query
					break
				if conflict:
					query.domain_radius_cursor = int(query.domain_radius_cursor) + 1
					query.domain_triangle_cursor = 0
					if int(query.domain_radius_cursor) >= query.radius_scales.size():
						if attempt_index >= 0 and attempt_index < query.domain_attempts.size():
							var failed_attempt: Dictionary = query.domain_attempts[attempt_index]
							failed_attempt["outcome"] = "all_radius_trials_conflicted"
							query.domain_attempts[attempt_index] = failed_attempt
						query.domain_candidate_cursor = int(query.domain_candidate_cursor) + 1
						domain_phase = "start_candidate"
					else:
						domain_phase = "test_candidate"
				elif int(query.domain_triangle_cursor) >= query.candidate_ids.size():
					var component: Dictionary = candidate.component
					if attempt_index >= 0 and attempt_index < query.domain_attempts.size():
						var accepted_attempt: Dictionary = query.domain_attempts[attempt_index]
						accepted_attempt["outcome"] = "certified"
						accepted_attempt["accepted_slot"] = query.domain_accepts.size()
						query.domain_attempts[attempt_index] = accepted_attempt
					query.domain_accepts.append({
						"triangle_id": int(candidate.triangle_id),
						"triangle_id_plus_one": int(candidate.triangle_id) + 1,
						"anchor": anchor, "normal": normal,
						"patch_id": int(component.patch_id),
						"component_id": int(component.component_id),
						"radius": current_radius, "half_height": half_height,
						"normal_cos": float(query.normal_cone_cos),
						"member_ids": component.triangle_ids.duplicate(),
						"tube_bounds": tube_bounds,
						"distance_squared": float(candidate.distance_squared)})
					query.domain_reason = "certified_%d_chart(s)" % query.domain_accepts.size()
					query.domain_candidate_cursor = int(query.domain_candidate_cursor) + 1
					domain_phase = "start_candidate"
				query.domain_phase = domain_phase
			"ready":
				break
			_:
				domain_phase = "failed"
				query.domain_phase = domain_phase
				query.domain_reason = "invalid_domain_phase"
				break
		_queries[query_key] = query
	return _domain_progress(query)


func get_chart_records(query_key: String, include_diagnostics: bool = false) -> Dictionary:
	if not _queries.has(query_key):
		return {"valid": false, "reason": "unknown_query"}
	var query: Dictionary = _queries[query_key]
	if str(query.get("domain_phase", "")) != "ready":
		return {"valid": false, "reason": "domain_build_incomplete"}
	var result := {"valid": true, "complete": true, "geometry_key": geometry_key,
		"complete_no_receiver": bool(query.complete_no_receiver),
		"candidate_count": query.candidate_ids.size(),
		"node_visits": int(query.node_visits),
		"local_edge_tests": int(query.local_edge_tests),
		"domain_triangle_tests": int(query.domain_triangle_tests),
		"charts": query.domain_accepts.duplicate(true),
		"domain_reason": str(query.domain_reason),
		"domain_candidate_count": query.domain_candidate_order.size(),
		"domain_attempt_count": query.domain_attempts.size(),
		"domain_prefilter_rejection_count": query.domain_prefilter_rejections.size()}
	if include_diagnostics:
		result["domain_attempts"] = query.domain_attempts.duplicate(true)
		result["domain_prefilter_rejections"] = query.domain_prefilter_rejections.duplicate(true)
	return result


## Builds conservative CPU summary metadata for one same-surface chart in each of
## eight cells. Uniform-slot candidates are tried first. A mixed slot map is only
## accepted when that same patch/component has exactly one chart in every corner.
## The GPU summary-only shader independently rereads the mapped live texels.
static func build_summary_candidate(corner_chart_sets: Array) -> Dictionary:
	if corner_chart_sets.size() != 8:
		return {"valid": false, "reason": "summary_requires_eight_corners"}
	var last_reason := "no_common_chart_slot"
	for selected_slot in MAX_CHART_SLOTS:
		var uniform_slots: Array[int] = []
		for _corner_index in 8:
			uniform_slots.append(selected_slot)
		var candidate := _build_summary_candidate_for_slots(corner_chart_sets,
				uniform_slots, true)
		if bool(candidate.get("valid", false)):
			return candidate
		last_reason = str(candidate.get("reason", last_reason))
	var first_value: Variant = corner_chart_sets[0]
	if not first_value is Array:
		return {"valid": false, "reason": "invalid_corner_chart_set"}
	var first_set: Array = first_value
	var identities: Array[Vector2i] = []
	var seen_identities: Dictionary = {}
	for chart_value in first_set:
		if not chart_value is Dictionary:
			continue
		var chart: Dictionary = chart_value
		var patch_value: Variant = chart.get("patch_id", -1)
		var component_value: Variant = chart.get("component_id", -1)
		if typeof(patch_value) != TYPE_INT or typeof(component_value) != TYPE_INT:
			continue
		var patch_id: int = patch_value
		var component_id: int = component_value
		if patch_id < 0 or component_id < 0:
			continue
		var identity_key := "%d:%d" % [patch_id, component_id]
		if not seen_identities.has(identity_key):
			seen_identities[identity_key] = true
			identities.append(Vector2i(patch_id, component_id))
	var mixed_candidates: Array[Dictionary] = []
	for identity in identities:
		var mapped_slots: Array[int] = []
		var identity_reason := "corner_missing_surface_identity"
		var complete_identity := true
		for corner_index in 8:
			var chart_set_value: Variant = corner_chart_sets[corner_index]
			if not chart_set_value is Array:
				return {"valid": false, "reason": "invalid_corner_chart_set"}
			var chart_set: Array = chart_set_value
			var matches: Array[int] = []
			for slot_index in mini(chart_set.size(), MAX_CHART_SLOTS):
				var chart_value: Variant = chart_set[slot_index]
				if not chart_value is Dictionary:
					continue
				var chart: Dictionary = chart_value
				var patch_value: Variant = chart.get("patch_id", -1)
				var component_value: Variant = chart.get("component_id", -1)
				if typeof(patch_value) == TYPE_INT and typeof(component_value) == TYPE_INT \
						and int(patch_value) == identity.x and int(component_value) == identity.y:
					matches.append(slot_index)
			if matches.size() != 1:
				complete_identity = false
				identity_reason = "corner_ambiguous_surface_identity" \
						if matches.size() > 1 else "corner_missing_surface_identity"
				break
			mapped_slots.append(matches[0])
		if not complete_identity or mapped_slots.size() != 8:
			last_reason = identity_reason
			continue
		var is_uniform := true
		for corner_index in range(1, 8):
			if mapped_slots[corner_index] != mapped_slots[0]:
				is_uniform = false
				break
		if is_uniform:
			# Every uniform mapping was already tested above. Do not duplicate its
			# failure or let it count as a second mixed identity candidate.
			continue
		var candidate := _build_summary_candidate_for_slots(corner_chart_sets,
				mapped_slots, false)
		if bool(candidate.get("valid", false)):
			mixed_candidates.append(candidate)
		else:
			last_reason = str(candidate.get("reason", last_reason))
	if mixed_candidates.size() == 1:
		return mixed_candidates[0]
	if mixed_candidates.size() > 1:
		return {"valid": false, "reason": "mixed_summary_identity_ambiguous"}
	return {"valid": false, "reason": last_reason}


static func _build_summary_candidate_for_slots(corner_chart_sets: Array,
		selected_slots: Array[int], uniform: bool) -> Dictionary:
	if selected_slots.size() != 8:
		return {"valid": false, "reason": "summary_requires_eight_slot_indices"}
	var selected_patch := -1
	var selected_component := -1
	var normals: Array[Vector3] = []
	var anchors: Array[Vector3] = []
	var radii: Array[float] = []
	var heights: Array[float] = []
	for corner_index in 8:
		var chart_set_value: Variant = corner_chart_sets[corner_index]
		if not chart_set_value is Array:
			return {"valid": false, "reason": "invalid_corner_chart_set"}
		var chart_set: Array = chart_set_value
		if chart_set.size() > MAX_CHART_SLOTS:
			return {"valid": false, "reason": "corner_chart_count_exceeds_abi"}
		var selected_slot := selected_slots[corner_index]
		if selected_slot < 0 or selected_slot >= MAX_CHART_SLOTS \
				or selected_slot >= chart_set.size():
			return {"valid": false, "reason": "corner_missing_selected_slot"}
		if not chart_set[selected_slot] is Dictionary:
			return {"valid": false, "reason": "selected_chart_not_dictionary"}
		var chart: Dictionary = chart_set[selected_slot]
		if corner_index == 0:
			var patch_value: Variant = chart.get("patch_id", -1)
			var component_value: Variant = chart.get("component_id", -1)
			if typeof(patch_value) != TYPE_INT or typeof(component_value) != TYPE_INT:
				return {"valid": false, "reason": "summary_surface_identity_invalid"}
			selected_patch = int(patch_value)
			selected_component = int(component_value)
		if selected_patch < 0 or selected_component < 0:
			return {"valid": false, "reason": "summary_surface_identity_invalid"}
		if typeof(chart.get("patch_id", -1)) != TYPE_INT \
				or typeof(chart.get("component_id", -1)) != TYPE_INT \
				or int(chart.get("patch_id", -1)) != selected_patch \
				or int(chart.get("component_id", -1)) != selected_component:
			return {"valid": false, "reason": "corner_surface_identity_mismatch"}
		var normal_value: Variant = chart.get("normal", Vector3.ZERO)
		var anchor_value: Variant = chart.get("anchor", Vector3.ZERO)
		if not normal_value is Vector3 or not anchor_value is Vector3:
			return {"valid": false, "reason": "invalid_corner_geometry_types"}
		var normal: Vector3 = normal_value
		var anchor: Vector3 = anchor_value
		if not normal.is_finite() or normal.length_squared() <= 1e-12 \
				or not anchor.is_finite():
			return {"valid": false, "reason": "invalid_corner_geometry"}
		var radius := float(chart.get("radius", 0.0))
		var half_height := float(chart.get("half_height", 0.0))
		if not is_finite(radius) or not is_finite(half_height) \
				or radius <= 0.0 or half_height <= 0.0:
			return {"valid": false, "reason": "invalid_corner_domain"}
		normals.append(normal.normalized())
		anchors.append(anchor)
		radii.append(radius)
		heights.append(half_height)
	var nbar := Vector3.ZERO
	var center := Vector3.ZERO
	for index in 8:
		nbar += normals[index]
		center += anchors[index]
	if nbar.length_squared() <= 1e-12:
		return {"valid": false, "reason": "summary_normal_cancels"}
	nbar = nbar.normalized()
	center /= 8.0
	var a := INF
	var b := INF
	var max_sine := 0.0
	var max_normal_deviation := 0.0
	for index in 8:
		var cosine := clampf(normals[index].dot(nbar), -1.0, 1.0)
		if cosine < 0.99:
			return {"valid": false, "reason": "summary_normal_cone_too_wide"}
		var offset := center - anchors[index]
		var signed_height := normals[index].dot(offset)
		var tangent_length := (offset - normals[index] * signed_height).length()
		a = minf(a, radii[index] - tangent_length)
		b = minf(b, heights[index] - absf(signed_height))
		max_sine = maxf(max_sine, sqrt(maxf(0.0, 1.0 - cosine * cosine)))
		max_normal_deviation = maxf(max_normal_deviation,
				(normals[index] - nbar).length())
	var denominator := 1.0 - max_sine * max_sine
	if denominator <= 1e-6:
		return {"valid": false, "reason": "summary_domain_denominator_invalid"}
	var radius_fast := (a - max_sine * b) / denominator
	var height_fast := (b - max_sine * a) / denominator
	if not is_finite(radius_fast) or not is_finite(height_fast) \
			or radius_fast <= 1e-6 or height_fast <= 1e-6:
		return {"valid": false, "reason": "summary_domain_has_no_positive_interior"}
	if not uniform and _mixed_summary_has_competing_chart(corner_chart_sets,
			selected_slots, nbar, center, radius_fast, height_fast):
		return {"valid": false, "reason": "mixed_summary_competing_chart_may_match"}
	var slot_map := 0
	var uniform_slot := selected_slots[0] if uniform else -1
	for corner_index in 8:
		var mapped_slot := selected_slots[corner_index]
		if mapped_slot < 0 or mapped_slot >= MAX_CHART_SLOTS:
			return {"valid": false, "reason": "summary_slot_map_invalid"}
		slot_map |= mapped_slot << (corner_index * 2)
		if uniform and mapped_slot != uniform_slot:
			return {"valid": false, "reason": "summary_uniform_slot_mismatch"}
	return {"valid": true, "slot": uniform_slot, "uniform_slot": uniform_slot,
		"slots": selected_slots.duplicate(), "slot_map": slot_map,
		"mixed": not uniform, "patch_id": selected_patch,
		"component_id": selected_component, "normal": nbar, "center": center,
		"radius": radius_fast, "half_height": height_fast,
		"max_normal_deviation": max_normal_deviation,
		"positive_corner_mask": 0xff}


static func _mixed_summary_has_competing_chart(corner_chart_sets: Array,
		selected_slots: Array[int], nbar: Vector3, center: Vector3,
		radius: float, half_height: float) -> bool:
	# Mixed summaries skip the ordinary per-pixel three-slot matcher. Reject a
	# summary if any unselected, geometrically valid chart could match a shading
	# normal in the summary cone and its conservative tube AABB overlaps the
	# summary cylinder AABB. This can create false misses, never false matches.
	var summary_extent := radius + half_height
	var summary_min := center - Vector3.ONE * summary_extent
	var summary_max := center + Vector3.ONE * summary_extent
	for corner_index in 8:
		var chart_set_value: Variant = corner_chart_sets[corner_index]
		if not chart_set_value is Array:
			return true
		var chart_set: Array = chart_set_value
		for slot_index in mini(chart_set.size(), MAX_CHART_SLOTS):
			if slot_index == selected_slots[corner_index]:
				continue
			var chart_value: Variant = chart_set[slot_index]
			if not chart_value is Dictionary:
				continue
			var chart: Dictionary = chart_value
			var patch_id := int(chart.get("patch_id", -1))
			var component_id := int(chart.get("component_id", -1))
			if patch_id < 0 or component_id < 0:
				continue
			var normal_value: Variant = chart.get("normal", Vector3.ZERO)
			var anchor_value: Variant = chart.get("anchor", Vector3.ZERO)
			if not normal_value is Vector3 or not anchor_value is Vector3:
				continue
			var competitor_normal: Vector3 = normal_value
			var anchor: Vector3 = anchor_value
			var radius_other := float(chart.get("radius", 0.0))
			var height_other := float(chart.get("half_height", 0.0))
			var normal_cos_value := float(chart.get("normal_cos", 0.72))
			if not is_finite(normal_cos_value):
				continue
			var normal_cos := clampf(normal_cos_value, -1.0, 1.0)
			if not competitor_normal.is_finite() or competitor_normal.length_squared() <= 1e-12 \
					or not anchor.is_finite() or not is_finite(radius_other) \
					or not is_finite(height_other) or radius_other <= 0.0 \
					or height_other <= 0.0:
				continue
			competitor_normal = competitor_normal.normalized()
			# Spherical-cap intersection: a pixel normal passes both the summary
			# dot>=.95 gate and this chart's normal_cos gate only above this bound.
			var summary_cos := 0.95
			var sin_summary := sqrt(maxf(0.0, 1.0 - summary_cos * summary_cos))
			var sin_competitor := sqrt(maxf(0.0, 1.0 - normal_cos * normal_cos))
			var compatible_threshold := summary_cos * normal_cos \
					- sin_summary * sin_competitor
			if nbar.dot(competitor_normal) < compatible_threshold:
				continue
			var competitor_extent := radius_other + height_other
			var competitor_min := anchor - Vector3.ONE * competitor_extent
			var competitor_max := anchor + Vector3.ONE * competitor_extent
			var separated := summary_max.x < competitor_min.x \
					or summary_min.x > competitor_max.x \
					or summary_max.y < competitor_min.y \
					or summary_min.y > competitor_max.y \
					or summary_max.z < competitor_min.z \
					or summary_min.z > competitor_max.z
			if not separated:
				return true
	return false


func _public_domain_candidate(candidate: Dictionary) -> Dictionary:
	var component: Dictionary = candidate.component
	return {"seed_triangle_id": int(candidate.triangle_id),
		"patch_id": int(component.patch_id), "global_component_id": int(component.component_id),
		"anchor": _vector3_array(candidate.anchor), "normal": _vector3_array(candidate.normal),
		"distance_squared_m2": float(candidate.distance_squared),
		"distance_m": sqrt(maxf(float(candidate.distance_squared), 0.0)),
		"local_triangle_count": component.triangle_ids.size()}


func _vector3_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]


func get_triangle(triangle_id: int) -> Dictionary:
	if not ready or triangle_id < 0 or triangle_id >= triangle_count \
			or _triangle_valid[triangle_id] == 0:
		return {}
	var base := triangle_id * TRIANGLE_FLOATS
	var a := _canonical_zero(Vector3(_triangles[base], _triangles[base + 1], _triangles[base + 2]))
	var e1 := Vector3(_triangles[base + 4], _triangles[base + 5], _triangles[base + 6])
	var e2 := Vector3(_triangles[base + 8], _triangles[base + 9], _triangles[base + 10])
	return {"id": triangle_id, "a": a,
		"b": _canonical_zero(_float32_vec3(a + e1)),
		"c": _canonical_zero(_float32_vec3(a + e2)),
		"normal": _triangle_normals[triangle_id], "patch_id": _triangle_patches[triangle_id],
		"component_id": _component_ids[triangle_id], "bounds": _triangle_bounds[triangle_id],
		"nonmanifold": _triangle_nonmanifold[triangle_id] != 0}


func clear_queries() -> void:
	_queries.clear()


func forget_query(query_key: String) -> void:
	_queries.erase(query_key)


func get_index_audit() -> Dictionary:
	if not ready or failed:
		return {"valid": false, "phase": phase, "reason": failure_reason}
	var adjacency_pairs := 0
	for neighbors in _adjacency:
		adjacency_pairs += neighbors.size()
	return {"valid": true, "geometry_key": geometry_key,
		"node_count": node_count, "triangle_count": triangle_count,
		"exact_vertex_count": _vertex_positions.size(),
		"global_component_count": _component_sizes.size(),
		"global_component_triangle_counts": _component_sizes.duplicate(),
		"exact_shared_edge_count": _exact_shared_edge_count,
		"boundary_edge_count": _boundary_edge_count,
		"nonmanifold_edge_count": _nonmanifold_edge_count,
		"adjacency_pairs": int(adjacency_pairs / 2)}


func _triangle_containment_tolerance(triangle: int) -> Vector3:
	var base := triangle * TRIANGLE_FLOATS
	var tolerance := Vector3.ZERO
	for axis in 3:
		var a_value := _triangles[base + axis]
		var b_value := a_value + _triangles[base + 4 + axis]
		var c_value := a_value + _triangles[base + 8 + axis]
		tolerance[axis] = maxf(0.00001,
			maxf(absf(a_value), maxf(absf(b_value), absf(c_value))) * 0.000001)
	return tolerance


func _compute_node_query_margin(node: int) -> Vector3:
	var offset := node * BVH_NODE_FLOATS
	var packed := int(_nodes[offset + 7])
	if packed > 0:
		var first := (packed >> 3) - 1
		var count := packed & 7
		var leaf_margin := Vector3.ZERO
		for triangle in range(first, first + count):
			var tri_margin := _triangle_containment_tolerance(triangle)
			for axis in 3:
				leaf_margin[axis] = maxf(leaf_margin[axis], tri_margin[axis])
		return leaf_margin
	var left := node + 1
	var right := int(_nodes[left * BVH_NODE_FLOATS + 3])
	var internal_margin := Vector3.ZERO
	for axis in 3:
		var local_tolerance := maxf(0.00001,
			maxf(absf(_nodes[offset + axis]), absf(_nodes[offset + 4 + axis])) * 0.000001)
		internal_margin[axis] = local_tolerance + maxf(
			_node_query_margin[left][axis], _node_query_margin[right][axis])
	return internal_margin


func _validate_bvh_node(node: int) -> bool:
	var offset := node * BVH_NODE_FLOATS
	for lane in BVH_NODE_FLOATS:
		if not is_finite(_nodes[offset + lane]):
			return false
	var escape_value := _nodes[offset + 3]
	var packed_value := _nodes[offset + 7]
	var escape := int(escape_value)
	var packed := int(packed_value)
	if escape_value != float(escape) or packed_value != float(packed) \
			or escape <= node or escape > node_count or packed < 0:
		return false
	if node == 0 and escape != node_count:
		return false
	for axis in 3:
		if _nodes[offset + axis] > _nodes[offset + 4 + axis]:
			return false
	if packed > 0:
		var first := (packed >> 3) - 1
		var count := packed & 7
		if first != _validated_leaf_triangles or count < 1 or count > BVH_LEAF_SIZE \
				or first + count > triangle_count or escape != node + 1:
			return false
		for triangle in range(first, first + count):
			var triangle_offset := triangle * TRIANGLE_FLOATS
			for lane in TRIANGLE_FLOATS:
				if not is_finite(_triangles[triangle_offset + lane]):
					return false
			var tri_bounds := _raw_triangle_bounds(triangle)
			for axis in 3:
				var tolerance := _triangle_containment_tolerance(triangle)[axis]
				if tri_bounds.position[axis] < _nodes[offset + axis] - tolerance \
						or tri_bounds.end[axis] > _nodes[offset + 4 + axis] + tolerance:
					return false
		_validated_leaf_triangles += count
		return true
	if escape < node + 3:
		return false
	var left := node + 1
	var left_escape_value := _nodes[left * BVH_NODE_FLOATS + 3]
	var right := int(left_escape_value)
	if left_escape_value != float(right) or right <= left or right >= escape or right >= node_count \
			or int(_nodes[right * BVH_NODE_FLOATS + 3]) != escape:
		return false
	for child in [left, right]:
		for axis in 3:
			var tolerance := maxf(0.00001,
				maxf(absf(_nodes[offset + axis]), absf(_nodes[offset + 4 + axis])) * 0.000001)
			if _nodes[child * BVH_NODE_FLOATS + axis] < _nodes[offset + axis] - tolerance \
					or _nodes[child * BVH_NODE_FLOATS + 4 + axis] \
					> _nodes[offset + 4 + axis] + tolerance:
				return false
	return true


func _raw_triangle_bounds(triangle_id: int) -> AABB:
	if triangle_id < 0 or triangle_id >= triangle_count:
		return AABB()
	var base := triangle_id * TRIANGLE_FLOATS
	for lane in TRIANGLE_FLOATS:
		if not is_finite(_triangles[base + lane]):
			return AABB()
	var a := Vector3(_triangles[base], _triangles[base + 1], _triangles[base + 2])
	var b := _float32_vec3(a + Vector3(_triangles[base + 4], _triangles[base + 5], _triangles[base + 6]))
	var c := _float32_vec3(a + Vector3(_triangles[base + 8], _triangles[base + 9], _triangles[base + 10]))
	return AABB(a, Vector3.ZERO).expand(b).expand(c)


func _index_triangle(triangle: int) -> bool:
	var base := triangle * TRIANGLE_FLOATS
	for lane in TRIANGLE_FLOATS:
		if not is_finite(_triangles[base + lane]):
			return false
	var a := _canonical_zero(Vector3(_triangles[base], _triangles[base + 1], _triangles[base + 2]))
	var edge1 := _canonical_zero(Vector3(_triangles[base + 4], _triangles[base + 5], _triangles[base + 6]))
	var edge2 := _canonical_zero(Vector3(_triangles[base + 8], _triangles[base + 9], _triangles[base + 10]))
	var area := _triangles[base + 3]
	var determinant_epsilon := _triangles[base + 7]
	var patch_value := _triangles[base + 11]
	if area < 0.0 or determinant_epsilon <= 0.0 or patch_value < 1.0 \
			or patch_value != floorf(patch_value) or patch_value > float(triangle_count):
		return false
	# Allocate this triangle's index entries as a single bounded work unit.
	_triangle_vertex_ids.append(-1)
	_triangle_vertex_ids.append(-1)
	_triangle_vertex_ids.append(-1)
	_triangle_normals.append(Vector3.ZERO)
	_triangle_patches.append(0)
	_triangle_bounds.append(AABB())
	_triangle_valid.append(0)
	_triangle_nonmanifold.append(0)
	_component_ids.append(0)
	_adjacency.append([])
	var patch := int(patch_value)
	var b := _canonical_zero(_float32_vec3(a + edge1))
	var c := _canonical_zero(_float32_vec3(a + edge2))
	# Match the production visibility shader's front-face convention.
	var cross := edge2.cross(edge1)
	var normal_length := cross.length()
	if not is_finite(normal_length) or normal_length <= 1e-10:
		_triangle_valid[triangle] = 0
		_triangle_patches[triangle] = patch
		_triangle_normals[triangle] = Vector3.ZERO
		_triangle_bounds[triangle] = AABB(a, Vector3.ZERO).expand(b).expand(c)
		_triangle_nonmanifold[triangle] = 1
		_triangle_vertex_ids[triangle * 3] = -1
		_triangle_vertex_ids[triangle * 3 + 1] = -1
		_triangle_vertex_ids[triangle * 3 + 2] = -1
		return true
	_triangle_valid[triangle] = 1
	_triangle_patches[triangle] = patch
	_triangle_normals[triangle] = cross / normal_length
	_triangle_bounds[triangle] = AABB(a, Vector3.ZERO).expand(b).expand(c)
	var ids := PackedInt32Array()
	for point in [a, b, c]:
		ids.append(_vertex_id(point, patch))
	if ids[0] < 0 or ids[1] < 0 or ids[2] < 0 \
			or ids[0] == ids[1] or ids[1] == ids[2] or ids[2] == ids[0]:
		_triangle_valid[triangle] = 0
		_triangle_nonmanifold[triangle] = 1
		return true
	var face_vertices := [ids[0], ids[1], ids[2]]
	face_vertices.sort()
	var face_key := "%d:%d:%d" % [face_vertices[0], face_vertices[1], face_vertices[2]]
	if _face_owners.has(face_key):
		var previous := int(_face_owners[face_key])
		_triangle_valid[triangle] = 0
		_triangle_nonmanifold[triangle] = 1
		_triangle_valid[previous] = 0
		_triangle_nonmanifold[previous] = 1
	else:
		_face_owners[face_key] = triangle
	for corner in 3:
		_triangle_vertex_ids[triangle * 3 + corner] = ids[corner]
		var first := ids[corner]
		var second := ids[(corner + 1) % 3]
		var low := mini(first, second)
		var high := maxi(first, second)
		var edge_key := (int(low) << 32) | int(high)
		if not _edge_records.has(edge_key):
			_edge_records[edge_key] = {"owners": [triangle], "nonmanifold": false}
			_edge_keys.append(edge_key)
		else:
			var edge: Dictionary = _edge_records[edge_key]
			if not bool(edge.nonmanifold):
				edge.owners.append(triangle)
				if edge.owners.size() > 2:
					edge.nonmanifold = true
					for owner_value in edge.owners:
						_triangle_nonmanifold[int(owner_value)] = 1
			else:
				edge.owners.append(triangle)
				_triangle_nonmanifold[triangle] = 1
			_edge_records[edge_key] = edge
	return true


func _vertex_id(point: Vector3, patch: int) -> int:
	var exact_by_patch: Dictionary = _exact_vertices.get(patch, {})
	if exact_by_patch.has(point):
		return int(exact_by_patch[point])
	var new_id := _vertex_positions.size()
	_vertex_positions.append(point)
	exact_by_patch[point] = new_id
	_exact_vertices[patch] = exact_by_patch
	return new_id


func _materialize_edge(edge_key: int) -> void:
	var edge: Dictionary = _edge_records[edge_key]
	var owners: Array = edge.owners
	if bool(edge.nonmanifold):
		_nonmanifold_edge_count += 1
		return
	if owners.size() != 2:
		_boundary_edge_count += 1
		return
	var left := int(owners[0])
	var right := int(owners[1])
	if _triangle_valid[left] == 0 or _triangle_valid[right] == 0 \
			or _triangle_nonmanifold[left] != 0 or _triangle_nonmanifold[right] != 0:
		return
	_exact_shared_edge_count += 1
	_adjacency[left].append(right)
	_adjacency[right].append(left)


func _next_remaining_candidate_info(query: Dictionary) -> Dictionary:
	if int(query.seed_cursor) >= query.seed_order.size():
		return {}
	var candidate_value: Dictionary = query.seed_order[int(query.seed_cursor)]
	query.seed_cursor = int(query.seed_cursor) + 1
	var triangle := int(candidate_value.triangle_id)
	if not query.remaining.has(triangle):
		return {"skipped": true}
	return {"valid": true, "triangle_id": triangle,
		"anchor": candidate_value.anchor}


func _canonical_zero(value: Vector3) -> Vector3:
	return Vector3(0.0 if value.x == 0.0 else value.x,
		0.0 if value.y == 0.0 else value.y,
		0.0 if value.z == 0.0 else value.z)


static func _float32_vec3(value: Vector3) -> Vector3:
	var rounded := PackedFloat32Array([value.x, value.y, value.z])
	return Vector3(rounded[0], rounded[1], rounded[2])


static func cell_query_spec(world_cell: Vector3i, step: float) -> Dictionary:
	if not is_finite(step) or step <= 0.0:
		return {"valid": false, "reason": "invalid_step"}
	var center := (Vector3(world_cell) + Vector3.ONE * 0.5) * step
	var magnitude := maxf(absf(center.x), maxf(absf(center.y), absf(center.z)))
	var margin := maxf(0.00001, maxf(step, magnitude) * 1.9073486328125e-6)
	var half_extent := Vector3.ONE * (1.75 * step + margin)
	return {"valid": true, "center": center, "box_margin": margin,
		"plane_tolerance": maxf(0.00001, step * 0.0001) + margin,
		"half_extent": half_extent, "minimum": center - half_extent,
		"maximum": center + half_extent}


static func _seed_candidate_less(a: Dictionary, b: Dictionary) -> bool:
	var a_distance := float(a.get("distance_squared", INF))
	var b_distance := float(b.get("distance_squared", INF))
	if a_distance != b_distance:
		return a_distance < b_distance
	return int(a.get("triangle_id", 0)) < int(b.get("triangle_id", 0))


func _start_budgeted_seed_sort(query: Dictionary, array_key: String,
		phase_key: String, next_phase: String, sort_phase: String) -> void:
	var source: Array = query.get(array_key, [])
	var count: int = source.size()
	query["sort_array_key"] = array_key
	query["sort_phase_key"] = phase_key
	query["sort_next_phase"] = next_phase
	query["sort_source"] = source
	query["sort_target"] = []
	query["sort_width"] = 1
	query["sort_start"] = 0
	if count <= 1:
		query[array_key] = source
		query[phase_key] = next_phase
		return
	_begin_budgeted_seed_sort_run(query)
	query[phase_key] = sort_phase


func _begin_budgeted_seed_sort_run(query: Dictionary) -> void:
	var count: int = query.sort_source.size()
	var start := int(query.sort_start)
	var width := int(query.sort_width)
	var mid := mini(start + width, count)
	query["sort_left"] = start
	query["sort_mid"] = mid
	query["sort_right"] = mid
	query["sort_end"] = mini(start + 2 * width, count)
	query["sort_out"] = start


## Stable bottom-up merge sort. Each call copies at most one record, so both
## candidate and seed ordering are charged to the caller's per-frame work budget.
func _advance_budgeted_seed_sort(query: Dictionary) -> void:
	var source: Array = query.sort_source
	var target: Array = query.sort_target
	var left := int(query.sort_left)
	var mid := int(query.sort_mid)
	var right := int(query.sort_right)
	var end := int(query.sort_end)
	var out := int(query.sort_out)
	var selected: Dictionary
	if left < mid and right < end:
		var left_candidate: Dictionary = source[left]
		var right_candidate: Dictionary = source[right]
		if _seed_candidate_less(left_candidate, right_candidate):
			selected = left_candidate
			left += 1
		else:
			selected = right_candidate
			right += 1
	elif left < mid:
		selected = source[left]
		left += 1
	else:
		selected = source[right]
		right += 1
	target.append(selected)
	out += 1
	query.sort_left = left
	query.sort_right = right
	query.sort_out = out
	query.sort_target = target
	if out < end:
		return
	var count := source.size()
	var run_start := int(query.sort_start) + 2 * int(query.sort_width)
	if run_start >= count:
		source = target
		var width := int(query.sort_width) * 2
		query.sort_source = source
		if width >= count:
			query[str(query.sort_array_key)] = source
			query[str(query.sort_phase_key)] = str(query.sort_next_phase)
			return
		target = []
		query.sort_target = target
		query.sort_width = width
		run_start = 0
	query.sort_start = run_start
	_begin_budgeted_seed_sort_run(query)


func _triangle_fits_seed_plane(triangle: Dictionary, anchor: Vector3,
		normal: Vector3, half_width: float) -> bool:
	if triangle.is_empty() or not anchor.is_finite() or not normal.is_finite() \
			or not is_finite(half_width) or half_width < 0.0:
		return false
	for point in [triangle.a, triangle.b, triangle.c]:
		if absf((point - anchor).dot(normal)) > half_width:
			return false
	return true


static func _closest_point_triangle(point: Vector3, a: Vector3, b: Vector3,
		c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := point - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := point - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := point - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and d4 - d3 >= 0.0 and d5 - d6 >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denominator := 1.0 / (va + vb + vc)
	var v := vb * denominator
	var w := vc * denominator
	return a + ab * v + ac * w


static func _tube_world_aabb(anchor: Vector3, normal: Vector3, radius: float,
		half_height: float, margin: float) -> AABB:
	var n := normal.normalized()
	var extent := Vector3(
		radius * sqrt(maxf(0.0, 1.0 - n.x * n.x)) + half_height * absf(n.x) + margin,
		radius * sqrt(maxf(0.0, 1.0 - n.y * n.y)) + half_height * absf(n.y) + margin,
		radius * sqrt(maxf(0.0, 1.0 - n.z * n.z)) + half_height * absf(n.z) + margin)
	return AABB(anchor - extent, extent * 2.0)


static func _aabbs_overlap(left: AABB, right: AABB) -> bool:
	return _aabb_overlaps(left.position, left.end, right.position, right.end)


static func _aabb_overlaps(a_min: Vector3, a_max: Vector3,
		b_min: Vector3, b_max: Vector3) -> bool:
	return a_min.x <= b_max.x and a_max.x >= b_min.x \
			and a_min.y <= b_max.y and a_max.y >= b_min.y \
			and a_min.z <= b_max.z and a_max.z >= b_min.z


func _progress() -> Dictionary:
	return {"valid": not failed, "ready": ready, "phase": phase,
		"failure_reason": failure_reason, "geometry_key": geometry_key,
		"triangle_count": triangle_count, "node_count": node_count,
		"triangle_cursor": _triangle_cursor, "edge_cursor": _edge_cursor,
		"component_seed_cursor": _component_seed_cursor,
		"work_completed": work_completed}


func _query_progress(query: Dictionary) -> Dictionary:
	var current_phase := str(query.get("phase", "failed"))
	var domain_phase := str(query.get("domain_phase", "not_started"))
	return {"valid": current_phase != "failed" and domain_phase != "failed",
		"ready": current_phase == "components_ready" and domain_phase == "ready",
		"components_ready": current_phase == "components_ready",
		"phase": current_phase, "reason": str(query.get("reason", "")),
		"domain_phase": domain_phase, "domain_reason": str(query.get("domain_reason", "")),
		"node_cursor": int(query.get("node_cursor", 0)),
		"node_visits": int(query.get("node_visits", 0)),
		"candidate_count": query.get("candidate_ids", []).size(),
		"candidate_duplicates": int(query.get("candidate_duplicates", 0)),
		"component_count": query.get("components", []).size()}


func _domain_progress(query: Dictionary) -> Dictionary:
	var domain_phase := str(query.get("domain_phase", "not_started"))
	var current_phase := str(query.get("phase", "failed"))
	return {"valid": current_phase != "failed" and domain_phase != "failed",
		"ready": current_phase == "components_ready" and domain_phase == "ready",
		"phase": domain_phase, "reason": str(query.get("domain_reason", "")),
		"candidate_count": query.get("candidate_ids", []).size(),
		"component_count": query.get("components", []).size(),
		"local_edge_tests": int(query.get("local_edge_tests", 0)),
		"domain_triangle_tests": int(query.get("domain_triangle_tests", 0)),
		"certified_chart_count": query.get("domain_accepts", []).size(),
		"domain_candidate_cursor": int(query.get("domain_candidate_cursor", 0)),
		"domain_radius_cursor": int(query.get("domain_radius_cursor", 0)),
		"domain_triangle_cursor": int(query.get("domain_triangle_cursor", 0))}


func _fail(reason: String) -> bool:
	failed = true
	ready = false
	phase = "failed"
	failure_reason = reason
	return false


func _reset() -> void:
	geometry_key = ""
	ready = false
	failed = false
	failure_reason = ""
	phase = "idle"
	triangle_count = 0
	node_count = 0
	work_completed = 0
	_nodes = PackedFloat32Array()
	_triangles = PackedFloat32Array()
	_node_query_margin.clear()
	_validate_cursor = 0
	_validated_leaf_triangles = 0
	_node_margin_cursor = -1
	_triangle_cursor = 0
	_edge_keys.clear()
	_edge_records.clear()
	_face_owners.clear()
	_edge_cursor = 0
	_component_seed_cursor = 0
	_component_seed = -1
	_component_queue.clear()
	_component_queue_head = 0
	_component_sizes.clear()
	_exact_shared_edge_count = 0
	_boundary_edge_count = 0
	_nonmanifold_edge_count = 0
	_exact_vertices.clear()
	_vertex_positions.clear()
	_triangle_vertex_ids = PackedInt32Array()
	_triangle_normals = PackedVector3Array()
	_triangle_patches = PackedInt32Array()
	_triangle_bounds.clear()
	_triangle_valid = PackedByteArray()
	_triangle_nonmanifold = PackedByteArray()
	_adjacency.clear()
	_component_ids = PackedInt32Array()
	_queries.clear()
