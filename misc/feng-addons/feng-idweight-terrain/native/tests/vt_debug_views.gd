# Run with a graphical rendering driver; see README.md in this directory.
#
# The two debug views the delivery matrix gates, plus the order the editor reads in.
#
# Four claims, all of them about what is *shown* rather than about what exists, which is why three of
# them are made by driving the Controls and one by rendering them:
#
#   1. **The order.** The native `Surface VT` group is registered in the order the layer assembles -
#      `VT Setting` with the delivery matrix as the first thing inside it, then `Clipmap`, `AVT`,
#      `SVT`, `CDLOD`, `VT Page` - and the Surface VT window's hierarchy reads in the same order.
#      This is a property of the registered property list, so it is asserted from that list rather
#      than from a screenshot of the Inspector. The dock's Clipmap group offers the one delivery's
#      implementation selector beside its shape and writes the native `vt_clipmap_implementation`.
#   2. **The clipmap view draws the selected implementation.** The Control is given a real terrain
#      whose height layer the mechanism's entry built, a focus with a queued whole-level job, and is
#      rendered into a SubViewport: the check counts the pixels that are not background, the pixels of
#      the queued strips' own colour, and the pixels of the coverage plot's own colour - because "the
#      debug view shows blocks and the density it serves" is otherwise a claim about a picture. The
#      implementation is then switched to the atlas and the same control must draw the region and the
#      grid instead, over the same coverage plot. The screenshots are kept.
#   3. **The gates.** A Control whose view has nothing behind it - no layer for the clipmap, no cell
#      selecting AVT for the layout - reports itself unavailable, hides itself, and never calls the
#      native preview: measured with the two counter pairs in `get_vt_settings()`
#      (`avt_preview_computed` / `clipmap_preview_computed` do not move while the calls do). The
#      clipmap's gate is the layer *object* rather than a matrix cell, which is the whole of the
#      difference in a build that refuses the cell for every group: the layer appears while no cell
#      claims the method, and the view follows the layer.
#
# Read `docs/vt_delivery_assembly.md` section 6 for the layer and the view; the group ids are
# Material=0/Height=1, the tiers Near=0/Far=1 and the delivery values are the native enum
# values, Direct=0/AVT=1/Clipmap=2/SVT=3. The implementations are LOD=0/Atlas=1.
extends SceneTree

const NEAR := 0
const FAR := 1
const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const AVT := 1
const CLIPMAP := 2
const SVT := 3

# A three-unit layer of 64 texels an axis: unit 0 covers 64 m in 64 texels (1 m a texel), unit 2
# covers 256 m. The unit strip cuts each square into 4-texel blocks, which is the picture the view
# exists to draw, and the map's extent is the coarsest unit's own 256 m.
const SIZE := 64
const LEVELS := 3
const BASE_WORLD := 64.0
const LEVEL_TEXELS := SIZE * SIZE
const VIEWPORT_SIZE := Vector2i(440, 420)
const CLIPMAP_PREVIEW_SCRIPT := "res://addons/feng-idweight-terrain/src/vt_clipmap_preview.gd"
const AVT_PREVIEW_SCRIPT := "res://addons/feng-idweight-terrain/src/vt_avt_layout_preview.gd"
const VT_EDITOR_SCRIPT := "res://addons/feng-idweight-terrain/src/vt_editor.gd"

var terrain: Terrain3D
var target: Node3D
var camera: Camera3D
var viewport: SubViewport
var failed := false


func _initialize() -> void:
	call_deferred("run")


func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true


func settings() -> Dictionary:
	return terrain.get_vt_settings()


# The mechanism's own entry, which is how the layer is built and stepped here: no cell may name
# `Clipmap` in this build, so the tick enters no clipmap phase and the layer is driven by
# `debug_update_vt_clipmap()` - the same update, focus and budget that phase runs.
func tick() -> void:
	await process_frame
	terrain.call("debug_update_vt_clipmap", HEIGHT)


func settle(frames: int) -> void:
	for _i in frames:
		await process_frame


# Ticks until the height layer has no job queued. The caller sets the budget high first, so the count
# this spends is the number of units, not a wait.
func drained(p_limit: int = 32) -> void:
	var spent := 0
	while int(settings().get("clipmap", {}).get("height", {}).get("pending_jobs", 0)) > 0 and spent < p_limit:
		await tick()
		spent += 1


# The Controls poll their gate on a timer, so a test drives one poll at a time rather than waiting
# for wall-clock seconds: the poll interval is reset to "long ago", then `_process` runs once.
func poll(p_control: Control) -> void:
	p_control.set("_last_poll_sec", -INF)
	p_control.call("_process", 0.0)
	await process_frame


# The preview's one layer and its units, read out of the payload the control stored. The helpers keep
# the assertions below naming the new schema (`layers` / `unit_reports`) in one place.
func clipmap_layer(p_snapshot: Dictionary) -> Dictionary:
	var layers: Array = p_snapshot.get("layers", [])
	return layers[0] if layers.size() > 0 else {}


func clipmap_units(p_snapshot: Dictionary) -> Array:
	return clipmap_layer(p_snapshot).get("unit_reports", [])


# The valid units of the first configured layer, which is the reading "the budget drained it" needs.
func clipmap_unit_count(p_settings: Dictionary) -> int:
	var layers: Dictionary = p_settings.get("clipmap", {})
	for group in ["height", "material"]:
		var entry: Dictionary = layers.get(group, {})
		if typeof(entry) != TYPE_DICTIONARY or not bool(entry.get("configured", false)):
			continue
		var valid := 0
		for value: Variant in entry.get("unit_reports", []):
			if typeof(value) == TYPE_DICTIONARY and bool((value as Dictionary).get("valid", false)):
				valid += 1
		return valid
	return 0


func setup() -> void:
	target = Node3D.new()
	target.position = Vector3(32.5, 0.0, 32.5)
	root.add_child(target)

	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	# Every cell direct to start with, so the first reading is the state the requirement is about: a
	# method no cell selects owns no layer, so its view must not draw and must not ask.
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.vt_clipmap_size = SIZE
	terrain.vt_clipmap_levels = LEVELS
	terrain.vt_clipmap_base_world = BASE_WORLD
	terrain.vt_clipmap_budget_texels = LEVEL_TEXELS
	terrain.set_camera(camera)
	terrain.set_clipmap_target(target)
	root.add_child(terrain)
	terrain.data.add_region_blank(Vector2i.ZERO)
	for z in 97:
		for x in 97:
			terrain.data.set_height(Vector3(x, 0.0, z), x * 0.25 + z * 0.5)
	await settle(4)
	terrain.set_physics_process(false)


# ---- 1. the order the editor reads in -----------------------------------------------------------

func check_group_order() -> void:
	var names: Array[String] = []
	for property in terrain.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_SUBGROUP:
			names.append(str(property.name))
	# The empty entry is the subgroup that closes the settings group before `surface_array_enabled`.
	var expected := ["VT Setting", "Clipmap", "", "AVT", "SVT", "CDLOD", "VT Page"]
	require(names.size() >= expected.size() and names.slice(0, expected.size()) == expected,
			"native Surface VT subgroups are not in assembly order: %s" % str(names))
	var matrix_index := -1
	var clipmap_index := -1
	for index in names.size():
		if names[index] == "VT Setting":
			matrix_index = index
		if names[index] == "Clipmap":
			clipmap_index = index
	require(matrix_index == 0 and clipmap_index == 1,
			"the settings group and the layer's shape must come first, in that order: %s" % str(names))


func check_dock_order() -> void:
	var window: Window = load(VT_EDITOR_SCRIPT).new()
	window.initialize(null)
	root.add_child(window)
	window.set_terrain(terrain)
	var surface: TreeItem = window.hierarchy.get_root().get_first_child()
	require(surface != null and surface.get_text(0) == "Surface VT",
			"the Surface VT window did not build its hierarchy root")
	var names: Array[String] = []
	var item: TreeItem = surface.get_first_child()
	while item:
		names.append(item.get_text(0))
		item = item.get_next()
	require(names == ["VT Setting", "Clipmap", "AVT", "SVT", "CDLOD", "VT Page"],
			"the Surface VT window's hierarchy is not in assembly order: %s" % str(names))
	# The layer's own node is where its storage, shape and budget are configured, and a write there has
	# to land on the native property rather than on a widget the next refresh overwrites.
	var clipmap_item: TreeItem = surface.get_first_child().get_next()
	clipmap_item.select(0)
	window.hierarchy.item_selected.emit()
	await process_frame
	require(window.clipmap_panel.visible and window.clipmap_size_spin != null and
			window.clipmap_levels_spin != null and window.clipmap_base_spin != null and
			window.clipmap_budget_spin != null and window.clipmap_implementation_option != null,
			"the Clipmap node did not show the layer's storage, shape and budget")
	var saved_size: int = terrain.vt_clipmap_size
	window.clipmap_size_spin.value = 32.0
	require(terrain.vt_clipmap_size == 32, "the level edge control did not write the native setting")
	window.clipmap_size_spin.value = float(saved_size)
	require(terrain.vt_clipmap_size == saved_size, "the level edge control did not write the setting back")
	# The one delivery's implementation selector: its items are the native enum's two storages in order,
	# and a click has to reach `vt_clipmap_implementation`.
	var implementation_option: OptionButton = window.clipmap_implementation_option
	require(implementation_option.item_count == 2 and
			implementation_option.get_item_text(implementation_option.get_item_index(0)) == "LOD" and
			implementation_option.get_item_text(implementation_option.get_item_index(1)) == "Atlas",
			"the implementation selector must offer LOD and Atlas in the native enum's order")
	var saved_implementation: int = terrain.vt_clipmap_implementation
	var atlas_index: int = implementation_option.get_item_index(1)
	implementation_option.select(atlas_index)
	implementation_option.item_selected.emit(atlas_index)
	await process_frame
	require(terrain.vt_clipmap_implementation == 1,
			"the implementation selector did not write the native setting")
	var lod_index: int = implementation_option.get_item_index(saved_implementation)
	implementation_option.select(lod_index)
	implementation_option.item_selected.emit(lod_index)
	await process_frame
	require(terrain.vt_clipmap_implementation == saved_implementation,
			"the implementation selector did not write the setting back")
	# The VT Page's third child is the layer's debug view, which is the page the requirement asks for.
	var pages_item: TreeItem = clipmap_item.get_next().get_next().get_next().get_next()
	require(pages_item != null and pages_item.get_text(0) == "VT Page", "the hierarchy lost its VT Page node")
	var page_names: Array[String] = []
	var page: TreeItem = pages_item.get_first_child()
	while page:
		page_names.append(page.get_text(0))
		page = page.get_next()
	require(page_names.has("Clipmap ring"), "the VT Page did not list its clipmap view: %s" % str(page_names))
	var clipmap_page: TreeItem = pages_item.get_first_child()
	while clipmap_page and str(clipmap_page.get_metadata(0)) != "clipmap_debug":
		clipmap_page = clipmap_page.get_next()
	require(clipmap_page != null, "the VT Page's clipmap view carries no clipmap_debug metadata")
	clipmap_page.select(0)
	window.hierarchy.item_selected.emit()
	await process_frame
	var control: Control = window.find_child("ClipmapDebugPreview", true, false) as Control
	require(window.clipmap_debug_panel.visible and control != null,
			"the VT Page's clipmap page did not show the debug view")
	require(not bool(control.call("is_available")),
			"and it must report itself unavailable while no layer exists")
	# The panel's own half of the acceptance rule: the height row offers the two methods the channel
	# has (Direct and the clipmap) and disables the other two, while the diffuse+normal row offers all
	# four - the layer carries that group's `R16` control payload, and AVT/SVT page it - which is the
	# asymmetry as a user sees it, read from the widget a click would hit. The window in this harness is
	# never shown, so its periodic refresh never runs; `open_vt_page_view()` is the public entry that
	# refreshes it.
	window.call("open_vt_page_view")
	await process_frame
	var height_row: OptionButton = window.delivery_near_height
	var material_row: OptionButton = window.delivery_near_material
	require(height_row != null and material_row != null, "the window has no delivery rows for both groups")
	if height_row == null or material_row == null:
		return
	require(not height_row.is_item_disabled(height_row.get_item_index(DIRECT)) and
			not height_row.is_item_disabled(height_row.get_item_index(CLIPMAP)),
			"the height row must keep Direct and Clipmap, the two methods the channel has")
	require(height_row.is_item_disabled(height_row.get_item_index(AVT)) and
			height_row.is_item_disabled(height_row.get_item_index(SVT)),
			"and disable AVT and SVT, neither of which is a method the height channel has")
	require(not material_row.is_item_disabled(material_row.get_item_index(CLIPMAP)),
			"the diffuse+normal row offers Clipmap as well: the layer has a source for that channel")
	require(not material_row.is_item_disabled(material_row.get_item_index(AVT)) and
			not material_row.is_item_disabled(material_row.get_item_index(SVT)),
			"and AVT and SVT stay available there: the same method is offered or refused per group")
	var clipmap_reason: String = height_row.get_item_tooltip(height_row.get_item_index(CLIPMAP))
	require(clipmap_reason.is_empty(),
			"an item this build can deliver carries no refusal as its tooltip: %s" % clipmap_reason)
	var svt_reason: String = height_row.get_item_tooltip(height_row.get_item_index(SVT))
	require(svt_reason.contains("AVT and SVT page the diffuse+normal group"),
			"and a disabled item carries the reason as its tooltip: %s" % svt_reason)
	print("VT_DEBUG_DOCK nodes=%s pages=%s" % [str(names), str(page_names)])
	window.queue_free()
	await process_frame


# ---- 2 and 3: the clipmap view, its gate and its drawing ----------------------------------------

func check_clipmap_view() -> void:
	var control: Control = load(CLIPMAP_PREVIEW_SCRIPT).new()
	control.size = Vector2(VIEWPORT_SIZE)
	viewport.add_child(control)
	control.set_terrain(terrain)

	# Unselected: no layer exists, so the view hides itself and the preview is never asked for. The
	# counters are the reading - an ask that is refused moves `clipmap_preview_calls` and not
	# `..._computed`.
	var before := settings()
	await poll(control)
	require(not bool(control.call("is_available")), "the clipmap view must be unavailable while no layer exists")
	require(not control.visible, "and must hide itself")
	var refused := settings()
	require(int(refused.get("clipmap_preview_calls", 0)) == int(before.get("clipmap_preview_calls", 0)),
			"a hidden view must not even ask for a layout")
	require(int(refused.get("clipmap_preview_computed", 0)) == int(before.get("clipmap_preview_computed", 0)),
			"and nothing may be computed in that state")

	# The layer appears - built by the mechanism's entry, since this build refuses the cell for every
	# group - and the view follows the *object*: it appears and asks, natively through the same preview
	# the layer publishes, with no delivery cell involved. The entry is given a budget of every unit so
	# the layer settles in the same call: the steps below need an empty job queue with every unit valid,
	# which is the state a stationary focus leaves a layer in, and a job left queued from the build would
	# make the teleport below describe the first focus instead of its own.
	terrain.vt_clipmap_budget_texels = LEVEL_TEXELS * LEVELS
	require(terrain.debug_update_vt_clipmap(HEIGHT) > 0, "the mechanism's entry builds and fills the layer")
	await drained()
	require(clipmap_unit_count(settings()) == LEVELS,
			"and a budget of every unit drains the whole layer in one call")
	terrain.set_physics_process(false)
	await process_frame
	await poll(control)
	require(bool(control.call("is_available")), "a layer that exists must make the view available")
	require(control.visible, "and visible")
	require(not terrain.is_vt_delivery_used(CLIPMAP), "while no delivery cell claims the method")
	var asked := settings()
	require(int(asked.get("clipmap_preview_calls", 0)) == int(refused.get("clipmap_preview_calls", 0)) + 1,
			"the view asked for the layout exactly once")
	require(int(asked.get("clipmap_preview_computed", 0)) == int(refused.get("clipmap_preview_computed", 0)) + 1,
			"and that ask computed it, because a layer was there to describe")
	var snapshot: Dictionary = control.get("_snapshot")
	require(not snapshot.is_empty(), "the view holds a layout to draw")
	var layers: Array = snapshot.get("layers", [])
	require(layers.size() == 1, "with one layer to draw")
	var layer := clipmap_layer(snapshot)
	var units: Array = layer.get("unit_reports", [])
	require(units.size() == LEVELS, "reported as %d units of the LOD level array" % LEVELS)
	require(str(layer.get("implementation", "")) == "LOD" and
			str((layer.get("impl", {}) as Dictionary).get("storage", "")) == "toroidal_level_array",
			"and the default implementation is the LOD level array")

	# A focus with no budget: the whole unit is queued, which is the state the orange rects show.
	terrain.vt_clipmap_budget_texels = 0
	target.position = Vector3(120.5, 0.0, 32.5)
	await tick()
	await poll(control)
	snapshot = control.get("_snapshot")
	var unit: Dictionary = clipmap_units(snapshot)[0]
	require(int(unit.get("pending", 0)) == 1, "the queued job is reported as pending")
	require(not bool(unit.get("valid", true)), "and the unit is invalid while it is queued")
	var rects: Array = unit.get("pending_rects", [])
	require(rects.size() == 1 and absf((rects[0] as Rect2).size.x - BASE_WORLD) < 0.001,
			"and the queued rect is the unit it has to rebuild: %s" % str(rects))

	# The state the view is drawn for, and the one a moving focus spends most of its time in: the layer
	# is whole and one small move has queued one strip a unit, with no budget left to produce it. At
	# four texels of unit 0 the queued column is four metres of a sixty-four metre unit, which is
	# what the map has to show at the right edge of every nested square.
	terrain.vt_clipmap_budget_texels = LEVEL_TEXELS
	await drained()
	terrain.vt_clipmap_budget_texels = 0
	target.position = target.position + Vector3(4.0, 0.0, 0.0)
	await tick()
	await poll(control)
	snapshot = control.get("_snapshot")
	unit = clipmap_units(snapshot)[0]
	rects = unit.get("pending_rects", [])
	require(rects.size() == 1 and absf((rects[0] as Rect2).size.x - 4.0) < 0.001 and
			absf((rects[0] as Rect2).size.y - BASE_WORLD) < 0.001,
			"a one-strip move queues one column rect, not a whole unit: %s" % str(rects))

	await render_clipmap_view(snapshot)

	# The selector's other half: the same layer, the other storage. The control must follow the
	# selected implementation rather than always drawing the LOD picture, and the atlas payload's cells
	# are now each unit's own 3x3 blocks rather than one shared shell.
	terrain.vt_clipmap_budget_texels = LEVEL_TEXELS * LEVELS
	terrain.vt_clipmap_implementation = 1
	terrain.set_physics_process(false)
	await process_frame
	terrain.debug_update_vt_clipmap(HEIGHT)
	await drained()
	await poll(control)
	var atlas_snapshot: Dictionary = control.get("_snapshot")
	var atlas_layer := clipmap_layer(atlas_snapshot)
	require(str(atlas_layer.get("implementation", "")) == "Atlas",
			"switching the implementation must make the view draw the atlas")
	var atlas_impl: Dictionary = atlas_layer.get("impl", {})
	require(str(atlas_impl.get("storage", "")) == "packed_block_atlas",
			"and the atlas payload must name the packed block storage")
	var atlas_layout: Dictionary = atlas_impl.get("layout", {})
	var atlas_rings := int(atlas_layout.get("rings", 0))
	var atlas_cells: Array = atlas_layout.get("cells", [])
	require(atlas_rings > 0 and atlas_cells.size() == 9 * atlas_rings,
			"every unit is a 3x3 arrangement of its own blocks: %d units, %d cells" % [atlas_rings, atlas_cells.size()])
	var inside := 0
	for value: Variant in atlas_cells:
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var gx := int((value as Dictionary).get("gx", 99))
		var gy := int((value as Dictionary).get("gy", 99))
		if gx >= -1 and gx <= 1 and gy >= -1 and gy <= 1:
			inside += 1
	require(inside == atlas_cells.size(),
			"and each cell's gx/gy is one of that unit's nine blocks: %d/%d" % [inside, atlas_cells.size()])
	await render_atlas_view(atlas_snapshot)
	# Back to the level array for the panel-write half below, so its assertions describe the default.
	terrain.vt_clipmap_implementation = 0
	terrain.set_physics_process(false)
	await process_frame
	await poll(control)

	# The other half of the gate: the matrix write the height row offers is *accepted*, so a user reaches
	# this view through the panel as well as through the mechanism's entry - and the view is a picture of
	# the layer either way. The layer is kept, because a layer is a residency cache and nothing frees it
	# at runtime.
	var painted := settings()
	terrain.vt_delivery_near_height = CLIPMAP
	terrain.set_physics_process(false)
	await process_frame
	require(terrain.vt_delivery_near_height == CLIPMAP,
			"the height cell takes Clipmap, so a user reaches this view through the panel too")
	await poll(control)
	var closed := settings()
	require(bool(control.call("is_available")) and control.visible,
			"and the view follows the layer, which is still there")
	require(int(closed.get("clipmap_preview_computed", 0)) == int(painted.get("clipmap_preview_computed", 0)) + 1,
			"so the poll it just made did the work, as every poll with a layer behind it does")
	require(bool(closed.get("clipmap", {}).get("height", {}).get("configured", false)),
			"and the layer the entry built is kept")
	print("VT_DEBUG_CLIPMAP_VIEW units=%d queued=%d rects=%d calls=%d computed=%d cell=%d" % [
		LEVELS, int(unit.get("pending", 0)), rects.size(),
		int(closed.get("clipmap_preview_calls", 0)) - int(before.get("clipmap_preview_calls", 0)),
		int(closed.get("clipmap_preview_computed", 0)) - int(before.get("clipmap_preview_computed", 0)),
		terrain.vt_delivery_near_height])
	terrain.vt_delivery_near_height = DIRECT
	control.queue_free()
	await process_frame


# The picture itself. "The debug view shows the LOD layer as blocks, over the density it serves" is a
# claim about pixels, so the pixels are counted: everything that is not the control's own background,
# the queued strips' own colour (which only the pending rects and the focus marker use), and the
# coverage plot's own colour.
func render_clipmap_view(p_snapshot: Dictionary) -> void:
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	require(image != null and image.get_width() == VIEWPORT_SIZE.x and image.get_height() == VIEWPORT_SIZE.y,
			"the clipmap view did not render its viewport")
	if image == null:
		return
	var background := image.get_pixel(2, 2)
	var painted := 0
	var queued := 0
	var density := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if absf(pixel.r - background.r) + absf(pixel.g - background.g) + absf(pixel.b - background.b) > 0.15:
				painted += 1
			if pixel.r > 0.6 and pixel.r - pixel.g > 0.15 and pixel.g - pixel.b > 0.15:
				queued += 1
			if absf(pixel.r - 0.62) < 0.08 and absf(pixel.g - 0.94) < 0.06 and absf(pixel.b - 0.75) < 0.08:
				density += 1
	require(painted > 2000, "the clipmap view rendered an effectively empty picture: %d painted pixels" % painted)
	require(queued > 100, "and did not draw the queued strips: %d pixels of the pending colour" % queued)
	require(density > 20, "and did not draw the coverage plot: %d pixels of the density colour" % density)
	# The two panels are told apart by where they are: the level strip is at the top and the world map
	# under it, and a view that drew only one of them would still pass the counts above.
	var strip_pixels := 0
	var map_pixels := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if absf(pixel.r - background.r) + absf(pixel.g - background.g) + absf(pixel.b - background.b) > 0.15:
				if y < 150:
					strip_pixels += 1
				else:
					map_pixels += 1
	require(strip_pixels > 500 and map_pixels > 500,
			"the unit strip and the world map must both be drawn: %d / %d" % [strip_pixels, map_pixels])
	image.save_png("user://vt_clipmap_debug_view.png")
	print("VT_DEBUG_CLIPMAP_RENDER painted=%d queued=%d density=%d strip=%d map=%d units=%d" % [
		painted, queued, density, strip_pixels, map_pixels, clipmap_units(p_snapshot).size()])


# The same claim for the other storage: the region panel and the grid panel (one 3x3 per unit) must
# both be drawn, over the same coverage plot. The two panels sit side by side in the top band, so the
# pixels are split there rather than by height.
func render_atlas_view(p_snapshot: Dictionary) -> void:
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	require(image != null and image.get_width() == VIEWPORT_SIZE.x and image.get_height() == VIEWPORT_SIZE.y,
			"the atlas view did not render its viewport")
	if image == null:
		return
	var background := image.get_pixel(2, 2)
	var painted := 0
	var density := 0
	var region := 0
	var grid := 0
	var middle := image.get_width() / 2
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			var lit := absf(pixel.r - background.r) + absf(pixel.g - background.g) + absf(pixel.b - background.b) > 0.15
			if lit:
				painted += 1
			if absf(pixel.r - 0.62) < 0.08 and absf(pixel.g - 0.94) < 0.06 and absf(pixel.b - 0.75) < 0.08:
				density += 1
			# The panels are the top band; the coverage plot and the legend live under it.
			if lit and y >= 20 and y < 240:
				if x < middle:
					region += 1
				else:
					grid += 1
	require(painted > 2000, "the atlas view rendered an effectively empty picture: %d painted pixels" % painted)
	require(density > 20, "the atlas view must draw the coverage plot too: %d pixels of the density colour" % density)
	require(region > 200 and grid > 200,
			"the atlas region and grid panels must both be drawn: %d / %d" % [region, grid])
	image.save_png("user://vt_clipmap_atlas_debug_view.png")
	print("VT_DEBUG_CLIPMAP_ATLAS_RENDER painted=%d density=%d region=%d grid=%d units=%d" % [
		painted, density, region, grid, clipmap_units(p_snapshot).size()])


# ---- 3, the other method ------------------------------------------------------------------------

func check_avt_view() -> void:
	var control: Control = load(AVT_PREVIEW_SCRIPT).new()
	control.size = Vector2(VIEWPORT_SIZE)
	viewport.add_child(control)
	control.set_terrain(terrain)
	# Every cell is direct after the clipmap block, so AVT is unselected and its view hides.
	var before := settings()
	await poll(control)
	require(not bool(control.call("is_available")), "the AVT view must be unavailable while no cell selects it")
	require(not control.visible, "and must hide itself")
	var refused := settings()
	require(int(refused.get("avt_preview_calls", 0)) == int(before.get("avt_preview_calls", 0)),
			"a hidden AVT view must not even ask for a layout")
	require(int(refused.get("avt_preview_computed", 0)) == int(before.get("avt_preview_computed", 0)),
			"and its scan must not run in that state")
	terrain.vt_delivery_near_material = AVT
	terrain.set_physics_process(false)
	await process_frame
	await poll(control)
	require(bool(control.call("is_available")) and control.visible,
			"selecting AVT must reveal its view without a reparse")
	var asked := settings()
	require(int(asked.get("avt_preview_calls", 0)) == int(refused.get("avt_preview_calls", 0)) + 1,
			"and the visible view asks once")
	require(int(asked.get("avt_preview_computed", 0)) == int(refused.get("avt_preview_computed", 0)) + 1,
			"and that ask computes, because a cell selects AVT")
	print("VT_DEBUG_AVT_VIEW calls=%d computed=%d" % [
		int(asked.get("avt_preview_calls", 0)) - int(before.get("avt_preview_calls", 0)),
		int(asked.get("avt_preview_computed", 0)) - int(before.get("avt_preview_computed", 0))])
	control.queue_free()
	await process_frame


func run() -> void:
	camera = Camera3D.new()
	camera.position = Vector3(32.5, 90.0, 32.5)
	camera.current = true
	root.add_child(camera)
	camera.look_at(Vector3(32.5, 0.0, 32.5))

	viewport = SubViewport.new()
	viewport.name = "DebugViewRender"
	viewport.size = VIEWPORT_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)

	await setup()
	check_group_order()
	await check_dock_order()
	await check_clipmap_view()
	await check_avt_view()

	if failed:
		print("REGRESSION: delivery debug views")
		quit(1)
		return
	print("PASS delivery debug views")
	quit(0)
