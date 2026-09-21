## GPU regression for the far field's fallback. Two policies, each on its own contract: the root
## pyramid (default) covers the whole addressable domain, and the per-unit guarantee covers the units
## the visible set selected. The pyramid is what answers a fragment whose selected far-field page is
## missing or still in production, and it is only a fallback where its pages actually are. The
## candidate set used to be the whole SVT domain - which is thousands of pages at a level the view
## selects - and the protection budget then truncated it in row-major order, so every pinned root sat
## in one corner of the map and the fallback answered nowhere near the camera. This test asserts
## coverage geometrically, asserts that every pinned root has content, and asserts that a settled view
## stops producing - then switches to the per-unit policy and asserts that one's own, weaker promise.
extends SceneTree

const REGION_SIZE := 64
const GRID := 12
const PAGE_WORLD := 64.0
const PAGE_SIZE := 16
const PAGE_BORDER := 1
const PAGE_COUNT := 64
# Forces a coarse detail hierarchy, so the candidate root set at the coarse level is far
# larger than the protection budget: that is the shape the truncation bug needed.
const MAX_MIP := 3
const REACH := 2048.0
const CENTER_WORLD := Vector2(384.0, 384.0)

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

func patch_stats(image: Image, world: Vector2, radius: int = 12) -> Dictionary:
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

func settings() -> Dictionary:
	return terrain.get_vt_settings()

## Slots the far field pinned at the coarsest planned levels, with whether the producer
## holds content for them. A pinned root without content is the fallback that renders the
## diagnostic, which is what a published-but-never-produced page looks like.
func root_records(level_min: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in terrain.get_vt_pages():
		if String(record.get("kind", "")) != "SVT":
			continue
		if int(record.get("mip", -1)) < level_min:
			continue
		var owners: Array = record.get("owners", [])
		var world_space := false
		for owner: Dictionary in owners:
			if bool(owner.get("world_space", false)):
				world_space = true
		if not world_space:
			continue
		result.append(record)
	return result

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

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
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

	terrain.region_size = REGION_SIZE
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = PAGE_COUNT
	terrain.vt_pages_per_update = 16
	terrain.surface_svt_page_world = PAGE_WORLD
	terrain.surface_svt_distance = REACH
	terrain.surface_svt_max_mip = MAX_MIP
	terrain.surface_svt_root_mips = 2
	terrain.surface_svt_feedback = true
	for z in GRID:
		for x in GRID:
			var location := Vector2i(x, z)
			terrain.data.add_region_blank(location)
			fill_region(location, 1 if (x + z) % 2 == 0 else 0)
	terrain.data.update_maps()

	await set_view(CENTER_WORLD, 400.0, float(GRID * REGION_SIZE))
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = true
	# Startup must render the live source material while protected roots are still pending,
	# never the full-screen missing-page checker.
	terrain.update_surface_svt(PAGE_COUNT)
	var startup := await frame_image(1)
	var startup_stats := patch_stats(startup, CENTER_WORLD)
	print("VTROOTCOVER startup=", startup_stats)
	require(float(startup_stats["magenta"]) < 0.02,
			"SVT startup must not expose the missing-page checker")
	for _frame in 150:
		terrain.update_surface_svt(PAGE_COUNT)
		await process_frame

	var far_world := CENTER_WORLD + Vector2(300.0, 0.0)
	var far := await frame_image()
	far.save_png(output_dir.path_join("root-coverage-far.png"))
	var far_stats := patch_stats(far, far_world)
	var info := settings()
	var coverage: Rect2 = info.get("svt_root_coverage", Rect2())
	var roots := int(info.get("svt_root_pages", 0))
	var level_min := int(info.get("svt_root_level_min", -1))
	var level_max := int(info.get("svt_root_level_max", -1))
	var svt: Terrain3DVirtualTexture = terrain.get_surface_svt()
	var domain := float(svt.get_indirection_size()) * PAGE_WORLD
	print("VTROOTCOVER cam=%s coverage=%s roots=%d levels=%d..%d domain=%.0f patch=%s" % [
			str(CENTER_WORLD), str(coverage), roots, level_min, level_max, domain, str(far_stats)])

	require(roots > 0, "the far field must pin a root pyramid")
	require(level_min >= 0 and level_min <= level_max, "the root set must name a level window")
	# The contract the whole domain depends on: any world position resolves through the
	# pyramid, so the pinned set has to cover the entire SVT domain, not a corner of it.
	require(coverage.has_point(CENTER_WORLD),
			"the root pyramid must cover the camera, got %s for %s" % [str(coverage), str(CENTER_WORLD)])
	require(coverage.has_point(far_world),
			"the root pyramid must cover the visible far field, got %s for %s" % [str(coverage), str(far_world)])
	require(coverage.has_point(Vector2(-domain * 0.45, -domain * 0.45)) and
			coverage.has_point(Vector2(domain * 0.45, domain * 0.45)),
			"the root pyramid must cover the whole SVT domain, got %s of %.0f metres" % [str(coverage), domain])
	require(roots <= PAGE_COUNT / 2,
			"the root pyramid must stay inside the protection budget (%d roots of %d pages)" % [roots, PAGE_COUNT])
	require(float(far_stats["magenta"]) < 0.02,
			"the far field must not show the missing-page diagnostic")

	var records := root_records(level_min)
	var ready := 0
	for record: Dictionary in records:
		if bool(record.get("ready", false)):
			ready += 1
	print("VTROOTCOVER pinned=%d ready=%d roots=%d" % [records.size(), ready, roots])
	require(records.size() > 0, "the pinned roots must be reported as pages")
	require(ready == records.size(),
			"every pinned root must have content, %d of %d were ready" % [ready, records.size()])

	# A settled view must stop producing: the roots are resident, so the retry never fires.
	var before := int(settings().get("svt_requeues", 0))
	for _frame in 60:
		terrain.update_surface_svt(PAGE_COUNT)
		await process_frame
	var after := int(settings().get("svt_requeues", 0))
	print("VTROOTCOVER settled requeues=%d->%d skips=%s passes=%s" % [before, after,
			str(settings().get("svt_root_skips", 0)), str(settings().get("svt_root_passes", 0))])
	require(after == before,
			"a settled far field must not re-produce pages every pass (requeues %d -> %d)" % [before, after])

	# The other fallback policy, H2 of `docs/vt_hdrp_avt_alignment.md`: the coarsest level the world
	# grid can express, for every unit the visible set selected, instead of one complete level window
	# over the whole addressable domain.
	#
	# It is a different **contract**, not a different threshold, and that is why this pass asserts its
	# own terms rather than the ones above: the pyramid's promise is that any world position resolves,
	# which is what lets the region array be unnecessary, and a unit-local guarantee deliberately does
	# not make that promise. Section 9 of the alignment document forbids relaxing an assertion to make
	# a phase pass, so the pyramid's domain assertions above are untouched and the domain the
	# alternative does not claim is *printed*, not asserted away.
	terrain.surface_svt_fallback_policy = 1
	for _frame in 150:
		terrain.update_surface_svt(PAGE_COUNT)
		await process_frame
	var alt := await frame_image()
	var alt_stats := patch_stats(alt, far_world)
	var alt_info := settings()
	var alt_coverage: Rect2 = alt_info.get("svt_root_coverage", Rect2())
	var alt_roots := int(alt_info.get("svt_root_pages", 0))
	print("VTROOTCOVER perunit coverage=%s roots=%d pyramid_roots=%d domain_covered=%s patch=%s" % [
			str(alt_coverage), alt_roots, roots,
			str(alt_coverage.has_point(Vector2(-domain * 0.45, -domain * 0.45))), str(alt_stats)])
	require(alt_roots > 0, "the per-unit policy must pin the visible units' coarsest pages")
	require(alt_roots < roots, "the per-unit set must be smaller than the domain pyramid (%d vs %d)" % [alt_roots, roots])
	require(alt_coverage.has_point(CENTER_WORLD), "the per-unit fallback must cover the camera")
	require(alt_coverage.has_point(far_world), "the per-unit fallback must cover the visible far field")
	require(float(alt_stats["magenta"]) < 0.02,
			"the per-unit fallback must not show the missing-page diagnostic in the visible field")

	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS far-field root pyramid covers the visible field")
	quit()
