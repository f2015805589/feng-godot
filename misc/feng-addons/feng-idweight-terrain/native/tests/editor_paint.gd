# Run with a graphical rendering driver; see README.md in this directory.
#
# Editor paint paths. Terrain3DEditor::_operate_map() dispatches on the map type,
# and each tool writes a different representation, so every tool exercises a
# different branch:
#
#   HEIGHT map   SCULPT / HEIGHT        -> floats, plus region->update_height()
#   CONTROL map  HOLES / NAVIGATION /   -> the packed control word
#                AUTOSHADER
#   SURFACE map  TEXTURE                -> IdWeight R16, written as raw bytes
#   COLOR map    COLOR / ROUGHNESS      -> albedo, and its alpha channel
#
# region_slots.gd, texture_layers.gd, vt_density.gd and vt_render.gd all paint
# with the TEXTURE tool only, so the height, color and legacy control branches had
# no headless coverage at all. This test drives every tool/operation pair the
# toolbar can produce, asserts the visible effect of each one, and pins the
# resulting region maps with a digest so a refactor of _operate_map() cannot
# quietly drop a branch or change a write.
extends "res://vt_scene_base.gd"

const REGION_SIZE := 64
const PAINT_Y := 32.0
# The brush is 16 m of a 64 m region, centred on the region, so it writes the
# texel at the region centre and every texel around it.
const CENTER_TEXEL := Vector2i(32, 32)

# One phase per tool/operation pair the toolbar can emit, each on its own region
# so a digest describes exactly one branch. The brush is an all-white 16x16 RF
# mask, so alpha is 1.0 under the cursor and every write is a full-strength write
# (strength 100% * mouse pressure 1.0 = 1.0 m per click).
var phases: Array[Dictionary] = [
	{ "name": "sculpt_add", "tool": Terrain3DEditor.SCULPT, "operation": Terrain3DEditor.ADD },
	{ "name": "sculpt_subtract", "tool": Terrain3DEditor.SCULPT, "operation": Terrain3DEditor.SUBTRACT },
	{ "name": "sculpt_average", "tool": Terrain3DEditor.SCULPT, "operation": Terrain3DEditor.AVERAGE },
	# The trough/flatten branch clamps to the cursor height, so it only differs from
	# a plain raise when the cursor sits below the surface. At y = -0.5 only the
	# texels whose mask exceeds 0.5 get lifted, and by the cursor height, not by the
	# full strength.
	{ "name": "sculpt_trough_alt", "tool": Terrain3DEditor.SCULPT, "operation": Terrain3DEditor.ADD,
			"cursor_y": -0.5, "brush": { "modifier_alt": true } },
	# Gradient points are world space, so paint() builds them around the phase
	# centre instead of pinning them to one region.
	{ "name": "gradient", "tool": Terrain3DEditor.SCULPT, "operation": Terrain3DEditor.GRADIENT,
			"gradient_rel": true },
	{ "name": "height_add", "tool": Terrain3DEditor.HEIGHT, "operation": Terrain3DEditor.ADD,
			"brush": { "height": 5.0 } },
	{ "name": "color_add", "tool": Terrain3DEditor.COLOR, "operation": Terrain3DEditor.ADD,
			"brush": { "color": Color(1, 0, 0, 1) } },
	{ "name": "roughness_add", "tool": Terrain3DEditor.ROUGHNESS, "operation": Terrain3DEditor.ADD,
			"brush": { "roughness": 100.0 } },
	{ "name": "holes_add", "tool": Terrain3DEditor.HOLES, "operation": Terrain3DEditor.ADD },
	{ "name": "navigation_add", "tool": Terrain3DEditor.NAVIGATION, "operation": Terrain3DEditor.ADD },
	# A blank region's control map is COLOR_CONTROL, so the autoshader bit starts
	# *set* and only the clearing operation is observable.
	{ "name": "autoshader_subtract", "tool": Terrain3DEditor.AUTOSHADER, "operation": Terrain3DEditor.SUBTRACT },
	{ "name": "texture_replace", "tool": Terrain3DEditor.TEXTURE, "operation": Terrain3DEditor.REPLACE,
			"brush": { "asset_id": 1, "pair_overlay_id": 1, "pair_background_id": 0,
					"pair_mode": 0, "pair_weight_level": 8 } },
]

# The density > 1 phase paints separately because surface_density belongs to the
# region, not to the brush.
var dense_phase := {
	"name": "texture_replace_dense",
	"tool": Terrain3DEditor.TEXTURE,
	"operation": Terrain3DEditor.REPLACE,
	"brush": { "asset_id": 1, "pair_overlay_id": 1, "pair_background_id": 0,
			"pair_mode": 0, "pair_weight_level": 8 },
}

# Digest of height + control + color + surface for each phase, recorded on the
# engine this test was written against. A mismatch means the paint result moved.
var expected := {
	"sculpt_add": "0d75e0d14b0b786f",
	"sculpt_subtract": "0dc8b991a596e05a",
	"sculpt_average": "8e4be85680e64ec2",
	"sculpt_trough_alt": "a903bf192c1d7a6b",
	"gradient": "f499dd4ffdd170ed",
	"height_add": "0b82b30a3deec077",
	"color_add": "b7644e443a2f15cf",
	"roughness_add": "89cf78822cffd8bb",
	"holes_add": "30a071de59b56e45",
	"navigation_add": "ada50585a388d758",
	"autoshader_subtract": "e166266e6cea646a",
	"texture_replace": "23659618f5bd45f2",
	"texture_replace_dense": "e72c6b35c7ea8a05",
}

var painter: Terrain3DEditor
var scene: Node3D
var brush: Image
var output_dir := "user://"

func _initialize() -> void:
	call_deferred("run")

# Stand-ins for Terrain3DEditorPlugin's undo interface.
func create_undo_action(_name: String) -> void:
	pass
func add_undo_method(_action: Callable) -> void:
	pass
func add_do_method(_action: Callable) -> void:
	pass
func commit_action(_execute: bool) -> void:
	pass

func asset_texture(size: int, color: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func phase_center(index: int, phase: Dictionary = {}) -> Vector3:
	return Vector3(index * REGION_SIZE + REGION_SIZE * 0.5, float(phase.get("cursor_y", 0.0)), PAINT_Y)

func region_of(loc: Vector2i) -> Terrain3DRegion:
	for region in terrain.data.get_regions_active():
		if region.get_location() == loc:
			return region
	return null

# Paints one phase. `set_tool()` runs first because `set_brush_data()` clamps
# asset_id against the tool's id range.
func paint(index: int, phase: Dictionary) -> void:
	var position := phase_center(index, phase)
	var data := {
		"brush": [brush, ImageTexture.create_from_image(brush)],
		"size": 16.0,
		"strength": 100.0,
		"mouse_pressure": 1.0,
		"align_to_view": false,
		"brush_spin_speed": 0.0,
		"auto_regions": true,
		"modifier_alt": false,
		"modifier_ctrl": false,
	}
	if phase.get("gradient_rel", false):
		# A 16 m ramp across the brush: the centre texel lands a quarter of the way
		# up a 0..8 m ramp.
		data["gradient_points"] = PackedVector3Array([
				position + Vector3(-8.0, 0.0, 0.0), position + Vector3(8.0, 8.0, 0.0)])
	data.merge(phase.get("brush", {}), true)
	painter.set_tool(phase["tool"])
	painter.set_operation(phase["operation"])
	painter.set_brush_data(data)
	painter.start_operation(position)
	painter.operate(position, 0.0)
	painter.stop_operation()

# The packed control word is stored as the bit pattern of a FORMAT_RF float, so
# read it back through the float bits the same way the shader does.
func control_bits(region: Terrain3DRegion) -> int:
	return Terrain3DUtil.as_uint(region.get_control_map().get_pixelv(CENTER_TEXEL).r)

# surface_density > 1 stores a density x density block per region texel. The
# handler paints the block's first texel and replicates the painted word across
# the rest, so every texel of the block has to read back identical.
func check_dense_block(region: Terrain3DRegion) -> void:
	var density := region.get_surface_density()
	require(density == 2, "the dense phase ran at density %d, expected 2" % density)
	var surface := region.get_surface_map()
	require(surface != null and surface.get_width() == REGION_SIZE * density,
			"dense surface map is %d texels wide, expected %d" % [
					surface.get_width() if surface != null else -1, REGION_SIZE * density])
	var bytes := surface.get_data()
	var width := surface.get_width()
	var origin := Vector2i(CENTER_TEXEL.x * density, CENTER_TEXEL.y * density)
	var base := ((origin.y * width) + origin.x) * 2
	require(bytes.slice(base, base + 2) != PackedByteArray([0, 0]),
			"the dense block's first texel is empty, so replication proves nothing")
	for by in density:
		for bx in density:
			var offset := (((origin.y + by) * width) + origin.x + bx) * 2
			require(bytes.slice(offset, offset + 2) == bytes.slice(base, base + 2),
					"dense block texel (%d,%d) was not replicated" % [bx, by])

func check_digest(name: String, region: Terrain3DRegion) -> void:
	var got := digest(region)
	print("PAINT %s %s" % [name, got])
	var want: String = expected.get(name, "")
	if want == "":
		require(false, "%s: no digest recorded for this phase" % name)
	else:
		require(got == want, "%s: paint digest changed, %s != %s" % [name, got, want])

func digest(region: Terrain3DRegion) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for image: Image in [region.get_height_map(), region.get_control_map(),
			region.get_color_map(), region.get_surface_map()]:
		if image != null and not image.is_empty():
			ctx.update(image.get_data())
	return ctx.finish().hex_encode().substr(0, 16)

# The effect each tool is supposed to have at the centre of its own region.
func check_effect(name: String, region: Terrain3DRegion, position: Vector3) -> void:
	var height := region.get_height_map().get_pixelv(CENTER_TEXEL).r
	var color := region.get_color_map().get_pixelv(CENTER_TEXEL)
	match name:
		"sculpt_add":
			require(absf(height - 1.0) < 0.001, "sculpt ADD raised the texel to %f, expected 1.0" % height)
		"sculpt_subtract":
			require(absf(height + 1.0) < 0.001, "sculpt SUBTRACT lowered the texel to %f, expected -1.0" % height)
		"sculpt_average":
			require(absf(height) < 0.001, "sculpt AVERAGE moved a flat texel to %f" % height)
		"sculpt_trough_alt":
			require(absf(height - 0.5) < 0.001, "alt-drag trough raised the texel to %f, expected the 0.5 cursor height" % height)
		"gradient":
			require(absf(height - 4.25) < 0.001, "gradient lerped the texel to %f, expected 4.25 of the 0..8 ramp" % height)
		"height_add":
			require(absf(height - 5.0) < 0.001, "HEIGHT ADD lerped the texel to %f, expected 5.0" % height)
		"color_add":
			require(color.r > 0.99, "COLOR ADD left red at %f, expected the brush colour" % color.r)
		"roughness_add":
			require(color.a > 0.99, "ROUGHNESS ADD left alpha at %f, expected full wetness" % color.a)
		"holes_add":
			require(Terrain3DUtil.is_hole(control_bits(region)), "HOLES ADD did not set the hole bit")
		"navigation_add":
			require(Terrain3DUtil.is_nav(control_bits(region)), "NAVIGATION ADD did not set the nav bit")
		"autoshader_subtract":
			require(not Terrain3DUtil.is_auto(control_bits(region)), "AUTOSHADER SUBTRACT did not clear the auto bit")
		"texture_replace":
			var id := terrain.data.get_texture_id(position)
			require(id.y == 1 and id.z > 0.99, "TEXTURE REPLACE wrote overlay %d blend %f, expected 1 / 1.0" % [id.y, id.z])
	# Every phase must also leave the world-space readback consistent.
	require(absf(terrain.data.get_height(position) - height) < 0.05,
			"%s: get_height() %f disagrees with the height map texel %f" % [name, terrain.data.get_height(position), height])

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]

	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.free_editor_textures = false
	scene.add_child(terrain)
	root.add_child(scene)

	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = asset_texture(8, Color(0.5, 0.5, 0.5) if id == 0 else Color(1, 0, 0))
		asset.normal_texture = asset_texture(8, Color(0.5, 0.5, 1, 1))
		terrain.assets.set_texture_asset(id, asset)

	terrain.region_size = REGION_SIZE
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)

	# One region per phase: the toolbar cannot paint a map into a region that does
	# not exist yet, and separate regions keep the digests independent.
	for index in phases.size():
		terrain.data.add_region_blank(Vector2i(index, 0))

	# Baseline the blank control map, because two of the phases below only make
	# sense against it. Regions are filled with COLOR_CONTROL: autoshader on, hole
	# and navigation off.
	var blank := control_bits(region_of(Vector2i.ZERO))
	require(Terrain3DUtil.is_auto(blank), "a blank control map should start with the autoshader bit set")
	require(not Terrain3DUtil.is_hole(blank) and not Terrain3DUtil.is_nav(blank),
			"a blank control map should start with hole and navigation clear")

	for index in phases.size():
		var phase := phases[index]
		var name: String = phase["name"]
		var region := region_of(Vector2i(index, 0))
		if region == null:
			require(false, "%s: region %d was not created" % [name, index])
			continue
		paint(index, phase)
		check_effect(name, region, phase_center(index, phase))
		check_digest(name, region)

	# surface_density > 1 stores a density x density block per region texel, and the
	# handler replicates the painted word across it. Every phase above runs at the
	# default density of 1, where that loop is skipped entirely, so the block needs
	# a region of its own.
	var dense_index := phases.size()
	var dense_loc := Vector2i(dense_index, 0)
	terrain.data.add_region_blank(dense_loc)
	var dense := region_of(dense_loc)
	if dense == null:
		require(false, "the dense region was not created")
	else:
		dense.ensure_surface_density(2)
		paint(dense_index, dense_phase)
		check_dense_block(dense)
		check_digest("texture_replace_dense", dense)

	terrain.set_editor(null)
	terrain.set_plugin(null)
	painter.free()
	scene.queue_free()
	await process_frame
	if failed:
		quit(1)
		return
	print("PASS editor paint drives every tool through _operate_map")
	quit()
