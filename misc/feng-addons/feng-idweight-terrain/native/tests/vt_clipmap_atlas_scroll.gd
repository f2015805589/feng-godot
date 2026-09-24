# Graphical stress probe; the runner defaults to D3D12 and 1920x1080.
# The target advances by one Atlas block per update while the Atlas is limited to one produced block
# per frame. Final Atlas and Direct height images use the same settled camera pose.
extends "res://vt_scene_base.gd"

const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2
const ATLAS := 1
const BLOCK_SIZE := 64
const BASE_WORLD := 64.0
const REGION_SIZE := 64
const START_FOCUS := Vector2(128.0, 128.0)
const SETTLE_CAP := 1024
const VISIBLE_CELL_COUNT := 9

var scene: Node3D
var target: Node3D
var output_dir := "user://"
var painter: Terrain3DEditor
var brush: Image
var brush_texture: ImageTexture
var move_count := 12
var move_step := 64.0
var expect_zero_mismatch := false
var manual_update_tick := 0
var visible_area_ready_tick := -1


func _initialize() -> void:
	call_deferred("run")


func settings() -> Dictionary:
	return terrain.get_vt_settings()


func height_entry() -> Dictionary:
	return (settings().get("clipmap", {}) as Dictionary).get("height", {})


func atlas_impl(p_entry: Dictionary) -> Dictionary:
	return p_entry.get("layout", {})


func cells(p_entry: Dictionary) -> Array:
	return (atlas_impl(p_entry).get("layout", {}) as Dictionary).get("cells", [])


func state_reading() -> Dictionary:
	var entry := height_entry()
	var atlas := atlas_impl(entry)
	var table := cells(entry)
	var layout_report: Dictionary = atlas.get("layout", {})
	var slots: Array = layout_report.get("rects", [])
	var current := 0
	var raw_current := 0
	var mismatches := 0
	var details := PackedStringArray()
	var actual_slot_coordinates := false
	if not slots.is_empty():
		var first_slot: Dictionary = slots[0]
		actual_slot_coordinates = first_slot.has("block")
	for value: Variant in table:
		var cell: Dictionary = value
		if not bool(cell.get("current", false)):
			continue
		raw_current += 1
		var want: Vector2i = cell.get("want", Vector2i.ZERO)
		var slot_index := int(cell.get("slot", -1))
		var slot: Dictionary = slots[slot_index] if slot_index >= 0 and slot_index < slots.size() else {}
		# Newer Atlas state reports the slot's own coordinate. The preserved before.dll predates that
		# field; there, `cell.block` is the published have_x/have_y value written from the same job.
		var slot_block: Vector2i = slot.get("block", cell.get("block", Vector2i.ZERO))
		var slot_valid := slot_index >= 0 and slot_index < slots.size()
		var slot_resident := slot_valid and bool(slot.get("resident", false))
		var slot_ring := int(slot.get("ring", cell.get("ring", -1)))
		if not slot_valid or not slot_resident \
				or slot_ring != int(cell.get("ring", -1)) or want != slot_block:
			mismatches += 1
			details.append("ring=%d cell=(%d,%d) slot=%d want=(%d,%d) block=(%d,%d)" % [
				int(cell.get("ring", -1)), int(cell.get("gx", 0)), int(cell.get("gy", 0)),
				int(cell.get("slot", -1)), want.x, want.y, slot_block.x, slot_block.y])
		else:
			current += 1
	return {
		"configured": bool(entry.get("configured", false)),
		"pending_jobs": int(entry.get("pending_jobs", -1)),
		"current": current,
		"raw_current": raw_current,
		"cells": table.size(),
		"mismatches": mismatches,
		"details": details,
		"actual_slot_coordinates": actual_slot_coordinates,
		"scroll_events": int(atlas.get("scroll_events", -1)),
		"loaded": int(atlas.get("last_scroll_loaded", -1)),
		"retained": int(atlas.get("last_scroll_retained", -1)),
	}


func state_line(label: String, frame: int, state: Dictionary) -> String:
	var slot_source := "actual" if bool(state.get("actual_slot_coordinates", false)) else "cell-have-fallback"
	return "CLIPMAP_ATLAS_SCROLL_STATE label=%s frame=%d configured=%s scroll_events=%d loaded=%d retained=%d current_match=%d/%d raw_current=%d pending_jobs=%d current_want_slot_block_mismatches=%d slot_blocks=%s visible_area_ready_tick=%d" % [
		label, frame, str(state.get("configured", false)), int(state.get("scroll_events", -1)),
		int(state.get("loaded", -1)), int(state.get("retained", -1)),
		int(state.get("current", 0)), int(state.get("cells", 0)),
		int(state.get("raw_current", 0)), int(state.get("pending_jobs", -1)),
		int(state.get("mismatches", -1)), slot_source, visible_area_ready_tick]


func record_visible_ready(state: Dictionary) -> void:
	if visible_area_ready_tick < 0 \
			and int(state.get("current", 0)) >= VISIBLE_CELL_COUNT:
		visible_area_ready_tick = manual_update_tick


func settle(frames: int) -> void:
	for _i in frames:
		await process_frame


func frame_image() -> Image:
	for _i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func differing(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				count += 1
	return count


func pixel_delta(a: Image, b: Image) -> Vector3:
	var worst := 0.0
	var total := 0.0
	var samples := 0.0
	var strong := 0
	for y in a.get_height():
		for x in a.get_width():
			var left := a.get_pixel(x, y)
			var right := b.get_pixel(x, y)
			var pixel_worst := 0.0
			for channel in 4:
				var delta: float = absf(left[channel] - right[channel])
				pixel_worst = maxf(pixel_worst, delta)
				total += delta
				samples += 1.0
			worst = maxf(worst, pixel_worst)
			if pixel_worst > 0.05:
				strong += 1
	return Vector3(worst, total / maxf(samples, 1.0), float(strong))


func save_image(image: Image, name: String) -> void:
	if output_dir != "user://":
		image.save_png(output_dir.path_join(name))


func capture_atlas_frame(name: String) -> void:
	var image := await frame_image()
	save_image(image, name)
	require(image.get_width() == 1920 and image.get_height() == 1080,
			"runner captures 1920x1080 at %s, got %dx%d" % [name, image.get_width(), image.get_height()])


func save_text(value: String, name: String) -> void:
	if output_dir != "user://":
		var file := FileAccess.open(output_dir.path_join(name), FileAccess.WRITE)
		if file != null:
			file.store_string(value)


func create_undo_action(_name: String) -> void:
	pass


func add_undo_method(_action: Callable) -> void:
	pass


func add_do_method(_action: Callable) -> void:
	pass


func commit_action(_execute: bool) -> void:
	pass


func solid_texture(size: int, color: Color) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func paint_material(center: Vector3, asset_id: int) -> void:
	painter.set_tool(Terrain3DEditor.TEXTURE)
	painter.set_operation(Terrain3DEditor.REPLACE)
	painter.set_brush_data({
		"brush": [brush, brush_texture],
		"size": 16.5, "strength": 100.0, "mouse_pressure": 1.0,
		"asset_id": asset_id, "pair_overlay_id": asset_id, "pair_background_id": asset_id,
		"pair_mode": 0, "pair_weight_level": 8,
	})
	painter.start_operation(center)
	painter.operate(center, 0.0)
	painter.stop_operation()


func height_profile(x: float, z: float) -> float:
	return 12.0 * sin(x * 0.027) * cos(z * 0.035) + 4.0 * sin(x * 0.061 + z * 0.043)


func set_focus(focus: Vector2) -> void:
	target.position = Vector3(focus.x, 0.0, focus.y)
	camera.position = target.position + Vector3(0.0, 180.0, 180.0)
	camera.look_at(target.position, Vector3.UP)


func make_scene() -> void:
	scene = Node3D.new()
	root.add_child(scene)

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 96.0
	camera.near = 0.1
	camera.far = 1500.0
	camera.current = true
	root.add_child(camera)

	target = Node3D.new()
	root.add_child(target)
	set_focus(START_FOCUS)

	terrain = Terrain3D.new()
	terrain.free_editor_textures = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.vt_clipmap_implementation = ATLAS
	terrain.vt_clipmap_detail_enabled = false
	terrain.vt_clipmap_size = BLOCK_SIZE
	terrain.vt_clipmap_levels = 1
	terrain.vt_clipmap_base_world = BASE_WORLD
	terrain.vt_clipmap_budget_texels = BLOCK_SIZE * BLOCK_SIZE
	terrain.vt_clipmap_blocks_per_frame = 1
	terrain.set_camera(camera)
	terrain.set_clipmap_target(target)
	terrain.region_size = REGION_SIZE
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = solid_texture(32, Color(0.8, 0.15, 0.1) if id == 0 else Color(0.1, 0.7, 0.2))
		asset.normal_texture = solid_texture(32, Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(id, asset)
	scene.add_child(terrain)
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)

	for region_x in range(16):
		for region_z in range(4):
			terrain.data.add_region_blank(Vector2i(region_x, region_z))
			for z in REGION_SIZE:
				for x in REGION_SIZE:
					var world_x := float(region_x * REGION_SIZE + x)
					var world_z := float(region_z * REGION_SIZE + z)
					terrain.data.set_height(Vector3(world_x, 0.0, world_z), height_profile(world_x, world_z))
	terrain.data.update_maps()
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)
	brush_texture = ImageTexture.create_from_image(brush)
	# A high-contrast checker in the final camera footprint makes a wrong height/slot address visible
	# as a displaced shaded surface instead of a data-only mismatch.
	for world_z in range(48, 209, 16):
		for world_x in range(64, 960, 16):
			paint_material(Vector3(float(world_x) + 8.0, 0.0, float(world_z) + 8.0),
					int(world_x / 16 + world_z / 16) % 2)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48.0, -30.0, 0.0)
	scene.add_child(light)
	# Let Terrain3D build its render meshes while its native physics tick is active, with VT delivery
	# still Direct. Then turn on Atlas and disable the automatic tick before starting the measured run.
	await settle(20)
	terrain.vt_clipmap_implementation = ATLAS
	terrain.vt_delivery_near_height = CLIPMAP
	terrain.set_process(false)
	terrain.set_physics_process(false)
	await settle(2)


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	move_count = maxi(1, int(OS.get_environment("CLIPMAP_ATLAS_SCROLL_MOVES")))
	move_step = maxf(0.001, float(OS.get_environment("CLIPMAP_ATLAS_SCROLL_MOVE_STEP")))
	expect_zero_mismatch = OS.get_environment("CLIPMAP_ATLAS_SCROLL_EXPECT_ZERO") == "1"
	await make_scene()

	var viewport_size := root.get_visible_rect().size
	var final_focus := Vector2(START_FOCUS.x + move_step * move_count, START_FOCUS.y)
	var trace := PackedStringArray()
	trace.append("CLIPMAP_ATLAS_SCROLL_CONFIG label=%s resolution=%dx%d initial_focus=%s final_focus=%s moves=%d move_step=%.3f base_world=%.3f block_size=%d camera_size=%.3f camera_offset=(0,180,180)" % [
		OS.get_environment("CLIPMAP_ATLAS_SCROLL_LABEL"), int(viewport_size.x), int(viewport_size.y),
		str(START_FOCUS), str(final_focus), move_count, move_step, BASE_WORLD, BLOCK_SIZE, camera.size])
	print(trace[-1])

	# Fully seed the original focus so the before/mid/final frames show actual terrain tiles.
	# Reset the measured tick count afterward; D starts at the first moved focus.
	terrain.call("debug_update_vt_clipmap", HEIGHT)
	await process_frame
	var initial := state_reading()
	for _seed_frame in SETTLE_CAP:
		if int(initial.get("pending_jobs", 1)) == 0 \
				and int(initial.get("raw_current", 0)) == int(initial.get("cells", 0)):
			break
		terrain.call("debug_update_vt_clipmap", HEIGHT)
		await process_frame
		initial = state_reading()
	var initial_row := state_line("seeded", 0, initial)
	trace.append(initial_row)
	print(initial_row)
	await capture_atlas_frame("height-atlas-before-scroll.png")
	# Readiness is measured from the first moved focus, not the seed update above.
	manual_update_tick = 0
	visible_area_ready_tick = -1
	for i in move_count:
		set_focus(Vector2(START_FOCUS.x + move_step * float(i + 1), START_FOCUS.y))
		terrain.call("debug_update_vt_clipmap", HEIGHT)
		manual_update_tick += 1
		var reading := state_reading()
		record_visible_ready(reading)
		var row := state_line("scroll", i + 1, reading)
		trace.append(row)
		print(row)
		for detail: String in reading.get("details", PackedStringArray()):
			print("CLIPMAP_ATLAS_SCROLL_MISMATCH frame=%d %s" % [i + 1, detail])
		if i + 1 == maxi(1, int(ceil(float(move_count) / 2.0))):
			await capture_atlas_frame("height-atlas-mid-scroll.png")
		await process_frame

	# Both saved frames use the same final focus, camera offset, projection and viewport.
	set_focus(final_focus)
	var settled := state_reading()
	for frame in SETTLE_CAP:
		if int(settled.get("pending_jobs", 1)) == 0 \
				and int(settled.get("raw_current", 0)) == int(settled.get("cells", 0)):
			break
		terrain.call("debug_update_vt_clipmap", HEIGHT)
		manual_update_tick += 1
		await process_frame
		settled = state_reading()
		record_visible_ready(settled)
		if frame % 32 == 31:
			var settle_row := state_line("settle", frame + 1, settled)
			trace.append(settle_row)
			print(settle_row)
	var final_row := state_line("final", move_count, settled)
	trace.append(final_row)
	print(final_row)
	require(int(settled.get("pending_jobs", -1)) == 0, "the final Atlas queue drains")
	require(int(settled.get("raw_current", 0)) == int(settled.get("cells", -1)), "all Atlas cells have landed at the final focus")
	if expect_zero_mismatch:
		require(int(settled.get("mismatches", -1)) == 0,
				"all current Atlas slot blocks match their wanted coordinates: %s" % str(settled.get("details", [])))
		require(visible_area_ready_tick >= 0, "the entire rendered area reaches matching current blocks")
	for detail: String in settled.get("details", PackedStringArray()):
		trace.append("FINAL_MISMATCH " + detail)

	var all_cells := cells(height_entry())
	var atlas_image := await frame_image()
	save_image(atlas_image, "height-atlas-final.png")
	require(atlas_image.get_width() == 1920 and atlas_image.get_height() == 1080,
			"runner captures 1920x1080, got %dx%d" % [atlas_image.get_width(), atlas_image.get_height()])

	# Direct region height is the correctness reference at the exact same camera/world pose.
	terrain.vt_delivery_near_height = DIRECT
	await settle(8)
	var direct_image := await frame_image()
	save_image(direct_image, "height-direct-reference.png")
	var atlas_delta := pixel_delta(atlas_image, direct_image)
	var atlas_diff := differing(atlas_image, direct_image)
	var pixel_row := "CLIPMAP_ATLAS_SCROLL_PIXEL atlas_vs_direct_differing=%d max=%.6f mean=%.6f strong=%d" % [
		atlas_diff, atlas_delta.x, atlas_delta.y, int(atlas_delta.z)]
	trace.append(pixel_row)
	print(pixel_row)
	save_text("\n".join(trace) + "\n\nFINAL_CELLS\n" + JSON.stringify(all_cells, "  ") + "\n",
		"height-atlas-final-state.txt")

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
	for frame in 5:
		await process_frame
	if failed:
		print("REGRESSION: clipmap atlas scroll probe")
		quit(1)
		return
	print("PASS clipmap atlas scroll probe")
	quit(0)
