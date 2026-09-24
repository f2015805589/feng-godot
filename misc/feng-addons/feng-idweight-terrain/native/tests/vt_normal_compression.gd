## GPU regression for independent diffuse and signed-normal page codecs.
##
## The normal view is intentionally rendered through the terrain material rather than
## reading an exported page.  That keeps this test on the complete path under test:
## the baker's normal transform, BC5/BC3N block encoder, page binding, shader decode,
## and PBR debug view.  The roughness view similarly proves that the parameter page's
## encoded alpha survives when either channel is compressed.
extends "res://vt_scene_base.gd"

const REGION_SIZE := 64
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const PAGE_COUNT := 128
const TARGET := Vector2(32.0, 32.0)

const DIFFUSE_UNCOMPRESSED := 0
const DIFFUSE_BC7 := 1
const DIFFUSE_BC3 := 2
const NORMAL_BC5 := 1
const NORMAL_BC3N := 2
const AVT_DIFFUSE_KEY := "surface_vt_diffuse_compression"
const AVT_NORMAL_KEY := "surface_vt_normal_compression"
const SVT_DIFFUSE_KEY := "surface_svt_diffuse_compression"
const SVT_NORMAL_KEY := "surface_svt_normal_compression"

var scene: Node3D
var output_dir := "user://"

func _initialize() -> void:
	call_deferred("run")

func make_albedo(size: int) -> ImageTexture:
	# A coloured gradient makes the independent diffuse codec observable as well as
	# keeping the page's material distinct from a missing-page diagnostic.
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var u := float(x) / float(maxi(1, size - 1))
			var v := float(y) / float(maxi(1, size - 1))
			var checker := 0.10 if ((x / 8 + y / 8) & 1) == 0 else 0.0
			image.set_pixel(x, y, Color(
				clampf(0.12 + 0.72 * u + checker, 0.0, 1.0),
				clampf(0.12 + 0.62 * (1.0 - v) + checker * 0.5, 0.0, 1.0),
				clampf(0.10 + 0.52 * (0.5 * u + 0.5 * v), 0.0, 1.0), 1.0))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func make_normal_and_roughness(size: int) -> ImageTexture:
	# RGB is a standard tangent-space normal map.  Red/green carry the two signed tilts;
	# blue is the positive reconstructed height.  After the shader's xzy swizzle these
	# become world-plane X/Z, and normal_depth=1.8 makes both signs easy to observe without
	# exceeding the unit disk.  Alpha is a broad roughness ramp, so params-page encoding
	# is measured too.
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var u := float(x) / float(maxi(1, size - 1))
			var v := float(y) / float(maxi(1, size - 1))
			var nx := 0.30 * sin(u * TAU * 4.0)
			var nz := 0.30 * cos(v * TAU * 4.0)
			var normal_height := sqrt(maxf(0.0, 1.0 - nx * nx - nz * nz))
			var roughness := 0.08 + 0.84 * (0.5 * u + 0.5 * v)
			image.set_pixel(x, y, Color(0.5 + 0.5 * nx, 0.5 + 0.5 * nz,
				0.5 + 0.5 * normal_height, roughness))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func fill_region() -> void:
	var bytes := PackedByteArray()
	bytes.resize(REGION_SIZE * REGION_SIZE * 2)
	var word := material_word(0)
	for i in REGION_SIZE * REGION_SIZE:
		bytes.encode_u16(i * 2, word)
	var region: Terrain3DRegion = terrain.data.get_region(Vector2i.ZERO)
	region.set_surface_map(Image.create_from_data(REGION_SIZE, REGION_SIZE, false, Image.FORMAT_R16, bytes))
	region.set_edited(true)

func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	# Keep the authored source exact.  This regression isolates page codecs from the
	# optional authoring-array codec, especially because normal signs and alpha matter.
	terrain.assets.texture_array_compression = Terrain3DAssets.ARRAY_UNCOMPRESSED
	var asset := Terrain3DTextureAsset.new()
	asset.albedo_texture = make_albedo(128)
	asset.normal_texture = make_normal_and_roughness(128)
	asset.normal_depth = 1.8
	asset.uv_scale = 0.5
	terrain.assets.set_texture_asset(0, asset)

func configure_terrain() -> void:
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
	terrain.surface_vt_feedback = false
	terrain.surface_svt_page_world = float(REGION_SIZE)
	terrain.surface_svt_distance = 512.0
	terrain.surface_svt_root_mips = 0
	terrain.vt_page_fade_frames = 0
	terrain.surface_svt_auto_bake = false
	terrain.data.add_region_blank(Vector2i.ZERO)
	fill_region()
	terrain.data.update_maps()

func frame_image(wait_frames: int = 8) -> Image:
	for _i in wait_frames:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func producer_stats() -> Dictionary:
	var settings: Dictionary = terrain.get_vt_settings()
	return settings.get("producer", {})

func tier_key(tier: String, suffix: String) -> String:
	if tier == "avt":
		return AVT_DIFFUSE_KEY if suffix == "diffuse_compression" else AVT_NORMAL_KEY
	return SVT_DIFFUSE_KEY if suffix == "diffuse_compression" else SVT_NORMAL_KEY

func tier_storage(tier: String) -> Dictionary:
	var settings: Dictionary = terrain.get_vt_settings()
	return settings.get("avt_storage" if tier == "avt" else "svt_storage", {})

func set_mode(tier: String, diffuse: int, normal: int) -> void:
	terrain.set(tier_key(tier, "diffuse_compression"), diffuse)
	terrain.set(tier_key(tier, "normal_compression"), normal)

func produce_frame(tier: String) -> void:
	if tier == "avt":
		terrain.update_surface_vt(64)
	else:
		terrain.update_surface_svt(64)

func wait_mode(tier: String, diffuse: int, normal: int, max_frames: int = 420) -> bool:
	var diffuse_key := tier_key(tier, "diffuse_compression")
	var normal_key := tier_key(tier, "normal_compression")
	for _frame in max_frames:
		produce_frame(tier)
		await process_frame
		var settings: Dictionary = terrain.get_vt_settings()
		var storage: Dictionary = settings.get("avt_storage" if tier == "avt" else "svt_storage", {})
		if int(settings.get(diffuse_key, -99)) != diffuse or int(settings.get(normal_key, -99)) != -1:
			continue
		if int(storage.get("applied", -99)) != diffuse or int(storage.get("normal_applied", -99)) != normal:
			continue
		var stats: Dictionary = settings.get("producer", {})
		if int(stats.get("pending", 1)) == 0 and int(stats.get("ready_pages", 0)) > 0:
			return true
	return false

func set_debug_view(view: String) -> void:
	terrain.show_texture_albedo = view == "albedo"
	terrain.show_texture_normal = view == "normal"
	terrain.show_texture_rough = view == "rough"

func visual_stats(image: Image) -> Dictionary:
	# Read the whole central viewport.  This records channel extrema and per-channel
	# errors; a mean luminance comparison alone would miss a swapped/negated normal axis.
	var min_value := Vector3.ONE
	var max_value := Vector3.ZERO
	var sum := Vector3.ZERO
	var bad := 0
	var samples := 0
	var left := 16
	var right := image.get_width() - 16
	var top := 16
	var bottom := image.get_height() - 16
	for y in range(top, bottom):
		for x in range(left, right):
			var pixel := image.get_pixel(x, y)
			var value := Vector3(pixel.r, pixel.g, pixel.b)
			min_value.x = minf(min_value.x, value.x)
			min_value.y = minf(min_value.y, value.y)
			min_value.z = minf(min_value.z, value.z)
			max_value.x = maxf(max_value.x, value.x)
			max_value.y = maxf(max_value.y, value.y)
			max_value.z = maxf(max_value.z, value.z)
			sum += value
			if maxf(value.x, maxf(value.y, value.z)) < 0.01 or (value.x > 0.75 and value.z > 0.75 and value.y < 0.20):
				bad += 1
			samples += 1
	return {
		"min": min_value,
		"max": max_value,
		"mean": sum / float(maxi(1, samples)),
		"bad": float(bad) / float(maxi(1, samples)),
	}

func compare_view(reference: Image, candidate: Image, view: String, label: String) -> void:
	var expected := visual_stats(reference)
	var got := visual_stats(candidate)
	var e: Vector3 = expected["mean"]
	var c: Vector3 = got["mean"]
	var delta := Vector3(absf(e.x - c.x), absf(e.y - c.y), absf(e.z - c.z))
	var error_limit := 0.18 if view == "albedo" else 0.14
	var mean_limit := 0.07 if view == "albedo" else 0.045
	print("VT_NORMAL_COMPARE ", label, " view=", view, " baseline=", expected, " candidate=", got,
			" mean_error=", delta)
	require(float(got["bad"]) < 0.05, label + " " + view + " contains missing-page diagnostics")
	require(maxf(delta.x, maxf(delta.y, delta.z)) < mean_limit,
			label + " " + view + " changed per-channel mean too far: " + str(delta))
	# Extrema are intentionally checked separately from the mean.  A codec that writes
	# one normal axis with the wrong sign can preserve the mean while failing this bound.
	var expected_min: Vector3 = expected["min"]
	var got_min: Vector3 = got["min"]
	var expected_max: Vector3 = expected["max"]
	var got_max: Vector3 = got["max"]
	var min_error := Vector3(absf(expected_min.x - got_min.x), absf(expected_min.y - got_min.y),
			absf(expected_min.z - got_min.z))
	var max_error := Vector3(absf(expected_max.x - got_max.x), absf(expected_max.y - got_max.y),
			absf(expected_max.z - got_max.z))
	var pixel_error_sum := 0.0
	var pixel_error_peak := 0.0
	var pixel_samples := 0
	for y in range(16, reference.get_height() - 16):
		for x in range(16, reference.get_width() - 16):
			var a := reference.get_pixel(x, y)
			var b := candidate.get_pixel(x, y)
			var pixel_error := Vector3(absf(a.r - b.r), absf(a.g - b.g), absf(a.b - b.b))
			pixel_error_sum += (pixel_error.x + pixel_error.y + pixel_error.z) / 3.0
			pixel_error_peak = maxf(pixel_error_peak, maxf(pixel_error.x, maxf(pixel_error.y, pixel_error.z)))
			pixel_samples += 1
	var pixel_error_mean := pixel_error_sum / float(maxi(1, pixel_samples))
	print("VT_NORMAL_PIXEL_ERROR ", label, " view=", view, " mean=", pixel_error_mean,
			" peak=", pixel_error_peak)
	var pixel_mean_limit := 0.10 if view == "albedo" else 0.075
	require(pixel_error_mean < pixel_mean_limit,
			label + " " + view + " per-pixel RGB error is too high")
	require(maxf(max_error.x, maxf(max_error.y, max_error.z)) < error_limit and
			maxf(min_error.x, maxf(min_error.y, min_error.z)) < error_limit,
			label + " " + view + " channel extrema changed too far")

func capture_view(tier: String, mode_label: String, view: String) -> Image:
	set_debug_view(view)
	var image := await frame_image()
	image.save_png(output_dir.path_join("normal-%s-%s-%s.png" % [tier, mode_label, view]))
	return image

func check_normal_shape(image: Image, label: String) -> void:
	var metrics := visual_stats(image)
	var minimum: Vector3 = metrics["min"]
	var maximum: Vector3 = metrics["max"]
	print("VT_NORMAL_SHAPE ", label, " metrics=", metrics)
	# PBR_TEXTURE_NORMAL writes world X/Y/Z into RGB.  The authored pattern and depth
	# must therefore cross neutral in both X (red) and Z (blue), proving signed decode.
	require(minimum.x < 0.46 and maximum.x > 0.54,
			label + " normal view did not expose both signs of world X")
	require(minimum.z < 0.46 and maximum.z > 0.54,
			label + " normal view did not expose both signs of world Z")

func check_roughness_shape(image: Image, label: String) -> void:
	var metrics := visual_stats(image)
	var minimum: Vector3 = metrics["min"]
	var maximum: Vector3 = metrics["max"]
	print("VT_ROUGHNESS_SHAPE ", label, " metrics=", metrics)
	require(maximum.x - minimum.x > 0.30 and maximum.y - minimum.y > 0.30 and maximum.z - minimum.z > 0.30,
			label + " roughness view lost the authored gradient")

func check_storage(tier: String, diffuse: int, normal: int, label: String) -> void:
	var settings: Dictionary = terrain.get_vt_settings()
	var storage: Dictionary = settings.get("avt_storage" if tier == "avt" else "svt_storage", {})
	print("VT_NORMAL_STORAGE ", label, " settings=", settings, " storage=", storage)
	require(int(storage.get("normal_available", -99)) == normal,
			label + " normal codec did not resolve to the requested mode")
	require(int(storage.get("normal_applied", -99)) == normal,
			label + " normal codec was not applied to the live page array")
	require(int(storage.get("applied", -99)) == diffuse,
			label + " diffuse codec was not applied to the live page array")
	require(int(settings.get(tier_key(tier, "diffuse_compression"), -99)) == diffuse and
			int(settings.get(tier_key(tier, "normal_compression"), -99)) == -1,
			label + " tier settings are not independent")
	require(int(terrain.get_vt_settings().get("producer", {}).get("encode_failures", 0)) == 0,
			label + " GPU page encode reported a failure")

func run_tier(tier: String) -> void:
	terrain.surface_vt_enabled = tier == "avt"
	terrain.surface_svt_enabled = tier == "svt"
	if tier == "avt":
		terrain.set_surface_vt_force_mip(true, 0)
	await process_frame
	set_mode(tier, DIFFUSE_UNCOMPRESSED, DIFFUSE_UNCOMPRESSED)
	var raw_ready := await wait_mode(tier, DIFFUSE_UNCOMPRESSED, DIFFUSE_UNCOMPRESSED)
	require(raw_ready, tier + " raw page set did not become ready")
	check_storage(tier, DIFFUSE_UNCOMPRESSED, DIFFUSE_UNCOMPRESSED, tier + " raw")

	var raw_albedo := await capture_view(tier, "raw", "albedo")
	var raw_normal := await capture_view(tier, "raw", "normal")
	var raw_rough := await capture_view(tier, "raw", "rough")
	check_normal_shape(raw_normal, tier + " raw")
	check_roughness_shape(raw_rough, tier + " raw")

	# One tier property controls all three formats. Legacy normal writes cannot override it.
	for diffuse in [DIFFUSE_BC7, DIFFUSE_BC3, DIFFUSE_UNCOMPRESSED]:
		var normal := 3 if diffuse == DIFFUSE_BC7 else (2 if diffuse == DIFFUSE_BC3 else 0)
		set_mode(tier, diffuse, NORMAL_BC5)
		var ready := await wait_mode(tier, diffuse, normal)
		var label := "%s-unified%d" % [tier, diffuse]
		require(ready, label + " page set did not become ready")
		check_storage(tier, diffuse, normal, label)
		var storage := tier_storage(tier)
		require(int(storage.rd_format) == int(storage.normal_rd_format), label + " normal physical format differs")
		if diffuse != 0:
			require(int(storage.rd_format) == int(storage.params_rd_format), label + " parameter physical format differs")
		compare_view(raw_albedo, await capture_view(tier, label, "albedo"), "albedo", label)
		compare_view(raw_normal, await capture_view(tier, label, "normal"), "normal", label)
		compare_view(raw_rough, await capture_view(tier, label, "rough"), "rough", label)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	DirAccess.make_dir_recursive_absolute("user://vt_normal_compression_data")

	scene = Node3D.new()
	terrain = Terrain3D.new()
	for property in terrain.get_property_list():
		if property.name in ["surface_vt_normal_compression", "surface_svt_normal_compression", "surface_vt_diffuse_compression", "surface_svt_diffuse_compression"]:
			require((int(property.usage) & (PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE)) == 0, "legacy compression must not be exposed or serialized")

	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	terrain.data_directory = "user://vt_normal_compression_data"
	scene.add_child(terrain)
	root.add_child(scene)
	add_materials()
	configure_terrain()

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.position = Vector3(TARGET.x, 180.0, TARGET.y)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.size = REGION_SIZE
	camera.near = 0.1
	camera.far = 512.0
	camera.current = true
	root.add_child(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)

	await process_frame
	await run_tier("avt")
	await run_tier("svt")

	terrain.show_texture_albedo = false
	terrain.show_texture_normal = false
	terrain.show_texture_rough = false
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = false
	terrain.set_process(false)
	terrain.set_physics_process(false)
	scene.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS GPU AVT/SVT diffuse and signed-normal compression preserve rendered normal and roughness")
	quit(0)
