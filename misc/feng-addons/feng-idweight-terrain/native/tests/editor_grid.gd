@tool
extends EditorPlugin

var completed := false
var completed_count := 0
var complete_grid := false

func _enter_tree() -> void:
	call_deferred("run")

func frames(count: int = 1) -> void:
	for i in count:
		await get_tree().process_frame

func require(value: bool, message: String) -> bool:
	if not value:
		push_error("TERRAIN_GRID_REGRESSION: " + message)
		get_tree().quit(1)
	return value

func run() -> void:
	await frames(40)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await frames()
	EditorInterface.open_scene_from_path("res://render/test.tscn")
	await frames(30)
	var scene := EditorInterface.get_edited_scene_root()
	var terrain: Terrain3D = scene.get_node("Terrain3D")
	EditorInterface.get_selection().add_node(terrain)
	EditorInterface.edit_node(terrain)
	await frames(20)
	var menu := EditorInterface.get_base_control().find_child("ManagementMenu", true, false)
	var dock: Node = menu
	while not dock is PanelContainer:
		dock = dock.get_parent()
	var setup: Node = dock.plugin.terrain_setup
	DirAccess.make_dir_recursive_absolute("res://grid_data")
	setup.dialog.dir_selected.emit("res://grid_data")
	setup.dialog.hide()
	if not require(setup.size_dialog.visible, "folder selection must open grid dimensions"): return
	setup.width_spin.value = 20
	setup.depth_spin.value = 20
	if not require(setup.size_summary.text.contains("400 blocks") and setup.size_summary.text.contains("10.24 x 10.24 km"), "20 x 20 preview must show correct metres"): return
	await frames(3)
	if not require(setup.size_dialog.size.y < 600, "grid dialog must fit on screen"): return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://cache/qa")
	setup.size_dialog.get_texture().get_image().save_png("res://cache/qa/terrain-grid-dialog.png")
	setup.width_spin.value = 128
	setup.depth_spin.value = 128
	if not require(setup.size_dialog.get_ok_button().disabled, "over-capacity grids must be rejected before allocation"): return
	setup.width_spin.value = 20
	setup.depth_spin.value = 20
	# Canceling the second step leaves no directory assignment or terrain files.
	setup.size_dialog.canceled.emit()
	setup.size_dialog.hide()
	if not require(terrain.data.get_region_count() == 0 and terrain.data_directory.is_empty() and DirAccess.get_files_at("res://grid_data").is_empty(), "cancel size selection must not create data"): return
	setup.request(terrain, true)
	setup.dialog.dir_selected.emit("res://grid_data")
	setup.dialog.hide()
	# Even a preconfigured empty node must create actual 512 m blocks.
	terrain.vertex_spacing = 2.0
	setup.creation_finished.connect(func(count: int, complete: bool):
		completed_count = count
		complete_grid = complete
		completed = true)
	setup.size_dialog.confirmed.emit()
	setup.size_dialog.hide()
	if not require(setup.creating and setup.progress_dialog.visible, "large creation must expose progress and yield between batches"): return
	for i in 1200:
		if completed: break
		await frames()
	if not require(completed and complete_grid and completed_count == 400, "batch creation did not finish all 400 blocks"): return
	if not require(terrain.region_size == 512 and is_equal_approx(terrain.vertex_spacing, 1.0), "block geometry footprint must be 512 metres"): return
	var locations: Array[Vector2i] = terrain.data.get_region_locations()
	var lo := Vector2i(999, 999)
	var hi := Vector2i(-999, -999)
	for location in locations:
		lo = lo.min(location)
		hi = hi.max(location)
		var path := "res://grid_data".path_join(Terrain3DUtil.location_to_filename(location))
		if not require(FileAccess.file_exists(path), "every block must have a saved region file"): return
	if not require(locations.size() == 400 and hi - lo + Vector2i.ONE == Vector2i(20, 20), "terrain must form a contiguous 20 x 20 rectangle"): return
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if not require(terrain.data.has_region(Vector2i(x, y)), "grid contains a missing block"): return
	print("TERRAIN_GRID_CREATED blocks=400 world=10240x10240 origin=", lo)
	var first_path := "res://grid_data".path_join(Terrain3DUtil.location_to_filename(lo))
	var original_hash := FileAccess.get_sha256(first_path)
	# Release the original live maps before loading the same 400 files again.
	EditorInterface.get_selection().clear()
	EditorInterface.edit_node(scene)
	await frames(3)
	terrain.data_directory = ""
	terrain.queue_free()
	await frames(8)
	var restored := Terrain3D.new()
	restored.name = "RestoredGrid"
	scene.add_child(restored)
	restored.owner = scene
	setup.request(restored, true)
	setup.dialog.dir_selected.emit("res://grid_data")
	setup.dialog.hide()
	if not require(restored.data.get_region_count() == 400 and not setup.size_dialog.visible, "existing grid must load without another creation dialog"): return
	if not require(restored.region_size == 512 and is_equal_approx(restored.vertex_spacing, 1.0) and FileAccess.get_sha256(first_path) == original_hash, "saved grid geometry and data must survive reload unchanged"): return
	# Stopping an in-flight job preserves the completed batch and its saved files.
	var stopped := Terrain3D.new()
	scene.add_child(stopped)
	DirAccess.make_dir_recursive_absolute("res://stopped_data")
	stopped.data_directory = "res://stopped_data"
	setup.request(stopped, true)
	setup.width_spin.value = 2
	setup.depth_spin.value = 4
	completed = false
	setup.size_dialog.confirmed.emit()
	setup.progress_dialog.confirmed.emit()
	for i in 60:
		if completed: break
		await frames()
	if not require(completed and not complete_grid and completed_count == 4 and stopped.data.get_region_count() == 4, "stopping creation must keep the completed four-block batch"): return
	for location in stopped.data.get_region_locations():
		if not require(FileAccess.file_exists("res://stopped_data".path_join(Terrain3DUtil.location_to_filename(location))), "stopped job must preserve saved blocks"): return
	stopped.queue_free()
	await frames(3)
	EditorInterface.save_scene()
	await frames(10)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await frames()
	print("PASS 20x20 terrain grid creation, cancellation, limits and reload")
	EditorInterface.get_base_control().get_parent().call_deferred("notification", NOTIFICATION_WM_CLOSE_REQUEST)
