# Run with a graphical rendering driver; see README.md in this directory.
#
# Evidence for the "near material = Clipmap is visually sharp at 1024 texels/m" fix, along the
# *user's* path: select `Clipmap` on the near material group and change nothing else - no hidden
# switch, no budget tuning. It renders the near ground at the project's gameplay pose and saves two
# pictures of the same patch, one with the default (detail on) and one with the detail layer off, so
# the difference the fix makes can be looked at rather than inferred.
#
# It also measures the *point-wise* density a fragment samples, through `Terrain3D.sample_vt_detail()`
# - the CPU mirror of the shader's own directory lookup - over every visible ground point within 8 m.
# That is the reading the acceptance test's global `delivered_density` cannot give: the test answers
# at the focus, and "the focus is 1024" was exactly the state in which the rest of the visible near
# field fell back to the 1 texel/m ring.
#
# The two claims it asserts, one reading each:
#  1. The ground `PROBE_FORWARD_M` in front of the camera samples at >= 1024 texels/m with the user's
#     default settings.
#  2. Every visible near-field point within 8 m is served by the *detail layer* (>= 128 texels/m), not
#     by the coarse ring. 128 is the coarsest detail level, so a point below it is a point the ring
#     answered.
extends "res://vt_probe_base.gd"

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2
const TARGET_DENSITY := 1024.0
# The coarsest detail level. A visible point below it is a point the detail layer does not cover and
# the 1 texel/m coarse ring answered instead - which is the "large coarse fallback" the fix removes.
const DETAIL_FLOOR := 128.0
const NEAR_RADIUS := 8.0
const PROBE_FORWARD_M := 1.6

var painter: Terrain3DEditor
var brush: Image
var target: Node3D

func settle(frames: int) -> void:
	for _i in frames:
		await process_frame

func settings() -> Dictionary:
	return terrain.get_vt_settings()

func detail_report() -> Dictionary:
	var s := settings()
	var entry: Dictionary = (s.get("clipmap", {}) as Dictionary).get("material", {})
	return entry.get("detail", s.get("detail_material", {}))

# The world point the plan probes: the ground `PROBE_FORWARD_M` in front of the camera on the ground
# plane, along the view's own horizontal heading.
func probe_world() -> Vector2:
	var forward := -camera.global_transform.basis.z
	var flat := Vector2(forward.x, forward.z)
	if flat.length() < 0.0001:
		flat = Vector2(0.0, -1.0)
	return Vector2(camera.position.x, camera.position.z) + flat.normalized() * PROBE_FORWARD_M

# Every ground point within `radius` of the camera that the view actually samples.
func visible_near_points(radius: float) -> Array[Vector2]:
	var center := Vector2(camera.position.x, camera.position.z)
	var view := Vector2(root.size)
	var points: Array[Vector2] = []
	var span := int(ceil(radius))
	for dz in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var point := center + Vector2(float(dx), float(dz))
			if point.distance_to(center) > radius:
				continue
			var world := Vector3(point.x, 0.0, point.y)
			if camera.is_position_behind(world):
				continue
			var screen := camera.unproject_position(world)
			if screen.x < 0.0 or screen.y < 0.0 or screen.x >= view.x or screen.y >= view.y:
				continue
			points.append(point)
	return points

# A reading of one state: the probe density, the point-wise hit rates over the visible near field, and
# the layer's own residency/fallback report.
func reading(label: String) -> Dictionary:
	var points := visible_near_points(NEAR_RADIUS)
	var probe := terrain.sample_vt_detail(probe_world())
	var probe_ring := terrain.sample_vt_clipmap(MATERIAL, probe_world())
	var hits_fine := 0
	var hits_detail := 0
	var ring := 0
	var worst := 1.0e9
	for point in points:
		var density := terrain.sample_vt_detail(point)
		worst = minf(worst, density)
		if density >= TARGET_DENSITY:
			hits_fine += 1
		if density >= DETAIL_FLOOR:
			hits_detail += 1
		if density <= 0.0:
			ring += 1
	var report := detail_report()
	print("SHARPNESS %s probe=%.0f probe_ring=%.1f points=%d hit1024=%.3f hit128=%.3f ring=%.3f worst=%.0f detail_enabled=%s resident=%s valid=%s missing=%s fallback=%s slots=%s budget=%s cache=%s" % [
		label, probe, probe_ring, points.size(),
		float(hits_fine) / float(maxi(points.size(), 1)),
		float(hits_detail) / float(maxi(points.size(), 1)),
		float(ring) / float(maxi(points.size(), 1)), worst,
		str(report.get("enabled", "?")), str(report.get("resident_tiles", "?")),
		str(report.get("valid_tiles", "?")), str(report.get("missing_tiles", "?")),
		str(report.get("fallback_tiles", "?")), str(report.get("slot_count", "?")),
		str(report.get("budget_bytes", "?")), str(report.get("cache_bytes", "?"))])
	return {
		"probe": probe,
		"hit1024": float(hits_fine) / float(maxi(points.size(), 1)),
		"hit128": float(hits_detail) / float(maxi(points.size(), 1)),
		"ring": float(ring) / float(maxi(points.size(), 1)),
	}

func captured_image() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

# A texture asset with fine structure: the coarse ring's bake filters it to a flat tone at 1 texel/m,
# and the 1024 layer reproduces it, so the two pictures differ in sharpness rather than in hue.
func patterned_texture(base: Color, accent: Color) -> ImageTexture:
	var image := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			var fine := Color(base)
			if ((x / 2) + (y / 2)) % 2 == 0:
				fine = accent
			# Fine diagonal ruling on top, so a filtered read averages toward the base tone.
			if (x + y) % 5 == 0:
				fine = base.lerp(accent, 0.15)
			image.set_pixel(x, y, fine)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func paint_material(center: Vector3, asset_id: int) -> void:
	painter.set_tool(Terrain3DEditor.TEXTURE)
	painter.set_operation(Terrain3DEditor.REPLACE)
	painter.set_brush_data({
		"brush": [brush, ImageTexture.create_from_image(brush)],
		"size": 12.0, "strength": 100.0, "mouse_pressure": 1.0,
		"asset_id": asset_id, "pair_overlay_id": asset_id, "pair_background_id": asset_id,
		"pair_mode": 0, "pair_weight_level": 8,
	})
	painter.start_operation(center)
	painter.operate(center, 0.0)
	painter.stop_operation()

func setup() -> void:
	scene = Node3D.new()
	root.add_child(scene)
	camera = Camera3D.new()
	camera.fov = 70.0
	camera.near = 0.05
	camera.far = 1024.0
	camera.position = Vector3(32.0, 1.7, 32.0)
	camera.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	camera.current = true
	root.add_child(camera)

	terrain = Terrain3D.new()
	terrain.region_size = 64
	terrain.free_editor_textures = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_page_fade_frames = 0
	# The user's path, and nothing else: the near material group on Clipmap. The detail layer, its
	# density, its budget and its switch are all left at their shipped defaults.
	terrain.vt_delivery_near_material = CLIPMAP
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.vt_clipmap_size = 256
	terrain.vt_clipmap_levels = 4
	terrain.vt_clipmap_base_world = 256.0
	terrain.vt_clipmap_budget_texels = 256 * 256
	terrain.assets = Terrain3DAssets.new()
	var red := Terrain3DTextureAsset.new()
	red.albedo_texture = patterned_texture(Color(0.55, 0.12, 0.10), Color(0.85, 0.55, 0.35))
	red.normal_texture = patterned_texture(Color(0.5, 0.5, 1.0), Color(0.62, 0.42, 0.98))
	terrain.assets.set_texture_asset(0, red)
	var green := Terrain3DTextureAsset.new()
	green.albedo_texture = patterned_texture(Color(0.12, 0.42, 0.14), Color(0.55, 0.78, 0.30))
	green.normal_texture = patterned_texture(Color(0.5, 0.5, 1.0), Color(0.62, 0.42, 0.98))
	terrain.assets.set_texture_asset(1, green)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	scene.add_child(terrain)
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)

	for z in range(-1, 2):
		for x in range(-1, 2):
			terrain.data.add_region_blank(Vector2i(x, z), false)
	terrain.data.update_maps()
	# Alternating material ids in eight-metre blocks, so the picture has material variation over the
	# visible near field as well as the texture's own structure.
	for bz in 8:
		for bx in 8:
			paint_material(Vector3(float(bx) * 8.0 + 4.0, 0.0, float(bz) * 8.0 + 4.0), (bx + bz) % 2)
	terrain.data.update_maps()
	await settle(8)

# The detail layer fills a slot table over many ticks; wait until the demanded set has stopped
# growing (or a frame cap) so a reading is taken on a settled picture rather than mid-arrival.
func settle_detail(frames: int = 400) -> void:
	for _frame in frames:
		await process_frame
		var report := detail_report()
		if int(report.get("missing_tiles", 1)) == 0 and int(report.get("fallback_tiles", 1)) == 0:
			break
	await settle(8)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	await setup()

	await settle_detail()
	var on := reading("default_clipmap")
	var on_image := await captured_image()
	on_image.save_png(output_dir.path_join("near-material-clipmap-detail-on.png"))

	# The same patch with the detail layer off, which is what the user saw before the fix: the coarse
	# ring's own 1 texel/m material. It is a picture, and the reading above is the number.
	terrain.vt_clipmap_detail_enabled = false
	await settle(12)
	var off := reading("detail_off")
	var off_image := await captured_image()
	off_image.save_png(output_dir.path_join("near-material-clipmap-detail-off.png"))
	terrain.vt_clipmap_detail_enabled = true
	await settle_detail()

	# The view moves; the fine field has to follow it and the same two claims have to hold.
	camera.position = Vector3(camera.position.x + 3.0, camera.position.y, camera.position.z - 4.0)
	await settle(20)
	await settle_detail()
	var moved := reading("default_clipmap_moved")
	var moved_image := await captured_image()
	moved_image.save_png(output_dir.path_join("near-material-clipmap-moved.png"))

	print("SHARPNESS images %s" % output_dir)
	require(on["probe"] >= TARGET_DENSITY,
			"用户路径：目标点 %.0f texels/m < %.0f" % [on["probe"], TARGET_DENSITY])
	require(on["ring"] <= 0.0,
			"用户路径：8 m 可见近场有 %.1f%% 的点回退到 1 texel/m 粗环" % [on["ring"] * 100.0])
	require(on["hit128"] >= 0.90,
			"用户路径：8 m 可见近场被细层覆盖的比例 %.3f < 0.90" % on["hit128"])
	require(moved["probe"] >= TARGET_DENSITY,
			"相机移动后：目标点 %.0f texels/m < %.0f" % [moved["probe"], TARGET_DENSITY])
	require(moved["ring"] <= 0.0,
			"相机移动后：8 m 可见近场有 %.1f%% 的点回退到 1 texel/m 粗环" % [moved["ring"] * 100.0])
	require(moved["hit128"] >= 0.90,
			"相机移动后：8 m 可见近场被细层覆盖的比例 %.3f < 0.90" % moved["hit128"])

	if terrain != null:
		terrain.set_process(false)
		terrain.set_physics_process(false)
		terrain.set_editor(null)
		terrain.set_plugin(null)
	if painter != null:
		painter.free()
	if scene != null:
		scene.queue_free()
	if camera != null:
		camera.queue_free()
	await process_frame
	await process_frame
	if failed:
		print("REGRESSION: clipmap near material sharpness evidence")
		quit(1)
		return
	print("PASS clipmap near material sharpness evidence")
	quit(0)
