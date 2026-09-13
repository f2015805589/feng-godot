# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Clickable, cached world overview used by the Surface VT editor.
@tool
extends Control
class_name TerrainVTWorldOverview

signal region_clicked(location: Vector2i)

var world_bounds: Rect2 = Rect2()
var region_size_world: Vector2 = Vector2(1.0, 1.0)
var regions: Array = []
var overview_texture: Texture2D
var selected_location: Vector2i = Vector2i(2147483647, 2147483647)
var hovered_location: Vector2i = Vector2i(2147483647, 2147483647)

var _region_lookup: Dictionary = {}
var fit_mode: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	set_process(false)


func set_overview(p_regions: Array, p_world_bounds: Rect2, p_region_size_world: Vector2,
		p_texture: Texture2D) -> void:
	regions = p_regions.duplicate(true)
	world_bounds = p_world_bounds
	region_size_world = p_region_size_world
	overview_texture = p_texture
	_update_canvas_height()
	_region_lookup.clear()
	for region in regions:
		if typeof(region) != TYPE_DICTIONARY or not region.has("location"):
			continue
		_region_lookup[region.location] = true
	queue_redraw()


func clear_overview() -> void:
	regions.clear()
	world_bounds = Rect2()
	overview_texture = null
	_region_lookup.clear()
	selected_location = Vector2i(2147483647, 2147483647)
	hovered_location = Vector2i(2147483647, 2147483647)
	queue_redraw()


func set_selected_location(p_location: Vector2i) -> void:
	selected_location = p_location
	queue_redraw()


func _notification(p_what: int) -> void:
	if p_what == NOTIFICATION_RESIZED:
		_update_canvas_height()
		queue_redraw()


func set_fit_mode(enabled: bool) -> void:
	fit_mode = enabled
	_update_canvas_height()
	queue_redraw()


func _update_canvas_height() -> void:
	# Fit the full width without squashing the map; the parent scrolls vertically.
	if fit_mode:
		custom_minimum_size.y = 0.0
	elif world_bounds.has_area():
		custom_minimum_size.y = maxf(180.0, size.x * world_bounds.size.y / world_bounds.size.x)


func _draw() -> void:
	var canvas := Rect2(Vector2.ZERO, size)
	draw_rect(canvas, Color("15191f"), true)
	if not world_bounds.has_area():
		var empty_font := get_theme_default_font()
		if empty_font:
			draw_string(empty_font, Vector2(16.0, 26.0), "No terrain regions", HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, get_theme_default_font_size(), get_theme_color("font_color", "Label"))
		return

	var image_rect := _image_rect(canvas)
	if overview_texture:
		draw_texture_rect(overview_texture, image_rect, false)
	else:
		draw_rect(image_rect, Color("222a32"), true)

	# Draw region bounds and labels on top of the cached thumbnail. The rectangles
	# are cheap and make sparse worlds and missing cells obvious at a glance.
	for region in regions:
		if typeof(region) != TYPE_DICTIONARY or not region.has("location"):
			continue
		var location: Vector2i = region.location
		var rect := _region_rect(location, image_rect)
		var has_data: bool = region.get("has_height", false)
		var has_material: bool = region.get("has_material", false)
		# Keep the baked RGB visible exactly as stitched. Material coverage is
		# communicated by the violet outline; a translucent fill would tint the
		# preview and make colour comparisons misleading.
		var fill := Color(0.0, 0.0, 0.0, 0.0) if has_material else (Color(0.15, 0.22, 0.29, 0.18) if has_data else Color(0.08, 0.10, 0.12, 0.35))
		draw_rect(rect, fill, true)
		var border := Color("d0a7ff") if has_material else (Color("a9d3ff") if has_data else Color("65717c"))
		if location == hovered_location:
			border = Color("f5c46b")
		if location == selected_location:
			border = Color("74e0a0")
		draw_rect(rect, border, false, 2.0 if location == selected_location else 1.0)

		# Avoid clutter when a region is smaller than a readable label. Tooltips and
		# the inspector still identify those cells when they are clicked.
		if rect.size.x >= 42.0 and rect.size.y >= 20.0:
			var font := get_theme_default_font()
			if font:
				draw_string(font, rect.position + Vector2(5.0, 16.0), str(location),
						HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color("f1f5f9"))

	# Keep a clear frame around the map even when its cached image fills the panel.
	draw_rect(image_rect, Color("74808c"), false, 1.0)


func _image_rect(p_canvas: Rect2) -> Rect2:
	if not world_bounds.has_area() or not p_canvas.size.x > 1.0 or not p_canvas.size.y > 1.0:
		return p_canvas
	var aspect := world_bounds.size.x / maxf(world_bounds.size.y, 0.001)
	var canvas_aspect := p_canvas.size.x / maxf(p_canvas.size.y, 0.001)
	var result := p_canvas
	if aspect > canvas_aspect:
		result.size.y = p_canvas.size.x / aspect
		result.position.y += (p_canvas.size.y - result.size.y) * 0.5
	else:
		result.size.x = p_canvas.size.y * aspect
		result.position.x += (p_canvas.size.x - result.size.x) * 0.5
	return result


func _region_rect(p_location: Vector2i, p_image_rect: Rect2) -> Rect2:
	var scale := Vector2(
		p_image_rect.size.x / maxf(world_bounds.size.x, 0.001),
		p_image_rect.size.y / maxf(world_bounds.size.y, 0.001))
	var world_position := Vector2(p_location.x * region_size_world.x,
			p_location.y * region_size_world.y)
	return Rect2(p_image_rect.position + (world_position - world_bounds.position) * scale,
			region_size_world * scale)


func _location_at(p_position: Vector2) -> Vector2i:
	var image_rect := _image_rect(Rect2(Vector2.ZERO, size))
	if not image_rect.has_point(p_position) or not world_bounds.has_area():
		return Vector2i(2147483647, 2147483647)
	var normalized := (p_position - image_rect.position) / image_rect.size
	var world_position := world_bounds.position + Vector2(
			normalized.x * world_bounds.size.x, normalized.y * world_bounds.size.y)
	return Vector2i(floori(world_position.x / maxf(region_size_world.x, 0.001)),
			floori(world_position.y / maxf(region_size_world.y, 0.001)))


func _gui_input(p_event: InputEvent) -> void:
	if p_event is InputEventMouseMotion:
		var location := _location_at(p_event.position)
		var next_hover := location if _region_lookup.has(location) else Vector2i(2147483647, 2147483647)
		if next_hover != hovered_location:
			hovered_location = next_hover
			tooltip_text = "Region %s — click to inspect" % next_hover if _region_lookup.has(next_hover) else ""
			queue_redraw()
		return
	if p_event is InputEventMouseButton and p_event.button_index == MOUSE_BUTTON_LEFT and p_event.pressed:
		var location := _location_at(p_event.position)
		if _region_lookup.has(location):
			selected_location = location
			region_clicked.emit(location)
			accept_event()
