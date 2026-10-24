@tool
extends RefCounted
## Runtime relight of the independent free-space source volume.
## The source chunk is immutable; only live SH/emitter inputs change per revision.

const U = preload("../rd/uniforms.gd")
const Clipmap = preload("../../feng-magic-gi/feng_magic_gi_volume_clipmap.gd")
const RELIGHT_SHADER_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_dynamic_volume_relight.glsl"
const PROJECT_SHADER_PATH := "res://addons/feng-render-pipeline/library/magic-gi/magic_gi_dynamic_volume_project.glsl"

const LAYOUT_VERSION := 4
const FIELD_COUNT := 1
const PARAMETERS_BYTES := 96
const SHADER_WORKGROUP_SIZE := 64
const CLIPMAP_RESOLUTION := 16
const CLIPMAP_LOD_COUNT := 3
const DEFAULT_RESPONSE_RESOLUTION := 8
const RESPONSE_RESOLUTIONS := [8, 12, 16]
const RAW_SH_FLOATS_PER_CELL := 28
const FIELD_FORMAT := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
const MOMENT_TILE_SIZE := 10
const MOMENT_FORMAT := RenderingDevice.DATA_FORMAT_R32G32_SFLOAT

var dimensions := Vector3i.ZERO
var source_dimensions := Vector3i.ZERO
var source_probe_count := 0
var clip_cell_count := 0
var response_resolution := DEFAULT_RESPONSE_RESOLUTION
var response_tile_size := DEFAULT_RESPONSE_RESOLUTION + 2
var origin_world := Vector3.ZERO
var spacing_m := 0.0
var domain_bounds_world := AABB()
var probe_count := 0
var emitter_count := 0
var source_signature := ""
var texture_fields: Array[RID] = []
var moment_texture := RID()
var parameters := RID()

var _shader := RID()
var _pipeline := RID()
var _shader_resource: RDShaderFile
var _project_shader := RID()
var _project_pipeline := RID()
var _project_shader_resource: RDShaderFile
var _transfer := RID()
var _sky := RID()
var _emission := RID()
var _validity := RID()
var _moments := RID()
var _relocation := RID()
var _clip_source_indices := RID()
var _clip_validity := RID()
var _clip_relocation := RID()
var _live_sources := RID()
var _raw_sh := RID()
var _last_live_sources := PackedFloat32Array()
var _last_lighting_key: Array = []
var _ready := false
var _error := ""
var _last_dispatch_count := 0
var _relight_revision := 0
var _clipmap_state: Dictionary = {}
var _lod_layouts: Array[Dictionary] = []
var _clipmap_update_count := 0
var _clipmap_camera_world := Vector3.ZERO
var _clipmap_camera_forward := Vector3.FORWARD
var _clipmap_anchor_world := Vector3.ZERO
var _clipmap_anchor_mode := "uninitialized"

func create(rd: RenderingDevice, source: Resource, prepared_validation := false,
		requested_response_resolution := DEFAULT_RESPONSE_RESOLUTION,
		camera_world := Vector3.ZERO,
		camera_forward := Vector3.FORWARD) -> bool:
	if not RESPONSE_RESOLUTIONS.has(requested_response_resolution):
		_error = "dynamic_volume_response_resolution_must_be_8_12_or_16"
		return false
	response_resolution = requested_response_resolution
	response_tile_size = response_resolution + 2
	if rd == null or not is_instance_valid(source) \
			or not source.has_method("is_header_valid") \
			or not bool(source.call("is_header_valid")) \
			or (not prepared_validation and (not source.has_method("is_valid") \
				or not bool(source.call("is_valid")))):
		_error = "invalid_free_space_source_chunk"
		return false
	if source.has_method("storage_probe_count") and int(source.get("format_version")) >= 2:
		_error = "packed_source_requires_preinterpolated_clv"
		return false
	var source_dims: Variant = source.get("dimensions")
	var source_origin: Variant = source.get("origin_world")
	var source_bounds: Variant = source.get("domain_bounds_world")
	var source_spacing := float(source.get("spacing_m"))
	var source_probes := int(source.get("probe_count"))
	var source_emitters := int(source.get("emitter_count"))
	if not source_dims is Vector3i or not source_origin is Vector3 \
			or not source_bounds is AABB or source_probes <= 0 \
			or source_emitters < 0 or source_emitters > 32 \
			or not is_finite(source_spacing) or absf(source_spacing - 0.25) > 0.000001:
		_error = "free_space_source_header_invalid"
		return false
	source_dimensions = source_dims
	source_probe_count = source_probes
	dimensions = Vector3i(CLIPMAP_RESOLUTION, CLIPMAP_RESOLUTION,
			CLIPMAP_RESOLUTION * CLIPMAP_LOD_COUNT)
	clip_cell_count = dimensions.x * dimensions.y * dimensions.z
	origin_world = source_origin
	domain_bounds_world = source_bounds
	spacing_m = source_spacing
	probe_count = source_probes
	emitter_count = source_emitters
	source_signature = str(source.get("directional_source_signature"))
	if source_signature.is_empty():
		_error = "free_space_source_signature_missing"
		return false
	var transfer_value: Variant = source.get("transfer")
	var sky_value: Variant = source.get("sky")
	var emission_value: Variant = source.get("emission")
	var validity_value: Variant = source.get("validity")
	var relocation_value: Variant = source.get("relocation_offset_m")
	var moments_value: Variant = source.get("receiver_visibility_moments")
	if not transfer_value is PackedFloat32Array \
			or not sky_value is PackedFloat32Array \
			or not emission_value is PackedFloat32Array \
			or not validity_value is PackedByteArray \
			or not relocation_value is PackedVector3Array \
			or not moments_value is PackedFloat32Array:
		_error = "free_space_source_payload_types_invalid"
		return false
	var transfer: PackedFloat32Array = transfer_value
	var sky: PackedFloat32Array = sky_value
	var emission: PackedFloat32Array = emission_value
	var validity: PackedByteArray = validity_value
	var relocation: PackedVector3Array = relocation_value
	var moments: PackedFloat32Array = moments_value
	if transfer.size() != probe_count * 243 or sky.size() != probe_count * 81 \
			or emission.size() != emitter_count * probe_count * 54 \
			or validity.size() != probe_count or relocation.size() != probe_count \
			or moments.size() != probe_count * 128:
		_error = "free_space_source_payload_size_mismatch"
		return false
	var source_validity := PackedInt32Array()
	source_validity.resize(probe_count)
	for index in probe_count:
		var state := int(validity[index])
		if state < 0 or state > 2:
			_error = "free_space_source_validity_value_invalid"
			return false
		source_validity[index] = state
	if not _create_source_buffers(rd, transfer, sky, emission, source_validity,
			relocation, moments):
		return false
	if not _create_output_resources(rd):
		return false
	if not update_clipmap(rd, source, camera_world, true, camera_forward):
		return false
	# Load lazily: source-only pages are optional, and an absent/unimported dynamic
	# shader must not break parsing or startup for legacy-only projects.
	var shader_value: Variant = ResourceLoader.load(RELIGHT_SHADER_PATH)
	if not shader_value is RDShaderFile:
		_error = "dynamic_volume_relight_shader_unavailable"
		return false
	_shader_resource = shader_value as RDShaderFile
	var spirv := _shader_resource.get_spirv()
	if spirv == null or _shader_resource.base_error != "" \
			or not spirv.compile_error_compute.is_empty() \
			or spirv.bytecode_compute.is_empty():
		_error = "dynamic_volume_relight_shader_not_compiled"
		return false
	_shader = rd.shader_create_from_spirv(spirv, "Magic GI Free Space Volume Relight")
	if not _shader.is_valid():
		_error = "dynamic_volume_relight_shader_create_failed"
		return false
	_pipeline = rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_error = "dynamic_volume_relight_pipeline_create_failed"
		return false
	var project_value: Variant = ResourceLoader.load(PROJECT_SHADER_PATH)
	if not project_value is RDShaderFile:
		_error = "dynamic_volume_project_shader_unavailable"
		return false
	_project_shader_resource = project_value as RDShaderFile
	var project_spirv := _project_shader_resource.get_spirv()
	if project_spirv == null or _project_shader_resource.base_error != "" \
			or not project_spirv.compile_error_compute.is_empty() \
			or project_spirv.bytecode_compute.is_empty():
		_error = "dynamic_volume_project_shader_not_compiled"
		return false
	_project_shader = rd.shader_create_from_spirv(project_spirv,
			"Magic GI Free Space Angular Projection")
	if not _project_shader.is_valid():
		_error = "dynamic_volume_project_shader_create_failed"
		return false
	_project_pipeline = rd.compute_pipeline_create(_project_shader)
	if not _project_pipeline.is_valid():
		_error = "dynamic_volume_project_pipeline_create_failed"
		return false
	_error = ""
	return true

func update_clipmap(rd: RenderingDevice, source: Resource, camera_world: Vector3,
		force := false, camera_forward := Vector3.FORWARD) -> bool:
	if rd == null or not is_instance_valid(source):
		_error = "dynamic_volume_clipmap_source_missing"
		return false
	var anchor_result := _clipmap_anchor_from_view(source, camera_world, camera_forward)
	if not bool(anchor_result.get("valid", false)):
		_error = "dynamic_volume_clipmap_anchor_invalid"
		return false
	var anchor_world: Vector3 = anchor_result.anchor_world
	_clipmap_camera_world = camera_world
	_clipmap_camera_forward = camera_forward.normalized() \
			if camera_forward.is_finite() and camera_forward.length_squared() > 1e-8 \
			else Vector3.FORWARD
	_clipmap_anchor_world = anchor_world
	_clipmap_anchor_mode = str(anchor_result.get("mode", "unknown"))
	var layout: Dictionary = Clipmap.build_layout(source, anchor_world,
			CLIPMAP_RESOLUTION, CLIPMAP_LOD_COUNT, _clipmap_state)
	if not bool(layout.get("valid", false)):
		_error = "dynamic_volume_clipmap_layout_invalid:" + str(layout.get("error", "unknown"))
		return false
	var next_state: Dictionary = layout.get("state", {})
	if not force and not _clipmap_state.is_empty() and next_state == _clipmap_state:
		return true
	var lod_values: Variant = layout.get("lods", [])
	if not lod_values is Array or lod_values.size() != CLIPMAP_LOD_COUNT:
		_error = "dynamic_volume_clipmap_lod_count_invalid"
		return false
	var source_indices := PackedInt32Array()
	var clip_validity := PackedInt32Array()
	var clip_relocation := PackedFloat32Array()
	source_indices.resize(clip_cell_count)
	clip_validity.resize(clip_cell_count)
	clip_relocation.resize(clip_cell_count * 4)
	source_indices.fill(-1)
	clip_validity.fill(0)
	clip_relocation.fill(0.0)
	var cells_per_lod := CLIPMAP_RESOLUTION * CLIPMAP_RESOLUTION * CLIPMAP_RESOLUTION
	for lod in CLIPMAP_LOD_COUNT:
		var lod_layout: Dictionary = lod_values[lod]
		for z in CLIPMAP_RESOLUTION:
			for y in CLIPMAP_RESOLUTION:
				for x in CLIPMAP_RESOLUTION:
					var cell := Vector3i(x, y, z)
					var mapped: Dictionary = Clipmap.map_logical_cell(source, lod_layout, cell)
					var logical_index := lod * cells_per_lod + (z * CLIPMAP_RESOLUTION + y) * CLIPMAP_RESOLUTION + x
					if not bool(mapped.get("valid", false)):
						continue
					var source_index := int(mapped.get("source_flat_index", -1))
					if source_index < 0 or source_index >= source_probe_count:
						continue
					source_indices[logical_index] = source_index
					clip_validity[logical_index] = 1
					var offset_value: Variant = mapped.get("relocation_offset_m", Vector3.ZERO)
					if offset_value is Vector3:
						var base := logical_index * 4
						clip_relocation[base] = offset_value.x
						clip_relocation[base + 1] = offset_value.y
						clip_relocation[base + 2] = offset_value.z
	if not _clip_buffers_valid():
		_error = "dynamic_volume_clipmap_buffers_unavailable"
		return false
	if rd.buffer_update(_clip_source_indices, 0, source_indices.size() * 4,
			source_indices.to_byte_array()) != OK \
			or rd.buffer_update(_clip_validity, 0, clip_validity.size() * 4,
				clip_validity.to_byte_array()) != OK \
			or rd.buffer_update(_clip_relocation, 0, clip_relocation.size() * 4,
				clip_relocation.to_byte_array()) != OK:
		_error = "dynamic_volume_clipmap_buffer_update_failed"
		return false
	_lod_layouts.clear()
	var origins := PackedFloat32Array()
	origins.resize(16)
	origins.fill(0.0)
	for lod in CLIPMAP_LOD_COUNT:
		var lod_layout: Dictionary = lod_values[lod]
		_lod_layouts.append(lod_layout.duplicate(true))
		var lod_origin: Vector3 = lod_layout.get("origin_world", Vector3.ZERO)
		var lod_spacing := float(lod_layout.get("spacing_m", 0.0))
		if not lod_origin.is_finite() or not is_finite(lod_spacing) or lod_spacing <= 0.0:
			_error = "dynamic_volume_clipmap_geometry_invalid"
			return false
		var base := lod * 4
		origins[base] = lod_origin.x
		origins[base + 1] = lod_origin.y
		origins[base + 2] = lod_origin.z
		origins[base + 3] = lod_spacing
	var param_bytes := PackedByteArray()
	param_bytes.append_array(origins.to_byte_array())
	param_bytes.append_array(PackedInt32Array([dimensions.x, dimensions.y,
			dimensions.z, LAYOUT_VERSION]).to_byte_array())
	param_bytes.append_array(PackedInt32Array([response_resolution,
			response_tile_size, CLIPMAP_LOD_COUNT, CLIPMAP_RESOLUTION]).to_byte_array())
	if param_bytes.size() != PARAMETERS_BYTES:
		_error = "dynamic_volume_parameters_size_invalid"
		return false
	if parameters.is_valid():
		if rd.buffer_update(parameters, 0, PARAMETERS_BYTES, param_bytes) != OK:
			_error = "dynamic_volume_parameters_update_failed"
			return false
	else:
		parameters = rd.uniform_buffer_create(PARAMETERS_BYTES, param_bytes)
		if not parameters.is_valid():
			_error = "dynamic_volume_parameters_create_failed"
			return false
	origin_world = _lod_layouts[0].get("origin_world", Vector3.ZERO)
	spacing_m = float(_lod_layouts[0].get("spacing_m", 0.0))
	_clipmap_state = next_state.duplicate(true)
	_clipmap_update_count += 1
	_last_lighting_key.clear()
	_ready = false
	_error = ""
	return true

func relight(rd: RenderingDevice, live_gi_ubo: RID, snapshot: Dictionary,
		profile_timestamps := false) -> bool:
	if not is_ready_resources() or not live_gi_ubo.is_valid():
		_error = "dynamic_volume_resources_not_ready"
		return false
	var source_value: Variant = snapshot.get("emission_sources", PackedFloat32Array())
	if not source_value is PackedFloat32Array:
		_error = "dynamic_volume_live_emission_payload_invalid"
		return false
	var source_values: PackedFloat32Array = source_value
	if source_values.size() != emitter_count * 6:
		_error = "dynamic_volume_live_emission_count_mismatch"
		return false
	var key: Array = [snapshot.get("lighting"), snapshot.get("sky_lighting"),
		source_values, snapshot.get("emission_revision", 0), _clipmap_state]
	if _ready and key == _last_lighting_key:
		return true
	if not source_values.is_empty() and source_values != _last_live_sources:
		if rd.buffer_update(_live_sources, 0, source_values.size() * 4,
				source_values.to_byte_array()) != OK:
			_error = "dynamic_volume_live_emission_upload_failed"
			return false
	var relight_uniforms := UniformSetCacheRD.get_cache(_shader, 0, [
		U.storage_buffer(0, _transfer), U.storage_buffer(1, _sky),
		U.storage_buffer(2, _emission), U.storage_buffer(3, _live_sources),
		U.uniform_buffer(4, live_gi_ubo), U.storage_buffer(5, _validity),
		U.storage_buffer(6, _raw_sh), U.storage_buffer(7, _clip_source_indices),
	])
	if not relight_uniforms.is_valid():
		_error = "dynamic_volume_relight_uniform_set_failed"
		return false
	var project_uniforms := UniformSetCacheRD.get_cache(_project_shader, 0,
			[U.storage_buffer(0, _raw_sh), U.storage_buffer(1, _moments),
				U.storage_buffer(2, _clip_source_indices)])
	if not project_uniforms.is_valid():
		_error = "dynamic_volume_project_uniform_set_failed"
		return false
	var project_output_uniforms := UniformSetCacheRD.get_cache(_project_shader, 1,
			[U.image(0, texture_fields[0]), U.image(1, moment_texture)])
	if not project_output_uniforms.is_valid():
		_error = "dynamic_volume_project_output_uniform_set_failed"
		return false
	if profile_timestamps:
		rd.capture_timestamp("Magic GI Dynamic Volume Relight Begin")
	var list := rd.compute_list_begin()
	if list < 0:
		_error = "dynamic_volume_relight_compute_list_failed"
		return false
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, relight_uniforms, 0)
	var push := PackedInt32Array([clip_cell_count, source_probe_count,
		emitter_count, 0]).to_byte_array()
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, (clip_cell_count + SHADER_WORKGROUP_SIZE - 1) \
			/ SHADER_WORKGROUP_SIZE, 1, 1)
	rd.compute_list_end()
	if profile_timestamps:
		rd.capture_timestamp("Magic GI Dynamic Volume Relight End")
		rd.capture_timestamp("Magic GI Dynamic Volume Projection Begin")
	# Projection is a separate pipeline/list so each cell's current SH9 is computed
	# once, then reused for all directions. Ending the first list exposes the raw
	# scratch-buffer writes to the reader pass.
	list = rd.compute_list_begin()
	if list < 0:
		_error = "dynamic_volume_project_compute_list_failed"
		return false
	rd.compute_list_bind_compute_pipeline(list, _project_pipeline)
	rd.compute_list_bind_uniform_set(list, project_uniforms, 0)
	rd.compute_list_bind_uniform_set(list, project_output_uniforms, 1)
	push = PackedInt32Array([clip_cell_count, source_probe_count,
		dimensions.x, dimensions.y, dimensions.z, response_resolution,
		response_tile_size]).to_byte_array()
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, dimensions.x, dimensions.y, dimensions.z)
	rd.compute_list_end()
	if profile_timestamps:
		rd.capture_timestamp("Magic GI Dynamic Volume Projection End")
	_last_live_sources = source_values.duplicate()
	_last_lighting_key = key.duplicate(true)
	_ready = true
	_last_dispatch_count += 1
	_relight_revision += 1
	_error = ""
	return true

func is_ready_resources() -> bool:
	if not _shader.is_valid() or not _pipeline.is_valid() \
			or not _project_shader.is_valid() or not _project_pipeline.is_valid() \
			or not _parameters_valid():
		return false
	if _transfer.is_valid() == false or _sky.is_valid() == false \
			or _emission.is_valid() == false or _validity.is_valid() == false \
			or _moments.is_valid() == false or _relocation.is_valid() == false \
			or _live_sources.is_valid() == false or _raw_sh.is_valid() == false \
			or not moment_texture.is_valid() or texture_fields.size() != FIELD_COUNT \
			or not _clip_buffers_valid():
		return false
	for field in texture_fields:
		if not field.is_valid():
			return false
	return true

func is_ready() -> bool:
	return _ready and is_ready_resources()

func get_field_textures() -> Array[RID]:
	return texture_fields.duplicate()

func get_moments_texture() -> RID:
	return moment_texture

func get_relocation_buffer() -> RID:
	return _clip_relocation

func get_validity_buffer() -> RID:
	return _clip_validity

func get_runtime_state() -> Dictionary:
	return {"layout_version": LAYOUT_VERSION, "probe_count": probe_count,
		"source_dimensions": source_dimensions, "source_probe_count": source_probe_count,
		"clip_cell_count": clip_cell_count, "clipmap_resolution": CLIPMAP_RESOLUTION,
		"clipmap_lod_count": CLIPMAP_LOD_COUNT, "clipmap_update_count": _clipmap_update_count,
		"clipmap_lods": _lod_layouts, "emitter_count": emitter_count, "dimensions": dimensions,
		"clipmap_camera_world": _clipmap_camera_world,
		"clipmap_camera_forward": _clipmap_camera_forward,
		"clipmap_anchor_world": _clipmap_anchor_world,
		"clipmap_anchor_mode": _clipmap_anchor_mode,
		"origin_world": origin_world, "spacing_m": spacing_m,
		"domain_bounds_world": domain_bounds_world,
		"source_signature": source_signature, "texture_count": texture_fields.size(),
		"resources_valid": is_ready_resources(), "ready": _ready,
		"relight_revision": _relight_revision,
		"dispatch_count": _last_dispatch_count, "last_error": _error,
		"padded_grid_bounds_world": _padded_grid_bounds(),
		"response_resolution": response_resolution,
		"response_tile_size": response_tile_size,
		"moment_tile_size": MOMENT_TILE_SIZE,
		"raw_sh_bytes": clip_cell_count * RAW_SH_FLOATS_PER_CELL * 4,
		"gpu_bytes": estimate_gpu_bytes(source_dimensions, emitter_count,
				response_resolution, dimensions)}

func owned_rids() -> Array[RID]:
	var result: Array[RID] = []
	if _pipeline.is_valid(): result.append(_pipeline)
	if _shader.is_valid(): result.append(_shader)
	if _project_pipeline.is_valid(): result.append(_project_pipeline)
	if _project_shader.is_valid(): result.append(_project_shader)
	result.append_array(texture_fields)
	for rid in [_transfer, _sky, _emission, _validity, _moments, _relocation,
			_clip_source_indices, _clip_validity, _clip_relocation,
			_live_sources, _raw_sh, parameters, moment_texture]:
		if rid.is_valid(): result.append(rid)
	return result

static func estimate_gpu_bytes(source_dims: Vector3i, emitters := 0,
		requested_response_resolution := DEFAULT_RESPONSE_RESOLUTION,
		clip_dims := Vector3i(CLIPMAP_RESOLUTION, CLIPMAP_RESOLUTION,
				CLIPMAP_RESOLUTION * CLIPMAP_LOD_COUNT)) -> int:
	if source_dims.x <= 0 or source_dims.y <= 0 or source_dims.z <= 0 \
			or clip_dims.x <= 0 or clip_dims.y <= 0 or clip_dims.z <= 0:
		return 0
	if not RESPONSE_RESOLUTIONS.has(requested_response_resolution):
		return 0
	var source_cells := source_dims.x * source_dims.y * source_dims.z
	var clip_cells := clip_dims.x * clip_dims.y * clip_dims.z
	var tile_size := requested_response_resolution + 2
	var tile_texels := tile_size * tile_size
	var source_bytes := source_cells * (243 + 81 + 54 * maxi(emitters, 0) \
			+ 4 + 128 + 16) * 4
	var clip_bytes := clip_cells * (4 + 4 + 16 + RAW_SH_FLOATS_PER_CELL * 4 \
			+ tile_texels * 16 + MOMENT_TILE_SIZE * MOMENT_TILE_SIZE * 8)
	return source_bytes + clip_bytes + maxi(emitters * 6 * 4, 4) + PARAMETERS_BYTES

func _padded_grid_bounds() -> AABB:
	if _lod_layouts.is_empty():
		return AABB()
	var bounds: AABB = _lod_layouts[0].get("clip_bounds_world", AABB())
	for lod in range(1, _lod_layouts.size()):
		var next_bounds: AABB = _lod_layouts[lod].get("clip_bounds_world", AABB())
		bounds = bounds.merge(next_bounds)
	return bounds

func _parameters_valid() -> bool:
	return parameters.is_valid()

func _clipmap_anchor_resolution() -> int:
	return CLIPMAP_RESOLUTION

func _clipmap_anchor_from_view(source: Resource, camera_world: Vector3,
		camera_forward: Vector3) -> Dictionary:
	var bounds_value: Variant = source.get("domain_bounds_world")
	if not bounds_value is AABB or not camera_world.is_finite():
		return {"valid": false, "mode": "invalid_camera_or_source_bounds"}
	var bounds: AABB = bounds_value
	if not bounds.position.is_finite() or not bounds.size.is_finite() \
			or minf(bounds.size.x, minf(bounds.size.y, bounds.size.z)) <= 0.0:
		return {"valid": false, "mode": "invalid_source_bounds"}
	if not camera_forward.is_finite() or camera_forward.length_squared() <= 1e-8:
		return {"valid": true, "anchor_world": bounds.get_center(),
			"mode": "source_bounds_center_invalid_view_direction"}
	var direction := camera_forward.normalized()
	var ray_enter := -INF
	var ray_exit := INF
	for axis in 3:
		var ray_origin := camera_world[axis]
		var ray_direction := direction[axis]
		var box_min := bounds.position[axis]
		var box_max := box_min + bounds.size[axis]
		if absf(ray_direction) <= 1e-7:
			if ray_origin < box_min or ray_origin > box_max:
				return {"valid": true, "anchor_world": bounds.get_center(),
					"mode": "source_bounds_center_view_misses_domain"}
			continue
		var t0 := (box_min - ray_origin) / ray_direction
		var t1 := (box_max - ray_origin) / ray_direction
		ray_enter = maxf(ray_enter, minf(t0, t1))
		ray_exit = minf(ray_exit, maxf(t0, t1))
		if ray_exit < ray_enter:
			return {"valid": true, "anchor_world": bounds.get_center(),
				"mode": "source_bounds_center_view_misses_domain"}
	var segment_start := maxf(ray_enter, 0.0)
	if not is_finite(ray_exit) or ray_exit < segment_start:
		return {"valid": true, "anchor_world": bounds.get_center(),
			"mode": "source_bounds_center_view_misses_domain"}
	# Fit the finest resident window against the far end of the visible source
	# segment. When a camera stands outside a room volume, centering all windows
	# at the camera can leave the entire fine Z range outside the source and force
	# visible receivers onto the 0.5m/1m layers. The projected cube half-depth
	# accounts for arbitrary view directions while preserving the exact .25m
	# source lattice.
	var fine_half_depth := 0.5 * float(_clipmap_anchor_resolution()) \
			* float(source.get("spacing_m")) \
			* (absf(direction.x) + absf(direction.y) + absf(direction.z))
	var anchor_t := maxf(segment_start, ray_exit - fine_half_depth)
	var anchor := camera_world + direction * anchor_t
	if not anchor.is_finite():
		return {"valid": false, "mode": "ray_box_focus_non_finite"}
	return {"valid": true, "anchor_world": anchor,
		"mode": "view_domain_far_fitted_finest_window"}

func _clip_buffers_valid() -> bool:
	return _clip_source_indices.is_valid() and _clip_validity.is_valid() \
			and _clip_relocation.is_valid()

func _create_source_buffers(rd: RenderingDevice, transfer: PackedFloat32Array,
		sky: PackedFloat32Array, emission: PackedFloat32Array,
		validity: PackedInt32Array, relocation: PackedVector3Array,
		moments: PackedFloat32Array) -> bool:
	_transfer = rd.storage_buffer_create(transfer.size() * 4, transfer.to_byte_array())
	_sky = rd.storage_buffer_create(sky.size() * 4, sky.to_byte_array())
	_emission = rd.storage_buffer_create(maxi(emission.size() * 4, 4),
		emission.to_byte_array() if not emission.is_empty() else PackedByteArray([0, 0, 0, 0]))
	_validity = rd.storage_buffer_create(validity.size() * 4, validity.to_byte_array())
	_moments = rd.storage_buffer_create(moments.size() * 4, moments.to_byte_array())
	var relocation_vec4 := PackedFloat32Array()
	relocation_vec4.resize(relocation.size() * 4)
	for index in relocation.size():
		var offset := relocation[index]
		var base := index * 4
		relocation_vec4[base] = offset.x
		relocation_vec4[base + 1] = offset.y
		relocation_vec4[base + 2] = offset.z
		relocation_vec4[base + 3] = 0.0
	_relocation = rd.storage_buffer_create(relocation_vec4.size() * 4,
			relocation_vec4.to_byte_array())
	var live_zeroes := PackedFloat32Array()
	live_zeroes.resize(emitter_count * 6)
	live_zeroes.fill(0.0)
	_live_sources = rd.storage_buffer_create(maxi(emitter_count * 6 * 4, 4),
		live_zeroes.to_byte_array() if emitter_count > 0 else PackedByteArray([0, 0, 0, 0]))
	if not _transfer.is_valid() or not _sky.is_valid() \
			or not _emission.is_valid() or not _validity.is_valid() \
			or not _moments.is_valid() or not _relocation.is_valid() \
			or not _live_sources.is_valid():
		_error = "dynamic_volume_source_buffer_create_failed"
		return false
	return true

func _create_output_resources(rd: RenderingDevice) -> bool:
	texture_fields.clear()
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = FIELD_FORMAT
	format.width = dimensions.x * response_tile_size
	format.height = dimensions.y * response_tile_size
	format.depth = dimensions.z
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var image := rd.texture_create(format, RDTextureView.new(), [])
	if not image.is_valid():
		_error = "dynamic_volume_response_atlas_create_failed"
		return false
	texture_fields.append(image)
	var moment_format := RDTextureFormat.new()
	moment_format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	moment_format.format = MOMENT_FORMAT
	moment_format.width = dimensions.x * MOMENT_TILE_SIZE
	moment_format.height = dimensions.y * MOMENT_TILE_SIZE
	moment_format.depth = dimensions.z
	moment_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	moment_texture = rd.texture_create(moment_format, RDTextureView.new(), [])
	if not moment_texture.is_valid():
		_error = "dynamic_volume_moment_atlas_create_failed"
		return false
	var raw_zeroes := PackedFloat32Array()
	raw_zeroes.resize(clip_cell_count * RAW_SH_FLOATS_PER_CELL)
	raw_zeroes.fill(0.0)
	_raw_sh = rd.storage_buffer_create(raw_zeroes.size() * 4, raw_zeroes.to_byte_array())
	var source_indices := PackedInt32Array()
	source_indices.resize(clip_cell_count)
	source_indices.fill(-1)
	_clip_source_indices = rd.storage_buffer_create(source_indices.size() * 4,
			source_indices.to_byte_array())
	var clip_validity := PackedInt32Array()
	clip_validity.resize(clip_cell_count)
	clip_validity.fill(0)
	_clip_validity = rd.storage_buffer_create(clip_validity.size() * 4,
			clip_validity.to_byte_array())
	var clip_relocation := PackedFloat32Array()
	clip_relocation.resize(clip_cell_count * 4)
	clip_relocation.fill(0.0)
	_clip_relocation = rd.storage_buffer_create(clip_relocation.size() * 4,
			clip_relocation.to_byte_array())
	if not _raw_sh.is_valid() or not _clip_buffers_valid():
		_error = "dynamic_volume_raw_sh_buffer_create_failed"
		return false
	return true
