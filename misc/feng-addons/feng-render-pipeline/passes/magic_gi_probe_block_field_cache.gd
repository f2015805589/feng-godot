@tool
extends "magic_gi_clv_cache.gd"
## Layout-14 falsification cache. This stores a normal-independent SH field and
## deliberately falls back to the existing source gather on any stale tag or
## unsupported stream; it is not an authored backend.

const FIELD_FILL_SHADER_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_probe_block_field_fill.glsl"

const FIELD_LAYOUT_VERSION := 14
const FIELD_COLUMN_COUNT := 18
const FIELD_JOB_RECORD_BYTES := 32
const FIELD_PARAMETER_BUFFER_BYTES := 80
const FIELD_RGBA32_TEXEL_BYTES := 16
const FIELD_VALID_SECONDARY := 1
const FIELD_VALID_PRIMARY := 2

# Internal layout-14 B falsification sidecar. This is deliberately lazy-loaded:
# the ordinary V0 cache must remain usable when the optional shader has not yet
# been imported by Godot.
const B14_NODE_MOMENT_SHADER_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_layout14_node_visibility_moments_b14.glsl"
const B14_NODE_TAG_BYTES := 16
const B14_NODE_JOB_BYTES := 16
const B14_NODE_JOB_BUDGET := 256
const B14_NODE_MOMENT_TILE_SIZE := 8
const B14_NODE_MOMENT_RANGE_SCALE := 4.0
const B14_NODE_MOMENT_BINDING := 33
const B14_NODE_TAG_BINDING := 34

var _layout14_focus_world := Vector3.ZERO
var _layout14_camera_world_position := Vector3.ZERO
var _layout14_submitted_geometry_slots: Dictionary = {}
var _b14_internal_test_enabled := false
var _b14_moment_image := RID()
var _b14_node_tags := RID()
var _b14_node_jobs := RID()
var _b14_moment_sampler := RID()
var _b14_shader_resource: RDShaderFile
var _field_fill_shader_resource: RDShaderFile
var _b14_shader := RID()
var _b14_pipeline := RID()
var _b14_resource_error := "disabled"
var _b14_dispatch_error := ""
var _b14_needs_window_backfill := false
var _b14_pending_jobs: Array[Vector4i] = []
var _b14_pending_slot_keys: Dictionary = {}
var _b14_submitted_geometry_slots: Dictionary = {}
var _b14_submission_count := 0
var _b14_last_submitted_epoch := -1

static func validate_abi_constants() -> bool:
	return FIELD_LAYOUT_VERSION == 14 and FIELD_COLUMN_COUNT == 18 \
			and FIELD_JOB_RECORD_BYTES == 32 and FIELD_PARAMETER_BUFFER_BYTES == 80 \
			and FIELD_VALID_SECONDARY == 1 and FIELD_VALID_PRIMARY == 2

func create(rd: RenderingDevice, requested_resolution := RESOLUTION,
		dynamic_transfer := false, emitter_count := 0) -> bool:
	if dynamic_transfer or emitter_count != 0:
		return false
	if not validate_abi_constants():
		return false
	resolution = EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION else RESOLUTION
	texture = _field_texture(rd, resolution)
	tags = _texture(rd, RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT, TAG_COLUMNS, resolution)
	support = _texture(rd, RenderingDevice.DATA_FORMAT_R32_UINT, 1, resolution)
	parameters = rd.uniform_buffer_create(FIELD_PARAMETER_BUFFER_BYTES)
	_jobs = rd.storage_buffer_create(MAX_JOBS * FIELD_JOB_RECORD_BYTES)
	_probe_cluster_fallback = rd.storage_buffer_create(FALLBACK_CLUSTER_BUFFER_BYTES,
		PackedInt32Array([1, 0, 0, 0]).to_byte_array())
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler = rd.sampler_create(sampler_state)
	if _field_fill_shader_resource == null:
		var field_fill_value: Resource = ResourceLoader.load(FIELD_FILL_SHADER_PATH)
		if field_fill_value is RDShaderFile:
			_field_fill_shader_resource = field_fill_value as RDShaderFile
	if _field_fill_shader_resource == null:
		return false
	var field_fill_spirv: RDShaderSPIRV = _field_fill_shader_resource.get_spirv()
	if field_fill_spirv == null or _field_fill_shader_resource.base_error != "" \
			or field_fill_spirv.bytecode_compute.is_empty() \
			or field_fill_spirv.compile_error_compute != "":
		return false
	_shader = rd.shader_create_from_spirv(field_fill_spirv, "Magic GI CLV Layout 14 Probe Field Fill")
	if _shader.is_valid():
		_pipeline = rd.compute_pipeline_create(_shader)
	# The B14 visibility sidecar is optional and is allocated below. Validate only
	# the base field cache here; owned_rids() also lists the not-yet-created B14
	# RIDs so that later cleanup can release them when present.
	var required_rids: Array[RID] = [texture, tags, support, parameters, sampler,
		_jobs, _probe_cluster_fallback, _pipeline, _shader]
	for rid: RID in required_rids:
		if not rid.is_valid():
			return false
	if rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK \
			or rd.texture_clear(support, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
		return false
	if _b14_internal_test_enabled:
		_ensure_b14_resources(rd)
	return true


func set_internal_b_test_enabled(enabled: bool) -> void:
	var was_enabled := _b14_internal_test_enabled
	_b14_internal_test_enabled = enabled
	if not enabled:
		_b14_pending_jobs.clear()
		_b14_pending_slot_keys.clear()
		_b14_needs_window_backfill = false
		_b14_resource_error = "disabled"
	elif not was_enabled:
		_b14_needs_window_backfill = true
		if _b14_resource_error == "disabled":
			_b14_resource_error = "not_initialized"


func update(rd: RenderingDevice, camera: Vector3, base_spacing: float,
		geometry_epoch: int, content_revision: int, bake: Dictionary,
		directional: RefCounted, ubo: RID, nearest_sampler: RID, budget := 256,
		approximate_volume_enabled := false,
		exact_corner_visibility_enabled := false,
		approximate_ready_bit_enabled := false,
		dynamic_transfer := false,
		camera_world_position := Vector3.ZERO) -> bool:
	if dynamic_transfer:
		return false
	var raw_value: Variant = directional.get("raw_lighting") if directional != null else null
	var moments_value: Variant = bake.get("visibility_moments", RID())
	if approximate_volume_enabled or exact_corner_visibility_enabled \
			or approximate_ready_bit_enabled or not validate_abi_constants() \
			or not (raw_value is RID) or not (moments_value is RID):
		return false
	var raw_rid: RID = raw_value
	var moments_rid: RID = moments_value
	if not raw_rid.is_valid() or not moments_rid.is_valid():
		return false
	var old_origins: Array[Vector3i] = _origins.duplicate()
	var geometry_changed := _origins.is_empty() or _geometry_epoch != geometry_epoch \
			or not is_equal_approx(_spacing, base_spacing)
	if geometry_changed and not _origins.is_empty():
		if rd.texture_clear(tags, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK \
				or rd.texture_clear(support, Color(0, 0, 0, 0), 0, 1, 0, 1) != OK:
			return false
	queue_updates(camera, base_spacing, geometry_epoch)
	if geometry_changed:
		_layout14_submitted_geometry_slots.clear()
		if _b14_internal_test_enabled:
			_b14_pending_jobs.clear()
			_b14_pending_slot_keys.clear()
			_b14_submitted_geometry_slots.clear()
			_b14_last_submitted_epoch = geometry_epoch
			if not _clear_b14_node_tags(rd):
				_release_b14_resources(rd)
				_b14_resource_error = "tag_clear_failed"
	elif old_origins != _origins:
		_prune_layout14_submitted_geometry_slots()
		if _b14_internal_test_enabled:
			_prune_b14_submitted_geometry_slots()
	queue_content_refresh(content_revision)
	if not _write_parameters(rd, base_spacing, geometry_epoch, camera_world_position):
		return false
	_layout14_focus_world = camera
	_layout14_camera_world_position = camera_world_position
	var selected := take_jobs(clampi(budget, 0, MAX_JOBS))
	if _b14_internal_test_enabled:
		if _b14_last_submitted_epoch != geometry_epoch:
			_b14_pending_jobs.clear()
			_b14_pending_slot_keys.clear()
			_b14_submitted_geometry_slots.clear()
			_b14_last_submitted_epoch = geometry_epoch
			if not _clear_b14_node_tags(rd):
				_release_b14_resources(rd)
				_b14_resource_error = "tag_clear_failed"
		if _b14_needs_window_backfill \
				and _enqueue_b14_current_window_missing(geometry_epoch):
			_b14_needs_window_backfill = false
		for cell in selected:
			_enqueue_b14_geometry_job(cell, geometry_epoch)
	if selected.is_empty():
		if _b14_internal_test_enabled:
			if not _dispatch_b14_pending_jobs(rd, base_spacing, geometry_epoch, bake):
				# Keep the base field update alive; get_node_visibility_bindings()
				# propagates the latched sidecar failure so the pass uses source gather.
				return true
		return true
	var jobs := PackedByteArray()
	for cell in selected:
		var step := base_spacing * float(1 << cell.w)
		var center := (Vector3(cell.x, cell.y, cell.z) + Vector3.ONE * 0.5) * step
		jobs.append_array(PackedFloat32Array([center.x, center.y, center.z, step]).to_byte_array())
		jobs.append_array(PackedInt32Array([cell.x, cell.y, cell.z, cell.w]).to_byte_array())
	if jobs.size() != selected.size() * FIELD_JOB_RECORD_BYTES \
			or rd.buffer_update(_jobs, 0, jobs.size(), jobs) != OK:
		requeue_jobs(selected)
		return false
	var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [
		U.sampled(0, nearest_sampler, bake.geometry),
		U.sampled(1, nearest_sampler, bake.indices),
		U.storage_buffer(2, bake.visibility_nodes),
		U.storage_buffer(3, bake.visibility_triangles),
		U.storage_buffer(4, directional.raw_lighting),
		U.storage_buffer(5, _jobs),
		U.image(6, texture), U.image(7, tags), U.uniform_buffer(8, ubo),
		U.storage_buffer(9, bake.index_entries),
		U.storage_buffer(10, _cluster_buffer(bake)),
		U.image(11, support),
		U.sampled(13, nearest_sampler, bake.visibility_moments)])
	if not uniforms.is_valid():
		requeue_jobs(selected)
		return false
	var push := PackedInt32Array([selected.size(), resolution, geometry_epoch]).to_byte_array()
	push.append_array(PackedFloat32Array([base_spacing]).to_byte_array())
	rd.draw_command_begin_label("Magic GI CLV Layout 14 Probe Field Fill", Color(0.45, 0.68, 0.92))
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, selected.size(), 1, 1)
	rd.compute_list_end()
	rd.draw_command_end_label()
	for cell in selected:
		_record_layout14_submitted_geometry_slot(cell, geometry_epoch)
	if _b14_internal_test_enabled:
		if not _dispatch_b14_pending_jobs(rd, base_spacing, geometry_epoch, bake):
			# The ordinary field cache succeeded; fail the optional sidecar closed.
			return true
	return true


func _enqueue_b14_current_window_missing(geometry_epoch: int) -> bool:
	if geometry_epoch <= 0 or _origins.size() != LEVELS:
		return false
	for level in range(LEVELS):
		var origin: Vector3i = _origins[level]
		for z in range(resolution):
			for y in range(resolution):
				for x in range(resolution):
					_enqueue_b14_geometry_job(Vector4i(
							origin.x + x, origin.y + y, origin.z + z, level), geometry_epoch)
	return true


func get_node_visibility_bindings(rd: RenderingDevice) -> Dictionary:
	if not _b14_internal_test_enabled or not _ensure_b14_resources(rd):
		return {"valid": false, "error": _b14_resource_error}
	if not _b14_dispatch_error.is_empty():
		return {"valid": false, "error": _b14_dispatch_error,
			"moments": _b14_moment_image, "sampler": _b14_moment_sampler,
			"tags": _b14_node_tags,
			"bytes": estimate_node_visibility_gpu_bytes(resolution)}
	return {"valid": _b14_moment_image.is_valid() and _b14_moment_sampler.is_valid() \
			and _b14_node_tags.is_valid(), "moments": _b14_moment_image,
		"sampler": _b14_moment_sampler, "tags": _b14_node_tags,
		"bytes": estimate_node_visibility_gpu_bytes(resolution)}


func _ensure_b14_resources(rd: RenderingDevice) -> bool:
	if not _b14_internal_test_enabled:
		_b14_resource_error = "disabled"
		return false
	if resolution != 16 or LEVELS != 3:
		_b14_resource_error = "unsupported_resolution_or_levels"
		return false
	if _b14_moment_image.is_valid() and _b14_node_tags.is_valid() \
			and _b14_node_jobs.is_valid() and _b14_moment_sampler.is_valid() \
			and _b14_shader.is_valid() and _b14_pipeline.is_valid():
		_b14_resource_error = ""
		return true
	if not _b14_moment_image.is_valid():
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
		format.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
		format.width = resolution * B14_NODE_MOMENT_TILE_SIZE
		format.height = resolution * B14_NODE_MOMENT_TILE_SIZE
		format.depth = resolution * LEVELS
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
				| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
				| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
				| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		_b14_moment_image = rd.texture_create(format, RDTextureView.new(), [])
	if not _b14_node_tags.is_valid():
		var tag_bytes := PackedByteArray()
		tag_bytes.resize(resolution * resolution * resolution * LEVELS * B14_NODE_TAG_BYTES)
		_b14_node_tags = rd.storage_buffer_create(tag_bytes.size(), tag_bytes)
	if not _b14_node_jobs.is_valid():
		_b14_node_jobs = rd.storage_buffer_create(B14_NODE_JOB_BUDGET * B14_NODE_JOB_BYTES)
	if not _b14_moment_sampler.is_valid():
		var sampler_state := RDSamplerState.new()
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_b14_moment_sampler = rd.sampler_create(sampler_state)
	if _b14_shader_resource == null:
		var shader_value: Resource = ResourceLoader.load(B14_NODE_MOMENT_SHADER_PATH)
		if shader_value is RDShaderFile:
			_b14_shader_resource = shader_value as RDShaderFile
	if _b14_shader_resource == null:
		_b14_resource_error = "producer_shader_unavailable"
		return false
	var spirv: RDShaderSPIRV = _b14_shader_resource.get_spirv()
	if spirv == null or _b14_shader_resource.base_error != "" \
			or spirv.bytecode_compute.is_empty() or spirv.compile_error_compute != "":
		_b14_resource_error = "producer_shader_compile_error"
		return false
	if not _b14_shader.is_valid():
		_b14_shader = rd.shader_create_from_spirv(spirv,
				"Magic GI Layout 14 B Node Visibility Moments")
	if _b14_shader.is_valid() and not _b14_pipeline.is_valid():
		_b14_pipeline = rd.compute_pipeline_create(_b14_shader)
	var resources_valid := _b14_moment_image.is_valid() and _b14_node_tags.is_valid() \
			and _b14_node_jobs.is_valid() and _b14_moment_sampler.is_valid() \
			and _b14_shader.is_valid() and _b14_pipeline.is_valid()
	_b14_resource_error = "" if resources_valid else "producer_resource_creation_failed"
	return resources_valid


func _clear_b14_node_tags(rd: RenderingDevice) -> bool:
	if not _b14_node_tags.is_valid():
		return true
	var zero := PackedByteArray()
	zero.resize(resolution * resolution * resolution * LEVELS * B14_NODE_TAG_BYTES)
	return rd.buffer_update(_b14_node_tags, 0, zero.size(), zero) == OK


func _enqueue_b14_geometry_job(cell: Vector4i, geometry_epoch: int) -> void:
	if geometry_epoch <= 0 or cell.w < 0 or cell.w >= LEVELS \
			or _origins.size() != LEVELS \
			or not _contains(_origins[cell.w], Vector3i(cell.x, cell.y, cell.z), resolution):
		return
	var slot_key := _b14_physical_slot_key(cell)
	var existing: Variant = _b14_submitted_geometry_slots.get(slot_key)
	if existing is Vector4i and existing.x == cell.x and existing.y == cell.y \
			and existing.z == cell.z and existing.w == geometry_epoch:
		return
	if _b14_pending_slot_keys.has(slot_key):
		return
	_b14_pending_jobs.append(cell)
	_b14_pending_slot_keys[slot_key] = Vector4i(cell.x, cell.y, cell.z, geometry_epoch)


func _dispatch_b14_pending_jobs(rd: RenderingDevice, base_spacing: float,
		geometry_epoch: int, bake: Dictionary) -> bool:
	if not _b14_internal_test_enabled or _b14_pending_jobs.is_empty():
		return true
	if not _ensure_b14_resources(rd):
		return _record_b14_dispatch_failure(_b14_resource_error if not _b14_resource_error.is_empty() \
				else "producer_resources_unavailable")
	var nodes_value: Variant = bake.get("visibility_nodes", RID())
	var triangles_value: Variant = bake.get("visibility_triangles", RID())
	if not nodes_value is RID or not triangles_value is RID:
		return _record_b14_dispatch_failure("missing_bvh_buffers")
	var nodes: RID = nodes_value
	var triangles: RID = triangles_value
	if not nodes.is_valid() or not triangles.is_valid():
		return _record_b14_dispatch_failure("invalid_bvh_buffers")
	var count := mini(_b14_pending_jobs.size(), B14_NODE_JOB_BUDGET)
	var jobs_bytes := PackedByteArray()
	var batch: Array[Vector4i] = []
	for index in count:
		var cell: Vector4i = _b14_pending_jobs[index]
		batch.append(cell)
		jobs_bytes.append_array(PackedInt32Array([cell.x, cell.y, cell.z, cell.w]).to_byte_array())
	if jobs_bytes.size() != count * B14_NODE_JOB_BYTES \
			or rd.buffer_update(_b14_node_jobs, 0, jobs_bytes.size(), jobs_bytes) != OK:
		return _record_b14_dispatch_failure("job_upload_failed")
	var uniforms := UniformSetCacheRD.get_cache(_b14_shader, 0, [
		U.storage_buffer(0, nodes), U.storage_buffer(1, triangles),
		U.storage_buffer(2, _b14_node_jobs), U.image(3, _b14_moment_image),
		U.storage_buffer(4, _b14_node_tags)])
	if not uniforms.is_valid():
		return _record_b14_dispatch_failure("producer_uniform_set_failed")
	var push := PackedInt32Array([count, resolution, LEVELS, geometry_epoch]).to_byte_array()
	push.append_array(PackedFloat32Array([base_spacing, base_spacing * 2.0,
		base_spacing * 4.0, B14_NODE_MOMENT_RANGE_SCALE]).to_byte_array())
	var list := rd.compute_list_begin()
	if list < 0:
		return _record_b14_dispatch_failure("producer_compute_list_failed")
	rd.compute_list_bind_compute_pipeline(list, _b14_pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, count, 1, 1)
	rd.compute_list_add_barrier(list)
	rd.compute_list_end()
	var remaining: Array[Vector4i] = []
	for index in range(count, _b14_pending_jobs.size()):
		remaining.append(_b14_pending_jobs[index])
	_b14_pending_jobs = remaining
	for cell in batch:
		var slot_key := _b14_physical_slot_key(cell)
		_b14_pending_slot_keys.erase(slot_key)
		_b14_submitted_geometry_slots[slot_key] = Vector4i(
				cell.x, cell.y, cell.z, geometry_epoch)
	_b14_submission_count += count
	_b14_last_submitted_epoch = geometry_epoch
	_b14_resource_error = ""
	_b14_dispatch_error = ""
	return true


func _record_b14_dispatch_failure(reason: String) -> bool:
	_b14_resource_error = reason
	_b14_dispatch_error = reason
	return false


func _b14_physical_slot_key(cell: Vector4i) -> int:
	var px := posmod(cell.x, resolution)
	var py := posmod(cell.y, resolution)
	var pz := posmod(cell.z, resolution)
	return ((cell.w * resolution + pz) * resolution + py) * resolution + px


func _prune_b14_submitted_geometry_slots() -> void:
	if _origins.size() != LEVELS:
		_b14_submitted_geometry_slots.clear()
		_b14_pending_jobs.clear()
		_b14_pending_slot_keys.clear()
		return
	for slot_key_value in _b14_submitted_geometry_slots.keys():
		var slot_key := int(slot_key_value)
		var cell: Vector4i = _b14_submitted_geometry_slots[slot_key_value]
		var level := slot_key / (resolution * resolution * resolution)
		if level < 0 or level >= LEVELS or cell.w != _geometry_epoch \
				or not _contains(_origins[level], Vector3i(cell.x, cell.y, cell.z), resolution):
			_b14_submitted_geometry_slots.erase(slot_key_value)
	var remaining: Array[Vector4i] = []
	_b14_pending_slot_keys.clear()
	for cell in _b14_pending_jobs:
		if cell.w >= 0 and cell.w < LEVELS \
				and _contains(_origins[cell.w], Vector3i(cell.x, cell.y, cell.z), resolution):
			remaining.append(cell)
			_b14_pending_slot_keys[_b14_physical_slot_key(cell)] = Vector4i(
					cell.x, cell.y, cell.z, _geometry_epoch)
	_b14_pending_jobs = remaining


func _release_b14_resources(rd: RenderingDevice) -> void:
	if rd != null:
		for rid in [_b14_pipeline, _b14_shader, _b14_moment_image, _b14_node_tags,
				_b14_node_jobs, _b14_moment_sampler]:
			if rid.is_valid():
				rd.free_rid(rid)
	_b14_pipeline = RID()
	_b14_shader = RID()
	_b14_moment_image = RID()
	_b14_node_tags = RID()
	_b14_node_jobs = RID()
	_b14_moment_sampler = RID()
	_b14_pending_jobs.clear()
	_b14_pending_slot_keys.clear()
	_b14_submitted_geometry_slots.clear()


func _write_parameters(rd: RenderingDevice, base_spacing: float, geometry_epoch: int,
		camera_world_position: Vector3) -> bool:
	if _origins.size() != LEVELS:
		return false
	var constants := PackedByteArray()
	for origin in _origins:
		constants.append_array(PackedInt32Array([origin.x, origin.y, origin.z, 0]).to_byte_array())
	constants.append_array(PackedFloat32Array([base_spacing, camera_world_position.x,
		camera_world_position.y, camera_world_position.z]).to_byte_array())
	constants.append_array(PackedInt32Array([resolution, LEVELS, geometry_epoch,
		FIELD_LAYOUT_VERSION]).to_byte_array())
	if constants.size() != FIELD_PARAMETER_BUFFER_BYTES \
			or rd.buffer_update(parameters, 0, constants.size(), constants) != OK:
		return false
	parameter_resolution = resolution
	return true


func owned_rids() -> Array[RID]:
	return [texture, tags, support, parameters, sampler, _jobs,
		_probe_cluster_fallback, _pipeline, _shader, _b14_moment_image, _b14_node_tags,
		_b14_node_jobs, _b14_moment_sampler, _b14_pipeline, _b14_shader]


func get_layout14_runtime_state() -> Dictionary:
	var padded := resolution + 1
	var field_width := FIELD_COLUMN_COUNT * padded
	var field_height := padded
	var field_depth := LEVELS * padded
	var field_texture_bytes := field_width * field_height * field_depth \
			* FIELD_RGBA32_TEXEL_BYTES
	var cell_count := resolution * resolution * resolution * LEVELS
	var pending_count := maxi(_pending.size() - _cursor, 0)
	var cache_gpu_bytes := estimate_field_gpu_bytes(resolution)
	return {
		"layout_version": FIELD_LAYOUT_VERSION,
		"texture_columns": FIELD_COLUMN_COUNT,
		"padded_resolution": padded,
		"field_texture_dimensions": [field_width, field_height, field_depth],
		"field_texture_bytes": field_texture_bytes,
		"cache_gpu_bytes_estimate": cache_gpu_bytes,
		"tag_support_jobs_parameter_bytes": cache_gpu_bytes - field_texture_bytes,
		"clipmap_focus_world": [_layout14_focus_world.x,
			_layout14_focus_world.y, _layout14_focus_world.z],
		"camera_world_position": [_layout14_camera_world_position.x,
			_layout14_camera_world_position.y, _layout14_camera_world_position.z],
		"geometry_epoch": _geometry_epoch,
		"content_revision": _content_revision,
		"pending_cell_count": pending_count,
		"submitted_current_geometry_slot_count": _layout14_submitted_geometry_slots.size(),
		"expected_current_geometry_slot_count": cell_count,
		"all_current_geometry_slots_submitted": \
			_layout14_submitted_geometry_slots.size() == cell_count,
		"node_visibility_sidecar_requested": _b14_internal_test_enabled,
		"node_visibility_sidecar_available": _b14_moment_image.is_valid() \
				and _b14_node_tags.is_valid() and _b14_node_jobs.is_valid() \
				and _b14_moment_sampler.is_valid() and _b14_shader.is_valid() \
				and _b14_pipeline.is_valid(),
		"node_visibility_sidecar_error": _b14_resource_error,
		"node_visibility_moment_dimensions": [resolution * B14_NODE_MOMENT_TILE_SIZE,
			resolution * B14_NODE_MOMENT_TILE_SIZE, resolution * LEVELS],
		"node_visibility_moment_texture_bytes": estimate_node_visibility_texture_bytes(resolution) \
				if _b14_moment_image.is_valid() else 0,
		"node_visibility_tag_bytes": estimate_node_visibility_tag_bytes(resolution) \
				if _b14_node_tags.is_valid() else 0,
		"node_visibility_job_buffer_bytes": B14_NODE_JOB_BUDGET * B14_NODE_JOB_BYTES \
				if _b14_node_jobs.is_valid() else 0,
		"node_visibility_sidecar_bytes": \
				(estimate_node_visibility_texture_bytes(resolution) if _b14_moment_image.is_valid() else 0) \
				+ (estimate_node_visibility_tag_bytes(resolution) if _b14_node_tags.is_valid() else 0) \
				+ (B14_NODE_JOB_BUDGET * B14_NODE_JOB_BYTES if _b14_node_jobs.is_valid() else 0),
		"node_visibility_sidecar_allocated_bytes": \
				(estimate_node_visibility_texture_bytes(resolution) if _b14_moment_image.is_valid() else 0) \
				+ (estimate_node_visibility_tag_bytes(resolution) if _b14_node_tags.is_valid() else 0) \
				+ (B14_NODE_JOB_BUDGET * B14_NODE_JOB_BYTES if _b14_node_jobs.is_valid() else 0),
		"node_visibility_sidecar_estimated_bytes": estimate_node_visibility_gpu_bytes(resolution) \
				if _b14_internal_test_enabled else 0,
		"node_visibility_pending_jobs": _b14_pending_jobs.size(),
		"node_visibility_backfill_pending": _b14_needs_window_backfill,
		"node_visibility_last_dispatch_error": _b14_dispatch_error,
		"node_visibility_host_submitted_current_geometry_slots": \
				_b14_submitted_geometry_slots.size(),
		"node_visibility_current_geometry_moment_submissions": \
				_b14_submitted_geometry_slots.size(),
		"node_visibility_expected_current_geometry_moment_submissions": cell_count,
		"node_visibility_host_submission_count_total": _b14_submission_count,
		"node_visibility_host_submission_epoch": _b14_last_submitted_epoch,
		"node_visibility_effective_tag_status": "not_read_back_host_submission_only",
	}


static func estimate_node_visibility_texture_bytes(requested_resolution := RESOLUTION) -> int:
	var selected := EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION \
			else RESOLUTION
	return selected * B14_NODE_MOMENT_TILE_SIZE * selected * B14_NODE_MOMENT_TILE_SIZE \
			* selected * LEVELS * 8


static func estimate_node_visibility_tag_bytes(requested_resolution := RESOLUTION) -> int:
	var selected := EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION \
			else RESOLUTION
	return selected * selected * selected * LEVELS * B14_NODE_TAG_BYTES


static func estimate_node_visibility_gpu_bytes(requested_resolution := RESOLUTION) -> int:
	var selected := EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION \
			else RESOLUTION
	if selected != 16:
		return 0
	return estimate_node_visibility_texture_bytes(selected) \
			+ estimate_node_visibility_tag_bytes(selected) \
			+ B14_NODE_JOB_BUDGET * B14_NODE_JOB_BYTES


func _record_layout14_submitted_geometry_slot(cell: Vector4i, geometry_epoch: int) -> void:
	if cell.w < 0 or cell.w >= LEVELS or _origins.size() != LEVELS \
			or not _contains(_origins[cell.w], Vector3i(cell.x, cell.y, cell.z), resolution):
		return
	var x := posmod(cell.x, resolution)
	var y := posmod(cell.y, resolution)
	var z := posmod(cell.z, resolution)
	var cells_per_level := resolution * resolution * resolution
	var slot_key := cell.w * cells_per_level + x * resolution * resolution \
			+ y * resolution + z
	_layout14_submitted_geometry_slots[slot_key] = Vector4i(
		cell.x, cell.y, cell.z, geometry_epoch)


func _prune_layout14_submitted_geometry_slots() -> void:
	if _origins.size() != LEVELS:
		_layout14_submitted_geometry_slots.clear()
		return
	var cells_per_level := resolution * resolution * resolution
	for slot_key_value in _layout14_submitted_geometry_slots.keys():
		var slot_key := int(slot_key_value)
		var level := slot_key / cells_per_level
		var cell: Vector4i = _layout14_submitted_geometry_slots[slot_key_value]
		if level < 0 or level >= LEVELS or cell.w != _geometry_epoch \
				or not _contains(_origins[level], Vector3i(cell.x, cell.y, cell.z), resolution):
			_layout14_submitted_geometry_slots.erase(slot_key_value)


static func estimate_field_gpu_bytes(requested_resolution := RESOLUTION) -> int:
	var selected := EXPANDED_RESOLUTION if requested_resolution >= EXPANDED_RESOLUTION else RESOLUTION
	var padded := selected + 1
	var field_bytes := FIELD_COLUMN_COUNT * padded * padded * LEVELS * padded * FIELD_RGBA32_TEXEL_BYTES
	var logical_cells := selected * selected * LEVELS * selected
	var tag_bytes := logical_cells * 16
	var support_bytes := logical_cells * 4
	var jobs_bytes := MAX_JOBS * FIELD_JOB_RECORD_BYTES
	return field_bytes + tag_bytes + support_bytes + FIELD_PARAMETER_BUFFER_BYTES \
			+ jobs_bytes + FALLBACK_CLUSTER_BUFFER_BYTES


static func _field_texture(rd: RenderingDevice, selected_resolution: int) -> RID:
	var padded := selected_resolution + 1
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.width = FIELD_COLUMN_COUNT * padded
	format.height = padded
	format.depth = LEVELS * padded
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return rd.texture_create(format, RDTextureView.new(), [])
