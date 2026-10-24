@tool
extends RefCounted
## Bounded camera-relative CLV. A stable nonzero geometry token owns cell tags;
## dynamic PRT refreshes resident radiance independently from spatial fill jobs.

const U = preload("../rd/uniforms.gd")
const FillShader: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_fill.glsl")
const CertifyShader: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_certify.glsl")
const ResidentRelightShader: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_relight.glsl")
const DebugSummaryShader: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_readback.glsl")
const RESOLUTION := 16
const EXPANDED_RESOLUTION := 24
const LEVELS := 3
const MAX_JOBS := 512
const MAX_PAGE_EPOCHS := 256
const LAYOUT_VERSION := 9
const RADIANCE_COEFFICIENT_COLUMNS := 18
const CLV_FACE_COUNT := 3
const CLV_FACE_SLOT_COLUMNS := 24
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
const TRANSFER_MATRIX_COLUMNS := 81 # 324 float coefficients: RGB transport SH9xSH9 + sky SH9xSH9.
const EMISSION_MATRIX_COLUMNS_PER_SOURCE := 14 # 54 float values, padded to vec4 columns.
const DEBUG_SUMMARY_MAX_RECEIVERS := 4
const DEBUG_SUMMARY_LEVELS := 3
const DEBUG_SUMMARY_CORNERS := 8
const DEBUG_SUMMARY_RECORD_WORDS := 194
var texture := RID()
var tags := RID()
var support := RID()
var parameters := RID()
var sampler := RID()
var transfer_matrix := RID()
var _transfer_aggregate_scratch := RID()
var _emission_sources := RID()
var transfer_matrix_emitters := 0
var _jobs := RID()
var _stencils := RID()
var _probe_cluster_fallback := RID()
var _shader := RID()
var _pipeline := RID()
var _certify_shader := RID()
var _certify_pipeline := RID()
var _resident_relight_shader := RID()
var _resident_relight_pipeline := RID()
var _debug_summary_shader := RID()
var _debug_summary_pipeline := RID()
var _debug_summary_uniform_set := RID()
var _debug_summary_receivers := RID()
var _debug_summary_output := RID()
var _debug_summary_inflight := false
var _debug_summary_serial := 0
var _debug_summary_error := ""
var _origins: Array[Vector3i] = []
var _pending: Array[Vector4i] = []
var _pending_set: Dictionary = {}
var _cursor := 0
var _geometry_epoch := -1
var _content_revision := -1
var _spacing := 0.0
var _page_epochs: Dictionary = {}
var _page_epoch_clock := 0
var resolution := RESOLUTION
var parameter_resolution := -1
var dispatch_serial := 0
var last_dispatch_frame := -1
var last_dispatch_blocks := 0
var scheduled_and_dispatched := false
var relight_serial := 0
var last_relight_frame := -1
var last_relight_cells := 0
var last_relight_faces := 0
var relight_lighting_revision := -1
var relight_pending := false
var relight_scheduled_and_dispatched := false
var relight_error := ""

func create(rd: RenderingDevice, requested_resolution := RESOLUTION,
		dynamic_transfer := false, emitter_count := 0) -> bool:
	relight_error = ""
	if dynamic_transfer and requested_resolution not in [RESOLUTION, EXPANDED_RESOLUTION]:
		relight_error = "dynamic_clv_resolution_unsupported"
		return false
	if dynamic_transfer and emitter_count < 0:
		relight_error = "dynamic_clv_emitter_count_invalid"
		return false
	resolution = requested_resolution if dynamic_transfer else \
			(EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION else RESOLUTION)
	texture = _texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		CLV_TEXTURE_COLUMNS, resolution)
	tags = _texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT, TAG_COLUMNS, resolution)
	support = _texture(rd, RenderingDevice.DATA_FORMAT_R32_UINT, 1, resolution)
	parameters = rd.uniform_buffer_create(PARAMETER_BUFFER_BYTES)
	_jobs = rd.storage_buffer_create(MAX_JOBS * JOB_RECORD_BYTES)
	_stencils = rd.storage_buffer_create(_stencil_buffer_bytes(resolution))
	transfer_matrix_emitters = maxi(0, emitter_count) if dynamic_transfer else 0
	if dynamic_transfer:
		transfer_matrix = _transfer_texture(rd, resolution, transfer_matrix_emitters)
	var aggregate_scratch_bytes := _transfer_aggregate_scratch_bytes(
		transfer_matrix_emitters) if dynamic_transfer else 16
	var aggregate_scratch_seed := PackedByteArray()
	aggregate_scratch_seed.resize(aggregate_scratch_bytes)
	_transfer_aggregate_scratch = rd.storage_buffer_create(
		aggregate_scratch_bytes, aggregate_scratch_seed)
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
	if dynamic_transfer:
		_resident_relight_shader = rd.shader_create_from_spirv(ResidentRelightShader.get_spirv(),
				"Magic GI CLV Resident Relight")
		if _resident_relight_shader.is_valid():
			_resident_relight_pipeline = rd.compute_pipeline_create(_resident_relight_shader)
	var required_rids: Array[RID] = [texture, tags, support, parameters, _jobs,
		_stencils, _transfer_aggregate_scratch, _probe_cluster_fallback, sampler, _shader, _pipeline,
		_certify_shader, _certify_pipeline]
	if dynamic_transfer:
		required_rids.append(transfer_matrix)
		required_rids.append(_resident_relight_shader)
		required_rids.append(_resident_relight_pipeline)
	for rid in required_rids:
		if not rid.is_valid():
			return false
	rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(support, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return true

func update(rd: RenderingDevice, camera: Vector3, base_spacing: float,
		geometry_epoch: int, content_revision: int, bake: Dictionary,
		directional: RefCounted, ubo: RID, nearest_sampler: RID, budget := 256,
		approximate_volume_enabled := false,
		exact_corner_visibility_enabled := false,
		approximate_ready_bit_enabled := false,
		dynamic_transfer := false) -> bool:
	scheduled_and_dispatched = false
	# Tags validate geometry/layout only. Keep valid lighting visible while a
	# content refresh advances fairly through the bounded queue.
	var geometry_changed := _origins.is_empty() or _geometry_epoch != geometry_epoch \
			or not is_equal_approx(_spacing, base_spacing)
	if geometry_changed and not _origins.is_empty() and tags.is_valid():
		rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1)
	queue_updates(camera, base_spacing, geometry_epoch)
	if not dynamic_transfer:
		queue_content_refresh(content_revision)
	var direct_inputs: Dictionary = directional.get_clv_transfer_bindings() \
			if dynamic_transfer and directional != null \
			and directional.has_method("get_clv_transfer_bindings") else {}
	if dynamic_transfer and (not transfer_matrix.is_valid() \
			or not _valid_transfer_inputs(direct_inputs) \
			or int(direct_inputs.get("emitters", -1)) != transfer_matrix_emitters \
			or int(direct_inputs.get("probes", 0)) <= 0):
		return false
	if dynamic_transfer:
		_emission_sources = direct_inputs.get("sources", RID())
	var logical_probe_count := int(direct_inputs.get("probes", 0)) if dynamic_transfer else 0
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
			U.storage_buffer(10, _cluster_buffer(bake)), U.image(11, support), U.storage_buffer(12, _stencils),
			U.storage_buffer(13, direct_inputs.get("transfer", directional.lighting)),
			U.storage_buffer(14, direct_inputs.get("sky", directional.lighting)),
			U.storage_buffer(15, direct_inputs.get("emission", directional.lighting)),
			U.storage_buffer(16, direct_inputs.get("sources", directional.lighting)),
			U.image(17, transfer_matrix if dynamic_transfer else texture),
			U.storage_buffer(18, _transfer_aggregate_scratch)])
		if not uniforms.is_valid():
			# Requeue the failed dispatch; unpublished tags still reject those cells.
			for cell in selected:
				_enqueue(cell)
			return false
		var push := _fill_push_constants(selected.size(), geometry_epoch, base_spacing,
			dynamic_transfer, transfer_matrix_emitters, logical_probe_count)
		rd.draw_command_begin_label("Magic GI CLV Fill", Color(0.3, 0.7, 0.9))
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline)
		rd.compute_list_bind_uniform_set(list, uniforms, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		# Fill shader uses one 64-lane workgroup per cell; later certify dispatch is unchanged.
		rd.compute_list_dispatch(list, selected.size(), 1, 1)
		rd.compute_list_end()
		dispatch_serial += 1
		last_dispatch_frame = Engine.get_process_frames()
		last_dispatch_blocks = selected.size()
		scheduled_and_dispatched = true
		rd.draw_command_end_label()
		if not _certify_jobs(rd, selected.size(), push, bake):
			requeue_jobs(selected)
			return false
	var constants := PackedByteArray()
	for origin in _origins:
		constants.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	constants.append_array(PackedFloat32Array([base_spacing,
		1.0 if approximate_volume_enabled else 0.0,
		1.0 if exact_corner_visibility_enabled else 0.0,
		1.0 if approximate_ready_bit_enabled else 0.0]).to_byte_array())
	constants.append_array(PackedInt32Array([resolution, LEVELS, geometry_epoch, LAYOUT_VERSION]).to_byte_array())
	var succeeded := rd.buffer_update(parameters, 0, constants.size(), constants) == OK
	if succeeded:
		parameter_resolution = resolution
	return succeeded

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
		var origin := Vector3i((camera / step).floor()) - Vector3i.ONE * (resolution / 2)
		var previous := _origins[level] if level < _origins.size() else origin
		if level == _origins.size():
			_origins.append(origin)
			reset = true
		else:
			_origins[level] = origin
		if not reset and origin == previous:
			continue
		var end := origin + Vector3i.ONE * resolution
		var old_end := previous + Vector3i.ONE * resolution
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
	if _pending.size() > resolution * resolution * resolution * LEVELS * 2:
		var retained: Array[Vector4i] = []
		for i in range(_cursor, _pending.size()):
			var cell := _pending[i]
			if _contains(_origins[cell.w], Vector3i(cell.x, cell.y, cell.z), resolution):
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
		enqueued += _enqueue_box(origin, origin + Vector3i.ONE * resolution, level)
	return enqueued

func take_jobs(budget: int) -> Array[Vector4i]:
	var selected: Array[Vector4i] = []
	while selected.size() < budget and _cursor < _pending.size():
		var cell := _pending[_cursor]
		_cursor += 1
		_pending_set.erase(cell)
		if _contains(_origins[cell.w], Vector3i(cell.x, cell.y, cell.z), resolution):
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
		var end := origin + Vector3i.ONE * resolution
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
		U.storage_buffer(10, _cluster_buffer(bake)), U.image(11, support), U.storage_buffer(12, _stencils),
		U.storage_buffer(13, directional.lighting), U.storage_buffer(14, directional.lighting),
		U.storage_buffer(15, directional.lighting), U.storage_buffer(16, directional.lighting),
		U.image(17, texture), U.storage_buffer(18, _transfer_aggregate_scratch)])
	if not uniforms.is_valid():
		requeue_jobs(selected)
		return false
	var push := _fill_push_constants(selected.size(), geometry_token, base_spacing, false, 0, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, selected.size(), 1, 1)
	rd.compute_list_end()
	dispatch_serial += 1
	last_dispatch_frame = Engine.get_process_frames()
	last_dispatch_blocks = selected.size()
	scheduled_and_dispatched = true
	if not _certify_jobs(rd, selected.size(), push, bake):
		requeue_jobs(selected)
		return false
	return true


func _certify_jobs(rd: RenderingDevice, job_count: int, push: PackedByteArray, bake: Dictionary) -> bool:
	var uniforms := UniformSetCacheRD.get_cache(_certify_shader, 0, [
		U.image(0, texture), U.image(1, tags), U.image(2, support), U.storage_buffer(3, _jobs),
		U.storage_buffer(4, bake.visibility_nodes), U.storage_buffer(5, bake.visibility_triangles),
		U.storage_buffer(6, _stencils)])
	if not uniforms.is_valid():
		return false
	rd.draw_command_begin_label("Magic GI CLV Support", Color(0.3, 0.7, 0.9))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _certify_pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	# The fill shader appends dynamic-transfer fields after the shared 16-byte
	# job header. Certify only declares that header, so do not pass the full ABI.
	var certify_push := push.slice(0, 16)
	rd.compute_list_set_push_constant(list, certify_push, certify_push.size())
	rd.compute_list_dispatch(list, (job_count * 8 + 63) / 64, 1, 1)
	rd.compute_list_end()
	rd.draw_command_end_label()
	return true


func update_parameters(rd: RenderingDevice, base_spacing: float, geometry_epoch: int,
		approximate_volume_enabled := false,
		exact_corner_visibility_enabled := false,
		approximate_ready_bit_enabled := false) -> bool:
	var constants := PackedByteArray()
	for origin in _origins:
		constants.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	constants.append_array(PackedFloat32Array([base_spacing,
		1.0 if approximate_volume_enabled else 0.0,
		1.0 if exact_corner_visibility_enabled else 0.0,
		1.0 if approximate_ready_bit_enabled else 0.0]).to_byte_array())
	constants.append_array(PackedInt32Array([resolution, LEVELS, geometry_epoch, LAYOUT_VERSION]).to_byte_array())
	var succeeded := rd.buffer_update(parameters, 0, constants.size(), constants) == OK
	if succeeded:
		parameter_resolution = resolution
	return succeeded


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


static func estimate_gpu_bytes_breakdown(requested_resolution := RESOLUTION,
		dynamic_transfer := false, emitter_count := 0) -> Dictionary:
	var selected_resolution := EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION else RESOLUTION
	var coefficient_dimensions: Vector3i = _texture_dimensions(CLV_TEXTURE_COLUMNS, selected_resolution)
	var tag_dimensions: Vector3i = _texture_dimensions(TAG_COLUMNS, selected_resolution)
	var coefficient_texture_bytes: int = coefficient_dimensions.x * coefficient_dimensions.y \
			* coefficient_dimensions.z * RGBA32_TEXEL_BYTES
	var tag_texture_bytes: int = tag_dimensions.x * tag_dimensions.y \
			* tag_dimensions.z * RGBA32_TEXEL_BYTES
	var jobs_buffer_bytes: int = MAX_JOBS * JOB_RECORD_BYTES
	var support_texture_bytes := selected_resolution * selected_resolution * selected_resolution * LEVELS * 4
	var stencil_buffer_bytes := _stencil_buffer_bytes(selected_resolution)
	var transfer_matrix_bytes := estimate_dynamic_transfer_bytes(selected_resolution,
			emitter_count) if dynamic_transfer else 0
	# The fill shader always declares binding 18, including legacy/page fills,
	# where a 16-byte dummy buffer keeps the descriptor set complete.
	var transfer_aggregate_scratch_bytes := _transfer_aggregate_scratch_bytes(
			emitter_count) if dynamic_transfer else 16
	var size_bearing_rids := ["texture", "tags", "support", "parameters", "_jobs",
			"_stencils", "_transfer_aggregate_scratch", "_probe_cluster_fallback"]
	if dynamic_transfer:
		size_bearing_rids.append("transfer_matrix")
	var total_bytes: int = coefficient_texture_bytes + tag_texture_bytes \
			+ support_texture_bytes + PARAMETER_BUFFER_BYTES + jobs_buffer_bytes \
			+ FALLBACK_CLUSTER_BUFFER_BYTES + stencil_buffer_bytes + transfer_matrix_bytes \
			+ transfer_aggregate_scratch_bytes
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
		"stencil_buffer_bytes": stencil_buffer_bytes,
		"transfer_matrix_dimensions": _transfer_texture_dimensions(selected_resolution,
				emitter_count) if dynamic_transfer else Vector3i.ZERO,
		"transfer_matrix_format": "R32G32B32A32_SFLOAT",
		"transfer_matrix_bytes": transfer_matrix_bytes,
		"transfer_aggregate_scratch_bytes": transfer_aggregate_scratch_bytes,
		"dynamic_transfer_enabled": dynamic_transfer,
		"transfer_matrix_emitter_count": maxi(0, emitter_count) if dynamic_transfer else 0,
		"tag_texture_dimensions": tag_dimensions,
		"tag_texture_format": "R32G32B32A32_SINT",
		"tag_texture_bytes": tag_texture_bytes,
		"parameter_buffer_bytes": PARAMETER_BUFFER_BYTES,
		"jobs_buffer_bytes": jobs_buffer_bytes,
		"fallback_cluster_buffer_bytes": FALLBACK_CLUSTER_BUFFER_BYTES,
		"size_bearing_rids": size_bearing_rids,
		# Driver-managed sampler/shader/pipeline objects have no byte-size query in RD.
		"opaque_driver_rids": ["sampler", "_shader", "_pipeline", "_certify_shader",
				"_certify_pipeline", "_resident_relight_shader", "_resident_relight_pipeline"],
		"total_bytes": total_bytes,
		"layout_version": LAYOUT_VERSION,
		"resolution": selected_resolution,
	}

static func estimate_dynamic_transfer_bytes(requested_resolution := RESOLUTION,
		emitter_count := 0) -> int:
	var selected_resolution := EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION else RESOLUTION
	var columns := TRANSFER_MATRIX_COLUMNS + maxi(0, emitter_count) * EMISSION_MATRIX_COLUMNS_PER_SOURCE
	return columns * selected_resolution * selected_resolution \
			* selected_resolution * LEVELS * CLV_FACE_COUNT * RGBA32_TEXEL_BYTES

static func estimate_gpu_bytes(requested_resolution := RESOLUTION,
		dynamic_transfer := false, emitter_count := 0) -> int:
	var selected_resolution := EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION else RESOLUTION
	return selected_resolution * selected_resolution * selected_resolution * LEVELS * CLV_TEXTURE_COLUMNS * RGBA32_TEXEL_BYTES \
			+ selected_resolution * selected_resolution * selected_resolution * LEVELS * TAG_COLUMNS * RGBA32_TEXEL_BYTES \
			+ selected_resolution * selected_resolution * selected_resolution * LEVELS * 4 \
			+ PARAMETER_BUFFER_BYTES + MAX_JOBS * JOB_RECORD_BYTES \
			+ FALLBACK_CLUSTER_BUFFER_BYTES + _stencil_buffer_bytes(selected_resolution) \
			+ (estimate_dynamic_transfer_bytes(selected_resolution, emitter_count)
					if dynamic_transfer else 0) \
			+ (_transfer_aggregate_scratch_bytes(emitter_count) if dynamic_transfer else 16)

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

static func _contains(origin: Vector3i, cell: Vector3i, selected_resolution := RESOLUTION) -> bool:
	var d := cell - origin
	return d.x >= 0 and d.y >= 0 and d.z >= 0 \
			and d.x < selected_resolution and d.y < selected_resolution and d.z < selected_resolution

## Place the finest clipmap over useful baked geometry while retaining room for
## trilinear corners and the receiver-normal sampling offset. Small bounds are
## centered so the cache does not waste its footprint outside the source volume.
static func focus_for_bounds(camera: Vector3, bounds: AABB, spacing: float,
		requested_resolution := RESOLUTION) -> Vector3:
	var safe_spacing := spacing if is_finite(spacing) and spacing > 0.0 else 0.001
	var selected_resolution := EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION else RESOLUTION
	var half_span := float(selected_resolution - 2.5) * safe_spacing * 0.5
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
	return [texture, tags, support, parameters, sampler, transfer_matrix,
		_transfer_aggregate_scratch, _jobs, _stencils, _probe_cluster_fallback,
		_pipeline, _shader, _certify_pipeline, _certify_shader,
		_resident_relight_pipeline, _resident_relight_shader,
		_debug_summary_uniform_set, _debug_summary_pipeline, _debug_summary_shader,
		_debug_summary_receivers, _debug_summary_output]

## One-shot diagnostic snapshot of the active cache. Each receiver dictionary
## contains `name`, `world`, and `normal`; output is deferred to the main thread
## as `(PackedByteArray, token, metadata)`. The pass must call this on the cache
## selected from its current native-prepared view, never on a global cache scan.
func debug_summary_request(rd: RenderingDevice, receivers: Array[Dictionary],
		callback: Callable, token: int, context := {}) -> Error:
	if rd == null or not callback.is_valid() or receivers.is_empty() \
			or receivers.size() > DEBUG_SUMMARY_MAX_RECEIVERS:
		_debug_summary_error = "invalid_debug_summary_request"
		return ERR_INVALID_PARAMETER
	if _debug_summary_inflight:
		_debug_summary_error = "debug_summary_readback_inflight"
		return ERR_UNAVAILABLE
	if not transfer_matrix.is_valid() or not texture.is_valid() or not tags.is_valid() \
			or not support.is_valid() or not parameters.is_valid() or not _stencils.is_valid():
		_debug_summary_error = "debug_summary_cache_resource_invalid"
		return ERR_UNAVAILABLE
	if not _ensure_debug_summary_resources(rd):
		_debug_summary_error = "debug_summary_pipeline_or_buffer_invalid"
		return ERR_CANT_CREATE
	var receiver_bytes := PackedByteArray()
	var receiver_metadata: Array[Dictionary] = []
	for receiver_index in receivers.size():
		var receiver: Dictionary = receivers[receiver_index]
		var world_value: Variant = receiver.get("world", Vector3.ZERO)
		var normal_value: Variant = receiver.get("normal", Vector3.ZERO)
		if not world_value is Vector3 or not normal_value is Vector3:
			_debug_summary_error = "debug_summary_receiver_type_invalid"
			return ERR_INVALID_PARAMETER
		var world: Vector3 = world_value
		var normal: Vector3 = normal_value
		if not is_finite(world.x) or not is_finite(world.y) or not is_finite(world.z) \
				or not is_finite(normal.x) or not is_finite(normal.y) or not is_finite(normal.z) \
				or normal.length_squared() <= 1e-12:
			_debug_summary_error = "debug_summary_receiver_nonfinite_or_zero_normal"
			return ERR_INVALID_PARAMETER
		receiver_bytes.append_array(PackedFloat32Array([
			world.x, world.y, world.z, 0.0,
			normal.x, normal.y, normal.z, 0.0]).to_byte_array())
		receiver_metadata.append({
			"name": String(receiver.get("name", "receiver_%d" % receiver_index)),
			"world": world,
			"normal": normal,
		})
	var update_error := rd.buffer_update(_debug_summary_receivers, 0,
		receiver_bytes.size(), receiver_bytes)
	if update_error != OK:
		_debug_summary_error = "debug_summary_receiver_upload_failed_%d" % update_error
		return update_error
	var output_bytes := receivers.size() * DEBUG_SUMMARY_LEVELS * DEBUG_SUMMARY_CORNERS \
			* DEBUG_SUMMARY_RECORD_WORDS * 4
	var push := PackedInt32Array([receivers.size(), resolution,
		transfer_matrix_emitters, DEBUG_SUMMARY_RECORD_WORDS]).to_byte_array()
	rd.draw_command_begin_label("Magic GI CLV Diagnostic Snapshot", Color(0.7, 0.7, 0.25))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _debug_summary_pipeline)
	rd.compute_list_bind_uniform_set(list, _debug_summary_uniform_set, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, receivers.size() * DEBUG_SUMMARY_LEVELS, 1, 1)
	rd.compute_list_end()
	rd.draw_command_end_label()
	var metadata := {
		"snapshot_format_version": 1,
		"cache_layout_version": LAYOUT_VERSION,
		"record_words": DEBUG_SUMMARY_RECORD_WORDS,
		"record_count": receivers.size() * DEBUG_SUMMARY_LEVELS * DEBUG_SUMMARY_CORNERS,
		"record_bytes": DEBUG_SUMMARY_RECORD_WORDS * 4,
		"sample_count": receivers.size(),
		"levels": DEBUG_SUMMARY_LEVELS,
		"corners_per_level": DEBUG_SUMMARY_CORNERS,
		"axis_policy": "dominant_axis_for_receiver_normal",
		"field_offsets_words": {
			"header": 0,
			"base_cell": 5,
			"logical_corner": 9,
			"tag": 13,
			"support": 17,
			"stencil_header": 18,
			"transport_statistics": 22,
			"sky_statistics": 26,
			"emission_statistics": 30,
			"transport_first4": 34,
			"sky_first4": 38,
			"emission_first4": 42,
			"relit_sh_rgba18": 46,
			"diffuse_secondary_rgba": 118,
			"diffuse_primary_rgba": 122,
			"metadata_rgba": 126,
			"anchor_rgba": 130,
			"approx_geometry_rgba": 134,
			"approx_plane_moments_rgba": 138,
			"fraction_rgba": 142,
			"stencil_entries_probe_secondary_sky_bits": 146,
		},
		"resolution": resolution,
		"geometry_epoch": _geometry_epoch,
		"spacing": _spacing,
		"origins": _origins.duplicate(),
		"emitter_count": transfer_matrix_emitters,
		"relight_serial": relight_serial,
		"relight_lighting_revision": relight_lighting_revision,
		"receivers": receiver_metadata,
		"context": context.duplicate(true) if context is Dictionary else {},
	}
	var async_callback := Callable(self, "_finish_debug_summary_readback").bind(
		callback, token, metadata, output_bytes)
	_debug_summary_inflight = true
	_debug_summary_error = ""
	var readback_error := rd.buffer_get_data_async(_debug_summary_output,
		async_callback, 0, output_bytes)
	if readback_error != OK:
		_debug_summary_inflight = false
		_debug_summary_error = "debug_summary_async_readback_failed_%d" % readback_error
		return readback_error
	_debug_summary_serial += 1
	return OK

func get_debug_summary_state() -> Dictionary:
	return {
		"pending": _debug_summary_inflight,
		"serial": _debug_summary_serial,
		"error": _debug_summary_error,
		"has_pipeline": _debug_summary_pipeline.is_valid(),
		"has_buffers": _debug_summary_receivers.is_valid() and _debug_summary_output.is_valid(),
	}

func _ensure_debug_summary_resources(rd: RenderingDevice) -> bool:
	if _debug_summary_pipeline.is_valid() and _debug_summary_uniform_set.is_valid() \
			and _debug_summary_receivers.is_valid() and _debug_summary_output.is_valid():
		return true
	_debug_summary_shader = rd.shader_create_from_spirv(DebugSummaryShader.get_spirv(),
		"Magic GI CLV Diagnostic Snapshot")
	if not _debug_summary_shader.is_valid():
		return false
	_debug_summary_pipeline = rd.compute_pipeline_create(_debug_summary_shader)
	if not _debug_summary_pipeline.is_valid():
		return false
	var receiver_zeros := PackedByteArray()
	receiver_zeros.resize(DEBUG_SUMMARY_MAX_RECEIVERS * 32)
	_debug_summary_receivers = rd.storage_buffer_create(receiver_zeros.size(), receiver_zeros)
	var output_size := DEBUG_SUMMARY_MAX_RECEIVERS * DEBUG_SUMMARY_LEVELS \
			* DEBUG_SUMMARY_CORNERS * DEBUG_SUMMARY_RECORD_WORDS * 4
	var output_zeros := PackedByteArray()
	output_zeros.resize(output_size)
	_debug_summary_output = rd.storage_buffer_create(output_size, output_zeros)
	if not _debug_summary_receivers.is_valid() or not _debug_summary_output.is_valid():
		return false
	_debug_summary_uniform_set = UniformSetCacheRD.get_cache(_debug_summary_shader, 0, [
		U.image(0, transfer_matrix), U.image(1, texture), U.image(2, tags),
		U.image(3, support), U.storage_buffer(4, _stencils),
		U.storage_buffer(5, _debug_summary_receivers),
		U.storage_buffer(6, _debug_summary_output), U.uniform_buffer(7, parameters)])
	return _debug_summary_uniform_set.is_valid()

func _finish_debug_summary_readback(data: PackedByteArray, callback: Callable,
		token: int, metadata: Dictionary, expected_bytes: int) -> void:
	_debug_summary_inflight = false
	var delivery_metadata := metadata.duplicate(true)
	if data.size() != expected_bytes:
		delivery_metadata["error"] = "debug_summary_size_mismatch"
		delivery_metadata["actual_bytes"] = data.size()
		_debug_summary_error = "debug_summary_size_mismatch"
	else:
		delivery_metadata["error"] = ""
		_debug_summary_error = ""
	# The RenderingDevice invokes async readback callbacks on its render thread
	# after the frame fence. Marshal inspection to the main thread and retain an
	# owned copy of the PackedByteArray before returning from the callback.
	call_deferred("_deliver_debug_summary_readback", data.duplicate(),
		callback, token, delivery_metadata)

func _deliver_debug_summary_readback(data: PackedByteArray, callback: Callable,
		token: int, metadata: Dictionary) -> void:
	if callback.is_valid():
		callback.call(data, token, metadata)

func get_runtime_state() -> Dictionary:
	return {
		"pending_blocks": maxi(0, _pending.size() - _cursor),
		"dispatch_serial": dispatch_serial,
		"last_dispatch_frame": last_dispatch_frame,
		"last_dispatch_blocks": last_dispatch_blocks,
		"transfer_matrix_valid": transfer_matrix.is_valid(),
		"transfer_matrix_emitters": transfer_matrix_emitters,
		"resident_levels": LEVELS,
		"resident_resolution": resolution,
		"resident_cells": resolution * resolution * resolution * LEVELS,
		"resident_face_slots": resolution * resolution * resolution * LEVELS * CLV_FACE_COUNT,
		"geometry_pending_blocks": maxi(0, _pending.size() - _cursor),
		"fill_scheduled_and_dispatched": scheduled_and_dispatched,
		"relight_serial": relight_serial,
		"last_relight_frame": last_relight_frame,
		"last_relight_cells": last_relight_cells,
		"last_relight_faces": last_relight_faces,
		"relight_lighting_revision": relight_lighting_revision,
		"relight_pending": relight_pending,
		"relight_scheduled_and_dispatched": relight_scheduled_and_dispatched,
		"scheduled_and_dispatched": relight_scheduled_and_dispatched,
		"relight_error": relight_error,
		"transfer_matrix_bytes": estimate_dynamic_transfer_bytes(resolution,
				transfer_matrix_emitters) if transfer_matrix.is_valid() else 0,
		"transfer_aggregate_scratch_bytes": _transfer_aggregate_scratch_bytes(
				transfer_matrix_emitters) if transfer_matrix.is_valid() else 0,
		"layout_version": LAYOUT_VERSION,
	}

## Apply current live SH to every resident transfer matrix in one GPU dispatch.
## Geometry fill remains on the bounded, camera-driven queue above and does not
## consume this lighting-refresh path.
func relight_resident(rd: RenderingDevice, live_gi_ubo: RID,
		lighting_revision: int) -> bool:
	relight_scheduled_and_dispatched = false
	relight_pending = lighting_revision != relight_lighting_revision
	relight_error = ""
	if not relight_pending:
		return true
	if rd == null or not live_gi_ubo.is_valid() or not texture.is_valid() \
			or not tags.is_valid() or not support.is_valid() \
			or not transfer_matrix.is_valid() or not _stencils.is_valid() \
			or not _resident_relight_pipeline.is_valid() \
			or not _resident_relight_shader.is_valid() \
			or not _emission_sources.is_valid():
		relight_error = "resident_relight_resource_invalid"
		return false
	var uniforms := UniformSetCacheRD.get_cache(_resident_relight_shader, 0, [
		U.image(0, texture), U.image(1, tags), U.image(2, transfer_matrix),
		U.uniform_buffer(3, live_gi_ubo),
		U.storage_buffer(4, _stencils),
		U.storage_buffer(5, _emission_sources)])
	if not uniforms.is_valid():
		relight_error = "resident_relight_uniform_set_invalid"
		return false
	var jobs := resolution * resolution * resolution * LEVELS
	var push := PackedInt32Array([jobs, resolution, _geometry_epoch,
		transfer_matrix_emitters, 0, 0, 0, 0]).to_byte_array()
	rd.draw_command_begin_label("Magic GI CLV Resident Relight", Color(0.7, 0.4, 0.9))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _resident_relight_pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, jobs, 1, 1)
	rd.compute_list_end()
	rd.draw_command_end_label()
	relight_serial += 1
	last_relight_frame = Engine.get_process_frames()
	last_relight_cells = jobs
	last_relight_faces = jobs * CLV_FACE_COUNT
	relight_lighting_revision = lighting_revision
	relight_pending = false
	relight_scheduled_and_dispatched = true
	return true

func _valid_transfer_inputs(inputs: Dictionary) -> bool:
	for key in ["transfer", "sky", "emission", "sources"]:
		var value: Variant = inputs.get(key, RID())
		if not value is RID or not value.is_valid():
			return false
	return true

func _fill_push_constants(job_count: int, geometry_epoch: int, base_spacing: float,
		dynamic_transfer: bool, emitter_count: int, logical_probe_count: int) -> PackedByteArray:
	var push := PackedInt32Array([job_count, resolution, geometry_epoch]).to_byte_array()
	push.append_array(PackedFloat32Array([base_spacing]).to_byte_array())
	push.append_array(PackedInt32Array([1 if dynamic_transfer else 0, emitter_count,
		logical_probe_count, 0]).to_byte_array())
	return push


func _cluster_buffer(bake: Dictionary) -> RID:
	var value: Variant = bake.get("probe_clusters", RID())
	if value is RID and value.is_valid():
		return value
	return _probe_cluster_fallback

static func _texture(rd: RenderingDevice, format_value: int, columns: int,
		selected_resolution := RESOLUTION) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = format_value
	var dimensions: Vector3i = _texture_dimensions(columns, selected_resolution)
	format.width = dimensions.x
	format.height = dimensions.y
	format.depth = dimensions.z
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	if format_value == RenderingDevice.DATA_FORMAT_R32_UINT:
		format.usage_bits |= RenderingDevice.TEXTURE_USAGE_STORAGE_ATOMIC_BIT
	return rd.texture_create(format, RDTextureView.new(), [])

static func _transfer_texture(rd: RenderingDevice, selected_resolution: int,
		emitter_count: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	var columns := TRANSFER_MATRIX_COLUMNS + maxi(0, emitter_count) * EMISSION_MATRIX_COLUMNS_PER_SOURCE
	format.width = selected_resolution * columns
	format.height = selected_resolution
	format.depth = selected_resolution * LEVELS * CLV_FACE_COUNT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return rd.texture_create(format, RDTextureView.new(), [])

static func _transfer_texture_dimensions(selected_resolution: int,
		emitter_count: int) -> Vector3i:
	var columns := TRANSFER_MATRIX_COLUMNS + maxi(0, emitter_count) * EMISSION_MATRIX_COLUMNS_PER_SOURCE
	return Vector3i(selected_resolution * columns, selected_resolution,
			selected_resolution * LEVELS * CLV_FACE_COUNT)

static func _texture_dimensions(columns: int, selected_resolution := RESOLUTION) -> Vector3i:
	return Vector3i(selected_resolution * columns, selected_resolution,
			selected_resolution * LEVELS)

static func _stencil_buffer_bytes(selected_resolution: int) -> int:
	return selected_resolution * selected_resolution * selected_resolution * LEVELS \
			* CLV_FACE_COUNT * STENCIL_WORDS * 4

static func _transfer_aggregate_scratch_bytes(emitter_count: int) -> int:
	var columns := TRANSFER_MATRIX_COLUMNS \
			+ maxi(0, emitter_count) * EMISSION_MATRIX_COLUMNS_PER_SOURCE
	return MAX_JOBS * CLV_FACE_COUNT * 2 * columns * 16
