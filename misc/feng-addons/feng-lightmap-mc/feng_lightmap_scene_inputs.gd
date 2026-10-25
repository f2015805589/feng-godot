@tool
extends RefCounted
## Main-thread scene adapter: validates and packs immutable CPU lightmap inputs.

static func signature(collection: Dictionary, volume: Node3D) -> String:
	var snapshot: Array = []
	for key in ["vertices", "normals", "uv2", "albedo", "emission", "material_flags", "mesh_ids", "roughness", "metallic", "specular", "diffuse_modes"]:
		snapshot.append(collection.get(key))
	for key in ["directional_lights", "area_lights"]:
		var sources: Array[Dictionary] = []
		for light: Dictionary in collection.get(key, []):
			var source := light.duplicate()
			# Absolute tree paths differ between editor and game instances; the
			# actual transport fields must determine persistent bake validity.
			source.erase("source_path")
			sources.append(source)
		snapshot.append(sources)
	for receiver: Node in collection.get("mesh_nodes", []):
		snapshot.append(volume.get_path_to(receiver))
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(snapshot))
	return hash.finish().hex_encode()


static func color_is_nonnegative_finite(color: Color) -> bool:
	return is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and color.r >= 0.0 and color.g >= 0.0 and color.b >= 0.0


static func _read_directional_light(light: DirectionalLight3D) -> Dictionary:
	var source := String(light.get_path())
	if light.light_negative:
		return {"ok": false, "error": "%s is a negative light; nonnegative physical transport is required." % source}
	if not is_finite(light.light_angular_distance) or light.light_angular_distance < 0.0 or light.light_angular_distance >= 180.0:
		return {"ok": false, "error": "%s requires a finite angular diameter in [0,180) degrees." % source}
	if (light.light_cull_mask & 0xFFFFF) != 0xFFFFF:
		return {"ok": false, "error": "%s has a restricted light_cull_mask; per-object light linking is not represented by this surface estimator." % source}
	if not is_finite(light.light_energy) or light.light_energy < 0.0 or not is_finite(light.light_indirect_energy) or light.light_indirect_energy < 0.0:
		return {"ok": false, "error": "%s has non-finite or negative light energy." % source}
	var radiance := light.light_color.srgb_to_linear()
	var energy := light.light_energy
	if bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
		energy *= light.light_intensity_lux
		radiance *= light.get_correlated_color().srgb_to_linear()
	else:
		# The nonphysical realtime Lambert path omits 1/pi; express the same
		# source in this integrator's radiometric convention.
		energy *= PI
	radiance *= energy
	var direction := light.global_basis.z.normalized()
	if not color_is_nonnegative_finite(radiance) or not direction.is_finite() or direction.length_squared() < 0.99:
		return {"ok": false, "error": "%s has an invalid direction or linear radiance." % source}
	return {"ok": true, "input": {"direction_to_light": direction, "radiance": radiance,
		"direct_enabled": light.light_bake_mode == Light3D.BAKE_STATIC,
		"indirect_energy": light.light_indirect_energy, "angular_distance": light.light_angular_distance,
		"source_path": source}}


static func _read_area_light(light: AreaLight3D) -> Dictionary:
	var source := String(light.get_path())
	if light.area_texture != null:
		return {"ok": false, "error": "%s uses an area-light texture; only constant rectangular emission is represented." % source}
	if light.light_negative or (light.light_cull_mask & 0xFFFFF) != 0xFFFFF:
		return {"ok": false, "error": "%s uses negative illumination or restricted light linking, unsupported by physical surface transport." % source}
	var shape := light.area_size
	if not shape.is_finite() or shape.x <= 0.0 or shape.y <= 0.0 or not is_finite(light.area_range) or light.area_range <= 0.0:
		return {"ok": false, "error": "%s requires finite positive rectangular size and range." % source}
	if not is_finite(light.light_energy) or light.light_energy < 0.0 or not is_finite(light.light_indirect_energy) or light.light_indirect_energy < 0.0 or not is_finite(light.area_attenuation):
		return {"ok": false, "error": "%s has invalid energy or attenuation." % source}
	var energy := light.light_energy
	var radiance := light.light_color.srgb_to_linear()
	var attenuation := light.area_attenuation
	if bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
		energy *= light.light_intensity_lumens / PI
		radiance *= light.get_correlated_color().srgb_to_linear()
		attenuation = 2.0
	else:
		energy *= PI
	if light.area_normalize_energy:
		energy /= shape.x * shape.y
	radiance *= energy
	# Match the renderer's authored rectangle size: node scale does not alter
	# AreaLight3D's explicit area_size; basis axes define its orientation only.
	var axis_u := light.global_basis.x.normalized() * shape.x
	var axis_v := light.global_basis.y.normalized() * shape.y
	var normal := -light.global_basis.z.normalized()
	if not light.global_position.is_finite() or axis_u.length_squared() <= 0.0 or axis_v.length_squared() <= 0.0 or normal.length_squared() < 0.99 or not color_is_nonnegative_finite(radiance) or not axis_u.is_finite() or not axis_v.is_finite() or not normal.is_finite() or absf(axis_u.normalized().dot(axis_v.normalized())) > 0.0001 or absf(normal.dot(axis_u.normalized())) > 0.0001 or absf(normal.dot(axis_v.normalized())) > 0.0001:
		return {"ok": false, "error": "%s has invalid rectangular axes/radiance; shear is unsupported." % source}
	return {"ok": true, "input": {"center": light.global_position, "axis_u": axis_u, "axis_v": axis_v,
		"normal": normal, "radiance": radiance, "range": light.area_range, "attenuation": attenuation,
		"direct_enabled": light.light_bake_mode == Light3D.BAKE_STATIC,
		"indirect_energy": light.light_indirect_energy, "source_path": source}}


static func collect(volume: Node3D, bounds: AABB, receiver_root: Node, scene_root: Node) -> Dictionary:
	var vertices := PackedVector3Array()
	var uv2 := PackedVector2Array()
	var albedo := PackedColorArray()
	var emission := PackedColorArray()
	var material_flags := PackedByteArray()
	var normals := PackedVector3Array()
	var roughness := PackedFloat32Array()
	var metallic := PackedFloat32Array()
	var specular := PackedFloat32Array()
	var diffuse_modes := PackedByteArray()
	var directional_lights: Array[Dictionary] = []
	var area_lights: Array[Dictionary] = []
	var triangle_sources: Array[Dictionary] = []
	var mesh_ids := PackedInt32Array()
	var mesh_nodes: Array[Node] = []
	var excluded_lights := PackedStringArray()
	var transport_only_reasons := PackedStringArray()
	var transport_only_mesh_count := 0
	var receiver_triangle_count := 0
	var transport_only_triangle_count := 0
	var skipped_zero_area_triangle_count := 0
	var errors := PackedStringArray()
	var scene_to_volume := volume.global_transform.affine_inverse()
	var stack: Array[Node] = [scene_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is Light3D:
			var light := node as Light3D
			if light.editor_only or not light.is_visible_in_tree() or light.light_bake_mode == Light3D.BAKE_DISABLED:
				excluded_lights.append("%s (editor-only, hidden, or BAKE_DISABLED; excluded from GI baking)" % light.get_path())
			elif light is DirectionalLight3D and (light as DirectionalLight3D).sky_mode == DirectionalLight3D.SKY_MODE_SKY_ONLY:
				excluded_lights.append("%s (SKY_MODE_SKY_ONLY; only present through the captured environment)" % light.get_path())
			elif light is DirectionalLight3D:
				var result := _read_directional_light(light as DirectionalLight3D)
				if result.ok:
					directional_lights.append(result.input)
				else:
					errors.append(result.error)
			elif light is AreaLight3D:
				var result := _read_area_light(light as AreaLight3D)
				if result.ok:
					area_lights.append(result.input)
				else:
					errors.append(result.error)
			else:
				errors.append("Analytic light %s (%s) is unsupported; use directional/rectangular area lights or emissive triangle surfaces. No light was silently discarded." % [light.get_path(), light.get_class()])
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			if not mesh_instance.is_visible_in_tree():
				errors.append("%s is not visible in the current scene tree; visibility-dependent geometry is unsupported." % mesh_instance.get_path())
				continue
			if mesh_instance.gi_mode != GeometryInstance3D.GI_MODE_STATIC:
				errors.append("%s is not marked GI_MODE_STATIC; mutable geometry cannot be used as a fixed transport scene." % mesh_instance.get_path())
				continue
			if mesh_instance.skin != null or mesh_instance.get_skin_reference() != null:
				errors.append("%s is skinned; deformed geometry is unsupported." % mesh_instance.get_path())
				continue
			var has_active_blend_shape := false
			for blend_shape_index in mesh_instance.get_blend_shape_count():
				if not is_zero_approx(mesh_instance.get_blend_shape_value(blend_shape_index)):
					has_active_blend_shape = true
					break
			if has_active_blend_shape:
				errors.append("%s has an active blend shape; deformed geometry is unsupported." % mesh_instance.get_path())
				continue
			if mesh_instance.mesh == null:
				errors.append("%s has no Mesh resource." % mesh_instance.get_path())
				continue
			if mesh_instance.mesh.get_surface_count() == 0:
				errors.append("%s has no mesh surfaces." % mesh_instance.get_path())
				continue

			var selected_for_receiving := mesh_instance == receiver_root or receiver_root.is_ancestor_of(mesh_instance)
			var inside_receiver_bounds := _mesh_aabb_inside_volume(mesh_instance, scene_to_volume, bounds)
			var is_receiver := selected_for_receiving and inside_receiver_bounds
			var mesh_id := -1
			if is_receiver:
				mesh_id = mesh_nodes.size()
				mesh_nodes.append(mesh_instance)
			else:
				transport_only_mesh_count += 1
				var reason := "outside source_root_path receiver subtree" if not selected_for_receiving else "whole MeshInstance3D AABB is not inside the volume-local bounds"
				transport_only_reasons.append("%s: %s; full geometry retained for transport." % [mesh_instance.get_path(), reason])

			var transform := mesh_instance.global_transform
			var flips_winding := transform.basis.determinant() < 0.0
			for surface_index in mesh_instance.mesh.get_surface_count():
				var surface_is_triangle_list := false
				if mesh_instance.mesh is ArrayMesh:
					surface_is_triangle_list = (mesh_instance.mesh as ArrayMesh).surface_get_primitive_type(surface_index) == Mesh.PRIMITIVE_TRIANGLES
				elif mesh_instance.mesh is PrimitiveMesh:
					# Godot's built-in PrimitiveMesh surfaces are expanded as triangle lists.
					surface_is_triangle_list = true
				else:
					errors.append("%s uses mesh class %s whose surface primitive type is not exposed to this extractor." % [mesh_instance.get_path(), mesh_instance.mesh.get_class()])
					continue
				if not surface_is_triangle_list:
					errors.append("%s surface %d is not a triangle list." % [mesh_instance.get_path(), surface_index])
					continue
				var arrays: Array = mesh_instance.mesh.surface_get_arrays(surface_index)
				var positions := PackedVector3Array()
				var surface_uv2 := PackedVector2Array()
				if arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
					positions = arrays[Mesh.ARRAY_VERTEX]
				if is_receiver and arrays[Mesh.ARRAY_TEX_UV2] is PackedVector2Array:
					surface_uv2 = arrays[Mesh.ARRAY_TEX_UV2]
				if positions.is_empty():
					errors.append("%s surface %d has no vertex positions." % [mesh_instance.get_path(), surface_index])
					continue
				if is_receiver and surface_uv2.size() != positions.size():
					errors.append("%s surface %d must have one UV2 per vertex because it receives a lightmap." % [mesh_instance.get_path(), surface_index])
					continue
				var indices := PackedInt32Array()
				if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
					indices = arrays[Mesh.ARRAY_INDEX]
				var triangle_index_count := indices.size() if not indices.is_empty() else positions.size()
				if triangle_index_count % 3 != 0:
					errors.append("%s surface %d has an incomplete triangle." % [mesh_instance.get_path(), surface_index])
					continue
				var has_invalid_indices := false
				for vertex_index in indices:
					if vertex_index < 0 or vertex_index >= positions.size():
						has_invalid_indices = true
						break
				if has_invalid_indices:
					errors.append("%s surface %d contains an invalid vertex index." % [mesh_instance.get_path(), surface_index])
					continue
				var material := mesh_instance.get_active_material(surface_index)
				var material_result := _read_material(material, mesh_instance, surface_index)
				if not material_result.ok:
					errors.append(material_result.error)
					continue
				var diffuse: Color = material_result.albedo
				var radiance: Color = material_result.emission
				var flags: int = material_result.flags
				var vertex_normals := PackedVector3Array()
				if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
					vertex_normals = arrays[Mesh.ARRAY_NORMAL]
				if not vertex_normals.is_empty() and vertex_normals.size() != positions.size():
					errors.append("%s surface %d has an incomplete vertex-normal array." % [mesh_instance.get_path(), surface_index])
					continue
				var normal_transform := transform.basis.inverse().transposed()
				var first_source_triangle := mesh_ids.size()
				for index_offset in range(0, triangle_index_count, 3):
					var i0 := indices[index_offset] if not indices.is_empty() else index_offset
					var i1 := indices[index_offset + 1] if not indices.is_empty() else index_offset + 1
					var i2 := indices[index_offset + 2] if not indices.is_empty() else index_offset + 2
					# Godot front faces are clockwise. The CPU integrator uses the
					# mathematical cross(b-a,c-a) convention, so reverse once;
					# a negative determinant already reverses the world winding.
					var local_indices := [i0, i2, i1] if not flips_winding else [i0, i1, i2]
					var triangle_positions: Array[Vector3] = []
					var triangle_uv2: Array[Vector2] = []
					for local_index in local_indices:
						var world_position: Vector3 = transform * positions[local_index]
						triangle_positions.append(world_position)
						triangle_uv2.append(surface_uv2[local_index] if is_receiver else Vector2.ZERO)
					var area_vector := (triangle_positions[1] - triangle_positions[0]).cross(triangle_positions[2] - triangle_positions[0])
					if area_vector.length_squared() == 0.0:
						# Zero-area faces have exactly zero measure in the surface integral.
						skipped_zero_area_triangle_count += 1
						continue
					for vertex in 3:
						vertices.append(triangle_positions[vertex])
						uv2.append(triangle_uv2[vertex])
						var shading_normal := (normal_transform * vertex_normals[local_indices[vertex]]).normalized() if not vertex_normals.is_empty() else area_vector.normalized()
						normals.append(shading_normal)
					albedo.append(diffuse)
					emission.append(radiance)
					material_flags.append(flags)
					roughness.append(material_result.roughness)
					metallic.append(material_result.metallic)
					specular.append(material_result.specular)
					diffuse_modes.append(material_result.diffuse_mode)
					mesh_ids.append(mesh_id)
					if is_receiver:
						receiver_triangle_count += 1
					else:
						transport_only_triangle_count += 1
				if mesh_ids.size() > first_source_triangle:
					triangle_sources.append({"first_triangle":first_source_triangle,"end_triangle":mesh_ids.size(),
						"path":str(mesh_instance.get_path()),"surface":surface_index})
		elif node is GeometryInstance3D:
			errors.append("Unsupported geometry node %s (%s)." % [node.get_path(), node.get_class()])

	if mesh_nodes.is_empty():
		errors.append("No fully-contained receiver MeshInstance3D was found under source_root_path and inside the volume-local bounds.")
	if receiver_triangle_count == 0:
		errors.append("No non-zero-area receiver triangles were found; transport-only meshes do not receive atlas layers.")
	if not errors.is_empty():
		return {"ok": false, "error": "\n".join(errors)}
	return {
		"ok": true,
		"vertices": vertices,
		"normals": normals,
		"roughness": roughness,
		"metallic": metallic,
		"specular": specular,
		"diffuse_modes": diffuse_modes,
		"directional_lights": directional_lights,
		"area_lights": area_lights,
		"triangle_sources": triangle_sources,
		"uv2": uv2,
		"albedo": albedo,
		"emission": emission,
		"material_flags": material_flags,
		"mesh_ids": mesh_ids,
		"mesh_nodes": mesh_nodes,
		"excluded_lights": excluded_lights,
		"transport_only_reasons": transport_only_reasons,
		"transport_only_mesh_count": transport_only_mesh_count,
		"receiver_triangle_count": receiver_triangle_count,
		"transport_only_triangle_count": transport_only_triangle_count,
		"skipped_zero_area_triangle_count": skipped_zero_area_triangle_count,
	}


static func _mesh_aabb_inside_volume(mesh_instance: MeshInstance3D, scene_to_volume: Transform3D, bounds: AABB) -> bool:
	var mesh_bounds := mesh_instance.get_aabb()
	if mesh_bounds.size.x < 0.0 or mesh_bounds.size.y < 0.0 or mesh_bounds.size.z < 0.0:
		return false
	var padded_volume_bounds := bounds.grow(0.00001)
	var mesh_to_volume: Transform3D = scene_to_volume * mesh_instance.global_transform
	for corner in 8:
		if not padded_volume_bounds.has_point(mesh_to_volume * mesh_bounds.get_endpoint(corner)):
			return false
	return true


static func _read_material(material: Material, mesh_instance: MeshInstance3D, surface_index: int) -> Dictionary:
	var source_name := "%s surface %d" % [mesh_instance.get_path(), surface_index]
	if material == null:
		return {"ok": false, "error": "%s has no material; implicit/default materials are rejected." % source_name}
	if not material is StandardMaterial3D:
		return {"ok": false, "error": "%s uses unsupported material type %s; only constant StandardMaterial3D is supported." % [source_name, material.get_class()]}
	var standard := material as StandardMaterial3D
	if standard.next_pass != null or mesh_instance.material_overlay != null:
		return {"ok": false, "error": "%s uses material overlay/next_pass; layered drawing is not represented by one surface BSDF." % source_name}
	if standard.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return {"ok": false, "error": "%s is transparent; transparent transport is unsupported." % source_name}
	if standard.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
		return {"ok": false, "error": "%s is unshaded; unshaded surface transport is unsupported." % source_name}
	if standard.get_flag(BaseMaterial3D.FLAG_ALBEDO_FROM_VERTEX_COLOR):
		return {"ok": false, "error": "%s uses vertex colors as albedo; vertex-color materials are unsupported." % source_name}
	if standard.get_flag(BaseMaterial3D.FLAG_DISABLE_AMBIENT_LIGHT):
		return {"ok": false, "error": "%s disables ambient light and cannot consume a LightmapGI result." % source_name}
	if standard.diffuse_mode not in [BaseMaterial3D.DIFFUSE_LAMBERT, BaseMaterial3D.DIFFUSE_BURLEY]:
		return {"ok": false, "error": "%s uses diffuse mode %s; this estimator supports DIFFUSE_LAMBERT and DIFFUSE_BURLEY." % [source_name, _diffuse_mode_name(standard.diffuse_mode)]}
	if standard.specular_mode not in [BaseMaterial3D.SPECULAR_DISABLED, BaseMaterial3D.SPECULAR_SCHLICK_GGX]:
		return {"ok": false, "error": "%s uses an unsupported specular mode; only disabled and Schlick GGX are represented." % source_name}
	if standard.emission_enabled and standard.emission_operator != BaseMaterial3D.EMISSION_OP_ADD:
		return {"ok": false, "error": "%s uses a multiplicative emission operator." % source_name}
	var texture_properties := PackedStringArray([
		"albedo_texture", "orm_texture", "metallic_texture", "roughness_texture",
		"normal_texture", "bent_normal_texture", "ao_texture", "emission_texture",
		"rim_texture", "clearcoat_texture", "anisotropy_flowmap", "heightmap_texture",
		"subsurf_scatter_texture", "subsurf_scatter_transmittance_texture", "backlight_texture",
		"refraction_texture", "detail_mask", "detail_albedo", "detail_normal",
	])
	for property_name in texture_properties:
		if standard.get(property_name) != null:
			return {"ok": false, "error": "%s uses texture %s; textured materials are unsupported." % [source_name, property_name]}
	if standard.clearcoat_enabled or standard.anisotropy_enabled or standard.refraction_enabled or standard.rim_enabled or standard.subsurf_scatter_enabled or standard.subsurf_scatter_transmittance_enabled or standard.backlight_enabled or standard.bent_normal_enabled or standard.ao_enabled:
		return {"ok": false, "error": "%s enables a non-diffuse lobe; this volume only estimates diffuse lightmaps." % source_name}
	if standard.cull_mode == BaseMaterial3D.CULL_FRONT:
		return {"ok": false, "error": "%s uses front-face culling; only back-face-culling and two-sided materials are supported." % source_name}
	# BaseMaterial3D color properties use the source-color convention. Godot's
	# voxel bake decodes these same values before using them as linear transport.
	var diffuse := standard.albedo_color.srgb_to_linear()

	if diffuse.a < 0.99999 or diffuse.r < 0.0 or diffuse.g < 0.0 or diffuse.b < 0.0 or diffuse.r > 1.0 or diffuse.g > 1.0 or diffuse.b > 1.0:
		return {"ok": false, "error": "%s has diffuse reflectance outside [0,1]." % source_name}
	var emitted := Color.BLACK
	if standard.emission_enabled:
		var emission_scale := standard.emission_energy_multiplier
		if ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false):
			emission_scale *= standard.emission_intensity
		emitted = standard.emission.srgb_to_linear() * emission_scale
	if emitted.r < 0.0 or emitted.g < 0.0 or emitted.b < 0.0:
		return {"ok": false, "error": "%s has negative emission." % source_name}
	var flags := 0
	if standard.cull_mode == BaseMaterial3D.CULL_DISABLED:
		flags |= 1
		if standard.emission_enabled:
			flags |= 2
	var material_specular := standard.metallic_specular if standard.specular_mode != BaseMaterial3D.SPECULAR_DISABLED else 0.0
	if standard.metallic < 0.0 or standard.metallic > 1.0 or standard.roughness < 0.0 or standard.roughness > 1.0 or material_specular < 0.0 or material_specular > 1.0:
		return {"ok": false, "error": "%s has invalid roughness, metallic, or specular values." % source_name}
	if standard.roughness == 0.0 and (material_specular > 0.0 or standard.metallic > 0.0):
		return {"ok": false, "error": "%s has a zero-roughness delta specular lobe; the current GGX integrator requires positive roughness." % source_name}
	if standard.specular_mode == BaseMaterial3D.SPECULAR_DISABLED and standard.metallic > 0.0:
		return {"ok": false, "error": "%s combines metallic > 0 with SPECULAR_DISABLED; this nonphysical material model is unsupported." % source_name}
	return {"ok": true, "albedo": diffuse, "emission": emitted, "flags": flags,
		"roughness": standard.roughness, "metallic": standard.metallic, "specular": material_specular,
		"diffuse_mode": 1 if standard.diffuse_mode == BaseMaterial3D.DIFFUSE_BURLEY else 0}


static func _diffuse_mode_name(mode: int) -> String:
	match mode:
		BaseMaterial3D.DIFFUSE_BURLEY:
			return "DIFFUSE_BURLEY"
		BaseMaterial3D.DIFFUSE_LAMBERT:
			return "DIFFUSE_LAMBERT"
		BaseMaterial3D.DIFFUSE_LAMBERT_WRAP:
			return "DIFFUSE_LAMBERT_WRAP"
		BaseMaterial3D.DIFFUSE_TOON:
			return "DIFFUSE_TOON"
		_:
			return "unknown (%d)" % mode
