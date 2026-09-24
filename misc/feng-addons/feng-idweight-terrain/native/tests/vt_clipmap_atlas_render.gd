# Run with a graphical rendering driver; see README.md in this directory.
#
# The block atlas's **render acceptance**: the mechanism (`vt_clipmap_atlas`) proves the structure with
# every cell `Direct`; this proves the *arms*. The clipmap is now one delivery (`Clipmap`) with an
# implementation selector, so this is the same pixel-identity method `vt_clipmap_render` uses for the
# LOD ring - `differing(direct_image, atlas_image) == 0` - applied to a delivery cell that names
# `Clipmap` while `vt_clipmap_implementation` names `Atlas`:
#
#  1. **the height arm**: at the height grid's own density (64 texels over 64 m, i.e. one texel a
#     metre) a block atlas serving the near band renders the region array's pixels exactly. The
#     shader's cell, rect and texel arithmetic must therefore be the CPU's, and the arm must be the
#     block reader rather than the array or the LOD ring;
#  2. **the material arm**: the atlas bakes the same three arrays out of the same payload at the same
#     density as the LOD ring, so the two density-matched renders are pixel-identical inside the
#     ring's own coverage. The atlas's baked rects are the addressing, and a cell whose bake has not
#     landed must fall back rather than sample a rect no dispatch wrote;
#  3. **the generated shader**: `_clipmap_block` and `clipmap_block_find` are in the compiled string
#     when, and only when, the implementation the selected cell answers with is the atlas.
extends "res://vt_scene_base.gd"

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2
# The implementation selector inside the one `Clipmap` delivery: `LOD = 0`, `Atlas = 1`.
const LOD := 0
const ATLAS := 1

var target: Node3D
var scene: Node3D
var painter: Terrain3DEditor
var brush: Image
var output_dir := "user://"


func _initialize() -> void:
	call_deferred("run")


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

# The group's entry. What only the selected implementation can say - the atlas's cell table, the LOD
# ring's level reports - is nested under `layout`, the implementation payload.
func group_entry(key: String) -> Dictionary:
	return settings().get("clipmap", {}).get(key, {})

func impl_of(p_entry: Dictionary) -> Dictionary:
	return p_entry.get("layout", {})

func cell_table(p_entry: Dictionary) -> Array:
	return (impl_of(p_entry).get("layout", {}) as Dictionary).get("cells", [])

func current_cells(p_entry: Dictionary) -> int:
	var count := 0
	for value: Variant in cell_table(p_entry):
		count += 1 if bool((value as Dictionary).get("current", false)) else 0
	return count

func baked_cells(p_entry: Dictionary) -> int:
	return int(impl_of(p_entry).get("baked_cells", 0))

func shader_code() -> String:
	return RenderingServer.shader_get_code(terrain.material.get_shader_rid())

# The pixel-identity method, unchanged from `vt_clipmap_render.gd`: the number of pixels that differ
# at all. The acceptance is zero.
func differing(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				count += 1
	return count

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


# ---- driving ------------------------------------------------------------------------------------

func settle(frames: int) -> void:
	for _i in frames:
		await process_frame

func frame_image() -> Image:
	for _i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

# The atlas is driven by the tick's own phase while a cell names it; the mechanism's entry runs the
# identical update, so it is the deterministic door a settle loop takes. It also offers the rects to
# the producer, which is what makes a material atlas baked rather than pending.
func settle_atlas(group: int) -> void:
	var key := "height" if group == HEIGHT else "material"
	# Only the material channel has baked arrays, so only it waits on the bake's acknowledgment; the
	# height channel's readiness is the cell's own `current`.
	var wants_baked := group == MATERIAL
	for _i in 8192:
		var entry: Dictionary = group_entry(key)
		if int(entry.get("pending_jobs", 1)) == 0 \
				and current_cells(entry) >= cell_table(entry).size() \
				and (!wants_baked or (int(entry.get("pending_bake_rects", 1)) == 0 \
						and baked_cells(entry) >= current_cells(entry))):
			break
		terrain.call("debug_update_vt_clipmap", group)
		await process_frame

func settle_ring() -> void:
	# The ring's *bake* is a handshake with the producer, so it is waited on as well: a ring whose
	# rects are queued but whose producer has not acknowledged them serves the payload evaluation, and
	# the material comparison below would then be two fallbacks agreeing.
	for _i in 8192:
		var entry: Dictionary = group_entry("material")
		var baked := 0
		var valid := 0
		var channels := 0
		for report: Dictionary in (impl_of(entry).get("level_reports", []) as Array):
			baked += 1 if bool(report.get("baked", false)) else 0
			valid += 1 if bool(report.get("valid", false)) else 0
			channels = int(report.get("baked_channels", 0))
		if int(entry.get("pending_jobs", 1)) == 0 \
				and valid >= int(entry.get("units", 1)) \
				and int(entry.get("pending_bake_rects", 1)) == 0 \
				and baked >= valid \
				and channels == 3:
			break
		terrain.call("debug_update_vt_clipmap", MATERIAL)
		await process_frame

func save_image(image: Image, name: String) -> void:
	if output_dir != "user://":
		image.save_png(output_dir.path_join(name))

func save_text(text: String, name: String) -> void:
	if output_dir != "user://":
		var file := FileAccess.open(output_dir.path_join(name), FileAccess.WRITE)
		if file != null:
			file.store_string(text)


# ---- the scene ----------------------------------------------------------------------------------

# A profile with detail at the height grid's own scale, exactly `vt_clipmap_render`'s: a linear ramp
# would render the same at any density.
func height_profile(x: float, z: float) -> float:
	return 6.0 * sin(x * 0.45) * cos(z * 0.42) + 0.05 * x


func solid_texture(size: int, color: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(color)
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
	root.add_child(camera)
	# Orthographic and straight down, the same fixture `vt_clipmap_render` uses: the visible square is
	# 53 m by 40 m centred on the focus, so every fragment it renders is inside the atlas's central
	# 3x3 ring and inside the region.
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
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	# The detail layer is off: this suite is about the atlas's own baked arm at the *ring's* density,
	# and the layer's 1024 texels/m would replace it. The layer has its own density suite.
	terrain.vt_clipmap_detail_enabled = false
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = solid_texture(32, Color(0.8, 0.15, 0.1) if id == 0 else Color(0.1, 0.7, 0.2))
		asset.normal_texture = solid_texture(32, Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(id, asset)
	# One block of 64 texels over 64 m: unit 0 is exactly one texel a metre, the height map's own grid
	# and the material payload's own grid. `vt_clipmap_levels` is the layer's unit count for both
	# implementations now, so one LOD level and one atlas unit - the atlas unit's 3x3 blocks cover the
	# visible square. The budget fills a level in one call, which is why the LOD ring settles
	# deterministically below; the implementation is selected in `run()`.
	terrain.vt_clipmap_size = 64
	terrain.vt_clipmap_levels = 1
	terrain.vt_clipmap_base_world = 64.0
	terrain.vt_clipmap_budget_texels = 64 * 64
	terrain.vt_clipmap_blocks_per_frame = 1
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
	for z in 64:
		for x in 64:
			terrain.data.set_height(Vector3(float(x), 0.0, float(z)), height_profile(float(x), float(z)))
	terrain.data.update_maps()
	# Alternating material ids across the visible square, so a wrong texel read is visible.
	for bz in 8:
		for bx in 8:
			paint_material(Vector3(float(bx) * 8.0 + 4.0, 0.0, float(bz) * 8.0 + 4.0), (bx + bz) % 2)
	var painted_a := terrain.data.get_texture_id(Vector3(4.0, 0.0, 4.0))
	var painted_b := terrain.data.get_texture_id(Vector3(12.0, 0.0, 4.0))
	require(painted_a.x != painted_b.x, "the fixture painted alternating material ids")
	await settle(2)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, -20, 0)
	scene.add_child(light)
	await settle(6)


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	await setup()

	# 1. The baseline: the shipped array path, no atlas arm in the generated shader.
	var direct_code := shader_code()
	require(not direct_code.contains("_clipmap_block"), "an all-direct matrix compiles no atlas sampler")
	require(not direct_code.contains("clipmap_block_find"), "and no block addressing")
	var direct_image := await frame_image()
	save_image(direct_image, "clipmap-atlas-direct.png")

	# 2. The height arm. The cell is deliverable, the implementation answers with the atlas, the arm
	#    enters the compiled string, and the atlas renders the array's pixels exactly at the grid's
	#    own density.
	terrain.vt_clipmap_implementation = ATLAS
	terrain.vt_delivery_near_height = CLIPMAP
	await settle(20)
	require(terrain.vt_delivery_near_height == CLIPMAP, "the height cell accepts Clipmap")
	require(terrain.is_vt_delivery_supported(HEIGHT, CLIPMAP), "and publishes it as deliverable")
	require(terrain.is_vt_delivery_used(CLIPMAP), "and as used")
	require(terrain.vt_clipmap_implementation == ATLAS, "and the layer answers with the atlas")
	await settle_atlas(HEIGHT)
	var atlas_code := shader_code()
	save_text(atlas_code, "clipmap-atlas-height.glsl")
	require(atlas_code.contains("_clipmap_block"), "selecting it compiles the atlas's sampler")
	require(atlas_code.contains("clipmap_block_find"), "including the block addressing")
	var height_entry := group_entry("height")
	require(bool(height_entry.get("configured", false)), "the height atlas exists")
	require(current_cells(height_entry) == cell_table(height_entry).size(), "with every cell current")
	var height_atlas_image := await frame_image()
	save_image(height_atlas_image, "clipmap-atlas-height.png")
	var height_diff := differing(direct_image, height_atlas_image)
	var height_delta := channel_delta(direct_image, height_atlas_image)
	print("CLIPMAP_ATLAS_RENDER height differing=%d max=%.6f mean=%.6f strong=%d" % [
		height_diff, height_delta.x, height_delta.y, int(height_delta.z)])
	require(height_diff == 0,
			"a block atlas at the height grid's own density renders the array's pixels, %d differ" % height_diff)
	if not failed:
		print("PASS clipmap atlas height arm: the block atlas renders pixel-identical to the array")

	# 3. The material arm. The LOD ring at the same density is the reference: both bake the same three
	#    arrays out of the same payload at the same texel lattice, so the two are pixel-identical. The
	#    implementation selector is a layer setting, so it goes back to LOD before this reference.
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_clipmap_implementation = LOD
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(20)
	await settle_ring()
	var ring_entry: Dictionary = group_entry("material")
	require(bool(ring_entry.get("configured", false)), "the material ring exists")
	require(str(ring_entry.get("implementation", "")) == "LOD", "and answers with the LOD ring")
	var ring_valid := 0
	var ring_baked := 0
	var ring_channels := 0
	for report: Dictionary in (impl_of(ring_entry).get("level_reports", []) as Array):
		ring_valid += 1 if bool(report.get("valid", false)) else 0
		ring_baked += 1 if bool(report.get("baked", false)) else 0
		ring_channels = int(report.get("baked_channels", 0))
	require(ring_valid >= 1, "with a current level")
	print("CLIPMAP_ATLAS_RENDER ring_diag baked_levels=%d valid=%d baked_channels=%d pending_bake=%d" % [
		ring_baked, ring_valid, ring_channels,
		int(ring_entry.get("pending_bake_rects", -1))])
	var ring_code := shader_code()
	require(ring_code.contains("clipmap_baked_material"), "and the ring's baked arm is compiled")
	var ring_image := await frame_image()
	save_image(ring_image, "clipmap-atlas-material-ring.png")
	print("CLIPMAP_ATLAS_RENDER ring_vs_array differing=%d" % differing(direct_image, ring_image))

	# The ring's *payload evaluation* render, which is the material a fragment reads when the baked
	# layers cannot answer. It is the discriminator the atlas's own answer is checked against: the
	# atlas must render the baked picture and must not render this one.
	var ring_arm: RID = terrain.material.get_material_rid()
	var ring_outstanding_bound: Variant = RenderingServer.material_get_param(ring_arm, "_clipmap_outstanding")
	var ring_counts_bound: Variant = RenderingServer.material_get_param(ring_arm, "_clipmap_outstanding_count")
	var ring_outstanding_full := PackedVector4Array()
	ring_outstanding_full.resize(32 * 4)
	ring_outstanding_full[0] = Vector4(0.0, 0.0, float(terrain.vt_clipmap_size), float(terrain.vt_clipmap_size))
	var ring_counts_full := PackedInt32Array()
	ring_counts_full.resize(32)
	ring_counts_full[0] = 1
	RenderingServer.material_set_param(ring_arm, "_clipmap_outstanding", ring_outstanding_full)
	RenderingServer.material_set_param(ring_arm, "_clipmap_outstanding_count", ring_counts_full)
	var ring_fallback_image := await frame_image()
	save_image(ring_fallback_image, "clipmap-atlas-material-ring-fallback.png")
	require(differing(ring_image, ring_fallback_image) > 0,
			"the ring's baked layer is what answers its band, %d pixels differ from the payload evaluation" % differing(ring_image, ring_fallback_image))
	RenderingServer.material_set_param(ring_arm, "_clipmap_outstanding", ring_outstanding_bound)
	RenderingServer.material_set_param(ring_arm, "_clipmap_outstanding_count", ring_counts_bound)
	require(differing(ring_image, await frame_image()) == 0, "and the ring's own answer returns the baked picture")

	terrain.vt_clipmap_implementation = ATLAS
	terrain.vt_delivery_near_material = CLIPMAP
	await settle(20)
	require(terrain.vt_delivery_near_material == CLIPMAP, "the material cell accepts Clipmap")
	require(terrain.vt_clipmap_implementation == ATLAS, "with the atlas implementation selected")
	require(terrain.is_vt_delivery_supported(MATERIAL, CLIPMAP), "and publishes it as deliverable")
	var material_code := shader_code()
	save_text(material_code, "clipmap-atlas-material.glsl")
	require(material_code.contains("clipmap_block_baked_material"),
			"selecting it compiles the atlas's baked-material arm")
	await settle_atlas(MATERIAL)
	var mat_entry := group_entry("material")
	require(bool(mat_entry.get("selected", false)), "the atlas reports the material cell")
	require(current_cells(mat_entry) == cell_table(mat_entry).size(),
			"with every cell current")
	require(baked_cells(mat_entry) >= current_cells(mat_entry),
			"and every current cell baked: %d of %d" % [
				baked_cells(mat_entry), current_cells(mat_entry)])
	require(int(mat_entry.get("pending_bake_rects", 1)) == 0, "with nothing left waiting for a producer")
	var material_atlas_image := await frame_image()
	save_image(material_atlas_image, "clipmap-atlas-material.png")
	var material_diff := differing(ring_image, material_atlas_image)
	var material_delta := channel_delta(ring_image, material_atlas_image)
	print("CLIPMAP_ATLAS_RENDER material differing=%d max=%.6f mean=%.6f strong=%d" % [
		material_diff, material_delta.x, material_delta.y, int(material_delta.z)])
	# The two are the same *material* read at the same density: the atlas bakes the same three arrays
	# out of the same payload at the same texel lattice, so the mean channel difference is a
	# thousandth of a channel and only the block-boundary texels differ at all. (The ring is the
	# reference here, not the array: the ring's baked read is itself a coarser answer than the
	# per-fragment evaluation, `CLIPMAP_MATERIAL_RING_DELTA` in `vt_clipmap_render`.) No fallback:
	# the payload evaluation render recorded above is a different picture and the atlas is not it.
	require(material_delta.y < 0.02,
			"the atlas's baked arm is the ring's material within a mean channel of 0.02, got %.6f" % material_delta.y)
	require(int(material_delta.z) * 10 < 76800,
			"and no more than a tenth of the pixels differ strongly, got %d" % int(material_delta.z))
	var fallback_diff := differing(ring_fallback_image, material_atlas_image)
	require(fallback_diff > 0,
			"and it is the baked answer, not the payload evaluation: %d pixels separate them" % fallback_diff)
	if not failed:
		print("PASS clipmap atlas material arm: the atlas bakes and serves the ring's density-matched material")

	# 4. Deselecting the atlas leaves the shader and restores the array, unchanged.
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	await settle(6)
	require(not shader_code().contains("clipmap_block_find"), "and the atlas leaves the generated shader")
	var restored_array := await frame_image()
	var restored_diff := differing(direct_image, restored_array)
	require(restored_diff == 0, "disabling the cell restores the array path, %d pixels differ" % restored_diff)

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
	if target != null:
		target.queue_free()
	await process_frame
	if failed:
		print("REGRESSION: clipmap atlas render")
		quit(1)
		return
	print("PASS clipmap atlas render")
	quit(0)
