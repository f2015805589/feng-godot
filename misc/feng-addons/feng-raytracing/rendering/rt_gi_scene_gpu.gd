@tool
extends RefCounted
## Shared render-thread scene owner for Feng's one-bounce ray tracing passes.
## Owns the BLAS/TLAS and the material, geometry, texture-atlas and common sampling data.
const DIR = "res://addons/feng-raytracing/shaders/"
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const MATERIAL_ROW_BYTES := 80
const MATERIAL_WORD_STRIDE := 20
var rd: RenderingDevice
var owned: Array[RID] = []
var scene_owned: Array[RID] = []
var tlas := RID()
var vertices := RID()
var indices := RID()
var surfaces := RID()
var materials := RID()
var sampler := RID()
var black_2d := RID()
var black_array := RID()
var neutral_lights := RID()
var atlas: Array[RID] = []
var atlas_samplers: Array[RID] = []
var scene_rows: Array = []
var geometry_key: Array = []
var transform_key: Array = []
var previous_hit_sbt_range := 0
var error := ""
var sky_array := false

func keep(rid: RID, scene := false) -> RID:
	if rid.is_valid():
		if scene:
			scene_owned.append(rid)
		else:
			owned.append(rid)
	return rid

func initialize(device: RenderingDevice) -> bool:
	if rd == device and sampler.is_valid() and neutral_lights.is_valid():
		return true
	release()
	rd = device
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler = keep(rd.sampler_create(state))
	neutral_lights = keep(rd.uniform_buffer_create(464 * 8))
	black_2d = keep(_create_black(false))
	black_array = keep(_create_black(true))
	return sampler.is_valid() and neutral_lights.is_valid() and black_2d.is_valid() and black_array.is_valid()

func _create_black(array_texture: bool) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.width = 1
	fmt.height = 1
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY if array_texture else RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(fmt, RDTextureView.new(), [PackedByteArray([0,0,0,0,0,0,0,0])])

func release_scene() -> void:
	var releasing := scene_owned.duplicate()
	releasing.reverse()
	for rid in releasing:
		if rid.is_valid():
			rd.free_rid(rid)
	scene_owned.clear()
	tlas = RID()
	vertices = RID()
	indices = RID()
	surfaces = RID()
	materials = RID()
	geometry_key.clear()
	transform_key.clear()
	previous_hit_sbt_range = 0
	scene_rows.clear()
	atlas.clear()
	atlas_samplers.clear()

func release() -> void:
	if rd == null:
		return
	release_scene()
	var releasing := owned.duplicate()
	releasing.reverse()
	for rid in releasing:
		if rid.is_valid():
			rd.free_rid(rid)
	owned.clear()
	sampler = RID()
	black_2d = RID()
	black_array = RID()
	neutral_lights = RID()
	rd = null

func all_rids() -> Array[RID]:
	var result: Array[RID] = []
	result.assign(owned + scene_owned)
	return result

func sync_scene(snapshot: Dictionary, hit_sbt_range: int) -> bool:
	var instances: Array = snapshot.get("instances", [])
	var next_key: Array = [snapshot.get("world_id"), snapshot.get("registry_epoch", 0), snapshot.get("snapshot_generation")]
	for instance in instances:
		next_key.append([instance.instance_id, instance.mesh_id, instance.layers, instance.cast_shadow])
	if next_key != geometry_key:
		release_scene()
		if not build_scene(instances):
			return false
		geometry_key = next_key
	var transforms: Array = []
	for instance in instances:
		transforms.append(instance.transform)
	if transforms == transform_key and tlas.is_valid() and previous_hit_sbt_range == hit_sbt_range:
		return true
	var native_instances: Array[RDAccelerationStructureInstance] = []
	for row in scene_rows:
		var instance: Dictionary = instances[row.instance]
		var native := RDAccelerationStructureInstance.new()
		native.id = native_instances.size()
		native.blas = row.blas
		native.transform = instance.transform
		# Godot meshes use clockwise winding; DXR/Vulkan hit kinds need the opposite front convention.
		native.flags = RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FLIP_FACING_BIT if native.transform.basis.determinant() > 0.0 else 0
		native.mask = 3 if instance.cast_shadow else 1
		native.hit_sbt_range = hit_sbt_range
		native_instances.append(native)
	if not tlas.is_valid():
		tlas = keep(rd.tlas_create(native_instances.size(), RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT), true)
	if not tlas.is_valid() or rd.tlas_build(tlas, native_instances) != OK:
		error = "RTGI TLAS build failed"
		return false
	transform_key = transforms
	previous_hit_sbt_range = hit_sbt_range
	return true

func build_trace_uniforms(textures: Array[RID], lighting: Dictionary, frame_buffer: RID,
		output: RID, dfg_texture: RID, reflection_inputs: bool, array_sky: bool) -> Array[RDUniform]:
	var uniforms: Array[RDUniform] = []
	var acceleration := RDUniform.new()
	acceleration.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	acceleration.binding = 0
	acceleration.add_id(tlas)
	uniforms.append(acceleration)
	var input_count := 5 if reflection_inputs else 4
	for index in input_count:
		uniforms.append(U.sampled(index + 1, sampler, textures[index]))
	var sky: RID = lighting.get("sky_radiance_texture", RID())
	var black: RID = black_array if array_sky else black_2d
	uniforms.append(U.sampled(6, sampler, sky if sky.is_valid() else black))
	var lights: RID = lighting.get("directional_light_buffer", RID())
	uniforms.append(U.uniform_buffer(7, lights if lights.is_valid() else neutral_lights))
	uniforms.append(U.storage_buffer(8, vertices))
	uniforms.append(U.storage_buffer(9, indices))
	uniforms.append(U.storage_buffer(10, surfaces))
	uniforms.append(U.storage_buffer(11, materials))
	for index in 8:
		var group := mini(index, atlas.size() - 1)
		uniforms.append(U.sampled(12 + index, atlas_samplers[group], atlas[group]))
	uniforms.append(U.uniform_buffer(20, frame_buffer))
	uniforms.append(U.image(21, output))
	var dfg: RID = dfg_texture if dfg_texture.is_valid() else lighting.get("dfg_texture", RID())
	uniforms.append(U.sampled(23, sampler, dfg if dfg.is_valid() else black_2d))
	return uniforms

func build_scene(instances: Array) -> bool:
	var vertex_bytes := PackedByteArray()
	var index_bytes := PackedByteArray()
	var surface_bytes := PackedByteArray()
	var material_bytes := PackedByteArray()
	var groups: Array = []
	var texture_locations: Dictionary = {}
	var texture_bytes := 0
	for instance_index in instances.size():
		var instance: Dictionary = instances[instance_index]
		var mesh: Dictionary = instance.mesh
		var vertex_base := vertex_bytes.size()
		var index_base := index_bytes.size()
		vertex_bytes.append_array(mesh.vertex_bytes)
		index_bytes.append_array(mesh.index_bytes)
		for surface in mesh.surfaces:
			var material: Dictionary = mesh.materials[surface.material_index]
			var texture: Dictionary = material.albedo_texture
			var location := Vector2i(-1, -1)
			if not texture.is_empty():
				var texture_key: Array = [texture.id, texture.filter, texture.repeat]
				if texture_locations.has(texture_key):
					location = texture_locations[texture_key]
				else:
					var group_key: Array = [texture.width, texture.height, texture.filter, texture.repeat]
					for group_index in groups.size():
						if groups[group_index].key == group_key and groups[group_index].data.size() < 32:
							location.x = group_index
							break
					if location.x < 0:
						location.x = groups.size()
						groups.append({"key": group_key, "data": []})
					location.y = groups[location.x].data.size()
					groups[location.x].data.append(texture.data)
					texture_locations[texture_key] = location
					texture_bytes += texture.data.size()
				if groups.size() > 8 or texture_bytes > 128 * 1024 * 1024:
					error = "RTGI texture atlas exceeds 8 groups or 128 MiB"
					return false
			var material_index := (material_bytes.size() / 4) / MATERIAL_WORD_STRIDE
			var data := PackedByteArray()
			data.resize(MATERIAL_ROW_BYTES)
			var albedo: Color = material.albedo
			var emission: Color = material.emission if material.emission_enabled else Color(0,0,0)
			var values := PackedFloat32Array([albedo.r, albedo.g, albedo.b, albedo.a, emission.r, emission.g, emission.b, material.emission_energy_multiplier, material.metallic])
			for word in values.size():
				data.encode_float(word * 4, values[word])
			data.encode_u32(36, location.y & 0xffffffff)
			data.encode_u32(40, material.flags)
			data.encode_u32(44, location.x & 0xffffffff)
			var uv: Vector4 = material.uv_transform
			for word in 4:
				data.encode_float(48 + word * 4, uv[word])
			data.encode_float(64, material.roughness)
			data.encode_float(68, material.specular)
			material_bytes.append_array(data)
			var vb: int = vertex_base + surface.vertex_base_byte
			var ib: int = index_base + surface.index_base_byte
			surface_bytes.append_array(PackedInt32Array([vb, ib, surface.index_count, material_index, 0, instance.layers, 0, 0]).to_byte_array())
			scene_rows.append({"instance": instance_index, "vertex": vb, "index": ib, "vertex_count": surface.vertex_count, "index_count": surface.index_count})
	if scene_rows.is_empty():
		return false
	vertices = keep(rd.storage_buffer_create(vertex_bytes.size(), vertex_bytes), true)
	indices = keep(rd.storage_buffer_create(index_bytes.size(), index_bytes), true)
	surfaces = keep(rd.storage_buffer_create(surface_bytes.size(), surface_bytes), true)
	materials = keep(rd.storage_buffer_create(material_bytes.size(), material_bytes), true)
	var flags := RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT | RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT
	var build_vertices := keep(rd.vertex_buffer_create(vertex_bytes.size(), vertex_bytes, flags), true)
	var build_indices := keep(rd.index_buffer_create(index_bytes.size() / 4, RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, index_bytes, false, flags), true)
	for row in scene_rows:
		var geometry := RDAccelerationStructureGeometry.new()
		geometry.vertex_buffer = build_vertices
		geometry.vertex_offset = row.vertex
		geometry.vertex_stride = 32
		geometry.vertex_count = row.vertex_count
		geometry.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
		geometry.index_buffer = build_indices
		geometry.index_offset = row.index
		geometry.index_count = row.index_count
		var blas := keep(rd.blas_create([geometry], RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT), true)
		if not blas.is_valid() or rd.blas_build(blas) != OK:
			error = "RTGI BLAS build failed"
			return false
		row.blas = blas
	if groups.is_empty():
		groups.append({"key": [1,1,1,false], "data": [PackedByteArray([255,255,255,255])]})
	for group in groups:
		var fmt := RDTextureFormat.new()
		fmt.width = group.key[0]
		fmt.height = group.key[1]
		fmt.array_layers = group.data.size()
		fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
		fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		var data: Array[PackedByteArray] = []
		data.assign(group.data)
		atlas.append(keep(rd.texture_create(fmt, RDTextureView.new(), data), true))
		var state := RDSamplerState.new()
		state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST if group.key[2] in [0,2,4] else RenderingDevice.SAMPLER_FILTER_LINEAR
		state.mag_filter = state.min_filter
		state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT if group.key[3] else RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		state.repeat_v = state.repeat_u
		atlas_samplers.append(keep(rd.sampler_create(state), true))
	return true
