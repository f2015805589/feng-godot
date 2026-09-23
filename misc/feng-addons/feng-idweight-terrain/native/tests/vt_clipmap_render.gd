# Run with a graphical rendering driver; see README.md in this directory.
#
# The height group delivered by the clipmap ring: the arm samples the ring where the ring is current
# and inside the band the height cells named, and the region texture array everywhere else. Four
# claims, one reading each:
#
#  1. **The cell and the arm are one decision.** Selecting `Near/Height = Clipmap` compiles the ring
#     into the generated shader and binds its uniforms; a height group that is `Direct` in both bands
#     compiles neither, and the string the GPU was handed is read back to say so (not a settings flag).
#  2. **A ring at the height grid's own density renders the same pixels as the array.** `size` texels
#     over `base_world` metres is one texel a metre with the configuration below, which is the region
#     height map's own grid, so the ring holds those numbers on that grid and the arm reads the same
#     value at every mesh vertex. Any slip in the level rule, the snap, the ring offset or the
#     fragment's own tap spacing shows up here as a different pixel.
#  3. **A coarser ring renders different ones**, which is what proves the render above is the ring's
#     and not a fallback that happened to agree.
#  4. **An editor stroke re-produces the rect it covers.** The levels that touch it stop being
#     current, the array serves until the rect has drained - so the picture follows the stroke at once
#     rather than waiting for the ring - and the ring's own counters say which texels were produced.
#     Once it has drained the ring serves the same picture the array did.
#
# The material group stays `Direct` through the height section, so the only difference between two
# images there is the height group's source; the material section that follows selects it and checks
# the baked layers the ring alone produces. Read `docs/vt_delivery_assembly.md` section 6 for the
# design; the group index is Material=0/Height=1 and the delivery values are
# Direct=0/AVT=1/Clipmap=2/SVT=3, i.e. the native `TerrainVT` enum values, which are also the
# property values.
extends SceneTree

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2

var terrain: Terrain3D
var painter: Terrain3DEditor
var camera: Camera3D
var target: Node3D
var scene: Node3D
var brush: Image
var failed := false
var output_dir := "user://"


func _initialize() -> void:
	call_deferred("run")


func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true


# ---- stand-ins for Terrain3DEditorPlugin's undo interface ---------------------------------------

func create_undo_action(_name: String) -> void:
	pass

func add_undo_method(action: Callable) -> void:
	pass

func add_do_method(action: Callable) -> void:
	pass

func commit_action(_execute: bool) -> void:
	pass


# ---- readings -----------------------------------------------------------------------------------

func settings() -> Dictionary:
	return terrain.get_vt_settings()


func ring() -> Dictionary:
	return settings().get("clipmap", {}).get("height", {})


func level_report(index: int = 0) -> Dictionary:
	var reports: Array = ring().get("level_reports", [])
	return reports[index] if reports.size() > index else {}


func valid_levels() -> int:
	return int(ring().get("valid_levels", -1))


func produced() -> int:
	return int(ring().get("produced_texels", -1))


func invalidated_texels() -> int:
	return int(ring().get("invalidated_texels", -1))


func invalidation_calls() -> int:
	return int(ring().get("invalidation_calls", -1))


# The generated shader, read back from the RID the GPU was handed. Godot's `Shader` resource runs the
# preprocessor before it hands the code to the server, so what comes back is the arm that was *kept*,
# with the other side of every `#ifdef` already gone. This is what makes "selecting the cell compiles
# the arm" a reading of the artifact rather than of a settings flag.
func shader_code() -> String:
	return RenderingServer.shader_get_code(terrain.material.get_shader_rid())


func differing(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				count += 1
	return count


# How far apart two renders of the same material are: the count of differing pixels says nothing about
# whether the difference is a different material or the same material's last bit. `x` is the worst
# channel delta, `y` the mean over every channel of every pixel, `z` how many pixels differ by more
# than a twentieth - the ones a different material, or a different texel read, would show up in.
func channel_delta(a: Image, b: Image) -> Vector3:
	var worst := 0.0
	var total := 0.0
	var samples := 0.0
	var strong := 0
	for y in a.get_height():
		for x in a.get_width():
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			var worst_here := 0.0
			for channel in 4:
				var delta: float = absf(pa[channel] - pb[channel])
				worst_here = maxf(worst_here, delta)
				total += delta
				samples += 1.0
			worst = maxf(worst, worst_here)
			if worst_here > 0.05:
				strong += 1
	return Vector3(worst, total / maxf(samples, 1.0), float(strong))


func diag(label: String) -> void:
	print("VT_CLIPMAP_RENDER_DIAG %s height=%s shader_arm=%s ring_arm=%s valid=%d pending=%d produced=%d invalidated=%d calls=%d" % [
		label, str(terrain.vt_delivery_near_height), str(settings().get("vt_shader_arms", "?")),
		str(clipmap_arm("height")), valid_levels(),
		int(ring().get("pending_jobs", -1)), produced(), invalidated_texels(), invalidation_calls()])


# The generated code's ring arm per channel group, as the report publishes it: the reading lives with
# the group that owns it (`clipmap[group].shader_arm`) rather than in a key of its own, so a build can
# carry one group's arm without the other's and a channel the ring gains needs no new key.
func clipmap_arm(group: String) -> bool:
	var clipmap: Dictionary = settings().get("clipmap", {})
	var entry: Dictionary = clipmap.get(group, {})
	return bool(entry.get("shader_arm", false))


# ---- driving ------------------------------------------------------------------------------------

func settle(frames: int) -> void:
	for _i in frames:
		await process_frame


func frame_image() -> Image:
	for _i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


# The ring is filled by the tick's own phase while a cell names the method; the mechanism's entry is
# the deterministic door and runs exactly the same update (same focus, same `vt_clipmap_budget_texels`),
# so a settled ring is the same ring either way.
func settle_ring() -> void:
	for _i in 4096:
		if int(ring().get("pending_jobs", 1)) == 0 && valid_levels() >= int(ring().get("levels", 1)):
			break
		terrain.call("debug_update_vt_clipmap", HEIGHT)
	await process_frame


func reference(world: Vector2) -> float:
	return terrain.data.get_pixel(Terrain3DRegion.TYPE_HEIGHT, Vector3(world.x, 0.0, world.y)).r


func sample(world: Vector2) -> float:
	return terrain.sample_vt_clipmap(HEIGHT, world)


# ---- the scene ----------------------------------------------------------------------------------

# A profile with detail at the height grid's own scale. A linear ramp would not do: its gradient is
# exact at any sampling density, so a coarse ring would render the same picture and the third check
# below would prove nothing.
func height_profile(x: float, z: float) -> float:
	return 6.0 * sin(x * 0.45) * cos(z * 0.42) + 0.05 * x


func setup() -> void:
	scene = Node3D.new()
	root.add_child(scene)

	camera = Camera3D.new()
	root.add_child(camera)
	# Orthographic and straight down. The size is the *vertical* extent, so at this window's 4:3 the
	# visible square is 53 m wide and 40 m tall, centred on the focus: every fragment that is rendered,
	# and every texel its taps read, is inside the ring's own coverage and inside the region.
	camera.position = Vector3(30.0, 200.0, 30.0)
	camera.rotation_degrees.x = -90
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 40.0
	camera.current = true

	target = Node3D.new()
	target.position = Vector3(30.0, 0.0, 30.0)
	root.add_child(target)

	terrain = Terrain3D.new()
	terrain.free_editor_textures = false
	terrain.surface_svt_auto_bake = false
	# Every cell direct to begin with: the shipped height path is the baseline the ring is compared
	# against. The material group gets two texture assets and a painted boundary below, because a
	# uniform payload cannot tell a coarse ring from a fine one.
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = solid_texture(32, Color(0.8, 0.15, 0.1) if id == 0 else Color(0.1, 0.7, 0.2))
		asset.normal_texture = solid_texture(32, Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(id, asset)
	# One level of 64 texels over 64 m, i.e. exactly one ring texel a metre: the height map's own
	# grid. The budget fills a whole level in one call, which is what makes the settling below exact.
	terrain.vt_clipmap_size = 64
	terrain.vt_clipmap_levels = 1
	terrain.vt_clipmap_base_world = 64.0
	terrain.vt_clipmap_budget_texels = 64 * 64
	terrain.set_camera(camera)
	terrain.set_clipmap_target(target)
	scene.add_child(terrain)
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)

	terrain.region_size = 64
	terrain.data.add_region_blank(Vector2i.ZERO)
	# `region_size` texels a region, so the vertices that exist are 0..63 on both axes. The visible
	# square is [0, 60) and its fragment reads reach one texel further, which is inside the region.
	for z in 64:
		for x in 64:
			terrain.data.set_height(Vector3(float(x), 0.0, float(z)), height_profile(float(x), float(z)))
	terrain.data.update_maps()
	# Two material ids with the boundary between them crossing the visible square, which is the payload
	# variation every material reading below needs. Painted before any image is captured, so the height
	# baselines are taken with the same material they are compared against.
	# Alternating material ids in eight-metre blocks across the visible square: the payload pattern every
	# material reading below stands on. Uniform patches would not do - a ring coarser than the payload
	# grid point-samples one value out of a uniform patch and renders the same picture, so the third
	# check below would prove nothing. It is the same reason the height profile is a gradient.
	for bz in 8:
		for bx in 8:
			paint_material(Vector3(float(bx) * 8.0 + 4.0, 0.0, float(bz) * 8.0 + 4.0), (bx + bz) % 2)
	# The reading the material arm stands on: the payload must vary across the visible square, or a
	# coarse ring would point-sample the same value and every comparison below would be vacuous.
	var painted_a := terrain.data.get_texture_id(Vector3(4.0, 0.0, 4.0))
	var painted_b := terrain.data.get_texture_id(Vector3(12.0, 0.0, 4.0))
	print("CLIPMAP_MATERIAL_FIXTURE a=%s b=%s" % [str(painted_a), str(painted_b)])
	require(painted_a.x != painted_b.x,
			"the fixture painted alternating material ids, so a coarse ring has something to get wrong")
	await settle(2)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, -20, 0)
	scene.add_child(light)
	await settle(6)


func paint_height(center: Vector3) -> void:
	painter.set_tool(Terrain3DEditor.HEIGHT)
	painter.set_operation(Terrain3DEditor.ADD)
	painter.set_brush_data({
		"brush": [brush, ImageTexture.create_from_image(brush)],
		"size": 16.0, "strength": 100.0, "mouse_pressure": 1.0,
		"align_to_view": false, "brush_spin_speed": 0.0, "auto_regions": true,
		"modifier_alt": false, "modifier_ctrl": false,
		"height": 30.0,
	})
	painter.start_operation(center)
	painter.operate(center, 0.0)
	painter.stop_operation()


# One solid texture, so a material id is a colour the image can be read for.
func solid_texture(size: int, color: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


# Material painting writes the `R16` id/weight payload - the same payload the material group's ring
# carries and its baked pages are produced from. It is what gives a ring coarser than the payload grid
# something to get wrong: over a uniform payload a coarse ring point-samples the same value and every
# material reading below would be vacuous.
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


# The material group's ring, settled the same way the height one is: the mechanism's own entry, which
# runs exactly the phase the tick runs for it, until every level is current.
func settle_material_ring() -> void:
	for _i in 4096:
		var entry: Dictionary = settings().get("clipmap", {}).get("material", {})
		if int(entry.get("pending_jobs", 1)) == 0 && int(entry.get("valid_levels", 0)) >= int(entry.get("levels", 1)):
			break
		terrain.call("debug_update_vt_clipmap", MATERIAL)
	await process_frame


func save_image(image: Image, name: String) -> void:
	if output_dir != "user://":
		image.save_png(output_dir.path_join(name))


# The material group's ring as the report publishes it, and the two readings the bake's handshake is
# made of: a level the producer may bake (current) and a level it *has* baked for that content.
func material_ring() -> Dictionary:
	return settings().get("clipmap", {}).get("material", {})


func baked_levels() -> int:
	var count := 0
	for report: Dictionary in (material_ring().get("level_reports", []) as Array):
		if bool(report.get("baked", false)):
			count += 1
	return count


# The *material* ring's own counts. `valid_levels()` above is the height group's - the two rings are
# separate objects with separate levels, so a bake reading taken from the wrong one is a reading of
# nothing.
func material_valid_levels() -> int:
	return int(material_ring().get("valid_levels", 0))


func material_baked_channels() -> int:
	var channels := 0
	for report: Dictionary in (material_ring().get("level_reports", []) as Array):
		channels = int(report.get("baked_channels", 0))
	return channels


# What a producer has written into the ring's layers, in channel texels - the unit the ring's
# production budget is charged in - and what the ring still owes it.
func baked_texels() -> int:
	return int(material_ring().get("baked_texels", 0))


func pending_bake_rects() -> int:
	return int(material_ring().get("pending_bake_rects", -1))


# How many rects the arm is currently told not to serve from the baked layers, as the material holds the
# table, over the *material* group's own rows (one row per level, from `MATERIAL`). It is the
# per-fragment gate's own state, so a settled ring reads zero and one poisoned entry reads one.
func mat_outstanding_total(arm_rid: RID) -> int:
	var counts: Variant = RenderingServer.material_get_param(arm_rid, "_clipmap_outstanding_count")
	var packed := counts as PackedInt32Array
	var total := 0
	for level in min(16, packed.size()):
		total += int(packed[MATERIAL * 16 + level])
	return total


func ready_pages() -> int:
	var count := 0
	for page: Dictionary in terrain.get_vt_pages():
		if bool(page.get("ready", false)):
			count += 1
	return count


# The paged tier's own settling: the pages the reference image stands on have to be produced, or the
# fragment reads the source evaluation instead of them and the comparison below is vacuous.
func settle_pages() -> void:
	for frame in 600:
		await process_frame
		var producer: Dictionary = settings().get("producer", {})
		if frame > 20 and int(producer.get("pending", 1)) == 0 and ready_pages() > 0:
			break
	await RenderingServer.frame_post_draw


func save_text(text: String, name: String) -> void:
	if output_dir == "user://":
		return
	var file := FileAccess.open(output_dir.path_join(name), FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


# ---- the run ------------------------------------------------------------------------------------

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	await setup()

	# 1. The baseline is the shipped array path, and its shader is the no-VT build: a height group
	#    that is `Direct` in both bands costs no ring code, no ring sampler and no VT uniform at all.
	var direct_code := shader_code()
	save_text(direct_code, "clipmap-height-direct.glsl")
	require(direct_code.contains("const bool _surface_vt_enabled"), "an all-direct matrix compiles the no-VT arm")
	require(not direct_code.contains("_avt_coverage_distance"), "which has no VT uniform in it")
	require(not direct_code.contains("_clipmap_atlas"), "and no ring sampler")
	require(not direct_code.contains("_clipmap_level_valid"), "and no ring gate")
	require(not clipmap_arm("height"), "and the report says so")
	var direct_image := await frame_image()
	save_image(direct_image, "clipmap-height-direct.png")
	diag("direct")

	# 2. Select the ring. The cell is deliverable, the arm leaves the policy and enters the compiled
	#    string, and the tick's own phase fills the ring - the entry below only settles it, it is no
	#    longer the only door to the mechanism.
	var tick_updates := int(ring().get("update_calls", 0))
	terrain.vt_delivery_near_height = CLIPMAP
	await settle(20)
	require(terrain.vt_delivery_near_height == CLIPMAP, "the height cell accepts Clipmap")
	require(terrain.is_vt_delivery_supported(HEIGHT, CLIPMAP), "and publishes it as deliverable")
	require(terrain.is_vt_delivery_used(CLIPMAP), "and as used")
	require(bool(ring().get("selected", false)), "and the ring reports the matrix's claim")
	var clip_code := shader_code()
	save_text(clip_code, "clipmap-height-ring.glsl")
	require(clip_code.contains("_surface_vt_enabled"), "selecting it compiles the VT arms")
	require(clip_code.contains("_clipmap_atlas"), "including the ring's sampler")
	require(clip_code.contains("_clipmap_level_valid"), "and the gate that keeps a stale level out")
	require(clip_code.contains("_avt_coverage_distance"), "with the band edge the ring serves inside")
	require(clipmap_arm("height"), "and the report says so")
	require(int(ring().get("update_calls", 0)) > tick_updates, "the tick's own phase drives the ring")
	settle_ring()
	diag("matched_ring")
	require(bool(ring().get("configured", false)), "the ring exists")
	require(int(ring().get("size", 0)) == 64, "with the configured size")
	require(absf(float(level_report().get("texel_world", 0.0)) - 1.0) < 0.0001, "and one texel a metre")
	require(valid_levels() == 1, "and its one level is current")
	require(int(ring().get("pending_jobs", -1)) == 0, "with nothing queued")
	var clip_image := await frame_image()
	save_image(clip_image, "clipmap-height-ring.png")
	var matched_diff := differing(direct_image, clip_image)
	require(matched_diff == 0, "a ring at the height grid's density renders the same pixels, %d differ" % matched_diff)
	if not failed:
		print("PASS clipmap height arm: a ring at the height grid's own density renders pixel-identical to the array")

	# 3. Coarser: four texels a metre holds one value where the grid holds four, so the picture must
	#    change. Reconfiguring drops the ring's content and the next fill rebuilds it whole.
	terrain.vt_clipmap_base_world = 256.0
	await settle(2)
	settle_ring()
	require(absf(float(level_report().get("texel_world", 0.0)) - 4.0) < 0.0001, "the reconfigured ring is four texels a metre")
	var coarse_image := await frame_image()
	save_image(coarse_image, "clipmap-height-coarse.png")
	var coarse_diff := differing(direct_image, coarse_image)
	require(coarse_diff > 1000, "a coarser ring renders different pixels, %d differ" % coarse_diff)
	if not failed:
		print("PASS clipmap height arm: a coarser ring changes the render, so the identical one is the ring's")

	# 3b. The coverage rule. The ring answers only inside the coarsest level's own coverage, and a point
	#     outside it is answered by the array - never by the coarsest level's edge, whose texel names a
	#     different world position. A ring of 32 texels over 32 m is still one texel a metre (so its
	#     grid is the height grid's) but covers only ±16 m around the focus, which the view reaches
	#     past: the render must be the array's, inside the coverage and outside it alike.
	terrain.vt_clipmap_size = 32
	terrain.vt_clipmap_base_world = 32.0
	await settle(2)
	settle_ring()
	require(absf(float(level_report().get("texel_world", 0.0)) - 1.0) < 0.0001, "the smaller ring is still one texel a metre")
	require(absf(float(level_report().get("world_size", 0.0)) - 32.0) < 0.0001, "and its coverage is 32 m, so the view leaves it")
	var edge_image := await frame_image()
	save_image(edge_image, "clipmap-height-edge.png")
	var edge_diff := differing(direct_image, edge_image)
	require(edge_diff == 0, "a view that reaches outside the ring's coverage renders the array there, %d differ" % edge_diff)
	if not failed:
		print("PASS clipmap height arm: outside the coarsest level's coverage the array serves, and the render is unchanged")

	# Back to the matched shape, settled, before the stroke below.
	terrain.vt_clipmap_size = 64
	terrain.vt_clipmap_base_world = 64.0
	await settle(2)
	settle_ring()
	require(valid_levels() == 1, "the matched ring is current again")

	# 4. An editor stroke reports itself to the ring through the one hook every edit uses. The ring
	#    cannot serve the rect it covers until it has re-produced it, so the array takes over - which is
	#    why the height the ring holds stays the old one across the same frames the picture is new.
	#    The production budget is zeroed for the window: a 4096 texel budget drains a 256 texel rect in
	#    the first tick, and "the rectangle waited" is only observable while nothing may drain it.
	var before_calls := invalidation_calls()
	var before_invalidated := invalidated_texels()
	var before_produced := produced()
	var probe := Vector2(30.0, 30.0)
	var ring_before := sample(probe)
	terrain.vt_clipmap_budget_texels = 0
	paint_height(Vector3(30.0, 0.0, 30.0))
	await settle(2)
	diag("after_stroke")
	require(invalidation_calls() == before_calls + 1, "the stroke reports itself to the ring once")
	require(invalidated_texels() > before_invalidated, "and queues the texels it covers")
	require(valid_levels() == 0, "so the level that covers it is not current")
	require(produced() == before_produced, "and nothing has been produced yet, the budget being zero")
	var edited_reference := reference(probe)
	require(absf(edited_reference - ring_before) > 0.5, "the stroke changed the height map under it")
	require(absf(sample(probe) - ring_before) < 0.001, "while the ring still holds the height from before it")
	var edited_image := await frame_image()
	save_image(edited_image, "clipmap-height-edited.png")
	require(differing(clip_image, edited_image) > 1000,
			"the picture follows the edit while the ring is stale, i.e. the array served it")
	if not failed:
		print("PASS clipmap height arm: a stroke falls back to the array until the rect has drained")

	# ... and then the rect drains, the ring holds the edit, and it renders what the array just did.
	var queued := invalidated_texels() - before_invalidated
	terrain.vt_clipmap_budget_texels = 64 * 64
	settle_ring()
	diag("after_drain")
	require(valid_levels() == 1, "the level is current again")
	require(int(ring().get("pending_jobs", -1)) == 0, "with the rect drained")
	require(produced() == before_produced + queued,
			"the ring produced exactly the texels it queued: %d against %d" % [produced() - before_produced, queued])
	require(absf(sample(probe) - edited_reference) < 0.001, "and it holds the edited height")
	var settled_image := await frame_image()
	save_image(settled_image, "clipmap-height-settled.png")
	var settled_diff := differing(edited_image, settled_image)
	require(settled_diff == 0,
			"the re-produced ring renders what the array did, %d pixels differ" % settled_diff)
	if not failed:
		print("PASS clipmap height arm: the re-produced rect renders the edited height, pixel-identical to the array")

	# Deselecting stops the ring serving; the array is the renderer again, unchanged by any of this.
	terrain.vt_delivery_near_height = DIRECT
	await settle(2)
	require(terrain.vt_delivery_near_height == DIRECT, "the height cell takes Direct back")
	require(not shader_code().contains("_clipmap_atlas"), "and the ring leaves the generated shader")
	require(not clipmap_arm("height"), "and the report follows it")
	var restored_image := await frame_image()
	var restored_diff := differing(settled_image, restored_image)
	require(restored_diff == 0, "disabling the cell restores the array path, %d pixels differ" % restored_diff)

	# The same focus move, twice: the tick's phase follows the *cell* rather than the object. With a cell
	# selecting the method a move produces strips; with none it produces nothing at all, even though the
	# ring is still there and still needs the work - which the mechanism's own entry then shows by doing
	# it. This is the deselection branch the phase had no way to reach before the arm existed.
	terrain.vt_delivery_near_height = CLIPMAP
	await settle(4)
	settle_ring()
	var selected_base := produced()
	target.position = Vector3(42.0, 0.0, 30.0)
	await settle(8)
	var tick_produced := produced() - selected_base
	require(tick_produced > 0, "a move under a selected cell produces into the ring: %d texels" % tick_produced)
	settle_ring()
	terrain.vt_delivery_near_height = DIRECT
	await settle(4)
	var parked := produced()
	target.position = Vector3(54.0, 0.0, 30.0)
	await settle(8)
	require(produced() == parked, "the same move under a deselected cell produces nothing at all")
	require(int(settings().get("clipmap_produced_texels", -1)) == 0,
			"and the tick reports no clipmap production, entering no phase for a method no cell selects")
	require(terrain.debug_update_vt_clipmap(HEIGHT) > 0,
			"while the mechanism's own entry still steps the ring it kept")
	diag("deselected")
	if not failed:
		print("PASS clipmap height arm: the tick's phase follows the cell, and keeps nothing for a deselected ring")

	# ---- The material group's arm ----
	# The material channel's source is the packed `R16` surface payload - the same payload the group's
	# baked pages are produced from - and the ring here is one texel a metre, exactly the payload's own
	# grid. So a ring serving the material group's band must render the pixels the array renders, and a
	# ring four metres a texel must not: the identical pair is the ring's render rather than a fallback
	# agreeing with itself only because the coarse one differs.
	terrain.vt_clipmap_base_world = 64.0
	var mat_direct_image := await frame_image()
	save_image(mat_direct_image, "clipmap-material-direct.png")
	# The two painted ids and the two colours they render as, which is the reading behind "the material
	# the ring serves is the material the array serves": the payload varies (asserted in `setup()`), and
	# the picture shows it.
	var probe_a := mat_direct_image.get_pixelv(Vector2i(camera.unproject_position(Vector3(4.0, 0.0, 12.0))))
	var probe_b := mat_direct_image.get_pixelv(Vector2i(camera.unproject_position(Vector3(12.0, 0.0, 12.0))))
	print("CLIPMAP_MATERIAL_PROBE a=%s b=%s" % [str(probe_a), str(probe_b)])
	require(not shader_code().contains("clipmap_material_payload"),
			"an all-direct matrix compiles no material ring arm")

	terrain.vt_delivery_near_material = CLIPMAP
	await settle(4)
	require(terrain.vt_delivery_near_material == CLIPMAP, "the material group accepts Clipmap")
	require(terrain.is_vt_delivery_supported(MATERIAL, CLIPMAP), "and publishes it as deliverable")
	var mat_code := shader_code()
	save_text(mat_code, "clipmap-material-ring.glsl")
	require(mat_code.contains("clipmap_baked_material"),
			"selecting it compiles the ring's baked-material arm into the shader")
	# The ring's channel is the *material*, not the payload it is baked from: the payload read the arm
	# used before the baked layers existed is gone, and a fragment the layers cannot answer reads the
	# payload where the shipped paths keep it - the array or a page.
	require(not mat_code.contains("clipmap_material_payload"),
			"and no payload read of its own, because the ring carries the material")
	settle_material_ring()
	var mat_entry: Dictionary = settings().get("clipmap", {}).get("material", {})
	require(bool(mat_entry.get("configured", false)), "the ring exists for the material group")
	require(str(mat_entry.get("source", "")) == "material", "and names the channel it carries")
	require(int(mat_entry.get("valid_levels", 0)) >= 1, "with a current level")
	# A ring whose group no page carries is still a producer's owner: the bake is the same pass a
	# page runs, so this configuration has one and the ring's levels are baked rather than left
	# waiting for a producer that never comes. `baked_levels` is the handshake's own reading - a
	# level counts only after the dispatch that covered its rect landed - so this waits on the
	# render callback and not on the mechanism's entry.
	for frame in 240:
		if baked_levels() >= material_valid_levels() and material_valid_levels() > 0:
			break
		await process_frame
	settle_material_ring()
	require(material_baked_channels() == 3, "and carries the three arrays the bake writes")
	require(baked_levels() >= material_valid_levels() and material_valid_levels() > 0,
			"the producer baked every current level for the ring alone, %d of %d" % [
				baked_levels(), material_valid_levels()])
	require(pending_bake_rects() == 0,
			"with nothing left waiting for a producer, %d rects" % pending_bake_rects())
	# And the ring alone allocated no page pool. The producer's own storage reading is the one
	# place the two bundle shapes are distinguishable: a ring-only bundle owns the bake core and no
	# page-sized staging layer and no compressed page array.
	var ring_producer: Dictionary = settings().get("producer", {})
	require(int(ring_producer.get("staging_layers", -1)) == 0,
			"a ring-only producer owns no page staging layers, %d" % int(ring_producer.get("staging_layers", -1)))
	require(int(ring_producer.get("material_bytes", -1)) == 0,
			"and no page array bytes, %d" % int(ring_producer.get("material_bytes", -1)))
	var mat_ring_image := await frame_image()
	save_image(mat_ring_image, "clipmap-material-ring.png")
	var mat_ring_delta := channel_delta(mat_direct_image, mat_ring_image)
	print("CLIPMAP_MATERIAL_RING_DELTA differing=%d max=%.6f mean=%.6f strong=%d" % [
		differing(mat_direct_image, mat_ring_image), mat_ring_delta.x, mat_ring_delta.y,
		int(mat_ring_delta.z)])
	var mat_ring_arm: RID = terrain.material.get_material_rid()
	require(mat_outstanding_total(mat_ring_arm) == 0,
			"and the ring has nothing outstanding to fall back for, %d rects" % mat_outstanding_total(mat_ring_arm))
	# Which of the arm's two sources answered the fragment. The baked layer and the payload
	# evaluation are the same material read at different points - the bake evaluates at the level's
	# texel centres, the fallback at the fragment - so the two renders are close but not equal, and
	# the gate is what decides between them. Filling the arm's table with the level's whole stored
	# square refuses every tap, so the band reads the payload evaluation and the render must change;
	# binding the ring's own answer again must return the baked picture exactly.
	var ring_outstanding_bound: Variant = RenderingServer.material_get_param(mat_ring_arm, "_clipmap_outstanding")
	var ring_counts_bound: Variant = RenderingServer.material_get_param(mat_ring_arm, "_clipmap_outstanding_count")
	var ring_outstanding_full := PackedVector4Array()
	ring_outstanding_full.resize(32 * 4)
	ring_outstanding_full[0] = Vector4(0.0, 0.0, float(terrain.vt_clipmap_size), float(terrain.vt_clipmap_size))
	var ring_counts_full := PackedInt32Array()
	ring_counts_full.resize(32)
	ring_counts_full[0] = 1
	RenderingServer.material_set_param(mat_ring_arm, "_clipmap_outstanding", ring_outstanding_full)
	RenderingServer.material_set_param(mat_ring_arm, "_clipmap_outstanding_count", ring_counts_full)
	var mat_ring_fallback := await frame_image()
	save_image(mat_ring_fallback, "clipmap-material-ring-fallback.png")
	require(differing(mat_ring_image, mat_ring_fallback) > 0,
			"the baked layer is what answered the band: refusing it changes the render, %d pixels" % differing(mat_ring_image, mat_ring_fallback))
	RenderingServer.material_set_param(mat_ring_arm, "_clipmap_outstanding", ring_outstanding_bound)
	RenderingServer.material_set_param(mat_ring_arm, "_clipmap_outstanding_count", ring_counts_bound)
	var mat_ring_restored := await frame_image()
	require(differing(mat_ring_image, mat_ring_restored) == 0,
			"and the ring's own answer returns the baked picture, %d pixels differ" % differing(mat_ring_image, mat_ring_restored))
	if not failed:
		print("PASS clipmap material arm: the ring alone is baked, and its layers answer the band")

	# Direct restores the array, unchanged by any of this.
	terrain.vt_clipmap_base_world = 64.0
	terrain.vt_delivery_near_material = DIRECT
	await settle(6)
	require(not shader_code().contains("clipmap_baked_material"),
			"and the material arm leaves the generated shader")
	var mat_restored_image := await frame_image()
	var mat_restored_diff := differing(mat_direct_image, mat_restored_image)
	require(mat_restored_diff == 0,
			"disabling the material cell restores the array path, %d pixels differ" % mat_restored_diff)
	diag("material")

	# ---- The material group's baked layers ----
	# The section above is the ring *alone*: a producer exists because the ring's bake is the pass a
	# page runs, and the ring's own baked layers answer the band, which the gate reading there proves.
	# This section is the other producer's half: the same ring held at the far field's density, so the
	# two producers can be compared on one lattice and the material the pages hold can be read beside
	# the material the ring bakes.
	#
	# The pages have to be up for the producer to exist - the bake is a pass the *shared* producer runs,
	# and a ring owns no pass of its own - so the far field is selected and settled first. What it is
	# *not* is the density-matched reference this section would like to compare against: its levels run
	# from its own finest (an eighth of a metre a texel here) up to a root that covers the horizon, its
	# root pages are produced from a coarse source rather than from the payload at the root's own grid,
	# and the level a fragment is served by is the distance table's choice. A reference the ring can be
	# held to *exactly* is therefore the region array at the payload's density, which is what the
	# comparisons below use - the paged render is captured beside them as the picture of the other
	# producer, and a page whose rect is the ring's level is the configuration that would compare the two
	# producers against each other directly.
	#
	# The height section left the focus at (54, 30), which is a *move* of the ring's own square: the
	# visible square is centred on the camera at (30, 30), and a ring whose level only covered [22, 86]
	# would leave the western fifth of the view to the fallback - which is the design, and not what this
	# section is comparing. Put the focus back where the camera looks.
	target.position = Vector3(30.0, 0.0, 30.0)
	terrain.surface_svt_enabled = true
	terrain.surface_svt_page_world = 32.0
	terrain.surface_svt_distance = 512.0
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 64
	terrain.vt_pages_per_update = 8
	await settle_pages()
	require(ready_pages() > 0, "the far field produced the pages whose producer bakes the ring")
	# The ring is configured at the far field's own density, which is the one density the two producers
	# can be held at together: `size` texels over `size * far_texel` metres. Its levels run from its
	# finest (an eighth of a metre a texel here) up to a root that covers the horizon, and which of them
	# a fragment is served by is the distance table's choice - entry `m` is the largest camera distance
	# sampled at level `m`, and the CPU's demand pass resolves page levels with the same table, so the
	# level sampled is the level produced. One entry at the root pins every fragment, and every page, to
	# the level that is already resident for a view this size.
	#
	# Both sides then bake on the same lattice: the ring's level origin is a whole number of its texels
	# from the focus, the pages' origins are the world grid, and the two texel sizes are equal - so the
	# bake evaluates the same world positions for both, and the two renders are one material read twice.
	var far_report := settings()
	var far_root_mip := int(far_report.get("svt_effective_max_mip", 0))
	var far_root_world := float(far_report.get("svt_root_page_world", 0.0))
	require(far_root_world > 0.0 and far_root_mip > 0,
			"the far field publishes the level it can serve at its coarsest, %d at %.1f m a page" % [
				far_root_mip, far_root_world])
	var far_texel: float = far_root_world / float(terrain.vt_page_size)
	var mip_distances := PackedFloat32Array()
	mip_distances.resize(far_root_mip + 1)
	mip_distances[far_root_mip] = 4096.0
	terrain.set_surface_svt_mip_distances(mip_distances)
	await settle_pages()
	var ring_base_world := float(terrain.vt_clipmap_size) * far_texel
	terrain.vt_clipmap_base_world = ring_base_world
	require(is_equal_approx(terrain.vt_clipmap_base_world, ring_base_world),
			"the ring takes the far field's texel as its own, %.4f m" % far_texel)
	print("CLIPMAP_MATERIAL_DENSITY far_root_mip=%d far_root_world=%.1f far_texel=%.4f ring_base_world=%.1f" % [
		far_root_mip, far_root_world, far_texel, terrain.vt_clipmap_base_world])
	# The reference image: no ring on the near cell, so the paged tier answers every fragment.
	terrain.vt_delivery_near_material = DIRECT
	await settle(4)
	var mat_paged_image := await frame_image()
	save_image(mat_paged_image, "clipmap-material-paged.png")

	# The ring on the near cell, and the producer baking it: its three layers, written from the ring's
	# own payload and height by the same shader the pages are written by.
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(6)
	settle_material_ring()
	# The handshake as a reading: `baked` is set by the offer that *drains* a landed dispatch, so this
	# is the bake having run and reached the ring - not a claim that one was asked for.
	for frame in 240:
		if baked_levels() >= material_valid_levels() and material_valid_levels() > 0:
			break
		await process_frame
	settle_material_ring()
	require(material_valid_levels() > 0, "the material ring has a current level a bake can be taken on")
	require(material_baked_channels() == 3, "and carries the three arrays the bake writes")
	require(baked_levels() >= material_valid_levels(),
			"and the producer wrote every current level's baked layers, %d of %d" % [
				baked_levels(), material_valid_levels()])
	# And the arm is bound to them: the rects a fragment must not serve from are the ring's own, read back
	# from the material, and the generated code carries the arm that reads them.
	var arm_rid: RID = terrain.material.get_material_rid()
	require(shader_code().contains("clipmap_baked_material"),
			"the arm that samples the layers is compiled into the generated shader")
	require(mat_outstanding_total(arm_rid) == 0,
			"and a settled ring has nothing outstanding to bind, %d rects" % mat_outstanding_total(arm_rid))
	var mat_baked_image := await frame_image()
	save_image(mat_baked_image, "clipmap-material-baked.png")
	# The judge, as the two producers can meet it. They bake one material through one shader, but not
	# from one staging copy: a page's source is a staging array resampled at the page's own grid with the
	# page's own slope policy, while the ring's is its own payload layer - so the last bits of the values
	# differ, and where a shadow terminator falls on a texel-scale normal difference a few pixels flip.
	# What the pair *can* be held to is that they render one material: the mean channel difference stays
	# under half a step of an 8-bit image, and no more than a hundredth of a percent of the frame differs
	# visibly. A ring serving the wrong texel, the wrong density, or a payload evaluation instead of a
	# bake misses both by orders of magnitude - the array render below is that picture.
	var mat_paged_delta := channel_delta(mat_paged_image, mat_baked_image)
	var mat_paged_diff := differing(mat_paged_image, mat_baked_image)
	print("CLIPMAP_MATERIAL_PAGED_DELTA differing=%d max=%.6f mean=%.6f strong=%d" % [
		mat_paged_diff, mat_paged_delta.x, mat_paged_delta.y, int(mat_paged_delta.z)])
	require(mat_paged_delta.y <= 0.005,
			"the ring's baked layers render the paged material at their density: mean channel difference %.6f" % mat_paged_delta.y)
	require(int(mat_paged_delta.z) * 10000 <= mat_paged_image.get_width() * mat_paged_image.get_height(),
			"and no more than a hundredth of a percent of the frame differs visibly, %d pixels" % int(mat_paged_delta.z))
	# The source evaluation is the *other* picture at this density - the payload resolved per fragment on
	# the payload's own grid rather than the material at the level's texels - and the distance between
	# them is what the bound above is a fraction of. This is a reading rather than a claim: which of the
	# arm's two sources a fragment is answered from is the flag and the compiled arm above.
	var mat_baked_vs_array := differing(mat_direct_image, mat_baked_image)
	var mat_baked_vs_array_delta := channel_delta(mat_direct_image, mat_baked_image)
	print("CLIPMAP_MATERIAL_ARRAY_DELTA differing=%d mean=%.6f" % [
		mat_baked_vs_array, mat_baked_vs_array_delta.y])
	require(mat_baked_vs_array > 0,
			"while the source evaluation's picture is a different one, %d pixels differ" % mat_baked_vs_array)
	# ---- Which of the arm's two sources the fragment was answered from ----
	# The claim the whole step is about is that the material a fragment gets inside the ring's band is the
	# ring's *baked layers* and not a payload evaluated per fragment. The arm's gate is a uniform table,
	# so the test can fill one entry with a rect and watch: filling it with a rect of the level that the
	# camera cannot see must change *nothing* - the layers still answer every visible fragment - while
	# filling it with the level's whole square must change everything the band covers. The same trick
	# `vt_material` uses when it poisons a source array to prove ready pages bypass it.
	var outstanding_full := PackedVector4Array()
	outstanding_full.resize(32 * 4)
	outstanding_full[0] = Vector4(0.0, 0.0, float(terrain.vt_clipmap_size), float(terrain.vt_clipmap_size))
	var counts_full := PackedInt32Array()
	counts_full.resize(32)
	counts_full[0] = 1
	var outstanding_far := PackedVector4Array()
	outstanding_far.resize(32 * 4)
	outstanding_far[0] = Vector4(0.0, 0.0, 1.0, 1.0)
	var counts_far := PackedInt32Array()
	counts_far.resize(32)
	counts_far[0] = 1
	# The ring's own answer, read *before* anything is poisoned, so the restore below binds what the ring
	# would bind rather than what this reading wrote.
	var outstanding_bound: Variant = RenderingServer.material_get_param(arm_rid, "_clipmap_outstanding")
	var counts_bound: Variant = RenderingServer.material_get_param(arm_rid, "_clipmap_outstanding_count")
	# A rect the camera cannot see: the level is a kilometre across and the visible square is fifty
	# metres of its middle, so its first stored texel is half a level away.
	RenderingServer.material_set_param(arm_rid, "_clipmap_outstanding", outstanding_far)
	RenderingServer.material_set_param(arm_rid, "_clipmap_outstanding_count", counts_far)
	var mat_far_rect_image := await frame_image()
	require(differing(mat_baked_image, mat_far_rect_image) == 0,
			"a rect the camera cannot see leaves the render the layers', %d pixels differ" % differing(mat_baked_image, mat_far_rect_image))
	# The whole square: every fragment's taps are in it, so the arm answers none of them and the band
	# reads the array - a different material at this density.
	RenderingServer.material_set_param(arm_rid, "_clipmap_outstanding", outstanding_full)
	RenderingServer.material_set_param(arm_rid, "_clipmap_outstanding_count", counts_full)
	var mat_fallback_image := await frame_image()
	save_image(mat_fallback_image, "clipmap-material-fallback.png")
	var mat_fallback_delta := channel_delta(mat_baked_image, mat_fallback_image)
	print("CLIPMAP_MATERIAL_SOURCE_DELTA differing=%d mean=%.6f strong=%d" % [
		differing(mat_baked_image, mat_fallback_image), mat_fallback_delta.y, int(mat_fallback_delta.z)])
	require(int(mat_fallback_delta.z) > 0,
			"a rect covering the level is what decides the source: it changes the render, %d pixels" % int(mat_fallback_delta.z))
	# And binding the ring's own answer again returns the baked picture exactly.
	RenderingServer.material_set_param(arm_rid, "_clipmap_outstanding", outstanding_bound)
	RenderingServer.material_set_param(arm_rid, "_clipmap_outstanding_count", counts_bound)
	var mat_restored_gate_image := await frame_image()
	require(differing(mat_baked_image, mat_restored_gate_image) == 0,
			"and the ring's own rects return the baked picture, %d pixels differ" % differing(mat_baked_image, mat_restored_gate_image))

	# And a ring twice as coarse is *its* density, which is what makes the identical pair above a
	# density both producers reached rather than a picture neither of them is in.
	terrain.vt_clipmap_base_world = ring_base_world * 2.0
	await settle(6)
	settle_material_ring()
	for frame in 240:
		if baked_levels() >= material_valid_levels() and material_valid_levels() > 0:
			break
		await process_frame
	settle_material_ring()
	require(baked_levels() >= material_valid_levels() and material_valid_levels() > 0,
			"the coarser ring is current and baked too, %d of %d" % [baked_levels(), material_valid_levels()])
	var mat_baked_coarse_image := await frame_image()
	save_image(mat_baked_coarse_image, "clipmap-material-baked-coarse.png")
	var mat_baked_coarse_diff := differing(mat_baked_image, mat_baked_coarse_image)
	require(mat_baked_coarse_diff > 0,
			"a coarser baked ring renders its own density, %d pixels differ" % mat_baked_coarse_diff)
	if not failed:
		print("PASS clipmap material bake: the ring serves its own baked layers, and they are the material the pages hold")
	diag("material-baked")

	# ---- The bake's grain: a strip, not a level ----
	# The ring's whole point is that a level which turned by `d` texels re-produces `2 * size * d` of
	# them, so a bake that covered the level's square on every move would give that back: the strip
	# would cost a level's worth of device work, and it would be the *transfer* pattern the section 6.2
	# note already records as the ring's non-incremental half. The producer is handed the ring's own
	# rects, so this is a number rather than a claim: one texel of focus movement under a `Clipmap` cell
	# bakes `size * channels` channel texels - one column strip - where the level's square is
	# `size * size * channels`.
	terrain.vt_clipmap_base_world = ring_base_world
	await settle(6)
	settle_material_ring()
	for frame in 240:
		if baked_levels() >= material_valid_levels() and material_valid_levels() > 0:
			break
		await process_frame
	settle_material_ring()
	require(pending_bake_rects() == 0, "a settled ring owes the producer nothing, %d rects" % pending_bake_rects())
	var baked_before := baked_texels()
	var focus := target.position
	target.position = Vector3(focus.x + far_texel, focus.y, focus.z)
	await settle(6)
	settle_material_ring()
	for frame in 240:
		if baked_levels() >= material_valid_levels() and material_valid_levels() > 0:
			break
		await process_frame
	settle_material_ring()
	var baked_strip := baked_texels() - baked_before
	var level_texels := terrain.vt_clipmap_size * terrain.vt_clipmap_size * material_baked_channels()
	print("CLIPMAP_MATERIAL_BAKE_GRAIN strip=%d level=%d texels_per_texel_move=%d" % [
		baked_strip, level_texels, terrain.vt_clipmap_size * material_baked_channels()])
	require(baked_strip >= terrain.vt_clipmap_size * material_baked_channels(),
			"a one-texel focus move bakes the strip it produced, %d channel texels" % baked_strip)
	require(baked_strip <= terrain.vt_clipmap_size * material_baked_channels() * 2,
			"and not the level's square: %d against %d" % [baked_strip, level_texels])
	require(baked_levels() >= material_valid_levels() and material_valid_levels() > 0,
			"with the level baked again, %d of %d" % [baked_levels(), material_valid_levels()])
	require(pending_bake_rects() == 0, "and nothing left queued, %d rects" % pending_bake_rects())
	# And the strip bake left the *rest* of the level describing the world positions it already
	# described: the camera did not move, the pages did not move, so a level whose middle still holds
	# its material renders the same paged material the pre-move render did. A baked layer indexed in the
	# level's own moving frame - rather than in the stored one the ring's ring offset rotates - would
	# show the material shifted by the texel the focus moved, and this reading is what says so.
	var mat_moved_image := await frame_image()
	save_image(mat_moved_image, "clipmap-material-baked-moved.png")
	var mat_moved_delta := channel_delta(mat_paged_image, mat_moved_image)
	print("CLIPMAP_MATERIAL_MOVED_DELTA differing=%d max=%.6f mean=%.6f strong=%d" % [
		differing(mat_paged_image, mat_moved_image), mat_moved_delta.x, mat_moved_delta.y,
		int(mat_moved_delta.z)])
	require(mat_moved_delta.y <= 0.005,
			"a strip bake leaves the level's material where it was: mean channel difference %.6f" % mat_moved_delta.y)
	require(int(mat_moved_delta.z) * 10000 <= mat_paged_image.get_width() * mat_paged_image.get_height(),
			"and no more than a hundredth of a percent of the frame differs visibly, %d pixels" % int(mat_moved_delta.z))
	if not failed:
		print("PASS clipmap material bake: a strip bake keeps the rest of the level's material in place")
	target.position = focus
	await settle(2)
	diag("material-bake-grain")

	# ---- An edit, through the bake ----
	# An editor stroke is the ring's invalidation path, and on this half of the ring it has to reach the
	# device pass as well: the level that covers the stroke stops being current, the array serves until
	# the rect has drained, and the producer is then handed *that* rect - the same shape as the height
	# arm's stroke reading, with the bake in place of the CPU fill. The stroke is painted where the
	# camera looks, so it lands inside the ring's coverage rather than outside every level.
	var invalidations_before := int(material_ring().get("invalidation_calls", 0))
	var baked_before_edit := baked_texels()
	paint_material(Vector3(30.0, 0.0, 30.0), 1)
	terrain.data.update_maps()
	await settle(2)
	print("CLIPMAP_MATERIAL_EDIT calls=%d pending=%d valid=%d" % [
		int(material_ring().get("invalidation_calls", 0)) - invalidations_before,
		pending_bake_rects(), material_valid_levels()])
	require(int(material_ring().get("invalidation_calls", 0)) > invalidations_before,
			"the stroke reaches the material ring as an invalidation")
	settle_material_ring()
	for frame in 240:
		if baked_levels() >= material_valid_levels() and material_valid_levels() > 0:
			break
		await process_frame
	settle_material_ring()
	var baked_edit := baked_texels() - baked_before_edit
	print("CLIPMAP_MATERIAL_EDIT_BAKE rect=%d level=%d" % [baked_edit, level_texels])
	require(baked_edit > 0, "and the producer bakes the rect it queued, %d channel texels" % baked_edit)
	require(baked_edit < level_texels,
			"the stroked rect rather than the level's square: %d against %d" % [baked_edit, level_texels])
	require(material_valid_levels() > 0 and baked_levels() >= material_valid_levels(),
			"the level is current and baked again, %d of %d" % [baked_levels(), material_valid_levels()])
	require(pending_bake_rects() == 0, "with nothing left queued, %d rects" % pending_bake_rects())
	if not failed:
		print("PASS clipmap material bake: an edit re-bakes the rect it covers, not the ring")
	diag("material-edit")

	# ---- A focus that keeps moving ----
	# This is the reading the step's lease exists for. A bake is accepted only while the *rect* it covers
	# still carries the content it was queued with, so a focus that advances a texel every frame - which
	# produces a strip every frame and bumps the level's content serial every frame - must still land its
	# bakes: the strips do not overlap, so no rect's content changes under its own dispatch. A lease taken
	# from the *level* instead was measured to accept nothing at all while moving: the dispatches grew
	# while every one of them was refused and the queue grew with them.
	var dispatches_before_move := int(material_ring().get("bake_dispatches", 0))
	var rejects_before_move := int(material_ring().get("bake_rejects", 0))
	var focus_walk := target.position
	for step in 8:
		target.position = Vector3(focus_walk.x + far_texel * float(step + 1), focus_walk.y, focus_walk.z)
		await process_frame
		await process_frame
	var walked_dispatches := int(material_ring().get("bake_dispatches", 0)) - dispatches_before_move
	var walked_rejects := int(material_ring().get("bake_rejects", 0)) - rejects_before_move
	print("CLIPMAP_MATERIAL_WALK dispatches=%d rejects=%d pending=%d producer_dispatches=%d" % [
		walked_dispatches, walked_rejects, pending_bake_rects(),
		int(settings().get("producer", {}).get("ring_bake_dispatches", -1))])
	require(walked_dispatches > 0,
			"a moving focus lands its bakes: %d acknowledged while walking" % walked_dispatches)
	require(walked_rejects == 0,
			"and none of them is refused, because a strip no later production touched still describes it: %d" % walked_rejects)
	require(pending_bake_rects() <= 8,
			"while what is queued drains instead of growing, %d rects" % pending_bake_rects())
	target.position = focus_walk
	await settle(6)
	settle_material_ring()
	for frame in 240:
		if baked_levels() >= material_valid_levels() and material_valid_levels() > 0:
			break
		await process_frame
	settle_material_ring()
	require(baked_levels() >= material_valid_levels() and material_valid_levels() > 0,
			"and the ring is baked again once the focus stops, %d of %d" % [
				baked_levels(), material_valid_levels()])
	if not failed:
		print("PASS clipmap material bake: a moving focus lands its bakes, a strip at a time")

	terrain.vt_delivery_near_material = DIRECT
	terrain.surface_svt_enabled = false
	await settle(4)

	terrain.set_editor(null)
	terrain.set_plugin(null)
	painter.free()
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS clipmap height arm and material arm")
	quit()
