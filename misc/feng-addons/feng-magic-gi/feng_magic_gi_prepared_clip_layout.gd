@tool
extends RefCounted
## Shared, allocation-light layout contract for CPU page selection and the GPU
## resident cache. A view rotation never changes the selected lattice windows.

const MAX_LEVELS := 10
const TENSOR_FIELDS := 7
const GUARANTEED_TEXTURE_DEPTH := 2048
const LegacyLayout = preload("feng_magic_gi_volume_clipmap.gd")

static func build(header: Resource, camera_world: Vector3, resolution := 16,
		radius_m := 512.0, previous_state: Dictionary = {}) -> Dictionary:
	if header == null or not header.has_method("is_header_valid") or not header.is_header_valid() \
			or not camera_world.is_finite() or resolution not in [16, 24, 32] \
			or not is_finite(radius_m) or radius_m <= 0.0:
		return {"valid": false, "error": "invalid_paged_clv_layout_input"}
	var base_spacing := float(header.get("spacing_m"))
	var source_origin: Vector3 = header.get("origin_world")
	var bounds: AABB = header.get("domain_bounds_world")
	var available_levels := int(header.get("prepared_level_count"))
	if not is_finite(base_spacing) or absf(base_spacing - 0.25) > 0.000001 \
			or not source_origin.is_finite() or available_levels < 1 or available_levels > MAX_LEVELS:
		return {"valid": false, "error": "invalid_paged_clv_source_geometry"}
	# Reserve a half-cell for quantized center error plus a cell for the asymmetric
	# last sample and edge blend. R16 therefore needs 10 levels for radius 512;
	# R24/R32 need 9, with depth 1512/2016 rather than an invalid R32*10*7=2240.
	var required_levels := levels_for_radius(resolution, base_spacing, radius_m)
	var texture_levels := mini(MAX_LEVELS, GUARANTEED_TEXTURE_DEPTH / (resolution * TENSOR_FIELDS))
	var level_count := mini(available_levels, mini(required_levels, texture_levels))
	var anchor := camera_world
	# Preserve the existing small-room fit, where the camera may stand outside
	# the entire authored source. Large worlds always center their windows on the
	# camera; aiming toward a distant domain center would abandon nearby cells.
	if available_levels <= 4 and bounds.size.max_axis_index() >= 0 \
			and bounds.size[bounds.size.max_axis_index()] <= resolution * base_spacing * 4.0:
		anchor = _small_domain_anchor(bounds, camera_world, resolution, base_spacing)
	var source_key := [header.get_instance_id(), source_origin, base_spacing,
		bounds, available_levels, resolution, level_count]
	var same_source: bool = previous_state.get("source_key", []) == source_key
	var old_lods: Array = previous_state.get("lods", []) if same_source else []
	var lods: Array[Dictionary] = []
	var next_lods: Array[Dictionary] = []
	for level in level_count:
		var stride := 1 << level
		var old: Dictionary = old_lods[level] if level < old_lods.size() else {}
		var previous_center: Vector3i = old.get("center_source_index", Vector3i.ZERO)
		var center := Vector3i.ZERO
		for axis in 3:
			center[axis] = LegacyLayout._snap_source_index(anchor[axis], source_origin[axis],
				base_spacing, stride, previous_center[axis], not old.is_empty())
		var logical_origin := center - Vector3i.ONE * (resolution / 2) * stride
		var spacing := base_spacing * stride
		var origin := source_origin + Vector3(logical_origin) * base_spacing
		var cells := Vector3i(resolution, resolution, resolution)
		var entry := {"lod": level, "level": level, "resolution": resolution,
			"origin_world": origin, "spacing_m": spacing, "stride": stride,
			"cell_origin": logical_origin / stride, "dimensions": cells,
			"logical_origin_source_index": logical_origin,
			"center_source_index": center,
			"clip_bounds_world": AABB(origin, Vector3.ONE * (resolution - 1) * spacing),
			"source_bounds_world": bounds}
		lods.append(entry)
		next_lods.append({"center_source_index": center,
			"logical_origin_source_index": logical_origin})
	return {"valid": true, "error": "", "lods": lods, "level_count": level_count,
		"resident_lod_count": level_count, "required_level_count": required_levels,
		"source_level_count": available_levels, "resolution": resolution,
		"anchor_world": anchor, "camera_world": camera_world, "radius_m": radius_m,
		"dimensions": Vector3i(resolution, resolution, resolution * level_count),
		"resident_capacity": resolution * resolution * resolution * level_count,
		"state": {"source_key": source_key, "lods": next_lods}}

static func levels_for_radius(resolution: int, base_spacing: float, radius_m: float) -> int:
	var guaranteed_half_width := (float(resolution) * 0.5 - 1.5) * base_spacing
	var levels := 1
	while levels < MAX_LEVELS and guaranteed_half_width < radius_m:
		guaranteed_half_width *= 2.0
		levels += 1
	return levels

static func intersects_sphere(bounds: AABB, center: Vector3, radius_m: float) -> bool:
	var closest := center.clamp(bounds.position, bounds.end)
	return closest.distance_squared_to(center) <= radius_m * radius_m

static func _small_domain_anchor(bounds: AABB, camera: Vector3,
		resolution: int, spacing: float) -> Vector3:
	var toward := bounds.get_center() - camera
	if toward.length_squared() <= 1e-12:
		return bounds.get_center()
	var direction := toward.normalized()
	var enter := -INF
	var leave := INF
	for axis in 3:
		if absf(direction[axis]) <= 1e-7:
			continue
		var a := (bounds.position[axis] - camera[axis]) / direction[axis]
		var b := (bounds.end[axis] - camera[axis]) / direction[axis]
		enter = maxf(enter, minf(a, b))
		leave = minf(leave, maxf(a, b))
	var half_depth := 0.5 * resolution * spacing \
		* (absf(direction.x) + absf(direction.y) + absf(direction.z))
	return camera + direction * maxf(maxf(enter, 0.0), leave - half_depth)
