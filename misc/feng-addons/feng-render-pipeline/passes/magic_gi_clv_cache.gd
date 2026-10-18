@tool
extends RefCounted
## Bounded camera-relative clipmaps. A stable nonzero geometry token owns cell tags;
## lighting-content revisions only enqueue bounded refreshes and do not invalidate geometry.

const U = preload("../rd/uniforms.gd")
const FillShader: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_fill.glsl")
const CertifyShader: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_certify.glsl")
const RESOLUTION := 16
const LEVELS := 3
const MAX_JOBS := 512
const MAX_PAGE_EPOCHS := 256
const LAYOUT_VERSION := 8
const RADIANCE_COEFFICIENT_COLUMNS := 18
const CLV_FACE_COUNT := 3
const CLV_FACE_SLOT_COLUMNS := 22
const SURFACE_METADATA_COLUMN := 18
const SURFACE_ANCHOR_COLUMN := 19
const DIFFUSE_PROJECTION_COLUMN := 20
const CLV_TEXTURE_COLUMNS := CLV_FACE_COUNT * CLV_FACE_SLOT_COLUMNS
const TAG_COLUMNS := 1
const RGBA32_TEXEL_BYTES := 16
const PARAMETER_BUFFER_BYTES := 80
const JOB_RECORD_BYTES := 16
const FALLBACK_CLUSTER_BUFFER_BYTES := 16
const STENCIL_CAPACITY := 16
const STENCIL_WORDS := 4 + STENCIL_CAPACITY * 3
const STENCIL_BUFFER_BYTES := RESOLUTION * RESOLUTION * RESOLUTION * LEVELS * CLV_FACE_COUNT * STENCIL_WORDS * 4
var texture := RID()
var tags := RID()
var support := RID()
var parameters := RID()
var sampler := RID()
var _jobs := RID()
var _stencils := RID()
var _probe_cluster_fallback := RID()
var _shader := RID()
var _pipeline := RID()
var _certify_shader := RID()
var _certify_pipeline := RID()
var _origins: Array[Vector3i] = []
var _pending: Array[Vector4i] = []
var _pending_set: Dictionary = {}
var _cursor := 0
var _geometry_epoch := -1
var _content_revision := -1
var _spacing := 0.0
var _page_epochs: Dictionary = {}
var _page_epoch_clock := 0

func create(rd: RenderingDevice) -> bool:
	texture = _texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, CLV_TEXTURE_COLUMNS)
	tags = _texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT, TAG_COLUMNS)
	support = _texture(rd, RenderingDevice.DATA_FORMAT_R32_UINT, 1)
	parameters = rd.uniform_buffer_create(PARAMETER_BUFFER_BYTES)
	_jobs = rd.storage_buffer_create(MAX_JOBS * JOB_RECORD_BYTES)
	_stencils = rd.storage_buffer_create(STENCIL_BUFFER_BYTES)
	_probe_cluster_fallback = rd.storage_buffer_create(FALLBACK_CLUSTER_BUFFER_BYTES,
		PackedInt32Array([1, 0, 0, 0]).to_byte_array())
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler = rd.sampler_create(state)
	_shader = rd.shader_create_from_spirv(FillShader.get_spirv(), "Magic GI CLV Fill")
	if _shader.is_valid():
		_pipeline = rd.compute_pipeline_create(_shader)
	_certify_shader = rd.shader_create_from_spirv(CertifyShader.get_spirv(), "Magic GI CLV Support")
	if _certify_shader.is_valid():
		_certify_pipeline = rd.compute_pipeline_create(_certify_shader)
	for rid in owned_rids():
		if not rid.is_valid():
			return false
	rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(support, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return true

func update(rd: RenderingDevice, camera: Vector3, base_spacing: float,
		geometry_epoch: int, content_revision: int, bake: Dictionary,
		directional: RefCounted, ubo: RID, nearest_sampler: RID, budget := 256) -> bool:
	# Tags validate geometry/layout only. Keep valid lighting visible while a
	# content refresh advances fairly through the bounded queue.
	var geometry_changed := _origins.is_empty() or _geometry_epoch != geometry_epoch \
			or not is_equal_approx(_spacing, base_spacing)
	if geometry_changed and not _origins.is_empty() and tags.is_valid():
		rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1)
	queue_updates(camera, base_spacing, geometry_epoch)
	queue_content_refresh(content_revision)
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
			U.storage_buffer(9, bake.index_entries),
			U.storage_buffer(10, _cluster_buffer(bake)), U.image(11, support), U.storage_buffer(12, _stencils)])
		if not uniforms.is_valid():
			# Requeue the failed dispatch; unpublished tags still reject those cells.
			for cell in selected:
				_enqueue(cell)
			return false
		var push := PackedInt32Array([selected.size(), RESOLUTION, geometry_epoch]).to_byte_array()
		push.append_array(PackedFloat32Array([base_spacing]).to_byte_array())
		rd.draw_command_begin_label("Magic GI CLV Fill", Color(0.3, 0.7, 0.9))
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline)
		rd.compute_list_bind_uniform_set(list, uniforms, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, (selected.size() + 63) / 64, 1, 1)
		rd.compute_list_end()
		rd.draw_command_end_label()
		if not _certify_jobs(rd, selected.size(), push, bake):
			requeue_jobs(selected)
			return false
	var constants := PackedByteArray()
	for origin in _origins:
		constants.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	constants.append_array(PackedFloat32Array([base_spacing, 0, 0, 0]).to_byte_array())
	constants.append_array(PackedInt32Array([RESOLUTION, LEVELS, geometry_epoch, LAYOUT_VERSION]).to_byte_array())
	return rd.buffer_update(parameters, 0, constants.size(), constants) == OK

## Scheduler is pure CPU state, also used by scrolling/geometry-token tests without a GPU.
func queue_updates(camera: Vector3, base_spacing: float, geometry_epoch: int) -> void:
	var reset := not is_equal_approx(_spacing, base_spacing) or _origins.is_empty()
	# A geometry-token change means existing tags cannot describe this bake.
	# Lighting revisions use queue_content_refresh() and never restart this sweep.
	reset = reset or geometry_epoch != _geometry_epoch
	if reset:
		_pending.clear()
		_pending_set.clear()
		_cursor = 0
	if reset:
		_geometry_epoch = geometry_epoch
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


## Content changes enqueue another full fair sweep without invalidating tags or
## clearing pending work. Each selected batch uses the latest lighting buffers.
func queue_content_refresh(content_revision: int) -> int:
	if content_revision == _content_revision or _origins.size() != LEVELS:
		return 0
	_content_revision = content_revision
	var enqueued := 0
	for level in LEVELS:
		var origin := _origins[level]
		enqueued += _enqueue_box(origin, origin + Vector3i.ONE * RESOLUTION, level)
	return enqueued

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

## Refill only this page's cells when its geometry or lighting content changes.
## Only geometry_token is written to tags; content updates keep current valid
## coefficients visible while the bounded refresh queue catches up.
func queue_page_revision(page_key: String, core_bounds: AABB, base_spacing: float,
		geometry_token: int, content_revision := 0) -> int:
	if page_key.is_empty() or _origins.size() != LEVELS or core_bounds.size == Vector3.ZERO:
		return 0
	_page_epoch_clock += 1
	var existing: Dictionary = _page_epochs.get(page_key, {})
	var had_entry := existing.has("geometry_token")
	var geometry_changed := not had_entry \
			or int(existing.get("geometry_token", -1)) != geometry_token
	var content_changed := not had_entry \
			or int(existing.get("content_revision", -1)) != content_revision
	if not geometry_changed and not content_changed:
		existing["last_used"] = _page_epoch_clock
		_page_epochs[page_key] = existing
		return 0
	_page_epochs[page_key] = {"geometry_token": geometry_token,
		"content_revision": content_revision, "last_used": _page_epoch_clock}
	_trim_page_epochs(page_key)
	var enqueued := 0
	for level in LEVELS:
		var step := base_spacing * float(1 << level)
		var origin := _origins[level]
		var end := origin + Vector3i.ONE * RESOLUTION
		var core_end := core_bounds.position + core_bounds.size
		var lower := Vector3i(
			ceili(core_bounds.position.x / step - 0.5),
			ceili(core_bounds.position.y / step - 0.5),
			ceili(core_bounds.position.z / step - 0.5))
		var upper := Vector3i(
			ceili(core_end.x / step - 0.5),
			ceili(core_end.y / step - 0.5),
			ceili(core_end.z / step - 0.5))
		lower = lower.max(origin)
		upper = upper.min(end)
		if lower.x < upper.x and lower.y < upper.y and lower.z < upper.z:
			enqueued += _enqueue_box(lower, upper, level)
	return enqueued


func world_position(cell: Vector4i, base_spacing: float) -> Vector3:
	var step := base_spacing * float(1 << cell.w)
	return (Vector3(cell.x, cell.y, cell.z) + Vector3.ONE * 0.5) * step


func requeue_jobs(cells: Array[Vector4i]) -> void:
	for cell in cells:
		_enqueue(cell)


func dispatch_page_jobs(rd: RenderingDevice, selected: Array[Vector4i], base_spacing: float,
		geometry_token: int, bake: Dictionary, directional: RefCounted, ubo: RID,
		nearest_sampler: RID) -> bool:
	if selected.is_empty():
		return true
	var bytes := PackedByteArray()
	for cell in selected:
		bytes.append_array(PackedInt32Array([cell.x, cell.y, cell.z, cell.w]).to_byte_array())
	if rd.buffer_update(_jobs, 0, bytes.size(), bytes) != OK:
		requeue_jobs(selected)
		return false
	var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [
		U.sampled(0, nearest_sampler, bake.geometry), U.sampled(1, nearest_sampler, bake.indices),
		U.storage_buffer(2, bake.visibility_nodes), U.storage_buffer(3, bake.visibility_triangles),
		U.storage_buffer(4, directional.lighting), U.storage_buffer(5, _jobs),
		U.image(6, texture), U.image(7, tags), U.uniform_buffer(8, ubo),
		U.storage_buffer(9, bake.index_entries),
		U.storage_buffer(10, _cluster_buffer(bake)), U.image(11, support), U.storage_buffer(12, _stencils)])
	if not uniforms.is_valid():
		requeue_jobs(selected)
		return false
	var push := PackedInt32Array([selected.size(), RESOLUTION, geometry_token]).to_byte_array()
	push.append_array(PackedFloat32Array([base_spacing]).to_byte_array())
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (selected.size() + 63) / 64, 1, 1)
	rd.compute_list_end()
	if not _certify_jobs(rd, selected.size(), push, bake):
		requeue_jobs(selected)
		return false
	return true


func _certify_jobs(rd: RenderingDevice, job_count: int, push: PackedByteArray, bake: Dictionary) -> bool:
	var uniforms := UniformSetCacheRD.get_cache(_certify_shader, 0, [
		U.image(0, texture), U.image(1, tags), U.image(2, support), U.storage_buffer(3, _jobs),
		U.storage_buffer(4, bake.visibility_nodes), U.storage_buffer(5, bake.visibility_triangles)])
	if not uniforms.is_valid():
		return false
	rd.draw_command_begin_label("Magic GI CLV Support", Color(0.3, 0.7, 0.9))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _certify_pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (job_count * 8 + 63) / 64, 1, 1)
	rd.compute_list_end()
	rd.draw_command_end_label()
	return true


func update_parameters(rd: RenderingDevice, base_spacing: float, geometry_epoch: int) -> bool:
	var constants := PackedByteArray()
	for origin in _origins:
		constants.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	constants.append_array(PackedFloat32Array([base_spacing, 0, 0, 0]).to_byte_array())
	constants.append_array(PackedInt32Array([RESOLUTION, LEVELS, geometry_epoch, LAYOUT_VERSION]).to_byte_array())
	return rd.buffer_update(parameters, 0, constants.size(), constants) == OK


func set_expected_page_epoch(rd: RenderingDevice, geometry_token: int) -> bool:
	return rd.buffer_update(parameters, 72, 4, PackedInt32Array([geometry_token]).to_byte_array()) == OK


func retain_page_epochs(page_keys: PackedStringArray) -> void:
	var retained: Dictionary = {}
	for key in page_keys:
		retained[String(key)] = true
	for key in _page_epochs.keys():
		if not retained.has(key):
			_page_epochs.erase(key)


func _trim_page_epochs(protected_key: String) -> void:
	while _page_epochs.size() > MAX_PAGE_EPOCHS:
		var oldest_key := ""
		var oldest := 0x7fffffff
		for key in _page_epochs:
			if str(key) == protected_key:
				continue
			var last_used := int(_page_epochs[key].get("last_used", 0))
			if last_used < oldest:
				oldest = last_used
				oldest_key = str(key)
		if oldest_key.is_empty():
			break
		_page_epochs.erase(oldest_key)


static func estimate_gpu_bytes_breakdown() -> Dictionary:
	var coefficient_dimensions: Vector3i = _texture_dimensions(CLV_TEXTURE_COLUMNS)
	var tag_dimensions: Vector3i = _texture_dimensions(TAG_COLUMNS)
	var coefficient_texture_bytes: int = coefficient_dimensions.x * coefficient_dimensions.y \
			* coefficient_dimensions.z * RGBA32_TEXEL_BYTES
	var tag_texture_bytes: int = tag_dimensions.x * tag_dimensions.y \
			* tag_dimensions.z * RGBA32_TEXEL_BYTES
	var jobs_buffer_bytes: int = MAX_JOBS * JOB_RECORD_BYTES
	var support_texture_bytes := RESOLUTION * RESOLUTION * RESOLUTION * LEVELS * 4
	var total_bytes: int = coefficient_texture_bytes + tag_texture_bytes \
			+ support_texture_bytes + PARAMETER_BUFFER_BYTES + jobs_buffer_bytes + FALLBACK_CLUSTER_BUFFER_BYTES + STENCIL_BUFFER_BYTES
	return {
		"coefficient_texture_dimensions": coefficient_dimensions,
		"coefficient_texture_format": "R32G32B32A32_SFLOAT",
		"coefficient_texture_bytes": coefficient_texture_bytes,
		"face_count": CLV_FACE_COUNT,
		"face_slot_columns": CLV_FACE_SLOT_COLUMNS,
		"radiance_coefficient_columns_per_face": RADIANCE_COEFFICIENT_COLUMNS,
		"surface_metadata_column_per_face": SURFACE_METADATA_COLUMN,
		"surface_anchor_column_per_face": SURFACE_ANCHOR_COLUMN,
		"diffuse_projection_column_per_face": DIFFUSE_PROJECTION_COLUMN,
		"support_texture_bytes": support_texture_bytes,
		"stencil_buffer_bytes": STENCIL_BUFFER_BYTES,
		"tag_texture_dimensions": tag_dimensions,
		"tag_texture_format": "R32G32B32A32_SINT",
		"tag_texture_bytes": tag_texture_bytes,
		"parameter_buffer_bytes": PARAMETER_BUFFER_BYTES,
		"jobs_buffer_bytes": jobs_buffer_bytes,
		"fallback_cluster_buffer_bytes": FALLBACK_CLUSTER_BUFFER_BYTES,
		"size_bearing_rids": ["texture", "tags", "support", "parameters", "_jobs", "_stencils", "_probe_cluster_fallback"],
		# Driver-managed sampler/shader/pipeline objects have no byte-size query in RD.
		"opaque_driver_rids": ["sampler", "_shader", "_pipeline", "_certify_shader", "_certify_pipeline"],
		"total_bytes": total_bytes,
		"layout_version": LAYOUT_VERSION,
	}

static func estimate_gpu_bytes() -> int:
	return RESOLUTION * RESOLUTION * RESOLUTION * LEVELS * CLV_TEXTURE_COLUMNS * RGBA32_TEXEL_BYTES \
			+ RESOLUTION * RESOLUTION * RESOLUTION * LEVELS * TAG_COLUMNS * RGBA32_TEXEL_BYTES \
			+ RESOLUTION * RESOLUTION * RESOLUTION * LEVELS * 4 \
			+ PARAMETER_BUFFER_BYTES + MAX_JOBS * JOB_RECORD_BYTES \
			+ FALLBACK_CLUSTER_BUFFER_BYTES + STENCIL_BUFFER_BYTES

func _enqueue_box(lower: Vector3i, upper: Vector3i, level: int) -> int:
	var added := 0
	for z in range(lower.z, upper.z):
		for y in range(lower.y, upper.y):
			for x in range(lower.x, upper.x):
				if _enqueue(Vector4i(x, y, z, level)):
					added += 1
	return added

func _enqueue(cell: Vector4i) -> bool:
	if not _pending_set.has(cell):
		_pending_set[cell] = true
		_pending.append(cell)
		return true
	return false

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
	return [texture, tags, support, parameters, sampler, _jobs, _stencils, _probe_cluster_fallback,
		_pipeline, _shader, _certify_pipeline, _certify_shader]


func _cluster_buffer(bake: Dictionary) -> RID:
	var value: Variant = bake.get("probe_clusters", RID())
	if value is RID and value.is_valid():
		return value
	return _probe_cluster_fallback

static func _texture(rd: RenderingDevice, format_value: int, columns: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = format_value
	var dimensions: Vector3i = _texture_dimensions(columns)
	format.width = dimensions.x
	format.height = dimensions.y
	format.depth = dimensions.z
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	if format_value == RenderingDevice.DATA_FORMAT_R32_UINT:
		format.usage_bits |= RenderingDevice.TEXTURE_USAGE_STORAGE_ATOMIC_BIT
	return rd.texture_create(format, RDTextureView.new(), [])

static func _texture_dimensions(columns: int) -> Vector3i:
	return Vector3i(RESOLUTION * columns, RESOLUTION, RESOLUTION * LEVELS)
