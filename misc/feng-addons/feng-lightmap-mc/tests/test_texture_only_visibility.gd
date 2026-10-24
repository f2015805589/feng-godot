extends SceneTree
## Texture-only lightmaps must survive a camera looking away from their origin.
## No path tracing, exposure adaptation, or SH probes are used by this fixture.
const Volume = preload("../feng_lightmap_volume.gd")
const Data = preload("../feng_lightmap_data.gd")
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, label: String) -> void:
	print("TEXTURE_LIGHTMAP_VISIBILITY ", value, " ", label)
	if not value: failures += 1

func _settle() -> void:
	for i in 30: await RenderingServer.frame_post_draw

func _run() -> void:
	# Forward+ supplies standalone ambient lighting without an addon compositor;
	# the complete FRP project is verified separately with its authored pipeline.
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		push_error("Run this isolated fixture with --rendering-method forward_plus.")
		quit(2)
		return
	root.size = Vector2i(512, 512)
	Engine.max_fps = 60
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0, 0, 0.3)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0, 0, 1)
	environment.environment.ambient_light_energy = 1.0
	scene.add_child(environment)
	var wall := MeshInstance3D.new()
	wall.name = "Wall"
	wall.mesh = BoxMesh.new()
	wall.mesh.size = Vector3(8, 4, 0.2)
	wall.mesh.add_uv2 = true
	wall.position = Vector3(0, 2, -4)
	wall.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	wall.material_override = material
	scene.add_child(wall)
	var volume := Volume.new()
	volume.name = "Volume"
	var data := Data.new()
	data.atlas_resolution = 4
	data.sampled_mesh_count = 1
	data.mesh_relative_paths.assign([NodePath("../Wall")])
	data.receiver_bounds_local = AABB(Vector3(-4.1, -0.1, -4.2), Vector3(8.2, 4.2, 0.4))
	data.display_gutter_pixels = 0
	var rgba := PackedFloat32Array()
	for i in 16: rgba.append_array(PackedFloat32Array([0.05, 1, 0.05, 1]))
	data.radiance_layers.assign([rgba])
	volume.baked_data = data
	volume.display_gutter_pixels = 0
	volume.enabled = true
	scene.add_child(volume)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.current = true
	camera.fov = 70
	var display := volume.get_node(Volume.DISPLAY_NODE_NAME) as LightmapGI
	_check(display.light_data.get("probe_data").bounds == data.receiver_bounds_local,
		"The renderer data retains receiver bounds without inventing SH probes")
	_check(display.light_data.get("probe_data").points.is_empty(), "No dynamic capture probes were synthesized")
	if OS.get_cmdline_user_args().has("--legacy-empty-bounds-control"):
		var legacy := display.light_data
		display.light_data = null
		RenderingServer.lightmap_set_probe_bounds(legacy.get_rid(), AABB())
		display.light_data = legacy
	var colors: Array[Color] = []
	for position in [Vector3(0, 2, 6), Vector3(3, 3, -2)]:
		camera.position = position
		camera.look_at(Vector3(0, 2.5, -4))
		await _settle()
		var image := root.get_texture().get_image()
		var color := image.get_pixel(image.get_width() / 2, image.get_height() / 2)
		colors.append(color)
		_check(color.g > color.b * 1.5 and color.g > 0.3,
			"Visible wall keeps its green atlas when the origin is outside the view: %s" % color)
	_check(absf(colors[0].g - colors[1].g) < 0.02, "Static diffuse atlas is independent of camera angle")
	var dynamic := MeshInstance3D.new()
	dynamic.mesh = BoxMesh.new()
	dynamic.mesh.size = Vector3(0.2, 0.2, 0.2)
	dynamic.material_override = material
	dynamic.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	dynamic.position = Vector3(2, 2, -3.85)
	scene.add_child(dynamic)
	camera.position = Vector3(2, 2, -1)
	camera.look_at(dynamic.position)
	await _settle()
	var dynamic_image := root.get_texture().get_image()
	var dynamic_color := dynamic_image.get_pixel(dynamic_image.get_width() / 2, dynamic_image.get_height() / 2)
	_check(dynamic_color.b > 0.3 and dynamic_color.b > dynamic_color.g * 1.5,
		"Texture-only bounds cannot assign empty SH captures to dynamic receivers: %s" % dynamic_color)
	print("TEXTURE_LIGHTMAP_VISIBILITY failures=", failures)
	quit(0 if failures == 0 else 1)
