# Full AVT/SVT update path, steep uphill views and continuous camera movement.
extends "res://vt_adaptive_base.gd"

# get_height() reads a nearest authored texel. Using it directly for camera Y
# creates metre-scale vertical teleports, rather than continuous hill movement.
# Keep that stricter stress trajectory available explicitly for reproduction.
func ground_height(at: Vector3) -> float:
	if OS.get_environment("TERRAIN_VT_STEP_CAMERA") == "1":
		return terrain.data.get_height(at)
	var spacing: float = terrain.vertex_spacing
	var grid := Vector2(at.x, at.z) / spacing
	var cell := grid.floor()
	var fraction := grid - cell
	var a := terrain.data.get_height(Vector3(cell.x * spacing, 0, cell.y * spacing))
	var b := terrain.data.get_height(Vector3((cell.x + 1) * spacing, 0, cell.y * spacing))
	var c := terrain.data.get_height(Vector3(cell.x * spacing, 0, (cell.y + 1) * spacing))
	var d := terrain.data.get_height(Vector3((cell.x + 1) * spacing, 0, (cell.y + 1) * spacing))
	return a + (b - a) * fraction.x + (d - b) * fraction.y if fraction.x > fraction.y else a + (d - c) * fraction.x + (c - a) * fraction.y

func missing_pixels(image: Image, stride: int = 1) -> int:
	var count := 0
	for y in range(0, image.get_height(), stride):
		for x in range(0, image.get_width(), stride):
			var c := image.get_pixel(x, y)
			if c.r > 0.1 and c.r > c.g * 1.5 and c.b > c.g * 1.5: count += 1
	return count

var last_generation := -1
var last_produced := 0
var peak_produced := 0
var cpu_peak_us := 0
var cpu_total_us := 0
var cpu_frames := 0
var avt_cpu_peak_ms := 0.0

func tick() -> void:
	# Exercise the shared demand epoch and budget, including SVT and the baker.
	var start := Time.get_ticks_usec()
	terrain.notification(Node.NOTIFICATION_PHYSICS_PROCESS)
	var elapsed := Time.get_ticks_usec() - start
	cpu_peak_us = maxi(cpu_peak_us, elapsed)
	cpu_total_us += elapsed
	cpu_frames += 1
	await process_frame
	await RenderingServer.frame_post_draw
	var settings := terrain.get_vt_settings()
	avt_cpu_peak_ms = maxf(avt_cpu_peak_ms, float(settings.get("avt_sector_stats", {}).get("cpu_update_ms", 0.0)))
	var producer: Dictionary = settings.get("producer", {})
	var generation := int(producer.get("generation", -1))
	var produced := int(producer.get("baked_pages", 0)) + int(producer.get("cached_uploads", 0))
	if generation == last_generation:
		peak_produced = maxi(peak_produced, produced - last_produced)
		require(produced - last_produced <= 16, "AVT and SVT must share the sixteen-page production limit")
	last_generation = generation
	last_produced = produced

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1: output_dir = args[1]
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_page_count = 256
	terrain.vt_pages_per_update = 16
	terrain.surface_vt_texels_per_meter = 1024
	terrain.surface_svt_texels_per_meter = 1
	terrain.surface_svt_auto_bake = false
	DirAccess.make_dir_recursive_absolute("res://navigation_terrain")
	terrain.data_directory = "res://navigation_terrain"
	scene.add_child(terrain)
	root.add_child(scene)
	add_assets()
	for rz in range(-1, 2):
		for rx in range(-1, 2):
			var location := Vector2i(rx, rz)
			terrain.data.add_region_blank(location)
			var heights := PackedFloat32Array()
			heights.resize(512 * 512)
			for z in 512:
				for x in 512:
					var h := 64.0 * exp(-pow((rx * 512 + x + 12.0) / 22.0, 2.0) - pow((rz * 512 + z - 232.0) / 32.0, 2.0))
					heights[z * 512 + x] = h if h > 0.005 else 0.0
			terrain.data.get_region(location).set_height_map(Image.create_from_data(512, 512, false, Image.FORMAT_RF, heights.to_byte_array()))
	terrain.data.calc_height_range(true)
	terrain.data.update_maps()
	camera = Camera3D.new()
	camera.position = Vector3(4, 10, 280)
	camera.current = true
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = true
	terrain.set_physics_process(false)
	terrain.bake_svt()
	for frame in 1200:
		await tick()
		if terrain.get_vt_settings().bake_pending == 0: break
	var bake := terrain.get_vt_settings()
	require(bake.bake_pending == 0 and bake.bake_failed == 0 and bake.bake_done == 9, "all nine SVT cells must be baked before navigation")

	cpu_peak_us = 0
	cpu_total_us = 0
	cpu_frames = 0
	avt_cpu_peak_ms = 0.0
	var turn := 0
	for yaw in [-90, 0, 90, 180]:
		for pitch in [-30, 0, 30, 60]:
			camera.position = Vector3(4, 0, 280)
			camera.position.y = ground_height(camera.position) + 2.0
			camera.rotation_degrees = Vector3(pitch, yaw, 0)
			terrain.snap()
			for frame in 90: await tick()
			var image := root.get_texture().get_image()
			var missing := missing_pixels(image)
			print("VT_NAVIGATION view=",turn," missing_pixels=",missing)
			if missing > 0:
				image.save_png(output_dir.path_join("navigation_%d.png" % turn))
				print("VT_NAVIGATION stats=",terrain.get_vt_settings())
			require(missing == 0, "uphill/horizon view must not retain missing pages")
			turn += 1

	for position in [Vector3(4, 0, 300), Vector3(-6, 0, 280), Vector3(-26, 0, 270)]:
		camera.position = position
		camera.position.y = ground_height(camera.position) + 2.0
		camera.look_at(Vector3(-12, 64, 232))
		terrain.snap()
		for frame in 90: await tick()
		for frame in 120:
			camera.position.x += 0.12
			camera.position.z -= 0.08
			camera.position.y = ground_height(camera.position) + 2.0
			camera.look_at(Vector3(-12, 64, 232))
			terrain.snap()
			await tick()
			if frame % 15 == 14:
				var image := root.get_texture().get_image()
				var missing := missing_pixels(image)
				print("VT_NAVIGATION path=", position, " moving_frame=",frame," missing_pixels=",missing)
				if missing > 0:
					image.save_png(output_dir.path_join("moving_%d_%d.png" % [int(position.x), frame]))
					print("VT_NAVIGATION moving_stats=", terrain.get_vt_settings())
				require(missing == 0, "continuous movement must keep producing visible material pages")
		for frame in 30: await tick()
		require(missing_pixels(root.get_texture().get_image()) == 0, "movement must recover within thirty frames")
	print("VT_NAVIGATION peak_produced=", peak_produced, " capacity=", terrain.vt_page_count,
		" avt_cpu_peak_ms=", avt_cpu_peak_ms, " physics_cpu_peak_ms=", cpu_peak_us / 1000.0,
		" physics_cpu_average_ms=", cpu_total_us / (1000.0 * maxi(1, cpu_frames)),
		" migrated_pages=", terrain.get_vt_settings().get("producer", {}).get("migrated_pages", 0))
	# Enabling VT delivery turns this node's own tick back on (`terrain_3d_surface_views.cpp`), so
	# the manual physics notifications above are the only tick while the test runs. Stop it again
	# before the camera goes: a tick with the camera freed cannot find a clipmap target and the
	# engine logs that as an error, which the runner counts against the test.
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	if not failed: print("PASS uphill and moving VT residency without substitution")
	quit(1 if failed else 0)
