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
# The material group stays `Direct` in every render, so the only difference between two images is the
# height group's source. Read `docs/vt_delivery_assembly.md` section 6 for the design; the group index
# is Material=0/Height=1 and the delivery values are Direct=0/AVT=1/Clipmap=2/SVT=3, i.e. the native
# `TerrainVT` enum values, which are also the property values.
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


func diag(label: String) -> void:
	print("VT_CLIPMAP_RENDER_DIAG %s height=%s shader_arm=%s ring_arm=%s valid=%d pending=%d produced=%d invalidated=%d calls=%d" % [
		label, str(terrain.vt_delivery_near_height), str(settings().get("vt_shader_arms", "?")),
		str(settings().get("vt_shader_height_clipmap", "?")), valid_levels(),
		int(ring().get("pending_jobs", -1)), produced(), invalidated_texels(), invalidation_calls()])


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
	# against, and the material group stays direct in every render below.
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_height = DIRECT
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


func save_image(image: Image, name: String) -> void:
	if output_dir != "user://":
		image.save_png(output_dir.path_join(name))


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
	require(not bool(settings().get("vt_shader_height_clipmap", true)), "and the report says so")
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
	require(bool(settings().get("vt_shader_height_clipmap", false)), "and the report says so")
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
	require(not bool(settings().get("vt_shader_height_clipmap", true)), "and the report follows it")
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

	terrain.set_editor(null)
	terrain.set_plugin(null)
	painter.free()
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS clipmap height arm")
	quit()
