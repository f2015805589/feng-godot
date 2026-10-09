class_name FFogRayTracingShadowProvider
extends RefCounted
## Render-thread hardware ray-tracing provider for volumetric shadow batches.
##
## Main-thread scene discovery is handled by FFogRayTracingGeometryRegistry. This
## object consumes its immutable PackedArray snapshot and owns RD buffers, BLAS,
## TLAS, ray pipeline, SBT, and the per-ray visibility output buffer.

const SHADER_DIR := "res://addons/feng-fog/rendering/raytracing"
const GeometryRegistryScript = preload("res://addons/feng-fog/rendering/raytracing/fog_rt_geometry_registry.gd")
const RAY_INPUT_STRIDE_BYTES := 48 # origin_min_t, direction_max_t, cone_words; three 16-byte std430 records
const RAY_INPUT_ABI_VERSION := 2
const VISIBILITY_STRIDE_BYTES := 4 # uint32, 1 visible / 0 blocked
const MAX_RAY_COUNT := 1 << 24

var _rd: RenderingDevice
var _ray_shader := RID()
var _pipeline := RID()
var _hit_sbt := RID()
var _hit_sbt_range := 0
var _blas_cache: Dictionary = {} # mesh id -> RD resources and revision
var _tlas := RID()
var _tlas_capacity := 0
var _output_buffer := RID()
var _output_capacity_bytes := 0
var _active_pipeline_abi := 0
var _alpha_triangle_buffer := RID()
var _alpha_surface_buffer := RID()
var _alpha_instance_buffer := RID()
var _alpha_material_ids_buffer := RID()
var _alpha_material_params_buffer := RID()
var _alpha_texture_meta_buffer := RID()
var _alpha_texture_bytes_buffer := RID()
var _alpha_payload_revision := -1
var _active_world_generation := -1
var _active_snapshot_revision := -1
var _last_error := ""
var _reported_unsupported := false


func get_capability_report(p_rd: RenderingDevice = null) -> Dictionary:
	var device := p_rd
	if device == null:
		device = RenderingServer.get_rendering_device()
	if device == null:
		return {
			"supported": false,
			"reason": "No main RenderingDevice is available.",
			"requires": ["raytracing_pipeline", "buffer_device_address"],
		}
	var pipeline_supported := device.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)
	var address_supported := device.has_feature(RenderingDevice.SUPPORTS_BUFFER_DEVICE_ADDRESS)
	return {
		"supported": pipeline_supported and address_supported,
		"raytracing_pipeline": pipeline_supported,
		"buffer_device_address": address_supported,
		"reason": "" if pipeline_supported and address_supported else
				"The active RenderingDevice lacks the RD ray-tracing pipeline or device-address feature.",
		"requires": ["raytracing_pipeline", "buffer_device_address"],
		"output_semantics": "uint32 1=unoccluded, 0=blocked; inactive ABI v2 rays write 1 without tracing",
		"ray_input_contract": get_ray_input_contract(),
	}


func get_ray_input_contract() -> Dictionary:
	return {
		"abi_version": RAY_INPUT_ABI_VERSION,
		"buffer_type": "RD storage buffer",
		"ownership": "borrowed_caller",
		"device": "RenderingServer main RenderingDevice",
		"zero_copy": true,
		"stride_bytes": RAY_INPUT_STRIDE_BYTES,
		"minimum_buffer_bytes": "ray_count * stride_bytes",
		"record_fields": [
			{"name": "origin_min_t", "offset_bytes": 0, "format": "std430 vec4", "meaning": "world-space origin in meters; minimum ray t in meters"},
			{"name": "direction_max_t", "offset_bytes": 16, "format": "std430 vec4", "meaning": "normalized world-space direction; maximum ray t in meters"},
			{"name": "cone_words", "offset_bytes": 32, "format": "std430 uvec4 raw words", "meaning": "ABI v1: x/y are IEEE-754 radius/growth bits and z/w are ignored; ABI v2: x/y unchanged, z is the raw uint32 light mask, w is IEEE-754 bits for active 1.0 or skip 0.0"},
		],
		"accepted_input_abi_versions": [1, RAY_INPUT_ABI_VERSION],
		"descriptor_bindings": {
			"set": 0,
			"raygen_input": 1,
			"any_hit_input": 10,
			"same_borrowed_input_rid": true,
		},
		"shader_variant": {
			"transport": "compile_time_pipeline_define",
			"define": "FENG_FOG_RAY_ABI",
			"accepted_values": [1, RAY_INPUT_ABI_VERSION],
		},
		"coordinate_space": "world_space",
		"distance_unit": "meter",
		"dispatch_order": "light_major_froxel_minor",
		"generation": "caller frame_generation echoed in result; caller must only bind matching generation",
		"ownership_transfer": false,
	}


static func shader_source_for_abi(p_source: String, p_abi: int) -> String:
	if p_source.is_empty() or p_abi not in [1, RAY_INPUT_ABI_VERSION]:
		return ""
	var lines := p_source.split("\n")
	if lines.is_empty() or not lines[0].strip_edges().begins_with("#version "):
		return ""
	var define_index := 1
	while define_index < lines.size() and lines[define_index].strip_edges().begins_with("#extension "):
		define_index += 1
	lines.insert(define_index, "#define FENG_FOG_RAY_ABI %d" % p_abi)
	return "\n".join(lines)


static func _object_id_is_valid(p_object_id: int) -> bool:
	# RefCounted Resource instance IDs can be negative because their high bits
	# carry an Object-type tag. Only zero is the invalid/sentinel ID.
	return p_object_id != 0


static func pack_instance_metadata(p_material_offset: int, p_geometry_offset: int,
		p_surface_count: int, p_layer_mask: int) -> PackedInt32Array:
	return PackedInt32Array([
			p_material_offset,
			p_geometry_offset,
			p_surface_count,
			p_layer_mask,
	])


static func storage_buffer_initial_data(p_bytes: PackedByteArray,
		p_minimum_bytes: int = 16) -> PackedByteArray:
	if p_minimum_bytes < 0:
		return PackedByteArray()
	var initial_data := p_bytes.duplicate()
	initial_data.resize(maxi(p_minimum_bytes, initial_data.size()))
	return initial_data


func trace_shadow_batch(p_rd: RenderingDevice, p_geometry_snapshot: Dictionary,
		p_ray_input_buffer: RID, p_ray_input_buffer_bytes: int,
		p_ray_input_stride_bytes: int, p_ray_input_generation: int,
		p_ray_count: int, p_light_count: int, p_froxel_count: int,
		p_frame_generation: int, p_ray_input_abi_version: int = 1) -> Dictionary:
	_last_error = ""
	if p_rd == null:
		return _invalid_result("No RenderingDevice was supplied.", p_frame_generation)
	var main_rd := RenderingServer.get_rendering_device()
	if main_rd == null or p_rd != main_rd:
		return _invalid_result("Ray input must use the RenderingServer main RenderingDevice.", p_frame_generation)
	var capabilities := get_capability_report(p_rd)
	if not bool(capabilities.get("supported", false)):
		_last_error = str(capabilities.get("reason", "Hardware ray tracing is unavailable."))
		if not _reported_unsupported:
			push_warning("Feng Fog: " + _last_error + " The raster shadow provider remains active.")
			_reported_unsupported = true
		return _invalid_result(_last_error, p_frame_generation)
	if p_ray_count <= 0 or p_ray_count > MAX_RAY_COUNT \
			or p_light_count <= 0 or p_froxel_count <= 0 \
			or p_light_count > MAX_RAY_COUNT / p_froxel_count:
		return _invalid_result("Ray batch dimensions are outside the supported limits.", p_frame_generation)
	if p_ray_input_abi_version not in [1, RAY_INPUT_ABI_VERSION]:
		return _invalid_result("Ray input ABI version is unsupported.", p_frame_generation)
	var expected_ray_count := p_light_count * p_froxel_count
	var required_input_bytes := p_ray_count * RAY_INPUT_STRIDE_BYTES
	if not p_ray_input_buffer.is_valid() \
			or p_ray_input_stride_bytes != RAY_INPUT_STRIDE_BYTES \
			or p_ray_input_buffer_bytes < required_input_bytes \
			or p_ray_input_generation != p_frame_generation \
			or p_ray_count != expected_ray_count:
		return _invalid_result("Ray batch dimensions, byte capacity, generation, or borrowed 48-byte input buffer are invalid.", p_frame_generation)
	if p_geometry_snapshot.get("abi_version", 0) != GeometryRegistryScript.SNAPSHOT_VERSION:
		return _invalid_result("Geometry snapshot ABI is unsupported.", p_frame_generation)
	var unsupported: Array = p_geometry_snapshot.get("unsupported_shadow_geometry", [])
	if not unsupported.is_empty():
		return _invalid_result("The active scene contains shadow casters that the RT geometry provider cannot represent; use the complete raster shadow batch.", p_frame_generation)
	if not _ensure_pipeline(p_rd, p_ray_input_abi_version):
		return _invalid_result(_last_error, p_frame_generation)
	if not _sync_scene(p_rd, p_geometry_snapshot):
		return _invalid_result(_last_error, p_frame_generation)
	if not _tlas.is_valid():
		return _invalid_result("No supported shadow-casting geometry is registered.", p_frame_generation)
	if not _ensure_alpha_buffers(p_rd, p_geometry_snapshot):
		return _invalid_result(_last_error, p_frame_generation)
	if not _ensure_output_buffer(p_rd, p_ray_count * VISIBILITY_STRIDE_BYTES):
		return _invalid_result(_last_error, p_frame_generation)
	var uniforms: Array[RDUniform] = []
	var acceleration_uniform := RDUniform.new()
	acceleration_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	acceleration_uniform.binding = 0
	acceleration_uniform.add_id(_tlas)
	uniforms.append(acceleration_uniform)
	var input_uniform := RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_uniform.binding = 1
	input_uniform.add_id(p_ray_input_buffer)
	uniforms.append(input_uniform)
	# Any-hit must use a stage-specific alias for this borrowed input buffer.
	# This adds no copy and does not change the external ray record ABI.
	var any_hit_input_uniform := RDUniform.new()
	any_hit_input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	any_hit_input_uniform.binding = 10
	any_hit_input_uniform.add_id(p_ray_input_buffer)
	uniforms.append(any_hit_input_uniform)
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output_uniform.binding = 2
	output_uniform.add_id(_output_buffer)
	uniforms.append(output_uniform)
	var alpha_bindings := [
		[3, _alpha_triangle_buffer],
		[4, _alpha_surface_buffer],
		[5, _alpha_instance_buffer],
		[6, _alpha_material_ids_buffer],
		[7, _alpha_material_params_buffer],
		[8, _alpha_texture_meta_buffer],
		[9, _alpha_texture_bytes_buffer],
	]
	for binding in alpha_bindings:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = int(binding[0])
		uniform.add_id(binding[1])
		uniforms.append(uniform)
	var uniform_set := p_rd.uniform_set_create(uniforms, _ray_shader, 0)
	if not uniform_set.is_valid():
		return _invalid_result("Could not bind TLAS and shadow ray buffers.", p_frame_generation)
	var list := p_rd.raytracing_list_begin()
	if list == RenderingDevice.INVALID_ID:
		p_rd.free_rid(uniform_set)
		return _invalid_result("Could not begin an RD ray-tracing list.", p_frame_generation)
	p_rd.raytracing_list_bind_raytracing_pipeline(list, _pipeline)
	p_rd.raytracing_list_bind_uniform_set(list, uniform_set, 0)
	p_rd.raytracing_list_trace_rays(list, 0, _hit_sbt, p_ray_count, 1, 1)
	p_rd.raytracing_list_end()
	p_rd.free_rid(uniform_set)
	return {
		"valid": true,
		"provider": "rd_raytracing_pipeline",
		"visibility_buffer": _output_buffer,
		"visibility_stride_bytes": VISIBILITY_STRIDE_BYTES,
		"ray_input_stride_bytes": RAY_INPUT_STRIDE_BYTES,
		"ray_input_bytes_required": p_ray_count * RAY_INPUT_STRIDE_BYTES,
		"ray_input_buffer_bytes": p_ray_input_buffer_bytes,
		"ray_count": p_ray_count,
		"light_count": p_light_count,
		"froxel_count": p_froxel_count,
		"ray_order": "light_major_froxel_minor",
		"visibility_semantics": "1=unoccluded,0=blocked",
		"fallback_required": false,
		"fallback_provider": "",
		"ray_input_ownership": "borrowed_caller",
		"ray_input_device": "same_rendering_device_as_p_rd",
		"ray_input_zero_copy": true,
		"ray_input_generation": p_ray_input_generation,
		"ray_input_abi_version": p_ray_input_abi_version,
		"output_ownership": "provider",
		"visibility_lifetime": "provider reuses this buffer on the next trace call; consume or accumulate the current result before tracing the next batch",
		"visibility_buffer_gpu_ordering_required": true,
		"ray_record_layout": "origin_min_t:vec4,direction_max_t:vec4,cone_words:uvec4",
		"geometry_snapshot_revision": _active_snapshot_revision,
		"world_generation": _active_world_generation,
		"snapshot_revision": _active_snapshot_revision,
		"frame_generation": p_frame_generation,
	}


func release() -> void:
	var rd := _rd
	var owned := take_owned_rids()
	if rd != null:
		for rid in owned:
			_free_rid(rd, rid)
	_last_error = ""


func get_owned_rids() -> Array[RID]:
	return _collect_owned_rids(false)


func take_owned_rids() -> Array[RID]:
	return _collect_owned_rids(true)


func _collect_owned_rids(p_clear: bool) -> Array[RID]:
	var result: Array[RID] = []
	var seen: Dictionary = {}
	# Keep teardown in dependency order: TLAS before its BLAS, then the SBT,
	# pipeline and ray shader, followed by each BLAS before its backing buffers.
	for rid in [_tlas, _hit_sbt, _pipeline, _ray_shader]:
		if rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			result.append(rid)
	for cache_value in _blas_cache.values():
		if cache_value is Dictionary:
			for rid in _blas_owned_rids(cache_value):
				if rid.is_valid() and not seen.has(rid):
					seen[rid] = true
					result.append(rid)
	for rid in [_output_buffer, _alpha_triangle_buffer, _alpha_surface_buffer,
			_alpha_instance_buffer, _alpha_material_ids_buffer,
			_alpha_material_params_buffer, _alpha_texture_meta_buffer,
			_alpha_texture_bytes_buffer]:
		if rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			result.append(rid)
	if p_clear:
		_rd = null
		_blas_cache.clear()
		_tlas = RID()
		_tlas_capacity = 0
		_output_buffer = RID()
		_hit_sbt = RID()
		_hit_sbt_range = 0
		_pipeline = RID()
		_ray_shader = RID()
		_active_pipeline_abi = 0
		_output_capacity_bytes = 0
		_alpha_triangle_buffer = RID()
		_alpha_surface_buffer = RID()
		_alpha_instance_buffer = RID()
		_alpha_material_ids_buffer = RID()
		_alpha_material_params_buffer = RID()
		_alpha_texture_meta_buffer = RID()
		_alpha_texture_bytes_buffer = RID()
		_alpha_payload_revision = -1
		_active_world_generation = -1
		_active_snapshot_revision = -1
		_last_error = ""
		_reported_unsupported = false
	return result


static func _blas_owned_rids(p_cache: Dictionary) -> Array[RID]:
	var result: Array[RID] = []
	var blas: RID = p_cache.get("blas", RID())
	if blas.is_valid():
		result.append(blas)
	for value in p_cache.get("buffers", []):
		if value is RID and value.is_valid() and not result.has(value):
			result.append(value)
	return result


func get_last_error() -> String:
	return _last_error


func _ensure_pipeline(p_rd: RenderingDevice, p_abi: int) -> bool:
	if p_abi not in [1, RAY_INPUT_ABI_VERSION]:
		_last_error = "Ray-tracing shader ABI variant is unsupported."
		return false
	if _pipeline.is_valid() and _ray_shader.is_valid() and _hit_sbt.is_valid() \
			and _rd == p_rd and _active_pipeline_abi == p_abi:
		return true
	if _rd != null and _rd != p_rd:
		release()
	_rd = p_rd
	# TLAS instances refer to the active hit SBT range. Drop TLAS before replacing
	# the SBT/pipeline, then let _sync_scene rebuild it for the selected ABI.
	_release_pipeline_variant(p_rd)
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	# These are raw RT-stage sources, not Godot Shader resources. Keep the
	# .glslinc extension so ResourceImporterShaderFile does not parse them as
	# ordinary vertex/fragment/compute GLSL when a project is opened in Editor.
	var raygen_source := FileAccess.get_file_as_string(SHADER_DIR.path_join("fog_shadow_raygen.glslinc"))
	source.source_miss = FileAccess.get_file_as_string(SHADER_DIR.path_join("fog_shadow_miss.glslinc"))
	source.source_closest_hit = FileAccess.get_file_as_string(SHADER_DIR.path_join("fog_shadow_closest_hit.glslinc"))
	var any_hit_source := FileAccess.get_file_as_string(SHADER_DIR.path_join("fog_shadow_any_hit.glslinc"))
	source.source_raygen = shader_source_for_abi(raygen_source, p_abi)
	source.source_any_hit = shader_source_for_abi(any_hit_source, p_abi)
	if source.source_raygen.is_empty() or source.source_miss.is_empty() \
			or source.source_closest_hit.is_empty() or source.source_any_hit.is_empty():
		_last_error = "Ray-tracing shader source files are missing or empty."
		return false
	var spirv: RDShaderSPIRV = p_rd.shader_compile_spirv_from_source(source)
	if spirv == null:
		_last_error = "The RD compiler returned no ray-tracing SPIR-V."
		return false
	for stage in [RenderingDevice.SHADER_STAGE_RAYGEN, RenderingDevice.SHADER_STAGE_MISS,
			RenderingDevice.SHADER_STAGE_CLOSEST_HIT, RenderingDevice.SHADER_STAGE_ANY_HIT]:
		var compile_error := spirv.get_stage_compile_error(stage)
		if not compile_error.is_empty():
			_last_error = "Ray-tracing shader compile failed: " + compile_error
			return false
	_ray_shader = p_rd.shader_create_from_spirv(spirv, "FengFogRayShadow")
	if not _ray_shader.is_valid():
		_last_error = "Could not create the ray-tracing shader RID."
		return false
	var raygen := RDPipelineShader.new()
	raygen.shader = _ray_shader
	var miss := RDPipelineShader.new()
	miss.shader = _ray_shader
	var closest_hit := RDPipelineShader.new()
	closest_hit.shader = _ray_shader
	var any_hit := RDPipelineShader.new()
	any_hit.shader = _ray_shader
	var hit_group := RDHitGroup.new()
	hit_group.closest_hit_shader = closest_hit
	hit_group.any_hit_shader = any_hit
	var raygen_shaders: Array[RDPipelineShader] = [raygen]
	var miss_shaders: Array[RDPipelineShader] = [miss]
	var hit_groups: Array[RDHitGroup] = [hit_group]
	_pipeline = p_rd.raytracing_pipeline_create(raygen_shaders, miss_shaders, hit_groups, 1)
	if not _pipeline.is_valid() or not p_rd.raytracing_pipeline_is_valid(_pipeline):
		_last_error = "Could not create an RD ray-tracing pipeline."
		return false
	_hit_sbt = p_rd.hit_sbt_create(_pipeline, 1)
	if not _hit_sbt.is_valid():
		_last_error = "Could not create a hit-shader binding table."
		return false
	_hit_sbt_range = p_rd.hit_sbt_range_alloc(_hit_sbt, 1)
	if _hit_sbt_range == 0 or p_rd.hit_sbt_range_update(_hit_sbt,
			_hit_sbt_range, 0, PackedInt32Array([0])) != OK:
		_last_error = "Could not allocate the triangle hit-group SBT range."
		return false
	_active_pipeline_abi = p_abi
	return true


func _release_pipeline_variant(p_rd: RenderingDevice) -> void:
	_release_tlas(p_rd)
	_free_rid(p_rd, _hit_sbt)
	_free_rid(p_rd, _pipeline)
	_free_rid(p_rd, _ray_shader)
	_hit_sbt = RID()
	_hit_sbt_range = 0
	_pipeline = RID()
	_ray_shader = RID()
	_active_pipeline_abi = 0


func _sync_scene(p_rd: RenderingDevice, p_snapshot: Dictionary) -> bool:
	var world_generation := int(p_snapshot.get("world_generation", -1))
	if world_generation < 0:
		_last_error = "Geometry snapshot has no world generation."
		return false
	if world_generation != _active_world_generation:
		_release_tlas(p_rd)
		for mesh_id in _blas_cache:
			_release_blas(p_rd, _blas_cache[mesh_id])
		_blas_cache.clear()
		_active_world_generation = world_generation
		_active_snapshot_revision = -1
	var snapshot_revision := int(p_snapshot.get("snapshot_revision", -1))
	if snapshot_revision == _active_snapshot_revision and _tlas.is_valid():
		return true
	var present_meshes: Dictionary = {}
	var replace_meshes: Dictionary = {}
	for geometry in p_snapshot.get("geometries", []):
		var mesh_id := int(geometry.get("mesh_id", 0))
		var mesh_revision := int(geometry.get("mesh_revision", 0))
		if not _object_id_is_valid(mesh_id) or mesh_revision <= 0:
			continue
		present_meshes[mesh_id] = true
		var cached: Dictionary = _blas_cache.get(mesh_id, {})
		if int(cached.get("mesh_revision", -1)) != mesh_revision:
			replace_meshes[mesh_id] = geometry
	var remove_meshes: Array = []
	for mesh_id in _blas_cache:
		if not present_meshes.has(mesh_id):
			remove_meshes.append(mesh_id)
	if not replace_meshes.is_empty() or not remove_meshes.is_empty():
		_release_tlas(p_rd)
	for geometry in p_snapshot.get("geometries", []):
		var mesh_id := int(geometry.get("mesh_id", 0))
		var mesh_revision := int(geometry.get("mesh_revision", 0))
		if not _object_id_is_valid(mesh_id) or mesh_revision <= 0:
			continue
		var cached: Dictionary = _blas_cache.get(mesh_id, {})
		if int(cached.get("mesh_revision", -1)) != mesh_revision:
			var next_cache := _build_blas(p_rd, geometry)
			if next_cache.is_empty():
				_last_error = "Could not build a complete BLAS for mesh %d." % mesh_id
				return false
			if not cached.is_empty():
				_release_blas(p_rd, cached)
			_blas_cache[mesh_id] = next_cache
	for mesh_id in remove_meshes:
		_release_blas(p_rd, _blas_cache[mesh_id])
		_blas_cache.erase(mesh_id)
	var instances: Array[RDAccelerationStructureInstance] = []
	var custom_index := 0
	for instance in p_snapshot.get("instances", []):
		if not bool(instance.get("visible", false)) or not bool(instance.get("cast_shadow", false)):
			continue
		var mesh_id := int(instance.get("mesh_id", 0))
		var cached: Dictionary = _blas_cache.get(mesh_id, {})
		var blas: RID = cached.get("blas", RID())
		var transform: Transform3D = instance.get("transform", Transform3D.IDENTITY)
		if not blas.is_valid() or not transform.is_finite() \
				or absf(transform.basis.determinant()) <= 0.00000001:
			_last_error = "An active shadow caster is missing valid RT geometry; raster fallback is required."
			return false
		if custom_index >= 0x1000000:
			_last_error = "Active RT caster count exceeds the acceleration-structure custom-index range."
			return false
		var rd_instance := RDAccelerationStructureInstance.new()
		rd_instance.transform = transform
		rd_instance.id = custom_index
		custom_index += 1
		rd_instance.mask = 0xff
		rd_instance.hit_sbt_range = _hit_sbt_range
		rd_instance.blas = blas
		instances.append(rd_instance)
	if instances.is_empty():
		_release_tlas(p_rd)
		_active_snapshot_revision = snapshot_revision
		return true
	if not _tlas.is_valid() or instances.size() > _tlas_capacity:
		_release_tlas(p_rd)
		_tlas_capacity = _next_power_of_two(instances.size())
		_tlas = p_rd.tlas_create(_tlas_capacity,
				RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT
				| RenderingDevice.ACCELERATION_STRUCTURE_ALLOW_UPDATE_BIT)
		if not _tlas.is_valid():
			_last_error = "Could not create the top-level acceleration structure."
			return false
	if p_rd.tlas_build(_tlas, instances) != OK:
		_last_error = "Could not build the top-level acceleration structure."
		return false
	_active_snapshot_revision = snapshot_revision
	return true


func _build_blas(p_rd: RenderingDevice, p_geometry: Dictionary) -> Dictionary:
	var geometries: Array[RDAccelerationStructureGeometry] = []
	var owned_buffers: Array[RID] = []
	for surface in p_geometry.get("surfaces", []):
		var vertices: PackedVector3Array = surface.get("vertices", PackedVector3Array())
		var indices: PackedInt32Array = surface.get("indices", PackedInt32Array())
		if vertices.is_empty() or indices.is_empty() or indices.size() % 3 != 0:
			continue
		var packed_vertices := PackedFloat32Array()
		packed_vertices.resize(vertices.size() * 3)
		for vertex_index in vertices.size():
			var base := vertex_index * 3
			packed_vertices[base] = vertices[vertex_index].x
			packed_vertices[base + 1] = vertices[vertex_index].y
			packed_vertices[base + 2] = vertices[vertex_index].z
		var build_input_flags := RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT \
				| RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT
		var vertex_bytes := packed_vertices.to_byte_array()
		var index_bytes := indices.to_byte_array()
		var vertex_buffer := p_rd.vertex_buffer_create(vertex_bytes.size(), vertex_bytes, build_input_flags)
		var index_buffer := p_rd.index_buffer_create(indices.size(),
				RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, index_bytes, false, build_input_flags)
		if not vertex_buffer.is_valid() or not index_buffer.is_valid():
			_free_rid(p_rd, vertex_buffer)
			_free_rid(p_rd, index_buffer)
			for rid in owned_buffers:
				_free_rid(p_rd, rid)
			return {}
		owned_buffers.append(vertex_buffer)
		owned_buffers.append(index_buffer)
		var rd_geometry := RDAccelerationStructureGeometry.new()
		# Leave OPAQUE unset so any-hit can apply the full 32-bit light/instance
		# mask even when this triangle's material is otherwise fully opaque.
		rd_geometry.flags = 0
		rd_geometry.vertex_buffer = vertex_buffer
		rd_geometry.vertex_offset = 0
		rd_geometry.vertex_stride = 12
		rd_geometry.vertex_count = vertices.size()
		rd_geometry.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
		rd_geometry.index_buffer = index_buffer
		rd_geometry.index_offset = 0
		rd_geometry.index_count = indices.size()
		geometries.append(rd_geometry)
	if geometries.is_empty():
		return {}
	var blas := p_rd.blas_create(geometries,
			RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT)
	if not blas.is_valid() or p_rd.blas_build(blas) != OK:
		_free_rid(p_rd, blas)
		for rid in owned_buffers:
			_free_rid(p_rd, rid)
		return {}
	return {
		"blas": blas,
		"buffers": owned_buffers,
		"mesh_revision": int(p_geometry.get("mesh_revision", -1)),
	}


func _ensure_alpha_buffers(p_rd: RenderingDevice, p_snapshot: Dictionary) -> bool:
	var revision := int(p_snapshot.get("alpha_payload_revision",
			p_snapshot.get("snapshot_revision", -1)))
	if revision == _alpha_payload_revision and _alpha_triangle_buffer.is_valid():
		return true
	var geometry_by_id: Dictionary = {}
	for geometry in p_snapshot.get("geometries", []):
		geometry_by_id[int(geometry.get("mesh_id", 0))] = geometry
	var texture_index_by_id: Dictionary = {}
	var texture_meta := PackedInt32Array()
	var alpha_words := PackedInt32Array()
	var textures: Array = p_snapshot.get("alpha_textures", [])
	textures.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("texture_id", 0)) < int(b.get("texture_id", 0)))
	for texture in textures:
		var texture_id := int(texture.get("texture_id", 0))
		var width := int(texture.get("width", 0))
		var height := int(texture.get("height", 0))
		var alpha: PackedByteArray = texture.get("alpha", PackedByteArray())
		if not bool(texture.get("valid", false)) or not _object_id_is_valid(texture_id) or width <= 0 or height <= 0 \
				or alpha.size() != width * height:
			_last_error = "An alpha-masked caster has an invalid CPU alpha-texture snapshot."
			return false
		var word_offset := alpha_words.size()
		for first_texel in range(0, alpha.size(), 4):
			var packed := 0
			for lane in 4:
				var texel := first_texel + lane
				if texel < alpha.size():
					packed |= int(alpha[texel]) << (lane * 8)
			alpha_words.append(packed)
		var texture_index := texture_meta.size() / 4
		texture_index_by_id[texture_id] = texture_index
		texture_meta.append_array(PackedInt32Array([width, height, word_offset, alpha.size()]))
	var triangle_data := PackedFloat32Array()
	var surface_data := PackedInt32Array()
	var geometry_metadata_offsets: Dictionary = {}
	var geometry_ids: Array = geometry_by_id.keys()
	geometry_ids.sort()
	for mesh_id in geometry_ids:
		var geometry: Dictionary = geometry_by_id[mesh_id]
		geometry_metadata_offsets[mesh_id] = surface_data.size() / 4
		for surface in geometry.get("surfaces", []):
			var indices: PackedInt32Array = surface.get("indices", PackedInt32Array())
			var uvs: PackedVector2Array = surface.get("uvs", PackedVector2Array())
			var colors: PackedColorArray = surface.get("colors", PackedColorArray())
			var triangle_offset := triangle_data.size() / 4
			var primitive_count := indices.size() / 3
			surface_data.append_array(PackedInt32Array([
				triangle_offset, primitive_count, int(surface.get("surface_index", 0)), 0,
			]))
			for vertex_index in indices:
				var uv := uvs[vertex_index] if vertex_index < uvs.size() else Vector2.ZERO
				var vertex_alpha := colors[vertex_index].a if vertex_index < colors.size() else 1.0
				triangle_data.append_array(PackedFloat32Array([uv.x, uv.y, vertex_alpha, 0.0]))
	var instance_data := PackedInt32Array()
	var material_ids := PackedInt32Array()
	var material_params := PackedFloat32Array()
	for instance in p_snapshot.get("instances", []):
		var mesh_id := int(instance.get("mesh_id", 0))
		var geometry: Dictionary = geometry_by_id.get(mesh_id, {})
		if geometry.is_empty() or not geometry_metadata_offsets.has(mesh_id):
			_last_error = "An active caster has no matching immutable mesh geometry snapshot."
			return false
		var surfaces: Array = geometry.get("surfaces", [])
		var materials: Array = instance.get("surface_materials", [])
		if materials.size() != surfaces.size():
			_last_error = "Per-instance material records do not match the BLAS geometry surface count."
			return false
		var material_offset := material_ids.size() / 4
		for surface_index in surfaces.size():
			var material: Dictionary = materials[surface_index]
			if not bool(material.get("supported", false)):
				_last_error = "An unsupported per-instance material reached the RT provider; use raster shadows."
				return false
			var mode := 0
			match str(material.get("mode", "opaque")):
				"scissor": mode = 1
				"hash": mode = 2
			var texture_index := -1
			var texture_id := int(material.get("alpha_texture_id", 0))
			if texture_id != 0:
				if not texture_index_by_id.has(texture_id):
					_last_error = "A masked material refers to an alpha texture absent from the frame snapshot."
					return false
				texture_index = int(texture_index_by_id[texture_id])
			var uv_scale: Vector2 = material.get("uv_scale", Vector2.ONE)
			var uv_offset: Vector2 = material.get("uv_offset", Vector2.ZERO)
			var flags := 1 if bool(material.get("uses_vertex_color_alpha", false)) else 0
			material_ids.append_array(PackedInt32Array([
				mode, texture_index + 1, flags, 1 if bool(material.get("alpha_texture_repeat", true)) else 0,
			]))
			material_params.append_array(PackedFloat32Array([
				float(material.get("base_alpha", 1.0)),
				float(material.get("threshold", 0.5)),
				float(material.get("hash_scale", 1.0)),
				float(material.get("texture_filter", 1)),
				uv_scale.x, uv_scale.y, uv_offset.x, uv_offset.y,
			]))
		instance_data.append_array(pack_instance_metadata(
				material_offset, int(geometry_metadata_offsets[mesh_id]),
				surfaces.size(), int(instance.get("layer_mask", 0))))
	if triangle_data.is_empty():
		triangle_data.append_array(PackedFloat32Array([0.0, 0.0, 1.0, 0.0]))
	if surface_data.is_empty():
		surface_data.append_array(PackedInt32Array([0, 0, 0, 0]))
	if instance_data.is_empty():
		instance_data.append_array(PackedInt32Array([0, 0, 0, 0]))
	if material_ids.is_empty():
		material_ids.append_array(PackedInt32Array([0, 0, 0, 0]))
	if material_params.is_empty():
		material_params.append_array(PackedFloat32Array([1, 0.5, 1, 1, 1, 1, 0, 0]))
	if texture_meta.is_empty():
		texture_meta.append_array(PackedInt32Array([1, 1, 0, 1]))
	if alpha_words.is_empty():
		alpha_words.append(-1)
	var new_buffers: Array[RID] = []
	for bytes in [triangle_data.to_byte_array(), surface_data.to_byte_array(), instance_data.to_byte_array(),
			material_ids.to_byte_array(), material_params.to_byte_array(), texture_meta.to_byte_array(),
			alpha_words.to_byte_array()]:
		var initial_data := storage_buffer_initial_data(bytes)
		if initial_data.is_empty():
			for created in new_buffers:
				_free_rid(p_rd, created)
			_last_error = "Could not prepare exact-size RT alpha/material metadata buffer data."
			return false
		var buffer := p_rd.storage_buffer_create(initial_data.size(), initial_data)
		if not buffer.is_valid():
			for created in new_buffers:
				_free_rid(p_rd, created)
			_last_error = "Could not allocate immutable RT alpha/material metadata buffers."
			return false
		new_buffers.append(buffer)
	for old_buffer in [_alpha_triangle_buffer, _alpha_surface_buffer, _alpha_instance_buffer,
			_alpha_material_ids_buffer, _alpha_material_params_buffer, _alpha_texture_meta_buffer,
			_alpha_texture_bytes_buffer]:
		_free_rid(p_rd, old_buffer)
	_alpha_triangle_buffer = new_buffers[0]
	_alpha_surface_buffer = new_buffers[1]
	_alpha_instance_buffer = new_buffers[2]
	_alpha_material_ids_buffer = new_buffers[3]
	_alpha_material_params_buffer = new_buffers[4]
	_alpha_texture_meta_buffer = new_buffers[5]
	_alpha_texture_bytes_buffer = new_buffers[6]
	_alpha_payload_revision = revision
	return true


func _next_power_of_two(p_value: int) -> int:
	var result := 1
	while result < p_value:
		result <<= 1
	return result


func _ensure_output_buffer(p_rd: RenderingDevice, p_required_bytes: int) -> bool:
	if p_required_bytes <= _output_capacity_bytes and _output_buffer.is_valid():
		return true
	_free_rid(p_rd, _output_buffer)
	_output_buffer = p_rd.storage_buffer_create(p_required_bytes)
	if not _output_buffer.is_valid():
		_output_capacity_bytes = 0
		_last_error = "Could not allocate the RD shadow visibility output buffer."
		return false
	_output_capacity_bytes = p_required_bytes
	return true


func _release_tlas(p_rd: RenderingDevice) -> void:
	_free_rid(p_rd, _tlas)
	_tlas = RID()
	_tlas_capacity = 0
	_active_snapshot_revision = -1


func _release_blas(p_rd: RenderingDevice, p_cache: Dictionary) -> void:
	for rid in _blas_owned_rids(p_cache):
		_free_rid(p_rd, rid)


func _free_rid(p_rd: RenderingDevice, p_rid: RID) -> void:
	if p_rid.is_valid():
		p_rd.free_rid(p_rid)


func _invalid_result(p_reason: String, p_frame_generation: int) -> Dictionary:
	_last_error = p_reason
	return {
		"valid": false,
		"provider": "rd_raytracing_pipeline",
		"reason": p_reason,
		"frame_generation": p_frame_generation,
		"fallback_required": true,
		"fallback_provider": "complete_raster_shadow_batch",
		"ray_input_ownership": "borrowed_caller",
		"output_ownership": "none",
	}
