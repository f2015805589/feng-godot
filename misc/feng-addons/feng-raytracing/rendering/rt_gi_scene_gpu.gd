@tool
extends RefCounted
## Shared render-thread scene owner for Feng's one-bounce ray tracing passes.
## Owns the BLAS/TLAS and the material, geometry, texture-atlas and common sampling data.
const DIR = "res://addons/feng-raytracing/shaders/"
const U = preload("res://addons/feng-render-pipeline/rd/uniforms.gd")
const Emitters = preload("res://addons/feng-raytracing/rendering/rt_gi_emitters.gd")
const Deformer = preload("res://addons/feng-raytracing/rendering/rt_gi_scene_deformer.gd")
const MATERIAL_ROW_BYTES := 80
const MATERIAL_WORD_STRIDE := 20
var rd: RenderingDevice
var owned: Array[RID] = []
var scene_owned: Array[RID] = []
var tlas := RID()
var vertices := RID()
var indices := RID()
var surfaces := RID()
var surface_tracking_buffer := RID()
var materials := RID()
var emitters := RID()
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
var surface_tracking_revision := -1
var surface_count := 0
var active_surface_count := 0
var material_revision := -1
var deformation_key_cache: Array = []
var pending_deform_blas_slots: Array[int] = []
var material_index_by_slot: Dictionary = {}
var emitter_signature_cache: Array = []
var deformer: RefCounted

func get_surface_tracking_buffer() -> RID:
	return surface_tracking_buffer

func get_surface_tracking_revision() -> int:
	return surface_tracking_revision

func get_surface_count() -> int:
	return surface_count

func get_active_surface_count() -> int:
	return active_surface_count

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
	if deformer != null:
		deformer.release()
		deformer = null
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
	surface_tracking_buffer = RID()
	materials = RID()
	emitters = RID()
	emitter_signature_cache.clear()
	geometry_key.clear()
	transform_key.clear()
	previous_hit_sbt_range = 0
	surface_tracking_revision = -1
	surface_count = 0
	active_surface_count = 0
	material_revision = -1
	deformation_key_cache.clear()
	pending_deform_blas_slots.clear()
	material_index_by_slot.clear()
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
	for rid in owned + scene_owned:
		if rid.is_valid() and not result.has(rid):
			result.append(rid)
	if deformer != null:
		for rid in deformer.all_rids():
			if rid.is_valid() and not result.has(rid):
				result.append(rid)
	return result

func sync_scene(snapshot: Dictionary, hit_sbt_range: int) -> bool:
	error = ""
	if rd == null:
		error = "RTGI shared scene has no RenderingDevice"
		return false
	var instances: Array = snapshot.get("instances", [])
	var next_key: Array = _make_geometry_key(snapshot, instances)
	if next_key != geometry_key:
		release_scene()
		if not build_scene(snapshot):
			var build_error := error
			release_scene()
			error = build_error
			return false
		geometry_key = next_key
	var tracking_revision := int(snapshot.get("surface_tracking_revision", 0))
	if tracking_revision != surface_tracking_revision:
		if not _upload_surface_tracking(snapshot):
			return false
	var next_material_revision := int(snapshot.get("material_revision", 0))
	var material_changed := next_material_revision != material_revision
	if material_changed:
		if not _rebuild_material_resources(instances):
			return false
	var transforms: Array = []
	var deformation_key: Array = []
	var surface_rows_changed := false
	for row_index in scene_rows.size():
		var row: Dictionary = scene_rows[row_index]
		var instance: Dictionary = _instance_for_row(instances, row)
		if instance.is_empty():
			error = "RTGI stable surface slot lost its snapshot instance"
			return false
		var current_surface: Dictionary = _surface_row_for_slot(instance,
				int(row.get("slot", -1)), int(row.get("surface_index", -1)))
		if current_surface.is_empty():
			error = "RTGI stable surface slot lost its current deformation snapshot"
			return false
		var deformation_value: Variant = current_surface.get("deformation", {})
		var deformation: Dictionary = deformation_value if deformation_value is Dictionary else {}
		var next_deformation_revision := int(current_surface.get("deformation_revision", 0))
		var next_deforming := bool(current_surface.get("deforming", false))
		var next_nee_unsampled := bool(current_surface.get("nee_unsampled", false))
		var next_layers := int(instance.get("layers", 1))
		var next_cast_shadow := bool(instance.get("cast_shadow", true))
		surface_rows_changed = surface_rows_changed \
				or bool(row.get("deforming", false)) != next_deforming \
				or bool(row.get("nee_unsampled", false)) != next_nee_unsampled \
				or int(row.get("layers", 1)) != next_layers
		row["generation"] = int(current_surface.get("generation", row.get("generation", 0)))
		row["geometry_revision"] = int(current_surface.get("geometry_revision", row.get("geometry_revision", 0)))
		row["motion_revision"] = int(current_surface.get("motion_revision", row.get("motion_revision", 0)))
		row["deforming"] = next_deforming
		row["nee_unsampled"] = next_nee_unsampled
		row["deformation"] = deformation
		row["deformation_revision"] = next_deformation_revision
		row["layers"] = next_layers
		row["cast_shadow"] = next_cast_shadow
		scene_rows[row_index] = row
		transforms.append([int(row.slot), instance.transform, instance.layers, instance.cast_shadow])
		deformation_key.append([int(row.slot), next_deformation_revision])
	if material_changed or surface_rows_changed:
		if not _upload_surface_rows():
			return false
	var transforms_changed := transforms != transform_key or previous_hit_sbt_range != hit_sbt_range
	var deformation_changed := deformation_key != deformation_key_cache
	if not transforms_changed and not deformation_changed and not material_changed and tlas.is_valid():
		return true
	var updated_deform_slots: Array[int] = []
	if deformation_changed and deformer != null:
		if not deformer.update_surfaces(scene_rows):
			error = str(deformer.error)
			return false
		updated_deform_slots = deformer.last_updated_slots.duplicate()
		for slot in updated_deform_slots:
			if not pending_deform_blas_slots.has(slot):
				pending_deform_blas_slots.append(slot)
	elif deformation_changed:
		# A non-deforming scene has no deformer resource graph. A non-empty key
		# change here indicates a malformed snapshot rather than work to skip.
		for row in scene_rows:
			if bool(row.get("deforming", false)):
				error = "RTGI deformation rows are missing their compute stage"
				return false
	for slot in pending_deform_blas_slots:
		var deformed_row := _row_for_slot(int(slot))
		if deformed_row.is_empty() or rd.blas_build(deformed_row.blas) != OK:
			error = "RTGI deformed BLAS rebuild failed"
			return false
	var needs_tlas_build := not tlas.is_valid() or transforms_changed or deformation_changed
	if needs_tlas_build:
		var native_instances: Array[RDAccelerationStructureInstance] = []
		for row in scene_rows:
			var instance: Dictionary = _instance_for_row(instances, row)
			var native := RDAccelerationStructureInstance.new()
			native.id = int(row.slot)
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
		# Keep these slots pending through a failed BLAS or TLAS build. A later
		# sync may have no new deformation dispatch, but must still rebuild BLAS
		# against the vertex buffer already written by the successful compute.
		pending_deform_blas_slots.clear()
	var next_emitter_signature := Emitters.signature(instances)
	if not emitters.is_valid() or next_emitter_signature != emitter_signature_cache:
		if not _replace_emitters(instances):
			return false
		emitter_signature_cache = next_emitter_signature
	transform_key = transforms
	deformation_key_cache = deformation_key
	previous_hit_sbt_range = hit_sbt_range
	material_revision = next_material_revision
	return true

func build_trace_uniforms(textures: Array[RID], lighting: Dictionary, frame_buffer: RID,
		output: RID, dfg_texture: RID, reflection_inputs: bool, array_sky: bool,
		include_surface_tracking := false) -> Array[RDUniform]:
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
	uniforms.append(U.storage_buffer(25, emitters))
	if include_surface_tracking:
		uniforms.append(U.storage_buffer(40, surface_tracking_buffer))
	return uniforms

func _make_geometry_key(snapshot: Dictionary, instances: Array) -> Array:
	var key: Array = [snapshot.get("world_id", 0), snapshot.get("world_generation", 0),
		snapshot.get("topology_revision", 0)]
	for instance_value in instances:
		var instance: Dictionary = instance_value
		var surfaces_key: Array = []
		for row_value in instance.get("surface_rows", []):
			var row: Dictionary = row_value
			var deformation_value: Variant = row.get("deformation", {})
			var deformation: Dictionary = deformation_value if deformation_value is Dictionary else {}
			var palette_value: Variant = deformation.get("bone_palette", PackedFloat32Array())
			var palette: PackedFloat32Array = palette_value if palette_value is PackedFloat32Array else PackedFloat32Array()
			var blend_weights_value: Variant = deformation.get("blend_weights", PackedFloat32Array())
			var blend_weights: PackedFloat32Array = blend_weights_value \
					if blend_weights_value is PackedFloat32Array else PackedFloat32Array()
			surfaces_key.append([int(row.get("slot", -1)),
				int(row.get("geometry_revision", 0)), int(row.get("surface_index", -1)),
				int(palette.size()), int(blend_weights.size()),
				int(deformation.get("bones_per_vertex", 4)),
				int(deformation.get("blend_shape_count", blend_weights.size()))])
		key.append([int(instance.get("instance_id", 0)), int(instance.get("mesh_id", 0)), surfaces_key])
	return key

func build_scene(snapshot: Dictionary) -> bool:
	var instances: Array = snapshot.get("instances", [])
	if instances.is_empty():
		error = "RTGI scene snapshot has no active mesh instances"
		return false
	var vertex_bytes := PackedByteArray()
	var index_bytes := PackedByteArray()
	scene_rows.clear()
	var seen_slots: Dictionary = {}
	for instance_index in instances.size():
		var instance: Dictionary = instances[instance_index]
		var mesh: Dictionary = instance.get("mesh", {})
		var source_vertices: PackedByteArray = mesh.get("vertex_bytes", PackedByteArray())
		var source_indices: PackedByteArray = mesh.get("index_bytes", PackedByteArray())
		if source_vertices.is_empty() or source_vertices.size() % 32 != 0 \
				or source_indices.size() % 4 != 0:
			error = "RTGI scene snapshot geometry byte arrays are malformed"
			return false
		var vertex_base := vertex_bytes.size()
		var index_base := index_bytes.size()
		vertex_bytes.append_array(source_vertices)
		index_bytes.append_array(source_indices)
		var mesh_surfaces: Array = mesh.get("surfaces", [])
		for row_value in instance.get("surface_rows", []):
			var surface_row: Dictionary = row_value
			var surface_index := int(surface_row.get("surface_index", -1))
			var slot := int(surface_row.get("slot", -1))
			if surface_index < 0 or surface_index >= mesh_surfaces.size() \
					or slot < 0 or slot > 0x00ffffff or seen_slots.has(slot):
				error = "RTGI snapshot surface slot or surface index is invalid"
				return false
			seen_slots[slot] = true
			var surface: Dictionary = mesh_surfaces[surface_index]
			var vb := vertex_base + int(surface.get("vertex_base_byte", 0))
			var ib := index_base + int(surface.get("index_base_byte", 0))
			var vertex_count := int(surface.get("vertex_count", 0))
			var index_count := int(surface.get("index_count", 0))
			if vb < 0 or ib < 0 or vertex_count <= 0 or index_count <= 0 \
					or index_count % 3 != 0 or vb + vertex_count * 32 > vertex_bytes.size() \
					or ib + index_count * 4 > index_bytes.size():
				error = "RTGI snapshot surface buffer range is invalid"
				return false
			var deformation_value: Variant = surface_row.get("deformation", {})
			var deformation: Dictionary = deformation_value if deformation_value is Dictionary else {}
			scene_rows.append({
				"instance_index": instance_index,
				"instance_id": int(instance.get("instance_id", 0)),
				"mesh_id": int(instance.get("mesh_id", 0)),
				"layers": int(instance.get("layers", 1)),
				"cast_shadow": bool(instance.get("cast_shadow", true)),
				"surface_index": surface_index,
				"slot": slot,
				"generation": int(surface_row.get("generation", 0)),
				"geometry_revision": int(surface_row.get("geometry_revision", 0)),
				"vertex_base_byte": vb,
				"index_base_byte": ib,
				"vertex_count": vertex_count,
				"index_count": index_count,
				"deforming": bool(surface_row.get("deforming", false)),
				"nee_unsampled": bool(surface_row.get("nee_unsampled", false)),
				"deformation": deformation,
				"deformation_revision": int(surface_row.get("deformation_revision", 0)),
				"blas": RID(),
			})
	if scene_rows.is_empty() or vertex_bytes.is_empty() or index_bytes.is_empty():
		error = "RTGI snapshot has no active triangle surfaces"
		return false
	active_surface_count = scene_rows.size()
	var tracking_rows: Array = snapshot.get("surface_tracking", [])
	surface_count = tracking_rows.size()
	for row in scene_rows:
		if int(row.slot) >= surface_count:
			error = "RTGI stable slot is outside the SurfaceTracking row array"
			return false
	var vertex_flags := RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT \
			| RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT \
			| RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT
	vertices = keep(rd.vertex_buffer_create(vertex_bytes.size(), vertex_bytes, vertex_flags), true)
	indices = keep(rd.storage_buffer_create(index_bytes.size(), index_bytes), true)
	if not vertices.is_valid() or not indices.is_valid():
		error = "RTGI shared vertex/index buffers could not be allocated"
		return false
	if not _upload_surface_tracking(snapshot):
		return false
	if not _rebuild_material_resources(instances):
		return false
	if not _upload_surface_rows():
		return false
	var has_deformation := false
	for row in scene_rows:
		has_deformation = has_deformation or bool(row.get("deforming", false))
	if has_deformation:
		deformer = Deformer.new()
		if not deformer.initialize(rd, vertex_bytes, vertices, scene_rows, surface_count):
			error = str(deformer.error)
			return false
		if not deformer.update_surfaces(scene_rows):
			error = str(deformer.error)
			return false
	var index_flags := RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT \
			| RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT
	for row in scene_rows:
		var surface_indices := index_bytes.slice(int(row.index_base_byte),
				int(row.index_base_byte) + int(row.index_count) * 4)
		var build_indices := keep(rd.index_buffer_create(int(row.index_count),
				RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, surface_indices, false, index_flags), true)
		if not build_indices.is_valid():
			error = "RTGI surface index build buffer could not be allocated"
			return false
		var geometry := RDAccelerationStructureGeometry.new()
		geometry.vertex_buffer = vertices
		geometry.vertex_offset = int(row.vertex_base_byte)
		geometry.vertex_stride = 32
		geometry.vertex_count = int(row.vertex_count)
		geometry.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
		geometry.index_buffer = build_indices
		geometry.index_offset = 0
		geometry.index_count = int(row.index_count)
		var blas := keep(rd.blas_create([geometry], RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT), true)
		if not blas.is_valid() or rd.blas_build(blas) != OK:
			error = "RTGI surface BLAS build failed"
			return false
		row.blas = blas
	material_revision = int(snapshot.get("material_revision", 0))
	surface_tracking_revision = int(snapshot.get("surface_tracking_revision", 0))
	return true

func _upload_surface_tracking(snapshot: Dictionary) -> bool:
	var rows: Array = snapshot.get("surface_tracking", [])
	var required_count := rows.size()
	var bytes := PackedByteArray()
	bytes.resize(maxi(required_count, 1) * 128)
	for row_index in required_count:
		var row_value: Variant = rows[row_index]
		if not row_value is Dictionary:
			error = "RTGI SurfaceTracking row is malformed"
			return false
		var row: Dictionary = row_value
		var local_to_world: Transform3D = row.get("local_to_world", Transform3D.IDENTITY)
		var normal_to_world: Basis = row.get("normal_to_world", Basis.IDENTITY)
		var identity: PackedInt32Array = row.get("identity", PackedInt32Array([0, 0, 0, 0]))
		if identity.size() != 4 or not local_to_world.is_finite() or not normal_to_world.is_finite():
			error = "RTGI SurfaceTracking transform or identity is invalid"
			return false
		var values := PackedFloat32Array([
			local_to_world.basis.x.x, local_to_world.basis.x.y, local_to_world.basis.x.z, 0.0,
			local_to_world.basis.y.x, local_to_world.basis.y.y, local_to_world.basis.y.z, 0.0,
			local_to_world.basis.z.x, local_to_world.basis.z.y, local_to_world.basis.z.z, 0.0,
			local_to_world.origin.x, local_to_world.origin.y, local_to_world.origin.z, 1.0,
			normal_to_world.x.x, normal_to_world.x.y, normal_to_world.x.z, 0.0,
			normal_to_world.y.x, normal_to_world.y.y, normal_to_world.y.z, 0.0,
			normal_to_world.z.x, normal_to_world.z.y, normal_to_world.z.z, 0.0,
		])
		for value_index in values.size():
			bytes.encode_float(row_index * 128 + value_index * 4, values[value_index])
		for identity_index in 4:
			bytes.encode_u32(row_index * 128 + 112 + identity_index * 4,
				int(identity[identity_index]) & 0xffffffff)
	if not surface_tracking_buffer.is_valid() or rows.size() != surface_count:
		var next_buffer := rd.storage_buffer_create(bytes.size(), bytes)
		if not next_buffer.is_valid():
			error = "RTGI SurfaceTracking buffer allocation failed"
			return false
		var previous := surface_tracking_buffer
		surface_tracking_buffer = keep(next_buffer, true)
		if previous.is_valid():
			scene_owned.erase(previous)
			rd.free_rid(previous)
	elif rd.buffer_update(surface_tracking_buffer, 0, bytes.size(), bytes) != OK:
		error = "RTGI SurfaceTracking buffer update failed"
		return false
	surface_count = required_count
	surface_tracking_revision = int(snapshot.get("surface_tracking_revision", 0))
	return true

func _upload_surface_rows() -> bool:
	var bytes := PackedByteArray()
	bytes.resize(maxi(surface_count, 1) * 32)
	for row in scene_rows:
		var slot := int(row.get("slot", -1))
		var offset := slot * 32
		if slot < 0 or slot >= surface_count or not material_index_by_slot.has(slot):
			error = "RTGI surface row slot or material mapping is invalid"
			return false
		var words := PackedInt32Array([
			int(row.get("vertex_base_byte", 0)), int(row.get("index_base_byte", 0)),
			int(row.get("index_count", 0)), int(material_index_by_slot[slot]),
			1 if bool(row.get("nee_unsampled", false)) else 0,
			int(row.get("layers", 1)), 0, 0])
		for word_index in 8:
			bytes.encode_u32(offset + word_index * 4, words[word_index])
	if not surfaces.is_valid():
		surfaces = keep(rd.storage_buffer_create(bytes.size(), bytes), true)
		if not surfaces.is_valid():
			error = "RTGI surface-row buffer allocation failed"
			return false
	elif rd.buffer_update(surfaces, 0, bytes.size(), bytes) != OK:
		error = "RTGI surface-row buffer update failed"
		return false
	return true

func _rebuild_material_resources(instances: Array) -> bool:
	var material_bytes := PackedByteArray()
	var groups: Array = []
	var texture_locations: Dictionary = {}
	var slot_materials: Dictionary = {}
	var texture_bytes := 0
	for row in scene_rows:
		var instance := _instance_for_row(instances, row)
		if instance.is_empty():
			error = "RTGI material row lost its source instance"
			return false
		var mesh: Dictionary = instance.get("mesh", {})
		var mesh_surfaces: Array = mesh.get("surfaces", [])
		var surface_index := int(row.get("surface_index", -1))
		if surface_index < 0 or surface_index >= mesh_surfaces.size():
			error = "RTGI material row has an invalid surface index"
			return false
		var surface: Dictionary = mesh_surfaces[surface_index]
		var mesh_materials: Array = mesh.get("materials", [])
		var source_material_index := int(surface.get("material_index", -1))
		if source_material_index < 0 or source_material_index >= mesh_materials.size():
			error = "RTGI material snapshot index is invalid"
			return false
		var material: Dictionary = mesh_materials[source_material_index]
		var texture_value: Variant = material.get("albedo_texture", {})
		var texture: Dictionary = texture_value if texture_value is Dictionary else {}
		var location := Vector2i(-1, -1)
		if not texture.is_empty():
			var texture_key: Array = [texture.get("id", 0), texture.get("filter", 0), texture.get("repeat", false)]
			if texture_locations.has(texture_key):
				location = texture_locations[texture_key]
			else:
				var group_key: Array = [texture.get("width", 0), texture.get("height", 0),
					texture.get("filter", 0), texture.get("repeat", false)]
				for group_index in groups.size():
					if groups[group_index].key == group_key and groups[group_index].data.size() < 32:
						location.x = group_index
						break
				if location.x < 0:
					location.x = groups.size()
					groups.append({"key": group_key, "data": []})
				location.y = groups[location.x].data.size()
				var image_data: PackedByteArray = texture.get("data", PackedByteArray())
				if image_data.is_empty():
					error = "RTGI albedo texture snapshot has no pixel data"
					return false
				groups[location.x].data.append(image_data)
				texture_locations[texture_key] = location
				texture_bytes += image_data.size()
			if groups.size() > 8 or texture_bytes > 128 * 1024 * 1024:
				error = "RTGI texture atlas exceeds 8 groups or 128 MiB"
				return false
		var material_index := material_bytes.size() / MATERIAL_ROW_BYTES
		slot_materials[int(row.slot)] = material_index
		var data := PackedByteArray()
		data.resize(MATERIAL_ROW_BYTES)
		var albedo: Color = material.get("albedo", Color.WHITE)
		var emission: Color = material.get("emission", Color.BLACK) \
				if bool(material.get("emission_enabled", false)) else Color.BLACK
		var values := PackedFloat32Array([albedo.r, albedo.g, albedo.b, albedo.a,
			emission.r, emission.g, emission.b,
			float(material.get("emission_energy_multiplier", 1.0)), float(material.get("metallic", 0.0))])
		for word in values.size():
			if not is_finite(values[word]):
				error = "RTGI material snapshot contains nonfinite values"
				return false
			data.encode_float(word * 4, values[word])
		data.encode_u32(36, int(location.y) & 0xffffffff)
		data.encode_u32(40, int(material.get("flags", 0)))
		data.encode_u32(44, int(location.x) & 0xffffffff)
		var uv: Vector4 = material.get("uv_transform", Vector4(1, 1, 0, 0))
		for word in 4:
			if not is_finite(uv[word]):
				error = "RTGI material UV transform is nonfinite"
				return false
			data.encode_float(48 + word * 4, uv[word])
		data.encode_float(64, float(material.get("roughness", 1.0)))
		data.encode_float(68, float(material.get("specular", 0.5)))
		material_bytes.append_array(data)
	if groups.is_empty():
		groups.append({"key": [1, 1, 1, false], "data": [PackedByteArray([255, 255, 255, 255])]})
	var created: Array[RID] = []
	var next_material := rd.storage_buffer_create(material_bytes.size(), material_bytes)
	if not next_material.is_valid():
		error = "RTGI material buffer allocation failed"
		return false
	created.append(next_material)
	var next_atlas: Array[RID] = []
	var next_samplers: Array[RID] = []
	for group in groups:
		var fmt := RDTextureFormat.new()
		fmt.width = int(group.key[0])
		fmt.height = int(group.key[1])
		fmt.array_layers = group.data.size()
		fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
		fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		var data: Array[PackedByteArray] = []
		data.assign(group.data)
		var texture_rid := rd.texture_create(fmt, RDTextureView.new(), data)
		if not texture_rid.is_valid():
			var reverse_created := created.duplicate()
			reverse_created.reverse()
			for rid in reverse_created:
				rd.free_rid(rid)
			error = "RTGI albedo atlas allocation failed"
			return false
		created.append(texture_rid)
		next_atlas.append(texture_rid)
		var sampler_state := RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST \
				if int(group.key[2]) in [0, 2, 4] else RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mag_filter = sampler_state.min_filter
		sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT \
				if bool(group.key[3]) else RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		sampler_state.repeat_v = sampler_state.repeat_u
		var sampler_rid := rd.sampler_create(sampler_state)
		if not sampler_rid.is_valid():
			var reverse_created := created.duplicate()
			reverse_created.reverse()
			for rid in reverse_created:
				rd.free_rid(rid)
			error = "RTGI albedo sampler allocation failed"
			return false
		created.append(sampler_rid)
		next_samplers.append(sampler_rid)
	var previous_resources: Array[RID] = []
	if materials.is_valid(): previous_resources.append(materials)
	previous_resources.append_array(atlas)
	previous_resources.append_array(atlas_samplers)
	materials = next_material
	atlas = next_atlas
	atlas_samplers = next_samplers
	material_index_by_slot = slot_materials
	scene_owned.append_array(created)
	previous_resources.reverse()
	for rid in previous_resources:
		if rid.is_valid():
			scene_owned.erase(rid)
			rd.free_rid(rid)
	return true

func _replace_emitters(instances: Array) -> bool:
	var emitter_data := Emitters.build(instances)
	if emitter_data.is_empty():
		error = "RTGI emitter distribution data is empty"
		return false
	var next_emitters := rd.storage_buffer_create(emitter_data.size(), emitter_data)
	if not next_emitters.is_valid():
		error = "RTGI emitter distribution creation failed"
		return false
	var previous := emitters
	emitters = keep(next_emitters, true)
	if previous.is_valid():
		scene_owned.erase(previous)
		rd.free_rid(previous)
	return true

func _instance_for_row(instances: Array, row: Dictionary) -> Dictionary:
	var index := int(row.get("instance_index", -1))
	if index >= 0 and index < instances.size():
		var candidate: Dictionary = instances[index]
		if int(candidate.get("instance_id", 0)) == int(row.get("instance_id", -1)):
			return candidate
	var instance_id := int(row.get("instance_id", -1))
	for candidate_value in instances:
		var candidate: Dictionary = candidate_value
		if int(candidate.get("instance_id", 0)) == instance_id:
			return candidate
	return {}

func _row_for_slot(slot: int) -> Dictionary:
	for row in scene_rows:
		if int(row.get("slot", -1)) == slot:
			return row
	return {}

func _surface_row_for_slot(instance: Dictionary, slot: int, surface_index: int) -> Dictionary:
	var rows_value: Variant = instance.get("surface_rows", [])
	if not rows_value is Array:
		return {}
	for row_value in rows_value:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		if int(row.get("slot", -1)) == slot \
				and int(row.get("surface_index", -1)) == surface_index:
			return row
	return {}
