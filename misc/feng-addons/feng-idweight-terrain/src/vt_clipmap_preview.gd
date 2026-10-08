# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Shared Inspector/window Clipmap preview. Availability follows the live layer;
# layout reads run only while visible. LOD shows level blocks and world coverage;
# Atlas shows packed rects and per-unit 3x3 cells. Both include the density ladder.
@tool
extends "res://addons/feng-idweight-terrain/src/vt_layout_preview.gd"

const MAP_MARGIN := 8.0
const STRIP_TOP := 24.0
const STRIP_SIDE := 52.0
const STRIP_LABEL := 11.0
const STRIP_GAP := 6.0
const LEGEND_LINE := 11.0
const MIN_HEIGHT := 330.0
## Bound the grid to 16 blocks per axis, using ceil(size / limit) texels per block.
const MAX_BLOCKS_PER_AXIS := 16
## Draw the full shipped eleven-unit ladder within this twelve-colour palette.
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
## Atlas panels show packed texture rects and each unit's current-frame cell indices.
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
## The first non-empty channel layer in the native preview report.
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


func _gate(p_terrain: Object) -> bool:
	# Older native builds without the availability query remain eligible for preview.
	if not p_terrain.has_method("has_vt_clipmap_layer"):
		return true
	return bool(p_terrain.call("has_vt_clipmap_layer"))


# The first layer's implementation selects the drawing from the same payload.
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


# Draw one square per unit, subdivided into storage blocks.
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
	# Draw pending work under the grid so block boundaries remain visible.
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
	# Translucent pending strips preserve the underlying coverage, including teleport jobs.
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


# Atlas texture rects and per-unit cells share current-frame slot indices.
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


# Lay out each unit's local 3x3 cells separately; gx/gy span -1..1 within a unit.
func _draw_atlas_grid(p_panel: Rect2, p_layout: Dictionary, p_font: Font, p_font_size: int,
		p_text_color: Color) -> void:
	var side := maxi(1, int(p_layout.get("grid_side", 3)))
	var rings := maxi(1, int(p_layout.get("rings", 1)))
	var half := (side - 1) / 2
	# Wrap units into a near-square grid to keep their cells readable.
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


# Both implementations use the layer's density/reach ladder.

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
	# Plot outer coverage radius (metres) against unit density (texels/metre).
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


## Label by level and density; * marks stale content.
func _unit_label(p_unit: Dictionary, p_index: int) -> String:
	return "L%d %.0f/m%s" % [p_index, float(p_unit.get("density", 0.0)),
			"" if bool(p_unit.get("valid", false)) else "*"]


func _level_color(p_level: int) -> Color:
	return LEVEL_PALETTE[clampi(p_level, 0, LEVEL_PALETTE.size() - 1)]


# Map a pending world rect into its own unit's normalized square.
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


# Unsupported payload types have no drawable rectangle.
func _rect2(p_value: Variant) -> Rect2:
	return p_value if p_value is Rect2 else Rect2()
