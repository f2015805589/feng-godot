## Storage-level codec check: what the block encoder actually leaves in a page.
##
## The render-level test (vt_compressed_render.gd) compares a patch of the rendered frame,
## which mixes the codec's error with the resolve, the lighting and the patch's own colour
## range. This test reads a page back out of the compressed array and decodes it with the
## engine's own software decoder, so a codec that writes the wrong channel order, or whose
## colour half lands in the wrong bytes, is visible per channel and per texel - with no
## renderer in the way.
extends SceneTree

const REGION_SIZE := 64
const GRID := 8
const PAGE_SIZE := 32
const PAGE_BORDER := 2
const BC7 := 1
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

func producer_stats() -> Dictionary:
	return terrain.get_vt_settings().get("producer", {})

func configure() -> void:
	terrain.region_size = REGION_SIZE
	terrain.vt_page_size = PAGE_SIZE
	terrain.vt_page_border = PAGE_BORDER
	terrain.vt_page_count = 128
	terrain.vt_pages_per_update = 16
	terrain.surface_vt_pages_per_axis = 8
	terrain.surface_vt_distance = 512.0
	terrain.surface_vt_region_grid = Vector2i(1, 1)
	terrain.surface_vt_selection_mode = 1
	terrain.surface_svt_enabled = false
	for z in GRID:
		for x in GRID:
			var location := Vector2i(x, z)
			terrain.data.add_region_blank(location)
			fill_region(location, 1 if location == Vector2i(1, 1) else 0)
	terrain.data.update_maps()

func produce(frames: int) -> void:
	for _frame in frames:
		terrain.update_surface_vt(64)
		await process_frame

## Interiors only: the border repeats the page's edge and is not part of the material.
func page_stats(image: Image, label: String) -> Dictionary:
	var total := 0
	var sums := Vector3.ZERO
	var minimum := Vector3(1.0, 1.0, 1.0)
	var maximum := Vector3.ZERO
	var samples := PackedStringArray()
	for y in range(PAGE_BORDER, image.get_height() - PAGE_BORDER):
		for x in range(PAGE_BORDER, image.get_width() - PAGE_BORDER):
			var pixel := image.get_pixel(x, y)
			sums += Vector3(pixel.r, pixel.g, pixel.b)
			minimum = Vector3(minf(minimum.x, pixel.r), minf(minimum.y, pixel.g), minf(minimum.z, pixel.b))
			maximum = Vector3(maxf(maximum.x, pixel.r), maxf(maximum.y, pixel.g), maxf(maximum.z, pixel.b))
			total += 1
	if total > 0 and samples.size() < 4:
		for i in 4:
			var pixel := image.get_pixel(PAGE_BORDER + 3 + i * 5, PAGE_BORDER + 3)
			samples.append("%.3f/%.3f/%.3f" % [pixel.r, pixel.g, pixel.b])
	var mean := sums / float(maxi(1, total))
	print("VTCODEC_COLORS %s size=%dx%d mean=%.4f,%.4f,%.4f min=%.4f,%.4f,%.4f max=%.4f,%.4f,%.4f samples=%s" % [
			label, image.get_width(), image.get_height(), mean.x, mean.y, mean.z,
			minimum.x, minimum.y, minimum.z, maximum.x, maximum.y, maximum.z, " ".join(samples)])
	return {"mean": mean, "min": minimum, "max": maximum}

## The first AVT slot that exports, so each codec is read from the same kind of page.
func first_page() -> Dictionary:
	for slot in int(producer_stats().get("page_count", 128)):
		var preview: Image = terrain.get_vt_page_preview(slot)
		if preview != null and preview.get_width() == PAGE_SIZE + 2 * PAGE_BORDER:
			return {"slot": slot, "image": preview}
	return {}

func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.free_editor_textures = false
	DirAccess.make_dir_recursive_absolute("user://terrain")
	terrain.data_directory = "user://terrain"
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.assets = Terrain3DAssets.new()
	var dark := Terrain3DTextureAsset.new()
	dark.albedo_texture = make_pattern(64, Color(0.035, 0.045, 0.055), Color(0.16, 0.10, 0.06))
	dark.normal_texture = make_normal(64)
	terrain.assets.set_texture_asset(0, dark)
	var bright := Terrain3DTextureAsset.new()
	bright.albedo_texture = make_pattern(64, Color(0.16, 0.72, 0.08), Color(0.95, 0.24, 0.04))
	bright.normal_texture = make_normal(64)
	terrain.assets.set_texture_asset(1, bright)
	camera = Camera3D.new()
	root.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.position = Vector3(96.0, 180.0, 96.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.size = 96.0
	camera.current = true
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	configure()
	await process_frame
	terrain.surface_vt_enabled = true
	await produce(90)

	var baseline := {}
	var results := {}
	for codec in [0, BC7, BC3]:
		terrain.vt_atlas_compression = codec
		await process_frame
		# The whole pool is rebuilt for a format change, so wait for it to drain and refill.
		for _i in 240:
			await process_frame
			var stats := producer_stats()
			if int(stats.get("retired_bundles", -1)) == 0 and int(stats.get("pending", 1)) == 0:
				break
		await produce(120)
		for _i in 240:
			await process_frame
			if int(producer_stats().get("pending", 1)) == 0:
				break
		var page := first_page()
		if page.is_empty():
			require(false, "codec %d exported no page to inspect" % codec)
			continue
		var label := "codec=%d" % codec
		var stats := page_stats(page["image"], label)
		results[codec] = stats
		if codec == 0:
			baseline = stats
		else:
			var cast: Vector3 = stats["mean"] - baseline["mean"]
			print("VTCODEC_COLORS cast %s cast=%.4f,%.4f,%.4f" % [label, cast.x, cast.y, cast.z])
			require(absf(cast.x) < 0.05 and absf(cast.y) < 0.05 and absf(cast.z) < 0.05,
					"%s shifted the stored page colour by %.4f,%.4f,%.4f" % [label, cast.x, cast.y, cast.z])
			for axis in 3:
				require(absf(cast[axis]) < 0.05, "%s channel %d is %.4f off" % [label, axis, cast[axis]])

	if failed:
		print("VTCODEC_COLORS FAILED")
		quit(1)
		return
	print("PASS stored pages keep their colour in every codec")
	quit(0)
