@tool
extends RefCounted
## Bounded camera-relative clipmaps. World-cell tags make scrolling and partial
## lighting refreshes safe: consumers reject stale cells rather than reuse light.

const U = preload("../rd/uniforms.gd")
const FillShader: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_fill.glsl")
const RESOLUTION := 16
const LEVELS := 3
const MAX_JOBS := 512
var texture := RID()
var tags := RID()
var parameters := RID()
var sampler := RID()
var _jobs := RID()
var _shader := RID()
var _pipeline := RID()
var _origins: Array[Vector3i] = []
var _pending: Array[Vector4i] = []
var _pending_set: Dictionary = {}
var _cursor := 0
var _refresh_epoch := -1
var _spacing := 0.0

func create(rd: RenderingDevice) -> bool:
	texture = _texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, 19)
	tags = _texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT, 1)
	parameters = rd.uniform_buffer_create(80)
	_jobs = rd.storage_buffer_create(MAX_JOBS * 16)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler = rd.sampler_create(state)
	_shader = rd.shader_create_from_spirv(FillShader.get_spirv(), "Magic GI CLV Fill")
	if _shader.is_valid():
		_pipeline = rd.compute_pipeline_create(_shader)
	for rid in owned_rids():
		if not rid.is_valid():
			return false
	rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return true

func update(rd: RenderingDevice, camera: Vector3, base_spacing: float, epoch: int,
		bake: Dictionary, directional: RefCounted, ubo: RID, nearest_sampler: RID,
		budget := 256) -> bool:
	queue_updates(camera, base_spacing, epoch)
	var selected := take_jobs(clampi(budget, 1, MAX_JOBS))
	var bytes := PackedByteArray()
	for cell in selected:
		bytes.append_array(PackedInt32Array([cell.x, cell.y, cell.z, cell.w]).to_byte_array())
	if not bytes.is_empty():
		rd.buffer_update(_jobs, 0, bytes.size(), bytes)
		var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [
			U.sampled(0, nearest_sampler, bake.geometry), U.sampled(1, nearest_sampler, bake.indices),
			U.storage_buffer(2, bake.visibility_nodes), U.storage_buffer(3, bake.visibility_triangles),
			U.storage_buffer(4, directional.lighting), U.storage_buffer(5, _jobs),
			U.image(6, texture), U.image(7, tags), U.uniform_buffer(8, ubo),
			U.storage_buffer(9, bake.index_entries)])
		if not uniforms.is_valid():
			# Requeue the failed dispatch; unpublished tags still reject those cells.
			for cell in selected:
				_enqueue(cell)
			return false
		var push := PackedInt32Array([selected.size(), RESOLUTION, epoch]).to_byte_array()
		push.append_array(PackedFloat32Array([base_spacing]).to_byte_array())
		rd.draw_command_begin_label("Magic GI CLV Fill", Color(0.3, 0.7, 0.9))
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline)
		rd.compute_list_bind_uniform_set(list, uniforms, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, (selected.size() + 63) / 64, 1, 1)
		rd.compute_list_end()
		rd.draw_command_end_label()
	var constants := PackedByteArray()
	for origin in _origins:
		constants.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	constants.append_array(PackedFloat32Array([base_spacing, 0, 0, 0]).to_byte_array())
	constants.append_array(PackedInt32Array([RESOLUTION, LEVELS, epoch, 1]).to_byte_array())
	return rd.buffer_update(parameters, 0, constants.size(), constants) == OK

## Scheduler is pure CPU state, also used by scrolling/epoch tests without a GPU.
func queue_updates(camera: Vector3, base_spacing: float, epoch: int) -> void:
	var reset := not is_equal_approx(_spacing, base_spacing) or _origins.is_empty()
	# Continuous light animation must not restart at the first fine slab forever.
	# Finish the current fair sweep, then refresh any cells from previous epochs.
	reset = reset or (_pending_set.is_empty() and epoch != _refresh_epoch)
	if reset:
		_pending.clear()
		_pending_set.clear()
		_cursor = 0
	if reset:
		_refresh_epoch = epoch
	_spacing = base_spacing
	for level in LEVELS:
		var step := base_spacing * float(1 << level)
		var origin := Vector3i((camera / step).floor()) - Vector3i.ONE * (RESOLUTION / 2)
		var previous := _origins[level] if level < _origins.size() else origin
		if level == _origins.size():
			_origins.append(origin)
			reset = true
		else:
			_origins[level] = origin
		if not reset and origin == previous:
			continue
		var end := origin + Vector3i.ONE * RESOLUTION
		var old_end := previous + Vector3i.ONE * RESOLUTION
		var overlap_min := origin.max(previous)
		var overlap_max := end.min(old_end)
		if reset or overlap_min.x >= overlap_max.x or overlap_min.y >= overlap_max.y or overlap_min.z >= overlap_max.z:
			_enqueue_box(origin, end, level)
		else:
			# Disjoint entering slabs: X uses full YZ; Y uses overlapping X;
			# Z uses overlapping XY. Work scales with changed cells, not 16 cubed.
			_enqueue_box(origin, Vector3i(overlap_min.x, end.y, end.z), level)
			_enqueue_box(Vector3i(overlap_max.x, origin.y, origin.z), end, level)
			_enqueue_box(Vector3i(overlap_min.x, origin.y, origin.z), Vector3i(overlap_max.x, overlap_min.y, end.z), level)
			_enqueue_box(Vector3i(overlap_min.x, overlap_max.y, origin.z), Vector3i(overlap_max.x, end.y, end.z), level)
			_enqueue_box(Vector3i(overlap_min.x, overlap_min.y, origin.z), Vector3i(overlap_max.x, overlap_max.y, overlap_min.z), level)
			_enqueue_box(Vector3i(overlap_min.x, overlap_min.y, overlap_max.z), Vector3i(overlap_max.x, overlap_max.y, end.z), level)
	# Old entering-slab jobs can accumulate under fast camera travel. Compact at a
	# fixed multiple of the total cache capacity, independent of session duration.
	if _pending.size() > RESOLUTION * RESOLUTION * RESOLUTION * LEVELS * 2:
		var retained: Array[Vector4i] = []
		for i in range(_cursor, _pending.size()):
			var cell := _pending[i]
			if _contains(_origins[cell.w], Vector3i(cell.x, cell.y, cell.z)):
				retained.append(cell)
		_pending = retained
		_pending_set.clear()
		for cell in _pending:
			_pending_set[cell] = true
		_cursor = 0

func take_jobs(budget: int) -> Array[Vector4i]:
	var selected: Array[Vector4i] = []
	while selected.size() < budget and _cursor < _pending.size():
		var cell := _pending[_cursor]
		_cursor += 1
		_pending_set.erase(cell)
		if _contains(_origins[cell.w], Vector3i(cell.x, cell.y, cell.z)):
			selected.append(cell)
	if _cursor == _pending.size():
		_pending.clear()
		_cursor = 0
	return selected

func _enqueue_box(lower: Vector3i, upper: Vector3i, level: int) -> void:
	for z in range(lower.z, upper.z):
		for y in range(lower.y, upper.y):
			for x in range(lower.x, upper.x):
				_enqueue(Vector4i(x, y, z, level))

func _enqueue(cell: Vector4i) -> void:
	if not _pending_set.has(cell):
		_pending_set[cell] = true
		_pending.append(cell)

static func _contains(origin: Vector3i, cell: Vector3i) -> bool:
	var d := cell - origin
	return d.x >= 0 and d.y >= 0 and d.z >= 0 and d.x < RESOLUTION and d.y < RESOLUTION and d.z < RESOLUTION

## Place the finest clipmap over useful baked geometry while retaining room for
## trilinear corners and the receiver-normal sampling offset. Small bounds are
## centered so the cache does not waste its footprint outside the source volume.
static func focus_for_bounds(camera: Vector3, bounds: AABB, spacing: float) -> Vector3:
	var safe_spacing := spacing if is_finite(spacing) and spacing > 0.0 else 0.001
	var half_span := float(RESOLUTION - 2.5) * safe_spacing * 0.5
	var focus := Vector3.ZERO
	for axis in 3:
		var bound_start := bounds.position[axis]
		var bound_end := bounds.position[axis] + bounds.size[axis]
		if not is_finite(bound_start) or not is_finite(bound_end):
			focus[axis] = camera[axis] if is_finite(camera[axis]) else 0.0
			continue
		var lower_bound := minf(bound_start, bound_end)
		var upper_bound := maxf(bound_start, bound_end)
		var lower := lower_bound + half_span
		var upper := upper_bound - half_span
		var center := (lower_bound + upper_bound) * 0.5
		if lower > upper or not is_finite(lower) or not is_finite(upper) \
				or not is_finite(camera[axis]):
			focus[axis] = center
		else:
			focus[axis] = clampf(camera[axis], lower, upper)
	return focus

func owned_rids() -> Array[RID]:
	return [texture, tags, parameters, sampler, _jobs, _pipeline, _shader]

static func _texture(rd: RenderingDevice, format_value: int, columns: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = format_value
	format.width = RESOLUTION * columns
	format.height = RESOLUTION
	format.depth = RESOLUTION * LEVELS
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return rd.texture_create(format, RDTextureView.new(), [])
