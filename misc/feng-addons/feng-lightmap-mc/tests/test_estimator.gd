extends SceneTree

const RESOLUTION := 4
const CAVITY_SPP := 8192
const EXTENSION_PATH := "res://addons/feng-lightmap-mc/feng-lightmap-mc.gdextension"

var _vertices := PackedVector3Array()
var _uv2 := PackedVector2Array()
var _albedo := PackedColorArray()
var _emission := PackedColorArray()
var _flags := PackedByteArray()
var _mesh_ids := PackedInt32Array()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not GDExtensionManager.is_extension_loaded(EXTENSION_PATH):
		var extension_status := GDExtensionManager.load_extension(EXTENSION_PATH)
		assert(extension_status == GDExtensionManager.LOAD_STATUS_OK,
			"could not load feng-lightmap-mc extension (status %d)" % extension_status)
	var integrator := ClassDB.instantiate("FengLightmapMCIntegrator")
	assert(integrator != null, "native FengLightmapMCIntegrator extension must load")
	assert(integrator.has_method("get_backend_contract_version")
			and int(integrator.call("get_backend_contract_version")) >= 2,
		"native backend contract v2 is required; rebuild the DLL to support transport-only mesh_id=-1")
	_test_volume_script_contract()
	_test_volume_model_rejections()
	_test_uniform_environment(integrator)
	_test_infinite_diffuse_cavity(integrator)
	_test_overlap_rejection(integrator)
	print("FengLightmapMC analytical CPU tests passed")
	quit(0)


func _test_volume_script_contract() -> void:
	var volume_script := load("res://addons/feng-lightmap-mc/feng_lightmap_volume.gd")
	assert(volume_script is Script, "FengLightmapVolume GDScript must parse")
	var volume: Object = (volume_script as Script).new()
	assert(volume is Node3D and not bool(volume.get("enabled")), "the separate Lightmap volume must default disabled")
	assert(String(volume.get("output_resource_path")) == "res://bake/lightmap/box_white_lightmap.res",
		"the standalone output resource path must be independent of MagicGI data")
	var bake_button: Callable = volume.get("bake_button")
	assert(bake_button.is_valid(), "the Inspector button must be connected to a real bake handler")
	assert(String(volume.get("bake_status")).contains("Not baked"), "the Inspector must expose visible bake status")
	assert(String(volume.get("bake_report_text")).contains("bounds"), "the Inspector must expose boundary and output details")
	var receiver_bounds: AABB = volume.get("bounds")
	assert(receiver_bounds.size.x > 0.0 and receiver_bounds.size.y > 0.0 and receiver_bounds.size.z > 0.0,
		"the receiver range must be an editable finite AABB")
	volume.free()


func _test_volume_model_rejections() -> void:
	var material := StandardMaterial3D.new()
	material.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	material.specular_mode = BaseMaterial3D.SPECULAR_TOON
	var fixture := _new_volume_validation_fixture(material)
	var volume: Object = fixture.volume
	var report: Dictionary = volume.call("bake")
	assert(not report.get("ok", false), "the volume must reject an unsupported toon specular lobe")
	assert(String(report.get("error", "")).contains("specular mode"), "specular rejection must explain the omitted lobe")

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.3, 0.2, 0.1)
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	(fixture.root as Node).add_child(world_environment)
	volume.set("environment_mode", 0) # REJECT_SCENE_ENVIRONMENT
	report = volume.call("bake")
	assert(not report.get("ok", false), "the volume must reject an undeclared non-black environment")
	assert(String(report.get("error", "")).contains("WorldEnvironment"), "environment rejection must identify the unsupported source")
	(fixture.root as Node).remove_child(world_environment)
	world_environment.free()

	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	var dynamic_light := DirectionalLight3D.new()
	dynamic_light.light_bake_mode = Light3D.BAKE_DYNAMIC
	(fixture.root as Node).add_child(dynamic_light)
	volume.set("environment_mode", 1) # BLACK_OVERRIDE
	report = volume.call("_collect_scene", fixture.root, fixture.root)
	assert(report.get("ok", false), "v3 frontend must collect BAKE_DYNAMIC directional lights")
	assert(not report.directional_lights[0].direct_enabled, "dynamic directional direct illumination must remain realtime")
	current_scene = null
	(fixture.root as Node).free()


func _new_volume_validation_fixture(material: StandardMaterial3D) -> Dictionary:
	var root := Node3D.new()
	root.name = "VolumeValidationFixture"
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-1.0, 0.0, -1.0), Vector3(-1.0, 0.0, 1.0),
		Vector3(1.0, 0.0, 1.0), Vector3(1.0, 0.0, -1.0),
	])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2]) # Godot clockwise front face
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	var receiver := MeshInstance3D.new()
	receiver.name = "Receiver"
	receiver.mesh = mesh
	receiver.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	root.add_child(receiver)
	get_root().add_child(root)
	current_scene = root
	var volume_script := load("res://addons/feng-lightmap-mc/feng_lightmap_volume.gd") as Script
	var volume: Object = volume_script.new()
	volume.set("source_root_path", NodePath(".."))
	volume.set("output_resource_path", "res://addons/feng-lightmap-mc/tests/fixtures/never_saved.tres")
	root.add_child(volume)
	return {"root": root, "volume": volume}


func _test_uniform_environment(integrator: Object) -> void:
	_clear()
	var white := Color(1.0, 1.0, 1.0, 1.0)
	_add_quad(
		0,
		Vector3(-1.0, 0.0, -1.0),
		Vector3(-1.0, 0.0, 1.0),
		Vector3(1.0, 0.0, 1.0),
		Vector3(1.0, 0.0, -1.0),
		white,
		Color.BLACK
	)
	var environment := Color(0.8, 0.35, 0.12, 1.0)
	var result := _bake(integrator, 1, 32, 0x724BD, environment)
	assert(result.ok, String(result.get("error", "uniform environment bake failed")))
	for layer_variant in result.layers:
		var rgba: PackedFloat32Array = layer_variant.rgba
		for pixel in RESOLUTION * RESOLUTION:
			var offset := pixel * 4
			assert(absf(rgba[offset] - environment.r) < 0.00001, "open-plane red irradiance/pi must equal uniform environment radiance")
			assert(absf(rgba[offset + 1] - environment.g) < 0.00001, "open-plane green irradiance/pi must equal uniform environment radiance")
			assert(absf(rgba[offset + 2] - environment.b) < 0.00001, "open-plane blue irradiance/pi must equal uniform environment radiance")
			assert(layer_variant.variance[pixel] < 0.00000001, "the constant open-plane integral should have zero path variance")


func _test_infinite_diffuse_cavity(integrator: Object) -> void:
	_clear()
	var rho := Color(0.75, 0.75, 0.75, 1.0)
	var emitted := Color(0.05, 0.05, 0.05, 1.0)
	# Every face normal points into the closed cube. The exact uniform-radiance
	# fixed point is E + rho*L, so L = E/(1-rho), including all bounce orders.
	_add_quad(0, Vector3(-1, -1, -1), Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, -1, -1), rho, emitted)
	_add_quad(1, Vector3(-1, 1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1), Vector3(-1, 1, 1), rho, emitted)
	_add_quad(2, Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1), rho, emitted)
	_add_quad(3, Vector3(-1, -1, 1), Vector3(-1, 1, 1), Vector3(1, 1, 1), Vector3(1, -1, 1), rho, emitted)
	_add_quad(4, Vector3(-1, -1, -1), Vector3(-1, 1, -1), Vector3(-1, 1, 1), Vector3(-1, -1, 1), rho, emitted)
	_add_quad(5, Vector3(1, -1, -1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(1, 1, -1), rho, emitted)
	var result := _bake(integrator, 6, CAVITY_SPP, 0x19A2E8, Color.BLACK)
	assert(result.ok, String(result.get("error", "cavity bake failed")))
	assert(result.rr_survivals > 0, "high-albedo cavity paths must exercise Russian roulette")
	assert(result.average_path_bounces > 3.0, "the estimator must continue beyond bounce three")
	var actual := Vector3.ZERO
	var texel_count := 0
	var sum_variance_of_mean := 0.0
	for layer_variant in result.layers:
		var rgba: PackedFloat32Array = layer_variant.rgba
		var variance: PackedFloat32Array = layer_variant.variance
		var coverage: PackedByteArray = layer_variant.coverage
		for pixel in RESOLUTION * RESOLUTION:
			if coverage[pixel] == 0:
				continue
			var offset := pixel * 4
			actual += Vector3(rgba[offset], rgba[offset + 1], rgba[offset + 2])
			sum_variance_of_mean += variance[pixel] / CAVITY_SPP
			texel_count += 1
	assert(texel_count == RESOLUTION * RESOLUTION * 6, "each cavity wall must cover its own non-overlapping atlas layer")
	actual /= float(texel_count)
	var expected := 0.05 / (1.0 - 0.75)
	var standard_error := sqrt(sum_variance_of_mean) / float(texel_count)
	assert(standard_error > 0.0, "MIS/RR cavity should report nonzero sampling variance")
	var z_score := absf(actual.x - expected) / standard_error
	assert(z_score < 4.0, "infinite-bounce result %f differs from analytic %f by %f standard errors" % [actual.x, expected, z_score])
	assert(absf(actual.y - expected) / standard_error < 4.0, "green channel must match the same analytic cavity reference")
	assert(absf(actual.z - expected) / standard_error < 4.0, "blue channel must match the same analytic cavity reference")
	print(JSON.stringify({
		"analytic_case": "six-wall diffuse cavity with uniform emission and no max-bounce cutoff",
		"expected_radiance": expected,
		"estimated_radiance": actual.x,
		"standard_error": standard_error,
		"z_score": z_score,
		"average_path_bounces": result.average_path_bounces,
		"rr_survivals": result.rr_survivals,
		"path_count": result.path_count,
	}))


func _test_overlap_rejection(integrator: Object) -> void:
	_clear()
	var rho := Color.WHITE
	var emitted := Color.BLACK
	_add_triangle(0, Vector3(-1, 0, -1), Vector3(1, 0, 1), Vector3(1, 0, -1), Vector2(0, 0), Vector2(1, 1), Vector2(1, 0), rho, emitted)
	_add_triangle(0, Vector3(-1, 0, -1), Vector3(1, 0, 1), Vector3(1, 0, -1), Vector2(0, 0), Vector2(1, 1), Vector2(1, 0), rho, emitted)
	var result := _bake(integrator, 1, 4, 1, Color.BLACK)
	assert(not result.ok, "overlapping UV2 interiors must be rejected")
	assert(String(result.error).contains("overlap"), "overlap rejection must name the invalid UV2 mapping")


func _add_quad(mesh_id: int, a: Vector3, b: Vector3, c: Vector3, d: Vector3, albedo: Color, emission: Color) -> void:
	_add_triangle(mesh_id, a, b, c, Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), albedo, emission)
	_add_triangle(mesh_id, a, c, d, Vector2(0, 0), Vector2(1, 1), Vector2(0, 1), albedo, emission)


func _add_triangle(mesh_id: int, a: Vector3, b: Vector3, c: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2, albedo: Color, emission: Color) -> void:
	_vertices.append_array(PackedVector3Array([a, b, c]))
	_uv2.append_array(PackedVector2Array([uv_a, uv_b, uv_c]))
	_albedo.append(albedo)
	_emission.append(emission)
	_flags.append(0)
	_mesh_ids.append(mesh_id)


func _bake(integrator: Object, mesh_count: int, spp: int, test_seed: int, environment: Color) -> Dictionary:
	return integrator.bake_atlases(_vertices, _uv2, _albedo, _emission, _flags, _mesh_ids, mesh_count, RESOLUTION, spp, test_seed, environment)


func _clear() -> void:
	_vertices.clear()
	_uv2.clear()
	_albedo.clear()
	_emission.clear()
	_flags.clear()
	_mesh_ids.clear()
