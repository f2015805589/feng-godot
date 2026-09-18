# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Image maths for the VT window's overview: world <-> image mapping, the stitched
# height thumbnail, and compositing baked material pages over it.
#
# These are pure functions over data that is passed in, so the per-pixel work can
# be reasoned about (and exercised) without a window, a live terrain or a tree.
@tool
class_name TerrainVTOverviewImage
extends RefCounted


static func overview_size(p_bounds: Rect2, p_edge: int) -> Vector2i:
	var longest := maxf(p_bounds.size.x, p_bounds.size.y)
	var scale := float(p_edge) / maxf(longest, 1.0)
	return Vector2i(max(1, roundi(p_bounds.size.x * scale)), max(1, roundi(p_bounds.size.y * scale)))


static func world_to_image(p_world: Vector2, p_bounds: Rect2, p_size: Vector2i) -> Vector2i:
	var uv := (p_world - p_bounds.position) / Vector2(maxf(p_bounds.size.x, 0.001), maxf(p_bounds.size.y, 0.001))
	return Vector2i(floori(uv.x * p_size.x), floori(uv.y * p_size.y))


static func region_rect_world(p_location: Vector2i, p_region_world: Vector2) -> Rect2:
	return Rect2(Vector2(p_location) * p_region_world, p_region_world)


static func region_world_bounds(p_locations: Array, p_region_world: Vector2) -> Rect2:
	var result := Rect2()
	var first := true
	for location in p_locations:
		var rect := region_rect_world(location, p_region_world)
		if first:
			result = rect
			first = false
		else:
			result = result.merge(rect)
	return result


# The baked pages published at one mip, with a usable preview image.
static func material_pages(p_pages: Array, p_mip: int) -> Array:
	if p_pages.is_empty():
		return []
	var result: Array = []
	for record in p_pages:
		if typeof(record) == TYPE_DICTIONARY and int(record.get("mip", 0)) == p_mip and TerrainVTBridge.is_valid_image(record.get("preview", null)):
			result.append(record)
	return result


# A display copy of a baked payload: its alpha stores height, so the copy has to
# be made opaque, and its RGB values are linear GPU output and need sRGB
# conversion. Both display paths below want exactly this.
static func to_display_image(p_image: Image) -> void:
	for y in p_image.get_height():
		for x in p_image.get_width():
			var color := p_image.get_pixel(x, y).linear_to_srgb()
			color.a = 1.0
			p_image.set_pixel(x, y, color)


# A texture for the page inspector. `p_edge` keeps the inspector responsive when a
# full page is larger than the preview panel.
static func display_texture(p_value: Variant, p_edge: int = 512) -> Texture2D:
	if not TerrainVTBridge.is_valid_image(p_value):
		return null
	var image: Image = p_value.duplicate()
	var longest := maxi(image.get_width(), image.get_height())
	if longest > p_edge:
		var scale := float(p_edge) / longest
		image.resize(maxi(1, roundi(image.get_width() * scale)), maxi(1, roundi(image.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	to_display_image(image)
	return ImageTexture.create_from_image(image)


# Composites one baked page over the overview. `p_border` is the texel border the
# producer stored around the page core.
static func blit_material_preview(p_image: Image, p_record: Dictionary, p_bounds: Rect2, p_border: int) -> void:
	var preview = p_record.get("preview", null)
	if not TerrainVTBridge.is_valid_image(preview):
		return
	var tile: Image = preview.duplicate()
	var crop := Rect2i(p_border, p_border, tile.get_width() - 2 * p_border, tile.get_height() - 2 * p_border)
	if crop.size.x > 0 and crop.size.y > 0:
		tile = tile.get_region(crop)
	var rect: Rect2 = p_record.get("world_rect", Rect2())
	if not rect.has_area() or not p_bounds.has_area():
		return
	# A coarse SVT tile can cover more world space than the loaded terrain. Clip
	# in world coordinates before resizing so an enormous page never allocates a
	# giant intermediate image and only the visible source UVs are copied.
	var visible_rect := rect.intersection(p_bounds)
	if not visible_rect.has_area():
		return
	var source_uv := Rect2(
		(visible_rect.position - rect.position) / rect.size,
		visible_rect.size / rect.size)
	var source_rect := Rect2i(
		floori(source_uv.position.x * tile.get_width()),
		floori(source_uv.position.y * tile.get_height()),
		ceili(source_uv.size.x * tile.get_width()),
		ceili(source_uv.size.y * tile.get_height()))
	source_rect = source_rect.intersection(Rect2i(Vector2i.ZERO, tile.get_size()))
	if source_rect.size.x <= 0 or source_rect.size.y <= 0:
		return
	tile = tile.get_region(source_rect)
	var position := world_to_image(visible_rect.position, p_bounds, p_image.get_size())
	var end := world_to_image(visible_rect.end, p_bounds, p_image.get_size())
	var size := Vector2i(max(1, end.x - position.x), max(1, end.y - position.y))
	# Resize before colour conversion so a large baked page never incurs a full
	# native-resolution per-pixel display pass in the editor.
	tile.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
	if tile.get_format() != Image.FORMAT_RGBA8:
		tile.convert(Image.FORMAT_RGBA8)
	# Work on this duplicate only: the serialized channel image must remain
	# untouched for later page inspection/export.
	to_display_image(tile)
	p_image.blit_rect(tile, Rect2i(Vector2i.ZERO, tile.get_size()), position)


# The stitched height overview: each region's CPU height image is read once and
# downsampled in memory. The previous implementation called
# Terrain3DData.get_height() for every thumbnail pixel, which made an explicit
# 768px overview issue hundreds of thousands of native calls. Sampling is capped
# at 128x128 per region and the small image is then enlarged into the stitch.
static func height_thumbnail(p_bounds: Rect2, p_size: Vector2i, p_locations: Array,
		p_region_world: Vector2, p_global_range: Vector2, p_get_region: Callable) -> Image:
	var image := Image.create(p_size.x, p_size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color("202a31"))
	for location in p_locations:
		var region: Object = p_get_region.call(location)
		var height_image = TerrainVTBridge.call_method(region, "get_height_map")
		if not TerrainVTBridge.is_valid_image(height_image):
			continue
		var world_rect := region_rect_world(location, p_region_world)
		var dst_position := world_to_image(world_rect.position, p_bounds, p_size)
		var dst_end := world_to_image(world_rect.end, p_bounds, p_size)
		var dst_size := Vector2i(max(1, dst_end.x - dst_position.x), max(1, dst_end.y - dst_position.y))
		var sample_size := mini(128, maxi(8, maxi(dst_size.x, dst_size.y)))
		var sample := Image.create(sample_size, sample_size, false, Image.FORMAT_RGBA8)
		var region_range: Vector2 = TerrainVTBridge.call_method(region, "get_height_range")
		if region_range.y <= region_range.x:
			region_range = p_global_range
		var low := region_range.x
		var span := maxf(region_range.y - region_range.x, 0.001)
		for y in sample_size:
			var source_y := mini(height_image.get_height() - 1, floori(float(y) * height_image.get_height() / sample_size))
			for x in sample_size:
				var source_x := mini(height_image.get_width() - 1, floori(float(x) * height_image.get_width() / sample_size))
				var value: float = height_image.get_pixel(source_x, source_y).r
				var normalized := clampf((value - low) / span, 0.0, 1.0)
				sample.set_pixel(x, y, Color(normalized * 0.65 + 0.12, normalized * 0.8 + 0.12, normalized * 0.95 + 0.12, 1.0))
		sample.resize(dst_size.x, dst_size.y, Image.INTERPOLATE_BILINEAR)
		image.blit_rect(sample, Rect2i(Vector2i.ZERO, sample.get_size()), dst_position)
	return image
