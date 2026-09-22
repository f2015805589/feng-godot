# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The clipmap ring's debug view: what the ring holds, where it holds it, and which blocks it is
# still producing. One control with two hosts - the Inspector's Surface VT / VT Page section and
# the Surface VT window's VT Page view - because it is a picture of the ring rather than of either
# window.
#
# **It draws nothing, and asks for nothing, while no ring exists.** The native preview refuses a
# terrain with no ring, so a view that kept asking would spend a call per interval to be told there is
# no layout; this one asks for one boolean instead (`has_vt_clipmap_ring()`) and hides itself. That
# boolean is cheap enough to keep polling while the view is hidden - a ring can be built while a
# section is folded - and the expensive `get_clipmap_layout_preview()` call waits for visibility,
# which is the rule the AVT preview follows for its scan.
#
# The gate is "is there a ring" rather than "does a cell select the method", and in a build that
# cannot deliver Clipmap for any group the two are the same answer for a user: no cell may name the
# method, so no ring exists and this view never appears. A ring built to measure the mechanism
# (`Terrain3D::debug_update_vt_clipmap()`, which is what the native suites drive) is a ring this view
# draws, because a picture of a ring is a picture of the ring that exists - not of the setting that
# asked for it.
#
# The two halves of the drawing answer the two questions a ring raises, and neither replaces the
# other:
#   * the *level strip* is the clipmap assembled from blocks: one square per level, each cut into
#     the texel blocks it is addressed in, coloured by level and drawn solid only while the level is
#     valid. It is the same readable picture whatever the ratio between the coarsest and the finest
#     level is - and that ratio is `2^levels`, which no single world map can show.
#   * the *map* is where those levels stand in the world. Every level's square is snapped to its own
#     texel size, so a level that is current sits on the focus and one that still holds the level it
#     replaces is offset from it by what it has not produced; the rects still queued are drawn on top,
#     because the strips a moving focus has just cost are the only part of the ring that changes.
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
## Levels drawn in the strip. A ring is allowed 16; the ones past this many share the row's width,
## so the strip stops rather than drawing sub-pixel squares.
const MAX_SCHEMATIC_LEVELS := 8
const LEVEL_PALETTE: Array[Color] = [
	Color("55d6be"), Color("5cc8ef"), Color("6f9df5"), Color("8d7cf2"),
	Color("b27bea"), Color("d875cb"), Color("eb7c9e"), Color("f09573"),
	Color("f4b65e"), Color("f0d36a"), Color("d8e77e"), Color("aee59b"),
]
const VALID_FILL_ALPHA := 0.16
const INVALID_FILL_ALPHA := 0.05
const BLOCK_LINE_ALPHA := 0.35
const PENDING_COLOR := Color("ff9f43")

var _snapshot: Dictionary = {}
var _status := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0.0, MIN_HEIGHT)
	set_process(true)
	queue_redraw()


func _reset_preview_state() -> void:
	_snapshot.clear()
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
	# The gate is one boolean and runs whether or not this view is on screen, because a ring can come
	# into existence while the section is folded and a gate that stopped would never notice.
	_set_available(_gate(terrain))
	if not _available:
		if not _snapshot.is_empty():
			_snapshot.clear()
			queue_redraw()
		return
	if not is_visible_in_tree():
		return
	_refresh_preview(terrain)


func _gate(p_terrain: Object) -> bool:
	# A terrain that cannot answer is not gated: the ring's existence is what says a view has something
	# to draw, and a stub (or a build that predates the query) has nothing to conclude from. The real
	# terrain always has the method, so the gate is exact where it matters.
	if not p_terrain.has_method("has_vt_clipmap_ring"):
		return true
	return bool(p_terrain.call("has_vt_clipmap_ring"))


func _refresh_preview(p_terrain: Object) -> void:
	if not p_terrain.has_method("get_clipmap_layout_preview"):
		_clear_preview("Clipmap debug needs a newer native Terrain3D")
		return
	var value: Variant = p_terrain.call("get_clipmap_layout_preview")
	if typeof(value) != TYPE_DICTIONARY:
		_clear_preview("Clipmap preview unavailable")
		return
	var layout: Dictionary = value
	if layout.is_empty():
		_clear_preview("No ring exists: no delivery cell may select Clipmap in this build")
		return
	_snapshot = layout.duplicate(true)
	_status = ""
	queue_redraw()


func _clear_preview(p_status: String) -> void:
	_snapshot.clear()
	_status = p_status
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("151b21"), true)
	var font := get_theme_default_font()
	var font_size := 11
	var text_color := get_theme_color("font_color", "Label")
	if font:
		draw_string(font, Vector2(MAP_MARGIN, 14.0), "Clipmap ring · levels / world", HORIZONTAL_ALIGNMENT_LEFT,
				maxf(1.0, size.x - MAP_MARGIN * 2.0), font_size, text_color)
	if not _status.is_empty():
		if font:
			draw_string(font, Vector2(MAP_MARGIN, STRIP_TOP + 14.0), _status, HORIZONTAL_ALIGNMENT_LEFT,
					maxf(1.0, size.x - MAP_MARGIN * 2.0), font_size, text_color)
		return
	var rings := _rings()
	if rings.is_empty():
		return
	var legend := _legend_lines(rings)
	var legend_height := float(legend.size()) * LEGEND_LINE + 6.0
	var strip_height := float(rings.size()) * (STRIP_SIDE + STRIP_LABEL)
	_draw_level_strip(rings, font, font_size, text_color)
	var map_side := minf(size.x - MAP_MARGIN * 2.0,
			size.y - STRIP_TOP - strip_height - legend_height - MAP_MARGIN)
	if map_side > 24.0:
		_draw_map(Rect2(Vector2(MAP_MARGIN, STRIP_TOP + strip_height), Vector2(map_side, map_side)), rings)
	_draw_legend(Vector2(MAP_MARGIN, size.y - legend_height), legend, font, font_size)


func _rings() -> Array:
	var value: Variant = _snapshot.get("rings", [])
	if not value is Array:
		return []
	var rings: Array = []
	for entry in (value as Array):
		if typeof(entry) == TYPE_DICTIONARY:
			rings.append(entry)
	return rings


func _levels_of(p_ring: Dictionary) -> Array:
	var value: Variant = p_ring.get("levels", [])
	if not value is Array:
		return []
	var levels: Array = []
	for entry in (value as Array):
		if typeof(entry) == TYPE_DICTIONARY:
			levels.append(entry)
	return levels


# The assembled ring, one row per ring and one square per level: each square is the level's own
# storage cut into the blocks it is addressed in, so a strip the budget cut short is visible as the
# part of the square it left untouched.
func _draw_level_strip(p_rings: Array, p_font: Font, p_font_size: int, p_text_color: Color) -> void:
	for ring_index in p_rings.size():
		var ring: Dictionary = p_rings[ring_index]
		var levels := _levels_of(ring)
		var count := mini(levels.size(), MAX_SCHEMATIC_LEVELS)
		if count <= 0:
			continue
		var row_y := STRIP_TOP + float(ring_index) * (STRIP_SIDE + STRIP_LABEL)
		var usable := size.x - MAP_MARGIN * 2.0 - STRIP_GAP * float(count - 1)
		var side := minf(STRIP_SIDE, usable / float(count))
		for index in count:
			var level: Dictionary = levels[index]
			var square := Rect2(MAP_MARGIN + float(index) * (side + STRIP_GAP), row_y, side, side)
			_draw_level_blocks(square, level, index)
			if p_font:
				draw_string(p_font, Vector2(square.position.x, square.end.y + 9.0), _level_label(level, index),
						HORIZONTAL_ALIGNMENT_CENTER, side, p_font_size - 2, p_text_color)


func _draw_level_blocks(p_square: Rect2, p_level: Dictionary, p_index: int) -> void:
	var valid := bool(p_level.get("valid", false))
	var color := _level_color(p_index)
	draw_rect(p_square, Color(color.r, color.g, color.b, VALID_FILL_ALPHA if valid else INVALID_FILL_ALPHA), true)
	# The queued rects go under the grid, not over it: the blocks are what the picture is of, and a
	# solid fill drawn last would hide the very thing it is made of. This is the one place the
	# ordering of two draws is a decision.
	for value: Variant in p_level.get("pending_rects", []):
		var fraction := _fraction_of_level(value, p_level)
		if fraction.has_area():
			draw_rect(Rect2(p_square.position + fraction.position * p_square.size,
					fraction.size * p_square.size), PENDING_COLOR, true)
	var texels := maxi(1, int(p_level.get("size", 1)))
	var step := maxi(1, int(ceil(float(texels) / float(MAX_BLOCKS_PER_AXIS))))
	var blocks := maxi(1, int(ceil(float(texels) / float(step))))
	var edge := p_square.size.x / float(blocks)
	var line := Color(color.r, color.g, color.b, BLOCK_LINE_ALPHA)
	for block in range(1, blocks):
		var offset := float(block) * edge
		draw_line(p_square.position + Vector2(offset, 0.0), p_square.position + Vector2(offset, p_square.size.y), line, 1.0)
		draw_line(p_square.position + Vector2(0.0, offset), p_square.position + Vector2(p_square.size.x, offset), line, 1.0)
	draw_rect(p_square, color, false, 1.6 if valid else 1.0)


# Where the levels stand in the world. The view is the coarsest level's own square, because that is
# the whole of what the ring covers; a finer level is a smaller square inside it, drawn on top.
func _draw_map(p_map: Rect2, p_rings: Array) -> void:
	var extent := 0.0
	for ring: Dictionary in p_rings:
		for level: Dictionary in _levels_of(ring):
			extent = maxf(extent, float(level.get("world_size", 0.0)))
	if extent <= 0.0:
		return
	var focus := _vector2(_snapshot.get("focus", Vector2.ZERO))
	var bounds := Rect2(focus - Vector2.ONE * extent * 0.5, Vector2.ONE * extent)
	var scale := p_map.size.x / extent
	draw_rect(p_map, Color("10161b"), true)
	draw_rect(p_map, Color("3b4b56"), false, 1.0)
	for ring: Dictionary in p_rings:
		var levels := _levels_of(ring)
		for index in range(levels.size() - 1, -1, -1):
			var level: Dictionary = levels[index]
			var world_size := float(level.get("world_size", 0.0))
			if world_size <= 0.0:
				continue
			var world_rect := Rect2(_vector2(level.get("center", Vector2.ZERO)) - Vector2.ONE * world_size * 0.5,
					Vector2.ONE * world_size)
			var canvas := _world_rect_to_canvas(world_rect, bounds, p_map.position, scale)
			var color := _level_color(index)
			var valid := bool(level.get("valid", false))
			draw_rect(canvas, Color(color.r, color.g, color.b, 0.10 if valid else 0.03), true)
			draw_rect(canvas, Color(color.r, color.g, color.b, 0.85 if valid else 0.40), false, 1.2)
	# The queued work last, and translucent: a level that has lost a strip is still drawn under it, and
	# an opaque fill at the coarsest level would cover the whole map - which is exactly the state a
	# teleport produces, and exactly when the picture is most useful.
	for ring: Dictionary in p_rings:
		for level: Dictionary in _levels_of(ring):
			for value: Variant in level.get("pending_rects", []):
				if not value is Rect2:
					continue
				var clipped := _world_rect_to_canvas(value, bounds, p_map.position, scale).intersection(p_map)
				if clipped.has_area():
					draw_rect(clipped, Color(PENDING_COLOR.r, PENDING_COLOR.g, PENDING_COLOR.b, 0.45), true)
					draw_rect(clipped, PENDING_COLOR, false, 1.0)
	var marker := p_map.position + (focus - bounds.position) * scale
	if p_map.has_point(marker):
		draw_circle(marker, 3.0, Color("f3d28a"), true)
		draw_line(marker - Vector2(6.0, 0.0), marker + Vector2(6.0, 0.0), Color("f3d28a"), 1.0)
		draw_line(marker - Vector2(0.0, 6.0), marker + Vector2(0.0, 6.0), Color("f3d28a"), 1.0)


func _draw_legend(p_origin: Vector2, p_lines: Array[String], p_font: Font, p_font_size: int) -> void:
	if p_font == null:
		return
	for index in p_lines.size():
		draw_string(p_font, p_origin + Vector2(0.0, 12.0 + float(index) * LEGEND_LINE), p_lines[index],
				HORIZONTAL_ALIGNMENT_LEFT, maxf(1.0, size.x - MAP_MARGIN * 2.0), maxi(9, p_font_size - 1),
				Color("b7c6ce"))


func _legend_lines(p_rings: Array) -> Array[String]:
	var focus := _vector2(_snapshot.get("focus", Vector2.ZERO))
	var lines: Array[String] = []
	lines.append("focus %.1f, %.1f · %d texels a tick · levels %d" % [focus.x, focus.y,
			int(_snapshot.get("budget_texels", 0)), int(_snapshot.get("levels_setting", 0))])
	for ring: Dictionary in p_rings:
		var levels := _levels_of(ring)
		var valid := 0
		var queued := 0
		for level: Dictionary in levels:
			if bool(level.get("valid", false)):
				valid += 1
			queued += int(level.get("pending", 0))
		lines.append("%s ring · source %s · %d/%d levels valid · %d queued · %.1f KB uploaded" % [
				str(ring.get("group", "?")), str(ring.get("source", "?")), valid, levels.size(), queued,
				float(ring.get("upload_bytes", 0)) / 1024.0])
	var texels := maxi(1, int(_snapshot.get("size", 1)))
	var step := maxi(1, int(ceil(float(texels) / float(MAX_BLOCKS_PER_AXIS))))
	lines.append("a square is one level, cut every %d of its %d texels · orange rects are queued strips" % [step, texels])
	return lines


func _level_label(p_level: Dictionary, p_index: int) -> String:
	return "L%d %.0fm%s" % [p_index, float(p_level.get("world_size", 0.0)),
			"" if bool(p_level.get("valid", false)) else "*"]


func _level_color(p_level: int) -> Color:
	return LEVEL_PALETTE[clampi(p_level, 0, LEVEL_PALETTE.size() - 1)]


# A world rect as the fraction of its level's own square. The map keeps every level inside one
# extent; the strip keeps every level inside its own square, which is why the pending rects have to
# be projected per level rather than drawn in world units.
func _fraction_of_level(p_value: Variant, p_level: Dictionary) -> Rect2:
	if not p_value is Rect2:
		return Rect2()
	var world_size := float(p_level.get("world_size", 0.0))
	if world_size <= 0.0:
		return Rect2()
	var origin: Vector2 = _vector2(p_level.get("center", Vector2.ZERO)) - Vector2.ONE * world_size * 0.5
	var rect: Rect2 = p_value
	return Rect2((rect.position - origin) / world_size, rect.size / world_size)


func _world_rect_to_canvas(p_rect: Rect2, p_bounds: Rect2, p_origin: Vector2, p_scale: float) -> Rect2:
	return Rect2(p_origin + (p_rect.position - p_bounds.position) * p_scale, p_rect.size * p_scale)


func _vector2(p_value: Variant) -> Vector2:
	return p_value if p_value is Vector2 else Vector2.ZERO
