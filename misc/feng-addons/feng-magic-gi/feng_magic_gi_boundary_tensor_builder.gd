@tool
class_name FMagicGIBoundaryTensorBuilder
extends RefCounted
## Bake-time, sparse layout-17 tensor boundary records for closed mesh surfaces.
## This builder never changes the persisted probe SH or the screen sampling ABI.

const Data = preload("feng_magic_gi_data.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const Visibility = preload("feng_magic_gi_visibility.gd")

const SCHEMA_VERSION := 1
const ALGORITHM := "closed_mesh_boundary_tensor_v1"
const LAYOUT_VERSION := 17
const LEVEL_COUNT := 3
const EXPECTED_SPACING := 0.25
const SOURCE_NORMAL_DOT_MIN := 0.85
const FACE_AXIS_DOT_MIN := 0.9999
const SOURCE_RADIUS_IN_CLV_CELLS := 2.0
const BOUNDARY_TUBE_IN_CLV_CELLS := 1.25
const QUERY_OFFSET_M := 0.03
const MIN_QUERY_OFFSET_M := 0.0005
const SOURCE_ANCHOR_EPSILON_M := 0.0001
const MAX_TANGENT_SHIFT_M := 0.4
const TANGENT_SHIFT_STEP_M := 0.05
const MAX_FACE_SOURCE_EXTRAPOLATION_M := 4.0
const FACE_SOURCE_MIN_SUPPORT := 3
const FACE_SOURCE_ANCHOR_TOLERANCE_M := 0.01
const FACE_SOURCE_NORMAL_DOT_MIN := 0.95
const FACE_SOURCE_LOO_RELATIVE_TOLERANCE := 0.025
const FACE_SOURCE_LOO_MAX_SCALED_TOLERANCE := 0.025
const FACE_SOURCE_QUERY_TANGENT_MAX_M := 0.08
const MINIMUM_VISIBLE_WEIGHT := 0.0
const MAX_SIDE_CANDIDATES := 65536
const MAX_RECORDS := 131072
const AXIS_CONFLICT_RELATIVE_TOLERANCE := 0.05
const FIT_RESIDUAL_RELATIVE_TOLERANCE := 0.025
const MAX_GRAM_CONDITION_INF := 1000.0
const SH_Y00 := 0.2820947918
const SH_L1_KERNEL := 0.325735007933
const SH_L2_KERNEL := 0.27313710765
const SH_Z2_TERM := 0.078847891325
const SH_X2Y2_TERM := 0.136568553825


static func build_records(volume: Node3D, data: Data,
		placement: Placement) -> Dictionary:
	if not is_instance_valid(volume) or not is_instance_valid(data) \
			or not is_instance_valid(placement):
		return _failure("invalid_builder_input")
	if data.baked_indirect_sh_revision != Data.BAKED_INDIRECT_SH_REVISION \
			or not data.has_baked_indirect_sh() \
			or data.baked_indirect_sh.size() != data.probe_count() * 27:
		return _failure("baked_indirect_sh_not_ready")
	if not is_equal_approx(data.spacing, EXPECTED_SPACING) \
			or not is_equal_approx(data.minimum_probe_spacing, EXPECTED_SPACING):
		return _failure("boundary_tensor_v1_requires_025m_probe_spacing")
	if data.positions.size() != data.probe_count() \
			or data.surface_positions.size() != data.probe_count() \
			or data.normals.size() != data.probe_count() \
			or not data.world_to_grid.is_finite() \
			or data.visibility_nodes.is_empty() or data.visibility_triangles.is_empty() \
			or not Visibility.validate(data.visibility_nodes, data.visibility_triangles):
		return _failure("source_geometry_or_visibility_bvh_invalid")
	if placement.faces.is_empty() or not placement.bvh_ready:
		return _failure("placement_geometry_not_ready")
	if (int(placement.scene_signature) & 0xffffffff) \
			!= (int(data.scene_signature) & 0xffffffff):
		return _failure("placement_scene_signature_mismatch")
	var solids_value: Variant = placement.get("_occlusion_volumes")
	if not solids_value is Array or solids_value.is_empty():
		return _failure("placement_has_no_validated_closed_solids")
	var solids: Array[Dictionary] = []
	for raw_solid in solids_value:
		if not raw_solid is Dictionary:
			return _failure("invalid_closed_solid_record")
		var faces_value: Variant = raw_solid.get("faces", null)
		var bvh_value: Variant = raw_solid.get("bvh", null)
		var bounds_value: Variant = raw_solid.get("world_aabb", null)
		if not faces_value is PackedVector3Array or faces_value.size() < 12 \
				or not bvh_value is TriangleMesh or not bounds_value is AABB:
			return _failure("closed_solid_missing_faces_bvh_or_bounds")
		solids.append({
			"instance_id": int(raw_solid.get("instance_id", 0)),
			"faces": faces_value,
			"bvh": bvh_value,
			"bounds": bounds_value,
		})
	if solids.is_empty():
		return _failure("placement_has_no_usable_closed_solids")
	if solids.size() > 256:
		return _failure("closed_solid_count_exceeds_boundary_builder_budget")

	var source_buckets: Dictionary = {}
	var source_spacing := minf(data.minimum_probe_spacing, data.spacing)
	if not _build_source_buckets(data, source_spacing, source_buckets):
		return _failure("source_bucket_build_failed")
	var path_by_id := _collect_scene_paths(volume)
	var face_pairs: Array[Dictionary] = []
	var curved_solids: Array[Dictionary] = []
	for solid_index in solids.size():
		var solid: Dictionary = solids[solid_index]
		solid["path"] = String(path_by_id.get(int(solid["instance_id"]), ""))
		solid["pairs"] = _build_axis_face_pairs(solid)
		if not _is_full_axis_aligned_box(solid, solid["pairs"]):
			curved_solids.append(solid)
		else:
			for pair in solid["pairs"]:
				pair["solid_index"] = solid_index
				pair["plus_face_source_indices"] = _collect_axis_face_source_indices(
					pair, 1, data)
				pair["minus_face_source_indices"] = _collect_axis_face_source_indices(
					pair, -1, data)
				face_pairs.append(pair)
	var owner_bounds := _volume_world_bounds(volume)
	if owner_bounds.size.x <= 0.0 or owner_bounds.size.y <= 0.0 or owner_bounds.size.z <= 0.0:
		return _failure("owner_world_bounds_invalid")
	var stats := {
		"solid_count": solids.size(),
		"plane_pair_count": face_pairs.size(),
		"curved_solid_count": curved_solids.size(),
		"records_by_level": PackedInt32Array([0, 0, 0]),
		"multi_axis_records": PackedInt32Array([0, 0, 0]),
		"curved_records": PackedInt32Array([0, 0, 0]),
		"maximum_gram_condition_inf": 0.0,
		"maximum_tensor_coefficient_abs": 0.0,
		"one_sided_axis_constraints": 0,
		"rejections": {},
	}
	var keys := PackedInt32Array()
	var coefficients := PackedFloat32Array()
	var duplicate_values: Dictionary = {}
	var query_cache: Dictionary = {}
	for level in LEVEL_COUNT:
		var step := data.spacing * float(1 << level)
		var grow := step * BOUNDARY_TUBE_IN_CLV_CELLS
		var min_cell := Vector3i(
			ceili((owner_bounds.position.x - grow) / step - 0.5),
			ceili((owner_bounds.position.y - grow) / step - 0.5),
			ceili((owner_bounds.position.z - grow) / step - 0.5))
		var max_cell := Vector3i(
			floori((owner_bounds.end.x + grow) / step - 0.5),
			floori((owner_bounds.end.y + grow) / step - 0.5),
			floori((owner_bounds.end.z + grow) / step - 0.5))
		var cell_count := (max_cell.x - min_cell.x + 1) * (max_cell.y - min_cell.y + 1) \
				* (max_cell.z - min_cell.z + 1)
		if cell_count < 0 or cell_count > MAX_SIDE_CANDIDATES:
			return _failure("boundary_cell_enumeration_exceeds_budget_level_%d" % level)
		for z in range(min_cell.z, max_cell.z + 1):
			for y in range(min_cell.y, max_cell.y + 1):
				for x in range(min_cell.x, max_cell.x + 1):
					var logical := Vector3i(x, y, z)
					var world := (Vector3(logical) + Vector3.ONE * 0.5) * step
					var near_pairs: Array[Dictionary] = []
					for pair in face_pairs:
						var pair_distance := _pair_distance(world, pair)
						if pair_distance <= grow:
							near_pairs.append({"distance": pair_distance, "pair": pair})
					var near_curved: Array[Dictionary] = []
					for solid in curved_solids:
						var bounds: AABB = solid["bounds"]
						if _point_aabb_distance_squared(world, bounds) > grow * grow:
							continue
						var nearest := _nearest_triangle(world, solid["faces"], step)
						if nearest.is_empty():
							continue
						if float(nearest["distance"]) <= grow:
							near_curved.append({"distance": nearest["distance"],
								"solid": solid, "nearest": nearest})
					if near_pairs.is_empty() and near_curved.is_empty():
						continue
					var node_state := _classify_union(world, solids, placement)
					if node_state == "unknown":
						_add_rejection(stats, "unknown_node")
						continue
					near_pairs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
						if float(a["distance"]) != float(b["distance"]):
							return float(a["distance"]) < float(b["distance"])
						var pa: Dictionary = a["pair"]
						var pb: Dictionary = b["pair"]
						if int(pa["axis"]) != int(pb["axis"]):
							return int(pa["axis"]) < int(pb["axis"])
						return int(pa["solid_index"]) < int(pb["solid_index"]))
					var axis_constraints: Dictionary = {}
					var one_sided_constraints: Dictionary = {}
					var locked_signed_keys: Dictionary = {}
					var locked_conflict_face_tags: Dictionary = {}
					var same_face_bases: Array[Dictionary] = []
					var axis_conflict := false
					for candidate in near_pairs:
						var pair: Dictionary = candidate["pair"]
						var axis := int(pair["axis"])
						var pair_distance := float(candidate["distance"])
						# Opposite caps of a long box axis are not a local measurement pair.
						# Keep only each nearby signed face; thin slabs may still use both sides.
						if float(pair["thickness"]) > step * 1.5:
							for side_sign in [1, -1]:
								var face_distance := _face_surface_distance(world, pair, side_sign)
								if face_distance > grow:
									continue
								var face_gather := _select_single_face_query(world, step, pair,
										side_sign, grow, solids, placement, data, source_buckets,
										source_spacing, query_cache)
								if not bool(face_gather.get("valid", false)):
									_add_rejection(stats, "long_axis_local_face_unsupported")
									continue
								var side_normal: Vector3 = face_gather["normal"]
								var side_axis := _dominant_axis(side_normal)
								var side_key := side_axis * 2 + (1 if side_normal[side_axis] > 0.0 else 0)
								var face_constraint := {
									"axis": side_axis,
									"normal": side_normal,
									"target": face_gather["response"],
									"tensor": face_gather["tensor"],
									"query": face_gather["query"],
									"distance": float(face_gather["distance"]),
									"source_indices": face_gather["source_indices"],
									"face_tag": "%s_%d_%s" % [String(pair["component"]),
										axis, str(side_sign)],
									"support_count": int(face_gather["visible_count"]),
									"kind": "one_sided",
								}
								if not _put_signed_constraint_or_lock(one_sided_constraints,
										locked_signed_keys, locked_conflict_face_tags,
										side_key, face_constraint, step, stats):
									_add_rejection(stats, "invalid_signed_face_constraint")
									axis_conflict = true
									break
								same_face_bases.append({"tensor": face_gather["tensor"],
									"query": face_gather["query"], "normal": side_normal,
									"surface_distance": float(face_gather["distance"]),
									"face_tag": face_constraint["face_tag"],
									"support_count": int(face_gather["visible_count"])})
							if axis_conflict:
								break
							continue
						if axis_constraints.has(axis) \
								and pair_distance > float(axis_constraints[axis]["distance"]) + step * 0.15:
							continue
						var selected := _select_pair_queries(world, step, pair, solids,
								placement, data, source_buckets, source_spacing, query_cache)
						if selected.is_empty():
							_add_rejection(stats, "no_known_free_supported_pair")
							var supported_side_count := 0
							if not axis_constraints.has(axis):
								for side_sign in [1, -1]:
									var face_response := _gather_axis_face_response(world,
										step, pair, side_sign, solids, placement, data)
									if not bool(face_response.get("valid", false)):
										continue
									supported_side_count += 1
									var side_key := axis * 2 + (1 if side_sign > 0 else 0)
									var side_normal := Vector3.ZERO
									side_normal[axis] = float(side_sign)
									same_face_bases.append({"tensor": face_response["tensor"],
										"query": face_response["query"], "normal": side_normal,
										"surface_distance": pair_distance,
										"face_tag": "%s_%d_%s" % [String(pair["component"]),
											axis, str(side_sign)],
										"support_count": int(face_response["support_count"])})
									var side_constraint := {
										"axis": axis,
										"normal": side_normal,
										"target": face_response["response"],
										"tensor": face_response["tensor"],
										"query": face_response["query"],
										"distance": _face_surface_distance(world, pair, side_sign),
										"face_tag": "%s_%d_%s" % [String(pair["component"]),
											axis, str(side_sign)],
										"support_count": int(face_response["support_count"]),
										"kind": "one_sided",
									}
									if not _put_signed_constraint_or_lock(one_sided_constraints,
											locked_signed_keys, locked_conflict_face_tags,
											side_key, side_constraint, step, stats):
										axis_conflict = true
										_add_rejection(stats, "invalid_signed_face_constraint")
										break
								if axis_conflict:
									break
								if supported_side_count == 0 and node_state == "known_solid":
									_add_rejection(stats, "no_same_face_source_constraint")
									axis_conflict = true
									break
							continue
						selected["distance"] = pair_distance
						if axis_constraints.has(axis):
							var prior: Dictionary = axis_constraints[axis]
							if absf(pair_distance - float(prior["distance"])) <= step * 0.15 \
									and _axis_pair_conflict(prior, selected):
								_add_rejection(stats, "same_axis_conflict")
								axis_conflict = true
								break
							if pair_distance < float(prior["distance"]):
								axis_constraints[axis] = selected
						else:
							axis_constraints[axis] = selected
					if axis_conflict:
						continue
					var curved_constraints: Array[Dictionary] = []
					near_curved.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
						return float(a["distance"]) < float(b["distance"]))
					for candidate in near_curved:
						var curved := _select_curved_query(world, step,
							candidate["solid"], candidate["nearest"], solids,
							placement, data, source_buckets, source_spacing, query_cache)
						if curved.is_empty():
							_add_rejection(stats, "curved_constraint_rejected")
							continue
						curved_constraints.append(curved)
					# Missing curved support must not discard an independently measured
					# floor/wall response. The complete-base and fit checks below still
					# reject unsupported records; no zero-radiance constraint is invented.
					if axis_constraints.is_empty() and curved_constraints.is_empty() \
							and one_sided_constraints.is_empty():
						continue
					var signed_constraints: Dictionary = {}
					for axis_variant in axis_constraints.keys():
						var selected_pair: Dictionary = axis_constraints[axis_variant]
						var selected_pair_data: Dictionary = selected_pair["pair"]
						var selected_axis := int(axis_variant)
						var plus_normal := Vector3.ZERO
						plus_normal[selected_axis] = 1.0
						var minus_normal := -plus_normal
						var plus_constraint := {
							"axis": selected_axis, "normal": plus_normal,
							"target": selected_pair["plus"]["response"],
							"tensor": selected_pair["plus"]["tensor"],
							"query": selected_pair["plus_query"],
							"distance": _face_surface_distance(world, selected_pair_data, 1),
							"face_tag": "%s_%d_plus" % [String(selected_pair_data["component"]), selected_axis],
							"kind": "paired",
						}
						var minus_constraint := {
							"axis": selected_axis, "normal": minus_normal,
							"target": selected_pair["minus"]["response"],
							"tensor": selected_pair["minus"]["tensor"],
							"query": selected_pair["minus_query"],
							"distance": _face_surface_distance(world, selected_pair_data, -1),
							"face_tag": "%s_%d_minus" % [String(selected_pair_data["component"]), selected_axis],
							"kind": "paired",
						}
						var plus_key := selected_axis * 2 + 1
						var minus_key := selected_axis * 2
						if not _put_signed_constraint_or_lock(signed_constraints,
								locked_signed_keys, locked_conflict_face_tags,
								plus_key, plus_constraint, step, stats) \
								or not _put_signed_constraint_or_lock(signed_constraints,
									locked_signed_keys, locked_conflict_face_tags,
									minus_key, minus_constraint, step, stats):
							axis_conflict = true
							_add_rejection(stats, "invalid_signed_face_constraint")
							break
					for side_key_variant in one_sided_constraints.keys():
						var one_sided: Dictionary = one_sided_constraints[side_key_variant]
						if not _put_signed_constraint_or_lock(signed_constraints,
								locked_signed_keys, locked_conflict_face_tags,
								int(side_key_variant), one_sided, step, stats):
							axis_conflict = true
							_add_rejection(stats, "invalid_signed_face_constraint")
							break
					if axis_conflict:
						continue
					var base_tensor: Array = []
					var has_complete_base := false
					if node_state == "known_solid":
						# A solid CLV node has no meaningful point sample. Prefer a full tensor
						# extrapolated from a validated source face; then use measured surface
						# constraints to replace only their directions. Never publish an all-zero
						# partial fit as coverage=1.
						var best_base_distance := INF
						var best_base_tag := ""
						# Prefer a full tensor extrapolated from a validated source face.
						# A nearby query on a perpendicular face can be across the cap plane
						# and would poison the unconstrained tensor components.
						for face_base in same_face_bases:
							var face_tensor: Array = face_base["tensor"]
							if face_tensor.size() != 9 or not _tensor_is_finite(face_tensor):
								continue
							if _face_tag_is_conflicted(String(face_base.get("face_tag", "")),
									locked_conflict_face_tags):
								continue
							var face_distance := float(face_base["surface_distance"])
							var face_tag := String(face_base["face_tag"])
							if face_distance < best_base_distance - 1e-10 \
									or (absf(face_distance - best_base_distance) <= 1e-10 \
										and (best_base_tag.is_empty() or face_tag < best_base_tag)):
								best_base_distance = face_distance
								best_base_tag = face_tag
								base_tensor = face_tensor.duplicate()
								has_complete_base = true
						# If no exact same-face fallback exists, paired/curved measurements
						# provide a complete local base. One-sided-only records never use a
						# perpendicular face as a substitute.
						if not has_complete_base:
							var signed_keys := signed_constraints.keys()
							signed_keys.sort()
							for signed_key_variant in signed_keys:
								var signed_constraint: Dictionary = signed_constraints[signed_key_variant]
								var candidate_tensor: Array = signed_constraint.get("tensor", [])
								if candidate_tensor.size() != 9 \
										or not _tensor_is_finite(candidate_tensor):
									continue
								var query: Vector3 = signed_constraint["query"]
								var candidate_distance := world.distance_squared_to(query)
								var candidate_tag := String(signed_constraint.get("face_tag", str(signed_key_variant)))
								if candidate_distance < best_base_distance - 1e-10 \
										or (absf(candidate_distance - best_base_distance) <= 1e-10 \
										and (best_base_tag.is_empty() or candidate_tag < best_base_tag)):
									best_base_distance = candidate_distance
									best_base_tag = candidate_tag
									base_tensor = candidate_tensor.duplicate()
									has_complete_base = true
							for curved in curved_constraints:
								var candidate_tensor: Array = curved.get("tensor", [])
								if candidate_tensor.size() != 9 \
										or not _tensor_is_finite(candidate_tensor):
									continue
								var query: Vector3 = curved["query"]
								var candidate_distance := world.distance_squared_to(query)
								var candidate_tag := "curved_%08d" % int(curved["triangle_index"])
								if candidate_distance < best_base_distance - 1e-10 \
										or (absf(candidate_distance - best_base_distance) <= 1e-10 \
										and (best_base_tag.is_empty() or candidate_tag < best_base_tag)):
									best_base_distance = candidate_distance
									best_base_tag = candidate_tag
									base_tensor = candidate_tensor.duplicate()
									has_complete_base = true
					else:
						var base_key := _query_cache_key(world, step, "base")
						if not query_cache.has(base_key):
							query_cache[base_key] = _gather_tensor(world, step, Vector3.ZERO,
								0.0, 0, data, source_buckets, source_spacing)
						var base_gather: Dictionary = query_cache[base_key]
						base_tensor = base_gather.get("tensor", [])
						has_complete_base = bool(base_gather.get("valid", false)) \
								and base_tensor.size() == 9 and _tensor_is_finite(base_tensor)
						if not has_complete_base:
							var best_face_distance := INF
							for face_base in same_face_bases:
								var face_normal: Vector3 = face_base["normal"]
								var face_query: Vector3 = face_base["query"]
								if (world - face_query).dot(face_normal) < -FACE_SOURCE_ANCHOR_TOLERANCE_M:
									continue
								var face_tensor: Array = face_base["tensor"]
								if _face_tag_is_conflicted(String(face_base.get("face_tag", "")),
										locked_conflict_face_tags):
									continue
								var face_distance := world.distance_squared_to(face_query)
								if face_tensor.size() == 9 and _tensor_is_finite(face_tensor) \
										and face_distance < best_face_distance:
									best_face_distance = face_distance
									base_tensor = face_tensor.duplicate()
									has_complete_base = true
					if not has_complete_base:
						_add_rejection(stats, "no_complete_free_space_tensor_base")
						continue
					# Conflicting same-sign measurements are removed above. Lock each such
					# direction to the independently validated complete base, while preserving
					# the original measurements on every non-conflicting signed direction.
					for locked_key_variant in locked_signed_keys.keys():
						var locked_key := int(locked_key_variant)
						var locked_normal := _signed_key_normal(locked_key)
						var locked_response := _tensor_response(base_tensor, locked_normal)
						if not _finite_vector3(locked_response):
							axis_conflict = true
							break
						signed_constraints[locked_key] = {
							"axis": locked_key >> 1,
							"normal": locked_normal,
							"target": locked_response,
							"tensor": base_tensor,
							"query": world,
							"distance": 0.0,
							"face_tag": "validated_base_locked_sign",
							"kind": "base_locked",
							"conflicting_face_tags": locked_conflict_face_tags.get(locked_key, []),
						}
					if axis_conflict:
						_add_rejection(stats, "invalid_locked_base_response")
						continue
					var constraints: Array[Dictionary] = []
					var ordered_signed_keys := signed_constraints.keys()
					ordered_signed_keys.sort()
					for signed_key_variant in ordered_signed_keys:
						var signed_constraint: Dictionary = signed_constraints[signed_key_variant]
						constraints.append({"normal": signed_constraint["normal"],
							"target": signed_constraint["target"]})
					for curved in curved_constraints:
						constraints.append({"normal": curved["normal"],
							"target": curved["response"]})
					for signed_constraint in signed_constraints.values():
						if String(signed_constraint.get("kind", "")) == "one_sided":
							stats["one_sided_axis_constraints"] = \
								int(stats["one_sided_axis_constraints"]) + 1
					var fitted := _fit_tensor_constraints(base_tensor, constraints)
					if not bool(fitted.get("valid", false)):
						_add_rejection(stats, String(fitted.get("reason", "tensor_fit_rejected")))
						continue
					stats["maximum_gram_condition_inf"] = maxf(
						float(stats["maximum_gram_condition_inf"]),
						float(fitted.get("gram_condition_inf", 0.0)))
					var record_tensor: Array = fitted["tensor"]
					if record_tensor.size() != 9 or not _tensor_is_finite(record_tensor):
						_add_rejection(stats, "nonfinite_tensor_record")
						continue
					var locked_response_error := 0.0
					var locked_response_scale := 1.0
					for locked_key_variant in locked_signed_keys.keys():
						var locked_key := int(locked_key_variant)
						var locked_normal := _signed_key_normal(locked_key)
						var expected_locked := _tensor_response(base_tensor, locked_normal)
						var actual_locked := _tensor_response(record_tensor, locked_normal)
						locked_response_error = maxf(locked_response_error,
							_max_abs(actual_locked - expected_locked))
						locked_response_scale = maxf(locked_response_scale, _max_abs(expected_locked))
					if locked_response_error > maxf(1e-4, locked_response_scale * 1e-5):
						_add_rejection(stats, "locked_base_response_changed")
						continue
					var key := Vector4i(logical.x, logical.y, logical.z, level)
					var flat_key := Vector4i(level, logical.x, logical.y, logical.z)
					var flat_coefficients := _flatten_tensor(record_tensor)
					if flat_coefficients.size() != 27:
						return _failure("tensor_record_shape_mismatch")
					for coefficient in flat_coefficients:
						stats["maximum_tensor_coefficient_abs"] = maxf(
							float(stats["maximum_tensor_coefficient_abs"]), absf(float(coefficient)))
					if duplicate_values.has(key):
						if not _records_equal(duplicate_values[key], flat_coefficients):
							return _failure("conflicting_duplicate_tensor_record")
						continue
					duplicate_values[key] = flat_coefficients
					keys.append_array(PackedInt32Array([flat_key.x, flat_key.y, flat_key.z, flat_key.w]))
					coefficients.append_array(flat_coefficients)
					var records_by_level: PackedInt32Array = stats["records_by_level"]
					records_by_level[level] += 1
					stats["records_by_level"] = records_by_level
					var constrained_axes: Dictionary = {}
					for signed_key_variant in signed_constraints.keys():
						constrained_axes[int(signed_key_variant) >> 1] = true
					for curved in curved_constraints:
						constrained_axes[_dominant_axis(curved["normal"])] = true
					if constrained_axes.size() > 1:
						var multi_axis_records: PackedInt32Array = stats["multi_axis_records"]
						multi_axis_records[level] += 1
						stats["multi_axis_records"] = multi_axis_records
					if not curved_constraints.is_empty():
						var curved_records: PackedInt32Array = stats["curved_records"]
						curved_records[level] += 1
						stats["curved_records"] = curved_records
					if keys.size() / 4 > MAX_RECORDS:
						return _failure("boundary_record_count_exceeds_budget")
	var provenance := _make_provenance(volume, data, placement, solids)
	if provenance.is_empty():
		return _failure("boundary_tensor_provenance_failed")
	provenance["input_signature"] = _input_signature(provenance)
	if String(provenance["input_signature"]).is_empty():
		return _failure("boundary_tensor_input_signature_failed")
	return {
		"valid": true,
		"keys": keys,
		"coefficients": coefficients,
		"provenance": provenance,
		"stats": stats,
	}


static func _failure(reason: String) -> Dictionary:
	return {"valid": false, "reason": reason,
		"keys": PackedInt32Array(), "coefficients": PackedFloat32Array(),
		"provenance": {}}


static func _build_source_buckets(data: Data, source_spacing: float,
		buckets: Dictionary) -> bool:
	if source_spacing <= 0.0 or data.grid_dims.x <= 0 \
			or data.grid_dims.y <= 0 or data.grid_dims.z <= 0:
		return false
	for probe in data.probe_count():
		var grid := data.world_to_grid * data.surface_positions[probe]
		if not _finite_vector3(grid):
			return false
		var cell := Vector3i(floori(grid.x), floori(grid.y), floori(grid.z))
		if cell.x < 0 or cell.y < 0 or cell.z < 0 \
				or cell.x >= data.grid_dims.x or cell.y >= data.grid_dims.y \
				or cell.z >= data.grid_dims.z:
			return false
		var probes: Array = buckets.get(cell, [])
		probes.append(probe)
		buckets[cell] = probes
	return true


static func _collect_scene_paths(volume: Node) -> Dictionary:
	var result: Dictionary = {}
	var root := SceneTracker.scene_root(volume)
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		result[int(node.get_instance_id())] = SceneTracker.scene_relative_path(node)
		for child in node.get_children():
			stack.append(child)
	return result


static func _volume_world_bounds(volume: Node3D) -> AABB:
	var size_value: Variant = volume.get("size")
	if not size_value is Vector3 or size_value.x <= 0.0 \
			or size_value.y <= 0.0 or size_value.z <= 0.0:
		return AABB()
	var half: Vector3 = size_value * 0.5
	var result := AABB()
	var first := true
	for z_sign in [-1.0, 1.0]:
		for y_sign in [-1.0, 1.0]:
			for x_sign in [-1.0, 1.0]:
				var point := volume.global_transform * Vector3(
					x_sign * half.x, y_sign * half.y, z_sign * half.z)
				if first:
					result = AABB(point, Vector3.ZERO)
					first = false
				else:
					result = result.expand(point)
	return result


static func _build_axis_face_pairs(solid: Dictionary) -> Array[Dictionary]:
	var faces: PackedVector3Array = solid["faces"]
	var bounds: AABB = solid["bounds"]
	var planes: Array = [{"min": {}, "max": {}}, {"min": {}, "max": {}}, {"min": {}, "max": {}}]
	var plane_epsilon := maxf(0.0001, bounds.size.length() * 1e-6)
	for face_offset in range(0, faces.size() - 2, 3):
		var a: Vector3 = faces[face_offset]
		var b: Vector3 = faces[face_offset + 1]
		var c: Vector3 = faces[face_offset + 2]
		var cross := (c - a).cross(b - a)
		var normal := cross.normalized()
		if normal.length_squared() < 0.5:
			continue
		var axis := _dominant_axis(normal)
		if absf(normal[axis]) < FACE_AXIS_DOT_MIN:
			continue
		var plane := (a[axis] + b[axis] + c[axis]) / 3.0
		var side := ""
		if absf(plane - bounds.position[axis]) <= plane_epsilon:
			side = "min"
		elif absf(plane - bounds.end[axis]) <= plane_epsilon:
			side = "max"
		if side.is_empty():
			continue
		var tangent_axes := _tangent_axes(axis)
		var minimum := Vector2(minf(a[tangent_axes.x], minf(b[tangent_axes.x], c[tangent_axes.x])),
			minf(a[tangent_axes.y], minf(b[tangent_axes.y], c[tangent_axes.y])))
		var maximum := Vector2(maxf(a[tangent_axes.x], maxf(b[tangent_axes.x], c[tangent_axes.x])),
			maxf(a[tangent_axes.y], maxf(b[tangent_axes.y], c[tangent_axes.y])))
		var plane_key := roundi(plane / plane_epsilon)
		var groups: Dictionary = planes[axis][side]
		if groups.has(plane_key):
			var group: Dictionary = groups[plane_key]
			group["minimum"] = Vector2(minf(group["minimum"].x, minimum.x),
				minf(group["minimum"].y, minimum.y))
			group["maximum"] = Vector2(maxf(group["maximum"].x, maximum.x),
				maxf(group["maximum"].y, maximum.y))
			group["plane_sum"] = float(group["plane_sum"]) + plane
			group["triangle_count"] = int(group["triangle_count"]) + 1
			var group_triangles: Array = group["triangles"]
			group_triangles.append(PackedVector3Array([a, b, c]))
			group["triangles"] = group_triangles
		else:
			groups[plane_key] = {"plane": plane, "plane_sum": plane,
				"triangle_count": 1, "minimum": minimum, "maximum": maximum,
				"triangles": [PackedVector3Array([a, b, c])]}
		planes[axis][side] = groups
	var result: Array[Dictionary] = []
	for axis in 3:
		var min_group := _best_boundary_plane(planes[axis]["min"], bounds.position[axis])
		var max_group := _best_boundary_plane(planes[axis]["max"], bounds.end[axis])
		if min_group.is_empty() or max_group.is_empty():
			continue
		if absf(min_group["plane"] - max_group["plane"]) <= plane_epsilon:
			continue
		var min_bounds: Vector2 = min_group["minimum"]
		var max_bounds: Vector2 = max_group["minimum"]
		var min_bounds_max: Vector2 = min_group["maximum"]
		var max_bounds_max: Vector2 = max_group["maximum"]
		if absf(min_bounds.x - max_bounds.x) > plane_epsilon \
				or absf(min_bounds.y - max_bounds.y) > plane_epsilon \
				or absf(min_bounds_max.x - max_bounds_max.x) > plane_epsilon \
				or absf(min_bounds_max.y - max_bounds_max.y) > plane_epsilon:
			continue
		result.append({"axis": axis, "component": String(solid.get("path", "")),
			"solid_index": -1, "plus_plane": float(max_group["plane"]),
			"minus_plane": float(min_group["plane"]),
			"midplane": (float(max_group["plane"]) + float(min_group["plane"])) * 0.5,
			"tangent_min": max_bounds, "tangent_max": max_bounds_max,
			"plus_face_triangles": max_group["triangles"],
			"minus_face_triangles": min_group["triangles"],
			"thickness": absf(float(max_group["plane"]) - float(min_group["plane"]))})
	return result


static func _is_full_axis_aligned_box(solid: Dictionary,
		pairs: Array[Dictionary]) -> bool:
	if pairs.size() != 3:
		return false
	var axes := {}
	for pair in pairs:
		axes[int(pair["axis"])] = true
	if axes.size() != 3:
		return false
	var faces: PackedVector3Array = solid["faces"]
	var bounds: AABB = solid["bounds"]
	var plane_epsilon := maxf(0.0001, bounds.size.length() * 1e-6)
	for face_offset in range(0, faces.size() - 2, 3):
		var a: Vector3 = faces[face_offset]
		var b: Vector3 = faces[face_offset + 1]
		var c: Vector3 = faces[face_offset + 2]
		var normal := (c - a).cross(b - a).normalized()
		if normal.length_squared() < 0.5:
			continue
		var axis := _dominant_axis(normal)
		if absf(normal[axis]) < FACE_AXIS_DOT_MIN:
			return false
		var plane := (a[axis] + b[axis] + c[axis]) / 3.0
		if absf(plane - bounds.position[axis]) > plane_epsilon \
				and absf(plane - bounds.end[axis]) > plane_epsilon:
			return false
	return true


static func _best_boundary_plane(groups: Dictionary, expected_plane: float) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := INF
	for group_variant in groups.values():
		var group: Dictionary = group_variant
		var distance := absf(float(group["plane"]) - expected_plane)
		if distance < best_distance:
			best_distance = distance
			best = group.duplicate()
	if best.is_empty():
		return {}
	var count := maxi(1, int(best["triangle_count"]))
	best["plane"] = float(best["plane_sum"]) / float(count)
	return best


static func _pair_distance(point: Vector3, pair: Dictionary) -> float:
	var axis := int(pair["axis"])
	var tangent_axes := _tangent_axes(axis)
	var tangent_min: Vector2 = pair["tangent_min"]
	var tangent_max: Vector2 = pair["tangent_max"]
	var tangent_distance_squared := 0.0
	for component in 2:
		var value := point[tangent_axes[component]]
		if value < tangent_min[component]:
			tangent_distance_squared += pow(tangent_min[component] - value, 2.0)
		elif value > tangent_max[component]:
			tangent_distance_squared += pow(value - tangent_max[component], 2.0)
	var plane_distance := minf(absf(point[axis] - float(pair["plus_plane"])),
		absf(point[axis] - float(pair["minus_plane"])))
	return sqrt(plane_distance * plane_distance + tangent_distance_squared)


static func _select_pair_queries(world: Vector3, step: float, pair: Dictionary,
		solids: Array[Dictionary], placement: Placement, data: Data,
		source_buckets: Dictionary, source_spacing: float,
		query_cache: Dictionary) -> Dictionary:
	var axis := int(pair["axis"])
	var tangent_axes := _tangent_axes(axis)
	var tangent_min: Vector2 = pair["tangent_min"]
	var tangent_max: Vector2 = pair["tangent_max"]
	var initial := Vector2(
		clampf(world[tangent_axes.x], tangent_min.x, tangent_max.x),
		clampf(world[tangent_axes.y], tangent_min.y, tangent_max.y))
	var shifts: Array[Vector2] = [Vector2.ZERO]
	for ring in range(1, ceili(MAX_TANGENT_SHIFT_M / TANGENT_SHIFT_STEP_M) + 1):
		var amount := float(ring) * TANGENT_SHIFT_STEP_M
		for signed_amount in [-amount, amount]:
			shifts.append(Vector2(signed_amount, 0.0))
			shifts.append(Vector2(0.0, signed_amount))
			for other_signed in [-amount, amount]:
				shifts.append(Vector2(signed_amount, other_signed))
	shifts.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		if not is_equal_approx(a.length_squared(), b.length_squared()):
			return a.length_squared() < b.length_squared()
		if not is_equal_approx(a.x, b.x):
			return a.x < b.x
		return a.y < b.y)
	var plus_normal := Vector3.ZERO
	plus_normal[axis] = 1.0
	var minus_normal := -plus_normal
	for shift in shifts:
		var tangent := Vector2(
			clampf(initial.x + shift.x, tangent_min.x, tangent_max.x),
			clampf(initial.y + shift.y, tangent_min.y, tangent_max.y))
		var plus_query := world
		var minus_query := world
		plus_query[axis] = float(pair["plus_plane"]) + QUERY_OFFSET_M
		minus_query[axis] = float(pair["minus_plane"]) - QUERY_OFFSET_M
		plus_query[tangent_axes.x] = tangent.x
		plus_query[tangent_axes.y] = tangent.y
		minus_query[tangent_axes.x] = tangent.x
		minus_query[tangent_axes.y] = tangent.y
		plus_query = _free_surface_query(plus_query - plus_normal * QUERY_OFFSET_M,
			plus_normal, solids, placement)
		minus_query = _free_surface_query(minus_query - minus_normal * QUERY_OFFSET_M,
			minus_normal, solids, placement)
		if not plus_query.is_finite() or not minus_query.is_finite():
			continue
		var plus_key := _query_cache_key(plus_query, step,
			"axis_%d_plus_%s" % [axis, String(pair["component"])])
		var minus_key := _query_cache_key(minus_query, step,
			"axis_%d_minus_%s" % [axis, String(pair["component"])])
		if not query_cache.has(plus_key):
			query_cache[plus_key] = _gather_tensor(plus_query, step, plus_normal,
				float(pair["midplane"]), 1, data, source_buckets, source_spacing,
				axis, SOURCE_NORMAL_DOT_MIN)
		if not query_cache.has(minus_key):
			query_cache[minus_key] = _gather_tensor(minus_query, step, minus_normal,
				float(pair["midplane"]), -1, data, source_buckets, source_spacing,
				axis, SOURCE_NORMAL_DOT_MIN)
		var plus_gather: Dictionary = query_cache[plus_key]
		var minus_gather: Dictionary = query_cache[minus_key]
		if not bool(plus_gather.get("valid", false)) \
				or not bool(minus_gather.get("valid", false)):
			continue
		return {"pair": pair, "plus": plus_gather, "minus": minus_gather,
			"plus_query": plus_query, "minus_query": minus_query,
			"tangent_shift_m": shift.length()}
	return {}


static func _face_surface_distance(world: Vector3, pair: Dictionary,
		side_sign: int) -> float:
	var axis := int(pair["axis"])
	var plane := float(pair["plus_plane"] if side_sign > 0 else pair["minus_plane"])
	var tangent_axes := _tangent_axes(axis)
	var tangent_min: Vector2 = pair["tangent_min"]
	var tangent_max: Vector2 = pair["tangent_max"]
	var closest := world
	closest[axis] = plane
	closest[tangent_axes.x] = clampf(world[tangent_axes.x], tangent_min.x, tangent_max.x)
	closest[tangent_axes.y] = clampf(world[tangent_axes.y], tangent_min.y, tangent_max.y)
	return world.distance_to(closest)


static func _select_single_face_query(world: Vector3, step: float,
		pair: Dictionary, side_sign: int, grow: float,
		solids: Array[Dictionary], placement: Placement, data: Data,
		source_buckets: Dictionary, source_spacing: float,
		query_cache: Dictionary) -> Dictionary:
	var axis := int(pair["axis"])
	var plane := float(pair["plus_plane"] if side_sign > 0 else pair["minus_plane"])
	var face_distance := absf(world[axis] - plane)
	if face_distance > grow:
		return {}
	var tangent_axes := _tangent_axes(axis)
	var tangent_min: Vector2 = pair["tangent_min"]
	var tangent_max: Vector2 = pair["tangent_max"]
	var initial := Vector2(
		clampf(world[tangent_axes.x], tangent_min.x, tangent_max.x),
		clampf(world[tangent_axes.y], tangent_min.y, tangent_max.y))
	var shifts: Array[Vector2] = [Vector2.ZERO]
	for ring in range(1, ceili(MAX_TANGENT_SHIFT_M / TANGENT_SHIFT_STEP_M) + 1):
		var amount := float(ring) * TANGENT_SHIFT_STEP_M
		for signed_amount in [-amount, amount]:
			shifts.append(Vector2(signed_amount, 0.0))
			shifts.append(Vector2(0.0, signed_amount))
			for other_signed in [-amount, amount]:
				shifts.append(Vector2(signed_amount, other_signed))
	shifts.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		if not is_equal_approx(a.length_squared(), b.length_squared()):
			return a.length_squared() < b.length_squared()
		if not is_equal_approx(a.x, b.x):
			return a.x < b.x
		return a.y < b.y)
	var normal := Vector3.ZERO
	normal[axis] = float(side_sign)
	var last_failure := "no_known_free_query_in_shift_budget"
	for shift in shifts:
		var tangent := Vector2(
			clampf(initial.x + shift.x, tangent_min.x, tangent_max.x),
			clampf(initial.y + shift.y, tangent_min.y, tangent_max.y))
		var world_tangent := Vector2(world[tangent_axes.x], world[tangent_axes.y])
		if world_tangent.distance_to(tangent) > MAX_TANGENT_SHIFT_M:
			last_failure = "face_query_tangent_shift_exceeded"
			continue
		var query := world
		query[axis] = plane + float(side_sign) * QUERY_OFFSET_M
		query[tangent_axes.x] = tangent.x
		query[tangent_axes.y] = tangent.y
		var surface_query := query - normal * QUERY_OFFSET_M
		query = _free_surface_query(surface_query, normal, solids, placement)
		if not query.is_finite():
			continue
		var cache_key := _query_cache_key(query, step,
			"local_face_sources_%s_%d_%s" % [String(pair["component"]), axis, str(side_sign)])
		if not query_cache.has(cache_key):
			query_cache[cache_key] = _gather_axis_face_response(world, step,
				pair, side_sign, solids, placement, data, true, query,
				MAX_TANGENT_SHIFT_M)
		var gathered: Dictionary = query_cache[cache_key]
		if not bool(gathered.get("valid", false)):
			last_failure = String(gathered.get("reason", "same_face_source_rejected"))
			continue
		var support_distance := _face_surface_distance(world, pair, side_sign)
		return {"valid": true, "normal": normal, "query": query,
			"surface_query": surface_query, "distance": support_distance,
			"response": gathered["response"], "tensor": gathered["tensor"],
			"visible_count": int(gathered["support_count"]),
			"candidate_count": int(gathered["support_count"]),
			"blocked_count": 0,
			"source_indices": gathered.get("source_indices", PackedInt32Array())}
	return {"valid": false, "reason": last_failure}


static func _put_signed_constraint_or_lock(target: Dictionary, locked: Dictionary,
		conflict_face_tags: Dictionary, key: int, candidate: Dictionary,
		step: float, stats: Dictionary) -> bool:
	if not candidate.has("target") or not candidate["target"] is Vector3 \
			or not _finite_vector3(candidate["target"]):
		return false
	var candidate_tag := String(candidate.get("face_tag", ""))
	if locked.has(key):
		_add_conflict_face_tag(conflict_face_tags, key, candidate_tag)
		return true
	if not target.has(key):
		target[key] = candidate
		return true
	var prior: Dictionary = target[key]
	var distance_delta := absf(float(candidate.get("distance", INF))
		- float(prior.get("distance", INF)))
	if distance_delta <= step * 0.15 and _response_disagrees(
			prior["target"], candidate["target"], AXIS_CONFLICT_RELATIVE_TOLERANCE):
		locked[key] = true
		target.erase(key)
		var prior_tag := String(prior.get("face_tag", ""))
		_add_conflict_face_tag(conflict_face_tags, key, prior_tag)
		_add_conflict_face_tag(conflict_face_tags, key, candidate_tag)
		var lock_count := int(stats.get("same_signed_conflicts_locked", 0)) + 1
		stats["same_signed_conflicts_locked"] = lock_count
		return true
	if float(candidate.get("distance", INF)) < float(prior.get("distance", INF)):
		target[key] = candidate
	return true


static func _add_conflict_face_tag(target: Dictionary, key: int, tag: String) -> void:
	if tag.is_empty():
		return
	var tags: Array = target.get(key, [])
	if not tags.has(tag):
		tags.append(tag)
	target[key] = tags


static func _face_tag_is_conflicted(tag: String, conflict_face_tags: Dictionary) -> bool:
	if tag.is_empty():
		return false
	for tags_value in conflict_face_tags.values():
		if tags_value is Array and tags_value.has(tag):
			return true
	return false


static func _signed_key_normal(key: int) -> Vector3:
	var axis := key >> 1
	if axis < 0 or axis > 2:
		return Vector3.ZERO
	var result := Vector3.ZERO
	result[axis] = 1.0 if (key & 1) != 0 else -1.0
	return result


static func _collect_axis_face_source_indices(pair: Dictionary, side_sign: int,
		data: Data) -> PackedInt32Array:
	var result := PackedInt32Array()
	var axis := int(pair["axis"])
	var plane := float(pair["plus_plane"] if side_sign > 0 else pair["minus_plane"])
	var face_normal := Vector3.ZERO
	face_normal[axis] = float(side_sign)
	var tangent_axes := _tangent_axes(axis)
	var tangent_min: Vector2 = pair["tangent_min"]
	var tangent_max: Vector2 = pair["tangent_max"]
	var faces: Array = pair["plus_face_triangles"] if side_sign > 0 \
			else pair["minus_face_triangles"]
	for probe in data.probe_count():
		var surface_position: Vector3 = data.surface_positions[probe]
		var sample_position: Vector3 = data.positions[probe]
		if absf(surface_position[axis] - plane) > FACE_SOURCE_ANCHOR_TOLERANCE_M:
			continue
		if (sample_position[axis] - plane) * float(side_sign) \
				< SOURCE_ANCHOR_EPSILON_M:
			continue
		if data.normals[probe].normalized().dot(face_normal) < FACE_SOURCE_NORMAL_DOT_MIN:
			continue
		var tangent := Vector2(surface_position[tangent_axes.x],
			surface_position[tangent_axes.y])
		if tangent.x < tangent_min.x - FACE_SOURCE_ANCHOR_TOLERANCE_M \
				or tangent.x > tangent_max.x + FACE_SOURCE_ANCHOR_TOLERANCE_M \
				or tangent.y < tangent_min.y - FACE_SOURCE_ANCHOR_TOLERANCE_M \
				or tangent.y > tangent_max.y + FACE_SOURCE_ANCHOR_TOLERANCE_M:
			continue
		if not _point_on_face_triangles(surface_position, faces,
				FACE_SOURCE_ANCHOR_TOLERANCE_M):
			continue
		result.append(probe)
	return result


static func _point_on_face_triangles(point: Vector3, triangles: Array,
		tolerance: float) -> bool:
	var tolerance_squared := tolerance * tolerance
	for triangle_value in triangles:
		if not triangle_value is PackedVector3Array:
			continue
		var triangle: PackedVector3Array = triangle_value
		if triangle.size() != 3:
			continue
		var closest := _closest_point_triangle(point, triangle[0], triangle[1], triangle[2])
		if point.distance_squared_to(closest) <= tolerance_squared:
			return true
	return false


static func _gather_axis_face_response(world: Vector3, step: float,
		pair: Dictionary, side_sign: int, solids: Array[Dictionary],
		placement: Placement, data: Data,
		use_query_override: bool = false,
		query_override: Vector3 = Vector3.ZERO,
		max_tangent_shift: float = FACE_SOURCE_QUERY_TANGENT_MAX_M) -> Dictionary:
	var axis := int(pair["axis"])
	var plane := float(pair["plus_plane"] if side_sign > 0 else pair["minus_plane"])
	var normal := Vector3.ZERO
	normal[axis] = float(side_sign)
	var tangent_axes := _tangent_axes(axis)
	var tangent_min: Vector2 = pair["tangent_min"]
	var tangent_max: Vector2 = pair["tangent_max"]
	var query := world
	var tangent: Vector2
	if use_query_override:
		query = query_override
		tangent = Vector2(query[tangent_axes.x], query[tangent_axes.y])
		var query_offset := (query[axis] - plane) * float(side_sign)
		if query_offset < MIN_QUERY_OFFSET_M - SOURCE_ANCHOR_EPSILON_M \
				or query_offset > QUERY_OFFSET_M + SOURCE_ANCHOR_EPSILON_M:
			return {"valid": false, "reason": "face_query_override_plane_mismatch"}
		if tangent.x < tangent_min.x - FACE_SOURCE_ANCHOR_TOLERANCE_M \
				or tangent.x > tangent_max.x + FACE_SOURCE_ANCHOR_TOLERANCE_M \
				or tangent.y < tangent_min.y - FACE_SOURCE_ANCHOR_TOLERANCE_M \
				or tangent.y > tangent_max.y + FACE_SOURCE_ANCHOR_TOLERANCE_M:
			return {"valid": false, "reason": "face_query_override_outside_patch"}
	else:
		tangent = Vector2(
			clampf(world[tangent_axes.x], tangent_min.x, tangent_max.x),
			clampf(world[tangent_axes.y], tangent_min.y, tangent_max.y))
		query[axis] = plane + float(side_sign) * QUERY_OFFSET_M
		query[tangent_axes.x] = tangent.x
		query[tangent_axes.y] = tangent.y
		query = _free_surface_query(query - normal * QUERY_OFFSET_M,
			normal, solids, placement)
		if not query.is_finite():
			return {"valid": false, "reason": "face_query_not_known_free"}
	var tangent_shift := Vector2(world[tangent_axes.x], world[tangent_axes.y]).distance_to(tangent)
	if tangent_shift > max_tangent_shift \
			or _classify_union(query, solids, placement) != "known_free":
		return {"valid": false, "reason": "face_query_not_known_free"}
	var face_diagonal := (tangent_max - tangent_min).length()
	var max_distance := minf(MAX_FACE_SOURCE_EXTRAPOLATION_M, face_diagonal)
	if max_distance <= 0.0:
		return {"valid": false, "reason": "face_source_domain_empty"}
	var source_indices: PackedInt32Array = pair[
			"plus_face_source_indices" if side_sign > 0 else "minus_face_source_indices"]
	var candidates: Array[Dictionary] = []
	var epsilon := maxf(step * step * 0.16, 0.0001)
	for probe in source_indices:
		var sample_position: Vector3 = data.positions[probe]
		var distance_squared := sample_position.distance_squared_to(query)
		if distance_squared > max_distance * max_distance:
			continue
		if Visibility.segment_blocked(data.visibility_nodes,
				data.visibility_triangles, sample_position, query):
			continue
		if _matches_contact_anchor(query, data.surface_positions[probe], normal,
				data.normals[probe], sample_position):
			var measured := _source_measurement(data, probe, normal)
			measured["query"] = query
			measured["support_count"] = 1
			measured["loo_relative_error"] = 0.0
			measured["loo_max_scaled_error"] = 0.0
			return measured
		var source_coefficients := PackedFloat32Array()
		source_coefficients.resize(27)
		var coefficient_start := probe * 27
		var coefficients_finite := true
		for coefficient in 27:
			var value := data.baked_indirect_sh[coefficient_start + coefficient]
			if not is_finite(value):
				coefficients_finite = false
				break
			source_coefficients[coefficient] = value
		if not coefficients_finite:
			continue
		var tensor := _sh_to_tensor(source_coefficients)
		if not _tensor_is_finite(tensor):
			continue
		var local_spacing := data.probe_spacings[probe] \
				if data.probe_spacings.size() == data.probe_count() else data.spacing
		var weight := local_spacing * local_spacing \
				/ sqrt(epsilon + distance_squared)
		if weight <= 0.0 or not is_finite(weight):
			continue
		candidates.append({"probe": probe, "tensor": tensor,
			"weight": weight, "distance_squared": distance_squared})
	if candidates.size() < FACE_SOURCE_MIN_SUPPORT:
		return {"valid": false, "reason": "insufficient_same_face_sources",
			"support_count": candidates.size(),
			"source_indices": _candidate_probe_indices(candidates)}
	var maximum_relative_error := 0.0
	var maximum_scaled_error := 0.0
	for held_out_index in candidates.size():
		var held_out: Array = candidates[held_out_index]["tensor"]
		var prediction := _zero_tensor()
		var prediction_count := 0
		for candidate_index in candidates.size():
			if candidate_index == held_out_index:
				continue
			var candidate_tensor: Array = candidates[candidate_index]["tensor"]
			for term in 9:
				prediction[term] += candidate_tensor[term]
			prediction_count += 1
		if prediction_count <= 0:
			return {"valid": false, "reason": "face_source_loo_empty"}
		for term in 9:
			prediction[term] /= float(prediction_count)
		var error_squared := 0.0
		var reference_squared := 0.0
		var max_error := 0.0
		var max_reference := 0.0
		for term in 9:
			var difference: Vector3 = held_out[term] - prediction[term]
			error_squared += difference.length_squared()
			reference_squared += held_out[term].length_squared()
			max_error = maxf(max_error, _max_abs(difference))
			max_reference = maxf(max_reference, _max_abs(held_out[term]))
		var relative_error := sqrt(error_squared) / maxf(sqrt(reference_squared), 1e-6)
		var scaled_error := max_error / maxf(max_reference, 1.0)
		maximum_relative_error = maxf(maximum_relative_error, relative_error)
		maximum_scaled_error = maxf(maximum_scaled_error, scaled_error)
	if maximum_relative_error > FACE_SOURCE_LOO_RELATIVE_TOLERANCE \
			or maximum_scaled_error > FACE_SOURCE_LOO_MAX_SCALED_TOLERANCE:
		return {"valid": false, "reason": "same_face_tensor_loo_disagreement",
			"support_count": candidates.size(),
			"source_indices": _candidate_probe_indices(candidates),
			"loo_relative_error": maximum_relative_error,
			"loo_max_scaled_error": maximum_scaled_error}
	var average_tensor := _zero_tensor()
	var total_weight := 0.0
	for candidate in candidates:
		var weight := float(candidate["weight"])
		var candidate_tensor: Array = candidate["tensor"]
		for term in 9:
			average_tensor[term] += candidate_tensor[term] * weight
		total_weight += weight
	if total_weight <= 0.0 or not is_finite(total_weight):
		return {"valid": false, "reason": "same_face_source_weight_invalid"}
	for term in 9:
		average_tensor[term] /= total_weight
	if not _tensor_is_finite(average_tensor):
		return {"valid": false, "reason": "same_face_source_tensor_nonfinite"}
	var used_source_indices := PackedInt32Array()
	for candidate in candidates:
		used_source_indices.append(int(candidate["probe"]))
	return {"valid": true, "query": query,
		"response": _tensor_response(average_tensor, normal),
		"tensor": average_tensor, "support_count": candidates.size(),
		"source_indices": used_source_indices,
		"loo_relative_error": maximum_relative_error,
		"loo_max_scaled_error": maximum_scaled_error}


static func _candidate_probe_indices(candidates: Array[Dictionary]) -> PackedInt32Array:
	var indices := PackedInt32Array()
	for candidate in candidates:
		indices.append(int(candidate["probe"]))
	return indices


static func _response_disagrees(a: Vector3, b: Vector3,
		relative_tolerance: float) -> bool:
	var scale := maxf(1.0, maxf(_max_abs(a), _max_abs(b)))
	return _max_abs(a - b) > relative_tolerance * scale


static func _axis_pair_conflict(a: Dictionary, b: Dictionary) -> bool:
	var plus_a: Vector3 = a["plus"]["response"]
	var plus_b: Vector3 = b["plus"]["response"]
	var minus_a: Vector3 = a["minus"]["response"]
	var minus_b: Vector3 = b["minus"]["response"]
	var error := _max_abs(plus_a - plus_b) + _max_abs(minus_a - minus_b)
	var scale := maxf(1.0, maxf(maxf(_max_abs(plus_a), _max_abs(plus_b)),
		maxf(_max_abs(minus_a), _max_abs(minus_b))))
	return error > AXIS_CONFLICT_RELATIVE_TOLERANCE * scale


static func _select_curved_query(world: Vector3, step: float, solid: Dictionary,
		nearest: Dictionary, solids: Array[Dictionary], placement: Placement,
		data: Data, source_buckets: Dictionary, source_spacing: float,
		query_cache: Dictionary) -> Dictionary:
	var normal: Vector3 = nearest["normal"]
	var surface: Vector3 = nearest["point"]
	var first_query := _free_surface_query(surface, normal, solids, placement)
	var second_query := _free_surface_query(surface, -normal, solids, placement)
	if first_query.is_finite() and _classify_union(surface - normal * MIN_QUERY_OFFSET_M,
			solids, placement) == "known_solid":
		pass
	elif second_query.is_finite() and _classify_union(surface + normal * MIN_QUERY_OFFSET_M,
			solids, placement) == "known_solid":
		normal = -normal
		first_query = second_query
	else:
		return {}
	var key := _query_cache_key(first_query, step,
		"curved_%d_%d" % [int(solid["instance_id"]), int(nearest["triangle_index"])])
	if not query_cache.has(key):
		query_cache[key] = _gather_tensor(first_query, step, normal, 0.0, 0,
				data, source_buckets, source_spacing, -1, SOURCE_NORMAL_DOT_MIN)
	var gathered: Dictionary = query_cache[key]
	if not bool(gathered.get("valid", false)):
		return {}
	return {"normal": normal, "query": first_query, "surface": surface,
		"distance": float(nearest["distance"]),
		"triangle_index": int(nearest["triangle_index"]),
		"tensor": gathered["tensor"],
		"response": gathered["response"],
		"support_count": int(gathered["visible_count"])}


static func _gather_tensor(point: Vector3, step: float, normal_gate: Vector3,
		side_plane: float, side_sign: int, data: Data, source_buckets: Dictionary,
		source_spacing: float, side_axis: int = -1,
		normal_dot_min: float = -1.0,
		collect_source_indices: bool = false) -> Dictionary:
	var grid_position := data.world_to_grid * point
	if not _finite_vector3(grid_position):
		return {"valid": false}
	var center := Vector3i(floori(grid_position.x), floori(grid_position.y), floori(grid_position.z))
	var fraction := grid_position - Vector3(center)
	var radius := maxi(2, ceili(SOURCE_RADIUS_IN_CLV_CELLS * step / source_spacing))
	var epsilon := maxf(step * step * 0.16, 0.0001)
	var total_weight := 0.0
	var candidate_count := 0
	var blocked_count := 0
	var used_source_indices := PackedInt32Array()
	var weighted_coefficients := PackedFloat64Array()
	weighted_coefficients.resize(27)
	var world_buckets: Dictionary = source_buckets
	for dz in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var cell := center + Vector3i(dx, dy, dz)
				if cell.x < 0 or cell.y < 0 or cell.z < 0 \
						or cell.x >= data.grid_dims.x or cell.y >= data.grid_dims.y \
						or cell.z >= data.grid_dims.z:
					continue
				var window := _cell_window(cell, center, fraction, radius)
				if window <= 0.0:
					continue
				var probes: Array = world_buckets.get(cell, [])
				for probe_value in probes:
					var probe := int(probe_value)
					var sample_position: Vector3 = data.positions[probe]
					var surface_position: Vector3 = data.surface_positions[probe]
					if side_sign != 0 \
							and (surface_position[side_axis] - side_plane) * float(side_sign) <= 0.0:
						continue
					# A narrow gap has one full-sphere radiance sample per CLV cell,
					# sometimes anchored to the opposing surface. Its SH is independent
					# of receiver normal. Reuse only a nearly coincident, mutually visible
					# sample; distant/opposite-side normals still follow the normal gate.
					var shared_gap_sample := side_sign != 0 \
						and data.normals[probe].normalized().dot(normal_gate) < -SOURCE_NORMAL_DOT_MIN \
						and sample_position.distance_squared_to(point) <= pow(minf(QUERY_OFFSET_M * 0.25,
							source_spacing * 0.03), 2.0)
					if normal_dot_min >= 0.0 \
							and data.normals[probe].normalized().dot(normal_gate) < normal_dot_min \
							and not shared_gap_sample:
						continue
					var local_spacing := data.probe_spacings[probe] \
							if data.probe_spacings.size() == data.probe_count() else source_spacing
					if local_spacing <= 0.0 or not is_finite(local_spacing):
						continue
					var offset := point - sample_position
					var distance_squared := offset.length_squared()
					var distance := sqrt(maxf(distance_squared, 0.0))
					var density_window := 1.0
					if local_spacing < source_spacing * 0.999:
						var support := local_spacing * 2.5
						if distance >= support:
							continue
						density_window = 1.0 - smoothstep(local_spacing * 1.5,
							support, distance)
					var weight := window * density_window * local_spacing * local_spacing \
							/ sqrt(epsilon + distance_squared)
					if weight <= 0.0 or not is_finite(weight):
						continue
					candidate_count += 1
					if Visibility.segment_blocked(data.visibility_nodes,
							data.visibility_triangles, sample_position, point):
						blocked_count += 1
						continue
					# At a narrow-contact anchor, reproduce the measured SH. Averaging
					# neighbours here erases occlusion; ordinary faces keep their filter.
					# Side, normal and visibility checks above remain mandatory.
					if shared_gap_sample or (side_sign != 0 and _matches_contact_anchor(point, surface_position,
							normal_gate, data.normals[probe], sample_position)):
						return _source_measurement(data, probe, normal_gate)
					if collect_source_indices:
						used_source_indices.append(probe)
					total_weight += weight
					for coefficient in 27:
						weighted_coefficients[coefficient] += \
								weight * data.baked_indirect_sh[probe * 27 + coefficient]
	if total_weight <= MINIMUM_VISIBLE_WEIGHT or not is_finite(total_weight):
		return {"valid": false, "visible_count": 0, "blocked_count": blocked_count,
			"candidate_count": candidate_count,
			"source_indices": used_source_indices if collect_source_indices else PackedInt32Array()}
	var coefficients := PackedFloat32Array()
	coefficients.resize(27)
	for coefficient in 27:
		coefficients[coefficient] = float(weighted_coefficients[coefficient] / total_weight)
	var tensor := _sh_to_tensor(coefficients)
	return {"valid": true, "coefficients": coefficients, "tensor": tensor,
		"response": _tensor_response(tensor, normal_gate) if normal_gate.length_squared() > 0.0 else Vector3.ZERO,
		"visible_count": candidate_count - blocked_count,
		"blocked_count": blocked_count, "candidate_count": candidate_count,
		"visible_weight": total_weight,
		"source_indices": used_source_indices if collect_source_indices else PackedInt32Array()}


static func _cell_window(cell: Vector3i, center: Vector3i,
		fraction: Vector3, radius: int) -> float:
	var result := 1.0
	for axis in 3:
		var offset := cell[axis] - center[axis]
		if abs(offset) == radius:
			if offset < 0:
				result *= 1.0 - smoothstep(0.0, 1.0, fraction[axis])
			else:
				result *= smoothstep(0.0, 1.0, fraction[axis])
	return result


static func _matches_contact_anchor(query: Vector3, surface: Vector3,
		normal: Vector3, source_normal: Vector3, sample_position: Vector3) -> bool:
	if source_normal.normalized().dot(normal) < FACE_AXIS_DOT_MIN:
		return false
	var delta := query - surface
	var offset := delta.dot(normal)
	# Preserve the low-noise reconstruction on unconstrained wall/ceiling faces.
	# Only geometry that forced a smaller clearance needs a cardinal contact sample.
	if minf(offset, (sample_position - surface).dot(normal)) >= QUERY_OFFSET_M - SOURCE_ANCHOR_EPSILON_M:
		return false
	return offset >= 0.0 and offset <= QUERY_OFFSET_M + SOURCE_ANCHOR_EPSILON_M \
		and (delta - normal * offset).length_squared() <= SOURCE_ANCHOR_EPSILON_M * SOURCE_ANCHOR_EPSILON_M


static func _source_measurement(data: Data, probe: int, normal: Vector3) -> Dictionary:
	var coefficients := data.baked_indirect_sh.slice(probe * 27, (probe + 1) * 27)
	var tensor := _sh_to_tensor(coefficients)
	return {"valid": _tensor_is_finite(tensor), "coefficients": coefficients,
		"tensor": tensor, "response": _tensor_response(tensor, normal),
		"visible_count": 1, "candidate_count": 1, "blocked_count": 0,
		"visible_weight": 1.0, "source_indices": PackedInt32Array([probe])}


static func _free_surface_query(surface: Vector3, normal: Vector3,
		solids: Array[Dictionary], placement: Placement) -> Vector3:
	# Search normal clearance before moving tangentially out of a contact shadow.
	# The near endpoint and segment proof prevent jumping across thin occluders.
	var start := surface + normal * (MIN_QUERY_OFFSET_M * 0.5)
	if _classify_union(start, solids, placement) != "known_free":
		return Vector3(INF, INF, INF)
	var offset := QUERY_OFFSET_M
	while offset >= MIN_QUERY_OFFSET_M:
		var query := surface + normal * offset
		if _classify_union(query, solids, placement) == "known_free":
			var blocked := false
			for solid in solids:
				var bvh: TriangleMesh = solid["bvh"]
				if not bvh.intersect_segment(start, query).is_empty():
					blocked = true
					break
			if not blocked:
				return query
		if offset == MIN_QUERY_OFFSET_M:
			break
		offset = maxf(offset * 0.5, MIN_QUERY_OFFSET_M)
	return Vector3(INF, INF, INF)


static func _classify_union(point: Vector3, solids: Array[Dictionary],
		placement: Placement) -> String:
	var has_unknown := false
	for solid in solids:
		var bounds: AABB = solid["bounds"]
		var epsilon := maxf(0.000001, bounds.size.length() * 0.000001)
		if not bounds.grow(epsilon).has_point(point):
			continue
		var state: int = placement._point_inside_closed_mesh_state(point,
				bounds, solid["bvh"], solid["faces"])
		if state == 1:
			return "known_solid"
		if state < 0:
			has_unknown = true
	return "unknown" if has_unknown else "known_free"


static func _nearest_triangle(point: Vector3, faces: PackedVector3Array,
		step: float) -> Dictionary:
	var best_distance_squared := INF
	var best_point := Vector3.ZERO
	var best_normal := Vector3.ZERO
	var best_index := -1
	var ambiguous := false
	var tie_distance := maxf(0.00001, step * 0.002)
	for face_offset in range(0, faces.size() - 2, 3):
		var a: Vector3 = faces[face_offset]
		var b: Vector3 = faces[face_offset + 1]
		var c: Vector3 = faces[face_offset + 2]
		var raw_normal := (c - a).cross(b - a)
		var normal := raw_normal.normalized()
		if normal.length_squared() < 0.5:
			continue
		var closest := _closest_point_triangle(point, a, b, c)
		var distance_squared := point.distance_squared_to(closest)
		if distance_squared + tie_distance * tie_distance < best_distance_squared:
			best_distance_squared = distance_squared
			best_point = closest
			best_normal = normal
			best_index = face_offset / 3
			ambiguous = false
		elif absf(distance_squared - best_distance_squared) <= tie_distance * tie_distance \
				and best_index >= 0 and absf(normal.dot(best_normal)) < 0.95:
			ambiguous = true
	if best_index < 0 or ambiguous:
		return {}
	return {"triangle_index": best_index, "point": best_point,
		"normal": best_normal, "distance": sqrt(best_distance_squared)}


static func _closest_point_triangle(point: Vector3, a: Vector3,
		b: Vector3, c: Vector3) -> Vector3:
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
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denominator := 1.0 / (va + vb + vc)
	var v := vb * denominator
	var w := vc * denominator
	return a + ab * v + ac * w


static func _point_aabb_distance_squared(point: Vector3, bounds: AABB) -> float:
	var closest := Vector3(
		clampf(point.x, bounds.position.x, bounds.end.x),
		clampf(point.y, bounds.position.y, bounds.end.y),
		clampf(point.z, bounds.position.z, bounds.end.z))
	return point.distance_squared_to(closest)


static func _fit_tensor_constraints(base: Array, constraints: Array[Dictionary]) -> Dictionary:
	if constraints.is_empty():
		return {"valid": true, "tensor": base}
	if base.size() != 9 or constraints.size() > 9:
		return {"valid": false, "reason": "unsupported_tensor_constraint_count"}
	var rows: Array[PackedFloat64Array] = []
	var targets: Array[Vector3] = []
	for constraint in constraints:
		var row := _tensor_basis(constraint["normal"])
		for prior in rows:
			var identical := true
			for lane in 9:
				if absf(row[lane] - prior[lane]) >= 1e-7:
					identical = false
					break
			if identical:
				return {"valid": false, "reason": "duplicate_normal_constraint"}
		rows.append(row)
		targets.append(constraint["target"])
	var count := rows.size()
	var gram: Array[PackedFloat64Array] = []
	for i in count:
		var gram_row := PackedFloat64Array()
		gram_row.resize(count)
		for j in count:
			var value := 0.0
			for term in 9:
				value += rows[i][term] * rows[j][term]
			gram_row[j] = value
		gram.append(gram_row)
	var gram_condition_inf := _gram_condition_inf(gram)
	if not is_finite(gram_condition_inf) or gram_condition_inf > MAX_GRAM_CONDITION_INF:
		return {"valid": false, "reason": "ill_conditioned_tensor_constraints",
			"gram_condition_inf": gram_condition_inf,
			"maximum_gram_condition_inf": MAX_GRAM_CONDITION_INF}
	var lambda_by_channel: Array[PackedFloat64Array] = []
	for channel in 3:
		var residual := PackedFloat64Array()
		residual.resize(count)
		for i in count:
			var predicted := 0.0
			for term in 9:
				predicted += rows[i][term] * base[term][channel]
			residual[i] = targets[i][channel] - predicted
		var solved := _solve_dense(gram, residual)
		if solved.is_empty():
			return {"valid": false, "reason": "rank_deficient_constraints"}
		lambda_by_channel.append(solved)
	var fitted: Array[Vector3] = []
	for term in 9:
		var value: Vector3 = base[term]
		for channel in 3:
			var delta := 0.0
			for i in count:
				delta += rows[i][term] * lambda_by_channel[channel][i]
			value[channel] += delta
		fitted.append(value)
	var scale := 1.0
	var max_error := 0.0
	for i in count:
		scale = maxf(scale, _max_abs(targets[i]))
		var got := _tensor_response(fitted, constraints[i]["normal"])
		max_error = maxf(max_error, _max_abs(got - targets[i]))
	if not is_finite(max_error) or max_error > maxf(0.0001,
			FIT_RESIDUAL_RELATIVE_TOLERANCE * scale):
		return {"valid": false, "reason": "constraint_residual",
			"max_abs_error": max_error, "scale": scale}
	return {"valid": true, "tensor": fitted, "max_abs_error": max_error,
		"scale": scale, "constraint_count": count,
		"gram_condition_inf": gram_condition_inf}


static func _gram_condition_inf(matrix: Array[PackedFloat64Array]) -> float:
	var count := matrix.size()
	if count == 0:
		return 1.0
	var matrix_norm := 0.0
	for row in matrix:
		var row_sum := 0.0
		for value in row:
			row_sum += absf(value)
		matrix_norm = maxf(matrix_norm, row_sum)
	var inverse_rows: Array[PackedFloat64Array] = []
	for _row in count:
		var inverse_row := PackedFloat64Array()
		inverse_row.resize(count)
		inverse_rows.append(inverse_row)
	for column in count:
		var rhs := PackedFloat64Array()
		rhs.resize(count)
		rhs[column] = 1.0
		var solved := _solve_dense(matrix, rhs)
		if solved.size() != count:
			return INF
		for row in count:
			inverse_rows[row][column] = solved[row]
	var inverse_norm := 0.0
	for row in inverse_rows:
		var row_sum := 0.0
		for value in row:
			row_sum += absf(value)
		inverse_norm = maxf(inverse_norm, row_sum)
	return matrix_norm * inverse_norm


static func _solve_dense(matrix: Array[PackedFloat64Array],
		right_hand_side: PackedFloat64Array) -> PackedFloat64Array:
	var count := right_hand_side.size()
	var augmented: Array[PackedFloat64Array] = []
	for row in count:
		var values := PackedFloat64Array()
		values.resize(count + 1)
		for column in count:
			values[column] = matrix[row][column]
		values[count] = right_hand_side[row]
		augmented.append(values)
	for column in count:
		var pivot := column
		for row in range(column + 1, count):
			if absf(augmented[row][column]) > absf(augmented[pivot][column]):
				pivot = row
		if absf(augmented[pivot][column]) <= 1e-10:
			return PackedFloat64Array()
		var swap := augmented[column]
		augmented[column] = augmented[pivot]
		augmented[pivot] = swap
		var divisor := augmented[column][column]
		for index in range(column, count + 1):
			augmented[column][index] /= divisor
		for row in count:
			if row == column:
				continue
			var factor := augmented[row][column]
			if factor == 0.0:
				continue
			for index in range(column, count + 1):
				augmented[row][index] -= factor * augmented[column][index]
	var result := PackedFloat64Array()
	result.resize(count)
	for row in count:
		result[row] = augmented[row][count]
	return result


static func _tensor_basis(normal: Vector3) -> PackedFloat64Array:
	var n := normal.normalized()
	return PackedFloat64Array([n.x * n.x, n.y * n.y, n.z * n.z,
		n.x, n.y, n.z, n.x * n.y, n.y * n.z, n.x * n.z])


static func _sh_to_tensor(coefficients: PackedFloat32Array) -> Array[Vector3]:
	var c: Array[Vector3] = []
	for coefficient in 9:
		var base := coefficient * 3
		c.append(Vector3(coefficients[base], coefficients[base + 1], coefficients[base + 2]))
	return [
		c[0] * SH_Y00 - c[6] * SH_Z2_TERM + c[8] * SH_X2Y2_TERM,
		c[0] * SH_Y00 - c[6] * SH_Z2_TERM - c[8] * SH_X2Y2_TERM,
		c[0] * SH_Y00 + c[6] * (2.0 * SH_Z2_TERM),
		c[3] * SH_L1_KERNEL,
		c[1] * SH_L1_KERNEL,
		c[2] * SH_L1_KERNEL,
		c[4] * SH_L2_KERNEL,
		c[5] * SH_L2_KERNEL,
		c[7] * SH_L2_KERNEL,
	]


static func _zero_tensor() -> Array[Vector3]:
	var values: Array[Vector3] = []
	for _term in 9:
		values.append(Vector3.ZERO)
	return values


static func _tensor_response(tensor: Array, normal: Vector3) -> Vector3:
	if tensor.size() != 9:
		return Vector3.ZERO
	var n := normal.normalized()
	var weights := PackedFloat64Array([n.x * n.x, n.y * n.y, n.z * n.z,
		n.x, n.y, n.z, n.x * n.y, n.y * n.z, n.x * n.z])
	var result := Vector3.ZERO
	for term in 9:
		result += tensor[term] * weights[term]
	return result


static func _tensor_is_finite(tensor: Array) -> bool:
	if tensor.size() != 9:
		return false
	for value in tensor:
		if not value is Vector3 or not _finite_vector3(value):
			return false
	return true


static func _flatten_tensor(tensor: Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(27)
	for term in 9:
		var value: Vector3 = tensor[term]
		result[term * 3] = value.x
		result[term * 3 + 1] = value.y
		result[term * 3 + 2] = value.z
	return result


static func _records_equal(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.size() != b.size():
		return false
	for index in a.size():
		var tolerance := 1e-5 * maxf(1.0, maxf(absf(a[index]), absf(b[index])))
		if absf(a[index] - b[index]) > tolerance:
			return false
	return true


static func _query_cache_key(point: Vector3, step: float, tag: String) -> String:
	return "%s|%.5f|%.5f|%.5f|%.6f" % [tag, point.x, point.y, point.z, step]


static func _make_provenance(volume: Node3D, data: Data,
		placement: Placement, solids: Array[Dictionary]) -> Dictionary:
	var placement_scene_signature := int(data.scene_signature) & 0xffffffff
	var source_data_path := String(data.resource_path)
	var scene_sha256 := _scene_file_sha256(volume)
	var source_sha256 := _sha256_bytes(data.baked_indirect_sh.to_byte_array())
	var trace_sha256 := _sha256_bytes(data.visibility_triangles.to_byte_array())
	var geometry_triangles_sha256 := _sha256_bytes(placement.faces.to_byte_array())
	if source_sha256.is_empty() or trace_sha256.is_empty() \
			or geometry_triangles_sha256.is_empty():
		return {}
	var path_by_id := _collect_scene_paths(volume)
	var component_signatures: Array[Dictionary] = []
	for solid in solids:
		var raw_faces: PackedVector3Array = solid["faces"]
		var face_sha := _sha256_bytes(raw_faces.to_byte_array())
		if face_sha.is_empty():
			return {}
		component_signatures.append({
			"path": String(path_by_id.get(int(solid["instance_id"]), "")),
			"face_sha256": face_sha,
			"triangle_count": raw_faces.size() / 3,
		})
	component_signatures.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["path"]) < String(b["path"]))
	var geometry_document := {
		"schema": "MagicGI placement geometry signature v1",
		"placement_scene_signature_u32": placement_scene_signature,
		"geometry_triangles_sha256": geometry_triangles_sha256,
		"closed_components": component_signatures,
	}
	var geometry_bytes := JSON.stringify(geometry_document, "", true, true).to_utf8_buffer()
	var geometry_signature := _sha256_bytes(geometry_bytes)
	if geometry_signature.is_empty():
		return {}
	var spacing := float(data.spacing)
	var level_steps := PackedFloat32Array([spacing, spacing * 2.0, spacing * 4.0])
	var provenance := {
		"schema_version": SCHEMA_VERSION,
		"algorithm": ALGORITHM,
		"layout_version": LAYOUT_VERSION,
		"placement_scene_signature_u32": placement_scene_signature,
		"source_sh_revision": int(data.baked_indirect_sh_revision),
		"source_sh_sha256": source_sha256,
		"base_spacing_m": spacing,
		"level_count": LEVEL_COUNT,
		"level_steps_m": level_steps,
		"phase_cells": PackedInt32Array([0, 0, 0]),
		"scene_sha256": scene_sha256,
		"source_data_path": source_data_path,
		"geometry_signature": geometry_signature,
		"geometry_triangles_sha256": geometry_triangles_sha256,
		"trace_geometry_sha256": trace_sha256,
	}
	return provenance


static func _input_signature(provenance: Dictionary) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update("MagicGI boundary tensor build input v1".to_utf8_buffer())
	for key in ["algorithm", "scene_sha256", "source_sh_sha256", "source_data_path",
			"geometry_signature", "geometry_triangles_sha256", "trace_geometry_sha256"]:
		var bytes := String(provenance.get(key, "")).to_utf8_buffer()
		context.update(PackedInt32Array([bytes.size()]).to_byte_array())
		if not bytes.is_empty():
			context.update(bytes)
	context.update(PackedInt32Array([
		int(provenance["schema_version"]), int(provenance["layout_version"]),
		int(provenance["source_sh_revision"]), int(provenance["placement_scene_signature_u32"]),
		int(provenance["level_count"])]).to_byte_array())
	var floats := PackedFloat32Array([float(provenance["base_spacing_m"])] )
	floats.append_array(provenance["level_steps_m"])
	context.update(floats.to_byte_array())
	context.update(provenance["phase_cells"].to_byte_array())
	return context.finish().hex_encode()


static func _scene_file_sha256(volume: Node) -> String:
	var root := SceneTracker.scene_root(volume)
	var path := String(root.scene_file_path)
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	return _sha256_bytes(FileAccess.get_file_as_bytes(path))


static func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(bytes)
	return context.finish().hex_encode()


static func _add_rejection(stats: Dictionary, reason: String) -> void:
	var rejections: Dictionary = stats["rejections"]
	rejections[reason] = int(rejections.get(reason, 0)) + 1


static func _tangent_axes(axis: int) -> Vector2i:
	match axis:
		0: return Vector2i(1, 2)
		1: return Vector2i(0, 2)
		_: return Vector2i(0, 1)


static func _dominant_axis(normal: Vector3) -> int:
	var axis := 0
	if absf(normal.y) > absf(normal.x):
		axis = 1
	if absf(normal.z) > absf(normal[axis]):
		axis = 2
	return axis


static func _finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _max_abs(value: Vector3) -> float:
	return maxf(absf(value.x), maxf(absf(value.y), absf(value.z)))
