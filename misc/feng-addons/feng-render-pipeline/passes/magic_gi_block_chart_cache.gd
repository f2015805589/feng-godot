@tool
extends "magic_gi_clv_cache.gd"
## Experimental layout-13 multi-chart cache. CPU geometry preparation is resumable;
## incomplete records never publish a current-epoch tag and therefore fall back to PRT.

const Layout13Builder = preload("magic_gi_clv_layout12_cpu_builder.gd")
const BlockFillShader: RDShaderFile = preload("../library/magic-gi/magic_gi_clv_block_fill.glsl")

const BLOCK_LAYOUT_VERSION := 13
const BLOCK_COLUMN_COUNT := 72
const BLOCK_CHART_COUNT := 3
const BLOCK_RECORD_BYTES := 208
const BLOCK_RECORD_WORDS := 52
const BLOCK_PARAMETER_BUFFER_BYTES := 80
const BLOCK_RGBA32_TEXEL_BYTES := 16
const BLOCK_TAG_COLUMNS := 1
const BLOCK_SUPPORT_COLUMNS := 1

# These values mirror magic_gi_clv_layout.glslinc exactly. In particular,
# WRITE_SUMMARY is bit 1 and RELIGHT_CACHED is bit 2.
const OP_WRITE_CHARTS := 1
const OP_WRITE_SUMMARY := 2
const OP_RELIGHT_CACHED := 4

const MAX_BLOCK_JOBS := 256
# Match the authored frame budget and dispatch capacity. Summary invalidations
# are sized for the corresponding worst-case old+new neighbors.
const MAX_FRAME_JOB_BUDGET := 256
# A recycled physical slot invalidates up to eight old and eight new same-level
# summary bases in one chart write batch.
const MAX_SUMMARY_BASES_PER_REPLACED_CELL := 16
const MAX_SUMMARY_JOBS := MAX_BLOCK_JOBS * MAX_SUMMARY_BASES_PER_REPLACED_CELL
const MAX_CPU_QUEUE := 256
const MAX_CPU_SOLVES_PER_FRAME := 8
const MAX_INDEX_WORK_PER_FRAME := 2048
const QUERY_NODE_BUDGET := 256
const QUERY_EDGE_BUDGET := 256
const QUERY_DOMAIN_BUDGET := 256

const BUILDER_INDEX_BYTES := 4
const CHART_MEMBER_NORMAL_COS := 0.55

var _records := RID()
var _summary_clear_jobs := RID()
var _summary_clear_records := RID()
var _summary_jobs := RID()
var _summary_records := RID()
# Reused upload scratch avoids per-job Packed*Array/to_byte_array/append churn.
var _layout12_job_upload_bytes := PackedByteArray()
var _layout12_record_upload_bytes := PackedByteArray()
var _layout12_builder: RefCounted
var _layout12_shader_key := ""
var _layout12_builder_ready := false
var _layout12_builder_failed := false
var _layout12_builder_progress: Dictionary = {}
var _layout12_index_ms_total := 0.0
var _layout12_cpu_last_ms := 0.0
var _layout12_query_started: Dictionary = {}
var _layout12_cpu_queue: Array[Vector4i] = []
var _layout12_cpu_queue_set: Dictionary = {}
var _layout12_ready_dispatch: Dictionary = {}
var _layout12_geometry_records: Dictionary = {}
var _layout12_slot_state: Dictionary = {}
var _layout12_summary_geometry_memo: Dictionary = {}
var _layout12_failures := 0
var _layout12_gpu_chart_jobs_submitted := 0
var _layout12_gpu_summary_clear_jobs_submitted := 0
var _layout12_gpu_summary_candidate_jobs_submitted := 0
var _layout12_gpu_summary_slot_counts := [0, 0, 0]
var _layout13_gpu_summary_mixed_jobs := 0
var _layout12_gpu_summary_clear_level_counts := [0, 0, 0]
var _layout12_gpu_summary_candidate_level_counts := [0, 0, 0]
var _layout12_gpu_chart_write_jobs_submitted := 0
var _layout12_gpu_chart_relight_jobs_submitted := 0
var _layout12_gpu_batches_submitted := 0
var _layout12_gpu_barriers_recorded := 0
var _layout12_gpu_stage_dispatch_failures := 0
var _layout12_gpu_stage_upload_failures := 0
var _layout12_summary_candidates_prepared := 0
var _layout12_summary_candidates_rejected: Dictionary = {}
var _layout12_summary_memo_hits := 0
var _layout12_summary_memo_misses := 0
var _layout12_summary_memo_invalidations := 0
var _layout12_summary_waiting_for_geometry_corners := 0
var _layout12_summary_waiting_for_current_slots := 0
var _layout12_cpu_records_pruned := 0
var _layout12_cpu_queries_pruned := 0
var _layout12_ready_jobs_pruned := 0
var _layout12_cpu_record_peak := 0
var _layout12_cpu_queue_peak := 0
var _layout12_frame_budget_last := 0
var _layout12_frame_chart_jobs_submitted_last := 0


static func abi_contract_values() -> Dictionary:
	return {
		"layout_version": BLOCK_LAYOUT_VERSION,
		"texture_columns": BLOCK_COLUMN_COUNT,
		"chart_count": BLOCK_CHART_COUNT,
		"record_bytes": BLOCK_RECORD_BYTES,
		"write_charts": OP_WRITE_CHARTS,
		"write_summary": OP_WRITE_SUMMARY,
		"relight_cached": OP_RELIGHT_CACHED
	}


static func validate_abi_constants() -> bool:
	return BLOCK_LAYOUT_VERSION == 13 and BLOCK_COLUMN_COUNT == 72 \
			and BLOCK_CHART_COUNT == 3 and BLOCK_RECORD_BYTES == 208 \
			and OP_WRITE_CHARTS == 1 and OP_WRITE_SUMMARY == 2 \
			and OP_RELIGHT_CACHED == 4 and BLOCK_RECORD_WORDS * 4 == BLOCK_RECORD_BYTES


func create(rd: RenderingDevice, requested_resolution := RESOLUTION,
		dynamic_transfer := false, emitter_count := 0) -> bool:
	if dynamic_transfer or emitter_count != 0:
		return false
	if not validate_abi_constants():
		return false
	_clear_layout12_summary_geometry_memo()
	resolution = EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION else RESOLUTION
	texture = _block_texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		BLOCK_COLUMN_COUNT, resolution)
	tags = _block_texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT,
		BLOCK_TAG_COLUMNS, resolution)
	support = _block_texture(rd, RenderingDevice.DATA_FORMAT_R32_UINT,
		BLOCK_SUPPORT_COLUMNS, resolution)
	parameters = rd.uniform_buffer_create(BLOCK_PARAMETER_BUFFER_BYTES)
	_jobs = rd.storage_buffer_create(MAX_BLOCK_JOBS * JOB_RECORD_BYTES)
	_records = rd.storage_buffer_create(MAX_BLOCK_JOBS * BLOCK_RECORD_BYTES)
	_summary_clear_jobs = rd.storage_buffer_create(MAX_SUMMARY_JOBS * JOB_RECORD_BYTES)
	_summary_clear_records = rd.storage_buffer_create(MAX_SUMMARY_JOBS * BLOCK_RECORD_BYTES)
	_summary_jobs = rd.storage_buffer_create(MAX_SUMMARY_JOBS * JOB_RECORD_BYTES)
	_summary_records = rd.storage_buffer_create(MAX_SUMMARY_JOBS * BLOCK_RECORD_BYTES)
	_stencils = rd.storage_buffer_create(_stencil_buffer_bytes(resolution))
	_probe_cluster_fallback = rd.storage_buffer_create(FALLBACK_CLUSTER_BUFFER_BYTES,
		PackedInt32Array([1, 0, 0, 0]).to_byte_array())
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler = rd.sampler_create(sampler_state)
	var spirv: RDShaderSPIRV = BlockFillShader.get_spirv()
	if spirv == null or BlockFillShader.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		_release_partial_create(rd)
		return false
	_shader = rd.shader_create_from_spirv(spirv, "Magic GI CLV Layout 13 Multi-Chart Fill")
	if _shader.is_valid():
		_pipeline = rd.compute_pipeline_create(_shader)
	for rid in owned_rids():
		if not rid.is_valid():
			_release_partial_create(rd)
			return false
	rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1)
	rd.texture_clear(support, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_layout12_builder = Layout13Builder.new()
	return true


func update(rd: RenderingDevice, camera: Vector3, base_spacing: float,
		geometry_epoch: int, content_revision: int, bake: Dictionary,
		directional: RefCounted, ubo: RID, nearest_sampler: RID, budget := 256,
		approximate_volume_enabled := false,
		exact_corner_visibility_enabled := false,
		approximate_ready_bit_enabled := false,
		dynamic_transfer := false) -> bool:
	if dynamic_transfer:
		return false
	# Layout 13 owns its domain certificates and does not accept legacy mode-9
	# approximate-volume or ready-bit controls.
	if approximate_volume_enabled or exact_corner_visibility_enabled \
			or approximate_ready_bit_enabled or not validate_abi_constants():
		return false
	var update_start := Time.get_ticks_usec()
	var frame_budget := clampi(budget, 0, MAX_FRAME_JOB_BUDGET)
	_layout12_frame_budget_last = frame_budget
	_layout12_frame_chart_jobs_submitted_last = 0
	var geometry_changed := _origins.is_empty() or _geometry_epoch != geometry_epoch \
			or not is_equal_approx(_spacing, base_spacing)
	if geometry_changed:
		_clear_layout12_summary_geometry_memo()
	if geometry_changed and not _origins.is_empty() and tags.is_valid():
		rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1)
		rd.texture_clear(support, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_layout12_slot_state.clear()
		_layout12_geometry_records.clear()
		_layout12_ready_dispatch.clear()
		_layout12_cpu_queue.clear()
		_layout12_cpu_queue_set.clear()
		_layout12_query_started.clear()
		_layout12_builder_ready = false
		_layout12_builder_failed = false
		_layout12_shader_key = ""
	var origins_before_update: Array = _origins.duplicate()
	queue_updates(camera, base_spacing, geometry_epoch)
	if _origins != origins_before_update:
		_prune_layout12_cpu_state()
	queue_content_refresh(content_revision)
	if not update_parameters(rd, base_spacing, geometry_epoch):
		return false
	if frame_budget <= 0:
		_layout12_cpu_last_ms = float(Time.get_ticks_usec() - update_start) / 1000.0
		return true
	if not _ensure_layout12_builder(rd, bake, geometry_epoch, base_spacing):
		_layout12_cpu_last_ms = float(Time.get_ticks_usec() - update_start) / 1000.0
		return true # Missing/invalid CPU geometry remains an ordinary source fallback.
	var index_start := Time.get_ticks_usec()
	if not _layout12_builder_ready and not _layout12_builder_failed:
		_layout12_builder_progress = _layout12_builder.advance_geometry_index(MAX_INDEX_WORK_PER_FRAME)
		_layout12_builder_ready = bool(_layout12_builder_progress.get("ready", false))
		_layout12_builder_failed = not bool(_layout12_builder_progress.get("valid", false))
		_layout12_index_ms_total += float(Time.get_ticks_usec() - index_start) / 1000.0
	if _layout12_builder_failed:
		_layout12_cpu_last_ms = float(Time.get_ticks_usec() - update_start) / 1000.0
		return true # Invalid index never publishes chart records.
	if not _layout12_builder_ready:
		_layout12_cpu_last_ms = float(Time.get_ticks_usec() - update_start) / 1000.0
		return true
	var submitted_frame_start := _layout12_gpu_chart_jobs_submitted
	_ingest_layout12_jobs(maxi(0, mini(MAX_CPU_QUEUE - _layout12_cpu_queue.size()
			- _layout12_ready_dispatch.size(), frame_budget)))
	_advance_layout12_cells(base_spacing, frame_budget)
	_layout12_cpu_queue_peak = maxi(_layout12_cpu_queue_peak, _layout12_cpu_queue.size())
	var dispatched_for_frame := 0
	var ok := true
	while not _layout12_ready_dispatch.is_empty() and dispatched_for_frame < frame_budget:
		var batch_budget := mini(MAX_BLOCK_JOBS, frame_budget - dispatched_for_frame)
		var submitted_before := _layout12_gpu_chart_jobs_submitted
		var ready_before := _layout12_ready_dispatch.size()
		if not _dispatch_layout12_ready(rd, base_spacing, geometry_epoch, bake,
				directional, ubo, nearest_sampler, batch_budget):
			ok = false
			break
		var submitted_delta := _layout12_gpu_chart_jobs_submitted - submitted_before
		dispatched_for_frame += submitted_delta
		if submitted_delta == 0 and _layout12_ready_dispatch.size() >= ready_before:
			break
	_layout12_frame_chart_jobs_submitted_last = \
			_layout12_gpu_chart_jobs_submitted - submitted_frame_start
	_layout12_cpu_last_ms = float(Time.get_ticks_usec() - update_start) / 1000.0
	return ok


func dispatch_page_jobs(_rd: RenderingDevice, selected: Array[Vector4i],
		_base_spacing: float, _geometry_token: int, _bake: Dictionary,
		_directional: RefCounted, _ubo: RID, _nearest_sampler: RID) -> bool:
	# Streamed-page jobs do not carry a complete immutable CPU BVH snapshot. Fail
	# closed; ordinary PRT sampling handles them until a complete bake is attached.
	return selected.is_empty()


func _ensure_layout12_builder(rd: RenderingDevice, bake: Dictionary, geometry_epoch: int,
		base_spacing: float) -> bool:
	var target_key := _builder_target_key(bake, geometry_epoch, base_spacing)
	if target_key == _layout12_shader_key:
		return _layout12_builder != null and not _layout12_builder_failed
	if not _layout12_shader_key.is_empty():
		_invalidate_layout12_builder_identity(rd)
	_layout12_builder = Layout13Builder.new()
	_layout12_builder_ready = false
	_layout12_builder_failed = false
	_layout12_builder_progress = {}
	_layout12_shader_key = target_key
	_layout12_query_started.clear()
	var nodes_value: Variant = bake.get("cpu_visibility_nodes", PackedFloat32Array())
	var triangles_value: Variant = bake.get("cpu_visibility_triangles", PackedFloat32Array())
	if not nodes_value is PackedFloat32Array or not triangles_value is PackedFloat32Array:
		_layout12_builder_failed = true
		return false
	var nodes: PackedFloat32Array = nodes_value
	var triangles: PackedFloat32Array = triangles_value
	if nodes.is_empty() or triangles.is_empty() \
			or not _layout12_builder.begin_geometry_epoch(target_key, nodes, triangles):
		_layout12_builder_failed = true
		return false
	return true


func _builder_target_key(bake: Dictionary, geometry_epoch: int,
		base_spacing: float) -> String:
	return "%s|%d|%.9f|layout%d|policy%d" % [
		str(bake.get("cpu_geometry_key", "")), geometry_epoch, base_spacing,
		BLOCK_LAYOUT_VERSION, Layout13Builder.MAX_CHART_SLOTS]


func _invalidate_layout12_builder_identity(rd: RenderingDevice) -> void:
	# The CPU BVH key is part of the geometry identity even if the caller's
	# geometry_epoch was accidentally reused. Never expose old chart tags under a
	# different immutable CPU geometry snapshot.
	_clear_layout12_summary_geometry_memo()
	if tags.is_valid():
		rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1)
	if support.is_valid():
		rd.texture_clear(support, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_layout12_slot_state.clear()
	_layout12_geometry_records.clear()
	_layout12_ready_dispatch.clear()
	_layout12_cpu_queue.clear()
	_layout12_cpu_queue_set.clear()
	_layout12_query_started.clear()
	_layout12_builder = null
	_pending.clear()
	_pending_set.clear()
	_cursor = 0
	for level in _origins.size():
		var origin: Vector3i = _origins[level]
		_enqueue_box(origin, origin + Vector3i.ONE * resolution, level)


func _ingest_layout12_jobs(budget: int) -> void:
	if budget <= 0:
		return
	var incoming := take_jobs(budget)
	for cell in incoming:
		var cell_key := _cell_key(cell)
		if _layout12_geometry_records.has(cell_key):
			_layout12_ready_dispatch[cell_key] = cell
		elif not _layout12_cpu_queue_set.has(cell_key) \
				and not _layout12_query_started.has(cell_key):
			_layout12_cpu_queue.append(cell)
			_layout12_cpu_queue_set[cell_key] = true
	_layout12_cpu_queue_peak = maxi(_layout12_cpu_queue_peak, _layout12_cpu_queue.size())


func _advance_layout12_cells(base_spacing: float, frame_budget: int) -> void:
	var advance_count := mini(MAX_CPU_SOLVES_PER_FRAME,
		mini(frame_budget, _layout12_cpu_queue.size()))
	var deferred: Array[Vector4i] = []
	for _index in advance_count:
		var cell: Vector4i = _layout12_cpu_queue.pop_front()
		var cell_key := _cell_key(cell)
		_layout12_cpu_queue_set.erase(cell_key)
		if _layout12_geometry_records.has(cell_key):
			_layout12_ready_dispatch[cell_key] = cell
			continue
		if _advance_layout12_cell_query(cell, base_spacing):
			if _layout12_geometry_records.has(cell_key):
				_layout12_ready_dispatch[cell_key] = cell
		else:
			deferred.append(cell)
	for cell in deferred:
		var cell_key := _cell_key(cell)
		if not _layout12_cpu_queue_set.has(cell_key):
			_layout12_cpu_queue.append(cell)
			_layout12_cpu_queue_set[cell_key] = true


func _advance_layout12_cell_query(cell: Vector4i, base_spacing: float) -> bool:
	var cell_key := _cell_key(cell)
	var query_key := "%s|%s" % [_layout12_shader_key, cell_key]
	if not _layout12_query_started.has(cell_key):
		var step := base_spacing * float(1 << cell.w)
		var spec := Layout13Builder.cell_query_spec(Vector3i(cell.x, cell.y, cell.z), step)
		if not bool(spec.get("valid", false)) or not _layout12_builder.begin_cell_query(
				query_key, spec.center, spec.half_extent):
			_layout12_failures += 1
			return true
		_layout12_query_started[cell_key] = {"query_key": query_key, "domain_started": false}
	var query_state: Dictionary = _layout12_query_started[cell_key]
	var progress: Dictionary = _layout12_builder.advance_cell_query(query_key, QUERY_NODE_BUDGET)
	if not bool(progress.get("valid", false)):
		_layout12_failures += 1
		_layout12_builder.forget_query(query_key)
		_layout12_query_started.erase(cell_key)
		return true
	if str(progress.get("phase", "")) == "partition":
		progress = _layout12_builder.advance_local_components(query_key,
			QUERY_EDGE_BUDGET, base_spacing * float(1 << cell.w),
			maxf(0.00001, base_spacing * float(1 << cell.w) * 0.0001),
			CHART_MEMBER_NORMAL_COS)
		if not bool(progress.get("valid", false)):
			_layout12_failures += 1
			_layout12_builder.forget_query(query_key)
			_layout12_query_started.erase(cell_key)
			return true
	if str(progress.get("phase", "")) == "components_ready":
		if not bool(query_state.get("domain_started", false)):
			if not _layout12_builder.begin_chart_domains_sweep(query_key, cell.w):
				_layout12_failures += 1
				_layout12_builder.forget_query(query_key)
				_layout12_query_started.erase(cell_key)
				return true
			query_state["domain_started"] = true
			_layout12_query_started[cell_key] = query_state
		progress = _layout12_builder.advance_chart_domains_sweep(query_key,
			QUERY_DOMAIN_BUDGET)
		if not bool(progress.get("valid", false)):
			_layout12_failures += 1
			_layout12_builder.forget_query(query_key)
			_layout12_query_started.erase(cell_key)
			return true
		if str(progress.get("phase", "")) == "ready":
			var result: Dictionary = _layout12_builder.get_chart_records(query_key)
			_layout12_builder.forget_query(query_key)
			_layout12_query_started.erase(cell_key)
			if not bool(result.get("valid", false)) or not bool(result.get("complete", false)):
				_layout12_failures += 1
				return true
			var compact_charts: Array[Dictionary] = []
			for chart_value in result.get("charts", []):
				var chart: Dictionary = chart_value
				compact_charts.append({
					"triangle_id": int(chart.get("triangle_id", -1)),
					"triangle_id_plus_one": int(chart.get("triangle_id_plus_one", -1)),
					"anchor": chart.get("anchor", Vector3.ZERO),
					"normal": chart.get("normal", Vector3.ZERO),
					"patch_id": int(chart.get("patch_id", -1)),
					"component_id": int(chart.get("component_id", -1)),
					"radius": float(chart.get("radius", 0.0)),
					"half_height": float(chart.get("half_height", 0.0)),
					"normal_cos": float(chart.get("normal_cos", 0.72))})
			# The GPU summary ABI stores a common slot across all eight corners.
			# Seed acceptance order is not a stable cross-cell slot order, so sort
			# using the builder's existing deterministic key before packing.
			compact_charts.sort_custom(Callable(self, "_chart_slot_stable_less"))
			_layout12_geometry_records[cell_key] = {
				"cell": cell, "complete": true,
				"complete_no_receiver": bool(result.get("complete_no_receiver", false)),
				"charts": compact_charts,
				"candidate_count": int(result.get("candidate_count", 0)),
				"node_visits": int(result.get("node_visits", 0))}
			_layout12_cpu_record_peak = maxi(_layout12_cpu_record_peak,
				_layout12_geometry_records.size())
			return true
		return false
	return false


func _chart_slot_stable_less(a: Dictionary, b: Dictionary) -> bool:
	var patch_a := int(a.get("patch_id", -1))
	var patch_b := int(b.get("patch_id", -1))
	if patch_a != patch_b:
		return patch_a < patch_b
	var component_a := int(a.get("component_id", -1))
	var component_b := int(b.get("component_id", -1))
	if component_a != component_b:
		return component_a < component_b
	var normal_a: Vector3 = a.get("normal", Vector3.ZERO)
	var normal_b: Vector3 = b.get("normal", Vector3.ZERO)
	for axis in 3:
		var quantized_a := roundi(normal_a[axis] * 4096.0)
		var quantized_b := roundi(normal_b[axis] * 4096.0)
		if quantized_a != quantized_b:
			return quantized_a < quantized_b
	return int(a.get("triangle_id", -1)) < int(b.get("triangle_id", -1))


func _dispatch_layout12_ready(rd: RenderingDevice, base_spacing: float,
		geometry_epoch: int, bake: Dictionary, directional: RefCounted,
		ubo: RID, nearest_sampler: RID, batch_budget: int) -> bool:
	if _layout12_ready_dispatch.is_empty():
		return true
	var ready_keys: Array = _layout12_ready_dispatch.keys()
	ready_keys.sort()
	var chart_jobs: Array[Dictionary] = []
	for key_value in ready_keys:
		if chart_jobs.size() >= mini(MAX_BLOCK_JOBS, batch_budget):
			break
		var key := str(key_value)
		var cell: Vector4i = _layout12_ready_dispatch[key]
		var record: Dictionary = _layout12_geometry_records.get(key, {})
		if not _cell_inside_current_clip(cell) \
				or not bool(record.get("complete", false)) \
				or record.get("cell", Vector4i(0x7fffffff, 0x7fffffff, 0x7fffffff, -1)) != cell:
			_layout12_ready_dispatch.erase(key)
			_layout12_ready_jobs_pruned += 1
			continue
		var slot_key := _physical_slot_key(cell)
		var slot_state: Dictionary = _layout12_slot_state.get(slot_key, {})
		var op := 0
		if str(slot_state.get("logical_key", "")) != key \
				or int(slot_state.get("geometry_epoch", -1)) != _geometry_epoch:
			op = OP_WRITE_CHARTS
		elif int(slot_state.get("content_revision", -1)) != _content_revision:
			op = OP_RELIGHT_CACHED
		if op != 0:
			chart_jobs.append({"key": key, "cell": cell, "op": op,
				"chart_count": int(_layout12_geometry_records[key].get("charts", []).size()) \
					if op == OP_WRITE_CHARTS else 0,
				"geometry": _layout12_geometry_records[key]})
		else:
			_layout12_ready_dispatch.erase(key)
	if chart_jobs.is_empty():
		return true
	if directional == null or not is_instance_valid(directional) \
			or not directional.lighting.is_valid():
		_layout12_gpu_stage_dispatch_failures += 1
		return false
	var affected_bases := _affected_summary_bases_by_reason(chart_jobs)
	var clear_bases: Dictionary = affected_bases["clear"]
	var clear_base_values: Array = clear_bases.values()
	var geometry_write_bases: Dictionary = affected_bases["geometry_writes"]
	_invalidate_summary_geometry_memo_for_bases(geometry_write_bases)
	var clear_jobs: Array[Dictionary] = []
	var chart_cells_invalidating_self: Dictionary = {}
	for chart_job in chart_jobs:
		var chart_cell: Vector4i = chart_job.cell
		chart_cells_invalidating_self[_physical_slot_key(chart_cell)] = _cell_key(chart_cell)
	for base_value in clear_base_values:
		var base_cell: Vector4i = base_value
		# Old toroidal occupants can contribute invalidation keys outside the new
		# logical window. Their physical slots are not sampled now; clearing them
		# would fail the current-window job gate and block the valid batch.
		if not _cell_inside_current_clip(base_cell):
			continue
		# WRITE_CHARTS and RELIGHT_CACHED both clear their own summary in the
		# chart stage, so avoid a duplicate SUMMARY_ONLY job for that same cell.
		if str(chart_cells_invalidating_self.get(_physical_slot_key(base_cell), "")) \
				== _cell_key(base_cell):
			continue
		clear_jobs.append({"cell": base_value, "op": OP_WRITE_SUMMARY,
			"chart_count": 0, "summary_word": 0, "summary": {}})
	var summary_jobs := _build_ready_summary_jobs(clear_base_values, chart_jobs, geometry_epoch, base_spacing)
	if not _dispatch_layout12_stages(rd, clear_jobs, chart_jobs, summary_jobs,
			base_spacing, geometry_epoch, bake, directional, ubo, nearest_sampler):
		return false
	for chart_job in chart_jobs:
		var cell: Vector4i = chart_job.cell
		var key := str(chart_job.key)
		_layout12_slot_state[_physical_slot_key(cell)] = {
			"logical_key": key, "logical_cell": cell,
			"geometry_epoch": geometry_epoch,
			"content_revision": _content_revision}
		_layout12_ready_dispatch.erase(key)
		if int(chart_job.op) == OP_WRITE_CHARTS:
			_layout12_gpu_chart_write_jobs_submitted += 1
		elif int(chart_job.op) == OP_RELIGHT_CACHED:
			_layout12_gpu_chart_relight_jobs_submitted += 1
	_layout12_gpu_chart_jobs_submitted += chart_jobs.size()
	_layout12_gpu_batches_submitted += 1
	_layout12_gpu_summary_clear_jobs_submitted += clear_jobs.size()
	_layout12_gpu_summary_candidate_jobs_submitted += summary_jobs.size()
	_layout12_summary_candidates_prepared += summary_jobs.size()
	for job in clear_jobs:
		var clear_level := int(job.cell.w)
		if clear_level >= 0 and clear_level < LEVELS:
			_layout12_gpu_summary_clear_level_counts[clear_level] += 1
	for job in summary_jobs:
		var slot := int(job.summary.get("uniform_slot", -1))
		if slot >= 0 and slot < 3:
			_layout12_gpu_summary_slot_counts[slot] += 1
		else:
			_layout13_gpu_summary_mixed_jobs += 1
		var summary_level := int(job.cell.w)
		if summary_level >= 0 and summary_level < LEVELS:
			_layout12_gpu_summary_candidate_level_counts[summary_level] += 1
	return true


func _affected_summary_bases_by_reason(chart_jobs: Array[Dictionary]) -> Dictionary:
	var clear_bases: Dictionary = {}
	var geometry_bases: Dictionary = {}
	if _origins.size() != LEVELS:
		return {"clear": clear_bases, "geometry_writes": geometry_bases}
	for job in chart_jobs:
		var cell: Vector4i = job.cell
		if cell.w < 0 or cell.w >= LEVELS:
			continue
		var geometry_write := int(job.op) == OP_WRITE_CHARTS
		var changed_cells: Array[Vector4i] = [cell]
		# A toroidal slot can replace a prior logical cell. Its old neighboring
		# summaries must be invalidated as well as the new cell's neighbors.
		if geometry_write:
			var previous: Dictionary = _layout12_slot_state.get(_physical_slot_key(cell), {})
			var previous_cell: Vector4i = previous.get("logical_cell",
				_cell_from_key(str(previous.get("logical_key", ""))))
			if str(previous.get("logical_key", "")) != "" and previous_cell != cell:
				changed_cells.append(previous_cell)
		for changed in changed_cells:
			if changed.w < 0 or changed.w >= LEVELS:
				continue
			var origin: Vector3i = _origins[changed.w]
			for zbit in 2:
				for ybit in 2:
					for xbit in 2:
						var base := Vector3i(changed.x - xbit, changed.y - ybit,
							changed.z - zbit)
						if not _inside_clip(base, origin):
							continue
						var base_cell := Vector4i(base.x, base.y, base.z, changed.w)
						var slot_key := _physical_slot_key(base_cell)
						clear_bases[slot_key] = base_cell
						if geometry_write:
							geometry_bases[slot_key] = base_cell
	return {"clear": clear_bases, "geometry_writes": geometry_bases}


func _invalidate_summary_geometry_memo_for_bases(affected_bases: Dictionary) -> void:
	for base_value in affected_bases.values():
		var key := _cell_key(base_value)
		if _layout12_summary_geometry_memo.erase(key):
			_layout12_summary_memo_invalidations += 1

func _clear_layout12_summary_geometry_memo() -> void:
	_layout12_summary_memo_invalidations += _layout12_summary_geometry_memo.size()
	_layout12_summary_geometry_memo.clear()


func _build_ready_summary_jobs(clear_base_values: Array, chart_jobs: Array[Dictionary],
		geometry_epoch: int, base_spacing: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# Corner coordinates are in [origin, origin + resolution] because each
	# summary base is clip-local and contributes its 8 upper/lower corners.
	# Dense call-local arrays avoid allocating a Dictionary snapshot per corner.
	var cache_side := resolution + 1
	var cache_per_level := cache_side * cache_side * cache_side
	var cache_size := LEVELS * cache_per_level
	var planned_current := PackedByteArray()
	planned_current.resize(cache_size)
	planned_current.fill(0)
	for chart_job in chart_jobs:
		var planned_cell: Vector4i = chart_job.cell
		if planned_cell.w < 0 or planned_cell.w >= _origins.size():
			continue
		var planned_origin: Vector3i = _origins[planned_cell.w]
		var planned_x := planned_cell.x - planned_origin.x
		var planned_y := planned_cell.y - planned_origin.y
		var planned_z := planned_cell.z - planned_origin.z
		if planned_x < 0 or planned_x > resolution or planned_y < 0 \
				or planned_y > resolution or planned_z < 0 or planned_z > resolution:
			continue
		var planned_index := planned_cell.w * cache_per_level \
				+ planned_x * cache_side * cache_side + planned_y * cache_side + planned_z
		planned_current[planned_index] = 1
	var corner_state_cache := PackedInt32Array()
	corner_state_cache.resize(cache_size)
	corner_state_cache.fill(-1)
	var corner_charts_cache: Array = []
	corner_charts_cache.resize(cache_size)
	for base_value in clear_base_values:
		if result.size() >= MAX_SUMMARY_JOBS:
			break
		var base_cell: Vector4i = base_value
		if not _cell_inside_current_clip(base_cell):
			continue
		var corners: Array = []
		var complete := true
		var geometry_wait := false
		var current_slot_wait := false
		for corner_index in 8:
			var corner := Vector4i(base_cell.x + (corner_index & 1),
				base_cell.y + ((corner_index >> 1) & 1),
				base_cell.z + ((corner_index >> 2) & 1), base_cell.w)
			var corner_origin: Vector3i = _origins[corner.w]
			var corner_x := corner.x - corner_origin.x
			var corner_y := corner.y - corner_origin.y
			var corner_z := corner.z - corner_origin.z
			var corner_cache_index := corner.w * cache_per_level \
					+ corner_x * cache_side * cache_side + corner_y * cache_side + corner_z
			var corner_state := corner_state_cache[corner_cache_index]
			if corner_state < 0:
				var corner_key := _cell_key(corner)
				var record: Dictionary = _layout12_geometry_records.get(corner_key, {})
				if not bool(record.get("complete", false)):
					corner_state = 0
				else:
					var slot_state: Dictionary = _layout12_slot_state.get(
						_physical_slot_key(corner), {})
					var state_cell: Vector4i = slot_state.get("logical_cell",
						_cell_from_key(str(slot_state.get("logical_key", ""))))
					var geometry_current := state_cell == corner \
							and int(slot_state.get("geometry_epoch", -1)) == geometry_epoch
					corner_state = 1
					if geometry_current:
						corner_state |= 2
					elif planned_current[corner_cache_index] != 0:
						corner_state |= 4
					corner_charts_cache[corner_cache_index] = record.get("charts", [])
				corner_state_cache[corner_cache_index] = corner_state
			if (corner_state & 1) == 0:
				geometry_wait = true
				complete = false
				break
			# Matching geometry tags/domain is sufficient here. Content revisions
			# intentionally remain budgeted and may differ among the eight corners,
			# just as the ordinary slow path may sample during a live Sky refresh.
			if (corner_state & 2) == 0 and (corner_state & 4) == 0:
				current_slot_wait = true
				complete = false
				break
			corners.append(corner_charts_cache[corner_cache_index])
		if geometry_wait:
			_layout12_summary_waiting_for_geometry_corners += 1
			continue
		if current_slot_wait:
			_layout12_summary_waiting_for_current_slots += 1
			continue
		if not complete or corners.size() != 8:
			continue
		var summary_key := _cell_key(base_cell)
		var summary: Dictionary
		if _layout12_summary_geometry_memo.has(summary_key):
			_layout12_summary_memo_hits += 1
			summary = _layout12_summary_geometry_memo[summary_key]
		else:
			_layout12_summary_memo_misses += 1
			summary = Layout13Builder.build_summary_candidate(corners)
			if bool(summary.get("valid", false)):
				summary = _prepare_summary_candidate_for_gpu(summary, corners,
					base_cell, base_spacing)
			_layout12_summary_geometry_memo[summary_key] = summary.duplicate(true)
		if bool(summary.get("valid", false)):
			result.append({"cell": base_cell, "op": OP_WRITE_SUMMARY,
				"chart_count": 0, "summary_word": 1 | (int(summary.get("positive_corner_mask", 0)) << 8),
				"summary": summary})
		else:
			var reason := str(summary.get("reason", "unknown"))
			_layout12_summary_candidates_rejected[reason] = \
					int(_layout12_summary_candidates_rejected.get(reason, 0)) + 1
	return result


func _prepare_summary_candidate_for_gpu(summary: Dictionary, corners: Array,
		base_cell: Vector4i, base_spacing: float) -> Dictionary:
	var slots_value: Variant = summary.get("slots", [])
	var slot_map := int(summary.get("slot_map", -1))
	var uniform_slot := int(summary.get("uniform_slot", -1))
	var center_value: Variant = summary.get("center", Vector3.ZERO)
	var normal_value: Variant = summary.get("normal", Vector3.ZERO)
	if not slots_value is Array or slots_value.size() != 8 \
			or not _summary_slot_map_valid(summary) or corners.size() != 8 \
			or not center_value is Vector3 or not normal_value is Vector3:
		return {"valid": false, "reason": "summary_gpu_payload_shape"}
	var slots: Array = slots_value
	var center: Vector3 = center_value
	var nbar: Vector3 = normal_value
	if not center.is_finite() or not nbar.is_finite() or nbar.length_squared() <= 1e-12:
		return {"valid": false, "reason": "summary_gpu_payload_nonfinite"}
	nbar = nbar.normalized()
	var max_normal_deviation := 0.0
	for corner_index in 8:
		var slot := int(slots[corner_index])
		var corner_set_value: Variant = corners[corner_index]
		if not corner_set_value is Array:
			return {"valid": false, "reason": "summary_gpu_corner_type"}
		var corner_set: Array = corner_set_value
		if slot >= corner_set.size() or not corner_set[slot] is Dictionary:
			return {"valid": false, "reason": "summary_gpu_corner_slot"}
		var chart: Dictionary = corner_set[slot]
		if int(chart.get("patch_id", -1)) != int(summary.get("patch_id", -2)) \
				or int(chart.get("component_id", -1)) != int(summary.get("component_id", -2)):
			return {"valid": false, "reason": "summary_gpu_identity_changed"}
		var chart_normal_value: Variant = chart.get("normal", Vector3.ZERO)
		if not chart_normal_value is Vector3:
			return {"valid": false, "reason": "summary_gpu_normal_type"}
		var chart_normal: Vector3 = chart_normal_value
		if not chart_normal.is_finite() or chart_normal.length_squared() <= 1e-12:
			return {"valid": false, "reason": "summary_gpu_normal_invalid"}
		max_normal_deviation = maxf(max_normal_deviation,
			(chart_normal.normalized() - nbar).length())
	var step_size := base_spacing * float(1 << base_cell.w)
	var magnitude := maxf(step_size, maxf(absf(center.x),
		maxf(absf(center.y), absf(center.z))))
	var coordinate_guard := maxf(1e-5, magnitude * 1.9073486328125e-6)
	var finalizer_tolerance := maxf(1e-5, step_size * 1e-4) + coordinate_guard
	var inset_guard := coordinate_guard
	var packed_radius := float(summary.get("radius", 0.0)) \
			- finalizer_tolerance - inset_guard
	var packed_height := float(summary.get("half_height", 0.0)) \
			- finalizer_tolerance - inset_guard
	var packed_normal_deviation := max_normal_deviation \
			+ finalizer_tolerance + inset_guard
	if not is_finite(packed_radius) or not is_finite(packed_height) \
			or not is_finite(packed_normal_deviation) \
			or packed_radius <= 0.0 or packed_height <= 0.0 \
			or packed_normal_deviation > 1.0:
		return {"valid": false, "reason": "summary_gpu_inward_margin_empty"}
	var prepared := summary.duplicate(true)
	prepared["normal"] = nbar
	prepared["radius"] = packed_radius
	prepared["half_height"] = packed_height
	prepared["max_normal_deviation"] = packed_normal_deviation
	prepared["slot_map"] = slot_map
	prepared["uniform_slot"] = uniform_slot
	prepared["gpu_finalizer_tolerance"] = finalizer_tolerance
	prepared["gpu_inward_guard"] = inset_guard
	return prepared


func _summary_slot_map_valid(summary: Dictionary) -> bool:
	if not bool(summary.get("valid", false)):
		return false
	var slots_value: Variant = summary.get("slots", [])
	var slot_map_value: Variant = summary.get("slot_map", -1)
	var uniform_value: Variant = summary.get("uniform_slot", -1)
	var slot_value: Variant = summary.get("slot", -1)
	var mixed_value: Variant = summary.get("mixed", false)
	if not slots_value is Array or slots_value.size() != 8 \
			or typeof(slot_map_value) != TYPE_INT \
			or typeof(uniform_value) != TYPE_INT or typeof(slot_value) != TYPE_INT \
			or typeof(mixed_value) != TYPE_BOOL:
		return false
	var slot_map: int = int(slot_map_value)
	if slot_map < 0 or slot_map > 0xffff:
		return false
	var slots: Array = slots_value
	var is_uniform := true
	if typeof(slots[0]) != TYPE_INT:
		return false
	var first_slot := int(slots[0])
	for corner_index in 8:
		if typeof(slots[corner_index]) != TYPE_INT:
			return false
		var slot := int(slots[corner_index])
		var encoded_slot := (slot_map >> (corner_index * 2)) & 3
		if slot < 0 or slot >= BLOCK_CHART_COUNT or encoded_slot != slot:
			return false
		if slot != first_slot:
			is_uniform = false
	var declared_uniform := int(uniform_value)
	if is_uniform:
		return declared_uniform == first_slot and int(slot_value) == first_slot \
				and not bool(mixed_value)
	return declared_uniform == -1 and int(slot_value) == -1 and bool(mixed_value)


func _dispatch_layout12_stages(rd: RenderingDevice, clear_jobs: Array[Dictionary],
		chart_jobs: Array[Dictionary], summary_jobs: Array[Dictionary],
		base_spacing: float, geometry_epoch: int, bake: Dictionary,
		directional: RefCounted, ubo: RID, nearest_sampler: RID) -> bool:
	var lighting: RID = directional.lighting
	if not lighting.is_valid():
		_layout12_gpu_stage_dispatch_failures += 1
		return false
	if not _upload_stage(rd, _summary_clear_jobs, _summary_clear_records, clear_jobs,
			MAX_SUMMARY_JOBS):
		_layout12_gpu_stage_upload_failures += 1
		return false
	if not _upload_stage(rd, _jobs, _records, chart_jobs, MAX_BLOCK_JOBS):
		_layout12_gpu_stage_upload_failures += 1
		return false
	if not _upload_stage(rd, _summary_jobs, _summary_records, summary_jobs,
			MAX_SUMMARY_JOBS):
		_layout12_gpu_stage_upload_failures += 1
		return false
	var clear_set := _layout12_uniform_set(rd, bake, lighting, ubo, nearest_sampler,
		_summary_clear_jobs, _summary_clear_records)
	var chart_set := _layout12_uniform_set(rd, bake, lighting, ubo, nearest_sampler,
		_jobs, _records)
	var summary_set := _layout12_uniform_set(rd, bake, lighting, ubo, nearest_sampler,
		_summary_jobs, _summary_records)
	if (not clear_jobs.is_empty() and not clear_set.is_valid()) \
			or (not chart_jobs.is_empty() and not chart_set.is_valid()) \
			or (not summary_jobs.is_empty() and not summary_set.is_valid()):
		_layout12_gpu_stage_dispatch_failures += 1
		return false
	var list := rd.compute_list_begin()
	var started := false
	if not clear_jobs.is_empty():
		_dispatch_stage(rd, list, clear_set, clear_jobs.size(), base_spacing, geometry_epoch)
		started = true
	if not chart_jobs.is_empty():
		if started:
			rd.compute_list_add_barrier(list)
			_layout12_gpu_barriers_recorded += 1
		_dispatch_stage(rd, list, chart_set, chart_jobs.size(), base_spacing, geometry_epoch)
		started = true
	if not summary_jobs.is_empty():
		if started:
			rd.compute_list_add_barrier(list)
			_layout12_gpu_barriers_recorded += 1
		_dispatch_stage(rd, list, summary_set, summary_jobs.size(), base_spacing, geometry_epoch)
	if started:
		# Publish chart/tag/support/summary writes to the following ordinary Apply
		# compute list; finalization must never race the consumer.
		rd.compute_list_add_barrier(list)
		_layout12_gpu_barriers_recorded += 1
	rd.compute_list_end()
	return true


func _dispatch_stage(rd: RenderingDevice, list: int, uniform_set: RID,
		job_count: int, base_spacing: float, geometry_epoch: int) -> void:
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	var push := PackedInt32Array([job_count, resolution, geometry_epoch]).to_byte_array()
	push.append_array(PackedFloat32Array([base_spacing]).to_byte_array())
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, job_count, 1, 1)


func _layout12_uniform_set(rd: RenderingDevice, bake: Dictionary, lighting: RID,
		ubo: RID, nearest_sampler: RID, jobs_rid: RID, records_rid: RID) -> RID:
	var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [
		U.sampled(0, nearest_sampler, bake.get("geometry", RID())),
		U.sampled(1, nearest_sampler, bake.get("indices", RID())),
		U.storage_buffer(2, bake.get("visibility_nodes", RID())),
		U.storage_buffer(3, bake.get("visibility_triangles", RID())),
		U.storage_buffer(4, lighting), U.storage_buffer(5, jobs_rid),
		U.image(6, texture), U.image(7, tags), U.uniform_buffer(8, ubo),
		U.storage_buffer(9, bake.get("index_entries", RID())),
		U.storage_buffer(10, _cluster_buffer(bake)), U.image(11, support),
		U.storage_buffer(12, _stencils), U.storage_buffer(13, records_rid)])
	return uniforms


func _upload_stage(rd: RenderingDevice, jobs_rid: RID, records_rid: RID,
		jobs: Array[Dictionary], capacity: int) -> bool:
	if jobs.is_empty():
		return true
	if jobs.size() > capacity:
		return false
	var job_byte_count := jobs.size() * JOB_RECORD_BYTES
	var record_byte_count := jobs.size() * BLOCK_RECORD_BYTES
	_layout12_job_upload_bytes.resize(job_byte_count)
	_layout12_record_upload_bytes.resize(record_byte_count)
	for job_index in jobs.size():
		var job: Dictionary = jobs[job_index]
		if not _layout12_job_valid(job):
			return false
		var cell: Vector4i = job.cell
		var job_offset := job_index * JOB_RECORD_BYTES
		_layout12_job_upload_bytes.encode_s32(job_offset, cell.x)
		_layout12_job_upload_bytes.encode_s32(job_offset + 4, cell.y)
		_layout12_job_upload_bytes.encode_s32(job_offset + 8, cell.z)
		_layout12_job_upload_bytes.encode_s32(job_offset + 12, cell.w)
		if not _serialize_layout12_job_into(_layout12_record_upload_bytes,
				job_index * BLOCK_RECORD_BYTES, job):
			return false
	if _layout12_job_upload_bytes.size() != job_byte_count \
			or _layout12_record_upload_bytes.size() != record_byte_count:
		return false
	return rd.buffer_update(jobs_rid, 0, job_byte_count, _layout12_job_upload_bytes) == OK \
			and rd.buffer_update(records_rid, 0, record_byte_count,
				_layout12_record_upload_bytes) == OK


func _layout12_job_valid(job: Dictionary) -> bool:
	if not job.has("cell") or not job.has("op"):
		return false
	var cell: Vector4i = job.cell
	var operation := int(job.op)
	var chart_count := int(job.get("chart_count", 0))
	if cell.w < 0 or cell.w >= LEVELS or not _cell_inside_current_clip(cell):
		return false
	if operation == OP_WRITE_CHARTS:
		var geometry: Dictionary = job.get("geometry", {})
		var charts: Array = geometry.get("charts", [])
		return bool(geometry.get("complete", false)) and chart_count >= 0 \
				and chart_count <= BLOCK_CHART_COUNT and chart_count == charts.size()
	if operation == OP_RELIGHT_CACHED:
		var slot_state: Dictionary = _layout12_slot_state.get(_physical_slot_key(cell), {})
		var state_cell: Vector4i = slot_state.get("logical_cell",
			_cell_from_key(str(slot_state.get("logical_key", ""))))
		return chart_count == 0 and state_cell == cell \
				and int(slot_state.get("geometry_epoch", -1)) == _geometry_epoch
	if operation == OP_WRITE_SUMMARY:
		var summary_word := int(job.get("summary_word", 0))
		var summary: Dictionary = job.get("summary", {})
		return chart_count == 0 and (summary_word == 0 \
				or _summary_slot_map_valid(summary))
	return false


func _serialize_layout12_job_into(bytes: PackedByteArray, byte_offset: int,
		job: Dictionary) -> bool:
	if byte_offset < 0 or byte_offset + BLOCK_RECORD_BYTES > bytes.size():
		return false
	var operation := int(job.get("op", 0))
	var charts: Array = job.get("geometry", {}).get("charts", [])
	var chart_count := int(job.get("chart_count", charts.size()))
	var summary_word := int(job.get("summary_word", 0))
	bytes.encode_s32(byte_offset, operation)
	bytes.encode_s32(byte_offset + 4, chart_count)
	bytes.encode_s32(byte_offset + 8, summary_word)
	bytes.encode_s32(byte_offset + 12, BLOCK_LAYOUT_VERSION)
	for slot in BLOCK_CHART_COUNT:
		var chart_offset := byte_offset + 16 + slot * 48
		if slot < chart_count:
			var chart: Dictionary = charts[slot]
			var anchor: Vector3 = chart.get("anchor", Vector3.ZERO)
			var normal: Vector3 = chart.get("normal", Vector3.ZERO)
			var radius := float(chart.get("radius", 0.0))
			var half_height := float(chart.get("half_height", 0.0))
			var normal_cos := float(chart.get("normal_cos", 0.72))
			var patch_id := int(chart.get("patch_id", -1))
			var triangle_plus_one := int(chart.get("triangle_id_plus_one", -1))
			var component_id := int(chart.get("component_id", -1))
			bytes.encode_float(chart_offset, anchor.x)
			bytes.encode_float(chart_offset + 4, anchor.y)
			bytes.encode_float(chart_offset + 8, anchor.z)
			bytes.encode_float(chart_offset + 12, float(triangle_plus_one))
			bytes.encode_float(chart_offset + 16, normal.x)
			bytes.encode_float(chart_offset + 20, normal.y)
			bytes.encode_float(chart_offset + 24, normal.z)
			bytes.encode_float(chart_offset + 28, float(patch_id))
			bytes.encode_float(chart_offset + 32, radius)
			bytes.encode_float(chart_offset + 36, half_height)
			bytes.encode_float(chart_offset + 40, normal_cos)
			bytes.encode_float(chart_offset + 44, float(component_id))
		else:
			bytes.encode_float(chart_offset, 0.0)
			bytes.encode_float(chart_offset + 4, 0.0)
			bytes.encode_float(chart_offset + 8, 0.0)
			bytes.encode_float(chart_offset + 12, 0.0)
			bytes.encode_float(chart_offset + 16, 0.0)
			bytes.encode_float(chart_offset + 20, 0.0)
			bytes.encode_float(chart_offset + 24, 0.0)
			bytes.encode_float(chart_offset + 28, -1.0)
			bytes.encode_float(chart_offset + 32, 0.0)
			bytes.encode_float(chart_offset + 36, 0.0)
			bytes.encode_float(chart_offset + 40, 0.0)
			bytes.encode_float(chart_offset + 44, 0.0)
	var summary: Dictionary = job.get("summary", {})
	var summary_offset := byte_offset + 16 + BLOCK_CHART_COUNT * 48
	if bool(summary.get("valid", false)):
		var normal_value: Vector3 = summary.get("normal", Vector3.ZERO)
		var center_value: Vector3 = summary.get("center", Vector3.ZERO)
		bytes.encode_float(summary_offset, normal_value.x)
		bytes.encode_float(summary_offset + 4, normal_value.y)
		bytes.encode_float(summary_offset + 8, normal_value.z)
		bytes.encode_float(summary_offset + 12, float(summary.get("patch_id", -1)))
		bytes.encode_float(summary_offset + 16, center_value.x)
		bytes.encode_float(summary_offset + 20, center_value.y)
		bytes.encode_float(summary_offset + 24, center_value.z)
		bytes.encode_float(summary_offset + 28, float(summary.get("component_id", -1)))
		bytes.encode_float(summary_offset + 32, float(summary.get("radius", 0.0)))
		bytes.encode_float(summary_offset + 36, float(summary.get("half_height", 0.0)))
		bytes.encode_float(summary_offset + 40,
			float(summary.get("max_normal_deviation", 0.0)))
		bytes.encode_float(summary_offset + 44, float(summary.get("slot_map", 0xffff)))
	else:
		bytes.encode_float(summary_offset, 0.0)
		bytes.encode_float(summary_offset + 4, 0.0)
		bytes.encode_float(summary_offset + 8, 0.0)
		bytes.encode_float(summary_offset + 12, -1.0)
		bytes.encode_float(summary_offset + 16, 0.0)
		bytes.encode_float(summary_offset + 20, 0.0)
		bytes.encode_float(summary_offset + 24, 0.0)
		bytes.encode_float(summary_offset + 28, -1.0)
		bytes.encode_float(summary_offset + 32, 0.0)
		bytes.encode_float(summary_offset + 36, 0.0)
		bytes.encode_float(summary_offset + 40, 0.0)
		bytes.encode_float(summary_offset + 44, -1.0)
	return true


func update_parameters(rd: RenderingDevice, base_spacing: float, geometry_epoch: int,
		_approximate_volume_enabled := false,
		_exact_corner_visibility_enabled := false,
		_approximate_ready_bit_enabled := false) -> bool:
	if _origins.size() != LEVELS:
		return false
	var constants := PackedByteArray()
	for origin in _origins:
		constants.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	constants.append_array(PackedFloat32Array([base_spacing, 0.0, 0.0, 0.0]).to_byte_array())
	constants.append_array(PackedInt32Array([resolution, LEVELS, geometry_epoch,
		BLOCK_LAYOUT_VERSION]).to_byte_array())
	var succeeded := rd.buffer_update(parameters, 0, constants.size(), constants) == OK
	if succeeded:
		parameter_resolution = resolution
	return succeeded


func get_layout12_runtime_state() -> Dictionary:
	var chart_ready_count := 0
	for record_value in _layout12_geometry_records.values():
		var record: Dictionary = record_value
		chart_ready_count += int(record.get("charts", []).size())
	return {
		"layout_version": BLOCK_LAYOUT_VERSION,
		"operation_bits": {"write_charts": OP_WRITE_CHARTS,
			"write_summary": OP_WRITE_SUMMARY, "relight_cached": OP_RELIGHT_CACHED},
		"builder_key": _layout12_shader_key,
		"builder_ready": _layout12_builder_ready,
		"builder_failed": _layout12_builder_failed,
		"builder_progress": _layout12_builder_progress.duplicate(true),
		"cpu_index_ms_total": _layout12_index_ms_total,
		"cpu_update_ms_last": _layout12_cpu_last_ms,
		"cpu_ready_geometry_cells": _layout12_geometry_records.size(),
		"cpu_ready_chart_slots": chart_ready_count,
		"cpu_query_queue_cells": _layout12_cpu_queue.size(),
		"cpu_query_queue_peak": _layout12_cpu_queue_peak,
		"cpu_query_inflight": _layout12_query_started.size(),
		"cpu_geometry_record_peak": _layout12_cpu_record_peak,
		"cpu_geometry_records_pruned": _layout12_cpu_records_pruned,
		"cpu_queries_pruned_on_scroll": _layout12_cpu_queries_pruned,
		"cpu_ready_jobs_pruned_on_scroll": _layout12_ready_jobs_pruned,
		"cpu_failures_source_fallback": _layout12_failures,
		"gpu_chart_jobs_submitted": _layout12_gpu_chart_jobs_submitted,
		"gpu_chart_jobs_submitted_last_frame": _layout12_frame_chart_jobs_submitted_last,
		"requested_frame_job_budget_last": _layout12_frame_budget_last,
		"max_supported_frame_job_budget": MAX_FRAME_JOB_BUDGET,
		"max_jobs_per_gpu_batch": MAX_BLOCK_JOBS,
		"gpu_chart_write_jobs_submitted": _layout12_gpu_chart_write_jobs_submitted,
		"gpu_chart_relight_jobs_submitted": _layout12_gpu_chart_relight_jobs_submitted,
		"gpu_batches_submitted": _layout12_gpu_batches_submitted,
		"gpu_barriers_recorded": _layout12_gpu_barriers_recorded,
		"gpu_stage_dispatch_failures": _layout12_gpu_stage_dispatch_failures,
		"gpu_stage_upload_failures": _layout12_gpu_stage_upload_failures,
		"gpu_summary_clear_jobs_submitted": _layout12_gpu_summary_clear_jobs_submitted,
		"gpu_summary_clear_jobs_by_level": _layout12_gpu_summary_clear_level_counts.duplicate(),
		"gpu_summary_candidate_jobs_submitted": _layout12_gpu_summary_candidate_jobs_submitted,
		"gpu_summary_candidate_jobs_are_attempts": true,
		"cpu_summary_candidates_prepared": _layout12_summary_candidates_prepared,
		"cpu_summary_candidate_rejection_reasons": _layout12_summary_candidates_rejected.duplicate(true),
		"cpu_summary_geometry_memo_entries": _layout12_summary_geometry_memo.size(),
		"cpu_summary_geometry_memo_hits": _layout12_summary_memo_hits,
		"cpu_summary_geometry_memo_builds": _layout12_summary_memo_misses,
		"cpu_summary_geometry_memo_invalidations": _layout12_summary_memo_invalidations,
		"cpu_summary_waiting_for_geometry_corners": _layout12_summary_waiting_for_geometry_corners,
		"cpu_summary_waiting_for_current_slots": _layout12_summary_waiting_for_current_slots,
		"gpu_summary_candidate_slot_counts": _layout12_gpu_summary_slot_counts.duplicate(),
		"gpu_summary_candidate_mixed_jobs": _layout13_gpu_summary_mixed_jobs,
		"gpu_summary_candidate_jobs_by_level": _layout12_gpu_summary_candidate_level_counts.duplicate(),
		"summary_level_coverage": "same-level 8-corner neighborhoods at L0/L1/L2",
		"gpu_publication_readback": false,
		"gpu_consumer_visibility": "trailing compute-list barrier after final dispatched stage",
		"pending_scheduler_cells": maxi(0, _pending.size() - _cursor)
	}


static func estimate_block_gpu_bytes(requested_resolution := RESOLUTION) -> int:
	var selected_resolution := EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION else RESOLUTION
	var volume := selected_resolution * selected_resolution * selected_resolution * LEVELS
	var coefficient_bytes := volume * BLOCK_COLUMN_COUNT * BLOCK_RGBA32_TEXEL_BYTES
	var tag_bytes := volume * BLOCK_TAG_COLUMNS * BLOCK_RGBA32_TEXEL_BYTES
	var support_bytes := volume * BLOCK_SUPPORT_COLUMNS * 4
	var stage_jobs := MAX_BLOCK_JOBS + MAX_SUMMARY_JOBS * 2
	var record_bytes := stage_jobs * BLOCK_RECORD_BYTES
	var job_bytes := stage_jobs * JOB_RECORD_BYTES
	return coefficient_bytes + tag_bytes + support_bytes + BLOCK_PARAMETER_BUFFER_BYTES \
			+ record_bytes + job_bytes + FALLBACK_CLUSTER_BUFFER_BYTES \
			+ _stencil_buffer_bytes(selected_resolution)


func owned_rids() -> Array[RID]:
	return [texture, tags, support, parameters, sampler, _jobs, _records,
		_summary_clear_jobs, _summary_clear_records, _summary_jobs, _summary_records,
		_stencils, _probe_cluster_fallback, _pipeline, _shader]


func _cell_key(cell: Vector4i) -> String:
	return "%d:%d:%d:%d" % [cell.x, cell.y, cell.z, cell.w]


func _cell_from_key(key: String) -> Vector4i:
	var parts := key.split(":")
	if parts.size() != 4:
		return Vector4i(0x7fffffff, 0x7fffffff, 0x7fffffff, -1)
	return Vector4i(parts[0].to_int(), parts[1].to_int(), parts[2].to_int(), parts[3].to_int())


func _cell_inside_current_clip(cell: Vector4i) -> bool:
	return cell.w >= 0 and cell.w < _origins.size() \
			and _inside_clip(Vector3i(cell.x, cell.y, cell.z), _origins[cell.w])


func _prune_layout12_cpu_state() -> void:
	if _origins.size() != LEVELS:
		return
	for key_value in _layout12_query_started.keys().duplicate():
		var key := str(key_value)
		var cell := _cell_from_key(key)
		if _cell_inside_current_clip(cell):
			continue
		var query_state: Dictionary = _layout12_query_started[key]
		if _layout12_builder != null:
			_layout12_builder.forget_query(str(query_state.get("query_key", "")))
		_layout12_query_started.erase(key)
		_layout12_cpu_queries_pruned += 1
	var retained_queue: Array[Vector4i] = []
	_layout12_cpu_queue_set.clear()
	for cell in _layout12_cpu_queue:
		if not _cell_inside_current_clip(cell):
			continue
		retained_queue.append(cell)
		_layout12_cpu_queue_set[_cell_key(cell)] = true
	_layout12_cpu_queue = retained_queue
	for key_value in _layout12_ready_dispatch.keys().duplicate():
		var key := str(key_value)
		var cell: Vector4i = _layout12_ready_dispatch[key]
		if _cell_inside_current_clip(cell):
			continue
		_layout12_ready_dispatch.erase(key)
		_layout12_ready_jobs_pruned += 1
	for key_value in _layout12_geometry_records.keys().duplicate():
		var key := str(key_value)
		if _cell_inside_current_clip(_cell_from_key(key)):
			continue
		_layout12_geometry_records.erase(key)
		_layout12_cpu_records_pruned += 1
	for key_value in _layout12_summary_geometry_memo.keys().duplicate():
		var key := str(key_value)
		if _cell_inside_current_clip(_cell_from_key(key)):
			continue
		_layout12_summary_geometry_memo.erase(key)
		_layout12_summary_memo_invalidations += 1


func _release_partial_create(rd: RenderingDevice) -> void:
	for rid in owned_rids():
		if rid.is_valid():
			rd.free_rid(rid)
	texture = RID()
	tags = RID()
	support = RID()
	parameters = RID()
	sampler = RID()
	_jobs = RID()
	_records = RID()
	_summary_clear_jobs = RID()
	_summary_clear_records = RID()
	_summary_jobs = RID()
	_summary_records = RID()
	_stencils = RID()
	_probe_cluster_fallback = RID()
	_pipeline = RID()
	_shader = RID()


func _physical_slot_key(cell: Vector4i) -> String:
	var x := posmod(cell.x, resolution)
	var y := posmod(cell.y, resolution)
	var z := posmod(cell.z, resolution)
	return "%d:%d:%d:%d" % [x, y, z, cell.w]


func _inside_clip(cell: Vector3i, origin: Vector3i) -> bool:
	return cell.x >= origin.x and cell.x < origin.x + resolution \
			and cell.y >= origin.y and cell.y < origin.y + resolution \
			and cell.z >= origin.z and cell.z < origin.z + resolution


static func _block_texture(rd: RenderingDevice, format_value: int, columns: int,
		selected_resolution: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = format_value
	format.width = selected_resolution * columns
	format.height = selected_resolution
	format.depth = selected_resolution * LEVELS
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	if format_value == RenderingDevice.DATA_FORMAT_R32_UINT:
		format.usage_bits |= RenderingDevice.TEXTURE_USAGE_STORAGE_ATOMIC_BIT
	return rd.texture_create(format, RDTextureView.new(), [])
