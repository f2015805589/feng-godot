@tool
extends "magic_gi_preinterpolated_volume_cache.gd"
## Bounded resident operator pool for independently streamed prepared bricks.
## The cache retains no brick resources or world-sized operator allocation.

const PagedLayout = preload("../../feng-magic-gi/feng_magic_gi_prepared_clip_layout.gd")
const PAGED_LAYOUT_VERSION := 7
const PARAMETERS_BYTES_PAGED := 208
const POOL_GRANULARITY := 256

var gpu_budget_bytes := 128 * 1024 * 1024
var requested_upload_budget_bytes := 0
var _pool_slots: Dictionary = {}
var _pool_capacity := 0
var _pages_revision := -1
var _resident_lod_count := 0
var _radius_m := 512.0
var _sphere_bytes := PackedByteArray()
var _loaded_bricks := 0
var _uploaded_bytes := 0
var _pool_resize_count := 0
var _paged_valid_cells := 0
var _upload_budget_exceeded_count := 0
var _maximum_uploaded_bytes := 0
var _eviction_clear_calls := 0

func create_paged(rd: RenderingDevice, header: Resource, pages: Array,
		pages_revision: int, camera_world: Vector3, radius_m := 512.0) -> bool:
	var layout := PagedLayout.build(header, camera_world, resolution, radius_m)
	if rd == null or not layout.get("valid", false):
		_error = "paged_clv_invalid_header_or_layout"
		return false
	_resident_lod_count = int(layout.level_count)
	dimensions = layout.dimensions
	clip_cell_count = int(layout.resident_capacity)
	source_dimensions = header.get("dimensions")
	emitter_count = int(header.get("emitter_count"))
	source_signature = String(header.get("directional_source_signature"))
	domain_bounds_world = header.get("domain_bounds_world")
	_operator_schema_version = int(header.get("operator_schema_version"))
	if _operator_schema_version != 2:
		_error = "prepared_sh9_cache_requires_sh2_rebake"
		return false
	_input_coefficient_count = 4
	_output_coefficient_count = 4
	_response_field_count = 4
	_runtime_layout_version = PAGED_LAYOUT_VERSION
	_operator_columns = 16 + emitter_count * 6
	_operator_bound = float(header.get("maximum_operator_row_l1"))
	_half_fields = is_finite(_operator_bound) and _operator_bound > 0.0
	response_resolution = 8
	response_tile_size = 1
	_radius_m = radius_m
	if _fixed_gpu_bytes() + _output_coefficient_count * _operator_columns * 4 > gpu_budget_bytes:
		_error = "paged_clv_gpu_budget_exceeded"
		return false
	var empty := PackedFloat32Array()
	empty.resize(maxi(4, emitter_count * 6))
	empty.fill(0.0)
	_live_sources = rd.storage_buffer_create(empty.size() * 4, empty.to_byte_array())
	_transfer = rd.storage_buffer_create(4, PackedByteArray([0, 0, 0, 0]))
	_resident_indices.resize(clip_cell_count)
	_resident_indices.fill(-1)
	_clip_source_indices = rd.storage_buffer_create(clip_cell_count * 4, _resident_indices.to_byte_array())
	_clip_validity = rd.storage_buffer_create(4, PackedInt32Array([0]).to_byte_array())
	_clip_relocation = rd.storage_buffer_create(16, PackedFloat32Array([0, 0, 0, 0]).to_byte_array())
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT if _half_fields \
		else RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.width = dimensions.x
	format.height = dimensions.y
	format.depth = dimensions.z * _response_field_count
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	texture_fields = [rd.texture_create(format, RDTextureView.new(), [])]
	var dummy := RDTextureFormat.new()
	dummy.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	dummy.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	dummy.width = 1
	dummy.height = 1
	dummy.depth = 1
	dummy.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	moment_texture = rd.texture_create(dummy, RDTextureView.new(), [PackedFloat32Array([0, 0]).to_byte_array()])
	_shader_resource = load(PREPARED_SHADER_R16 if _half_fields else PREPARED_SHADER) as RDShaderFile
	if _shader_resource == null or not _shader_resource.base_error.is_empty():
		_error = "paged_clv_relight_shader_unavailable"
		return false
	var spirv := _shader_resource.get_spirv()
	if spirv == null or not spirv.compile_error_compute.is_empty():
		_error = "paged_clv_relight_shader_not_compiled"
		return false
	_shader = rd.shader_create_from_spirv(spirv, "Magic GI Paged CLV Transfer Relight")
	_pipeline = rd.compute_pipeline_create(_shader)
	return update_pages(rd, header, pages, pages_revision, camera_world, radius_m, true) \
		and is_ready_resources()

func update_pages(rd: RenderingDevice, header: Resource, pages: Array,
		pages_revision: int, camera_world: Vector3, radius_m := 512.0, force := false) -> bool:
	var layout := PagedLayout.build(header, camera_world, resolution, radius_m, _clipmap_state)
	if not layout.get("valid", false) or layout.dimensions != dimensions:
		_error = "paged_clv_layout_recreation_required"
		return false
	# The receiver cutoff follows sub-cell camera movement. Updating these 16
	# bytes must not invalidate transfer lighting or dispatch a redundant relight.
	var sphere := PackedFloat32Array([camera_world.x, camera_world.y, camera_world.z, radius_m]).to_byte_array()
	if parameters.is_valid() and sphere != _sphere_bytes:
		if rd.buffer_update(parameters, 192, 16, sphere) != OK:
			_error = "paged_clv_sphere_upload_failed"
			return false
	_sphere_bytes = sphere
	_clipmap_camera_world = camera_world
	_radius_m = radius_m
	if not force and layout.state == _clipmap_state and pages_revision == _pages_revision:
		return true
	_uploaded_bytes = 0
	_eviction_clear_calls = 0
	var desired: Dictionary = {}
	var bricks: Array[Resource] = []
	var rows_per_probe := _output_coefficient_count * _operator_columns
	var bytes_per_probe := rows_per_probe * 4
	# Iterate loaded bricks rather than the unbounded source lattice. Halos are
	# permitted to supply boundary interpolation support; duplicate samples are
	# byte-identical and are assigned a single stable resident pool slot.
	for descriptor in pages:
		if not descriptor is Dictionary or not descriptor.get("brick") is Resource:
			continue
		var brick: Resource = descriptor.brick
		if not brick.has_method("is_header_valid") or not brick.is_header_valid() \
				or int(brick.get("operator_schema_version")) != _operator_schema_version \
				or String(brick.get("directional_source_signature")) != source_signature \
				or int(brick.get("geometry_signature")) != int(header.get("geometry_signature")) \
				or int(brick.get("emitter_count")) != emitter_count \
				or brick.get("emitter_ids") != header.get("emitter_ids") \
				or brick.get("emitter_static_signatures") != header.get("emitter_static_signatures") \
				or brick.get("source_origin_world") != header.get("origin_world") \
				or float(brick.get("source_spacing_m")) != float(header.get("spacing_m")) \
				or float(brick.get("maximum_operator_row_l1")) > _operator_bound:
			_error = "paged_clv_brick_header_mismatch"
			return false
		var level := int(brick.get("level"))
		if level < 0 or level >= _resident_lod_count:
			continue
		var lod: Dictionary = layout.lods[level]
		var brick_origin: Vector3i = brick.get("cell_origin")
		var brick_dimensions: Vector3i = brick.get("dimensions")
		var begin: Vector3i = brick_origin.max(lod.cell_origin)
		var end: Vector3i = (brick_origin + brick_dimensions).min(lod.cell_origin + Vector3i.ONE * resolution)
		if begin.x >= end.x or begin.y >= end.y or begin.z >= end.z:
			continue
		if not PagedLayout.intersects_sphere(brick.support_bounds(), camera_world, radius_m):
			continue
		var brick_index := bricks.size()
		bricks.append(brick)
		var validity: PackedByteArray = brick.get("validity")
		for z in range(begin.z, end.z):
			for y in range(begin.y, end.y):
				for x in range(begin.x, end.x):
					var global_cell := Vector3i(x, y, z)
					var local := global_cell - brick_origin
					var source_index := (local.z * brick_dimensions.y + local.y) * brick_dimensions.x + local.x
					if validity[source_index] == 0:
						continue
					# Keep the window's bounded interpolation support from admitted
					# pages. Trimming samples to today's sphere would lose support
					# after sub-cell movement without a clipmap/page revision. Whole
					# pages outside the sphere are evicted by the streamer; receiver
					# shading enforces the exact current per-pixel sphere separately.
					var relative: Vector3i = global_cell - lod.cell_origin
					var resident_index := ((level * resolution + relative.z) * resolution + relative.y) * resolution + relative.x
					var key := "%d:%d:%d:%d" % [level, x, y, z]
					if not desired.has(key):
						desired[key] = Vector3i(resident_index, brick_index, source_index)
	_loaded_bricks = bricks.size()
	var needed_capacity := maxi(1, ((desired.size() + POOL_GRANULARITY - 1) / POOL_GRANULARITY) * POOL_GRANULARITY)
	if needed_capacity * bytes_per_probe + _fixed_gpu_bytes() > gpu_budget_bytes:
		_error = "paged_clv_gpu_budget_exceeded"
		return false
	var resize_pool := needed_capacity > _pool_capacity or needed_capacity * 4 < _pool_capacity
	var dirty: Dictionary = {}
	if resize_pool:
		# Bounded geometric growth avoids reallocating and retransferring every
		# existing cell when one new page or clipmap strip enters the window.
		var target_capacity := needed_capacity
		if needed_capacity > _pool_capacity and _pool_capacity > 1:
			var headroom := int(ceil(float(_pool_capacity) * 1.5 / POOL_GRANULARITY)) * POOL_GRANULARITY
			var affordable := int((gpu_budget_bytes - _fixed_gpu_bytes()) / bytes_per_probe)
			target_capacity = maxi(needed_capacity, mini(headroom, mini(clip_cell_count, affordable)))
		# Rebuilds copy from admitted CPU bricks, so the old pool need not remain
		# live while allocating its replacement. Drop it first to keep owned GPU
		# payload within the stated budget even during resize. RD may retire the
		# released allocation later to protect previously submitted GPU work.
		if _transfer.is_valid(): rd.free_rid(_transfer)
		_transfer = RID()
		_pool_capacity = 0
		_pool_slots.clear()
		_ready = false
		_gpu_bytes = _fixed_gpu_bytes()
		var replacement := rd.storage_buffer_create(target_capacity * bytes_per_probe)
		if not replacement.is_valid():
			_error = "paged_clv_operator_pool_allocation_failed"
			return false
		_transfer = replacement
		_pool_capacity = target_capacity
		_gpu_bytes += target_capacity * bytes_per_probe
		_pool_resize_count += 1
	else:
		var evicted_slots: Array[int] = []
		for key in _pool_slots.keys():
			if not desired.has(key):
				evicted_slots.append(int(_pool_slots[key]))
				_pool_slots.erase(key)
		# A leaving page often owns many consecutive slots. Clear one interval
		# per run, rather than issuing thousands of tiny RD operations.
		evicted_slots.sort()
		var evicted_cursor := 0
		while evicted_cursor < evicted_slots.size():
			var first := evicted_slots[evicted_cursor]
			var end_slot := first + 1
			evicted_cursor += 1
			while evicted_cursor < evicted_slots.size() and evicted_slots[evicted_cursor] == end_slot:
				end_slot += 1
				evicted_cursor += 1
			if rd.buffer_clear(_transfer, first * bytes_per_probe, (end_slot - first) * bytes_per_probe) != OK:
				_error = "paged_clv_operator_eviction_failed"
				return false
			_eviction_clear_calls += 1
	var used := PackedByteArray()
	used.resize(_pool_capacity)
	used.fill(0)
	for slot in _pool_slots.values(): used[int(slot)] = 1
	var free_slot := 0
	var indices := PackedInt32Array()
	indices.resize(clip_cell_count)
	indices.fill(-1)
	for key in desired:
		var item: Vector3i = desired[key]
		if not _pool_slots.has(key):
			while free_slot < _pool_capacity and used[free_slot] != 0: free_slot += 1
			_pool_slots[key] = free_slot
			used[free_slot] = 1
			dirty[free_slot] = Vector2i(item.y, item.z)
		var slot := int(_pool_slots[key])
		indices[item.x] = slot
	# Group consecutive destination slots into bounded uploads. Each source slice
	# is copied by the packed-array implementation, not a GDScript float loop.
	var dirty_slots: Array = dirty.keys()
	dirty_slots.sort()
	var cursor := 0
	while cursor < dirty_slots.size():
		var first_slot := int(dirty_slots[cursor])
		var next_slot := first_slot
		var bytes := PackedByteArray()
		while cursor < dirty_slots.size() and int(dirty_slots[cursor]) == next_slot \
				and next_slot - first_slot < POOL_GRANULARITY:
			var source: Vector2i = dirty[next_slot]
			var operators: PackedFloat32Array = bricks[source.x].get("operators")
			bytes.append_array(operators.slice(source.y * rows_per_probe,
				(source.y + 1) * rows_per_probe).to_byte_array())
			next_slot += 1
			cursor += 1
		if rd.buffer_update(_transfer, first_slot * bytes_per_probe, bytes.size(), bytes) != OK:
			_error = "paged_clv_operator_upload_failed"
			return false
		_uploaded_bytes += bytes.size()
	_maximum_uploaded_bytes = maxi(_maximum_uploaded_bytes, _uploaded_bytes)
	if requested_upload_budget_bytes > 0 and _uploaded_bytes > requested_upload_budget_bytes:
		_upload_budget_exceeded_count += 1
	_resident_indices = indices
	_paged_valid_cells = desired.size()
	probe_count = desired.size()
	source_probe_count = _pool_capacity
	if rd.buffer_update(_clip_source_indices, 0, indices.size() * 4, indices.to_byte_array()) != OK:
		_error = "paged_clv_index_upload_failed"
		return false
	_lod_layouts = layout.lods
	_clipmap_anchor_world = layout.anchor_world
	_clipmap_anchor_mode = "camera_position_paged_clv"
	var parameter_bytes := _pack_parameters()
	if parameters.is_valid():
		if rd.buffer_update(parameters, 0, parameter_bytes.size(), parameter_bytes) != OK: return false
	else:
		parameters = rd.uniform_buffer_create(parameter_bytes.size(), parameter_bytes)
	origin_world = _lod_layouts[0].origin_world
	spacing_m = _lod_layouts[0].spacing_m
	_clipmap_state = layout.state
	_pages_revision = pages_revision
	_clipmap_update_count += 1
	_last_lighting_key.clear()
	_ready = false
	_gpu_bytes = _pool_capacity * bytes_per_probe + _fixed_gpu_bytes()
	_error = ""
	return true

func _fixed_gpu_bytes() -> int:
	return clip_cell_count * (4 + _response_field_count * (8 if _half_fields else 16)) \
		+ maxi(4, emitter_count * 6) * 4 + PARAMETERS_BYTES_PAGED + 28

func _pack_parameters() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(PARAMETERS_BYTES_PAGED)
	for level in _lod_layouts.size():
		var origin: Vector3 = _lod_layouts[level].origin_world
		var offset := level * 16 if level < 4 else 96 + (level - 4) * 16
		bytes.encode_float(offset, origin.x)
		bytes.encode_float(offset + 4, origin.y)
		bytes.encode_float(offset + 8, origin.z)
		bytes.encode_float(offset + 12, float(_lod_layouts[level].spacing_m))
	bytes.encode_s32(64, dimensions.x)
	bytes.encode_s32(68, dimensions.y)
	bytes.encode_s32(72, dimensions.z)
	bytes.encode_s32(76, _runtime_layout_version)
	bytes.encode_float(80, _decode_scale)
	bytes.encode_s32(84, _response_field_count)
	bytes.encode_s32(88, _resident_lod_count)
	bytes.encode_s32(92, resolution)
	for lane in 4: bytes.encode_float(192 + lane * 4, _sphere_bytes.decode_float(lane * 4))
	return bytes

func get_runtime_state() -> Dictionary:
	var state := super.get_runtime_state()
	state.merge({"layout_version": _runtime_layout_version, "paged_prepared_transfer": true,
		"operator_schema_version": _operator_schema_version,
		"operator_input_coefficients": _input_coefficient_count,
		"operator_output_coefficients": _output_coefficient_count,
		"response_field_count": _response_field_count,
		"sh_basis": "real_orthonormal_l0_l1_coefficients4",
		"clipmap_lod_count": _resident_lod_count, "valid_resident_cells": _paged_valid_cells,
		"gi_radius_m": _radius_m, "loaded_bricks": _loaded_bricks,
		"resident_operator_slots": _pool_capacity, "gpu_budget_bytes": gpu_budget_bytes,
		"operator_pool_bytes": _pool_capacity * _output_coefficient_count * _operator_columns * 4,
		"uploaded_operator_bytes_last_update": _uploaded_bytes,
		"maximum_uploaded_operator_bytes": _maximum_uploaded_bytes,
		"requested_upload_budget_bytes": requested_upload_budget_bytes,
		"upload_budget_enforced": false, "upload_budget_exceeded_count": _upload_budget_exceeded_count,
		"eviction_clear_calls_last_update": _eviction_clear_calls,
		"operator_pool_resize_count": _pool_resize_count, "prepared_pages_revision": _pages_revision}, true)
	return state
