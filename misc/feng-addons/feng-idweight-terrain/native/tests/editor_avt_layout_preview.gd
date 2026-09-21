@tool
extends EditorPlugin

## Focused render check for the Inspector AVT layout Control. It uses a small
## fake Terrain3D API so this UI check does not depend on the native producer
## finishing a plan while the editor is paused.

class FakeTerrain extends RefCounted:
	var camera: Camera3D

	func get_camera() -> Camera3D:
		return camera

	func get_avt_layout_preview(_p_camera: Camera3D) -> Dictionary:
		var coarse_pages: Array = []
		var resolution_levels: Array = []
		for level in 10:
			resolution_levels.append({
				"level": level,
				"resolution": 65536 >> level,
				"texels_per_meter": 1024.0 / pow(2.0, level),
				"block_size": maxi(1, 256 >> mini(level, 8)),
			})
		var sectors: Array = []
		var sector_levels := [0, 3, 6, 9]
		for index in 4:
			var rect := Rect2(Vector2(-64.0 + (index % 2) * 64.0, -64.0 + (index / 2) * 64.0), Vector2.ONE * 64.0)
			var level: int = sector_levels[index]
			sectors.append({
				"rect": rect,
				"level": level,
				"resolution": 65536 >> level,
				"block_size": maxi(1, 256 >> mini(level, 8)),
				"logical_pages": 256.0 / pow(2.0, level),
				"visible": index != 3,
				"allocated": index != 2,
				"allocation_rect": Rect2(Vector2(index * 16, 0), Vector2.ONE * maxi(1, 16 >> mini(level, 4))) if index != 2 else Rect2(),
			})
		for y in 6:
			for x in 6:
				coarse_pages.append({
					"rect": Rect2(Vector2(-384.0 + x * 128.0, -384.0 + y * 128.0), Vector2.ONE * 128.0),
					"mip": 1 if (x + y) % 3 else 2,
				})
		return {
			"bounds": Rect2(Vector2(-384.0, -384.0), Vector2.ONE * 768.0),
			"camera": Vector2.ZERO,
			"camera_forward": Vector2(1.0, 0.25).normalized(),
			"radius": 384.0,
			"page_world": 128.0,
			"size": 6,
			"levels": 3,
			"requested_levels": 3,
			"resident_pages": 40,
			"effective_texels_per_meter": 1024.0,
			"coarse_texels_per_meter": 2.0,
			"fine_page_world": 0.25,
			"fine_block_size": 256,
			"fine_section_world": 64.0,
			"fine_mip_levels": 9,
			"resolution_levels": resolution_levels,
			"sectors": sectors,
			"fine_cells": [
				Rect2(Vector2(-64.0, -64.0), Vector2.ONE * 64.0),
				Rect2(Vector2(0.0, -64.0), Vector2.ONE * 64.0),
				Rect2(Vector2(-64.0, 0.0), Vector2.ONE * 64.0),
				Rect2(Vector2(0.0, 0.0), Vector2.ONE * 64.0),
			],
			"coarse_pages": coarse_pages,
		}


var _finished := false


func _enter_tree() -> void:
	call_deferred("_run")


func _fail(p_message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("EDITOR_AVT_LAYOUT_PREVIEW: " + p_message)
	get_tree().quit(1)


func _render_case(p_width: int, p_filename: String) -> bool:
	var initial_height := 512
	var viewport := SubViewport.new()
	viewport.name = "AVTLayoutPreviewTestViewport_%d" % p_width
	viewport.size = Vector2i(p_width, initial_height)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	var preview = load("res://addons/feng-idweight-terrain/src/vt_avt_layout_preview.gd").new()
	preview.name = "TerrainAVTLayoutPreview"
	preview.size = Vector2(p_width, initial_height)
	viewport.add_child(preview)
	var expected_height := int(ceil(float(preview.call("_minimum_height_for_width", float(p_width)))))
	viewport.size = Vector2i(p_width, expected_height)
	preview.size = Vector2(p_width, expected_height)

	var terrain := FakeTerrain.new()
	terrain.camera = Camera3D.new()
	preview.set_terrain(terrain)
	preview.call("_refresh_preview")
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var image := viewport.get_texture().get_image()
	if image == null or image.get_width() != p_width or image.get_height() != expected_height:
		_fail("AVT layout Control did not render its expected %dx%d viewport" % [p_width, expected_height])
		return false
	var background := image.get_pixel(2, 2)
	var changed := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			var difference := absf(pixel.r - background.r) + absf(pixel.g - background.g) + absf(pixel.b - background.b)
			if difference > 0.15:
				changed += 1
	if changed < 1000:
		_fail("AVT layout render was effectively empty at %dx%d" % [p_width, expected_height])
		return false
	image.save_png(p_filename)
	viewport.queue_free()
	await get_tree().process_frame
	return true


func _run() -> void:
	if not await _render_case(260, "user://editor_avt_layout_preview_small.png"):
		return
	if not await _render_case(625, "user://editor_avt_layout_preview_wide.png"):
		return
	_finished = true
	print("PASS AVT Inspector layout preview render; screenshots=user://editor_avt_layout_preview_small.png,user://editor_avt_layout_preview_wide.png")
	get_tree().quit()
