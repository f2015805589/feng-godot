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

# The two page codecs the block encoder implements, in the order the settings offer them.
const BC7 := 1
const BC3 := 2

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

## Waits until every replaced page array has been released. A format change rebuilds all six
## arrays and the material only rebinds them once the producer publishes the new bundle, so a
## second change stacked on top of an undrained retire is a race the test does not need to take
## part in - it is about the codecs, not about how fast the material can follow a rebuild.
func settle_bundles(max_frames: int = 120) -> void:
	for _i in max_frames:
		await process_frame
		if int(producer_stats().get("retired_bundles", -1)) == 0:
			return

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
	await settle_bundles()
	for codec in [BC7, BC3]:
		terrain.vt_atlas_compression = codec
		await process_frame
		await settle_bundles()
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

	# The far field's own setting. An SVT page is assembled once from a baked cell and then
	# never rewritten, so this is the tier where compression is paid once and the memory is
	# saved for the rest of the session.
	#
	# The near field is switched off for this section on purpose: the AVT grid follows the
	# target, so with AVT enabled the far view is resolved by the near field and the far
	# patch would prove nothing about the far-field setting. With AVT off, every texel of the
	# patch can only come from the SVT arrays.
	terrain.surface_vt_enabled = false
	terrain.vt_atlas_compression = 0
	terrain.surface_svt_compression = 0
	await settle_bundles()
	await set_view(FAR_WORLD, 220.0, 144.0)
	await produce(120)
	await wait_pending_empty()
	var svt_baseline := await frame_image()
	svt_baseline.save_png(output_dir.path_join("compressed-svt-baseline-far.png"))
	require(float(patch_stats(svt_baseline, FAR_WORLD, 14)["mean"]) > 0.03,
			"the far field's uncompressed baseline is unexpectedly black")
	for svt_codec in [BC7, BC3]:
		terrain.surface_svt_compression = svt_codec
		await process_frame
		await settle_bundles()
		var svt_resolved: Dictionary = terrain.get_vt_settings()
		var svt_available := int(svt_resolved.get("surface_svt_compression_available", -1))
		var svt_reason := String(svt_resolved.get("surface_svt_compression_reason", ""))
		print("VTCOMPRESS_RENDER svt_codec=%d available=%d reason='%s'" % [svt_codec, svt_available, svt_reason])
		if svt_available != svt_codec:
			print("VTCOMPRESS_RENDER skipped SVT codec %d: %s" % [svt_codec, svt_reason])
			continue
		require(int(svt_resolved.get("surface_vt_compression_available", -1)) == 0,
				"the two tier settings must be independent: an SVT request changed the AVT resolution")
		await set_view(FAR_WORLD, 220.0, 144.0)
		await produce(120)
		await wait_pending_empty()
		await produce(40)
		var svt_image := await frame_image()
		svt_image.save_png(output_dir.path_join("compressed-svt-codec%d-far.png" % svt_codec))
		compare_patch(svt_baseline, svt_image, FAR_WORLD, "far SVT codec %d" % svt_codec)
		# Compressed once. The demand pass keeps visiting its working set every frame, so the
		# property that has to hold is not "nothing is produced" but "a page is compressed at
		# most once per production": with the view still and the pool settled, the encode
		# count, the ready count and the re-production count must all stop moving.
		await produce(30)
		var settled := producer_stats()
		var settled_requests := int(settled.get("encode_requests", -1))
		var settled_ready := int(settled.get("ready_pages", -1))
		var settled_requeues := int(terrain.get_vt_settings().get("svt_requeues", -1))
		await produce(30)
		var later := producer_stats()
		var later_requests := int(later.get("encode_requests", -1))
		var later_ready := int(later.get("ready_pages", -1))
		var later_requeues := int(terrain.get_vt_settings().get("svt_requeues", -1))
		print("VTCOMPRESS_RENDER svt_once codec=%d requests %d->%d ready %d->%d requeues %d->%d produced=%d" % [
				svt_codec, settled_requests, later_requests, settled_ready, later_ready,
				settled_requeues, later_requeues,
				int(later.get("baked_pages", 0)) + int(later.get("cached_uploads", 0))])
		require(later_ready == settled_ready,
				"a settled far field changed its ready page count (%d -> %d)" % [settled_ready, later_ready])
		require(later_requeues == settled_requeues,
				"a settled far field re-produced a ready page (%d -> %d)" % [settled_requeues, later_requeues])
		require(later_requests == settled_requests,
				"a settled far field compressed a page again (%d -> %d encodes)" % [settled_requests, later_requests])
		require(int(later.get("encode_failures", -1)) == 0,
				"the far field's block encodes must not fail (%d)" % int(later.get("encode_failures", -1)))
		require(int(later.get("encode_requests", 0)) <= int(later.get("baked_pages", 0)) + int(later.get("cached_uploads", 0)),
				"a far-field page must be compressed at most once per production")
	terrain.surface_svt_compression = 0
	await process_frame

	# Both tiers compressed at once. This is the case that releases the half-float pool: with
	# nothing sampling the staging arrays by slot they shrink to the encoder ring, so the
	# resident pool stops carrying a page-sized RGBA16F allocation per slot.
	terrain.surface_vt_enabled = true
	terrain.vt_atlas_compression = BC7
	terrain.surface_svt_compression = BC7
	await settle_bundles()
	var pool := producer_stats()
	var layers := int(pool.get("staging_layers", -1))
	var page_count := int(terrain.get_vt_settings().get("page_count", -1))
	var page_sized_bytes := int(terrain.get_vt_settings().get("physical_cache_bytes_uncompressed", 0))
	print("VTCOMPRESS_RENDER scratch layers=%d scratch=%s bytes=%d page_count=%d ring_capacity=%d" % [
			layers, str(pool.get("staging_scratch", false)), int(pool.get("staging_bytes", -1)), page_count,
			int(pool.get("encode_ring_capacity", -1))])
	require(bool(pool.get("staging_scratch", false)),
			"both tiers compressed must put the staging pool in scratch mode")
	require(layers > 0 and layers * 2 <= page_count,
			"the staging pool must be at most half the slot count (%d layers for %d pages)" % [layers, page_count])
	# The ring is as deep as the page budget needs it to be, which is deeper than the slot
	# count only for a pool smaller than two budgets; what has to hold is that the scratch pool
	# costs at most half of what the page sized pool would.
	require(int(pool.get("staging_bytes", 1 << 40)) * 2 <= page_sized_bytes,
			"the staging pool must be at most half the page sized pool (%d of %d bytes)" % [
				int(pool.get("staging_bytes", -1)), page_sized_bytes])
	# Both tiers still render their own material out of the ring, near and far.
	await set_view(NEAR_WORLD, 180.0, 96.0)
	await produce(120)
	await wait_pending_empty()
	await produce(40)
	var scratch_near := await frame_image()
	scratch_near.save_png(output_dir.path_join("compressed-scratch-near.png"))
	compare_patch(baseline_near, scratch_near, NEAR_WORLD, "scratch near")
	await set_view(FAR_WORLD, 220.0, 144.0)
	await produce(40)
	var scratch_far := await frame_image()
	scratch_far.save_png(output_dir.path_join("compressed-scratch-far.png"))
	compare_patch(baseline_far, scratch_far, FAR_WORLD, "scratch far")
	# A resident page is still exportable: its half-float layer is long reused, so the export
	# reads the block words and decodes them. The dock's preview is the same path.
	var exported := 0
	for slot in page_count:
		var preview: Image = terrain.get_vt_page_preview(slot)
		if preview != null and preview.get_width() == PAGE_SIZE + 2 * PAGE_BORDER:
			exported += 1
	print("VTCOMPRESS_RENDER scratch export pages=%d failures=%d" % [
			exported, int(producer_stats().get("encode_failures", -1))])
	require(exported > 0, "a resident page must still export under the scratch pool")
	require(int(producer_stats().get("encode_failures", -1)) == 0, "the scratch pool must not fail an encode")
	terrain.vt_atlas_compression = 0
	terrain.surface_svt_compression = 0
	await process_frame

	# Production must keep the caller's rate: the budget is a setting, not a codec
	# property. The pool is emptied by a format change, then the camera is stepped across a
	# world that demands many more pages than the budget, and the largest production of a
	# single frame is measured. That is the callback's budget: with the old four-page cap
	# the compressed format could not exceed 4 while the uncompressed one reached 16.
	#
	# The far field is the only producer in this section, so the setting it toggles is the far
	# field's own: the two tiers are separate, and an AVT codec would no longer change what
	# these pages are stored in.
	var budget := 16
	terrain.surface_vt_enabled = false
	terrain.vt_auto_capacity = false
	terrain.vt_page_count = 64
	terrain.vt_pages_per_update = budget
	terrain.surface_svt_page_world = 32.0
	terrain.surface_svt_distance = 1024.0
	var peak := {}
	var ring_depth := {}
	var ring_held := {}
	for mode in [BC7, 0]:
		terrain.surface_svt_compression = mode
		await set_view(Vector2(256.0, 256.0), 60.0, 512.0)
		for _frame in 8:
			terrain.update_surface_svt(64)
			await process_frame
		var best := 0
		var deepest := 0
		for step in 10:
			await set_view(Vector2(256.0 + step * 48.0, 256.0 + step * 32.0), 60.0, 512.0)
			var before := produced_pages()
			terrain.update_surface_svt(64)
			await process_frame
			best = maxi(best, produced_pages() - before)
			deepest = maxi(deepest, int(producer_stats().get("encode_ring_pages", 0)))
		peak[mode] = best
		ring_depth[mode] = int(producer_stats().get("encode_ring_capacity", 0))
		ring_held[mode] = deepest
		print("VTCOMPRESS_RENDER rate mode=%d pages_per_frame=%d ready=%d ring_capacity=%d ring_peak=%d visible=%s" % [
				mode, best, int(producer_stats().get("ready_pages", 0)), int(ring_depth[mode]), deepest,
				str(terrain.get_vt_settings().get("svt_visible_pages"))])
	# Compression must not lower the rate the budget allows. The two modes are measured in
	# separate passes over the same fixture, so a page of difference is frame timing rather than
	# throughput; what this has to catch is the collapse the compressed path used to have.
	var uncompressed_peak := int(peak.get(0, 0))
	var rate_slack := maxi(2, uncompressed_peak / 5)
	require(int(peak.get(BC7, 0)) >= uncompressed_peak - rate_slack,
			"compression must not lower the production rate (BC7 %d vs uncompressed %d pages per frame)" % [
				int(peak.get(BC7, 0)), uncompressed_peak])
	# The compressed path used to cap the budget at four pages per frame, so a demand-driven
	# rate above that in both formats is what proves the budget alone decides the rate.
	require(int(peak.get(0, 0)) > 4,
			"a demand pass must not be capped below the demand (%d pages of a %d page budget)" % [
				int(peak.get(0, 0)), budget])
	require(int(ring_depth.get(BC7, 0)) >= budget,
			"the compressed ring must admit a whole page budget (%d regions for a %d page budget)" % [
				int(ring_depth.get(BC7, 0)), budget])
	# A page used to keep its ring regions until its readbacks landed, about two frames later, so
	# the ring had to admit a whole budget in flight or it - not the budget - was the page rate.
	# How deep the ring actually gets is now a property of how the encode is stored: with the
	# engine's buffer to texture copy the blocks go straight into the sampling array and nothing
	# waits in the ring at all, while an engine without it still pays the readback latency and
	# then the depth has to cover the budget. Either way the ring must not stall the burst.
	var ring_peak := int(ring_held.get(BC7, 0))
	print("VTCOMPRESS_RENDER ring peak=%d depth=%d ready_latency_mean=%.2f max=%d samples=%d" % [
			ring_peak, int(ring_depth.get(BC7, 0)),
			float(producer_stats().get("ready_latency_frames_mean", 0.0)),
			int(producer_stats().get("ready_latency_frames_max", 0)),
			int(producer_stats().get("ready_latency_samples", 0))])
	require(ring_peak == 0 or ring_peak > 8,
			"a compressed demand burst must not stall on the ring (peak %d of %d regions)" % [
				ring_peak, int(ring_depth.get(BC7, 0))])

	terrain.surface_svt_compression = 0
	await process_frame
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS compressed material pages render and keep the production rate")
	quit()
