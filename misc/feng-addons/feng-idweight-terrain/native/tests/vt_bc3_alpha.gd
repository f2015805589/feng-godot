## GPU storage regression for the BC3/BC4 alpha index stream.
##
## The source pattern is baked into a real material page, the page is encoded by the
## production compute pass, and the page is exported back through the engine's compressed
## array decoder.  Comparing that page with the same page in the uncompressed array keeps
## this test independent of a second BC3 implementation in the test itself.
extends SceneTree

const REGION_SIZE := 64
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const PAGE_COUNT := 64
const BC3 := 2

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func producer_stats() -> Dictionary:
	return terrain.get_vt_settings().get("producer", {})

func material_word(id: int) -> int:
	return (id << 11) | (id << 6)

func make_alpha_pattern(size: int) -> ImageTexture:
	# A diagonal 0..1 ramp keeps every 4x4 output block away from a constant channel,
	# even if the bake selects either horizontal projection axis.  The relatively high UV
	# scale repeats that ramp across a page, so the test exercises many alpha blocks.
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var alpha := float(x + y) / float(maxi(1, (size - 1) * 2))
			image.set_pixel(x, y, Color(0.35, 0.35, 0.35, alpha))
	return ImageTexture.create_from_image(image)

func make_normal(size: int) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.5, 0.5, 1.0, 1.0))
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

func configure() -> void:
	terrain.region_size = REGION_SIZE
	terrain.vt_auto_capacity = false
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = PAGE_COUNT
	terrain.vt_pages_per_update = 16
	terrain.surface_vt_pages_per_axis = 8
	terrain.surface_vt_distance = 512.0
	terrain.surface_vt_region_grid = Vector2i.ONE
	terrain.surface_vt_selection_mode = 1
	terrain.surface_vt_adaptive_enabled = false
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	terrain.data.add_region_blank(Vector2i.ZERO)
	fill_region(Vector2i.ZERO, 0)
	terrain.data.update_maps()

func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	var asset := Terrain3DTextureAsset.new()
	asset.set_uv_scale(0.5)
	asset.albedo_texture = make_alpha_pattern(64)
	asset.normal_texture = make_normal(64)
	terrain.assets.set_texture_asset(0, asset)

func produce(frames: int) -> void:
	for _frame in frames:
		terrain.update_surface_vt(64)
		await process_frame

func wait_for_pages(max_frames: int = 360) -> bool:
	for _frame in max_frames:
		terrain.update_surface_vt(64)
		await process_frame
		var stats := producer_stats()
		if int(stats.get("pending", 1)) == 0 and int(stats.get("ready_pages", 0)) > 0:
			return true
	return false

func first_page() -> Dictionary:
	for slot in PAGE_COUNT:
		var preview: Image = terrain.get_vt_page_preview(slot)
		if preview != null and preview.get_width() == PAGE_SIZE + PAGE_BORDER * 2:
			return {"slot": slot, "image": preview}
	return {}

func alpha_comparison(reference: Image, candidate: Image) -> Dictionary:
	var all_max := 0.0
	var tail_max := 0.0
	var tail_min := 1.0
	var tail_max_value := 0.0
	var tail_large := 0
	var tail_samples := 0
	for y in range(PAGE_BORDER, reference.get_height() - PAGE_BORDER):
		for x in range(PAGE_BORDER, reference.get_width() - PAGE_BORDER):
			all_max = maxf(all_max, absf(reference.get_pixel(x, y).a - candidate.get_pixel(x, y).a))
	# The encoder's 4x4 block origin is the stored image origin, including the gutter.
	var blocks := ceili(float(reference.get_width()) / 4.0)
	for by in blocks:
		for bx in blocks:
			for index in range(11, 16):
				var x := bx * 4 + index % 4
				var y := by * 4 + (index >> 2)
				if x < PAGE_BORDER or y < PAGE_BORDER or x >= reference.get_width() - PAGE_BORDER or y >= reference.get_height() - PAGE_BORDER:
					continue
				var reference_alpha := reference.get_pixel(x, y).a
				var error := absf(reference_alpha - candidate.get_pixel(x, y).a)
				tail_max = maxf(tail_max, error)
				tail_min = minf(tail_min, reference_alpha)
				tail_max_value = maxf(tail_max_value, reference_alpha)
				if error > 0.18:
					tail_large += 1
				tail_samples += 1
	return {
		"all_max": all_max,
		"tail_max": tail_max,
		"tail_range": tail_max_value - tail_min,
		"tail_large": tail_large,
		"tail_samples": tail_samples,
	}

func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	DirAccess.make_dir_recursive_absolute("user://vt_bc3_alpha_data")
	terrain.data_directory = "user://vt_bc3_alpha_data"
	scene.add_child(terrain)
	root.add_child(scene)
	add_materials()

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.position = Vector3(32.0, 180.0, 32.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.size = 64.0
	camera.current = true
	root.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	configure()
	await process_frame
	terrain.surface_vt_enabled = true
	terrain.set_surface_vt_force_mip(true, 0)

	# First capture the exact page in the uncompressed staging array.
	terrain.vt_atlas_compression = Terrain3D.SURFACE_PAGE_UNCOMPRESSED
	var produced := await wait_for_pages()
	require(produced, "the uncompressed fixture must produce a material page")
	await produce(30)
	var baseline_page := first_page()
	require(not baseline_page.is_empty(), "the uncompressed fixture must export a page")
	if baseline_page.is_empty():
		quit(1)
		return
	var baseline_slot := int(baseline_page["slot"])
	var baseline: Image = baseline_page["image"]

	var before_encode := int(producer_stats().get("encode_requests", 0))
	terrain.vt_atlas_compression = BC3
	var applied := false
	for _frame in 360:
		terrain.update_surface_vt(64)
		await process_frame
		var settings := terrain.get_vt_settings()
		var stats := producer_stats()
		if int(settings.get("vt_atlas_compression_applied", 0)) == BC3 and int(stats.get("pending", 1)) == 0 and int(stats.get("ready_pages", 0)) > 0:
			applied = true
			break
	require(applied, "BC3 must be applied to the live page arrays")
	await produce(30)

	var compressed: Image = terrain.get_vt_page_preview(baseline_slot)
	if compressed == null or compressed.get_width() != baseline.get_width():
		var fallback := first_page()
		if not fallback.is_empty():
			compressed = fallback["image"]
	require(compressed != null and compressed.get_width() == baseline.get_width(),
				"the GPU-compressed page must be exportable")
	if compressed == null or compressed.get_width() != baseline.get_width():
		quit(1)
		return

	var comparison := alpha_comparison(baseline, compressed)
	var after_encode := int(producer_stats().get("encode_requests", 0))
	print("VT_BC3_ALPHA slot=%d encode_requests=%d->%d applied=%d comparison=%s" % [
			baseline_slot, before_encode, after_encode,
			int(terrain.get_vt_settings().get("vt_atlas_compression_applied", 0)), str(comparison)])
	require(after_encode > before_encode, "the test must exercise a real GPU block encode")
	require(int(producer_stats().get("encode_failures", 0)) == 0, "the BC3 encode must not fail")
	require(int(comparison["tail_samples"]) > 8, "the alpha fixture must cover encoded tail indices")
	require(float(comparison["tail_range"]) > 0.25, "the alpha fixture must vary across encoded tail indices")
	# Correct BC3 alpha quantisation stays within the normal 8-level interpolation error;
	# the old 32-bit index stream decoded indices 11..15 as endpoint 0 and exceeded this
	# bound on the same real page.
	require(float(comparison["tail_max"]) < 0.18 and int(comparison["tail_large"]) == 0,
			"BC3 alpha tail indices must survive the GPU encoder: %s" % str(comparison))

	scene.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS GPU BC3 alpha preserves the full 48-bit index stream")
	quit(0)
