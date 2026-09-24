# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Small, texture-free AVT layout preview for the Terrain3D Inspector. It extends the base both layout
# previews share (`vt_layout_preview.gd`) for the terrain reference, the availability boolean and the
# poll interval; what is left here is the AVT half - the sector scan and the drawing.
@tool
extends "res://addons/feng-idweight-terrain/src/vt_layout_preview.gd"

const MAP_MARGIN := 8.0
const MAP_TOP := 28.0
const MAP_GAP := 6.0
const LEGEND_HEIGHT := 58.0
const STATS_HEIGHT := 88.0
const WIDE_LAYOUT_MIN_WIDTH := 480.0
const MIN_RADIUS := 0.001
const WORLD_SECTOR_SIZE := 64.0
const MAX_WORLD_GRID_CELLS := 4096
const MAX_SECTOR_RECTS := 2048
const MAX_COARSE_PAGE_RECTS := 2048
const MAX_RESOLUTION_LEVELS := 16
## `TerrainVT::Delivery::AVT`, which is also the value of the property that selects it.
const DELIVERY_AVT := 1

var _snapshot: Dictionary = {}
var _status := "Waiting for an editor camera"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	call_deferred("_update_minimum_height")
	queue_redraw()


func _notification(p_what: int) -> void:
	if p_what == NOTIFICATION_RESIZED:
		_update_minimum_height()


func _update_minimum_height() -> void:
	var width := size.x
	if width <= 1.0:
		var parent := get_parent_control()
		if parent != null:
			width = parent.size.x
	if width <= 1.0:
		return
	var required_height := _minimum_height_for_width(width)
	if not is_equal_approx(custom_minimum_size.y, required_height):
		custom_minimum_size.y = required_height


func _minimum_height_for_width(p_width: float) -> float:
	var width := maxf(1.0, p_width)
	if width >= WIDE_LAYOUT_MIN_WIDTH:
		var side_width := clampf(width * 0.38, 220.0, 270.0)
		var map_side := maxf(1.0, width - side_width - MAP_MARGIN * 3.0)
		var map_height := map_side + MAP_TOP + MAP_MARGIN
		var side_height := MAP_TOP + LEGEND_HEIGHT + MAP_GAP + STATS_HEIGHT + MAP_MARGIN
		return ceil(maxf(map_height, side_height))
	var map_side := maxf(1.0, width - MAP_MARGIN * 2.0)
	return ceil(map_side + MAP_TOP + LEGEND_HEIGHT + STATS_HEIGHT + MAP_GAP * 2.0 + MAP_MARGIN)


## Drops the last terrain's layout, so a host never draws it over the new terrain's name.
func _reset_preview_state() -> void:
	_snapshot.clear()
	_status = "Terrain unavailable"


func _process(_p_delta: float) -> void:
	var now_sec := float(Time.get_ticks_msec()) / 1000.0
	if now_sec - _last_poll_sec < POLL_INTERVAL_SEC:
		return
	_last_poll_sec = now_sec
	var terrain := _get_terrain()
	if terrain == null:
		_set_available(false)
		_clear_preview("Terrain unavailable")
		return
	# The gate is one boolean and runs whether or not the view is on screen, because the matrix can
	# select AVT while the section is folded and a gate that stopped would never notice. The *scan* -
	# the half that walks the visible grid and builds a record per sector - still waits for
	# visibility, which is the rule this preview has always followed.
	_set_available(_gate(terrain))
	if not _available:
		if not _snapshot.is_empty():
			_clear_preview("")
		return
	if not is_visible_in_tree():
		return
	_refresh_preview()


func _gate(p_terrain: Object) -> bool:
	# A terrain that cannot answer is not gated: the delivery matrix is what says a method is unused,
	# and a stub (or a build that predates the matrix) has nothing to conclude from.
	if not p_terrain.has_method("is_vt_delivery_used"):
		return true
	return bool(p_terrain.call("is_vt_delivery_used", DELIVERY_AVT))


func _refresh_preview() -> void:
	var terrain := _get_terrain()
	if terrain == null:
		_clear_preview("Terrain unavailable")
		return
	if not terrain.has_method("get_avt_layout_preview"):
		_clear_preview("AVT layout preview requires a newer native Terrain3D")
		return

	var camera := _get_active_camera(terrain)
	if camera == null or not is_instance_valid(camera):
		_clear_preview("Waiting for an editor camera")
		return

	# The validity checks above keep this call on the main thread and avoid
	# holding a strong terrain reference between Inspector refreshes.
	var value: Variant = terrain.call("get_avt_layout_preview", camera)
	if typeof(value) != TYPE_DICTIONARY:
		_clear_preview("AVT layout preview unavailable")
		return
	var layout: Dictionary = value
	if layout.is_empty():
		_clear_preview("No AVT layout for the current terrain view")
		return
	_snapshot = layout.duplicate(true)
	_set_status("")
	queue_redraw()


func _get_active_camera(p_terrain: Object) -> Camera3D:
	# The editor viewport is the most direct source while the Inspector is open.
	# Terrain3D's camera remains a useful fallback for tests and older editor
	# viewport layouts where no SubViewport camera has been attached yet.
	if Engine.is_editor_hint():
		var viewport_value: Variant = EditorInterface.get_editor_viewport_3d()
		if viewport_value is SubViewport:
			var viewport := viewport_value as SubViewport
			if is_instance_valid(viewport):
				var viewport_camera := viewport.get_camera_3d()
				if viewport_camera != null and is_instance_valid(viewport_camera):
					return viewport_camera

	if p_terrain.has_method("get_camera"):
		var terrain_camera_value: Variant = p_terrain.call("get_camera")
		if terrain_camera_value is Camera3D:
			var terrain_camera := terrain_camera_value as Camera3D
			if is_instance_valid(terrain_camera):
				return terrain_camera
	return null


func _clear_preview(p_status: String) -> void:
	_snapshot.clear()
	_set_status(p_status)
	queue_redraw()


func _set_status(p_status: String) -> void:
	_status = p_status


func _draw() -> void:
	var canvas := Rect2(Vector2.ZERO, size)
	draw_rect(canvas, Color("151b21"), true)
	var font := get_theme_default_font()
	var font_size := 11
	var text_color := get_theme_color("font_color", "Label")

	if not _status.is_empty():
		if font:
			draw_string(font, Vector2(MAP_MARGIN, 17.0), _status, HORIZONTAL_ALIGNMENT_LEFT,
				maxf(1.0, size.x - MAP_MARGIN * 2.0), font_size, text_color)
		return

	var bounds_value: Variant = _snapshot.get("bounds", Rect2())
	if not bounds_value is Rect2:
		_draw_status(font, font_size, text_color, "AVT layout has no world bounds")
		return
	var bounds: Rect2 = bounds_value
	if not bounds.has_area():
		_draw_status(font, font_size, text_color, "No AVT layout for the current terrain view")
		return

	var wide_layout := size.x >= WIDE_LAYOUT_MIN_WIDTH
	var map_rect: Rect2
	var legend_rect: Rect2
	var stats_rect: Rect2
	if wide_layout:
		var side_width := clampf(size.x * 0.38, 220.0, 270.0)
		var map_side := maxf(1.0, minf(size.y - MAP_TOP - MAP_MARGIN, size.x - side_width - MAP_MARGIN * 3.0))
		map_rect = Rect2(MAP_MARGIN, MAP_TOP, map_side, map_side)
		var panel_x := map_rect.end.x + MAP_GAP
		var panel_width := maxf(1.0, size.x - panel_x - MAP_MARGIN)
		legend_rect = Rect2(panel_x, MAP_TOP, panel_width, LEGEND_HEIGHT)
		stats_rect = Rect2(panel_x, MAP_TOP + LEGEND_HEIGHT + MAP_GAP, panel_width,
				maxf(1.0, size.y - MAP_TOP - LEGEND_HEIGHT - MAP_GAP - MAP_MARGIN))
	else:
		var reserved_height := LEGEND_HEIGHT + STATS_HEIGHT + MAP_GAP * 2.0 + MAP_MARGIN
		var map_side := maxf(1.0, minf(size.x - MAP_MARGIN * 2.0, size.y - MAP_TOP - reserved_height))
		map_rect = Rect2((size.x - map_side) * 0.5, MAP_TOP, map_side, map_side)
		var panel_y := map_rect.end.y + MAP_GAP
		legend_rect = Rect2(MAP_MARGIN, panel_y, maxf(1.0, size.x - MAP_MARGIN * 2.0), LEGEND_HEIGHT)
		stats_rect = Rect2(MAP_MARGIN, panel_y + LEGEND_HEIGHT + MAP_GAP,
				maxf(1.0, size.x - MAP_MARGIN * 2.0), maxf(1.0, size.y - panel_y - LEGEND_HEIGHT - MAP_GAP))

	draw_rect(map_rect, Color("10161b"), true)
	draw_rect(map_rect, Color("3b4b56"), false, 1.0)

	var camera := _vector2_from_value(_snapshot.get("camera", Vector2.ZERO))
	var radius := maxf(MIN_RADIUS, float(_snapshot.get("radius", 0.0)))
	# Native bounds include padded coarse storage. The map follows the camera's
	# actual near-field radius instead, leaving only a small SVT border around it.
	var view_half := radius + maxf(8.0, radius * 0.10)
	var view_bounds := Rect2(camera - Vector2.ONE * view_half, Vector2.ONE * (view_half * 2.0))
	var scale := map_rect.size.x / maxf(view_bounds.size.x, 0.001)
	var map_origin := map_rect.position
	var camera_canvas := _world_to_canvas(camera, view_bounds, map_origin, scale)
	var radius_canvas := radius * scale
	# The near AVT field is lightly tinted before the grid is drawn. Regions
	# outside its circle stay legible but are visibly the SVT fallback area.
	draw_circle(camera_canvas, radius_canvas, Color(0.08, 0.36, 0.44, 0.08))
	_draw_fixed_world_grid(view_bounds, map_origin, scale)

	var coarse_pages := _valid_coarse_pages()
	var coarse_count := coarse_pages.size()
	if coarse_count == 0:
		coarse_count = _draw_fallback_coarse(view_bounds, map_origin, scale, camera, radius)
	elif coarse_count <= MAX_COARSE_PAGE_RECTS:
		for page: Dictionary in coarse_pages:
			var rect: Rect2 = page.rect
			_draw_world_outline(rect, view_bounds, map_origin, scale,
					_coarse_color(int(page.get("mip", 1)), _rect_touches_circle(rect, camera, radius)),
					1.5)
	else:
		# A pathological page list is still represented by its bounded world
		# extent. Avoid making the Inspector draw tens of thousands of outlines.
		_draw_world_outline(view_bounds, view_bounds, map_origin, scale, Color("97adff", 0.55), 1.5)

	# A sector always remains a fixed 64 m world rectangle; its tier and block
	# describe the independent virtual allocation attached to that rectangle.
	# The native preview publishes `sectors` unconditionally, so this is the only
	# sector shape there is to draw.
	var sectors := _valid_sectors()
	var resolution_levels := _valid_resolution_levels()
	for sector: Dictionary in sectors:
		_draw_sector(sector, view_bounds, map_origin, scale, camera, radius, resolution_levels)

	# The native preview provides horizontal camera forward in XZ. Draw it only
	# when it is valid, so a top-down camera with no horizontal heading is not
	# given a fabricated direction.
	var camera_forward := _vector2_from_value(_snapshot.get("camera_forward", Vector2.ZERO))
	if camera_forward.length_squared() > 0.0001:
		camera_forward = camera_forward.normalized()
		var heading_length := minf(radius_canvas * 0.30, maxf(18.0, map_rect.size.x * 0.18))
		var heading_tip := camera_canvas + camera_forward * heading_length
		draw_line(camera_canvas, heading_tip, Color("f3d28a"), 2.0, true)
		var side := Vector2(-camera_forward.y, camera_forward.x) * 4.0
		draw_line(heading_tip, heading_tip - camera_forward * 7.0 + side, Color("f3d28a"), 1.5, true)
		draw_line(heading_tip, heading_tip - camera_forward * 7.0 - side, Color("f3d28a"), 1.5, true)

	# The radius is a world-space value from the native plan. The camera marker
	# makes it clear what moves when the user orbits/pans the editor viewport.
	draw_arc(camera_canvas, radius_canvas, 0.0, TAU, 64, Color("edc36a", 0.9), 1.5, true)
	draw_circle(camera_canvas, 3.0, Color("f3d28a"), true)
	draw_line(camera_canvas - Vector2(7.0, 0.0), camera_canvas + Vector2(7.0, 0.0), Color("f3d28a"), 1.0)
	draw_line(camera_canvas - Vector2(0.0, 7.0), camera_canvas + Vector2(0.0, 7.0), Color("f3d28a"), 1.0)

	_draw_resolution_schematic(legend_rect, resolution_levels, font, font_size, text_color)
	_draw_stats(stats_rect, font, font_size, sectors, resolution_levels, coarse_count, radius)
	if font:
		var contract_note := "" if not resolution_levels.is_empty() else " · tier data needed"
		var text_width := maxf(1.0, size.x - MAP_MARGIN * 2.0)
		draw_string(font, Vector2(MAP_MARGIN, 17.0), "AVT layout · world / allocation" + contract_note,
				HORIZONTAL_ALIGNMENT_LEFT, text_width, font_size, text_color)


func _draw_status(p_font: Font, p_font_size: int, p_color: Color, p_text: String) -> void:
	if p_font:
		draw_string(p_font, Vector2(MAP_MARGIN, 17.0), p_text, HORIZONTAL_ALIGNMENT_LEFT,
				maxf(1.0, size.x - MAP_MARGIN * 2.0), p_font_size, p_color)


func _draw_fixed_world_grid(p_bounds: Rect2, p_origin: Vector2, p_scale: float) -> void:
	var first_x := floori(p_bounds.position.x / WORLD_SECTOR_SIZE)
	var first_y := floori(p_bounds.position.y / WORLD_SECTOR_SIZE)
	var last_x := ceili(p_bounds.end.x / WORLD_SECTOR_SIZE)
	var last_y := ceili(p_bounds.end.y / WORLD_SECTOR_SIZE)
	var columns := maxi(0, last_x - first_x)
	var rows := maxi(0, last_y - first_y)
	if columns <= 0 or rows <= 0 or columns * rows > MAX_WORLD_GRID_CELLS:
		return
	var grid_color := Color(0.34, 0.47, 0.55, 0.20)
	for x in range(first_x, last_x + 1):
		var world_x := float(x) * WORLD_SECTOR_SIZE
		var start := _world_to_canvas(Vector2(world_x, p_bounds.position.y), p_bounds, p_origin, p_scale)
		var end := _world_to_canvas(Vector2(world_x, p_bounds.end.y), p_bounds, p_origin, p_scale)
		draw_line(start, end, grid_color, 1.0)
	for y in range(first_y, last_y + 1):
		var world_y := float(y) * WORLD_SECTOR_SIZE
		var start := _world_to_canvas(Vector2(p_bounds.position.x, world_y), p_bounds, p_origin, p_scale)
		var end := _world_to_canvas(Vector2(p_bounds.end.x, world_y), p_bounds, p_origin, p_scale)
		draw_line(start, end, grid_color, 1.0)


func _draw_sector(p_sector: Dictionary, p_bounds: Rect2, p_origin: Vector2, p_scale: float,
		p_camera: Vector2, p_radius: float, p_levels: Array) -> void:
	var rect_value: Variant = p_sector.get("rect", Rect2())
	if not rect_value is Rect2:
		return
	var rect: Rect2 = rect_value
	if not rect.has_area():
		return
	var level := maxi(0, int(p_sector.get("level", 0)))
	var active := _rect_touches_circle(rect, p_camera, p_radius)
	var visible := bool(p_sector.get("visible", active))
	var allocated := bool(p_sector.get("allocated", false))
	var color := _tier_color(level, active, visible, allocated)
	var fill := color
	fill.a = color.a * (0.20 if allocated else 0.08)
	_draw_world_fill(rect, p_bounds, p_origin, p_scale, fill)
	_draw_world_outline(rect, p_bounds, p_origin, p_scale, color, 1.7 if allocated else 1.2)


func _draw_resolution_schematic(p_map: Rect2, p_levels: Array, p_font: Font,
		p_font_size: int, p_text_color: Color) -> void:
	# This panel is deliberately outside the world map. Its squares compare
	# virtual image resolutions; they are not extra world cells and never change
	# the fixed 64 m sector geometry.
	var inset := Rect2(p_map.position + Vector2.ONE, p_map.size - Vector2.ONE * 2.0)
	draw_rect(inset, Color(0.04, 0.07, 0.09, 0.94), true)
	draw_rect(inset, Color(0.32, 0.43, 0.50, 0.85), false, 1.0)
	if p_font:
		draw_string(p_font, inset.position + Vector2(4.0, 11.0), "VT tiers · resolution only",
				HORIZONTAL_ALIGNMENT_LEFT, maxf(1.0, inset.size.x - 8.0), p_font_size - 2, p_text_color)
	if p_levels.is_empty():
		if p_font:
			draw_string(p_font, inset.position + Vector2(4.0, 35.0), "resolution tiers unavailable",
					HORIZONTAL_ALIGNMENT_LEFT, maxf(1.0, inset.size.x - 8.0), p_font_size - 2, p_text_color)
		return
	var slot_width := inset.size.x / float(p_levels.size())
	var max_resolution := 0.0
	for level_value in p_levels:
		var level: Dictionary = level_value
		max_resolution = maxf(max_resolution, float(level.get("resolution", 0.0)))
	if max_resolution <= 0.0:
		max_resolution = 1.0
	for index in p_levels.size():
		var level: Dictionary = p_levels[index]
		var resolution := maxf(1.0, float(level.get("resolution", 0.0)))
		var ratio := clampf(sqrt(resolution / max_resolution), 0.22, 1.0)
		var square_size := minf(20.0, maxf(4.0, slot_width * 0.72)) * ratio
		var center := Vector2(inset.position.x + slot_width * (float(index) + 0.5), inset.position.y + 32.0)
		var color := _tier_color(int(level.get("level", index)), true, true, true)
		color.a = 0.90
		draw_rect(Rect2(center - Vector2.ONE * square_size * 0.5, Vector2.ONE * square_size), color, false, 1.2)
		if p_font:
			draw_string(p_font, Vector2(center.x - slot_width * 0.5, inset.position.y + inset.size.y - 4.0),
					str(int(level.get("level", index))), HORIZONTAL_ALIGNMENT_CENTER, slot_width,
					maxi(8, p_font_size - 3), Color("b9c7cf"))


func _draw_stats(p_panel: Rect2, p_font: Font, p_font_size: int, p_sectors: Array,
		p_levels: Array, p_coarse_count: int, p_radius: float) -> void:
	draw_rect(p_panel, Color(0.04, 0.07, 0.09, 0.94), true)
	draw_rect(p_panel, Color(0.25, 0.34, 0.40, 0.75), false, 1.0)
	if not p_font:
		return
	var visible_count := _visible_sector_count(p_sectors)
	var allocated_count := _allocated_sector_count(p_sectors)
	var lines := [
		"Visible sectors: %d" % visible_count,
		"Allocated sectors: %d" % allocated_count,
		"Coarse pages: %d" % p_coarse_count,
		"Resolution tiers: %s (%s)" % [_integer_text(p_levels.size()), _resolution_range_text(p_levels)],
		"Local chain: %s levels (full)" % _integer_text(_fine_mip_levels()),
		"Fine max: %s / Coarse: %s texel/m" % [_density_text(_fine_density()), _density_text(_coarse_density())],
		"Radius: %.0fm · Outside: SVT" % p_radius,
	]
	var line_height := 11.0
	for index in lines.size():
		var y := p_panel.position.y + 13.0 + float(index) * line_height
		if y > p_panel.end.y - 2.0:
			break
		draw_string(p_font, Vector2(p_panel.position.x + 5.0, y), lines[index], HORIZONTAL_ALIGNMENT_LEFT,
				maxf(1.0, p_panel.size.x - 10.0), maxi(9, p_font_size - 1), Color("b7c6ce"))


func _draw_fallback_coarse(p_bounds: Rect2, p_origin: Vector2, p_scale: float,
		p_camera: Vector2, p_radius: float) -> int:
	var side := maxi(1, int(_snapshot.get("size", 1)))
	var page_world := maxf(0.001, float(_snapshot.get("page_world", p_bounds.size.x / float(side))))
	if side * side > MAX_COARSE_PAGE_RECTS:
		_draw_world_outline(p_bounds, p_bounds, p_origin, p_scale, Color("97adff", 0.55), 1.5)
		return side * side
	var count := 0
	for y in side:
		for x in side:
			var rect := Rect2(p_bounds.position + Vector2(x, y) * page_world,
					Vector2.ONE * page_world)
			_draw_world_outline(rect, p_bounds, p_origin, p_scale, _coarse_color(1,
					_rect_touches_circle(rect, p_camera, p_radius)), 1.5)
			count += 1
	return count


func _draw_world_fill(p_rect: Rect2, p_bounds: Rect2, p_origin: Vector2, p_scale: float,
		p_color: Color) -> void:
	var clipped := p_rect.intersection(p_bounds)
	if not clipped.has_area():
		return
	var canvas_rect := Rect2(_world_to_canvas(clipped.position, p_bounds, p_origin, p_scale), clipped.size * p_scale)
	draw_rect(canvas_rect, p_color, true)


func _draw_world_outline(p_rect: Rect2, p_bounds: Rect2, p_origin: Vector2, p_scale: float,
		p_color: Color, p_width: float) -> void:
	var clipped := p_rect.intersection(p_bounds)
	if not clipped.has_area():
		return
	var canvas_rect := Rect2(_world_to_canvas(clipped.position, p_bounds, p_origin, p_scale), clipped.size * p_scale)
	draw_rect(canvas_rect, p_color, false, p_width)


func _world_to_canvas(p_world: Vector2, p_bounds: Rect2, p_origin: Vector2, p_scale: float) -> Vector2:
	return p_origin + (p_world - p_bounds.position) * p_scale


func _rect_touches_circle(p_rect: Rect2, p_center: Vector2, p_radius: float) -> bool:
	var nearest := Vector2(
			clampf(p_center.x, p_rect.position.x, p_rect.end.x),
			clampf(p_center.y, p_rect.position.y, p_rect.end.y))
	return nearest.distance_squared_to(p_center) <= p_radius * p_radius


func _valid_coarse_pages() -> Array:
	var result: Array = []
	var value: Variant = _snapshot.get("coarse_pages", [])
	if not value is Array:
		return result
	for page_value in value:
		if typeof(page_value) != TYPE_DICTIONARY:
			continue
		var page: Dictionary = page_value
		var rect_value: Variant = page.get("rect", Rect2())
		if not rect_value is Rect2 or not (rect_value as Rect2).has_area():
			continue
		result.append(page)
	return result


func _valid_sectors() -> Array:
	var result: Array = []
	var value: Variant = _snapshot.get("sectors", [])
	if not value is Array:
		return result
	for sector_value in value:
		if typeof(sector_value) != TYPE_DICTIONARY:
			continue
		var sector: Dictionary = sector_value
		var rect_value: Variant = sector.get("rect", Rect2())
		if not rect_value is Rect2 or not (rect_value as Rect2).has_area():
			continue
		result.append(sector)
		if result.size() >= MAX_SECTOR_RECTS:
			break
	return result


func _valid_resolution_levels() -> Array:
	var result: Array = []
	var value: Variant = _snapshot.get("resolution_levels", [])
	if not value is Array:
		return result
	for level_value in value:
		if typeof(level_value) != TYPE_DICTIONARY:
			continue
		var level: Dictionary = level_value
		if int(level.get("level", result.size())) < 0:
			continue
		result.append(level)
		if result.size() >= MAX_RESOLUTION_LEVELS:
			break
	return result


func _fine_mip_levels() -> int:
	# This field is the complete local page-table chain, independent of the
	# number of world resolution tiers selected by surface_vt_mip_levels.
	var levels := int(_snapshot.get("fine_mip_levels", 0))
	return maxi(1, levels) if levels > 0 else 0


func _fine_density() -> float:
	if not _snapshot.has("resolution_levels") or not _snapshot.has("effective_texels_per_meter"):
		return 0.0
	var density := float(_snapshot.get("effective_texels_per_meter", 0.0))
	return density if density > 0.0 else 0.0


func _coarse_density() -> float:
	var density := float(_snapshot.get("coarse_texels_per_meter", 0.0))
	return density if density > 0.0 else 0.0


func _allocated_sector_count(p_sectors: Array) -> int:
	var count := 0
	for sector_value in p_sectors:
		if typeof(sector_value) == TYPE_DICTIONARY and bool((sector_value as Dictionary).get("allocated", false)):
			count += 1
	return count


func _visible_sector_count(p_sectors: Array) -> int:
	var count := 0
	for sector_value in p_sectors:
		if typeof(sector_value) == TYPE_DICTIONARY and bool((sector_value as Dictionary).get("visible", true)):
			count += 1
	return count


func _density_text(p_density: float) -> String:
	return "—" if p_density <= 0.0 else "%.0f" % p_density


func _integer_text(p_value: int) -> String:
	return "—" if p_value <= 0 else str(p_value)


func _resolution_range_text(p_levels: Array) -> String:
	if p_levels.is_empty():
		return "—"
	var highest := 0.0
	var lowest := INF
	for level_value in p_levels:
		if typeof(level_value) != TYPE_DICTIONARY:
			continue
		var resolution := float((level_value as Dictionary).get("resolution", 0.0))
		if resolution <= 0.0:
			continue
		highest = maxf(highest, resolution)
		lowest = minf(lowest, resolution)
	if highest <= 0.0 or lowest == INF:
		return "—"
	return "%s→%s" % [_resolution_text(highest), _resolution_text(lowest)]


func _resolution_text(p_resolution: float) -> String:
	if p_resolution >= 1024.0:
		return "%.0fk" % (p_resolution / 1024.0)
	return "%.0f" % p_resolution


func _tier_color(p_level: int, p_active: bool, p_visible: bool, p_allocated: bool) -> Color:
	var palette := [
		Color("55d6be"), Color("5cc8ef"), Color("6f9df5"), Color("8d7cf2"),
		Color("b27bea"), Color("d875cb"), Color("eb7c9e"), Color("f09573"),
		Color("f4b65e"), Color("f0d36a"), Color("d8e77e"), Color("aee59b"),
	]
	var color: Color = palette[clampi(p_level, 0, palette.size() - 1)]
	var alpha := 0.82 if p_active else 0.20
	if not p_visible:
		alpha *= 0.65
	if not p_allocated:
		alpha *= 0.62
	color.a = alpha
	return color


func _coarse_color(p_mip: int, p_active: bool) -> Color:
	var palette := [Color("7cddf5"), Color("97adff"), Color("bd93f9"), Color("e59bd0"), Color("f0bb86")]
	var color: Color = palette[clampi(p_mip, 0, palette.size() - 1)]
	color.a = 0.88 if p_active else 0.18
	return color


func _vector2_from_value(p_value: Variant) -> Vector2:
	if p_value is Vector2:
		return p_value
	return Vector2.ZERO
