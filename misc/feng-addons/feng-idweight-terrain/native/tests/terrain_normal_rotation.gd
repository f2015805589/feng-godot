extends "res://vt_scene_base.gd"

const REGION_SIZE := 64
const TARGET := Vector3(32.0, 0.0, 32.0)
const ANGLES := [0.0, 45.0, 90.0, 135.0, 180.0, 0.0]

var scene: Node3D
var output_dir := "user://"
var base_transform := Transform3D.IDENTITY
var target_height := 0.0


func _initialize() -> void:
	call_deferred("run")


func height_at(x: float, z: float) -> float:
	return 2.0 * sin(x * 0.31) + 1.5 * cos(z * 0.27) + 0.04 * x


func fill_region() -> void:
	var heights := PackedFloat32Array()
	heights.resize(REGION_SIZE * REGION_SIZE)
	for z in REGION_SIZE:
		for x in REGION_SIZE:
			heights[z * REGION_SIZE + x] = height_at(float(x), float(z))
	var region: Terrain3DRegion = terrain.data.get_region(Vector2i.ZERO)
	region.set_height_map(Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_RF, heights.to_byte_array()))
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var word := material_word(0)
	for i in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(i * 2, word)
	region.set_surface_map(Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)
	target_height = height_at(TARGET.x, TARGET.z)


func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	terrain.assets.texture_array_compression = Terrain3DAssets.ARRAY_UNCOMPRESSED
	var asset := Terrain3DTextureAsset.new()
	asset.albedo_texture = texture(32, Color(0.35, 0.35, 0.35, 1.0))
	var normal := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var tilt := Vector2(0.35, -0.25)
	normal.fill(Color(0.5 + 0.5 * tilt.x, 0.5 + 0.5 * tilt.y,
		0.5 + 0.5 * sqrt(1.0 - tilt.length_squared()), 1.0))
	normal.generate_mipmaps()
	asset.normal_texture = ImageTexture.create_from_image(normal)
	asset.normal_depth = 1.0
	asset.uv_scale = 1.0
	terrain.assets.set_texture_asset(0, asset)


func frame_image(wait_frames: int = 4) -> Image:
	for _i in wait_frames:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func capture_sample(label: String, pose: Transform3D) -> Dictionary:
	camera.global_transform = pose
	root.debug_draw = Viewport.DEBUG_DRAW_NORMAL_BUFFER
	var image := await frame_image()
	image.save_png(output_dir.path_join("normal-" + label + ".png"))
	var pixel := image.get_pixel(image.get_width() / 2, image.get_height() / 2)
	var view_normal := Vector3(pixel.r, pixel.g, pixel.b) * 2.0 - Vector3.ONE
	require(view_normal.length_squared() > 0.01, "normal buffer is empty at " + label + ": " + str(pixel))
	var world_normal := (camera.global_basis * view_normal).normalized()
	root.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	var color_image := await frame_image()
	color_image.save_png(output_dir.path_join("lit-" + label + ".png"))
	var color := color_image.get_pixel(color_image.get_width() / 2, color_image.get_height() / 2)
	print("TERRAIN_NORMAL_ROTATION ", label, " view=", view_normal.normalized(),
		" world=", world_normal, " lit=", color)
	return {"normal": world_normal, "color": color}


func measure_sequence(label: String, poses: Array) -> Dictionary:
	var reference := Vector3.ZERO
	var reference_color := Color.BLACK
	var worst_angle := 0.0
	var worst_color := 0.0
	for index in poses.size():
		var sample := await capture_sample("%s-%03d" % [label, int(ANGLES[index])], poses[index])
		var world_normal: Vector3 = sample["normal"]
		var lit: Color = sample["color"]
		if reference == Vector3.ZERO:
			reference = world_normal
			reference_color = lit
			continue
		var angle_error := rad_to_deg(acos(clampf(reference.dot(world_normal), -1.0, 1.0)))
		var color_error := maxf(absf(reference_color.r - lit.r), maxf(absf(reference_color.g - lit.g), absf(reference_color.b - lit.b)))
		worst_angle = maxf(worst_angle, angle_error)
		worst_color = maxf(worst_color, color_error)
		print("TERRAIN_NORMAL_ROTATION compare ", label, " world_degrees=", angle_error, " lit_max=", color_error)
	print("TERRAIN_NORMAL_ROTATION summary ", label, " world_degrees=", worst_angle, " lit_max=", worst_color)
	return {"normal_degrees": worst_angle, "lit_max": worst_color}


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	DirAccess.make_dir_recursive_absolute("user://terrain_normal_rotation_data")
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.free_editor_textures = false
	terrain.data_directory = "user://terrain_normal_rotation_data"
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = false
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.region_size = REGION_SIZE
	terrain.vertex_spacing = 1.0
	terrain.surface_density = 1
	var depth_cap := OS.get_environment("TERRAIN_NORMAL_ROTATION_DEPTH_CAP")
	if not depth_cap.is_empty():
		terrain.material.set_shader_param("distant_normal_scale", depth_cap.to_float())
	add_materials()
	terrain.data.add_region_blank(Vector2i.ZERO)
	fill_region()
	terrain.data.update_maps()

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 300.0
	camera.near = 0.1
	camera.far = 512.0
	var target := Vector3(TARGET.x, target_height, TARGET.z)
	camera.position = target + Vector3(0.0, 50.0, 50.0)
	camera.current = true
	root.add_child(camera)
	camera.look_at(target)
	base_transform = camera.global_transform
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	light.light_intensity_lux = 6.0
	light.light_energy = 1.0
	light.shadow_enabled = false
	scene.add_child(light)
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.BLACK
	environment.ambient_light_energy = 0.0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment_node.environment = environment
	scene.add_child(environment_node)
	root.use_taa = false
	root.msaa_3d = Viewport.MSAA_DISABLED
	await frame_image(12)
	print("TERRAIN_NORMAL_ROTATION setup target=", target, " screen=", camera.unproject_position(target),
		" viewport=", root.get_texture().get_size(), " vertex_spacing=", terrain.material.get_shader_param("_vertex_spacing"),
		" vertex_density=", terrain.material.get_shader_param("_vertex_density"),
		" region=", terrain.data.get_region(Vector2i.ZERO).get_region_size(),
		" surface_density=", terrain.data.get_region(Vector2i.ZERO).get_surface_density())

	var roll_poses := []
	var orbit_poses := []
	for angle_value in ANGLES:
		var angle := deg_to_rad(float(angle_value))
		roll_poses.append(Transform3D(base_transform.basis * Basis(Vector3(0.0, 0.0, 1.0), angle), base_transform.origin))
		var orbit_offset := Basis(Vector3.UP, angle) * Vector3(0.0, 50.0, 50.0)
		var orbit_pose := Transform3D(Basis(), target + orbit_offset)
		orbit_poses.append(orbit_pose.looking_at(target, Vector3.UP))
	var ortho_roll := await measure_sequence("ortho-roll", roll_poses)
	require(ortho_roll["normal_degrees"] < 1.0, "orthographic roll changed the terrain world normal: " + str(ortho_roll))
	require(ortho_roll["lit_max"] <= 2.0 / 255.0, "orthographic roll changed fixed-light shading: " + str(ortho_roll))
	var ortho_orbit := await measure_sequence("ortho-orbit", orbit_poses)
	require(ortho_orbit["normal_degrees"] < 1.0, "orthographic orbit changed the terrain world normal: " + str(ortho_orbit))

	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = 70.0
	base_transform = Transform3D(Basis(), target + Vector3(0.0, 150.0, 150.0)).looking_at(target, Vector3.UP)
	roll_poses.clear()
	orbit_poses.clear()
	for angle_value in ANGLES:
		var angle := deg_to_rad(float(angle_value))
		roll_poses.append(Transform3D(base_transform.basis * Basis(Vector3(0.0, 0.0, 1.0), angle), base_transform.origin))
		var orbit_offset := Basis(Vector3.UP, angle) * Vector3(0.0, 150.0, 150.0)
		var orbit_pose := Transform3D(Basis(), target + orbit_offset)
		orbit_poses.append(orbit_pose.looking_at(target, Vector3.UP))
	var perspective_roll := await measure_sequence("perspective-roll", roll_poses)
	require(perspective_roll["normal_degrees"] < 1.0, "perspective roll changed the terrain world normal: " + str(perspective_roll))
	require(perspective_roll["lit_max"] <= 2.0 / 255.0, "perspective roll changed fixed-light shading: " + str(perspective_roll))
	var perspective_orbit := await measure_sequence("perspective-orbit", orbit_poses)
	require(perspective_orbit["normal_degrees"] < 1.0, "perspective orbit changed the terrain world normal: " + str(perspective_orbit))

	root.debug_draw = Viewport.DEBUG_DRAW_DISABLED
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS terrain world normals and fixed-light shading are invariant to camera roll")
	quit(0)
