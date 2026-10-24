@tool
extends "magic_gi_clv_cache.gd"
## Layout 17 cache: source asset stays SH27; runtime cells store the derived exact E/pi irradiance tensor.
## Pixel shading only samples these seven linearly filtered 3D textures.

const FieldShaderR32: RDShaderFile = preload("../library/magic-gi/magic_gi_baked_sh_clv_probe_block_field_fill.glsl")
const FieldShaderR16: RDShaderFile = preload("../library/magic-gi/magic_gi_baked_sh_clv_probe_block_field_fill_r16.glsl")
const MAGICDAWN_LAYOUT_VERSION := 17
const CLIPMAP_PARAMETER_BYTES := 96
const FIELD_TEXTURE_COUNT := 7
const FIELD_JOB_RECORD_BYTES := 48
const BOUNDARY_RECORD_BYTES := 128
const BOUNDARY_NO_RECORDS_SIGNATURE := "none"
const FIELD_TEXTURE_TEXEL_BYTES_R32 := 16
const FIELD_TEXTURE_TEXEL_BYTES_R16 := 8
const FIELD_TAG_BYTES := 16
const MAX_DISPATCHED_FIELD_JOBS := 65535
const HALF_MAX_SAFE_VALUE := 60000.0
const HALF_ROUND_TO_ZERO_LIMIT := 2.9802322387695312e-8
const DEFAULT_CODEC_R32 := Vector4(1.0, 1.0, 32.0, 1.0)

var field_images: Array[RID] = []
var _clear_jobs := RID()
var _slot_owners: Dictionary = {}
var _field_clear_dispatches := 0
var _field_fill_dispatches := 0
var _field_cleared_cells := 0
var _field_filled_cells := 0
var _scroll_count := 0
var _recycled_slot_scan_count := 0
var _field_job_capacity := 0
var _last_max_jobs_per_dispatch := MAX_DISPATCHED_FIELD_JOBS
var _codec := DEFAULT_CODEC_R32
var _field_format_tag := 32
var _field_format := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
var _format_fallback_reason := ""
var _last_camera_world := Vector3.ZERO
var _last_focus_world := Vector3.ZERO
var _last_focus_domain := AABB()
var _last_focus_report: Dictionary = {}
var _last_error := ""
var _boundary_tensor_records_buffer := RID()
var _boundary_tensor_record_index_by_cell: Dictionary = {}
var _boundary_tensor_records_signature := ""
var _boundary_tensor_records_format_tag := 0
var _boundary_tensor_refresh_pending := false
var _boundary_tensor_record_capacity := 0
var _boundary_tensor_buffer_bytes := 0
var _boundary_tensor_buffer_generation := 0
var _recycled_slots_dirty := false
var _full_reset_pending := false
var _identity_payload_signature := ""
var _identity_format_tag := 0
var _identity_codec := Vector4.ZERO
var _identity_digest := ""
var _uploaded_parameter_origins: Array[Vector3i] = []
var _uploaded_parameter_spacing := 0.0
var _uploaded_parameter_camera := Vector3.ZERO
var _uploaded_parameter_epoch := -1
var _uploaded_parameter_resolution := -1
var _uploaded_parameter_codec := Vector4.ZERO
var _parameter_upload_count := 0

func create(rd: RenderingDevice, requested_resolution := RESOLUTION,
		dynamic_transfer := false, emitter_count := 0,
		requested_format_tag := 16, requested_codec := Vector4(1.0, 1.0, 16.0, 1.0),
		boundary_record_count := 0) -> bool:
	if dynamic_transfer or emitter_count != 0:
		return false
	if boundary_record_count < 0 or boundary_record_count > 1048576:
		_last_error = "boundary_tensor_record_count_out_of_range"
		return false
	resolution = _select_resolution(requested_resolution)
	_field_job_capacity = resolution * resolution * resolution * LEVELS
	_boundary_tensor_record_capacity = boundary_record_count
	_boundary_tensor_buffer_bytes = maxi(boundary_record_count, 1) * BOUNDARY_RECORD_BYTES
	_jobs = rd.storage_buffer_create(_field_job_capacity * FIELD_JOB_RECORD_BYTES)
	_clear_jobs = rd.storage_buffer_create(_field_job_capacity * FIELD_JOB_RECORD_BYTES)
	var empty_boundary_records := PackedByteArray()
	empty_boundary_records.resize(_boundary_tensor_buffer_bytes)
	_boundary_tensor_records_buffer = rd.storage_buffer_create(
			_boundary_tensor_buffer_bytes, empty_boundary_records)
	_boundary_tensor_buffer_generation = 1 if _boundary_tensor_records_buffer.is_valid() else 0
	_probe_cluster_fallback = rd.storage_buffer_create(FALLBACK_CLUSTER_BUFFER_BYTES,
			PackedInt32Array([1, 0, 0, 0]).to_byte_array())
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler = rd.sampler_create(state)
	parameters = rd.uniform_buffer_create(CLIPMAP_PARAMETER_BYTES)
	_uploaded_parameter_origins.clear()
	_last_max_jobs_per_dispatch = _max_dispatched_job_count(rd)
	if not _common_resources_valid():
		_last_error = "common_resource_creation_failed"
		return false
	var try_r16 := requested_format_tag == 16 and _valid_r16_codec(requested_codec)
	if try_r16 and _create_field_format_resources(rd, 16, requested_codec):
		_last_error = ""
		return true
	if try_r16:
		_format_fallback_reason = _last_error if not _last_error.is_empty() \
				else "r16_field_resource_creation_failed"
		_free_field_format_resources(rd)
	if requested_format_tag != 16 and requested_format_tag != 32:
		_last_error = "unsupported_field_format_tag:%d" % requested_format_tag
		return false
	if not _create_field_format_resources(rd, 32, DEFAULT_CODEC_R32):
		if _last_error.is_empty():
			_last_error = "r32_field_resource_creation_failed"
		return false
	_last_error = ""
	return true

func _common_resources_valid() -> bool:
	return _jobs.is_valid() and _clear_jobs.is_valid() \
			and _probe_cluster_fallback.is_valid() and sampler.is_valid() \
			and _boundary_tensor_records_buffer.is_valid() \
			and parameters.is_valid()

func _create_field_format_resources(rd: RenderingDevice, format_tag: int,
		codec: Vector4) -> bool:
	var rd_format := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT \
			if format_tag == 16 else RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	if not rd.texture_is_format_supported_for_usage(rd_format, usage):
		_last_error = "field_format_usage_unsupported:%d" % format_tag
		return false
	var extent := resolution + 1
	for _index in FIELD_TEXTURE_COUNT:
		field_images.append(_create_3d_texture(rd, rd_format,
				Vector3i(extent, extent, LEVELS * extent)))
	texture = field_images[0] if not field_images.is_empty() else RID()
	tags = _create_3d_texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT,
			Vector3i(resolution, resolution, LEVELS * resolution))
	support = _create_3d_texture(rd, RenderingDevice.DATA_FORMAT_R32_UINT,
			Vector3i(resolution, resolution, LEVELS * resolution))
	if field_images.size() != FIELD_TEXTURE_COUNT \
			or field_images.any(func(value: RID) -> bool: return not value.is_valid()) \
			or not tags.is_valid() or not support.is_valid():
		_last_error = "field_texture_creation_failed:%d" % format_tag
		return false
	var expected_format := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT \
			if format_tag == 16 else RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	for image in field_images:
		var actual_format := rd.texture_get_format(image)
		if actual_format.format != expected_format \
				or actual_format.width != extent or actual_format.height != extent \
				or actual_format.depth != LEVELS * extent:
			_last_error = "field_texture_format_validation_failed:%d" % format_tag
			return false
	var shader_resource := FieldShaderR16 if format_tag == 16 else FieldShaderR32
	var spirv := shader_resource.get_spirv()
	if spirv == null or shader_resource.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		_last_error = "producer_shader_compile_error:%d" % format_tag
		return false
	_shader = rd.shader_create_from_spirv(spirv,
			"Magic GI CLV Baked SH Block Fill Layout 17 Format %d" % format_tag)
	if _shader.is_valid():
		_pipeline = rd.compute_pipeline_create(_shader)
	if not _shader.is_valid() or not _pipeline.is_valid():
		_last_error = "producer_pipeline_creation_failed:%d" % format_tag
		return false
	for image in field_images:
		if rd.texture_clear(image, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
			_last_error = "field_texture_clear_failed:%d" % format_tag
			return false
	if rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK \
			or rd.texture_clear(support, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
		_last_error = "tag_support_clear_failed"
		return false
	_field_format_tag = format_tag
	_field_format = rd_format
	_codec = codec
	return true

func _free_field_format_resources(rd: RenderingDevice) -> void:
	if _pipeline.is_valid():
		rd.free_rid(_pipeline)
	_pipeline = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
	_shader = RID()
	for image in field_images:
		if image.is_valid():
			rd.free_rid(image)
	field_images.clear()
	texture = RID()
	for rid in [tags, support]:
		if rid.is_valid():
			rd.free_rid(rid)
	tags = RID()
	support = RID()

static func _select_resolution(requested_resolution: int) -> int:
	if requested_resolution >= 32:
		return 32
	if requested_resolution >= 24:
		return 24
	return 16

static func _valid_r16_codec(codec: Vector4) -> bool:
	return is_finite(codec.x) and codec.x > 0.0 \
			and is_finite(codec.y) and codec.y > 0.0 \
			and is_finite(codec.z) and codec.z == 16.0 \
			and is_finite(codec.w) and codec.w == 1.0 \
			and is_finite(codec.x * codec.y) \
			and absf(codec.x * codec.y - 1.0) <= 2e-6

static func choose_codec(source: PackedFloat32Array) -> Dictionary:
	if source.is_empty():
		return {"valid": false, "error": "baked_sh_empty"}
	var max_abs := 0.0
	var min_nonzero := INF
	for value in source:
		if not is_finite(value):
			return {"valid": false, "error": "baked_sh_nonfinite"}
		var magnitude := absf(value)
		max_abs = maxf(max_abs, magnitude)
		if magnitude > 0.0:
			min_nonzero = minf(min_nonzero, magnitude)
	var scale := 1.0
	if max_abs > 0.0:
		var target_scale := maxf(1.0, max_abs / HALF_MAX_SAFE_VALUE)
		var exponent := ceili(log(target_scale) / log(2.0))
		scale = pow(2.0, float(maxi(exponent, 0)))
		while max_abs / scale > HALF_MAX_SAFE_VALUE:
			scale *= 2.0
	var inverse_scale := 1.0 / scale
	if not is_finite(scale) or scale <= 0.0 \
			or not is_finite(inverse_scale) or inverse_scale <= 0.0:
		return {"valid": true, "codec": DEFAULT_CODEC_R32,
			"format_tag": 32, "fallback_reason": "fp16_scale_not_representable",
			"max_abs": max_abs, "min_nonzero_abs": min_nonzero}
	if min_nonzero < INF and min_nonzero * inverse_scale <= HALF_ROUND_TO_ZERO_LIMIT:
		return {"valid": true, "codec": DEFAULT_CODEC_R32,
			"format_tag": 32, "fallback_reason": "fp16_nonzero_underflow_risk",
			"max_abs": max_abs, "min_nonzero_abs": min_nonzero}
	var codec := Vector4(scale, inverse_scale, 16.0, 1.0)
	return {"valid": true, "codec": codec, "format_tag": 16,
		"fallback_reason": "", "max_abs": max_abs,
		"min_nonzero_abs": min_nonzero}

static func estimate_field_gpu_bytes(requested_resolution := RESOLUTION,
		format_tag := 16, boundary_record_count := 0) -> int:
	var selected := _select_resolution(requested_resolution)
	var texel_bytes := FIELD_TEXTURE_TEXEL_BYTES_R16 \
			if format_tag == 16 else FIELD_TEXTURE_TEXEL_BYTES_R32
	var extent := selected + 1
	var texels := extent * extent * LEVELS * extent
	var fields := FIELD_TEXTURE_COUNT * texels * texel_bytes
	var tags_bytes := selected * selected * LEVELS * selected * FIELD_TAG_BYTES
	var support_bytes := selected * selected * LEVELS * selected * 4
	return fields + tags_bytes + support_bytes + CLIPMAP_PARAMETER_BYTES \
			+ selected * selected * selected * LEVELS * FIELD_JOB_RECORD_BYTES * 2 \
			+ FALLBACK_CLUSTER_BUFFER_BYTES \
			+ maxi(boundary_record_count, 1) * BOUNDARY_RECORD_BYTES

func update(rd: RenderingDevice, camera: Vector3, base_spacing: float,
		geometry_epoch: int, content_revision: int, bake: Dictionary,
		directional: RefCounted, ubo: RID, nearest_sampler: RID, budget := 256,
		approximate_volume_enabled := false,
		exact_corner_visibility_enabled := false,
		approximate_ready_bit_enabled := false,
		dynamic_transfer := false,
		camera_world_position := Vector3.ZERO,
		focus_domain_bounds := AABB(), focus_report := {}) -> bool:
	if dynamic_transfer:
		return false
	if approximate_volume_enabled or exact_corner_visibility_enabled \
			or approximate_ready_bit_enabled or not _pipeline.is_valid():
		_last_error = "unsupported_optional_clv_feature"
		return false
	var raw_value: Variant = directional.get("baked_indirect_lighting") if directional != null else null
	var moments_value: Variant = bake.get("visibility_moments", RID())
	if not raw_value is RID or not moments_value is RID:
		_last_error = "missing_baked_sh_or_visibility_moments"
		return false
	var raw: RID = raw_value
	var moments: RID = moments_value
	if not raw.is_valid() or not moments.is_valid():
		_last_error = "invalid_baked_sh_or_visibility_moments"
		return false
	if not _ensure_boundary_tensor_records(rd, bake):
		_last_error = "boundary_tensor_record_buffer_prepare_failed"
		return false
	var old_origins := _origins.duplicate()
	var geometry_changed := _full_reset_pending or _origins.is_empty() \
			or _geometry_epoch != geometry_epoch \
			or not is_equal_approx(_spacing, base_spacing)
	if geometry_changed:
		_full_reset_pending = true
	queue_updates(camera, base_spacing, geometry_epoch)
	var origins_changed := old_origins != _origins
	if origins_changed and not geometry_changed:
		_recycled_slots_dirty = true
	if not _write_parameters(rd, base_spacing, geometry_epoch, camera_world_position):
		_last_error = "clipmap_parameter_upload_failed"
		return false
	if not old_origins.is_empty() and origins_changed:
		_scroll_count += 1
	_last_camera_world = camera_world_position
	_last_focus_world = camera
	_last_focus_domain = focus_domain_bounds
	_last_focus_report = focus_report.duplicate(true)
	if geometry_changed:
		if not _clear_all_fields(rd):
			_last_error = "full_field_clear_failed"
			return false
		# Every current cell is now known-zero; record ownership so a still-pending
		# initial fill does not trigger redundant per-cell clear dispatches. Do not
		# allocate a second 98,304-cell array just to populate this dictionary.
		# The reset already queued every current cell; those jobs consume this
		# content and boundary snapshot, so the two additional full-window sweeps
		# would only revisit cells deduplicated by _pending_set.
		_record_full_reset_slot_owners()
		_queue_refreshes_after_origin_update(true, content_revision)
		_recycled_slots_dirty = false
		_full_reset_pending = false
	else:
		_queue_refreshes_after_origin_update(false, content_revision)
	var clear_cells := _collect_recycled_slots_for_update(origins_changed, geometry_changed)
	var selected := take_jobs(clampi(budget, 1, MAX_JOBS))
	if not _dispatch_clear_and_fill(rd, clear_cells, selected, base_spacing,
			geometry_epoch, bake, directional, ubo, nearest_sampler):
		requeue_jobs(selected)
		_last_error = "recycled_slot_or_field_fill_dispatch_failed"
		return false
	for cell in clear_cells:
		_slot_owners[_slot_key(cell)] = cell
	for cell in selected:
		_slot_owners[_slot_key(cell)] = cell
		_field_filled_cells += 1
	_commit_recycled_slot_scan()
	_last_error = ""
	return true

func get_field_textures() -> Array[RID]:
	return field_images.duplicate()

func get_layout16_runtime_state() -> Dictionary:
	var pending_count := maxi(_pending.size() - _cursor, 0)
	var bytes_per_texel := FIELD_TEXTURE_TEXEL_BYTES_R16 \
			if _field_format_tag == 16 else FIELD_TEXTURE_TEXEL_BYTES_R32
	var format_name := "R16G16B16A16_SFLOAT" if _field_format_tag == 16 \
			else "R32G32B32A32_SFLOAT"
	return {
		"layout_version": MAGICDAWN_LAYOUT_VERSION,
		"clipmap_parameter_bytes": CLIPMAP_PARAMETER_BYTES,
		"codec": _codec,
		"format_tag": _field_format_tag,
		"format_fallback_reason": _format_fallback_reason,
		"field_texture_count": FIELD_TEXTURE_COUNT,
		"field_texture_dimensions": [resolution + 1, resolution + 1,
				LEVELS * (resolution + 1)],
		"field_texture_format": format_name,
		"field_bytes_per_cell": FIELD_TEXTURE_COUNT * bytes_per_texel,
		"field_gpu_bytes_estimate": estimate_field_gpu_bytes(resolution,
				_field_format_tag, _boundary_tensor_record_capacity),
		"boundary_tensor_record_count": _boundary_tensor_record_capacity,
		"boundary_tensor_buffer_bytes": _boundary_tensor_buffer_bytes,
		"boundary_tensor_buffer_generation": _boundary_tensor_buffer_generation,
		"texture_count_valid": field_images.size() == FIELD_TEXTURE_COUNT,
		"texture_rids_valid": field_images.size() == FIELD_TEXTURE_COUNT \
				and field_images.all(func(value: RID) -> bool: return value.is_valid()),
		"geometry_epoch": _geometry_epoch,
		"content_revision": _content_revision,
		"spacing_m": _spacing,
		"origins_cells": _origins.duplicate(),
		"camera_world_position": [_last_camera_world.x, _last_camera_world.y,
				_last_camera_world.z],
		"focus_world_position": [_last_focus_world.x, _last_focus_world.y,
				_last_focus_world.z],
		"focus_domain_position": [_last_focus_domain.position.x,
				_last_focus_domain.position.y, _last_focus_domain.position.z],
		"focus_domain_size": [_last_focus_domain.size.x,
				_last_focus_domain.size.y, _last_focus_domain.size.z],
		"focus_strategy": str(_last_focus_report.get("strategy", "unavailable")),
		"focus_domain_valid": bool(_last_focus_report.get("valid", false)),
		"domain_fits_full_coverage": bool(_last_focus_report.get("domain_fits_full_coverage", false)),
		"outer_step_m": float(_last_focus_report.get("outer_step_m", 0.0)),
		"outer_fade_width_m": float(_last_focus_report.get("outer_fade_width_m", 0.0)),
		"full_coverage_span_m": float(_last_focus_report.get("full_coverage_span_m", 0.0)),
		"safe_fit_span_m": float(_last_focus_report.get("safe_fit_span_m", 0.0)),
		"scroll_count": _scroll_count,
		"recycled_slot_scan_count": _recycled_slot_scan_count,
		"pending_fill_cells": pending_count,
		"host_submitted_slot_count": _slot_owners.size(),
		"expected_current_slot_count": resolution * resolution * resolution * LEVELS,
		"clear_dispatch_count": _field_clear_dispatches,
		"clear_cell_count": _field_cleared_cells,
		"fill_dispatch_count": _field_fill_dispatches,
		"fill_cell_count": _field_filled_cells,
		"field_job_capacity": _field_job_capacity,
		"field_job_bytes_each": _field_job_capacity * FIELD_JOB_RECORD_BYTES,
		"max_jobs_per_dispatch": _last_max_jobs_per_dispatch,
		"parameter_upload_count": _parameter_upload_count,
		"gpu_ready_readback": false,
		"ready_semantics": "host_submitted_after_compute_dispatch_only",
		"last_error": _last_error,
	}

## Center the three clipmap levels on the baked receiver domain when that domain
## fits inside the coarsest safe sampling window. If it is larger, keep the
## camera-nearest window inside the domain while maximizing covered extent.
## The safety margin accounts for origin quantization and the shader's trilinear
## interior requirement; base density and all cascade step sizes stay unchanged.
static func focus_for_baked_domain(camera: Vector3, bounds: AABB, spacing: float,
		requested_resolution := RESOLUTION) -> Dictionary:
	var safe_spacing := spacing if is_finite(spacing) and spacing > 0.0 else 0.001
	var selected_resolution := _select_resolution(requested_resolution)
	var outer_step := safe_spacing * float(1 << (LEVELS - 1))
	var window_span := float(maxi(selected_resolution - 3, 2)) * outer_step
	var half_extent := 0.5 * float(maxi(selected_resolution - 3, 2)) * outer_step
	var fade_width := maxf(2.0 * outer_step, 0.15 * half_extent)
	var full_coverage_span := maxf(window_span - 2.0 * fade_width, 0.0)
	# Leave half a coarse cell at both ends for the discrete floor(origin) snap.
	var fit_half_span := maxf((full_coverage_span - outer_step) * 0.5, 0.0)
	var focus := Vector3.ZERO
	var domain_fits_full_coverage := true
	for axis in 3:
		var bound_start := bounds.position[axis]
		var bound_end := bounds.position[axis] + bounds.size[axis]
		if not is_finite(bound_start) or not is_finite(bound_end):
			return {"valid": false, "strategy": "invalid_world_space_domain"}
		var lower_bound := minf(bound_start, bound_end)
		var upper_bound := maxf(bound_start, bound_end)
		var center := (lower_bound + upper_bound) * 0.5
		var lower_focus := lower_bound + fit_half_span
		var upper_focus := upper_bound - fit_half_span
		var candidate := center
		var axis_fits := upper_bound - lower_bound <= fit_half_span * 2.0
		if not axis_fits:
			domain_fits_full_coverage = false
		if not axis_fits and lower_focus <= upper_focus \
				and is_finite(camera[axis]):
			candidate = clampf(camera[axis], lower_focus, upper_focus)
		focus[axis] = floor(candidate / outer_step + 0.5) * outer_step
	return {"valid": true, "strategy": "baked_domain_center_or_nearest_camera_fit",
		"focus_world": focus, "domain_fits_full_coverage": domain_fits_full_coverage,
		"outer_step_m": outer_step, "outer_fade_width_m": fade_width,
		"full_coverage_span_m": full_coverage_span,
		"safe_fit_span_m": fit_half_span * 2.0,
		"domain_size_m": bounds.size}

func _queue_refreshes_after_origin_update(geometry_changed: bool,
		content_revision: int) -> void:
	if geometry_changed:
		_content_revision = content_revision
		_boundary_tensor_refresh_pending = false
		return
	queue_content_refresh(content_revision)
	if _boundary_tensor_refresh_pending:
		_queue_boundary_tensor_refresh()

func _record_full_reset_slot_owners() -> void:
	_slot_owners.clear()
	for level in LEVELS:
		var origin: Vector3i = _origins[level]
		for z in range(resolution):
			for y in range(resolution):
				for x in range(resolution):
					var cell := Vector4i(origin.x + x, origin.y + y,
						origin.z + z, level)
					_slot_owners[_slot_key(cell)] = cell

func _collect_recycled_slots_for_update(origins_changed: bool,
		geometry_changed: bool) -> Array[Vector4i]:
	if geometry_changed:
		_recycled_slots_dirty = false
		return []
	if origins_changed:
		_recycled_slots_dirty = true
	if not _recycled_slots_dirty:
		return []
	return _collect_recycled_slots()

func _commit_recycled_slot_scan() -> void:
	_recycled_slots_dirty = false

func _collect_recycled_slots() -> Array[Vector4i]:
	_recycled_slot_scan_count += 1
	var clear: Array[Vector4i] = []
	for index in range(_cursor, _pending.size()):
		var cell: Vector4i = _pending[index]
		if cell.w < 0 or cell.w >= LEVELS \
				or not _contains(_origins[cell.w], Vector3i(cell.x, cell.y, cell.z), resolution):
			continue
		var slot_key := _slot_key(cell)
		var owner: Variant = _slot_owners.get(slot_key)
		if owner is Vector4i and owner == cell:
			continue
		clear.append(cell)
	return clear

func _dispatch_clear_and_fill(rd: RenderingDevice, clear_cells: Array[Vector4i],
		fill_cells: Array[Vector4i], base_spacing: float, geometry_epoch: int,
		bake: Dictionary, directional: RefCounted, ubo: RID,
		nearest_sampler: RID) -> bool:
	if clear_cells.is_empty() and fill_cells.is_empty():
		return true
	# Dispatch x is one workgroup per cell. Split the expanded 32^3×3 grid by the
	# active device's maxComputeWorkGroupCount[0].
	# Each batch is its own list, so its buffer update and clear/fill ordering are
	# visible before the next batch is submitted.
	if not _dispatch_job_batches(rd, clear_cells, _clear_jobs, base_spacing,
			geometry_epoch, bake, directional, ubo, nearest_sampler, true):
		return false
	if not _dispatch_job_batches(rd, fill_cells, _jobs, base_spacing,
			geometry_epoch, bake, directional, ubo, nearest_sampler, false):
		return false
	return true

func _dispatch_job_batches(rd: RenderingDevice, cells: Array[Vector4i],
		jobs_buffer: RID, base_spacing: float, geometry_epoch: int,
		bake: Dictionary, directional: RefCounted, ubo: RID,
		nearest_sampler: RID, clear_only: bool) -> bool:
	var offset := 0
	var max_batch := _last_max_jobs_per_dispatch
	while offset < cells.size():
		var count := mini(max_batch, cells.size() - offset)
		var batch: Array[Vector4i] = cells.slice(offset, offset + count)
		if not _upload_jobs(rd, jobs_buffer, batch, base_spacing, clear_only):
			return false
		var uniform_set := _producer_uniforms(rd, jobs_buffer, bake, directional,
				ubo, nearest_sampler)
		if not uniform_set.is_valid():
			return false
		var list := rd.compute_list_begin()
		if list < 0:
			return false
		rd.compute_list_bind_compute_pipeline(list, _pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		var push := _push_constants(count, base_spacing, geometry_epoch)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, count, 1, 1)
		# CLEAR writes all seven coefficients, coverage, tags and support before
		# any FILL can publish the recycled logical cell.
		rd.compute_list_add_barrier(list)
		rd.compute_list_end()
		if clear_only:
			_field_clear_dispatches += 1
			_field_cleared_cells += count
		else:
			_field_fill_dispatches += 1
		offset += count
	return true

func _max_dispatched_job_count(rd: RenderingDevice) -> int:
	var maximum := MAX_DISPATCHED_FIELD_JOBS
	const LIMIT_NAME := &"LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X"
	if ClassDB.class_has_integer_constant(&"RenderingDevice", LIMIT_NAME):
		var limit_id := ClassDB.class_get_integer_constant(&"RenderingDevice", LIMIT_NAME)
		var device_limit := int(rd.limit_get(limit_id))
		if device_limit > 0:
			maximum = mini(maximum, device_limit)
	return maxi(maximum, 1)

func _upload_jobs(rd: RenderingDevice, target: RID, cells: Array[Vector4i],
		base_spacing: float, clear_only: bool) -> bool:
	if cells.is_empty():
		return true
	if cells.size() > _field_job_capacity:
		return false
	var bytes := _pack_job_records(cells, base_spacing, clear_only)
	return bytes.size() == cells.size() * FIELD_JOB_RECORD_BYTES \
			and rd.buffer_update(target, 0, bytes.size(), bytes) == OK

func _pack_job_records(cells: Array[Vector4i], base_spacing: float,
		clear_only: bool) -> PackedByteArray:
	# Write the existing 48-byte GPU ABI directly. This avoids three temporary
	# packed arrays and repeated growing/concatenating of the destination per cell.
	var bytes := PackedByteArray()
	bytes.resize(cells.size() * FIELD_JOB_RECORD_BYTES)
	var offset := 0
	for cell in cells:
		var step := base_spacing * float(1 << cell.w)
		var center := (Vector3(cell.x, cell.y, cell.z) + Vector3.ONE * 0.5) * step
		bytes.encode_float(offset, center.x)
		bytes.encode_float(offset + 4, center.y)
		bytes.encode_float(offset + 8, center.z)
		bytes.encode_float(offset + 12, -step if clear_only else step)
		bytes.encode_s32(offset + 16, cell.x)
		bytes.encode_s32(offset + 20, cell.y)
		bytes.encode_s32(offset + 24, cell.z)
		bytes.encode_s32(offset + 28, cell.w)
		var record_index := int(_boundary_tensor_record_index_by_cell.get(cell, 0)) \
				if not clear_only else 0
		bytes.encode_s32(offset + 32, record_index)
		# resize() initializes the final three padding words to zero.
		offset += FIELD_JOB_RECORD_BYTES
	return bytes

func _push_constants(job_count: int, base_spacing: float,
		geometry_epoch: int) -> PackedByteArray:
	var push := PackedInt32Array([job_count, resolution, geometry_epoch]).to_byte_array()
	push.append_array(PackedFloat32Array([base_spacing]).to_byte_array())
	return push

func _producer_uniforms(rd: RenderingDevice, jobs_buffer: RID, bake: Dictionary,
		directional: RefCounted, ubo: RID, nearest_sampler: RID) -> RID:
	var geometry: RID = bake.get("geometry", RID())
	var indices: RID = bake.get("indices", RID())
	var nodes: RID = bake.get("visibility_nodes", RID())
	var triangles: RID = bake.get("visibility_triangles", RID())
	var entries: RID = bake.get("index_entries", RID())
	var clusters: RID = _cluster_buffer(bake)
	var moments: RID = bake.get("visibility_moments", RID())
	var raw: RID = directional.get("baked_indirect_lighting")
	if not geometry.is_valid() or not indices.is_valid() or not nodes.is_valid() \
			or not triangles.is_valid() or not entries.is_valid() \
			or not clusters.is_valid() or not moments.is_valid() \
			or not raw.is_valid() or not ubo.is_valid():
		return RID()
	if not _boundary_tensor_records_buffer.is_valid():
		return RID()
	var uniforms: Array[RDUniform] = [
		U.sampled(0, nearest_sampler, geometry), U.sampled(1, nearest_sampler, indices),
		U.storage_buffer(2, nodes), U.storage_buffer(3, triangles),
		U.storage_buffer(4, raw), U.storage_buffer(5, jobs_buffer),
	]
	for image_index in FIELD_TEXTURE_COUNT:
		uniforms.append(U.image(6 + image_index, field_images[image_index]))
	uniforms.append_array([
		U.image(13, tags), U.uniform_buffer(14, ubo), U.storage_buffer(15, entries),
		U.storage_buffer(16, clusters), U.image(17, support),
		U.sampled(18, nearest_sampler, moments), U.uniform_buffer(19, parameters),
		U.storage_buffer(20, _boundary_tensor_records_buffer),
	])
	return UniformSetCacheRD.get_cache(_shader, 0, uniforms)

func _current_cells() -> Array[Vector4i]:
	var cells: Array[Vector4i] = []
	for level in LEVELS:
		var origin: Vector3i = _origins[level]
		for z in range(resolution):
			for y in range(resolution):
				for x in range(resolution):
					cells.append(Vector4i(origin.x + x, origin.y + y, origin.z + z, level))
	return cells

func _clear_all_fields(rd: RenderingDevice) -> bool:
	for image in field_images:
		if rd.texture_clear(image, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
			return false
	return rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1) == OK \
			and rd.texture_clear(support, Color(0, 0, 0, 0), 0, 1, 0, 1) == OK

func _write_parameters(rd: RenderingDevice, base_spacing: float, geometry_epoch: int,
		camera_world_position: Vector3) -> bool:
	if _origins.size() != LEVELS:
		return false
	if parameters.is_valid() and _parameters_are_current(base_spacing, geometry_epoch,
			camera_world_position):
		return true
	var bytes := PackedByteArray()
	for origin in _origins:
		bytes.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	bytes.append_array(PackedFloat32Array([base_spacing, camera_world_position.x,
			camera_world_position.y, camera_world_position.z]).to_byte_array())
	bytes.append_array(PackedInt32Array([resolution, LEVELS, geometry_epoch,
			MAGICDAWN_LAYOUT_VERSION]).to_byte_array())
	bytes.append_array(PackedFloat32Array([_codec.x, _codec.y,
			_codec.z, _codec.w]).to_byte_array())
	if bytes.size() != CLIPMAP_PARAMETER_BYTES \
			or rd.buffer_update(parameters, 0, bytes.size(), bytes) != OK:
		return false
	parameter_resolution = resolution
	_record_parameter_upload(base_spacing, geometry_epoch, camera_world_position)
	return true

func _parameters_are_current(base_spacing: float, geometry_epoch: int,
		camera_world_position: Vector3) -> bool:
	return _uploaded_parameter_origins == _origins \
			and _uploaded_parameter_spacing == base_spacing \
			and _uploaded_parameter_camera == camera_world_position \
			and _uploaded_parameter_epoch == geometry_epoch \
			and _uploaded_parameter_resolution == resolution \
			and _uploaded_parameter_codec == _codec

func _record_parameter_upload(base_spacing: float, geometry_epoch: int,
		camera_world_position: Vector3) -> void:
	# Called only after a successful buffer update; a failed upload remains dirty.
	_uploaded_parameter_origins = _origins.duplicate()
	_uploaded_parameter_spacing = base_spacing
	_uploaded_parameter_camera = camera_world_position
	_uploaded_parameter_epoch = geometry_epoch
	_uploaded_parameter_resolution = resolution
	_uploaded_parameter_codec = _codec
	_parameter_upload_count += 1

func _ensure_boundary_tensor_records(rd: RenderingDevice, bake: Dictionary) -> bool:
	var payload_value: Variant = bake.get("boundary_tensor_records_payload", {})
	var payload: Dictionary = payload_value if payload_value is Dictionary else {}
	var valid := payload_value is Dictionary and bool(payload.get("valid", false))
	var signature := String(payload.get("signature", "")) if valid else ""
	if signature.is_empty():
		valid = false
	var payload_identity := signature if valid else BOUNDARY_NO_RECORDS_SIGNATURE
	var target_identity := _boundary_tensor_cache_identity(payload_identity)
	if target_identity.is_empty():
		return false
	if target_identity == _boundary_tensor_records_signature \
			and _boundary_tensor_records_format_tag == _field_format_tag \
			and _boundary_tensor_records_buffer.is_valid():
		return true
	var old_identity := _boundary_tensor_records_signature
	var old_format_tag := _boundary_tensor_records_format_tag
	var bytes := PackedByteArray()
	var record_index_by_cell: Dictionary = {}
	if valid:
		var keys_value: Variant = payload.get("keys", null)
		var coefficients_value: Variant = payload.get("coefficients", null)
		if not keys_value is PackedInt32Array or not coefficients_value is PackedFloat32Array:
			valid = false
		else:
			var keys: PackedInt32Array = keys_value
			var coefficients: PackedFloat32Array = coefficients_value
			var record_count := keys.size() / 4
			if keys.size() % 4 != 0 or coefficients.size() != record_count * 27:
				valid = false
			else:
				for record_index in record_count:
					var key_offset := record_index * 4
					var level := keys[key_offset]
					var x := keys[key_offset + 1]
					var y := keys[key_offset + 2]
					var z := keys[key_offset + 3]
					var cell_key := Vector4i(x, y, z, level)
					if level < 0 or level >= LEVELS or record_index_by_cell.has(cell_key):
						valid = false
						break
					var value_offset := record_index * 27
					var t := PackedFloat32Array()
					for component in 27:
						var value := coefficients[value_offset + component]
						var encoded_value := value * _codec.y
						if not is_finite(value) or not is_finite(encoded_value) \
								or (_field_format_tag == 16 \
								and absf(encoded_value) > HALF_MAX_SAFE_VALUE):
							valid = false
							break
						t.append(value)
					if not valid:
						break
					var packed := PackedFloat32Array([
						t[0], t[1], t[2], t[18],
						t[9], t[10], t[11], t[19],
						t[3], t[4], t[5], t[20],
						t[12], t[13], t[14], t[21],
						t[6], t[7], t[8], t[22],
						t[15], t[16], t[17], t[23],
						t[24], t[25], t[26], 0.0])
					bytes.append_array(PackedInt32Array([x, y, z, level]).to_byte_array())
					bytes.append_array(packed.to_byte_array())
					record_index_by_cell[cell_key] = record_index + 1
	if not valid:
		bytes.clear()
		record_index_by_cell.clear()
		# Invalid or absent optional records select the original gather path; do not
		# disable the field cache. Binding 20 still needs a valid empty SSBO.
		bytes.resize(BOUNDARY_RECORD_BYTES)
	elif bytes.is_empty():
		# A valid empty record set is a no-op, but still needs the binding.
		bytes.resize(BOUNDARY_RECORD_BYTES)
	if bytes.is_empty() or bytes.size() % BOUNDARY_RECORD_BYTES != 0:
		return false
	if _boundary_tensor_records_buffer.is_valid() \
			and bytes.size() == _boundary_tensor_buffer_bytes:
		if rd.buffer_update(_boundary_tensor_records_buffer, 0, bytes.size(), bytes) != OK:
			return false
	else:
		var new_buffer := rd.storage_buffer_create(bytes.size(), bytes)
		if not new_buffer.is_valid():
			return false
		if _boundary_tensor_records_buffer.is_valid():
			rd.free_rid(_boundary_tensor_records_buffer)
		_boundary_tensor_records_buffer = new_buffer
		_boundary_tensor_buffer_generation += 1
	_boundary_tensor_buffer_bytes = bytes.size()
	_boundary_tensor_record_capacity = record_index_by_cell.size() if valid else 0
	_boundary_tensor_record_index_by_cell = record_index_by_cell
	# Cache both accepted records and a rejected/absent payload identity. Without
	# this, a missing sidecar would rebuild the empty SSBO and enqueue the whole
	# clipmap window on every update.
	_boundary_tensor_records_signature = target_identity
	_boundary_tensor_records_format_tag = _field_format_tag
	if old_identity != _boundary_tensor_records_signature \
			or old_format_tag != _boundary_tensor_records_format_tag:
		_boundary_tensor_refresh_pending = true
	return true

func _boundary_tensor_cache_identity(payload_signature: String) -> String:
	# The payload signature is already the authoritative immutable bake identity.
	# Reuse its context digest until either that signature or the field codec changes.
	if not _identity_digest.is_empty() \
			and _identity_payload_signature == payload_signature \
			and _identity_format_tag == _field_format_tag and _identity_codec == _codec:
		return _identity_digest
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(payload_signature.to_utf8_buffer())
	context.update(PackedInt32Array([_field_format_tag]).to_byte_array())
	context.update(PackedFloat32Array([_codec.x, _codec.y, _codec.z, _codec.w]).to_byte_array())
	var digest := context.finish().hex_encode()
	_identity_payload_signature = payload_signature
	_identity_format_tag = _field_format_tag
	_identity_codec = _codec
	_identity_digest = digest
	return digest

func _queue_boundary_tensor_refresh() -> void:
	if _origins.size() != LEVELS:
		return
	for level in LEVELS:
		var origin := _origins[level]
		_enqueue_box(origin, origin + Vector3i.ONE * resolution, level)
	_boundary_tensor_refresh_pending = false

func owned_rids() -> Array[RID]:
	# Base owns the shared first field as `texture`; remove it before appending all
	# seven fields so it is released once. Keep the inherited pipeline-before-shader
	# order required by RD teardown.
	var rids: Array[RID] = super.owned_rids()
	rids.erase(texture)
	rids.append_array(field_images)
	rids.append(_clear_jobs)
	rids.append(_boundary_tensor_records_buffer)
	return rids

func _slot_key(cell: Vector4i) -> int:
	var px := posmod(cell.x, resolution)
	var py := posmod(cell.y, resolution)
	var pz := posmod(cell.z, resolution)
	return ((cell.w * resolution + pz) * resolution + py) * resolution + px

static func _create_3d_texture(rd: RenderingDevice, format_value: int,
		dimensions: Vector3i) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = format_value
	format.width = dimensions.x
	format.height = dimensions.y
	format.depth = dimensions.z
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return rd.texture_create(format, RDTextureView.new(), [])
