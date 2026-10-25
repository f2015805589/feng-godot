@tool
extends RefCounted
## Bake-time CLV preparation. All geometry queries run here, never in a pixel
## shader or in a lighting update. The fitted values are linear transfer
## operators, so changing the sun, sky, or an emitter still relights the field.

const Boundary = preload("feng_magic_gi_boundary_tensor_builder.gd")
const Data = preload("feng_magic_gi_data.gd")
const DirectionalBaker = preload("feng_magic_gi_directional_baker.gd")
const DirectionalData = preload("feng_magic_gi_directional_data.gd")
const LEVELS := 4
const REVISION := 4
const SUPPORT_RADIUS := 0.65
const MAX_NEIGHBORS := 12
const OUTPUT_SCHEMA_VERSION := 2
const OUTPUT_COEFFICIENTS := 4 # SH2 is L0 + L1: four coefficients per RGB channel.
const RANK_RELATIVE_THRESHOLD := 0.001
const SURFACE_SAMPLE_OFFSET_M := 0.008
const SURFACE_TARGET_CACHE_LIMIT := 4096
const SURFACE_QUADRATURE_OFFSET := 0.2886751346 # Two-point Gauss rule over one cell.

var _source: Resource
var _geometry: RefCounted
var _columns := 0
var _output_coefficients := OUTPUT_COEFFICIENTS
var _matrix_cache: Dictionary = {}
var _solids: Array[Dictionary] = []
var _prepared := PackedFloat32Array()
var _validity := PackedByteArray()
var _dimensions := PackedInt32Array()
var _offsets := PackedInt32Array()
var _stats: Dictionary = {}
var _support_radius := SUPPORT_RADIUS
var _surface_coordinates: Array[PackedFloat64Array] = []
var _surface_coordinates_by_count: Dictionary = {}
var _surface_target_cache: Dictionary = {}
var _surface_target_cache_order: Array[String] = []
var _preparation_error := ""

func prepare_async(source: Resource, geometry: RefCounted,
		cancelled := Callable(), progress := Callable(),
		surface_coordinates: Array[PackedFloat64Array] = [],
		surface_target_cache: Dictionary = {}) -> Dictionary:
	if source == null or geometry == null or not source.is_source_data_valid() or not geometry.bvh_ready:
		return {"ok": false, "error": "invalid_clv_transfer_preparation_input"}
	_source = source
	if not _surface_coordinates_are_valid(source, surface_coordinates):
		return {"ok": false, "error": "surface_constraint_sampling_coordinates_missing_or_invalid"}
	_surface_coordinates = surface_coordinates
	_surface_coordinates_by_count.clear()
	_surface_target_cache = surface_target_cache
	_initialize_surface_target_cache_order()
	_preparation_error = ""
	_output_coefficients = OUTPUT_COEFFICIENTS
	_support_radius = SUPPORT_RADIUS
	_geometry = geometry
	_columns = _output_coefficients * 4 + source.emitter_count * 6
	_matrix_cache.clear()
	_solids.clear()
	_prepared.clear()
	_validity.clear()
	_dimensions.clear()
	_offsets.clear()
	_stats = {"cells": 0, "supported": 0, "boundary_cells": 0,
		"constraints": 0, "constraint_candidates": 0, "rank_dropped_constraints": 0,
		"rank_selected_constraints": 0, "visibility_rays": 0, "maximum_fit_error": 0.0,
		"maximum_operator_row_l1": 0.0, "surface_target_constraints": 0,
		"surface_target_cache_hits": 0, "surface_direct_probes": 0,
		"surface_direct_samples": 0,
		"surface_direct_bake_usec": 0}
	for record in geometry.get("_occlusion_volumes"):
		var solid := {"faces": record.faces, "bounds": record.world_aabb, "bvh": record.bvh}
		var pairs: Array[Dictionary] = Boundary._build_axis_face_pairs(solid)
		solid["box"] = Boundary._is_full_axis_aligned_box(solid, pairs)
		_solids.append(solid)
	var total := 0
	for level in LEVELS:
		var stride := 1 << level
		var dims := Vector3i((Vector3(source.dimensions) / float(stride)).ceil())
		_offsets.append(total)
		_dimensions.append_array(PackedInt32Array([dims.x, dims.y, dims.z]))
		total += dims.x * dims.y * dims.z
	_prepared.resize(total * _output_coefficients * _columns)
	_prepared.fill(0.0)
	_validity.resize(total)
	_validity.fill(0)
	var tree := Engine.get_main_loop() as SceneTree
	var last_yielded_surface_probe_count := 0
	if progress.is_valid():
		progress.call("Preinterpolating CLV transfer", 0, total, 0, LEVELS)
	var completed := 0
	for level in LEVELS:
		var stride := 1 << level
		var step: float = source.spacing_m * stride
		var dims := Vector3i(_dimensions[level * 3], _dimensions[level * 3 + 1], _dimensions[level * 3 + 2])
		for z in dims.z:
			for y in dims.y:
				for x in dims.x:
					if cancelled.is_valid() and bool(cancelled.call()):
						return {"ok": false, "error": "cancelled"}
					var source_cell := Vector3i(x, y, z) * stride
					var world: Vector3 = source.origin_world + Vector3(source_cell) * source.spacing_m
					var destination := _offsets[level] + (z * dims.y + y) * dims.x + x
					_prepare_cell(world, step, source.cell_index(source_cell), destination)
					if not _preparation_error.is_empty():
						return {"ok": false, "error": _preparation_error, "stats": _stats.duplicate(true)}
					completed += 1
					if int(_stats.surface_direct_probes) - last_yielded_surface_probe_count >= 4 \
							and tree != null:
						last_yielded_surface_probe_count = int(_stats.surface_direct_probes)
						await tree.process_frame
					if completed % 128 == 0:
						if progress.is_valid():
							progress.call("Preinterpolating CLV transfer", completed, total, level + 1, LEVELS)
						if tree != null:
							await tree.process_frame
	_source.clv_preparation_revision = REVISION
	_source.clv_preparation_schema_version = OUTPUT_SCHEMA_VERSION
	_source.clv_prepared_dimensions = _dimensions
	_source.clv_prepared_offsets = _offsets
	_source.clv_prepared_validity = _validity
	_source.clv_prepared_operators = _prepared
	_source.clv_preparation_signature = source.directional_source_signature
	_source.clv_preparation_stats = _stats.duplicate(true)
	_matrix_cache.clear()
	return {"ok": source.has_preinterpolated_clv(), "stats": _stats}

## Prepare one bounded region of an independently traced LOD. Global page
## ownership and halo copies are established by the paged baker; no whole-world
## source array or fixed four-level Chunk is created here.
func prepare_region_async(source: Resource, geometry: RefCounted,
		first_cell: Vector3i, dimensions: Vector3i,
		cancelled := Callable(), progress := Callable(),
		surface_coordinates: Array[PackedFloat64Array] = [],
		surface_target_cache: Dictionary = {}, source_level := -1) -> Dictionary:
	if source == null or geometry == null or not source.is_source_data_valid() or not geometry.bvh_ready:
		return {"ok": false, "error": "invalid_multires_prepare_source"}
	for axis in 3:
		if first_cell[axis] < 0 or dimensions[axis] <= 0 \
				or first_cell[axis] + dimensions[axis] > source.dimensions[axis]:
			return {"ok": false, "error": "multires_prepare_region_out_of_bounds"}
	if source_level < 0 or source_level >= 10 \
			or absf(source.spacing_m - 0.25 * float(1 << source_level)) > 0.000001:
		return {"ok": false, "error": "multires_prepare_level_spacing_mismatch"}
	_source = source
	if not _surface_coordinates_are_valid(source, surface_coordinates):
		return {"ok": false, "error": "surface_constraint_sampling_coordinates_missing_or_invalid"}
	_surface_coordinates = surface_coordinates
	_surface_coordinates_by_count.clear()
	_surface_target_cache = surface_target_cache
	_initialize_surface_target_cache_order()
	_preparation_error = ""
	_geometry = geometry
	_output_coefficients = OUTPUT_COEFFICIENTS
	_columns = _output_coefficients * 4 + source.emitter_count * 6
	_support_radius = SUPPORT_RADIUS * source.spacing_m / 0.25
	_matrix_cache.clear()
	_solids.clear()
	_stats = {"cells": 0, "supported": 0, "boundary_cells": 0,
		"constraints": 0, "constraint_candidates": 0, "rank_dropped_constraints": 0,
		"rank_selected_constraints": 0, "visibility_rays": 0, "maximum_fit_error": 0.0,
		"maximum_operator_row_l1": 0.0, "surface_target_constraints": 0,
		"surface_target_cache_hits": 0, "surface_direct_probes": 0,
		"surface_direct_samples": 0,
		"surface_direct_bake_usec": 0}
	for record in geometry.get("_occlusion_volumes"):
		var solid := {"faces": record.faces, "bounds": record.world_aabb, "bvh": record.bvh}
		solid["box"] = Boundary._is_full_axis_aligned_box(solid, Boundary._build_axis_face_pairs(solid))
		_solids.append(solid)
	var total := dimensions.x * dimensions.y * dimensions.z
	var stride := _output_coefficients * _columns
	_prepared.resize(total * stride)
	_prepared.fill(0.0)
	_validity.resize(total)
	_validity.fill(0)
	var tree := Engine.get_main_loop() as SceneTree
	for z in dimensions.z:
		for y in dimensions.y:
			for x in dimensions.x:
				if cancelled.is_valid() and bool(cancelled.call()): return {"ok": false, "error": "cancelled"}
				var source_cell := first_cell + Vector3i(x, y, z)
				var destination := (z * dimensions.y + y) * dimensions.x + x
				_prepare_cell(source.origin_world + Vector3(source_cell) * source.spacing_m,
						source.spacing_m, source.cell_index(source_cell), destination)
				if not _preparation_error.is_empty():
					return {"ok": false, "error": _preparation_error, "stats": _stats.duplicate(true)}
				if destination % 128 == 0 and tree != null:
					if progress.is_valid(): progress.call("Preparing paged CLV transfer", destination, total, 0, 0)
					await tree.process_frame
	_matrix_cache.clear()
	return {"ok": true, "operators": _prepared, "validity": _validity,
		"operator_schema_version": OUTPUT_SCHEMA_VERSION, "stats": _stats.duplicate(true)}

func _prepare_cell(world: Vector3, step: float, source_index: int, destination: int) -> void:
	_stats.cells += 1
	var selected := _collect_constraints(world, step)
	var base := PackedFloat32Array()
	if _source.cell_is_valid(source_index):
		base = _source_matrix(source_index).duplicate()
	elif not selected.is_empty():
		base = selected[0].matrix.duplicate()
	else:
		return
	if not selected.is_empty():
		_stats.boundary_cells += 1
		_stats.constraints += selected.size()
		# Every level must estimate the same receiver transport. Mixing directly
		# integrated fine targets with truncated probe estimates at coarse levels
		# darkens walls in the clipmap's blend band, even with a stationary camera.
		for constraint in selected:
			var target: Dictionary = _bake_surface_footprint_target(constraint, step)
			if not bool(target.get("ok", false)):
				_preparation_error = "direct_surface_target_failed: " + str(target.get("error", "invalid_result"))
				return
			constraint["surface_target"] = target.columns
			_stats.surface_target_constraints += 1
		_fit(base, selected)
	for value in base:
		if not is_finite(value):
			return
	for row in _output_coefficients:
		var row_l1 := 0.0
		for column in _columns:
			row_l1 += absf(base[row * _columns + column])
		_stats.maximum_operator_row_l1 = maxf(_stats.maximum_operator_row_l1, row_l1)
	var start := destination * _output_coefficients * _columns
	for scalar in base.size():
		_prepared[start + scalar] = base[scalar]
	_validity[destination] = 1
	_stats.supported += 1

func _collect_constraints(world: Vector3, step: float) -> Array[Dictionary]:
	var constraints: Array[Dictionary] = []
	var radius := step * 1.5
	for solid in _solids:
		var bounds: AABB = solid.bounds
		if Boundary._point_aabb_distance_squared(world, bounds) > radius * radius:
			continue
		if bool(solid.box):
			for axis in 3:
				for sign_value in [-1.0, 1.0]:
					var point := world
					var normal := Vector3.ZERO
					normal[axis] = sign_value
					point[axis] = bounds.position[axis] if sign_value < 0.0 else bounds.end[axis]
					for tangent in 3:
						if tangent != axis:
							var margin := minf(0.02, bounds.size[tangent] * 0.1)
							point[tangent] = clampf(point[tangent], bounds.position[tangent] + margin, bounds.end[tangent] - margin)
					_add_constraint(constraints, world, point, normal, radius, bounds)
		else:
			var nearest: Dictionary = Boundary._nearest_triangle(world, solid.faces, step)
			if not nearest.is_empty():
				_add_constraint(constraints, world, nearest.point, nearest.normal, radius)
	constraints.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance < b.distance)
	var unique_constraints: Array[Dictionary] = []
	for constraint in constraints:
		var duplicate := false
		for prior in unique_constraints:
			if constraint.normal.dot(prior.normal) > 0.98:
				duplicate = true
				break
		if not duplicate and unique_constraints.size() < 8:
			unique_constraints.append(constraint)
	var constraint_bases: Array[PackedFloat64Array] = []
	for constraint in unique_constraints:
		constraint_bases.append(constraint.basis)
	var selected_indices := rank_independent_constraint_indices(constraint_bases,
			_output_coefficients, RANK_RELATIVE_THRESHOLD)
	var selected: Array[Dictionary] = []
	for index in selected_indices:
		selected.append(unique_constraints[index])
	_stats.constraint_candidates += unique_constraints.size()
	_stats.rank_selected_constraints += selected.size()
	_stats.rank_dropped_constraints += unique_constraints.size() - selected.size()
	return selected

## Keep the nearest constraint rows that add independent rank in the compact
## L0+L1 output space. Inputs are already sorted by surface distance, so the
## first valid surface wins; selection does not assume any world-axis normal.
static func rank_independent_constraint_indices(bases: Array[PackedFloat64Array],
		maximum := OUTPUT_COEFFICIENTS, relative_threshold := RANK_RELATIVE_THRESHOLD) -> PackedInt32Array:
	var result := PackedInt32Array()
	if maximum <= 0 or relative_threshold < 0.0: return result
	var orthonormal: Array[PackedFloat64Array] = []
	for index in bases.size():
		if result.size() >= maximum: break
		var basis := bases[index]
		if basis.size() < OUTPUT_COEFFICIENTS: continue
		var residual := PackedFloat64Array()
		residual.resize(OUTPUT_COEFFICIENTS)
		var original_length_squared := 0.0
		var finite := true
		for coefficient in OUTPUT_COEFFICIENTS:
			residual[coefficient] = basis[coefficient]
			finite = finite and is_finite(residual[coefficient])
			original_length_squared += residual[coefficient] * residual[coefficient]
		if not finite or original_length_squared <= 0.000000000001: continue
		for prior in orthonormal:
			var projection := 0.0
			for coefficient in OUTPUT_COEFFICIENTS:
				projection += residual[coefficient] * prior[coefficient]
			for coefficient in OUTPUT_COEFFICIENTS:
				residual[coefficient] -= projection * prior[coefficient]
		var residual_length_squared := 0.0
		for coefficient in OUTPUT_COEFFICIENTS:
			residual_length_squared += residual[coefficient] * residual[coefficient]
		var original_length := sqrt(original_length_squared)
		if sqrt(residual_length_squared) <= original_length * relative_threshold: continue
		var residual_length := sqrt(residual_length_squared)
		for coefficient in OUTPUT_COEFFICIENTS:
			residual[coefficient] /= residual_length
		orthonormal.append(residual)
		result.append(index)
	return result

func _add_constraint(constraints: Array[Dictionary], world: Vector3,
		point: Vector3, normal: Vector3, radius: float, face_bounds := AABB()) -> void:
	var distance := world.distance_to(point)
	if distance > radius or normal.length_squared() < 0.5:
		return
	var query := point + normal * 0.008
	if _geometry.point_is_inside_or_ambiguous_solid(query):
		# At a wall/ceiling intersection the closest point on one box can be
		# buried inside the other. Find an exposed point ON THE SAME FACE; using
		# an exterior probe as a replacement would reintroduce corner light leaks.
		if face_bounds.size == Vector3.ZERO: return
		var found := false
		var original := point
		for ring in range(1, 7):
			var shift := float(ring) * 0.025
			var best_distance := INF
			for axis in 3:
				if absf(normal[axis]) > 0.5: continue
				for sign_value in [-1.0, 1.0]:
					var candidate := original
					candidate[axis] += sign_value * shift
					if not face_bounds.grow(0.00001).has_point(candidate): continue
					var distance_to_node := world.distance_to(candidate)
					if distance_to_node > radius or distance_to_node >= best_distance: continue
					if _geometry.point_is_inside_or_ambiguous_solid(candidate + normal * 0.008): continue
					point = candidate
					best_distance = distance_to_node
					found = true
			if found: break
		if not found: return
		query = point + normal * 0.008
		distance = world.distance_to(point)
	var gathered := _gather(query, point, normal)
	if gathered.is_empty():
		return
	constraints.append({"normal": normal, "distance": distance,
		"basis": _irradiance_basis(normal), "matrix": gathered,
		"surface_point": point, "face_bounds": face_bounds})

func _bake_surface_footprint_target(constraint: Dictionary, step: float) -> Dictionary:
	var point: Vector3 = constraint.surface_point
	var normal: Vector3 = constraint.normal
	if _source.bake_samples < 4:
		return _bake_direct_surface_target(point, normal)
	var tangent := normal.cross(Vector3.UP if absf(normal.y) < 0.99 else Vector3.RIGHT).normalized()
	var bitangent := normal.cross(tangent)
	var points: Array[Vector3] = []
	var bounds: AABB = constraint.face_bounds
	var center_query := point + normal * SURFACE_SAMPLE_OFFSET_M
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			var sample_point: Vector3 = point + (tangent * x + bitangent * y) * (step * SURFACE_QUADRATURE_OFFSET)
			if bounds.size != Vector3.ZERO:
				for axis in 3:
					if absf(normal[axis]) < 0.5:
						var margin := minf(0.0001, bounds.size[axis] * 0.1)
						sample_point[axis] = clampf(sample_point[axis], bounds.position[axis] + margin, bounds.end[axis] - margin)
			var query := sample_point + normal * SURFACE_SAMPLE_OFFSET_M
			if _geometry.point_is_inside_or_ambiguous_solid(query): continue
			# Keep the footprint on the same connected receiver surface. Never
			# borrow a sample across a wall or from the other side of a thin slab.
			if not _geometry.bvh.intersect_segment(center_query, query).is_empty(): continue
			var hit: Dictionary = _geometry.trace_path(query, -normal, SURFACE_SAMPLE_OFFSET_M * 2.0)
			if hit.is_empty() or hit.position.distance_to(sample_point) > 0.001 \
					or hit.normal.dot(normal) < 0.98: continue
			points.append(sample_point)
	if points.is_empty(): return _bake_direct_surface_target(point, normal)
	# Integrate the finite footprint represented by a CLV texel rather than
	# aliasing a sub-cell cavity into a whole trilinear patch. Split the existing
	# ray budget; this changes neither runtime sampling nor total traced paths.
	var columns := PackedFloat64Array()
	columns.resize(_columns)
	var samples_per_point: int = _source.bake_samples / points.size()
	var remainder: int = _source.bake_samples % points.size()
	for index in points.size():
		var rays := samples_per_point + (1 if index < remainder else 0)
		var result := _bake_direct_surface_target(points[index], normal, rays, index)
		if not bool(result.get("ok", false)): return result
		for column in _columns:
			columns[column] += result.columns[column] / float(points.size())
	return {"ok": true, "columns": columns}

func _surface_coordinates_are_valid(source: Resource,
		coordinates: Array[PackedFloat64Array]) -> bool:
	if coordinates.size() != (int(source.bake_bounces) + 1) * 2:
		return false
	for coordinate in coordinates:
		if coordinate.size() < int(source.bake_samples):
			return false
	return true

func _initialize_surface_target_cache_order() -> void:
	_surface_target_cache_order.clear()
	for key in _surface_target_cache.keys():
		_surface_target_cache_order.append(String(key))
	while _surface_target_cache_order.size() > SURFACE_TARGET_CACHE_LIMIT:
		_surface_target_cache.erase(_surface_target_cache_order.pop_front())

func _surface_sampling_coordinates(sample_count: int) -> Array[PackedFloat64Array]:
	if sample_count == _source.bake_samples: return _surface_coordinates
	if _surface_coordinates_by_count.has(sample_count): return _surface_coordinates_by_count[sample_count]
	var coordinates: Array[PackedFloat64Array] = _surface_coordinates.duplicate()
	# Hammersley's first dimension depends on N. Taking a prefix of the full
	# bake's sequence would cover only a fraction of the sphere after splitting.
	var first := PackedFloat64Array()
	first.resize(sample_count)
	for index in sample_count:
		first[index] = (float(index) + 0.5) / float(sample_count)
	coordinates[0] = first
	_surface_coordinates_by_count[sample_count] = coordinates
	return coordinates

func _bake_direct_surface_target(point: Vector3, normal: Vector3, sample_count := 0,
		sampling_stratum := 0) -> Dictionary:
	if sample_count <= 0: sample_count = _source.bake_samples
	var key := _surface_target_key(point, normal)
	if sample_count != _source.bake_samples: key += "|rays:%d" % sample_count
	key += "|stratum:%d" % sampling_stratum
	if _surface_target_cache.has(key):
		_stats.surface_target_cache_hits += 1
		return {"ok": true, "columns": _surface_target_cache[key], "cached": true}
	if _surface_coordinates.is_empty() \
			or _source.emitter_count != _geometry.emitters.groups.size() \
			or _source.emitter_ids != _geometry.emitters.keys:
		return {"ok": false, "error": "sampling_coordinates_or_emitter_layout_mismatch"}
	var output := Data.new()
	output.positions = PackedVector3Array([point + normal * SURFACE_SAMPLE_OFFSET_M])
	output.normals = PackedVector3Array([normal])
	output.stable_probe_ids = PackedInt64Array([hash(key)])
	output.bake_samples = sample_count
	output.bake_bounces = _source.bake_bounces
	output.bake_distance = _source.trace_distance_m
	output.emitter_keys = _source.emitter_ids
	output.transfer.resize(27)
	output.primary_sky_visibility.resize(9)
	output.emitter_transport.resize(_source.emitter_count * 6)
	output.bake_exact_directional_secondary.resize(27)
	output.bake_exact_directional_secondary.fill(0.0)
	output.bake_exact_directional_secondary_valid = false
	output.directional = DirectionalData.new()
	output.directional.allocate(1, _source.emitter_count)
	var rng := RandomNumberGenerator.new()
	# Common random numbers keep neighboring receivers spatially correlated.
	# Independent per-position scrambles turn integration variance into visible
	# grid mottling even on a smooth, uniformly oriented wall.
	var scramble_key := [Data.SAMPLER_REVISION, _source.directional_source_signature, normal, sampling_stratum]
	rng.seed = int(hash(scramble_key))
	var shifts := PackedFloat32Array()
	shifts.resize((_source.bake_bounces + 1) * 2)
	for index in shifts.size():
		shifts[index] = rng.randf()
	var emitter_shifts := PackedFloat32Array()
	emitter_shifts.resize((_source.bake_bounces + 1) * _source.emitter_count * 3)
	for emitter in _source.emitter_count:
		var emitter_rng := RandomNumberGenerator.new()
		emitter_rng.seed = int(hash([scramble_key,
			_source.emitter_ids[emitter], "emission"]))
		for dimension in (_source.bake_bounces + 1) * 3:
			emitter_shifts[emitter * (_source.bake_bounces + 1) * 3 + dimension] = emitter_rng.randf()
	var started_usec := Time.get_ticks_usec()
	DirectionalBaker.bake_probe(output, _geometry, 0, sample_count,
		_source.bake_bounces, _source.trace_distance_m, _surface_sampling_coordinates(sample_count),
		shifts, emitter_shifts, [])
	_stats.surface_direct_bake_usec += Time.get_ticks_usec() - started_usec
	_stats.surface_direct_probes += 1
	_stats.surface_direct_samples += sample_count
	if not output.bake_exact_directional_secondary_valid:
		return {"ok": false, "error": "surface_estimator_returned_invalid_transport"}
	var columns := PackedFloat64Array()
	columns.resize(_columns)
	columns.fill(0.0)
	for incoming in OUTPUT_COEFFICIENTS:
		for channel in 3:
			columns[incoming * 3 + channel] = output.transfer[incoming * 3 + channel]
		columns[12 + incoming] = output.primary_sky_visibility[incoming] / PI
	for column in mini(_source.emitter_count * 6, output.emitter_transport.size()):
		columns[16 + column] = output.emitter_transport[column]
	_surface_target_cache[key] = columns
	_surface_target_cache_order.append(key)
	while _surface_target_cache_order.size() > SURFACE_TARGET_CACHE_LIMIT:
		_surface_target_cache.erase(_surface_target_cache_order.pop_front())
	return {"ok": true, "columns": columns, "cached": false}

func _surface_target_key(point: Vector3, normal: Vector3) -> String:
	var unit_normal := normal.normalized()
	return "%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s" % [
		_source.directional_source_signature,
		roundi(point.x * 10000.0), roundi(point.y * 10000.0), roundi(point.z * 10000.0),
		roundi(unit_normal.x * 10000.0), roundi(unit_normal.y * 10000.0), roundi(unit_normal.z * 10000.0),
		_source.bake_samples, _source.bake_bounces, roundi(_source.trace_distance_m * 10000.0),
		Data.SAMPLER_REVISION, str(_source.emitter_ids)]

func _gather(query: Vector3, surface: Vector3, normal: Vector3) -> PackedFloat32Array:
	var grid: Vector3 = (query - _source.origin_world) / _source.spacing_m
	var minimum := Vector3i((grid - Vector3.ONE * (_support_radius / _source.spacing_m)).floor()).max(Vector3i.ZERO)
	var maximum := Vector3i((grid + Vector3.ONE * (_support_radius / _source.spacing_m)).ceil()).min(_source.dimensions - Vector3i.ONE)
	var candidates: Array[Dictionary] = []
	for z in range(minimum.z, maximum.z + 1):
		for y in range(minimum.y, maximum.y + 1):
			for x in range(minimum.x, maximum.x + 1):
				var index: int = _source.cell_index(Vector3i(x, y, z))
				if not _source.cell_is_valid(index):
					continue
				var position: Vector3 = _source.cell_position(index)
				if normal.dot(position - surface) < 0.002:
					continue
				var distance := query.distance_to(position)
				if distance < _support_radius:
					candidates.append({"index": index, "position": position, "distance": distance})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance < b.distance)
	var values := PackedFloat32Array()
	values.resize(_output_coefficients * _columns)
	values.fill(0.0)
	var weight_sum := 0.0
	var neighbors := 0
	for candidate in candidates:
		_stats.visibility_rays += 1
		if not _geometry.bvh.intersect_segment(query, candidate.position).is_empty():
			continue
		var t: float = candidate.distance / _support_radius
		var weight := pow(1.0 - t, 4.0) * (1.0 + 4.0 * t)
		var matrix := _source_matrix(int(candidate.index))
		for scalar in values.size():
			values[scalar] += matrix[scalar] * weight
		weight_sum += weight
		neighbors += 1
		if neighbors >= MAX_NEIGHBORS:
			break
	if weight_sum <= 0.000001:
		return PackedFloat32Array()
	for scalar in values.size():
		values[scalar] /= weight_sum
	return values

func _source_matrix(index: int) -> PackedFloat32Array:
	if _matrix_cache.has(index):
		return _matrix_cache[index]
	var values := PackedFloat32Array()
	values.resize(_output_coefficients * _columns)
	var storage_index: int = _source.storage_index(index)
	if storage_index < 0 or storage_index >= _source.storage_probe_count():
		return values
	for outgoing in _output_coefficients:
		var row := outgoing * _columns
		for incoming in _output_coefficients:
			for channel in 3:
				var source_column := incoming * 3 + channel
				values[row + source_column] = _source.transfer[storage_index * 243 + outgoing * 27 + source_column]
		for incoming in _output_coefficients:
			values[row + _output_coefficients * 3 + incoming] = _source.sky[storage_index * 81 + outgoing * 9 + incoming]
		for emitter in _source.emitter_count:
			for channel in 6:
				values[row + _output_coefficients * 4 + emitter * 6 + channel] = _source.emission[(emitter * _source.storage_probe_count() + storage_index) * 54 + outgoing * 6 + channel]
	_matrix_cache[index] = values
	return values

static func _irradiance_basis(n: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([0.2820947918, 0.3257350079 * n.y,
		0.3257350079 * n.z, 0.3257350079 * n.x])

func _fit(base: PackedFloat32Array, constraints: Array[Dictionary]) -> void:
	var count := constraints.size()
	var inverse: Array[PackedFloat64Array] = []
	for i in count:
		var row := PackedFloat64Array()
		row.resize(count * 2)
		for j in count:
			for k in _output_coefficients:
				row[j] += constraints[i].basis[k] * constraints[j].basis[k]
		row[i] += 0.00001
		row[count + i] = 1.0
		inverse.append(row)
	for pivot in count:
		var best := pivot
		for row in range(pivot + 1, count):
			if absf(inverse[row][pivot]) > absf(inverse[best][pivot]): best = row
		if absf(inverse[best][pivot]) < 0.0000001: return
		var swap := inverse[pivot]
		inverse[pivot] = inverse[best]
		inverse[best] = swap
		var scale := inverse[pivot][pivot]
		for column in count * 2: inverse[pivot][column] /= scale
		for row in count:
			if row == pivot: continue
			var factor := inverse[row][pivot]
			for column in count * 2: inverse[row][column] -= factor * inverse[pivot][column]
	var projection: Array[PackedFloat64Array] = []
	for k in _output_coefficients:
		var row := PackedFloat64Array()
		row.resize(count)
		for j in count:
			for i in count: row[j] += constraints[i].basis[k] * inverse[i][count + j]
		projection.append(row)
	for column in _columns:
		var residual := PackedFloat64Array()
		residual.resize(count)
		for i in count:
			var predicted := 0.0
			for k in _output_coefficients:
				predicted += constraints[i].basis[k] * base[k * _columns + column]
			residual[i] = float(constraints[i].surface_target[column]) - predicted
		for k in _output_coefficients:
			var delta := 0.0
			for i in count: delta += projection[k][i] * residual[i]
			base[k * _columns + column] += delta
		for i in count:
			var error := 0.0
			for k in _output_coefficients:
				error += constraints[i].basis[k] * base[k * _columns + column]
			error -= float(constraints[i].surface_target[column])
			_stats.maximum_fit_error = maxf(float(_stats.maximum_fit_error), absf(error))
