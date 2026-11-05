@tool
extends "magic_gi_dynamic_volume_cache.gd"
## A fixed resident CLV of baked linear transfer operators. Geometry is used
## only by the offline builder; updates are matrix products and texture stores.

const PREPARED_LAYOUT_VERSION := 8
const PREPARED_LEVELS := 4
const PREPARED_SHADER := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_transfer_relight.glsl"
const PREPARED_SHADER_R16 := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_transfer_relight_r16.glsl"
const EditorSnapshot = preload("magic_gi_clv_editor_snapshot.gd")
const OLVDomain = preload("../../feng-magic-gi/feng_magic_gi_olv_domain.gd")
## Set before create(). Changing the resident window requires recreating its GPU
## resources; source spacing and the four baked transfer levels stay unchanged.
var resolution := CLIPMAP_RESOLUTION
var profile_updates := false
var _prepared_dimensions := PackedInt32Array()
var _prepared_offsets := PackedInt32Array()
var _prepared_validity := PackedByteArray()
var _operator_columns := 0
var _operator_schema_version := 2
var _input_coefficient_count := 4
var _output_coefficient_count := 4
var _response_field_count := 4
var _runtime_layout_version := PREPARED_LAYOUT_VERSION
var _gpu_bytes := 0
var _operator_bound := 0.0
var _half_fields := false
var _decode_scale := 1.0
var _resident_indices := PackedInt32Array()
var _valid_cells_per_lod := PackedInt32Array([0, 0, 0, 0])
var _valid_resident_cells := 0
var _olv_label_set: Resource
var _olv_label_context: Dictionary = {}
var _olv_label_blocks: Dictionary = {}
var _olv_label_resolution := 0
var _olv_label_lod_count := 0
var _olv_label_encoding := 1
var _olv_label_atlas := RID()
var _olv_label_parameters := RID()
var _olv_labels_hash := ""
var _olv_upload_count := 0
var _olv_uploaded_bytes := 0
var _olv_enabled := false
var _olv_partition_indices := RID()
var _olv_partition_weights := RID()
var _olv_partition_shader := RID()
var _olv_partition_pipeline := RID()
var _olv_partition_sampler := RID()
var _olv_partition_uniform_set := RID()
var _olv_resident_labels := PackedByteArray()
var _olv_mapped_indices := PackedInt32Array()
var _olv_lod_labels: Array[PackedByteArray] = []
var _olv_lod_label_origins: Dictionary = {}
var _olv_partition_update_count := 0
var _olv_partition_updated_lods := 0
var _raw_response := RID()
var _premix_shader := RID()
var _premix_pipeline := RID()
var _premix_sampler := RID()
var _premix_origins := RID()
var _premix_uniforms := RID()
var _premix_mapping_revision := -1
var _premix_dispatch_count := 0

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
		camera_forward := Vector3.FORWARD, olv_label_set: Resource = null,
		olv_context: Dictionary = {}) -> bool:
	if resolution not in [16, 24, 32]:
		_error = "prepared_clv_resolution_must_be_16_24_or_32"
		return false
	if source != null and int(source.get("clv_preparation_schema_version")) != 2:
		_error = "prepared_sh9_cache_requires_sh2_rebake"
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
	_operator_schema_version = 2
	_input_coefficient_count = 4
	_output_coefficient_count = 4
	_response_field_count = 4
	_runtime_layout_version = PREPARED_LAYOUT_VERSION
	_prepared_dimensions = source.clv_prepared_dimensions
	_prepared_offsets = source.clv_prepared_offsets
	_prepared_validity = source.clv_prepared_validity
	source_probe_count = _prepared_validity.size()
	_operator_columns = 16 + emitter_count * 6
	_operator_bound = float(source.clv_preparation_stats.get("maximum_operator_row_l1", 0.0))
	_half_fields = is_finite(_operator_bound) and _operator_bound > 0.0
	dimensions = Vector3i(resolution, resolution, resolution * PREPARED_LEVELS)
	clip_cell_count = dimensions.x * dimensions.y * dimensions.z
	if olv_label_set != null and not _configure_olv(rd, olv_label_set, olv_context,
			int(source.get("geometry_signature")), Vector3(source.get("origin_world")),
			float(source.get("spacing_m")), dimensions, PREPARED_LEVELS):
		# An invalid/stale sidecar never prevents the legacy prepared SH2 cache from
		# being used. It simply does not publish label bindings.
		_clear_olv_binding(rd)
	response_resolution = 8 # Legacy bridge field; the response field count is explicit below.
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
	format.width = dimensions.x * _response_partition_count()
	format.height = dimensions.y
	format.depth = dimensions.z * _response_field_count
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	if not _create_response_fields(rd, format): return false
	var dummy := RDTextureFormat.new()
	dummy.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	dummy.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	dummy.width = 1
	dummy.height = 1
	dummy.depth = 1
	dummy.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	moment_texture = rd.texture_create(dummy, RDTextureView.new(), [PackedFloat32Array([0, 0]).to_byte_array()])
	_shader_resource = load(_prepared_relight_shader_path()) as RDShaderFile
	if _shader_resource == null or not _shader_resource.base_error.is_empty():
		_error = "clv_transfer_relight_shader_unavailable"
		return false
	var spirv := _shader_resource.get_spirv()
	if spirv == null or not spirv.compile_error_compute.is_empty():
		_error = "clv_transfer_relight_shader_not_compiled"
		return false
	_shader = rd.shader_create_from_spirv(spirv, "Magic GI CLV Transfer Relight")
	_pipeline = rd.compute_pipeline_create(_shader)
	_gpu_bytes = operators.size() * 4 + clip_cell_count * (4 + 2 * _response_partition_count() * _response_field_count * (8 if _half_fields else 16)) + empty.size() * 4 + 284
	if _olv_label_atlas.is_valid():
		_gpu_bytes += _olv_label_resolution * _olv_label_resolution * _olv_label_resolution * _olv_label_lod_count + clip_cell_count * 64 + 32
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
	_disable_olv_gate(rd)
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
	if _olv_label_atlas.is_valid() and not _upload_olv_labels(rd, _build_resident_olv_labels()):
		_error = "clv_partition_upload_failed"
		return false
	var bytes := origins.to_byte_array()
	bytes.append_array(PackedInt32Array([dimensions.x, dimensions.y, dimensions.z, _runtime_layout_version]).to_byte_array())
	bytes.append_array(PackedFloat32Array([_decode_scale]).to_byte_array())
	bytes.append_array(PackedInt32Array([_response_field_count, PREPARED_LEVELS, resolution]).to_byte_array())
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
	var partition_count := _response_partition_count()
	var relight_indices := _olv_partition_indices if partition_count == 2 else _clip_source_indices
	var relight_uniforms: Array[RDUniform] = [U.storage_buffer(0, _transfer),
		U.storage_buffer(1, relight_indices), U.storage_buffer(2, _live_sources),
		U.uniform_buffer(3, live_gi_ubo), U.image(4, _raw_response)]
	if partition_count == 2: relight_uniforms.append(U.storage_buffer(5, _olv_partition_weights))
	var uniforms := UniformSetCacheRD.get_cache(_shader, 0, relight_uniforms)
	if not uniforms.is_valid():
		_error = "clv_relight_uniform_set_failed"
		return false
	if profile_timestamps: rd.capture_timestamp("Magic GI Dynamic Volume Relight Begin")
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	var relight_cells := clip_cell_count * partition_count
	var push := PackedInt32Array([relight_cells, source_probe_count, emitter_count,
		_operator_columns, dimensions.x * partition_count, dimensions.y, dimensions.z]).to_byte_array()
	push.append_array(PackedFloat32Array([1.0 / _decode_scale]).to_byte_array())
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (relight_cells + 63) / 64, 1, 1)
	rd.compute_list_end()
	if profile_timestamps: rd.capture_timestamp("Magic GI Dynamic Volume Relight End")
	if not _premix_response(rd, profile_timestamps): return false
	_last_lighting_key = key.duplicate(true)
	_last_live_sources = live.duplicate()
	_ready = true
	_last_dispatch_count += 1
	_relight_revision += 1
	return true

func is_ready_resources() -> bool:
	return _premix_pipeline.is_valid() and _raw_response.is_valid() \
		and _pipeline.is_valid() and _shader.is_valid() and parameters.is_valid() \
		and _transfer.is_valid() and _live_sources.is_valid() and _clip_source_indices.is_valid() \
		and _clip_validity.is_valid() and _clip_relocation.is_valid() \
		and texture_fields.size() == 1 and texture_fields[0].is_valid() and moment_texture.is_valid()

func _configure_olv(rd: RenderingDevice, labels: Resource, context: Dictionary,
		geometry_signature: int, source_origin: Vector3, source_spacing: float,
		label_dimensions: Vector3i, lod_count: int) -> bool:
	if rd == null or labels == null or not labels.has_method("validate") \
			or not labels.has_method("matches_bake"):
		return false
	if lod_count <= 0 or label_dimensions.x != resolution \
			or label_dimensions.y != resolution \
			or label_dimensions.z != resolution * lod_count:
		return false
	for required in ["scene_id", "volume_id", "layout_revision", "layout_signature",
			"grid_origin_world", "base_cell_spacing_m", "labels_hash"]:
		if not context.has(required): return false
	var validated: Dictionary = labels.call("validate")
	if not bool(validated.get("ok", false)):
		return false
	var scene_id := String(context.get("scene_id", ""))
	var volume_id := String(context.get("volume_id", ""))
	var layout_revision := int(context.get("layout_revision", -1))
	var layout_signature := String(context.get("layout_signature", ""))
	var grid_origin: Variant = context.get("grid_origin_world")
	var base_spacing := float(context.get("base_cell_spacing_m", 0.0))
	if scene_id.is_empty() or volume_id.is_empty() or layout_revision < 0 \
			or layout_signature.is_empty() or not grid_origin is Vector3 \
			or not Vector3(grid_origin).is_finite() \
			or not is_finite(base_spacing) or base_spacing <= 0.0 \
			or not source_origin.is_finite() or not is_finite(source_spacing) \
			or absf(source_spacing - base_spacing) > 0.000001 \
			or Vector3(grid_origin).distance_to(source_origin) > 0.0001:
		return false
	if String(labels.get("labels_hash")) != String(context.get("labels_hash")) \
			or not bool(labels.call("matches_bake", scene_id, volume_id,
				layout_revision, geometry_signature, layout_signature)):
		return false
	var raw_cells: Variant = labels.get("cell_labels")
	if not raw_cells is Dictionary:
		return false
	var complete_receivers := bool(labels.get("receiver_labels_complete"))
	var receiver_cells: Dictionary = labels.get("receiver_labels")
	_olv_label_encoding = 2 if complete_receivers else 1
	var blocks: Dictionary = {}
	for encoded_key: Variant in raw_cells:
		if not encoded_key is String: return false
		var identity: Dictionary = OLVDomain.parse_identity_key(String(encoded_key))
		if identity.is_empty() or String(identity.get("scene_id", "")) != scene_id \
				or String(identity.get("volume_id", "")) != volume_id \
				or int(identity.get("layout_revision", -1)) != layout_revision:
			return false
		var cell: Vector3i = identity.global_cell
		var label := int(raw_cells[encoded_key])
		if label not in [OLVDomain.LABEL_EXTERIOR, OLVDomain.LABEL_INTERIOR]: continue
		if complete_receivers:
			# Low two bits retain the lighting source's domain; upper two bits
			# describe the logical receiver anchor. The GPU atlas stays R8.
			label |= int(receiver_cells.get(encoded_key, OLVDomain.LABEL_UNSET)) << 2
		var block := Vector3i(floori(cell.x / 16.0), floori(cell.y / 16.0), floori(cell.z / 16.0))
		var block_key := Vector4i(block.x, block.y, block.z, int(identity.lod))
		if not blocks.has(block_key): blocks[block_key] = []
		blocks[block_key].append(Vector4i(cell.x, cell.y, cell.z, label))
	_olv_label_set = labels
	_olv_label_context = context.duplicate(true)
	_olv_label_blocks = blocks
	# A categorical lookup must not lose the fine source labels just because
	# their SH operators are outside the smaller lighting window. The byte-only
	# halo covers the next lighting cascade; it adds no SH or relight work.
	_olv_label_resolution = resolution * 2
	_olv_label_lod_count = lod_count
	_olv_labels_hash = String(context.labels_hash)
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	format.width = _olv_label_resolution
	format.height = _olv_label_resolution
	format.depth = _olv_label_resolution * lod_count
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_olv_label_atlas = rd.texture_create(format, RDTextureView.new(), [])
	if not _olv_label_atlas.is_valid():
		_clear_olv_binding(rd)
		return false
	var metadata := PackedInt32Array([label_dimensions.x, label_dimensions.y,
		label_dimensions.z, _runtime_layout_version, _olv_label_encoding, 0,
		_olv_label_resolution * lod_count, _olv_label_resolution])
	_olv_label_parameters = rd.uniform_buffer_create(metadata.size() * 4,
		metadata.to_byte_array())
	if not _olv_label_parameters.is_valid() or not _create_olv_partition_resources(rd):
		_clear_olv_binding(rd)
		return false
	return true

func _create_response_fields(rd: RenderingDevice, format: RDTextureFormat) -> bool:
	_raw_response = rd.texture_create(format, RDTextureView.new(), [])
	texture_fields = [rd.texture_create(format, RDTextureView.new(), [])]
	var path := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_premix_r16.glsl" if _half_fields \
		else "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_premix.glsl"
	var resource := load(path) as RDShaderFile
	if resource == null or not resource.base_error.is_empty():
		_error = "clv_premix_shader_unavailable: " + (resource.base_error if resource != null else path)
		return false
	var spirv := resource.get_spirv()
	if spirv == null or not spirv.compile_error_compute.is_empty():
		_error = "clv_premix_shader_not_compiled: " + (spirv.compile_error_compute if spirv != null else path)
		return false
	_premix_shader = rd.shader_create_from_spirv(spirv, "Magic GI CLV Cascade Premix")
	_premix_pipeline = rd.compute_pipeline_create(_premix_shader)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_premix_sampler = rd.sampler_create(state)
	_premix_origins = rd.storage_buffer_create(160)
	return _raw_response.is_valid() and texture_fields[0].is_valid() \
		and _premix_pipeline.is_valid() and _premix_sampler.is_valid() and _premix_origins.is_valid()

func _premix_response(rd: RenderingDevice, profile_timestamps: bool) -> bool:
	if _premix_mapping_revision != _clipmap_update_count:
		var origins := PackedFloat32Array()
		origins.resize(40)
		for level in _lod_layouts.size():
			var lod: Dictionary = _lod_layouts[level]
			var origin: Vector3 = lod.origin_world
			for axis in 3: origins[level * 4 + axis] = origin[axis]
			origins[level * 4 + 3] = lod.spacing_m
		if rd.buffer_update(_premix_origins, 0, 160, origins.to_byte_array()) != OK:
			_error = "clv_premix_origins_upload_failed"
			return false
		_premix_mapping_revision = _clipmap_update_count
	if not _premix_uniforms.is_valid():
		_premix_uniforms = rd.uniform_set_create([
			U.sampled(0, _premix_sampler, _raw_response), U.image(1, texture_fields[0]),
			U.storage_buffer(2, _premix_origins)], _premix_shader, 0)
	if not _premix_uniforms.is_valid():
		_error = "clv_premix_uniform_set_failed"
		return false
	if profile_timestamps: rd.capture_timestamp("Magic GI CLV Premix Begin")
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _premix_pipeline)
	rd.compute_list_bind_uniform_set(list, _premix_uniforms, 0)
	var partitions := _response_partition_count()
	var push := PackedInt32Array([resolution, _lod_layouts.size(), partitions, _response_field_count]).to_byte_array()
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (clip_cell_count * partitions + 63) / 64, 1, 1)
	rd.compute_list_end()
	if profile_timestamps: rd.capture_timestamp("Magic GI CLV Premix End")
	_premix_dispatch_count += 1
	return true

func _prepared_relight_shader_path() -> String:
	if _olv_label_atlas.is_valid():
		return "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_partition_relight_r16.glsl" if _half_fields \
			else "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_partition_relight.glsl"
	return PREPARED_SHADER_R16 if _half_fields else PREPARED_SHADER

func _response_partition_count() -> int:
	return 2 if _olv_label_atlas.is_valid() else 1

func _create_olv_partition_resources(rd: RenderingDevice) -> bool:
	var shader_file := load("res://addons/feng-render-pipeline/library/magic-gi/magic_gi_olv_partition_indices.glsl") as RDShaderFile
	if shader_file == null or not shader_file.base_error.is_empty(): return false
	var spirv := shader_file.get_spirv()
	if spirv == null or not spirv.compile_error_compute.is_empty(): return false
	_olv_partition_shader = rd.shader_create_from_spirv(spirv, "Magic GI OLV Partition Mapping")
	_olv_partition_pipeline = rd.compute_pipeline_create(_olv_partition_shader)
	_olv_partition_indices = rd.storage_buffer_create(clip_cell_count * 32)
	_olv_partition_weights = rd.storage_buffer_create(clip_cell_count * 32)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_olv_partition_sampler = rd.sampler_create(sampler_state)
	return _olv_partition_shader.is_valid() and _olv_partition_pipeline.is_valid() \
		and _olv_partition_indices.is_valid() and _olv_partition_weights.is_valid() and _olv_partition_sampler.is_valid()

func _update_olv_partition_indices(rd: RenderingDevice, lod_mask: int) -> bool:
	if lod_mask == 0: return true
	if not _olv_partition_pipeline.is_valid() or not _clip_source_indices.is_valid(): return false
	var texture_uniform := RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
	texture_uniform.binding = 1
	texture_uniform.add_id(_olv_label_atlas)
	var sampler_uniform := RDUniform.new()
	sampler_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
	sampler_uniform.binding = 2
	sampler_uniform.add_id(_olv_partition_sampler)
	if not _olv_partition_uniform_set.is_valid():
		_olv_partition_uniform_set = rd.uniform_set_create([
			U.storage_buffer(0, _clip_source_indices), texture_uniform, sampler_uniform,
			U.storage_buffer(3, _olv_partition_indices), U.storage_buffer(4, _olv_partition_weights)], _olv_partition_shader, 0)
	if not _olv_partition_uniform_set.is_valid(): return false
	if profile_updates: rd.capture_timestamp("Magic GI OLV Mapping Begin")
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _olv_partition_pipeline)
	rd.compute_list_bind_uniform_set(list, _olv_partition_uniform_set, 0)
	var push := PackedInt32Array([resolution, _olv_label_lod_count, _olv_label_resolution, _olv_label_encoding, lod_mask]).to_byte_array()
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (clip_cell_count * 2 + 63) / 64, 1, 1)
	rd.compute_list_end()
	if profile_updates: rd.capture_timestamp("Magic GI OLV Mapping End")
	_olv_partition_update_count += 1
	for lod in _olv_label_lod_count:
		if lod_mask & (1 << lod): _olv_partition_updated_lods += 1
	return true

func _build_resident_olv_labels() -> PackedByteArray:
	var labels := PackedByteArray()
	var side := _olv_label_resolution
	var cells_per_lod := side * side * side
	_olv_lod_labels.resize(_olv_label_lod_count)
	var halo := (side - resolution) / 2
	var base_origin: Vector3 = _olv_label_context.get("grid_origin_world", Vector3.ZERO)
	var base_spacing := float(_olv_label_context.get("base_cell_spacing_m", 0.25))
	for lod in _lod_layouts:
		var level := int(lod.get("level", lod.get("lod", 0)))
		if level < 0 or level >= _olv_label_lod_count: continue
		var step := base_spacing * float(1 << level)
		var first := Vector3i(((Vector3(lod.origin_world) - base_origin) / step).round()) - Vector3i.ONE * halo
		if _olv_lod_label_origins.get(level) == first and _olv_lod_labels[level].size() == cells_per_lod:
			continue
		var layer := PackedByteArray()
		layer.resize(cells_per_lod)
		var last := first + Vector3i.ONE * (side - 1)
		var begin_block := Vector3i(floori(first.x / 16.0), floori(first.y / 16.0), floori(first.z / 16.0))
		var end_block := Vector3i(floori(last.x / 16.0), floori(last.y / 16.0), floori(last.z / 16.0))
		for bz in range(begin_block.z, end_block.z + 1):
			for by in range(begin_block.y, end_block.y + 1):
				for bx in range(begin_block.x, end_block.x + 1):
					for record: Vector4i in _olv_label_blocks.get(Vector4i(bx, by, bz, level), []):
						var relative := Vector3i(record.x, record.y, record.z) - first
						if relative.x < 0 or relative.y < 0 or relative.z < 0 \
								or relative.x >= side or relative.y >= side or relative.z >= side: continue
						var slot := (relative.z * side + relative.y) * side + relative.x
						layer[slot] = record.w
		_olv_lod_labels[level] = layer
		_olv_lod_label_origins[level] = first
	for layer in _olv_lod_labels: labels.append_array(layer)
	return labels

func _upload_olv_labels(rd: RenderingDevice, labels: PackedByteArray) -> bool:
	if not _olv_label_atlas.is_valid(): return true
	var depth := _olv_label_resolution * _olv_label_lod_count
	if rd == null or labels.size() != _olv_label_resolution * _olv_label_resolution * depth:
		return false
	var lod_mask := 0
	var label_stride := _olv_label_resolution * _olv_label_resolution * _olv_label_resolution
	var index_stride := resolution * resolution * resolution
	if _olv_resident_labels.size() != labels.size() or _olv_mapped_indices.size() != _resident_indices.size():
		lod_mask = (1 << _olv_label_lod_count) - 1
	else:
		for lod in _olv_label_lod_count:
			if labels.slice(lod * label_stride, (lod + 1) * label_stride) \
					!= _olv_resident_labels.slice(lod * label_stride, (lod + 1) * label_stride) \
					or _resident_indices.slice(lod * index_stride, (lod + 1) * index_stride) \
					!= _olv_mapped_indices.slice(lod * index_stride, (lod + 1) * index_stride):
				lod_mask |= 1 << lod
	var metadata_disabled := PackedInt32Array([dimensions.x, dimensions.y, dimensions.z,
		_runtime_layout_version, _olv_label_encoding, 0, depth, _olv_label_resolution]).to_byte_array()
	if rd.buffer_update(_olv_label_parameters, 0, metadata_disabled.size(), metadata_disabled) != OK:
		return false
	var payload := labels
	if payload != _olv_resident_labels:
		if profile_updates: rd.capture_timestamp("Magic GI OLV Upload Begin")
		if rd.texture_update(_olv_label_atlas, 0, payload) != OK: return false
		if profile_updates: rd.capture_timestamp("Magic GI OLV Upload End")
		_olv_upload_count += 1
		_olv_uploaded_bytes += payload.size()
	if not _update_olv_partition_indices(rd, lod_mask): return false
	_olv_resident_labels = labels
	_olv_mapped_indices = _resident_indices
	var metadata_enabled := PackedInt32Array([dimensions.x, dimensions.y, dimensions.z,
		_runtime_layout_version, _olv_label_encoding, 1, depth, _olv_label_resolution]).to_byte_array()
	if rd.buffer_update(_olv_label_parameters, 0, metadata_enabled.size(), metadata_enabled) != OK:
		return false
	_olv_enabled = true
	return true

func _disable_olv_gate(rd: RenderingDevice) -> void:
	_olv_enabled = false
	if rd != null and _olv_label_parameters.is_valid():
		rd.buffer_update(_olv_label_parameters, 20, 4, PackedInt32Array([0]).to_byte_array())

func _clear_olv_binding(rd: RenderingDevice) -> void:
	_olv_enabled = false
	if rd != null:
		for rid in [_olv_partition_uniform_set, _olv_label_atlas, _olv_label_parameters,
			_olv_partition_indices, _olv_partition_weights, _olv_partition_pipeline, _olv_partition_shader, _olv_partition_sampler]:
			if rid.is_valid(): rd.free_rid(rid)
	_olv_label_atlas = RID()
	_olv_label_parameters = RID()
	_olv_partition_indices = RID()
	_olv_partition_weights = RID()
	_olv_partition_pipeline = RID()
	_olv_partition_shader = RID()
	_olv_partition_sampler = RID()
	_olv_partition_uniform_set = RID()
	_olv_resident_labels.clear()
	_olv_mapped_indices.clear()
	_olv_lod_labels.clear()
	_olv_lod_label_origins.clear()
	_olv_label_set = null
	_olv_label_context.clear()
	_olv_label_blocks.clear()
	_olv_label_resolution = 0
	_olv_label_lod_count = 0
	_olv_label_encoding = 1
	_olv_labels_hash = ""

func has_olv_binding() -> bool:
	return _olv_enabled and _olv_label_atlas.is_valid() and _olv_label_parameters.is_valid()

func get_olv_binding() -> Dictionary:
	return {"enabled": has_olv_binding(), "label_atlas": _olv_label_atlas,
		"label_parameters": _olv_label_parameters, "labels_hash": _olv_labels_hash}

func owned_rids() -> Array[RID]:
	var result: Array[RID] = []
	if _premix_uniforms.is_valid(): result.append(_premix_uniforms)
	if _olv_partition_uniform_set.is_valid(): result.append(_olv_partition_uniform_set)
	result.append_array(super.owned_rids())
	for rid in [_olv_label_atlas, _olv_label_parameters,
			_olv_partition_indices, _olv_partition_weights, _olv_partition_pipeline, _olv_partition_shader, _olv_partition_sampler,
			_raw_response, _premix_pipeline, _premix_shader, _premix_sampler, _premix_origins]:
		if rid.is_valid(): result.append(rid)
	return result

## Called only after the editor broker admits an explicit request. Snapshot the
## exact resident mapping/decode scale alongside the ordered GPU copy, so a later
## camera move or relight cannot pair new metadata with older texture contents.
func request_editor_snapshot(rd: RenderingDevice, request: Dictionary) -> Error:
	if rd == null or not _ready or not is_ready_resources() or request.is_empty():
		return ERR_UNAVAILABLE
	var metadata := request.duplicate(true)
	metadata["layout_version"] = int(get_runtime_state().get("layout_version", _runtime_layout_version))
	metadata["response_field_count"] = _response_field_count
	metadata["operator_schema_version"] = _operator_schema_version
	metadata["dimensions"] = dimensions
	metadata["resident_indices"] = _resident_indices.duplicate()
	metadata["response_partition_count"] = _response_partition_count()
	metadata["olv_labels"] = _olv_resident_labels
	metadata["olv_label_side"] = _olv_label_resolution
	metadata["olv_label_encoding"] = _olv_label_encoding
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
	return {"layout_version": _runtime_layout_version, "preinterpolated_transfer": true,
		"olv_enabled": has_olv_binding(), "olv_labels_hash": _olv_labels_hash,
		"olv_label_encoding": _olv_label_encoding,
		"olv_atlas_upload_count": _olv_upload_count,
		"olv_atlas_uploaded_bytes": _olv_uploaded_bytes,
		"operator_schema_version": _operator_schema_version,
		"operator_input_coefficients": _input_coefficient_count,
		"operator_output_coefficients": _output_coefficient_count,
		"response_field_count": _response_field_count,
		"response_partition_count": _response_partition_count(),
		"cascade_blending": "compute_premix_center_aligned",
		"premix_dispatch_count": _premix_dispatch_count,
		"pixel_cascade_blend_samples": 1,
		"olv_partition_update_count": _olv_partition_update_count,
		"olv_partition_updated_lods": _olv_partition_updated_lods,
		"sh_basis": "real_orthonormal_l0_l1_coefficients4",
		"runtime_geometry_queries": 0, "runtime_pixel_neighbor_loop": false,
		"field_format": "RGBA16F" if _half_fields else "RGBA32F", "decode_scale": _decode_scale,
		"probe_count": probe_count, "source_probe_count": source_probe_count,
		"clip_cell_count": clip_cell_count, "clipmap_resolution": resolution,
		"valid_resident_cells": _valid_resident_cells,
		"clipmap_lod_count": PREPARED_LEVELS, "clipmap_update_count": _clipmap_update_count,
		"clipmap_camera_world": _clipmap_camera_world, "clipmap_anchor_world": _clipmap_anchor_world,
		"dimensions": dimensions, "origin_world": origin_world, "spacing_m": spacing_m,
		"domain_bounds_world": domain_bounds_world, "source_signature": source_signature,
		"texture_count": 2, "resources_valid": is_ready_resources(), "ready": _ready,
		"relight_revision": _relight_revision, "dispatch_count": _last_dispatch_count,
		"last_error": _error, "gpu_bytes": _gpu_bytes}
