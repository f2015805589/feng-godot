extends "res://vt_adaptive_base.gd"

# The page table stores one physical mip per slot.  A grazing orthographic view has a
# long footprint in the view direction and a short one across it.  The old AVT resolver
# used the long derivative as its mip level and therefore selected the coarse probe page;
# the shader under test is expected to keep the fine page when the long axis fits inside
# the number of taps the sampler really has.
#
# That number is the point of this file. `get_avt_anisotropy()` used to be the terrain's request
# clamped only by the page gutter, and the shipped pair - a five-texel gutter and an eight-times
# request - made it 8. But Godot builds a material sampler per *viewport* with
# `anisotropy_max = 1 << level` and there is no per-material anisotropy, so on a stock project
# (4x) the shader was selecting mips for taps that no fragment gets. This file pins the rule that
# fixed it - the effective number is the request clamped by the sampler *and* the gutter - and then
# measures, at a saturated grazing pose, what believing the wrong number costs on pixels.
const REGION := Vector2i.ZERO
const TARGET := Vector3(34.0, 0.0, 34.0)
const TARGET_XZ := Vector2(34.0, 34.0)
const PAGE_SIZE := 32
# The shipped gutter. A ratio of n spans about n texels along the major axis and bilinear adds half
# a texel, so the gutter admits `2 * border - 1`; five texels therefore admit `9`, which is above the
# 8x the near field requests by default - so what caps the assumed anisotropy here is the sampler's
# own 4x and not the page, which is the pair a project gets and the pair the grazing measurement at
# the end of this file is about.
const PAGE_BORDER := 5
const DENSITY := 8.0
const EXPECTED_BLOCK_SIZE := 16
const CAMERA_SIZE := 16.0
const SCREEN_CENTER := Vector2(160.0, 120.0)
const CAMERA_ELEVATION := 2.0
const CAMERA_DISTANCE := 11.3425636 # 2 / tan(10 degrees)
# The saturated grazing pose. `sin` of the elevation angle, chosen so the major footprint is about
# 1.15 m: 1.15 / 8 = 0.144 m and 1.15 / 4 = 0.288 m straddle the 0.25 m boundary between the cell's
# local mip 0 (0.125 m per texel) and mip 1 (0.250 m), with margin on both sides.
const GRAZING_ELEVATION_SIN := 0.058
# The measurement window has to stay inside the cell's mip 0 page, which at this pose is about
# +/-2 m of ground: `major` is 1.15 m per screen row, so one row above and below, and 25 columns is
# 1.7 m across.
const GRAZING_ROWS := 1
const GRAZING_COLUMNS := 25

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
	var supported := maxf(1.0, 2.0 * float(PAGE_BORDER) - 1.0)
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

# A one-texel black/white noise page and, below it, the 2x2 box average of that page - the
# relationship a produced mip chain has (`the parent's texel is the child's four`). That average is
# what makes the grazing reading below mean something: a page the sampler can cover returns a
# correctly prefiltered average, and a page twice finer than its taps can cover returns four
# unfiltered samples instead, which is sampling noise that crawls frame to frame.
func make_noise_layers() -> Array:
	var stored := PAGE_SIZE + 2 * PAGE_BORDER
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240922
	var fine := Image.create(stored, stored, false, Image.FORMAT_RGBAF)
	for y in stored:
		for x in stored:
			var value := 1.0 if rng.randf() < 0.5 else 0.0
			fine.set_pixel(x, y, Color(value, value, value, 1.0))
	# Only the coarse page's lower-left quadrant maps onto this cell's fine page (a mip 1 page spans
	# four mip 0 pages); the rest is filled with the pattern's mean, which is what the neighbouring
	# child pages would average to anyway.
	var quadrant := PAGE_SIZE / 2 + PAGE_BORDER
	var coarse := Image.create(stored, stored, false, Image.FORMAT_RGBAF)
	coarse.fill(Color(0.5, 0.5, 0.5, 1.0))
	for y in quadrant:
		for x in quadrant:
			var sum := 0.0
			for dy in 2:
				for dx in 2:
					sum += fine.get_pixel(x * 2 + dx, y * 2 + dy).r
			var value := sum * 0.25
			coarse.set_pixel(x, y, Color(value, value, value, 1.0))
	return [fine, coarse]

# A grazing pose whose major footprint is a chosen multiple of the page texel. The elevation is what
# sets the ratio: a flat ground plane seen from `theta` above the horizon has a major axis of
# `size / height / sin(theta)` and a minor axis of `size / height`.
func set_grazing_pose(azimuth_degrees: float) -> void:
	var sine := GRAZING_ELEVATION_SIN
	var distance := CAMERA_ELEVATION * sqrt(1.0 - sine * sine) / sine
	var azimuth := deg_to_rad(azimuth_degrees)
	var horizontal := Vector3(sin(azimuth), 0.0, cos(azimuth)) * distance
	camera.position = TARGET + Vector3(horizontal.x, CAMERA_ELEVATION, horizontal.z)
	camera.look_at(TARGET, Vector3.UP)

# The mean and the mean absolute deviation of the red channel inside one screen window. The mean is
# what a filtered page must reproduce (it is the pattern's true average) and the deviation says how
# patchy the same window is, which is the frame-to-frame crawling a moving camera sees.
func window_values(image: Image) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	var center := Vector2i(int(SCREEN_CENTER.x), int(SCREEN_CENTER.y))
	for y in range(center.y - GRAZING_ROWS, center.y + GRAZING_ROWS + 1):
		for x in range(center.x - GRAZING_COLUMNS, center.x + GRAZING_COLUMNS + 1):
			values.push_back(image.get_pixel(clampi(x, 0, image.get_width() - 1), clampi(y, 0, image.get_height() - 1)).r)
	return values

func window_mean(image: Image) -> float:
	var values := window_values(image)
	var sum := 0.0
	for value: float in values:
		sum += value
	return sum / float(maxi(1, values.size()))

func window_spread(image: Image) -> float:
	var values := window_values(image)
	var mean := window_mean(image)
	var spread := 0.0
	for value: float in values:
		spread += absf(value - mean)
	return spread / float(maxi(1, values.size()))

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
	# Read while the instance still holds its defaults: the pair a project that changes nothing
	# gets, and the reason the grazing case below no longer describes the shipped behaviour.
	require(terrain.vt_page_border == 5,
			"the shipped gutter must admit the near field's 8x default, got %d" % terrain.vt_page_border)
	require(terrain.surface_vt_anisotropy == 8,
			"the near field must request 8x anisotropy by default, got %d" % terrain.surface_vt_anisotropy)
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

	# The rule that owns the number, measured rather than restated. Two bounds decide what the
	# shader and the planner may assume, and they are checked in the order they bind:
	#
	# 1. the sampler. Godot builds a material sampler per viewport with `anisotropy_max = 1 << level`
	#    from the viewport's own filtering level (the project default is 4x), and there is no
	#    per-material anisotropy, so a terrain request above it is a wish the hardware never
	#    implements. Believing the wish selects a page two times finer than the sampler can cover -
	#    see the grazing measurement at the end of this file.
	# 2. the page gutter, `2 * border - 1`, unchanged.
	terrain.vt_page_border = 5
	root.get_viewport().set_anisotropic_filtering_level(2) # Viewport.ANISOTROPY_4X
	var shipped: Dictionary = terrain.get_vt_settings()
	var shipped_sampler := float(shipped.get("avt_anisotropy_sampler", 0.0))
	var shipped_requested := float(shipped.get("avt_anisotropy_requested", 0.0))
	var shipped_anisotropy := float(shipped.get("avt_anisotropy_effective", 0.0))
	print("VT_ANISO_SHIPPED sampler=", shipped_sampler, " requested=", shipped_requested,
			" effective=", shipped_anisotropy, " border=5 viewport_level=2")
	require(shipped_sampler == 4.0,
			"the sampler reading must be the viewport's filtering level (4x here), got %.2f" % shipped_sampler)
	require(shipped_requested == 8.0,
			"the near field must request 8x anisotropy by default, got %.2f" % shipped_requested)
	require(is_equal_approx(shipped_anisotropy, minf(minf(shipped_requested, shipped_sampler), 9.0)),
			"the effective anisotropy must be the request clamped by the sampler and by the gutter, got %.2f" % shipped_anisotropy)
	# The bound is live in both directions: raising the viewport's filtering level raises the number
	# the shader may assume, up to the request, and a gutter narrower than the request still caps it.
	root.get_viewport().set_anisotropic_filtering_level(3) # Viewport.ANISOTROPY_8X
	var raised := float(terrain.get_vt_settings().get("avt_anisotropy_effective", 0.0))
	require(is_equal_approx(raised, 8.0),
			"an 8x viewport must let the 8x request through a five-texel gutter, got %.2f" % raised)
	terrain.vt_page_border = 4
	var gutter_capped := float(terrain.get_vt_settings().get("avt_anisotropy_effective", 0.0))
	require(is_equal_approx(gutter_capped, 7.0),
			"a four-texel gutter must cap an 8x viewport at 7, got %.2f" % gutter_capped)
	root.get_viewport().set_anisotropic_filtering_level(2)
	terrain.vt_page_border = PAGE_BORDER
	await process_frame

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
	var supported := minf(shader_anisotropy, 2.0 * float(PAGE_BORDER) - 1.0)
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

	# The reason the sampler bound above exists, measured on pixels instead of argued.
	#
	# A grazing footprint whose anisotropy is wider than the sampler can filter. Every slot starts as
	# the parent's pattern, so a page this fixture does not name still answers with correctly
	# prefiltered content, and the cell's two resident pages hold a one-texel noise page and its 2x2
	# box average: the reading asks one question of the same pose twice - how much of the pattern the
	# four taps this viewport really has can cover.
	#   assumed 8: footprint 1.15/8 = 0.144 m -> local mip 0, a 0.125 m page, four taps 2.3 texels
	#              apart cover 44% of the footprint
	#   assumed 4: footprint 1.15/4 = 0.288 m -> local mip 1, a 0.250 m page, four taps a texel apart
	#              cover it and average the sixteen child texels the pattern is made of
	# The sampler runs at 4x in both, so the first is exactly the two-times overshoot the aliasing
	# argument predicts and the second is what the fix delivers. The reading is the window's mean
	# absolute deviation - sampling noise, uncorrelated frame to frame, which is what a moving camera
	# sees as crawling.
	root.get_viewport().set_anisotropic_filtering_level(2) # Viewport.ANISOTROPY_4X
	# Precondition: the two assumptions must land on *different* resident pages of this cell, or the
	# reading below compares one page with itself. Read as colour first, with the flat red and green
	# pages the poses above used.
	for slot in terrain.vt_page_count:
		albedo_array.update_layer(make_layer(Color.MAGENTA), slot)
	albedo_array.update_layer(make_layer(Color(0.95, 0.04, 0.02, 1.0)), int(slots[0]))
	albedo_array.update_layer(make_layer(Color(0.02, 0.82, 0.06, 1.0)), int(slots[1]))
	set_grazing_pose(0.0)
	var landing := {}
	for assumed in [8.0, 4.0]:
		RenderingServer.material_set_param(material_rid, "_surface_vt_anisotropy", assumed)
		var page_shot := await frame_image(3)
		landing[assumed] = probe_label(page_shot)
		print("VT_ANISO_GRAZING_PAGE assumed=%.0f label=%s" % [assumed, landing[assumed]])
	require(landing[8.0] == "red" and landing[4.0] == "green",
			"the coarse grazing pose must make 8x land on the fine page and 4x on its parent, got %s and %s" % [landing[8.0], landing[4.0]])

	var layers := make_noise_layers()
	var fine_noise: Image = layers[0]
	var coarse_noise: Image = layers[1]
	for slot in terrain.vt_page_count:
		albedo_array.update_layer(coarse_noise, slot)
	albedo_array.update_layer(fine_noise, int(slots[0]))
	albedo_array.update_layer(coarse_noise, int(slots[1]))
	set_grazing_pose(0.0)
	var grazing := footprint_metrics(4.0)
	print("VT_ANISO_GRAZING major=%.4f minor=%.4f ratio=%.2f page_texel=%.4f mip0_footprint=%.4f mip1_footprint=%.4f" % [
			grazing.major, grazing.minor, grazing.major / maxf(grazing.minor, 1e-9), observed_texel,
			grazing.major / 8.0, grazing.major / 4.0])
	var spread := {}
	for assumed in [8.0, 4.0]:
		RenderingServer.material_set_param(material_rid, "_surface_vt_anisotropy", assumed)
		var shot := await frame_image(3)
		shot.save_png(output_dir.path_join("anisotropy-grazing-%d.png" % int(assumed)))
		spread[assumed] = window_spread(shot)
		print("VT_ANISO_GRAZING assumed=%.0f window_mean=%.5f spread=%.5f" % [
				assumed, window_mean(shot), spread[assumed]])
	# Restore the value the terrain publishes, so the teardown renders what the fix delivers.
	RenderingServer.material_set_param(material_rid, "_surface_vt_anisotropy", shader_anisotropy)
	print("VT_ANISO_GRAZING restored=", shader_anisotropy, " ratio=%.2f" % (float(spread[8.0]) / maxf(float(spread[4.0]), 1e-9)))
	require(float(spread[8.0]) > float(spread[4.0]) * 1.25,
			"a page twice finer than the sampler's taps can cover must read noisier than its parent: spread %.5f against %.5f" % [
				float(spread[8.0]), float(spread[4.0])])

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
