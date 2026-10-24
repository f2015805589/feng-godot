@tool
extends RefCounted
## Bake-time CLV preparation. All geometry queries run here, never in a pixel
## shader or in a lighting update. The fitted values are linear transfer
## operators, so changing the sun, sky, or an emitter still relights the field.

const Boundary = preload("feng_magic_gi_boundary_tensor_builder.gd")
const LEVELS := 4
const REVISION := 1
const SUPPORT_RADIUS := 0.65
const MAX_NEIGHBORS := 12

var _source: Resource
var _geometry: RefCounted
var _columns := 0
var _matrix_cache: Dictionary = {}
var _solids: Array[Dictionary] = []
var _prepared := PackedFloat32Array()
var _validity := PackedByteArray()
var _dimensions := PackedInt32Array()
var _offsets := PackedInt32Array()
var _stats: Dictionary = {}
var _support_radius := SUPPORT_RADIUS

func prepare_async(source: Resource, geometry: RefCounted,
		cancelled := Callable(), progress := Callable()) -> Dictionary:
	if source != null and int(source.get("format_version")) == 2:
		return {"ok": false, "error": "packed_source_requires_original_dense_bake_for_repreparation"}
	if source == null or geometry == null or not source.is_valid() or not geometry.bvh_ready:
		return {"ok": false, "error": "invalid_clv_transfer_preparation_input"}
	_source = source
	_support_radius = SUPPORT_RADIUS
	_geometry = geometry
	_columns = 36 + source.emitter_count * 6
	_matrix_cache.clear()
	_solids.clear()
	_prepared.clear()
	_validity.clear()
	_dimensions.clear()
	_offsets.clear()
	_stats = {"cells": 0, "supported": 0, "boundary_cells": 0,
		"constraints": 0, "visibility_rays": 0, "maximum_fit_error": 0.0,
		"maximum_operator_row_l1": 0.0}
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
	_prepared.resize(total * 9 * _columns)
	_prepared.fill(0.0)
	_validity.resize(total)
	_validity.fill(0)
	var tree := Engine.get_main_loop() as SceneTree
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
					completed += 1
					if completed % 128 == 0:
						if progress.is_valid():
							progress.call("Preinterpolating CLV transfer", completed, total, level + 1, LEVELS)
						if tree != null:
							await tree.process_frame
	_source.clv_preparation_revision = REVISION
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
		cancelled := Callable(), progress := Callable()) -> Dictionary:
	if source == null or geometry == null or not source.is_valid() or not geometry.bvh_ready:
		return {"ok": false, "error": "invalid_multires_prepare_source"}
	for axis in 3:
		if first_cell[axis] < 0 or dimensions[axis] <= 0 \
				or first_cell[axis] + dimensions[axis] > source.dimensions[axis]:
			return {"ok": false, "error": "multires_prepare_region_out_of_bounds"}
	_source = source
	_geometry = geometry
	_columns = 36 + source.emitter_count * 6
	_support_radius = SUPPORT_RADIUS * source.spacing_m / 0.25
	_matrix_cache.clear()
	_solids.clear()
	_stats = {"cells": 0, "supported": 0, "boundary_cells": 0,
		"constraints": 0, "visibility_rays": 0, "maximum_fit_error": 0.0,
		"maximum_operator_row_l1": 0.0}
	for record in geometry.get("_occlusion_volumes"):
		var solid := {"faces": record.faces, "bounds": record.world_aabb, "bvh": record.bvh}
		solid["box"] = Boundary._is_full_axis_aligned_box(solid, Boundary._build_axis_face_pairs(solid))
		_solids.append(solid)
	var total := dimensions.x * dimensions.y * dimensions.z
	_prepared.resize(total * 9 * _columns)
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
				if destination % 128 == 0 and tree != null:
					if progress.is_valid(): progress.call("Preparing paged CLV transfer", destination, total, 0, 0)
					await tree.process_frame
	_matrix_cache.clear()
	return {"ok": true, "operators": _prepared, "validity": _validity, "stats": _stats.duplicate(true)}

func _prepare_cell(world: Vector3, step: float, source_index: int, destination: int) -> void:
	_stats.cells += 1
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
	var selected: Array[Dictionary] = []
	for constraint in constraints:
		var duplicate := false
		for prior in selected:
			if constraint.normal.dot(prior.normal) > 0.98:
				duplicate = true
				break
		if not duplicate and selected.size() < 8:
			selected.append(constraint)
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
		_fit(base, selected)
	for value in base:
		if not is_finite(value):
			return
	for row in 9:
		var row_l1 := 0.0
		for column in _columns:
			row_l1 += absf(base[row * _columns + column])
		_stats.maximum_operator_row_l1 = maxf(_stats.maximum_operator_row_l1, row_l1)
	var start := destination * 9 * _columns
	for scalar in base.size():
		_prepared[start + scalar] = base[scalar]
	_validity[destination] = 1
	_stats.supported += 1

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
		"basis": _irradiance_basis(normal), "matrix": gathered})

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
	values.resize(9 * _columns)
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
	values.resize(9 * _columns)
	for outgoing in 9:
		var row := outgoing * _columns
		for incoming_rgb in 27:
			values[row + incoming_rgb] = _source.transfer[index * 243 + outgoing * 27 + incoming_rgb]
		for incoming in 9:
			values[row + 27 + incoming] = _source.sky[index * 81 + outgoing * 9 + incoming]
		for emitter in _source.emitter_count:
			for channel in 6:
				values[row + 36 + emitter * 6 + channel] = _source.emission[(emitter * _source.probe_count + index) * 54 + outgoing * 6 + channel]
	_matrix_cache[index] = values
	return values

static func _irradiance_basis(n: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([0.2820947918, 0.3257350079 * n.y,
		0.3257350079 * n.z, 0.3257350079 * n.x, 0.2731371076 * n.x * n.y,
		0.2731371076 * n.y * n.z, 0.0788478913 * (3.0 * n.z * n.z - 1.0),
		0.2731371076 * n.x * n.z, 0.1365685538 * (n.x * n.x - n.y * n.y)])

func _fit(base: PackedFloat32Array, constraints: Array[Dictionary]) -> void:
	var count := constraints.size()
	var inverse: Array[PackedFloat64Array] = []
	for i in count:
		var row := PackedFloat64Array()
		row.resize(count * 2)
		for j in count:
			for k in 9:
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
	for k in 9:
		var row := PackedFloat64Array()
		row.resize(count)
		for j in count:
			for i in count: row[j] += constraints[i].basis[k] * inverse[i][count + j]
		projection.append(row)
	for column in _columns:
		var residual := PackedFloat64Array()
		residual.resize(count)
		for i in count:
			for k in 9:
				residual[i] += constraints[i].basis[k] * (constraints[i].matrix[k * _columns + column] - base[k * _columns + column])
		for k in 9:
			var delta := 0.0
			for i in count: delta += projection[k][i] * residual[i]
			base[k * _columns + column] += delta
		for i in count:
			var error := 0.0
			for k in 9:
				error += constraints[i].basis[k] * (base[k * _columns + column] - constraints[i].matrix[k * _columns + column])
			_stats.maximum_fit_error = maxf(float(_stats.maximum_fit_error), absf(error))
