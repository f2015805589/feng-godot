## GPU regression for the compressed material page arrays.
##
## The atlas compression setting must be a storage decision only: a page that renders
## from the uncompressed staging arrays must render the same material from the
## compressed arrays, at the same production rate, with no CPU readback of the page.
## This test drives the real renderer, because the resolver test (vt_compression.gd)
## cannot see a compressed array that is never filled.
extends SceneTree

const REGION_SIZE := 64
const GRID := 8
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const NEAR_WORLD := Vector2(96.0, 96.0) # region (1, 1), material 1
const FAR_WORLD := Vector2(224.0, 224.0) # region (3, 3), material 1

const BC7 := 1
const BC3 := 3

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false
var output_dir := "user://"

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func material_word(id: int) -> int:
	return (id << 11) | (id << 6)

func make_pattern(size: int, a: Color, b: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var checker := ((x / 8 + y / 8) & 1) == 0
			var gradient := float(x + y) / float(maxi(1, (size - 1) * 2))
			var color := a.lerp(b, 0.25 + gradient * 0.45)
			if not checker:
				color = color.lerp(b, 0.35)
			image.set_pixel(x, y, color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func make_normal(size: int) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var n := 0.5 + 0.08 * sin(float(x) * 0.35) * cos(float(y) * 0.27)
			image.set_pixel(x, y, Color(n, 0.5, 1.0, 1.0))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func fill_region(location: Vector2i, id: int) -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var word := material_word(id)
	for i in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(i * 2, word)
	var region: Terrain3DRegion = terrain.data.get_region(location)
	region.set_surface_map(Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func frame_image(wait_frames: int = 6) -> Image:
	for _i in wait_frames:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func set_view(world: Vector2, height: float, size: float) -> void:
	camera.position = Vector3(world.x, height, world.y)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.size = size
	camera.current = true
	terrain.set_clipmap_target(camera)
	await process_frame

func screen_of(image: Image, world: Vector2) -> Vector2i:
	var screen := camera.unproject_position(Vector3(world.x, 0.0, world.y))
	return Vector2i(clampi(int(screen.x), 0, image.get_width() - 1), clampi(int(screen.y), 0, image.get_height() - 1))

func patch_stats(image: Image, world: Vector2, radius: int = 18) -> Dictionary:
	var center := screen_of(image, world)
	var black := 0
	var magenta := 0
	var total := 0
	var luminance := 0.0
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			var pixel := image.get_pixel(clampi(x, 0, image.get_width() - 1), clampi(y, 0, image.get_height() - 1))
			var peak := maxf(pixel.r, maxf(pixel.g, pixel.b))
			if peak < 0.01:
				black += 1
			if pixel.r > 0.42 and pixel.b > 0.42 and pixel.g < 0.28:
				magenta += 1
			luminance += pixel.r * 0.2126 + pixel.g * 0.7152 + pixel.b * 0.0722
			total += 1
	return {
		"black": float(black) / float(total),
		"magenta": float(magenta) / float(total),
		"mean": luminance / float(total),
	}

func producer_stats() -> Dictionary:
	return terrain.get_vt_settings().get("producer", {})

## Pages handed to the producer since the baker was configured: a bake dispatch, a cached
## upload, or a cell copy. Cumulative, so a delta over one demand pass is that pass's rate.
func produced_pages() -> int:
	var stats := producer_stats()
	return int(stats.get("baked_pages", 0)) + int(stats.get("cached_uploads", 0))

func wait_ready_pages(target: int, max_frames: int = 240) -> int:
	var ready := 0
	for _i in max_frames:
		await process_frame
		ready = int(producer_stats().get("ready_pages", 0))
		if ready >= target:
			break
	return ready

func wait_pending_empty(max_frames: int = 240) -> bool:
	for _i in max_frames:
		await process_frame
		var stats := producer_stats()
		if int(stats.get("pending", 1)) == 0 and int(stats.get("ready_pages", 0)) > 0:
			return true
	return false

func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	var dark := Terrain3DTextureAsset.new()
	dark.albedo_texture = make_pattern(64, Color(0.035, 0.045, 0.055), Color(0.16, 0.10, 0.06))
	dark.normal_texture = make_normal(64)
	terrain.assets.set_texture_asset(0, dark)
	var bright := Terrain3DTextureAsset.new()
	bright.albedo_texture = make_pattern(64, Color(0.16, 0.72, 0.08), Color(0.95, 0.24, 0.04))
	bright.normal_texture = make_normal(64)
	terrain.assets.set_texture_asset(1, bright)

func configure_terrain() -> void:
	terrain.region_size = REGION_SIZE
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = 128
	terrain.vt_pages_per_update = 16
	terrain.surface_vt_pages_per_axis = 8
	terrain.surface_vt_distance = 512.0
	terrain.surface_svt_page_world = float(REGION_SIZE)
	terrain.surface_svt_distance = 512.0
	terrain.surface_svt_root_mips = 0
	terrain.surface_vt_region_grid = Vector2i(1, 1)
	terrain.surface_vt_selection_mode = 1
	for z in GRID:
		for x in GRID:
			var location := Vector2i(x, z)
			terrain.data.add_region_blank(location)
			fill_region(location, 1 if location == Vector2i(1, 1) or location == Vector2i(3, 3) else 0)
	terrain.data.update_maps()
## One production burst: enough explicit demand passes to fill the pool, then the idle
## frames the callback needs to finish whatever it queued.
func produce(frames: int) -> void:
	for _frame in frames:
		terrain.update_surface_vt(64)
		terrain.update_surface_svt(64)
		await process_frame

func compare_patch(baseline: Image, candidate: Image, world: Vector2, label: String) -> void:
	var expected := patch_stats(baseline, world)
	var got := patch_stats(candidate, world)
	var black_limit := maxf(0.04, float(expected["black"]) + 0.04)
	var delta := absf(float(expected["mean"]) - float(got["mean"]))
	print("VTCOMPRESS_RENDER_PATCH ", label, " baseline=", expected, " candidate=", got, " delta=%.4f" % delta)
	require(float(got["black"]) <= black_limit, label + " became black with compression on")
	require(float(got["magenta"]) < 0.02, label + " displayed missing-page diagnostics with compression on")
	require(delta < 0.10, label + " changed too far from the array baseline (delta %.4f)" % delta)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	DirAccess.make_dir_recursive_absolute("user://terrain")
	terrain.data_directory = "user://terrain"
	scene.add_child(terrain)
	root.add_child(scene)
	add_materials()
	camera = Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	configure_terrain()

	await set_view(NEAR_WORLD, 180.0, 96.0)
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = true
	await produce(90)
	await wait_pending_empty()
	if failed:
		quit(1)
		return
	var ready_before := int(producer_stats().get("ready_pages", 0))
	var baseline_near := await frame_image()
	baseline_near.save_png(output_dir.path_join("compressed-baseline-near.png"))
	var near_base := patch_stats(baseline_near, NEAR_WORLD)
	require(float(near_base["mean"]) > 0.03, "near baseline material is unexpectedly black")
	print("VTCOMPRESS_RENDER baseline ready=%d stats=%s" % [ready_before, str(producer_stats())])

	await set_view(FAR_WORLD, 220.0, 144.0)
	await produce(60)
	await wait_pending_empty()
	var baseline_far := await frame_image()
	baseline_far.save_png(output_dir.path_join("compressed-baseline-far.png"))
	var far_base := patch_stats(baseline_far, FAR_WORLD, 14)
	require(float(far_base["mean"]) > 0.03, "far baseline material is unexpectedly black")

	# Both alpha-capable codecs, because the failure is about the storage path and not
	# about which of the two was chosen.
	for codec in [BC7, BC3]:
		terrain.vt_atlas_compression = codec
		await process_frame
		var resolved: Dictionary = terrain.get_vt_settings()
		var available := int(resolved.get("vt_atlas_compression_available", -1))
		var reason := String(resolved.get("vt_atlas_compression_reason", ""))
		print("VTCOMPRESS_RENDER codec=%d available=%d reason='%s'" % [codec, available, reason])
		if available != codec:
			# A build without the codec cannot be asked to render from it; the resolver
			# test owns that verdict.
			print("VTCOMPRESS_RENDER skipped codec %d: %s" % [codec, reason])
			continue
		# Re-demand the working set so the compressed arrays are actually filled.
		await produce(120)
		await wait_pending_empty()
		await set_view(NEAR_WORLD, 180.0, 96.0)
		await produce(40)
		var compressed_near := await frame_image()
		compressed_near.save_png(output_dir.path_join("compressed-codec%d-near.png" % codec))
		compare_patch(baseline_near, compressed_near, NEAR_WORLD, "near codec %d" % codec)

		await set_view(FAR_WORLD, 220.0, 144.0)
		await produce(40)
		var compressed_far := await frame_image()
		compressed_far.save_png(output_dir.path_join("compressed-codec%d-far.png" % codec))
		compare_patch(baseline_far, compressed_far, FAR_WORLD, "far codec %d" % codec)
		print("VTCOMPRESS_RENDER codec=%d ready=%d stats=%s" % [
				codec, int(producer_stats().get("ready_pages", 0)), str(producer_stats())])

	# Production must keep the caller's rate: the budget is a setting, not a codec
	# property. The pool is emptied by a format change, then the camera is stepped across a
	# world that demands many more pages than the budget, and the largest production of a
	# single frame is measured. That is the callback's budget: with the old four-page cap
	# the compressed format could not exceed 4 while the uncompressed one reached 16.
	var budget := 16
	terrain.surface_vt_enabled = false
	terrain.vt_auto_capacity = false
	terrain.vt_page_count = 64
	terrain.vt_pages_per_update = budget
	terrain.surface_svt_page_world = 32.0
	terrain.surface_svt_distance = 1024.0
	var peak := {}
	for mode in [BC7, 0]:
		terrain.vt_atlas_compression = mode
		await set_view(Vector2(256.0, 256.0), 60.0, 512.0)
		for _frame in 8:
			terrain.update_surface_svt(64)
			await process_frame
		var best := 0
		for step in 10:
			await set_view(Vector2(256.0 + step * 48.0, 256.0 + step * 32.0), 60.0, 512.0)
			var before := produced_pages()
			terrain.update_surface_svt(64)
			await process_frame
			best = maxi(best, produced_pages() - before)
		peak[mode] = best
		print("VTCOMPRESS_RENDER rate mode=%d pages_per_frame=%d ready=%d visible=%s" % [
				mode, best, int(producer_stats().get("ready_pages", 0)),
				str(terrain.get_vt_settings().get("svt_visible_pages"))])
	require(int(peak.get(BC7, 0)) == int(peak.get(0, 0)),
			"compression must not lower the production rate (BC7 %d vs uncompressed %d pages per frame)" % [
				int(peak.get(BC7, 0)), int(peak.get(0, 0))])
	# The compressed path used to cap the budget at four pages per frame, so a demand-driven
	# rate above that in both formats is what proves the budget alone decides the rate.
	require(int(peak.get(0, 0)) > 4,
			"a demand pass must not be capped below the demand (%d pages of a %d page budget)" % [
				int(peak.get(0, 0)), budget])

	terrain.vt_atlas_compression = 0
	await process_frame
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS compressed material pages render and keep the production rate")
	quit()
