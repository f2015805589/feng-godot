extends "res://vt_adaptive_base.gd"

# The page table stores one physical mip per slot.  A grazing orthographic view has a
# long footprint in the view direction and a short one across it.  The old AVT resolver
# used the long derivative as its mip level and therefore selected the coarse probe page;
# the shader under test is expected to keep the fine page when the long axis fits inside
# the page's supported anisotropy.
const REGION := Vector2i.ZERO
const TARGET := Vector3(34.0, 0.0, 34.0)
const TARGET_XZ := Vector2(34.0, 34.0)
const PAGE_SIZE := 32
const PAGE_BORDER := 4
const DENSITY := 8.0
const EXPECTED_BLOCK_SIZE := 16
const CAMERA_SIZE := 16.0
const SCREEN_CENTER := Vector2(160.0, 120.0)
const CAMERA_ELEVATION := 2.0
const CAMERA_DISTANCE := 11.3425636 # 2 / tan(10 degrees)

var albedo_array: Texture2DArray
var normal_array: Texture2DArray
var param_array: Texture2DArray

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func ground_point(screen: Vector2) -> Vector2:
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(
			camera.project_ray_origin(screen), camera.project_ray_normal(screen))
	if hit == null:
		return Vector2(INF, INF)
	return Vector2(hit.x, hit.z)

func footprint_metrics(anisotropy: float) -> Dictionary:
	var center := ground_point(SCREEN_CENTER)
	var dx := ground_point(SCREEN_CENTER + Vector2(1.0, 0.0)) - center
	var dy := ground_point(SCREEN_CENTER + Vector2(0.0, 1.0)) - center
	var a := dx.dot(dx)
	var b := dx.dot(dy)
	var c := dy.dot(dy)
	var discriminant := maxf((a - c) * (a - c) + 4.0 * b * b, 0.0)
	var major := sqrt(maxf(0.5 * (a + c + sqrt(discriminant)), 1e-16))
	var minor := absf(dx.x * dy.y - dx.y * dy.x) / major
	var scalar := maxf(dx.length(), dy.length())
	var supported := maxf(1.0, float(PAGE_BORDER) - 0.5)
	var capped := maxf(minor, major / minf(maxf(1.0, anisotropy), supported))
	return {
		"dx": dx,
		"dy": dy,
		"major": major,
		"minor": minor,
		"scalar": scalar,
		"capped": capped,
	}

func set_camera_pose(azimuth_degrees: float, roll_degrees: float) -> void:
	var azimuth := deg_to_rad(azimuth_degrees)
	var horizontal := Vector3(sin(azimuth), 0.0, cos(azimuth)) * CAMERA_DISTANCE
	camera.position = TARGET + Vector3(horizontal.x, CAMERA_ELEVATION, horizontal.z)
	camera.look_at(TARGET, Vector3.UP)
	if not is_zero_approx(roll_degrees):
		# Roll rotates the two screen derivatives while leaving their singular values
		# unchanged.  It catches a replacement that takes min(dx.length(), dy.length()).
		camera.rotate_object_local(Vector3.FORWARD, deg_to_rad(roll_degrees))

func make_layer(color: Color) -> Image:
	var stored := PAGE_SIZE + 2 * PAGE_BORDER
	var image := Image.create(stored, stored, false, Image.FORMAT_RGBAF)
	image.fill(color)
	return image

func install_probe_pages(block_size: int) -> Dictionary:
	var vt := terrain.get_surface_vt()
	var max_mip := 0
	var level_size := block_size
	while level_size > 1:
		max_mip += 1
		level_size >>= 1
	# Remove the automatically produced hierarchy for this one sector.  The two
	# pages below are then the only valid samples at the centre of the image.
	for mip in range(max_mip + 1):
		var count := maxi(1, block_size >> mip)
		for y in range(count):
			for x in range(count):
				vt.release_page(REGION, mip, x, y)
	var fine_x := clampi(int(floor(TARGET_XZ.x / 64.0 * float(block_size))), 0, block_size - 1)
	var fine_y := clampi(int(floor(TARGET_XZ.y / 64.0 * float(block_size))), 0, block_size - 1)
	var slots: Dictionary = {}
	for mip in [0, 1]:
		var slot := vt.request_page(REGION, mip, fine_x >> mip, fine_y >> mip)
		require(slot >= 0, "allocate anisotropic probe mip %d" % mip)
		if slot >= 0:
			slots[mip] = slot
	vt.commit()

	var albedo_images: Array[Image] = []
	var normal_images: Array[Image] = []
	var param_images: Array[Image] = []
	for slot in terrain.vt_page_count:
		var albedo := Color.MAGENTA
		if slot == int(slots.get(0, -1)):
			albedo = Color(0.95, 0.04, 0.02, 1.0) # fine page
		elif slot == int(slots.get(1, -1)):
			albedo = Color(0.02, 0.82, 0.06, 1.0) # coarse page
		albedo_images.append(make_layer(albedo))
		normal_images.append(make_layer(Color(0.5, 0.5, 1.0, 1.0)))
		param_images.append(make_layer(Color(0.0, 1.0, 0.0, 1.0)))
	albedo_array = Texture2DArray.new()
	normal_array = Texture2DArray.new()
	param_array = Texture2DArray.new()
	albedo_array.create_from_images(albedo_images)
	normal_array.create_from_images(normal_images)
	param_array.create_from_images(param_images)
	var material_rid := terrain.material.get_material_rid()
	RenderingServer.material_set_param(material_rid, "_surface_material_albedo", albedo_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_normal", normal_array.get_rid())
	RenderingServer.material_set_param(material_rid, "_surface_material_params", param_array.get_rid())
	return slots

func probe_label(image: Image) -> String:
	return sample_area(image, TARGET_XZ, 2)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://vt_anisotropy_data"))
	# Keep the internal shader uniform deterministic without adding a terrain-facing
	# setting.  The production material reads this viewport value when it binds uniforms.
	root.get_viewport().set_anisotropic_filtering_level(2) # Viewport.ANISOTROPY_4X

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_auto_capacity = false
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = 256
	terrain.vt_pages_per_update = 16
	terrain.surface_vt_texels_per_meter = DENSITY
	terrain.surface_vt_adaptive_enabled = false
	terrain.surface_vt_selection_mode = 2 # Full AVT sectors, so the address is 64 m aligned.
	terrain.surface_vt_region_grid = Vector2i.ONE
	terrain.surface_vt_distance = 512.0
	terrain.surface_vt_feedback = false
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_page_fade_frames = 0
	terrain.free_editor_textures = false
	terrain.data_directory = "user://vt_anisotropy_data"
	scene.add_child(terrain)
	root.add_child(scene)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -25.0, 0.0)
	scene.add_child(light)
	add_assets()
	terrain.data.add_region_blank(REGION)
	terrain.data.update_maps()

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_SIZE
	camera.near = 0.1
	camera.far = 512.0
	camera.current = true
	root.add_child(camera)
	set_camera_pose(0.0, 0.0)
	terrain.set_camera(camera)
	terrain.surface_vt_enabled = true
	if terrain.material != null:
		terrain.material.update()

	# Let the real planner publish the sector directory first.  The test then freezes
	# scheduling and only changes the payload slots, so a colour result cannot be a
	# scheduler configuration check.
	for _frame in 180:
		await process_frame
	await RenderingServer.frame_post_draw
	terrain.set_process(false)
	terrain.set_physics_process(false)

	var settings: Dictionary = terrain.get_vt_settings()
	var stats: Dictionary = settings.get("avt_sector_stats", {})
	var block_size := int(terrain.get_surface_vt().get_sector_block_size(REGION))
	var base_resolution := float(stats.get("base_virtual_resolution", 0.0))
	var planned_texel := float(stats.get("finest_requested_texel_world", 0.0))
	print("VT_ANISO_GEOMETRY block=", block_size, " base_resolution=", base_resolution,
			" finest_requested_texel=", planned_texel)
	require(block_size == EXPECTED_BLOCK_SIZE,
			"density/page settings must produce a 16 texel sector block, got %d" % block_size)
	require(is_equal_approx(base_resolution, 64.0 * DENSITY),
			"probe must use the actual 64 m virtual resolution, got %.3f" % base_resolution)
	var expected_texel := 64.0 / base_resolution if base_resolution > 0.0 else 0.0
	require(expected_texel > 0.0, "AVT must publish a physical world texel size")
	require(planned_texel > 0.0 and planned_texel <= expected_texel * 1.01,
			"native grazing-view demand must request the fine mip selected by anisotropic sampling")

	var slots := install_probe_pages(block_size)
	# Synthetic slot replacement does not update the producer's old world_rect
	# records. Derive this mip's texel from the published sector geometry instead.
	var observed_texel := 64.0 / (float(block_size) * float(PAGE_SIZE))
	print("VT_ANISO_PAGES fine_slot=", slots.get(0, -1), " coarse_slot=", slots.get(1, -1),
			" observed_texel=", observed_texel, " expected_texel=", expected_texel)
	require(observed_texel > 0.0 and absf(observed_texel - expected_texel) < 0.001,
			"fine page world texel must come from the published page rect")

	var material_rid := terrain.material.get_material_rid()
	var bound_anisotropy = RenderingServer.material_get_param(material_rid, "_surface_vt_anisotropy")
	var shader_anisotropy := float(bound_anisotropy) if bound_anisotropy != null else 4.0
	if shader_anisotropy <= 0.0:
		shader_anisotropy = 4.0
	var supported := minf(shader_anisotropy, float(PAGE_BORDER) - 0.5)
	require(supported >= 3.0, "the test viewport must expose at least 4x anisotropy")

	var poses := [
		{"name": "yaw0", "azimuth": 0.0, "roll": 0.0},
		{"name": "yaw45", "azimuth": 45.0, "roll": 0.0},
		{"name": "yaw45_roll45", "azimuth": 45.0, "roll": 45.0},
	]
	for pose: Dictionary in poses:
		set_camera_pose(float(pose.azimuth), float(pose.roll))
		var metrics := footprint_metrics(shader_anisotropy)
		print("VT_ANISO pose=", pose.name, " scalar=", metrics.scalar,
				" major=", metrics.major, " minor=", metrics.minor, " capped=", metrics.capped,
				" dx=", metrics.dx, " dy=", metrics.dy)
		# These checks prove the fixture is in the intended mip interval.  The image
		# assertion below is the contract: it must sample the red fine page rather than
		# merely agreeing with a reported footprint or a material uniform.
		require(metrics.scalar > observed_texel * 2.0,
				"%s must make the legacy scalar footprint cross a mip boundary" % pose.name)
		require(metrics.major > metrics.minor * 3.0,
				"%s must contain a real anisotropic footprint" % pose.name)
		require(metrics.capped < observed_texel,
				"%s capped singular-value footprint must remain inside the fine texel" % pose.name)
		var shot := await frame_image(3)
		shot.save_png(output_dir.path_join("anisotropy-%s.png" % pose.name))
		var label := probe_label(shot)
		var center := shot.get_pixelv(Vector2i(int(SCREEN_CENTER.x), int(SCREEN_CENTER.y)))
		print("VT_ANISO_SAMPLE pose=", pose.name, " label=", label, " center=", center)
		require(label == "red", "%s must retain the distinct fine-page colour; got %s" % [pose.name, label])

	# Stop callbacks before freeing the camera and terrain.  The synthetic arrays remain
	# referenced until the material is no longer used by a draw.
	terrain.surface_vt_enabled = false
	terrain.set_process(false)
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS AVT anisotropic footprint keeps the fine page at grazing angles")
	quit(0)
