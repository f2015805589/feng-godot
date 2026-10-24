@tool
extends "magic_gi_dynamic_volume_cache.gd"
## A fixed resident CLV of baked linear transfer operators. Geometry is used
## only by the offline builder; updates are matrix products and texture stores.

const PREPARED_LAYOUT := 5
const PREPARED_LEVELS := 4
const PREPARED_SHADER := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_transfer_relight.glsl"
const PREPARED_SHADER_R16 := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_transfer_relight_r16.glsl"
const EditorSnapshot = preload("magic_gi_clv_editor_snapshot.gd")
## Set before create(). Changing the resident window requires recreating its GPU
## resources; source spacing and the four baked transfer levels stay unchanged.
var resolution := CLIPMAP_RESOLUTION
var _prepared_dimensions := PackedInt32Array()
var _prepared_offsets := PackedInt32Array()
var _prepared_validity := PackedByteArray()
var _operator_columns := 0
var _gpu_bytes := 0
var _operator_bound := 0.0
var _half_fields := false
var _decode_scale := 1.0
var _resident_indices := PackedInt32Array()
var _valid_cells_per_lod := PackedInt32Array([0, 0, 0, 0])
var _valid_resident_cells := 0

func _clipmap_anchor_resolution() -> int:
	return resolution

func _clipmap_anchor_from_view(source: Resource, camera_world: Vector3,
		_camera_forward: Vector3) -> Dictionary:
	# Residency is a function of camera position, never its orientation. Fitting
	# against the actual view ray made an in-place turn move cascade boundaries
	# over the same receiver and blend a different prepared transfer LOD there.
	# Aim the existing domain fit toward its center instead. This keeps the fine
	# window inside a small room when the camera is outside, without extra cells,
	# texture samples, or relight work when the camera only rotates.
	if not is_instance_valid(source) or not camera_world.is_finite():
		return {"valid": false, "mode": "invalid_camera_or_source_bounds"}
	var bounds_value: Variant = source.get("domain_bounds_world")
	if not bounds_value is AABB:
		return {"valid": false, "mode": "invalid_camera_or_source_bounds"}
	var bounds: AABB = bounds_value
	if not bounds.position.is_finite() or not bounds.size.is_finite() \
			or minf(bounds.size.x, minf(bounds.size.y, bounds.size.z)) <= 0.0:
		return {"valid": false, "mode": "invalid_source_bounds"}
	var spacing := float(source.get("spacing_m"))
	if not is_finite(spacing) or spacing <= 0.0:
		return {"valid": false, "mode": "invalid_source_spacing"}
	var center := bounds.get_center()
	var toward_center := center - camera_world
	if toward_center.length_squared() <= 1e-12:
		return {"valid": true, "anchor_world": center,
			"mode": "camera_position_at_source_center"}
	var anchor := super._clipmap_anchor_from_view(source, camera_world, toward_center)
	if bool(anchor.get("valid", false)):
		anchor["mode"] = "camera_position_domain_far_fitted_finest_window"
	return anchor

func create(rd: RenderingDevice, source: Resource, prepared_validation := false,
		_requested_response_resolution := 8, camera_world := Vector3.ZERO,
		camera_forward := Vector3.FORWARD) -> bool:
	if resolution not in [16, 24, 32]:
		_error = "prepared_clv_resolution_must_be_16_24_or_32"
		return false
	if rd == null or source == null or not source.has_preinterpolated_clv() \
			or (not prepared_validation and not source.is_valid()):
		_error = "preinterpolated_clv_source_invalid"
		return false
	source_dimensions = source.dimensions
	probe_count = source.probe_count
	emitter_count = source.emitter_count
	source_signature = source.directional_source_signature
	domain_bounds_world = source.domain_bounds_world
	_prepared_dimensions = source.clv_prepared_dimensions
	_prepared_offsets = source.clv_prepared_offsets
	_prepared_validity = source.clv_prepared_validity
	source_probe_count = _prepared_validity.size()
	_operator_columns = 36 + emitter_count * 6
	_operator_bound = float(source.clv_preparation_stats.get("maximum_operator_row_l1", 0.0))
	_half_fields = is_finite(_operator_bound) and _operator_bound > 0.0
	dimensions = Vector3i(resolution, resolution, resolution * PREPARED_LEVELS)
	clip_cell_count = dimensions.x * dimensions.y * dimensions.z
	response_resolution = 8 # Legacy bridge field; layout 5 selects seven packed tensors.
	response_tile_size = 1
	var operators: PackedFloat32Array = source.clv_prepared_operators
	_transfer = rd.storage_buffer_create(operators.size() * 4, operators.to_byte_array())
	var empty := PackedFloat32Array()
	empty.resize(maxi(4, emitter_count * 6))
	empty.fill(0.0)
	_live_sources = rd.storage_buffer_create(empty.size() * 4, empty.to_byte_array())
	var indices := PackedInt32Array()
	indices.resize(clip_cell_count)
	indices.fill(-1)
	_resident_indices = indices
	_clip_source_indices = rd.storage_buffer_create(indices.size() * 4, indices.to_byte_array())
	# Compatibility handles for the common publication ABI. Layout 5 never reads
	# moments, relocations, or per-pixel validity buffers.
	_clip_validity = rd.storage_buffer_create(4, PackedInt32Array([0]).to_byte_array())
	_clip_relocation = rd.storage_buffer_create(16, PackedFloat32Array([0, 0, 0, 0]).to_byte_array())
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT if _half_fields \
		else RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.width = dimensions.x
	format.height = dimensions.y
	format.depth = dimensions.z * 7
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
		_error = "clv_transfer_relight_shader_unavailable"
		return false
	var spirv := _shader_resource.get_spirv()
	if spirv == null or not spirv.compile_error_compute.is_empty():
		_error = "clv_transfer_relight_shader_not_compiled"
		return false
	_shader = rd.shader_create_from_spirv(spirv, "Magic GI CLV Transfer Relight")
	_pipeline = rd.compute_pipeline_create(_shader)
	_gpu_bytes = operators.size() * 4 + clip_cell_count * (4 + 7 * (8 if _half_fields else 16)) + empty.size() * 4 + 124
	return update_clipmap(rd, source, camera_world, true, camera_forward) and is_ready_resources()

func update_clipmap(rd: RenderingDevice, source: Resource, camera_world: Vector3,
		force := false, camera_forward := Vector3.FORWARD) -> bool:
	var anchor := _clipmap_anchor_from_view(source, camera_world, camera_forward)
	if not bool(anchor.get("valid", false)):
		_error = "clv_camera_anchor_invalid"
		return false
	_clipmap_camera_world = camera_world
	_clipmap_camera_forward = camera_forward
	_clipmap_anchor_world = anchor.anchor_world
	_clipmap_anchor_mode = anchor.mode
	var layout := Clipmap.build_prepared_layout(source, _clipmap_anchor_world,
		resolution, _clipmap_state)
	if not bool(layout.get("valid", false)):
		_error = "clv_layout_invalid"
		return false
	if not force and layout.state == _clipmap_state: return true
	var indices := _resident_indices
	var origins := PackedFloat32Array()
	origins.resize(16)
	var previous_lods := _lod_layouts.duplicate()
	var cells_per_lod := resolution * resolution * resolution
	_lod_layouts.clear()
	for level in PREPARED_LEVELS:
		var lod: Dictionary = layout.lods[level]
		_lod_layouts.append(lod)
		var origin: Vector3 = lod.origin_world
		origins[level * 4] = origin.x
		origins[level * 4 + 1] = origin.y
		origins[level * 4 + 2] = origin.z
		origins[level * 4 + 3] = lod.spacing_m
		if not force and level < previous_lods.size() \
				and previous_lods[level].logical_origin_source_index == lod.logical_origin_source_index:
			continue
		for slot in range(level * cells_per_lod, (level + 1) * cells_per_lod): indices[slot] = -1
		_valid_cells_per_lod[level] = 0
		var stride := 1 << level
		var start: Vector3i = lod.logical_origin_source_index / stride
		var dims := Vector3i(_prepared_dimensions[level * 3], _prepared_dimensions[level * 3 + 1], _prepared_dimensions[level * 3 + 2])
		for z in resolution:
			var source_z := start.z + z
			if source_z < 0 or source_z >= dims.z: continue
			for y in resolution:
				var source_y := start.y + y
				if source_y < 0 or source_y >= dims.y: continue
				for x in resolution:
					var source_x := start.x + x
					if source_x < 0 or source_x >= dims.x: continue
					var source_index := _prepared_offsets[level] + (source_z * dims.y + source_y) * dims.x + source_x
					if _prepared_validity[source_index] == 0: continue
					indices[((level * resolution + z) * resolution + y) * resolution + x] = source_index
					_valid_cells_per_lod[level] += 1
	_resident_indices = indices
	_valid_resident_cells = 0
	for count in _valid_cells_per_lod:
		_valid_resident_cells += count
	if rd.buffer_update(_clip_source_indices, 0, indices.size() * 4, indices.to_byte_array()) != OK:
		_error = "clv_index_upload_failed"
		return false
	var bytes := origins.to_byte_array()
	bytes.append_array(PackedInt32Array([dimensions.x, dimensions.y, dimensions.z, PREPARED_LAYOUT]).to_byte_array())
	bytes.append_array(PackedFloat32Array([_decode_scale]).to_byte_array())
	bytes.append_array(PackedInt32Array([7, PREPARED_LEVELS, resolution]).to_byte_array())
	if parameters.is_valid():
		if rd.buffer_update(parameters, 0, bytes.size(), bytes) != OK: return false
	else:
		parameters = rd.uniform_buffer_create(bytes.size(), bytes)
	origin_world = _lod_layouts[0].origin_world
	spacing_m = _lod_layouts[0].spacing_m
	_clipmap_state = layout.state
	_clipmap_update_count += 1
	_last_lighting_key.clear()
	_ready = false
	return true

func relight(rd: RenderingDevice, live_gi_ubo: RID, snapshot: Dictionary,
		profile_timestamps := false) -> bool:
	if not is_ready_resources() or not live_gi_ubo.is_valid(): return false
	var live: PackedFloat32Array = snapshot.get("emission_sources", PackedFloat32Array())
	if live.size() != emitter_count * 6:
		_error = "clv_live_emitter_count_mismatch"
		return false
	var key: Array = [snapshot.get("lighting"), snapshot.get("sky_lighting"), live,
		snapshot.get("emission_revision", 0), _clipmap_update_count]
	if _ready and key == _last_lighting_key: return true
	if _half_fields:
		var input_max := 0.0
		for family in [snapshot.get("lighting", PackedFloat32Array()),
				snapshot.get("sky_lighting", PackedFloat32Array()), live]:
			for value in family: input_max = maxf(input_max, absf(value))
		# Every packed tensor lane is bounded by one SH row's L1 operator norm
		# times the maximum current input. A shared power-of-two scale preserves
		# linear filtering and prevents half-float HDR overflow without clamping.
		var bound := _operator_bound * input_max
		var scale := pow(2.0, maxf(0.0, ceil(log(maxf(bound / 32752.0, 1.0)) / log(2.0))))
		if not is_finite(scale):
			_error = "clv_lighting_scale_nonfinite"
			return false
		if scale != _decode_scale:
			if rd.buffer_update(parameters, 80, 4, PackedFloat32Array([scale]).to_byte_array()) != OK: return false
			_decode_scale = scale
	if not live.is_empty() and live != _last_live_sources:
		if rd.buffer_update(_live_sources, 0, live.size() * 4, live.to_byte_array()) != OK: return false
	var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [U.storage_buffer(0, _transfer),
		U.storage_buffer(1, _clip_source_indices), U.storage_buffer(2, _live_sources),
		U.uniform_buffer(3, live_gi_ubo), U.image(4, texture_fields[0])])
	if not uniforms.is_valid():
		_error = "clv_relight_uniform_set_failed"
		return false
	if profile_timestamps: rd.capture_timestamp("Magic GI Dynamic Volume Relight Begin")
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	var push := PackedInt32Array([clip_cell_count, source_probe_count, emitter_count,
		_operator_columns, dimensions.x, dimensions.y, dimensions.z]).to_byte_array()
	push.append_array(PackedFloat32Array([1.0 / _decode_scale]).to_byte_array())
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (clip_cell_count + 63) / 64, 1, 1)
	rd.compute_list_end()
	if profile_timestamps: rd.capture_timestamp("Magic GI Dynamic Volume Relight End")
	_last_lighting_key = key.duplicate(true)
	_last_live_sources = live.duplicate()
	_ready = true
	_last_dispatch_count += 1
	_relight_revision += 1
	return true

func is_ready_resources() -> bool:
	return _pipeline.is_valid() and _shader.is_valid() and parameters.is_valid() \
		and _transfer.is_valid() and _live_sources.is_valid() and _clip_source_indices.is_valid() \
		and _clip_validity.is_valid() and _clip_relocation.is_valid() \
		and texture_fields.size() == 1 and texture_fields[0].is_valid() and moment_texture.is_valid()

## Called only after the editor broker admits an explicit request. Snapshot the
## exact resident mapping/decode scale alongside the ordered GPU copy, so a later
## camera move or relight cannot pair new metadata with older texture contents.
func request_editor_snapshot(rd: RenderingDevice, request: Dictionary) -> Error:
	if rd == null or not _ready or not is_ready_resources() or request.is_empty():
		return ERR_UNAVAILABLE
	var metadata := request.duplicate(true)
	metadata["layout_version"] = int(get_runtime_state().get("layout_version", PREPARED_LAYOUT))
	metadata["dimensions"] = dimensions
	metadata["resident_indices"] = _resident_indices.duplicate()
	metadata["half_fields"] = _half_fields
	metadata["decode_scale"] = _decode_scale
	metadata["domain_bounds_world"] = domain_bounds_world
	var origins := PackedVector3Array()
	var steps := PackedFloat32Array()
	for lod in _lod_layouts:
		origins.append(lod.origin_world)
		steps.append(lod.spacing_m)
	metadata["lod_origins"] = origins
	metadata["lod_spacings"] = steps
	if not bool(request.get("include_sh", true)):
		EditorSnapshot.receive_readback(PackedByteArray(), metadata)
		return OK
	return rd.texture_get_data_async(texture_fields[0], 0,
		Callable(EditorSnapshot, "receive_readback").bind(metadata))

func get_runtime_state() -> Dictionary:
	return {"layout_version": PREPARED_LAYOUT, "preinterpolated_transfer": true,
		"runtime_geometry_queries": 0, "runtime_pixel_neighbor_loop": false,
		"field_format": "RGBA16F" if _half_fields else "RGBA32F", "decode_scale": _decode_scale,
		"probe_count": probe_count, "source_probe_count": source_probe_count,
		"clip_cell_count": clip_cell_count, "clipmap_resolution": resolution,
		"valid_resident_cells": _valid_resident_cells,
		"clipmap_lod_count": PREPARED_LEVELS, "clipmap_update_count": _clipmap_update_count,
		"clipmap_camera_world": _clipmap_camera_world, "clipmap_anchor_world": _clipmap_anchor_world,
		"dimensions": dimensions, "origin_world": origin_world, "spacing_m": spacing_m,
		"domain_bounds_world": domain_bounds_world, "source_signature": source_signature,
		"texture_count": 1, "resources_valid": is_ready_resources(), "ready": _ready,
		"relight_revision": _relight_revision, "dispatch_count": _last_dispatch_count,
		"last_error": _error, "gpu_bytes": _gpu_bytes}
