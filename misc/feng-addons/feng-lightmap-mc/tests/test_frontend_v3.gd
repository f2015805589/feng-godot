extends SceneTree

const SceneInputs = preload("res://addons/feng-lightmap-mc/feng_lightmap_scene_inputs.gd")
## CPU-only collection checks. No GPU bake, project scene edits or output atlas.

const Volume = preload("res://addons/feng-lightmap-mc/feng_lightmap_volume.gd")
class DerivedData extends "res://addons/feng-lightmap-mc/feng_lightmap_data.gd":
	var display_builds := 0
	func build_lightmap_gi_data(_volume: Node3D, _display: LightmapGI) -> LightmapGIData:
		display_builds += 1
		return LightmapGIData.new()

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failures += 1
	else:
		checks += 1

func _run() -> void:
	var scene := Node3D.new()
	scene.name = "FrontendContract"
	root.add_child(scene)
	current_scene = scene
	var volume := Volume.new()
	volume.name = "FengLightmapVolume"
	volume.bounds = AABB(Vector3(-2,-2,-2), Vector3(4,4,4))
	scene.add_child(volume)
	_check(not volume.enabled and volume.REQUIRED_BACKEND_CONTRACT_VERSION == 4, "Independent v4 volume defaults disabled")
	_check(volume.bake_button.is_valid() and volume.cancel_button.is_valid() and volume.validate_button.is_valid(), "Inspector has real bake, cancel and stale-input check actions")
	var receiver := MeshInstance3D.new()
	receiver.name = "SmoothSphere"
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 12
	sphere.rings = 6
	sphere.add_uv2 = true
	receiver.mesh = sphere
	receiver.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	receiver.scale = Vector3(1.5,1.0,0.7)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.3,0.5,0.6)
	material.metallic = 0.04
	material.roughness = 0.32
	material.emission_enabled = true
	material.emission = Color(0.0,1.0,0.0)
	receiver.material_override = material
	scene.add_child(receiver)
	var sun := DirectionalLight3D.new()
	sun.name = "Directional"
	sun.light_bake_mode = Light3D.BAKE_DYNAMIC
	scene.add_child(sun)
	var surface_material := StandardMaterial3D.new()
	surface_material.albedo_color = Color.RED
	receiver.set_surface_override_material(0, surface_material)
	_check(SceneInputs.collect(volume, volume.bounds, scene, scene).albedo[0].is_equal_approx(material.albedo_color.srgb_to_linear()), "Instance override wins over surface override")
	receiver.material_override = null
	_check(SceneInputs.collect(volume, volume.bounds, scene, scene).albedo[0].is_equal_approx(Color.RED), "Surface override is used when instance override is absent")
	receiver.material_override = material
	receiver.set_surface_override_material(0, null)
	var data := SceneInputs.collect(volume, volume.bounds, scene,scene)
	_check(data.get("ok",false), "Smooth Burley/GGX sphere + dynamic directional collection must succeed: %s" % data.get("error",""))
	_check(data.normals.size() == data.vertices.size(), "Normals preserve per-corner data")
	_check(data.roughness.size() == data.albedo.size() and data.metallic.size() == data.albedo.size(), "PBR data remain per triangle")
	var error_text := volume._native_failure_message({"error":"UV overlap","mesh_id":0,"triangle_id":0,"other_triangle_id":1,"texel_x":2,"texel_y":3},data)
	_check(error_text.contains("SmoothSphere") and error_text.contains("surface 0") and error_text.contains("Atlas texel"), "Native triangle/mesh diagnostics map to scene node and surface")
	_check(data.diffuse_modes[0] == 1 and is_equal_approx(data.roughness[0], 0.32), "Burley enum and roughness match backend")
	_check(data.albedo[0].is_equal_approx(material.albedo_color.srgb_to_linear()), "Metal fraction is not applied twice to base albedo")
	_check(not data.directional_lights[0].direct_enabled, "Dynamic directional contributes indirect only")
	for normal: Vector3 in data.normals:
		_check(normal.is_finite() and absf(normal.length()-1.0) < 0.00001, "Nonuniform scale normals use inverse transpose")
	for offset in range(0,data.vertices.size(),3):
		var normal: Vector3 = (data.vertices[offset+1]-data.vertices[offset]).cross(data.vertices[offset+2]-data.vertices[offset]).normalized()
		_check(normal.dot(data.normals[offset]) > 0.0, "Shading normals stay in geometric front hemisphere")
	sun.light_bake_mode = Light3D.BAKE_STATIC
	sun.light_indirect_energy = 0.4
	var directional := SceneInputs._read_directional_light(sun)
	_check(directional.ok and directional.input.direct_enabled and is_equal_approx(directional.input.indirect_energy,0.4), "Static direct and indirect multipliers are distinct")
	var snapshot := SceneInputs.collect(volume, volume.bounds, scene,scene)
	var signature := SceneInputs.signature(snapshot, volume)
	var renamed_snapshot := snapshot.duplicate(true)
	renamed_snapshot.directional_lights[0].source_path = "/root/DifferentEditorTree/Directional"
	_check(SceneInputs.signature(renamed_snapshot, volume) == signature, "Persistent transport signature ignores absolute editor tree paths")
	var saved := DerivedData.new()
	saved.set("scene_transport_signature",signature)
	saved.set("receiver_bounds_local",volume.bounds)
	saved.set("physical_light_units_enabled",ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units",false))
	volume.baked_data = saved
	_check(volume.validate_saved_bake_inputs().ok, "Saved source certificate accepts unchanged material/light inputs")
	material.emission_enabled = false
	_check(not volume.validate_saved_bake_inputs().ok, "Changed emission invalidates saved transport instead of claiming the old bake is current")
	material.emission_enabled = true
	saved.set("scene_transport_signature","")
	_check(not volume.validate_saved_bake_inputs().ok, "Legacy data without a source signature is not implicitly current")
	volume.enabled = true
	volume.display_gutter_pixels = 2
	volume._refresh_display()
	_check(saved.display_gutter_pixels == 2 and saved.display_builds == 2, "Derived bake resources receive typed settings and display invalidation")
	var invalid_path := "user://lightmap_wrong_resource_%d.tres" % Time.get_ticks_usec()
	_check(ResourceSaver.save(Resource.new(), invalid_path) == OK, "Wrong external resource fixture saves")
	volume.baked_data = null
	volume.output_resource_path = invalid_path
	volume._refresh_display()
	_check(volume.baked_data == null and volume.get_node(volume.DISPLAY_NODE_NAME).light_data == null, "Wrong external resource leaves no stale display binding")
	volume.enabled = false
	volume.output_resource_path = volume.DEFAULT_OUTPUT
	DirAccess.remove_absolute(ProjectSettings.globalize_path(invalid_path))
	sun.light_angular_distance = 0.1
	var finite_sun := SceneInputs._read_directional_light(sun)
	_check(finite_sun.ok and is_equal_approx(finite_sun.input.angular_distance,0.1), "Finite disk is retained for native solid-angle integration")
	sun.light_angular_distance = 0.0
	sun.light_cull_mask = 1
	_check(not SceneInputs._read_directional_light(sun).ok, "Light linking is rejected instead of omitted")
	sun.light_cull_mask = 0xFFFFF
	sun.light_bake_mode = Light3D.BAKE_DISABLED
	var external := MeshInstance3D.new()
	external.name = "OutsideNoUV2"
	var outside_box := BoxMesh.new()
	external.mesh = outside_box
	external.material_override = material
	external.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	external.position = Vector3(10,0,0)
	scene.add_child(external)
	data = SceneInputs.collect(volume, volume.bounds, scene,scene)
	_check(data.ok and data.transport_only_mesh_count == 1 and data.mesh_nodes.size() == 1, "Outside mesh is complete transport-only geometry without UV2")
	_check(data.excluded_lights.size() == 1 and data.directional_lights.is_empty(), "Disabled directional is explicitly excluded")
	var area := AreaLight3D.new()
	area.name = "RectSource"
	area.area_size = Vector2(2.0,3.0)
	area.light_energy = 4.0
	area.area_range = 6.5
	area.area_attenuation = 1.25
	area.light_indirect_energy = 0.7
	area.light_bake_mode = Light3D.BAKE_DYNAMIC
	scene.add_child(area)
	var rectangle := SceneInputs._read_area_light(area)
	_check(rectangle.ok and not rectangle.input.direct_enabled, "Dynamic analytic area source keeps direct realtime")
	_check(rectangle.input.axis_u.length() == 2.0 and rectangle.input.axis_v.length() == 3.0, "Area rectangle preserves authored full axes")
	_check(is_equal_approx(rectangle.input.indirect_energy,0.7), "Area indirect multiplier stays separate")
	var physical := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units",false))
	_check(rectangle.input.attenuation == (2.0 if physical else 1.25), "Area attenuation follows physical units convention")
	data = SceneInputs.collect(volume, volume.bounds, scene,scene)
	_check(data.ok and data.area_lights.size() == 1, "Analytic area remains independent scene source")
	area.area_texture = GradientTexture2D.new()
	_check(not SceneInputs._read_area_light(area).ok, "Textured area light must not silently become uniform")
	area.area_texture = null
	receiver.scale.x = -1.5
	data = SceneInputs.collect(volume, volume.bounds, scene,scene)
	var mirrored_ok := true
	for offset in range(0,data.vertices.size(),3):
		var normal: Vector3 = (data.vertices[offset+1]-data.vertices[offset]).cross(data.vertices[offset+2]-data.vertices[offset]).normalized()
		mirrored_ok = mirrored_ok and normal.dot(data.normals[offset]) > 0.0
	_check(mirrored_ok, "Mirrored transform preserves geometric/shading front hemisphere")
	_test_gutter()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.4,0.3,0.2)
	scene.add_child(env)
	volume.environment_mode = Volume.EnvironmentMode.REJECT_SCENE_ENVIRONMENT
	_check(not volume._resolve_environment(scene).ok, "Explicit reject mode preserves v2 strict environment contract")
	volume.environment_mode = Volume.EnvironmentMode.UNIFORM_OVERRIDE
	volume.environment_radiance = Color(0.8,0.4,0.2)
	_check(volume._resolve_environment(scene).radiance == volume.environment_radiance, "Uniform override remains explicit linear radiance")
	material.roughness = 0.0
	_check(not SceneInputs._read_material(material,receiver,0).ok, "Unrepresented delta specular is rejected")
	material.roughness = 0.32
	material.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	_check(not SceneInputs._read_material(material,receiver,0).ok, "Unrepresented diffuse model is rejected")
	current_scene = null
	scene.free()
	print("FengLightmap frontend v3: %d checks passed; %d failures" % [checks,failures])
	quit(0 if failures == 0 else 1)


func _test_gutter() -> void:
	var data = load("res://addons/feng-lightmap-mc/feng_lightmap_data.gd").new()
	data.atlas_resolution = 5
	data.display_gutter_pixels = 1
	var raw := PackedFloat32Array()
	raw.resize(5*5*4)
	# Two unrelated chart samples straddle an empty gutter cell.
	var left := (2*5+1)*4
	var right := (2*5+3)*4
	raw[left] = 10.0
	raw[left+3] = 1.0
	raw[right+2] = 20.0
	raw[right+3] = 1.0
	var before := raw.to_byte_array()
	var display: PackedFloat32Array = data._display_rgba(raw)
	_check(raw.to_byte_array() == before, "Display reconstruction preserves every raw estimator bit")
	_check(display[(2*5+2)*4+3] == 0.0, "Different-color equidistant unknown-chart candidates remain empty")
	var single_chart_display: PackedFloat32Array = data._display_rgba(raw,true)
	_check(single_chart_display[(2*5+2)*4+3] == 1.0 and raw.to_byte_array() == before, "Proven same-chart ties fill display holes without touching raw samples")
	var sphere := SphereMesh.new()
	sphere.add_uv2 = true
	_check(data._mesh_has_single_uv_chart(sphere), "Sphere curved lens is one physical UV chart")
	var box := BoxMesh.new()
	box.add_uv2 = true
	_check(not data._mesh_has_single_uv_chart(box), "Box atlas remains multiple UV charts with strict tie isolation")
	var disconnected := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0,0,0),Vector3(1,0,0),Vector3(0,1,0),Vector3(10,0,0),Vector3(10,1,0),Vector3(9,0,0)])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(0,0),Vector2(1,0),Vector2(0,1),Vector2(1,0),Vector2(0,1),Vector2(1,1)])
	disconnected.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	_check(not data._mesh_has_single_uv_chart(disconnected), "UV-edge coincidence must not join physically unrelated charts")
	var plane := PlaneMesh.new()
	plane.add_uv2 = true
	var proof: Dictionary = data.create_display_chart_proof(plane)
	data.display_chart_proofs.assign([proof])
	data._single_chart_cache.clear()
	_check(data._display_chart_single_for_layer(plane,0) and data._single_chart_cache.is_empty(), "Valid persisted proof skips topology certification")
	_check(not data._display_chart_single_for_layer(disconnected,0), "Stale source geometry must not reuse a true single-chart proof")
	data.display_chart_proofs.assign([{"version":999,"single_connected_chart":true,"mesh_signature":data._mesh_chart_signature(disconnected)}])
	_check(not data._display_chart_single_for_layer(disconnected,0), "Unknown proof version cannot enable single-chart filling")
	data.display_chart_proofs.assign([{"version":1,"single_connected_chart":1,"mesh_signature":data._mesh_chart_signature(disconnected)}])
	_check(not data._display_chart_single_for_layer(disconnected,0), "Malformed proof boolean cannot enable single-chart filling")
	data.display_chart_proofs.clear()
	_check(data._display_chart_single_for_layer(plane,0), "Legacy resource uses explicit topology certification")
	_check(display[left] == 10.0 and display[right+2] == 20.0, "Covered texels remain unchanged")
	_check(display[(1*5+1)*4] == 10.0, "Unique nearest original sample extends one gutter pixel")
	_check(display[(0*5+1)*4+3] == 0.0, "Padding never propagates from previously-filled texels")
	raw[right] = 10.0
	raw[right+2] = 0.0
	display = data._display_rgba(raw)
	_check(display[(2*5+2)*4] == 10.0, "Identical-color ties need no blending")
	data.display_gutter_pixels = 0
	_check(data._display_rgba(raw).to_byte_array() == raw.to_byte_array(), "Zero gutter returns raw reference unchanged")
