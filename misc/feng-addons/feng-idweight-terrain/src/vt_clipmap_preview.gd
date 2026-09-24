# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The clipmap's debug view: what the one delivery holds, where it holds it, and which units it is
# still producing. One control with two hosts - the Inspector's Surface VT / VT Page section and the
# Surface VT window's VT Page view - because it is a picture of the layer rather than of either
# window.
#
# **It draws nothing, and asks for nothing, while no layer exists.** The native preview refuses a
# terrain with no layer, so a view that kept asking would spend a call per interval to be told there is
# no layout; this one asks for one boolean instead (`has_vt_clipmap_layer()`) and hides itself. That
# boolean is cheap enough to keep polling while the view is hidden - a layer can be built while a
# section is folded - and the expensive `get_clipmap_layout_preview()` call waits for visibility,
# which is the rule the AVT preview follows for its scan.
#
# The gate is "is there a layer" rather than "does a cell select the method", and in a build that
# cannot deliver Clipmap for any group the two are the same answer for a user: no cell may name the
# method, so no layer exists and this view never appears. A layer built to measure the mechanism
# (`Terrain3D::debug_update_vt_clipmap()`, which is what the native suites drive) is a layer this view
# draws, because a picture of a layer is a picture of the layer that exists - not of the setting that
# asked for it.
#
# The view follows the *implementation* the delivery has selected (`vt_clipmap_implementation`), not a
# fixed storage: the LOD level array and the packed block atlas are two pictures of the same layer, and
# `get_clipmap_layout_preview()` reports which one it is. Both pictures are drawn over the *same*
# coverage plot, because density and reach belong to the shared ladder rather than to either storage -
# that plot is what says whether the units actually cover the distances the focus needs.
#
# The LOD picture answers the two questions the level array raises, and neither half replaces the
# other:
#   * the *level strip* is the layer assembled from units: one square per level, each cut into
#     the texel blocks it is addressed in, coloured by level and drawn solid only while the level is
#     valid. It is the same readable picture whatever the ratio between the coarsest and the finest
#     level is - and that ratio is `2^levels`, which no single world map can show.
#   * the *map* is where those levels stand in the world. Every level's square is snapped to its own
#     texel size, so a level that is current sits on the focus and one that still holds the level it
#     replaces is offset from it by what it has not produced; the rects still queued are drawn on top,
#     because the strips a moving focus has just cost are the only part of the layer that changes.
@tool
extends "res://addons/feng-idweight-terrain/src/vt_layout_preview.gd"

const MAP_MARGIN := 8.0
const STRIP_TOP := 24.0
const STRIP_SIDE := 52.0
const STRIP_LABEL := 11.0
const STRIP_GAP := 6.0
const LEGEND_LINE := 11.0
const MIN_HEIGHT := 330.0
## How many blocks a level's square is cut into, at most. The step is `ceil(size / this)`, so a
## 256-texel level draws 16-texel blocks; a per-texel grid would be a quarter of a million rectangles
## an axis on a 4096-texel level.
const MAX_BLOCKS_PER_AXIS := 16
## Levels drawn in the strip. The shipped ladder is eleven units (1024 -> 1 texels a metre) and the
## palette below has a colour for each, so the whole ladder is drawn rather than the first eight: a
## picture that stopped at eight could not show the 1 texel/m outer unit the ladder is measured by.
const MAX_SCHEMATIC_LEVELS := 12
const LEVEL_PALETTE: Array[Color] = [
	Color("55d6be"), Color("5cc8ef"), Color("6f9df5"), Color("8d7cf2"),
	Color("b27bea"), Color("d875cb"), Color("eb7c9e"), Color("f09573"),
	Color("f4b65e"), Color("f0d36a"), Color("d8e77e"), Color("aee59b"),
]
const VALID_FILL_ALPHA := 0.16
const INVALID_FILL_ALPHA := 0.05
const BLOCK_LINE_ALPHA := 0.35
const PENDING_COLOR := Color("ff9f43")
## The atlas view's own constants. The atlas is drawn as two squares: the *region* - every rect the
## packer placed, at its real position and size in the texture - and the *grid* - each unit's own 3x3
## arrangement of blocks, coloured by the unit that owns each one and marked with the atlas index it
## reads this frame. The user asked for exactly this: "the debug should show the atlas's region".
const ATLAS_GAP := 10.0
const GLOBAL_COLOR := Color("f3d28a")
const SPARE_ALPHA := 0.45
const ATLAS_MIN_HEIGHT := 420.0
## The shared coverage plot, drawn under both pictures. Its colour is its own so a regression can count
## the plot's pixels without counting the map's focus marker, which shares the atlas's gold.
const DENSITY_COLOR := Color("9ef0c0")
const DENSITY_HEIGHT := 76.0
const DENSITY_GAP := 8.0
const AXIS_COLOR := Color("3b4b56")

var _snapshot: Dictionary = {}
## The layer entry the picture is of, which is the first entry `get_clipmap_layout_preview()` returns.
## A terrain may carry a layer for each channel group, but a debug view is a picture of one thing, and
## the first entry is the group the report lists first.
var _layer: Dictionary = {}
var _status := ""

func _has_layer() -> bool:
	return not _layer.is_empty()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0.0, MIN_HEIGHT)
	set_process(true)
	queue_redraw()


func _reset_preview_state() -> void:
	_snapshot.clear()
	_layer.clear()
	_status = ""


func _process(_p_delta: float) -> void:
	var terrain := _get_terrain()
	if terrain == null:
		_set_available(false)
		return
	var now_sec := float(Time.get_ticks_msec()) / 1000.0
	if now_sec - _last_poll_sec < POLL_INTERVAL_SEC:
		return
	_last_poll_sec = now_sec
	# The gate is one boolean and runs whether or not this view is on screen, because a layer can come
	# into existence while the section is folded and a gate that stopped would never notice.
	_set_available(_gate(terrain))
	if not _available:
		if not _snapshot.is_empty() or not _layer.is_empty():
			_snapshot.clear()
			_layer.clear()
			queue_redraw()
		return
	if not is_visible_in_tree():
		return
	_refresh_preview(terrain)


func _gate(p_terrain: Object) -> bool:
	# A terrain that cannot answer is not gated: the layer's existence is what says a view has something
	# to draw, and a stub (or a build that predates the query) has nothing to conclude from. The real
	# terrain always has the method, so the gate is exact where it matters.
	if not p_terrain.has_method("has_vt_clipmap_layer"):
		return true
	return bool(p_terrain.call("has_vt_clipmap_layer"))


# One payload, one layer: the preview reports every layer that exists, and the drawing is of the first
# entry. Which *storage* that layer uses is the entry's own `implementation` / `impl["storage"]`, so the
# picture is chosen from the payload rather than from a second question that could disagree with it.
func _refresh_preview(p_terrain: Object) -> void:
	var layout: Dictionary = {}
	if p_terrain.has_method("get_clipmap_layout_preview"):
		var value: Variant = p_terrain.call("get_clipmap_layout_preview")
		if typeof(value) == TYPE_DICTIONARY:
			layout = value
	var layer := _first_layer(layout)
	if layer.is_empty():
		_clear_preview("No clipmap layer exists: no delivery cell selects Clipmap in this build")
		return
	_snapshot = layout
	_layer = layer
	_status = ""
	custom_minimum_size = Vector2(0.0, ATLAS_MIN_HEIGHT if _is_atlas() else MIN_HEIGHT)
	queue_redraw()


func _first_layer(p_layout: Dictionary) -> Dictionary:
	var value: Variant = p_layout.get("layers", [])
	if not value is Array:
		return {}
	for entry: Variant in (value as Array):
		if typeof(entry) == TYPE_DICTIONARY and not (entry as Dictionary).is_empty():
			return entry
	return {}


func _clear_preview(p_status: String) -> void:
	_snapshot.clear()
	_layer.clear()
	_status = p_status
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("151b21"), true)
	var font := get_theme_default_font()
	var font_size := 11
	var text_color := get_theme_color("font_color", "Label")
	if font:
		draw_string(font, Vector2(MAP_MARGIN, 14.0), _title(), HORIZONTAL_ALIGNMENT_LEFT,
				maxf(1.0, size.x - MAP_MARGIN * 2.0), font_size, text_color)
	if not _status.is_empty():
		if font:
			draw_string(font, Vector2(MAP_MARGIN, STRIP_TOP + 14.0), _status, HORIZONTAL_ALIGNMENT_LEFT,
					maxf(1.0, size.x - MAP_MARGIN * 2.0), font_size, text_color)
		return
	if not _has_layer():
		return
	if _is_atlas():
		_draw_atlas(font, font_size, text_color)
	else:
		_draw_lod(font, font_size, text_color)


func _title() -> String:
	if not _has_layer():
		return "Clipmap · no layer"
	var view := "region / cells" if _is_atlas() else "levels / world"
	return "Clipmap · %s implementation · %s" % [_implementation(), view]


func _implementation() -> String:
	var value := str(_layer.get("implementation", _snapshot.get("implementation", "LOD")))
	return value if not value.is_empty() else "LOD"


func _is_atlas() -> bool:
	var impl: Dictionary = _layer.get("impl", {})
	return str(impl.get("storage", "")) == "packed_block_atlas" or _implementation() == "Atlas"


func _focus() -> Vector2:
	return _vector2(_layer.get("focus", _snapshot.get("focus", Vector2.ZERO)))


func _units() -> Array:
	var value: Variant = _layer.get("unit_reports", [])
	if not value is Array:
		return []
	var units: Array = []
	for entry: Variant in (value as Array):
		if typeof(entry) == TYPE_DICTIONARY:
			units.append(entry)
	return units


# ---- The LOD picture -----------------------------------------------------------------------------

func _draw_lod(p_font: Font, p_font_size: int, p_text_color: Color) -> void:
	var units := _units()
	if units.is_empty():
		return
	var legend := _lod_legend_lines(units)
	var legend_height := float(legend.size()) * LEGEND_LINE + 6.0
	var strip_height := STRIP_SIDE + STRIP_LABEL
	_draw_level_strip(units, p_font, p_font_size, p_text_color)
	# The coverage plot is pinned above the legend and the map takes what is left, so the density
	# reading is drawn even on a control too narrow for a map.
	var density_top := size.y - legend_height - DENSITY_HEIGHT - MAP_MARGIN
	var map_side := minf(size.x - MAP_MARGIN * 2.0,
			density_top - DENSITY_GAP - (STRIP_TOP + strip_height))
	if map_side > 24.0:
		_draw_map(Rect2(Vector2(MAP_MARGIN, STRIP_TOP + strip_height), Vector2(map_side, map_side)), units)
	if density_top > STRIP_TOP + strip_height:
		_draw_density(Rect2(Vector2(MAP_MARGIN, density_top),
				Vector2(size.x - MAP_MARGIN * 2.0, DENSITY_HEIGHT)), _density_pairs(), p_font, p_font_size, p_text_color)
	_draw_legend(Vector2(MAP_MARGIN, size.y - legend_height), legend, p_font, p_font_size)


# The assembled layer, one square per unit: each square is the unit's own storage cut into the blocks
# it is addressed in, so a strip the budget cut short is visible as the part of the square it left
# untouched.
func _draw_level_strip(p_units: Array, p_font: Font, p_font_size: int, p_text_color: Color) -> void:
	var count := mini(p_units.size(), MAX_SCHEMATIC_LEVELS)
	if count <= 0:
		return
	var usable := size.x - MAP_MARGIN * 2.0 - STRIP_GAP * float(count - 1)
	var side := minf(STRIP_SIDE, usable / float(count))
	for index in count:
		var unit: Dictionary = p_units[index]
		var square := Rect2(MAP_MARGIN + float(index) * (side + STRIP_GAP), STRIP_TOP, side, side)
		_draw_level_blocks(square, unit, index)
		if p_font:
			draw_string(p_font, Vector2(square.position.x, square.end.y + 9.0), _unit_label(unit, index),
					HORIZONTAL_ALIGNMENT_CENTER, side, p_font_size - 2, p_text_color)


func _draw_level_blocks(p_square: Rect2, p_unit: Dictionary, p_index: int) -> void:
	var valid := bool(p_unit.get("valid", false))
	var color := _level_color(p_index)
	draw_rect(p_square, Color(color.r, color.g, color.b, VALID_FILL_ALPHA if valid else INVALID_FILL_ALPHA), true)
	# The queued rects go under the grid, not over it: the blocks are what the picture is of, and a
	# solid fill drawn last would hide the very thing it is made of. This is the one place the
	# ordering of two draws is a decision.
	for value: Variant in p_unit.get("pending_rects", []):
		var fraction := _fraction_of_unit(value, p_unit)
		if fraction.has_area():
			draw_rect(Rect2(p_square.position + fraction.position * p_square.size,
					fraction.size * p_square.size), PENDING_COLOR, true)
	var texels := maxi(1, int(p_unit.get("texels", 1)))
	var step := maxi(1, int(ceil(float(texels) / float(MAX_BLOCKS_PER_AXIS))))
	var blocks := maxi(1, int(ceil(float(texels) / float(step))))
	var edge := p_square.size.x / float(blocks)
	var line := Color(color.r, color.g, color.b, BLOCK_LINE_ALPHA)
	for block in range(1, blocks):
		var offset := float(block) * edge
		draw_line(p_square.position + Vector2(offset, 0.0), p_square.position + Vector2(offset, p_square.size.y), line, 1.0)
		draw_line(p_square.position + Vector2(0.0, offset), p_square.position + Vector2(p_square.size.x, offset), line, 1.0)
	draw_rect(p_square, color, false, 1.6 if valid else 1.0)


# Where the units stand in the world. The view is the coarsest unit's own square, because that is the
# whole of what the layer covers; a finer unit is a smaller square inside it, drawn on top.
func _draw_map(p_map: Rect2, p_units: Array) -> void:
	var extent := 0.0
	for unit: Dictionary in p_units:
		extent = maxf(extent, float(unit.get("world_size", 0.0)))
	if extent <= 0.0:
		return
	var focus := _focus()
	var bounds := Rect2(focus - Vector2.ONE * extent * 0.5, Vector2.ONE * extent)
	var scale := p_map.size.x / extent
	draw_rect(p_map, Color("10161b"), true)
	draw_rect(p_map, Color("3b4b56"), false, 1.0)
	for index in range(p_units.size() - 1, -1, -1):
		var unit: Dictionary = p_units[index]
		var world_size := float(unit.get("world_size", 0.0))
		if world_size <= 0.0:
			continue
		var world_rect := Rect2(_vector2(unit.get("center", Vector2.ZERO)) - Vector2.ONE * world_size * 0.5,
				Vector2.ONE * world_size)
		var canvas := _world_rect_to_canvas(world_rect, bounds, p_map.position, scale)
		var color := _level_color(index)
		var valid := bool(unit.get("valid", false))
		draw_rect(canvas, Color(color.r, color.g, color.b, 0.10 if valid else 0.03), true)
		draw_rect(canvas, Color(color.r, color.g, color.b, 0.85 if valid else 0.40), false, 1.2)
	# The queued work last, and translucent: a unit that has lost a strip is still drawn under it, and
	# an opaque fill at the coarsest unit would cover the whole map - which is exactly the state a
	# teleport produces, and exactly when the picture is most useful.
	for unit: Dictionary in p_units:
		for value: Variant in unit.get("pending_rects", []):
			if not value is Rect2:
				continue
			var clipped := _world_rect_to_canvas(value, bounds, p_map.position, scale).intersection(p_map)
			if clipped.has_area():
				draw_rect(clipped, Color(PENDING_COLOR.r, PENDING_COLOR.g, PENDING_COLOR.b, 0.45), true)
				draw_rect(clipped, PENDING_COLOR, false, 1.0)
	var marker := p_map.position + (focus - bounds.position) * scale
	if p_map.has_point(marker):
		draw_circle(marker, 3.0, GLOBAL_COLOR, true)
		draw_line(marker - Vector2(6.0, 0.0), marker + Vector2(6.0, 0.0), GLOBAL_COLOR, 1.0)
		draw_line(marker - Vector2(0.0, 6.0), marker + Vector2(0.0, 6.0), GLOBAL_COLOR, 1.0)


func _lod_legend_lines(p_units: Array) -> Array[String]:
	var focus := _focus()
	var lines: Array[String] = []
	lines.append("focus %.1f, %.1f · %d texels a tick · %d levels" % [focus.x, focus.y,
			int(_snapshot.get("budget_texels", 0)), int(_snapshot.get("units_setting", 0))])
	var valid := 0
	var queued := 0
	for unit: Dictionary in p_units:
		if bool(unit.get("valid", false)):
			valid += 1
		queued += int(unit.get("pending", 0))
	lines.append("%s layer · %s implementation · source %s · %d/%d units valid · %d queued · %.1f KB uploaded" % [
			str(_layer.get("group", "?")), _implementation(), str(_layer.get("source", "?")), valid,
			p_units.size(), queued, float(_layer.get("upload_bytes", 0)) / 1024.0])
	var texels := maxi(1, int(_layer.get("size", 1)))
	var step := maxi(1, int(ceil(float(texels) / float(MAX_BLOCKS_PER_AXIS))))
	lines.append("a square is one unit, cut every %d of its %d texels · orange rects are queued strips" % [step, texels])
	lines.append("coverage plot: outer radius (m) across, texels a metre up · the density the ladder serves at each distance")
	return lines


# ---- The atlas's own picture ---------------------------------------------------------------------
#
# Two squares, because the atlas raises two questions the level array does not. The left one is the
# **region**: the texture the packer laid out, drawn to scale, every rect at its own position and
# size, coloured by the unit whose block it is, with the spare rects outlined and the one-time global
# block in its own colour. The right one is the **grid**: every unit's own 3x3 arrangement of blocks,
# laid side by side, each cell coloured by its unit and marked with the atlas index it reads this
# frame. "Which rect does this cell read" is the current-frame atlas index, and it is the arrow
# between the two squares.
func _draw_atlas(p_font: Font, p_font_size: int, p_text_color: Color) -> void:
	var impl: Dictionary = _layer.get("impl", {})
	var layout: Dictionary = impl.get("layout", {})
	var legend := _atlas_legend_lines(impl, layout)
	var legend_height := float(legend.size()) * LEGEND_LINE + 6.0
	var available := size.y - STRIP_TOP - legend_height - DENSITY_HEIGHT - DENSITY_GAP - MAP_MARGIN
	var panel := minf((size.x - MAP_MARGIN * 3.0 - ATLAS_GAP) * 0.5, available)
	if panel <= 16.0:
		_draw_legend(Vector2(MAP_MARGIN, size.y - legend_height), legend, p_font, p_font_size)
		return
	var region_rect := Rect2(Vector2(MAP_MARGIN, STRIP_TOP), Vector2(panel, panel))
	var grid_rect := Rect2(Vector2(MAP_MARGIN + panel + ATLAS_GAP, STRIP_TOP), Vector2(panel, panel))
	_draw_atlas_region(region_rect, layout, p_font, p_font_size, p_text_color)
	_draw_atlas_grid(grid_rect, layout, p_font, p_font_size, p_text_color)
	_draw_density(Rect2(Vector2(MAP_MARGIN, STRIP_TOP + panel + DENSITY_GAP),
			Vector2(size.x - MAP_MARGIN * 2.0, DENSITY_HEIGHT)), _density_pairs(), p_font, p_font_size, p_text_color)
	_draw_legend(Vector2(MAP_MARGIN, size.y - legend_height), legend, p_font, p_font_size)


func _draw_atlas_region(p_panel: Rect2, p_layout: Dictionary, p_font: Font, p_font_size: int,
		p_text_color: Color) -> void:
	var width := maxi(1, int(p_layout.get("width", 1)))
	var height := maxi(1, int(p_layout.get("height", 1)))
	var span := maxf(float(width), float(height))
	var scale := p_panel.size.x / span
	var texture_rect := Rect2(p_panel.position, Vector2(float(width), float(height)) * scale)
	draw_rect(p_panel, Color("10161b"), true)
	draw_rect(texture_rect, Color("1b242c"), true)
	var live_slots := {}
	for cell: Variant in p_layout.get("cells", []):
		if typeof(cell) == TYPE_DICTIONARY:
			live_slots[int((cell as Dictionary).get("slot", -1))] = bool((cell as Dictionary).get("current", false))
	var slot_index := 0
	for value: Variant in p_layout.get("rects", []):
		if typeof(value) != TYPE_DICTIONARY:
			slot_index += 1
			continue
		var entry: Dictionary = value
		var rect := _rect2(entry.get("rect", Rect2()))
		if not rect.has_area():
			slot_index += 1
			continue
		var canvas := Rect2(texture_rect.position + rect.position * scale, rect.size * scale)
		if bool(entry.get("global", false)):
			draw_rect(canvas, Color(GLOBAL_COLOR.r, GLOBAL_COLOR.g, GLOBAL_COLOR.b, 0.30), true)
			draw_rect(canvas, GLOBAL_COLOR, false, 1.2)
			slot_index += 1
			continue
		var color := _level_color(int(entry.get("ring", 0)))
		# The rects are published in slot order, so the array position *is* the atlas index the cells
		# name - the rect array and the cell table are the same array.
		var current := bool(live_slots.get(slot_index, false))
		var spare := bool(entry.get("spare", false))
		# A spare is drawn as an outline only: it is a slot, not content, and filling it would say a
		# block is there when nothing has been produced into it.
		if not spare:
			draw_rect(canvas, Color(color.r, color.g, color.b, VALID_FILL_ALPHA), true)
		draw_rect(canvas, Color(color.r, color.g, color.b, SPARE_ALPHA if spare else 1.0), false,
				1.0 if spare else 1.2)
		if current:
			draw_rect(canvas.grow(-0.5), Color("ffffff"), false, 1.4)
		slot_index += 1
	draw_rect(texture_rect, Color("3b4b56"), false, 1.0)
	if p_font:
		draw_string(p_font, p_panel.position + Vector2(0.0, p_panel.size.y + 11.0),
				"atlas %d x %d texels · %d rects" % [width, height, int(p_layout.get("total_blocks", 0))],
				HORIZONTAL_ALIGNMENT_LEFT, p_panel.size.x, p_font_size - 1, p_text_color)


# Every unit is a 3x3 arrangement of its own blocks, so the grid panel lays the units side by side
# and draws each one's own square of cells. The old `(2 * rings + 1)^2` shell is gone: a cell's
# `gx`/`gy` now spans only `-1..1` for *its* unit, and stacking them all in one 3x3 square would draw
# every unit over the others.
func _draw_atlas_grid(p_panel: Rect2, p_layout: Dictionary, p_font: Font, p_font_size: int,
		p_text_color: Color) -> void:
	var side := maxi(1, int(p_layout.get("grid_side", 3)))
	var rings := maxi(1, int(p_layout.get("rings", 1)))
	var half := (side - 1) / 2
	# The shipped ladder is eleven units, so one row of eleven 3x3 squares would draw sub-pixel cells.
	# The units wrap into a near-square block of rows instead, which keeps every cell readable and still
	# reads as the nested arrangement it is.
	var per_row := maxi(1, int(ceil(sqrt(float(rings)))))
	var rows := int(ceil(float(rings) / float(per_row)))
	var columns := side * per_row
	var cell := Vector2(p_panel.size.x / float(columns), p_panel.size.y / float(side * rows))
	draw_rect(p_panel, Color("10161b"), true)
	for value: Variant in p_layout.get("cells", []):
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = value
		var ring := clampi(int(entry.get("ring", 0)), 0, rings - 1)
		var unit_column := ring % per_row
		var unit_row := ring / per_row
		var column := unit_column * side + clampi(int(entry.get("gx", 0)) + half, 0, side - 1)
		var row := unit_row * side + clampi(int(entry.get("gy", 0)) + half, 0, side - 1)
		var box := Rect2(p_panel.position + Vector2(float(column), float(row)) * cell, cell)
		var color := _level_color(ring)
		# One unit's square is its own blocks, so the fill says which unit owns the cell and the
		# outline says whether the cell has the block it wants this frame.
		draw_rect(box.grow(-0.5), Color(color.r, color.g, color.b, 0.28), true)
		if int(entry.get("pending_slot", -1)) >= 0:
			draw_rect(box.grow(-1.0), PENDING_COLOR, false, 1.6)
			draw_rect(box.grow(-1.0), Color(PENDING_COLOR.r, PENDING_COLOR.g, PENDING_COLOR.b, 0.35), true)
		elif bool(entry.get("current", false)):
			draw_rect(box.grow(-0.5), Color(color.r, color.g, color.b, 1.0), false, 1.4)
		else:
			draw_rect(box.grow(-0.5), Color(color.r, color.g, color.b, 0.35), false, 1.0)
		if p_font and cell.x >= 14.0:
			draw_string(p_font, box.position + Vector2(2.0, cell.y - 3.0), "%d" % int(entry.get("slot", -1)),
					HORIZONTAL_ALIGNMENT_LEFT, cell.x, maxi(8, p_font_size - 2), p_text_color)
	draw_rect(p_panel, Color("3b4b56"), false, 1.0)
	if p_font:
		draw_string(p_font, p_panel.position + Vector2(0.0, p_panel.size.y + 11.0),
				"%d units · %d x %d blocks each · number is the current-frame atlas index" % [rings, side, side],
				HORIZONTAL_ALIGNMENT_LEFT, p_panel.size.x, p_font_size - 1, p_text_color)


func _atlas_legend_lines(p_impl: Dictionary, p_layout: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var focus := _focus()
	lines.append("%s atlas · source %s · focus %.1f, %.1f" % [str(_layer.get("group", "?")),
			str(_layer.get("source", "?")), focus.x, focus.y])
	lines.append("%d blocks in %s · %d rects · %.0f%% packed · %d x %d texels" % [
			int(p_layout.get("blocks", 0)), str(p_layout.get("chosen", "?")),
			int(p_layout.get("total_blocks", 0)), float(p_layout.get("efficiency", 0.0)) * 100.0,
			int(p_layout.get("width", 0)), int(p_layout.get("height", 0))])
	lines.append("units %s blocks · %.1f KB uploaded in %d block rects · %d pending" % [
			str(p_layout.get("ring_blocks", [])), float(_layer.get("upload_bytes", 0)) / 1024.0,
			int(p_impl.get("block_uploads", 0)), int(_layer.get("pending_jobs", 0))])
	lines.append("rolling: %d scrolls · %d blocks loaded, %d cells kept · last %d loaded / %d kept" % [
			int(p_impl.get("scroll_events", 0)), int(p_impl.get("blocks_loaded", 0)),
			int(p_impl.get("blocks_retained", 0)), int(p_impl.get("last_scroll_loaded", 0)),
			int(p_impl.get("last_scroll_retained", 0))])
	lines.append("white outline: a cell reads this rect now · orange: its replacement is in flight · yellow: the one-time global block")
	return lines


# ---- The coverage reading, drawn for both implementations ----------------------------------------

# The shared ladder's density against the reach of the unit that serves it. `unit_reach` and
# `unit_density` are the *layer's* arrays - one function of the ladder - so the plot is the same
# reading whichever storage is selected, which is what makes "the layer covers this distance at this
# density" a claim about the delivery rather than about the atlas or the level array.
func _draw_density(p_rect: Rect2, p_pairs: Array, p_font: Font, p_font_size: int, p_text_color: Color) -> void:
	draw_rect(p_rect, Color("10161b"), true)
	draw_rect(p_rect, AXIS_COLOR, false, 1.0)
	var plot := Rect2(p_rect.position + Vector2(38.0, 14.0), p_rect.size - Vector2(44.0, 28.0))
	if plot.size.x <= 8.0 or plot.size.y <= 8.0:
		return
	if p_font:
		draw_string(p_font, p_rect.position + Vector2(4.0, 10.0),
				"coverage · outer radius (m) against density (texels/m)", HORIZONTAL_ALIGNMENT_LEFT,
				p_rect.size.x - 6.0, maxi(8, p_font_size - 2), Color("b7c6ce"))
	if p_pairs.is_empty():
		return
	var max_reach := 0.0
	var max_density := 0.0
	for pair: Vector2 in p_pairs:
		max_reach = maxf(max_reach, pair.x)
		max_density = maxf(max_density, pair.y)
	if max_reach <= 0.0 or max_density <= 0.0:
		return
	draw_line(plot.position + Vector2(0.0, plot.size.y), plot.position + Vector2(plot.size.x, plot.size.y), AXIS_COLOR, 1.0)
	draw_line(plot.position, plot.position + Vector2(0.0, plot.size.y), AXIS_COLOR, 1.0)
	var points := PackedVector2Array()
	for pair: Vector2 in p_pairs:
		points.append(plot.position + Vector2(pair.x / max_reach * plot.size.x,
				(1.0 - pair.y / max_density) * plot.size.y))
	if points.size() >= 2:
		draw_polyline(points, DENSITY_COLOR, 1.5)
	for point: Vector2 in points:
		draw_circle(point, 2.5, DENSITY_COLOR)
	if p_font:
		draw_string(p_font, plot.position + Vector2(0.0, plot.size.y + 11.0), "0",
				HORIZONTAL_ALIGNMENT_LEFT, 20.0, maxi(8, p_font_size - 2), p_text_color)
		draw_string(p_font, plot.position + Vector2(plot.size.x - 60.0, plot.size.y + 11.0),
				"%.0f m" % max_reach, HORIZONTAL_ALIGNMENT_RIGHT, 60.0, maxi(8, p_font_size - 2), p_text_color)
		draw_string(p_font, plot.position + Vector2(-34.0, 6.0), "%.1f" % max_density,
				HORIZONTAL_ALIGNMENT_RIGHT, 32.0, maxi(8, p_font_size - 2), p_text_color)


func _density_pairs() -> Array:
	# The x is the unit's **coverage outer radius** - the distance at which the unit's density stops
	# being the one a fragment gets - because that is the reading "density against distance" means.
	# The payload publishes it directly as `unit_radius` beside `unit_density`; the layer's own
	# `density_curve` / `density_distance` pair is the same curve and is read by the service report,
	# not by this plot.
	var reach := _float_series("unit_radius")
	var density := _float_series("unit_density")
	var count := mini(reach.size(), density.size())
	var pairs: Array = []
	for index in count:
		pairs.append(Vector2(reach[index], density[index]))
	return pairs


func _float_series(p_key: String) -> PackedFloat32Array:
	var value: Variant = _layer.get(p_key, PackedFloat32Array())
	if value is PackedFloat32Array:
		return value
	if value is Array:
		var out := PackedFloat32Array()
		for entry: Variant in (value as Array):
			out.append(float(entry))
		return out
	return PackedFloat32Array()


func _draw_legend(p_origin: Vector2, p_lines: Array[String], p_font: Font, p_font_size: int) -> void:
	if p_font == null:
		return
	for index in p_lines.size():
		draw_string(p_font, p_origin + Vector2(0.0, 12.0 + float(index) * LEGEND_LINE), p_lines[index],
				HORIZONTAL_ALIGNMENT_LEFT, maxf(1.0, size.x - MAP_MARGIN * 2.0), maxi(9, p_font_size - 1),
				Color("b7c6ce"))


## The strip's label for a unit. It names the *density* rather than the world size, because the density
## is the ladder's own reading and the sizes span four orders of magnitude (0.25 m to 256 m) in the same
## row: "L0 1024/m ... L10 1/m" is the ladder at a glance, and `*` marks a unit that is not current.
func _unit_label(p_unit: Dictionary, p_index: int) -> String:
	return "L%d %.0f/m%s" % [p_index, float(p_unit.get("density", 0.0)),
			"" if bool(p_unit.get("valid", false)) else "*"]


func _level_color(p_level: int) -> Color:
	return LEVEL_PALETTE[clampi(p_level, 0, LEVEL_PALETTE.size() - 1)]


# A world rect as the fraction of its unit's own square. The map keeps every unit inside one extent;
# the strip keeps every unit inside its own square, which is why the pending rects have to be
# projected per unit rather than drawn in world units.
func _fraction_of_unit(p_value: Variant, p_unit: Dictionary) -> Rect2:
	if not p_value is Rect2:
		return Rect2()
	var world_size := float(p_unit.get("world_size", 0.0))
	if world_size <= 0.0:
		return Rect2()
	var origin: Vector2 = _vector2(p_unit.get("center", Vector2.ZERO)) - Vector2.ONE * world_size * 0.5
	var rect: Rect2 = p_value
	return Rect2((rect.position - origin) / world_size, rect.size / world_size)


func _world_rect_to_canvas(p_rect: Rect2, p_bounds: Rect2, p_origin: Vector2, p_scale: float) -> Rect2:
	return Rect2(p_origin + (p_rect.position - p_bounds.position) * p_scale, p_rect.size * p_scale)


func _vector2(p_value: Variant) -> Vector2:
	return p_value if p_value is Vector2 else Vector2.ZERO


# A `Rect2` out of a payload value, the way `_vector2()` is a `Vector2` out of one. The native side
# publishes `Rect2` for a slot's rect, so the guard is what keeps a payload a stub or an older build
# answers with from being a hard failure in the drawing code.
func _rect2(p_value: Variant) -> Rect2:
	return p_value if p_value is Rect2 else Rect2()
