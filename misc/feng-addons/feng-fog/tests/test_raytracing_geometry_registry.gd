extends SceneTree
## CPU-only contract checks for the RT scene geometry snapshot.

const RegistryScript = preload("res://addons/feng-fog/rendering/raytracing/fog_rt_geometry_registry.gd")
const ShadowProviderScript = preload("res://addons/feng-fog/rendering/raytracing/fog_rt_shadow_provider.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _require(p_condition: bool, p_message: String) -> void:
	_checks += 1
	if not p_condition:
		_failures += 1
		push_error("REGRESSION: " + p_message)


func _run() -> void:
	_test_tlas_release_state()
	var raw_stage_names := ["raygen", "miss", "closest_hit", "any_hit"]
	for stage_name in raw_stage_names:
		var raw_path := "res://addons/feng-fog/rendering/raytracing/fog_shadow_%s.glslinc" % stage_name
		var import_path := "res://addons/feng-fog/rendering/raytracing/fog_shadow_%s.glsl" % stage_name
		_require(FileAccess.file_exists(raw_path), "RT stage source is available as a non-imported include: %s" % stage_name)
		_require(not FileAccess.file_exists(import_path), "raw RT stage is not imported as a regular shader: %s" % stage_name)
		if FileAccess.file_exists(raw_path):
			var stage_source := FileAccess.get_file_as_string(raw_path)
			_require(stage_source.begins_with("#version 460"), "RD ray-tracing stage uses required GLSL 4.60: %s" % stage_name)
	var viewport := SubViewport.new()
	root.add_child(viewport)
	var world := World3D.new()
	viewport.world_3d = world
	var scene_root := Node3D.new()
	viewport.add_child(scene_root)

	var shared_mesh := BoxMesh.new()
	var scissor_material := StandardMaterial3D.new()
	scissor_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	scissor_material.alpha_scissor_threshold = 0.37
	var hash_material := StandardMaterial3D.new()
	hash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	hash_material.alpha_hash_scale = 0.65
	var opaque_material := StandardMaterial3D.new()

	var scissor_instance := MeshInstance3D.new()
	scissor_instance.name = "ScissorOverride"
	scissor_instance.mesh = shared_mesh
	scissor_instance.material_override = scissor_material
	scissor_instance.layers = 0x00010001
	scene_root.add_child(scissor_instance)
	var hash_instance := MeshInstance3D.new()
	hash_instance.name = "HashOverride"
	hash_instance.mesh = shared_mesh
	hash_instance.material_override = hash_material
	scene_root.add_child(hash_instance)
	var opaque_instance := MeshInstance3D.new()
	opaque_instance.name = "OpaqueOverride"
	opaque_instance.mesh = shared_mesh
	opaque_instance.material_override = opaque_material
	scene_root.add_child(opaque_instance)

	var lod_mesh := ArrayMesh.new()
	var lod_arrays: Array = []
	lod_arrays.resize(Mesh.ARRAY_MAX)
	lod_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0),
		Vector3(1.0, 1.0, 0.0), Vector3(-1.0, 1.0, 0.0),
	])
	lod_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	lod_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lod_arrays, [], {1.0: PackedInt32Array([0, 1, 3])})
	var lod_instance := MeshInstance3D.new()
	lod_instance.name = "LodMesh"
	lod_instance.mesh = lod_mesh
	scene_root.add_child(lod_instance)

	var multimesh := MultiMesh.new()
	multimesh.mesh = shared_mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = 3
	multimesh.visible_instance_count = 2
	var multi_instance := MultiMeshInstance3D.new()
	multi_instance.name = "MultiOverride"
	multi_instance.multimesh = multimesh
	multi_instance.material_override = scissor_material
	multi_instance.layers = 0x00020002
	scene_root.add_child(multi_instance)
	var csg_box := CSGBox3D.new()
	csg_box.name = "CSGRootCaster"
	csg_box.position = Vector3(0.0, 3.0, 0.0)
	scene_root.add_child(csg_box)

	var hidden_instance := MeshInstance3D.new()
	hidden_instance.mesh = shared_mesh
	hidden_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene_root.add_child(hidden_instance)

	await process_frame
	var registry = RegistryScript.new()
	_require(ShadowProviderScript != null, "RT provider script parses with the 48-byte ray and alpha metadata ABI")
	var provider = ShadowProviderScript.new()
	_require(ShadowProviderScript._object_id_is_valid(shared_mesh.get_instance_id()),
			"a real ArrayMesh instance ID is accepted regardless of its signed high-bit representation")
	var alpha_placeholder := ShadowProviderScript.storage_buffer_initial_data(
			PackedInt32Array([-1]).to_byte_array())
	_require(alpha_placeholder.size() == 16 and alpha_placeholder.decode_u32(0) == 0xffffffff
			and alpha_placeholder.decode_u32(4) == 0 and alpha_placeholder.decode_u32(12) == 0,
			"one white default alpha word is zero-padded to the exact minimum storage-buffer allocation")
	var larger_metadata := ShadowProviderScript.storage_buffer_initial_data(PackedByteArray([1, 2, 3, 4]), 32)
	_require(larger_metadata.size() == 32 and larger_metadata[0] == 1
			and larger_metadata[3] == 4 and larger_metadata[4] == 0,
			"storage-buffer initial data is padded to its requested allocation without truncation")
	var packed_instance_metadata := ShadowProviderScript.pack_instance_metadata(
			3, 7, 2, -2147483643).to_byte_array()
	_require(packed_instance_metadata.size() == 16
			and packed_instance_metadata.decode_u32(0) == 3
			and packed_instance_metadata.decode_u32(4) == 7
			and packed_instance_metadata.decode_u32(8) == 2
			and packed_instance_metadata.decode_u32(12) == 0x80000005,
			"instance metadata keeps its full 32-bit caster layer mask in the any-hit lane")
	var input_contract: Dictionary = provider.get_ray_input_contract()
	_require(int(input_contract.get("stride_bytes", 0)) == 48,
			"ray input records are three 16-byte std430 lanes")
	_require(input_contract.get("ownership") == "borrowed_caller"
			and bool(input_contract.get("zero_copy")), "ray input stays borrowed and zero-copy")
	_require(input_contract.get("device") == "RenderingServer main RenderingDevice",
			"ray input uses the same main RD as BLAS/TLAS and the trace pipeline")
	_require(input_contract.get("coordinate_space") == "world_space"
			and input_contract.get("distance_unit") == "meter",
			"shadow rays use normalized world coordinates and meter distances")
	var cone_record: Dictionary = input_contract.get("record_fields", [])[2]
	_require(int(input_contract.get("abi_version", 0)) == 2
			and str(cone_record.get("meaning", "")).contains("IEEE-754 radius/growth bits")
			and str(cone_record.get("name", "")) == "cone_words"
			and str(cone_record.get("format", "")).contains("uvec4 raw words")
			and str(cone_record.get("meaning", "")).contains("raw uint32 light mask")
			and str(cone_record.get("meaning", "")).contains("active 1.0"),
			"48-byte ray ABI v2 defines float-bit footprint lanes and an unconverted raw uint mask lane")
	var unavailable_result: Dictionary = provider.trace_shadow_batch(null, {}, RID(), 0,
			48, 23, 1, 1, 1, 23)
	_require(not bool(unavailable_result.get("valid", true)),
			"provider rejects a missing RenderingDevice")
	_require(bool(unavailable_result.get("fallback_required", false))
			and unavailable_result.get("fallback_provider") == "complete_raster_shadow_batch",
			"provider requests complete raster fallback instead of assuming unoccluded rays")
	_require(int(unavailable_result.get("frame_generation", -1)) == 23,
			"failure response preserves the ray batch generation")
	_require(registry.attach(scene_root, world), "registry attaches to a live world")
	var snapshot: Dictionary = registry.get_snapshot()
	_require(snapshot.get("abi_version") == RegistryScript.SNAPSHOT_VERSION, "snapshot ABI is stable")
	_require(snapshot.get("geometries", []).size() == 3,
			"shared mesh, LOD mesh, and public CSG root mesh are each captured once")
	var shared_geometry := _geometry_for_mesh(snapshot, shared_mesh.get_instance_id())
	var shared_geometry_rows := 0
	var all_geometry_revisions_valid := true
	for geometry in snapshot.get("geometries", []):
		if int(geometry.get("mesh_id", 0)) == shared_mesh.get_instance_id():
			shared_geometry_rows += 1
		if int(geometry.get("mesh_revision", 0)) <= 0:
			all_geometry_revisions_valid = false
	_require(shared_geometry_rows == 1 and int(shared_geometry.get("mesh_revision", 0)) > 0
			and all_geometry_revisions_valid,
			"snapshot exports each shared geometry once with its positive resource revision")
	var initial_shared_mesh_revision := int(shared_geometry.get("mesh_revision", 0))
	var instances: Array = snapshot.get("instances", [])
	_require(instances.size() == 7,
			"four mesh instances, two visible MultiMesh instances, and the CSG root caster are captured")
	var by_name := {}
	for node in [scissor_instance, hash_instance, opaque_instance, multi_instance]:
		by_name[node.name] = node.get_instance_id()
	var materials_by_instance := {}
	for instance in instances:
		materials_by_instance[int(instance["instance_id"])] = instance["surface_materials"]
	var scissor_snapshot: Dictionary = materials_by_instance[by_name["ScissorOverride"]][0]
	var hash_snapshot: Dictionary = materials_by_instance[by_name["HashOverride"]][0]
	var opaque_snapshot: Dictionary = materials_by_instance[by_name["OpaqueOverride"]][0]
	var multi_snapshot: Dictionary = {}
	for instance in instances:
		if int(instance.get("source_node_id", 0)) == multi_instance.get_instance_id():
			multi_snapshot = instance["surface_materials"][0]
			break
	_require(scissor_snapshot.get("mode") == "scissor", "first shared-mesh override keeps alpha-scissor material")
	_require(is_equal_approx(float(scissor_snapshot.get("threshold", -1.0)), 0.37), "scissor threshold is captured")
	_require(hash_snapshot.get("mode") == "hash", "second shared-mesh override keeps alpha-hash material")
	_require(is_equal_approx(float(hash_snapshot.get("hash_scale", -1.0)), 0.65), "hash scale is captured")
	_require(opaque_snapshot.get("mode") == "opaque", "opaque override is independent of masked overrides")
	_require(multi_snapshot.get("mode") == "scissor", "MultiMeshInstance material override is captured without MeshInstance-only APIs")
	var layered_mesh_mask := -1
	var layered_multi_mask := -1
	for instance in instances:
		if int(instance.get("source_node_id", 0)) == scissor_instance.get_instance_id():
			layered_mesh_mask = int(instance.get("layer_mask", -1))
		if int(instance.get("source_node_id", 0)) == multi_instance.get_instance_id():
			layered_multi_mask = int(instance.get("layer_mask", -1))
	_require(layered_mesh_mask == 0x00010001,
			"mesh caster snapshots retain layer bits above the RD eight-bit TLAS mask")
	_require(layered_multi_mask == 0x00020002,
			"MultiMesh caster snapshots retain its complete 32-bit visual layer mask")
	var csg_captured := false
	for instance in instances:
		if int(instance.get("source_node_id", 0)) == csg_box.get_instance_id():
			csg_captured = instance.get("geometry_source") == "csg" \
					and instance.get("transform", Transform3D.IDENTITY).origin.is_equal_approx(Vector3(0.0, 3.0, 0.0))
	_require(csg_captured, "public CSG get_meshes geometry and its node transform enter the shadow snapshot")
	_require(snapshot.get("unsupported_shadow_geometry", []).is_empty(), "supported static casters do not trigger fallback")
	var initial_geometry_revision := int(snapshot.get("geometry_revision", 0))
	var initial_alpha_revision := int(snapshot.get("alpha_payload_revision", 0))
	var initial_snapshot_revision := int(snapshot.get("snapshot_revision", 0))
	opaque_instance.position = Vector3(2.0, 0.0, 0.0)
	var transform_snapshot: Dictionary = registry.get_snapshot()
	var moved_instance: Dictionary = {}
	for instance in transform_snapshot.get("instances", []):
		if int(instance.get("instance_id", 0)) == opaque_instance.get_instance_id():
			moved_instance = instance
			break
	_require(transform_snapshot.get("snapshot_revision", 0) > initial_snapshot_revision
			and moved_instance.get("transform", Transform3D.IDENTITY).origin.is_equal_approx(Vector3(2.0, 0.0, 0.0)),
			"transform changes are published in the next immutable TLAS snapshot")
	_require(int(transform_snapshot.get("geometry_revision", -1)) == initial_geometry_revision
			and int(transform_snapshot.get("alpha_payload_revision", -1)) == initial_alpha_revision,
			"transform-only updates reuse cached mesh geometry and alpha metadata")
	_require(int(_geometry_for_mesh(transform_snapshot, shared_mesh.get_instance_id()).get("mesh_revision", 0))
			== initial_shared_mesh_revision,
			"transform-only updates preserve the shared mesh resource revision")
	shared_mesh.size = Vector3(2.0, 1.0, 1.0)
	var resource_changed_snapshot: Dictionary = registry.get_snapshot()
	var resource_changed_geometry := _geometry_for_mesh(resource_changed_snapshot, shared_mesh.get_instance_id())
	_require(int(resource_changed_geometry.get("mesh_revision", 0)) > initial_shared_mesh_revision
			and int(resource_changed_snapshot.get("geometry_revision", 0)) > initial_geometry_revision,
			"a changed mesh resource publishes an incremented revision with its geometry payload")
	var original_instance_ids := _ordered_instance_ids(snapshot)
	var original_sorted_instance_ids := original_instance_ids.duplicate()
	original_sorted_instance_ids.sort()
	scene_root.remove_child(hash_instance)
	scene_root.add_child(hash_instance)
	await process_frame
	var reordered_snapshot: Dictionary = registry.get_snapshot()
	var reordered_instance_ids := _ordered_instance_ids(reordered_snapshot)
	var reordered_sorted_instance_ids := reordered_instance_ids.duplicate()
	reordered_sorted_instance_ids.sort()
	_require(reordered_instance_ids != original_instance_ids
			and reordered_sorted_instance_ids == original_sorted_instance_ids,
			"re-registering a caster changes TLAS custom-index order without changing active membership")
	_require(int(reordered_snapshot.get("alpha_payload_revision", -1)) > initial_alpha_revision,
			"alpha metadata revision tracks a reordered TLAS custom-index mapping")
	var alpha_before_layer_change := int(reordered_snapshot.get("alpha_payload_revision", -1))
	var original_hash_layers := hash_instance.layers
	hash_instance.layers = 0x40000004
	var changed_layer_snapshot: Dictionary = registry.get_snapshot()
	_require(int(changed_layer_snapshot.get("alpha_payload_revision", -1)) > alpha_before_layer_change,
			"light-mask changes invalidate the matching per-instance any-hit metadata")
	var alpha_before_layer_restore := int(changed_layer_snapshot.get("alpha_payload_revision", -1))
	hash_instance.layers = original_hash_layers
	var restored_layer_snapshot: Dictionary = registry.get_snapshot()
	_require(int(restored_layer_snapshot.get("alpha_payload_revision", -1)) > alpha_before_layer_restore,
			"restoring a caster light mask restores its matching alpha metadata")
	var alpha_before_multimesh_count := int(restored_layer_snapshot.get("alpha_payload_revision", -1))
	multimesh.visible_instance_count = 1
	var one_multimesh_snapshot: Dictionary = registry.get_snapshot()
	_require(int(one_multimesh_snapshot.get("alpha_payload_revision", -1)) > alpha_before_multimesh_count
			and _count_source_instances(one_multimesh_snapshot, multi_instance.get_instance_id()) == 1,
			"MultiMesh visible-instance count invalidates ordered any-hit metadata")
	var alpha_before_multimesh_restore := int(one_multimesh_snapshot.get("alpha_payload_revision", -1))
	multimesh.visible_instance_count = 2
	var restored_multimesh_snapshot: Dictionary = registry.get_snapshot()
	_require(int(restored_multimesh_snapshot.get("alpha_payload_revision", -1)) > alpha_before_multimesh_restore
			and _count_source_instances(restored_multimesh_snapshot, multi_instance.get_instance_id()) == 2,
			"restoring MultiMesh active indices refreshes the matching any-hit rows")
	opaque_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hash_instance.visible = false
	multimesh.visible_instance_count = 1
	var filtered_snapshot: Dictionary = registry.get_snapshot()
	var filtered_multi_count := 0
	for instance in filtered_snapshot.get("instances", []):
		if int(instance.get("source_node_id", 0)) == multi_instance.get_instance_id():
			filtered_multi_count += 1
	_require(filtered_snapshot.get("instances", []).size() == 4 and filtered_multi_count == 1,
			"visibility, cast-shadow, and MultiMesh visible-instance changes filter TLAS instances")
	opaque_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	hash_instance.visible = true
	multimesh.visible_instance_count = 2
	var sprite_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	sprite_image.fill(Color.WHITE)
	var sprite_caster := Sprite3D.new()
	sprite_caster.name = "UnsupportedSpriteCaster"
	sprite_caster.texture = ImageTexture.create_from_image(sprite_image)
	sprite_caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	scene_root.add_child(sprite_caster)
	var particles_caster := GPUParticles3D.new()
	particles_caster.name = "UnsupportedParticlesCaster"
	particles_caster.amount = 1
	particles_caster.draw_passes = 1
	particles_caster.set_draw_pass_mesh(0, BoxMesh.new())
	particles_caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	scene_root.add_child(particles_caster)
	var ordinary_node := Node3D.new()
	ordinary_node.name = "NonCasterNode"
	scene_root.add_child(ordinary_node)
	await process_frame
	var unsupported_snapshot: Dictionary = registry.get_snapshot()
	var unsupported_classes: Dictionary = {}
	for unsupported in unsupported_snapshot.get("unsupported_shadow_geometry", []):
		unsupported_classes[str(unsupported.get("node_class", ""))] = true
	_require(unsupported_classes.has("Sprite3D"),
			"visible Sprite3D shadow casters request a complete raster fallback")
	_require(unsupported_classes.has("GPUParticles3D"),
			"visible particle shadow casters request a complete raster fallback")
	var ordinary_node_reported := false
	for unsupported in unsupported_snapshot.get("unsupported_shadow_geometry", []):
		if int(unsupported.get("instance_id", 0)) == ordinary_node.get_instance_id():
			ordinary_node_reported = true
	_require(not ordinary_node_reported, "ordinary Node3D helpers are not treated as shadow casters")
	sprite_caster.queue_free()
	particles_caster.queue_free()
	ordinary_node.queue_free()
	await process_frame
	var lod_geometry: Dictionary = {}
	for geometry in snapshot.get("geometries", []):
		if geometry.get("surfaces", [])[0].get("vertices", PackedVector3Array()).size() == 4:
			lod_geometry = geometry
			break
	var captured_lods: Array = lod_geometry.get("surfaces", [])[0].get("lods", [])
	_require(captured_lods.size() == 1, "raw RenderingServer surface data exposes and decodes its LOD")
	_require(captured_lods[0].get("indices") == PackedInt32Array([0, 1, 3]), "16-bit LOD index bytes decode correctly")
	var registry_capabilities: Dictionary = registry.get_capability_report()
	_require(bool(registry_capabilities.get("captures_all_mesh_lods")), "all raw mesh LODs are captured")
	_require(not bool(registry_capabilities.get("supports_screen_lod_selection")), "screen LOD selection is not claimed")
	_require(bool(registry_capabilities.get("supports_terrain3d_bake_mesh"))
			and bool(registry_capabilities.get("unsupported_geometry_instances_force_complete_raster_fallback")),
			"Terrain3D has an explicit public-bake adapter and unknown geometry has a fail-closed path")
	_require(registry._terrain_bake_lod(1, 64) == 0,
			"small Terrain3D bakes retain the public bake_mesh highest detail")
	_require(registry._terrain_bake_lod(1, 2048) == 2,
			"large Terrain3D bakes select a coarser cached LOD within the triangle budget")
	_require(registry._terrain_bake_lod(10000, 2048) == -1,
			"Terrain3D bakes over the maximum LOD budget request complete raster fallback")
	if ClassDB.class_exists("Terrain3D"):
		print("Terrain3D extension detected; its runtime adapter is covered by public bake_mesh and data-change contracts")
	else:
		print("SKIP Terrain3D instance fixture: this CPU fixture has no Terrain3D GDExtension binary")
	var alpha_mesh := ArrayMesh.new()
	var alpha_arrays: Array = []
	alpha_arrays.resize(Mesh.ARRAY_MAX)
	alpha_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3.ZERO, Vector3.RIGHT, Vector3.UP,
	])
	alpha_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	alpha_arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2.ZERO, Vector2.RIGHT, Vector2.UP,
	])
	alpha_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, alpha_arrays)
	var alpha_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	alpha_image.fill(Color(1.0, 1.0, 1.0, 1.0))
	alpha_image.set_pixel(0, 0, Color(1.0, 1.0, 1.0, 0.25))
	var alpha_texture := ImageTexture.create_from_image(alpha_image)
	var alpha_material := StandardMaterial3D.new()
	alpha_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	alpha_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	alpha_material.albedo_texture = alpha_texture
	var alpha_instance := MeshInstance3D.new()
	alpha_instance.name = "AlphaScissorTexture"
	alpha_instance.mesh = alpha_mesh
	alpha_instance.material_override = alpha_material
	scene_root.add_child(alpha_instance)
	await process_frame
	var alpha_snapshot: Dictionary = registry.get_snapshot()
	var alpha_texture_id := alpha_texture.get_instance_id()
	_require(ShadowProviderScript._object_id_is_valid(alpha_texture_id),
			"a real ImageTexture instance ID is accepted regardless of its signed high-bit representation")
	var alpha_texture_snapshot_found := false
	for texture_snapshot in alpha_snapshot.get("alpha_textures", []):
		if int(texture_snapshot.get("texture_id", 0)) == alpha_texture_id:
			alpha_texture_snapshot_found = bool(texture_snapshot.get("valid", false))
	_require(alpha_texture_snapshot_found,
			"alpha texture snapshot cache preserves its real signed instance ID")
	var alpha_geometry_instance: Dictionary = {}
	for instance in alpha_snapshot.get("instances", []):
		if int(instance.get("instance_id", 0)) == alpha_instance.get_instance_id():
			alpha_geometry_instance = instance
			break
	var alpha_material_snapshot: Dictionary = alpha_geometry_instance.get("surface_materials", [{}])[0]
	_require(alpha_material_snapshot.get("mode") == "scissor"
			and int(alpha_material_snapshot.get("alpha_texture_width", 0)) == 2,
			"alpha scissor texture and UV material data are captured")
	var alpha_payloads: Array = alpha_snapshot.get("alpha_textures", [])
	_require(alpha_payloads.size() == 1 and alpha_payloads[0].get("alpha", PackedByteArray())[0] == 63,
			"CPU alpha image snapshot preserves the source base-level alpha bytes")
	var mip_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	mip_image.fill(Color(1.0, 1.0, 1.0, 1.0))
	mip_image.generate_mipmaps()
	var mip_material := StandardMaterial3D.new()
	mip_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	mip_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mip_material.albedo_texture = ImageTexture.create_from_image(mip_image)
	var mip_instance := MeshInstance3D.new()
	mip_instance.name = "MipFilteredAlphaHash"
	mip_instance.mesh = alpha_mesh
	mip_instance.material_override = mip_material
	scene_root.add_child(mip_instance)
	await process_frame
	var mip_snapshot: Dictionary = registry.get_snapshot()
	var mip_falls_back := false
	for unsupported in mip_snapshot.get("unsupported_shadow_geometry", []):
		if int(unsupported.get("instance_id", 0)) == mip_instance.get_instance_id() \
				and "mip_filtered_alpha_texture_requires_derivative_lod" in unsupported.get("reasons", []):
			mip_falls_back = true
	_require(mip_falls_back, "mip-filtered alpha texture requires full raster fallback")
	registry.detach()

	var deformation_root := Node3D.new()
	deformation_root.name = "DynamicGeometryFixtures"
	viewport.add_child(deformation_root)
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	skeleton.add_bone("root")
	skeleton.set_bone_pose_position(0, Vector3(0.0, 2.0, 0.0))
	deformation_root.add_child(skeleton)
	var skinned_mesh := ArrayMesh.new()
	skinned_mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	skinned_mesh.add_blend_shape("offset")
	var skinned_arrays: Array = []
	skinned_arrays.resize(Mesh.ARRAY_MAX)
	var source_vertices := PackedVector3Array([
		Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0),
	])
	skinned_arrays[Mesh.ARRAY_VERTEX] = source_vertices
	skinned_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var skin_bones := PackedInt32Array()
	var skin_weights := PackedFloat32Array()
	for _vertex in source_vertices.size():
		skin_bones.append_array(PackedInt32Array([0, 0, 0, 0]))
		skin_weights.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]))
	skinned_arrays[Mesh.ARRAY_BONES] = skin_bones
	skinned_arrays[Mesh.ARRAY_WEIGHTS] = skin_weights
	var shape_arrays: Array = []
	shape_arrays.resize(Mesh.ARRAY_MAX)
	shape_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0),
	])
	skinned_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, skinned_arrays, [shape_arrays])
	var skinned_instance := MeshInstance3D.new()
	skinned_instance.name = "SkinnedBlendshape"
	skinned_instance.mesh = skinned_mesh
	skinned_instance.skeleton = NodePath("../Skeleton")
	deformation_root.add_child(skinned_instance)
	skinned_instance.set_blend_shape_value(0, 0.5)
	var morph_mesh := ArrayMesh.new()
	morph_mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	morph_mesh.add_blend_shape("offset")
	var morph_arrays: Array = []
	morph_arrays.resize(Mesh.ARRAY_MAX)
	morph_arrays[Mesh.ARRAY_VERTEX] = source_vertices
	morph_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var morph_shape: Array = []
	morph_shape.resize(Mesh.ARRAY_MAX)
	morph_shape[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0),
	])
	morph_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, morph_arrays, [morph_shape])
	var morph_instance := MeshInstance3D.new()
	morph_instance.name = "BlendshapeOnly"
	morph_instance.mesh = morph_mesh
	deformation_root.add_child(morph_instance)
	morph_instance.set_blend_shape_value(0, 0.5)
	var unresolved_skin_instance := MeshInstance3D.new()
	unresolved_skin_instance.name = "MissingSkeletonFallback"
	unresolved_skin_instance.mesh = skinned_mesh
	unresolved_skin_instance.skeleton = NodePath("../MissingSkeleton")
	deformation_root.add_child(unresolved_skin_instance)
	await process_frame
	var skin_reference: SkinReference = skinned_instance.get_skin_reference()
	var skin_rid := skin_reference.get_skeleton() if skin_reference != null else RID()
	var skin_ready := skin_rid.is_valid() and RenderingServer.skeleton_get_bone_count(skin_rid) > 0
	if not skin_ready:
		# Headless dummy rendering servers do not allocate skeleton RIDs.
		skinned_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dynamic_registry = RegistryScript.new()
	_require(dynamic_registry.attach(deformation_root, world), "dynamic registry attaches to the deformation fixture")
	var opt_in_snapshot: Dictionary = dynamic_registry.get_snapshot()
	_require(not opt_in_snapshot.get("unsupported_shadow_geometry", []).is_empty(),
			"animated geometry requires the explicit CPU deformation opt-in")
	dynamic_registry.set_cpu_deformation_enabled(true)
	var deformed_snapshot: Dictionary = dynamic_registry.get_snapshot()
	var missing_skeleton_reported := false
	var blendshape_marked_unsupported := false
	for unsupported in deformed_snapshot.get("unsupported_shadow_geometry", []):
		if int(unsupported.get("instance_id", 0)) == unresolved_skin_instance.get_instance_id() \
				and "weighted_mesh_has_no_resolved_skeleton3d" in unsupported.get("reasons", []):
			missing_skeleton_reported = true
		if int(unsupported.get("instance_id", 0)) == morph_instance.get_instance_id():
			blendshape_marked_unsupported = true
	_require(missing_skeleton_reported,
			"weighted mesh without a resolved Skeleton3D requests complete raster fallback")
	_require(not blendshape_marked_unsupported,
			"blendshape-only bake remains supported alongside unsupported weighted geometry")
	var deformed_geometry := _geometry_for_instance(deformed_snapshot, morph_instance.get_instance_id())
	var deformed_surfaces: Array = deformed_geometry.get("surfaces", [])
	_require(int(deformed_geometry.get("mesh_revision", 0)) > 0,
			"dynamic baked geometry exports the revision associated with its payload")
	var deformed_vertices := PackedVector3Array()
	if not deformed_surfaces.is_empty():
		deformed_vertices = deformed_surfaces[0].get("vertices", PackedVector3Array())
	_require(deformed_vertices.size() == 3, "blendshape bake keeps source triangle topology")
	if deformed_vertices.size() == 3:
		_require(deformed_vertices[0].is_equal_approx(Vector3(-0.5, 0.0, 0.0)),
				"relative blend shape produces the expected CPU vertex")
	if skin_ready:
		var skinned_snapshot := _geometry_for_instance(deformed_snapshot, skinned_instance.get_instance_id())
		var skinned_surfaces: Array = skinned_snapshot.get("surfaces", [])
		var skinned_vertices := PackedVector3Array()
		if not skinned_surfaces.is_empty():
			skinned_vertices = skinned_surfaces[0].get("vertices", PackedVector3Array())
		_require(skinned_vertices.size() == 3, "combined skin and morph geometry keeps source triangle topology")
		if skinned_vertices.size() == 3:
			_require(skinned_vertices[0].is_equal_approx(Vector3(-0.5, 2.0, 0.0)),
					"combined skin and relative blend shape produce the expected CPU vertex")
		skeleton.set_bone_pose_position(0, Vector3(0.0, 3.0, 0.0))
		await process_frame
		var moved_snapshot: Dictionary = dynamic_registry.get_snapshot()
		var moved_geometry := _geometry_for_instance(moved_snapshot, skinned_instance.get_instance_id())
		_require(int(moved_geometry.get("mesh_revision", 0))
				> int(skinned_snapshot.get("mesh_revision", 0)),
				"a refreshed skeleton pose exports its incremented dynamic mesh revision")
		var moved_surfaces: Array = moved_geometry.get("surfaces", [])
		var moved_vertices := PackedVector3Array()
		if not moved_surfaces.is_empty():
			moved_vertices = moved_surfaces[0].get("vertices", PackedVector3Array())
		if moved_vertices.size() == 3:
			_require(moved_vertices[0].is_equal_approx(Vector3(-0.5, 3.0, 0.0)),
					"skeleton updates invalidate only the cached dynamic mesh pose")
		else:
			_require(false, "updated skeleton pose returns the cached triangle mesh")
	else:
		print("SKIP skinned pose fixture: headless rendering server exposes no skeleton RID")
	var dynamic_capabilities: Dictionary = dynamic_registry.get_capability_report()
	_require(bool(dynamic_capabilities.get("cpu_deformation_may_stall_renderer")),
			"CPU deformation reports its RenderingServer readback cost")
	dynamic_registry.detach()
	viewport.queue_free()
	await process_frame
	if _failures == 0:
		print("PASS ray-tracing geometry registry (%d checks)" % _checks)
	else:
		push_error("ray-tracing geometry registry failed: %d/%d" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _test_tlas_release_state() -> void:
	var provider := ShadowProviderScript.new()
	provider.set("_tlas_capacity", 8)
	provider.set("_active_snapshot_revision", 41)
	provider.call("_release_tlas", null)
	_require(not provider.get("_tlas").is_valid(),
			"releasing TLAS clears its RID so later scene sync cannot free it twice")
	_require(int(provider.get("_tlas_capacity")) == 0,
			"releasing TLAS resets its allocation capacity")
	_require(int(provider.get("_active_snapshot_revision")) == -1,
			"releasing TLAS invalidates the snapshot revision")
	provider.call("_release_tlas", null)
	_require(not provider.get("_tlas").is_valid(),
			"repeated empty TLAS release remains safe")
	var sentinel_texture := ImageTexture.create_from_image(
		Image.create(1, 1, false, Image.FORMAT_RGBA8))
	var sentinel_rid := sentinel_texture.get_rid()
	provider.set("_ray_shader", sentinel_rid)
	provider.set("_pipeline", sentinel_rid)
	provider.set("_hit_sbt", sentinel_rid)
	provider.set("_hit_sbt_range", 7)
	provider.set("_tlas", sentinel_rid)
	provider.set("_tlas_capacity", 8)
	provider.set("_output_buffer", sentinel_rid)
	provider.set("_reported_unsupported", true)
	provider.set("_blas_cache", {123: {"blas": sentinel_rid}})
	provider.call("release")
	_require(not provider.get("_ray_shader").is_valid()
			and not provider.get("_pipeline").is_valid()
			and not provider.get("_hit_sbt").is_valid()
			and int(provider.get("_hit_sbt_range")) == 0
			and not provider.get("_tlas").is_valid()
			and int(provider.get("_tlas_capacity")) == 0
			and not provider.get("_output_buffer").is_valid()
			and not bool(provider.get("_reported_unsupported"))
			and provider.get("_blas_cache").is_empty(),
		"release clears every GPU handle and cache even after the RenderingDevice reference is lost")
	provider.call("release")
	_require(not provider.get("_pipeline").is_valid()
			and not provider.get("_tlas").is_valid(),
		"provider release is idempotent and cannot reuse stale pipeline or TLAS handles")


func _geometry_for_instance(p_snapshot: Dictionary, p_instance_id: int) -> Dictionary:
	var mesh_id := 0
	for instance in p_snapshot.get("instances", []):
		if int(instance.get("instance_id", 0)) == p_instance_id:
			mesh_id = int(instance.get("mesh_id", 0))
			break
	return _geometry_for_mesh(p_snapshot, mesh_id)


func _geometry_for_mesh(p_snapshot: Dictionary, p_mesh_id: int) -> Dictionary:
	for geometry in p_snapshot.get("geometries", []):
		if int(geometry.get("mesh_id", 0)) == p_mesh_id:
			return geometry
	return {}


func _ordered_instance_ids(p_snapshot: Dictionary) -> Array[int]:
	var ids: Array[int] = []
	for instance in p_snapshot.get("instances", []):
		ids.append(int(instance.get("instance_id", 0)))
	return ids


func _count_source_instances(p_snapshot: Dictionary, p_source_node_id: int) -> int:
	var count := 0
	for instance in p_snapshot.get("instances", []):
		if int(instance.get("source_node_id", 0)) == p_source_node_id:
			count += 1
	return count
