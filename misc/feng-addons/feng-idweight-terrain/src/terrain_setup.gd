@tool
extends Node

signal creation_finished(created: int, complete: bool)

const BLOCK_METRES := 512
const CREATE_BATCH_SIZE := 4

var plugin: EditorPlugin
var dialog: EditorFileDialog
var size_dialog: ConfirmationDialog
var width_spin: SpinBox
var depth_spin: SpinBox
var size_summary: Label
var size_error: Label
var progress_dialog: AcceptDialog
var progress_bar: ProgressBar
var progress_label: Label
var target: Terrain3D
var dismissed: Array[WeakRef] = []
var creating := false
var _cancel_requested := false
var _pending_directory := ""
var _region_limit := 1024

func _exit_tree() -> void:
	_cancel_requested = true
	target = null
	dismissed.clear()
	for window in [dialog, size_dialog, progress_dialog]:
		if is_instance_valid(window):
			window.queue_free()

func request(terrain: Terrain3D, retry: bool = false) -> void:
	if creating or (is_instance_valid(size_dialog) and size_dialog.visible):
		return
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.data:
		return
	if terrain.data.get_region_count() > 0:
		return
	if not retry and _is_dismissed(terrain):
		return
	if is_instance_valid(dialog) and dialog.visible:
		return
	target = terrain
	if not terrain.data_directory.is_empty():
		initialize_directory(terrain.data_directory)
		return
	if not is_instance_valid(dialog):
		dialog = EditorFileDialog.new()
		dialog.title = "Choose Terrain Data Folder"
		dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
		dialog.access = EditorFileDialog.ACCESS_RESOURCES
		dialog.dir_selected.connect(initialize_directory)
		dialog.canceled.connect(func():
			if is_instance_valid(target):
				_remember_dismissed(target)
			target = null)
		EditorInterface.get_base_control().add_child(dialog)
	dialog.current_dir = "res://"
	dialog.popup_centered_ratio(0.6)

func initialize_directory(directory: String) -> void:
	if is_instance_valid(dialog):
		dialog.hide()
	var terrain := target
	target = null
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.data:
		return
	if terrain.data.get_region_count() > 0:
		return
	var previous_directory := terrain.data_directory
	terrain.data_directory = directory
	# Selecting an existing terrain folder loads its regions. Do not replace
	# their size, material, or background configuration with new-terrain defaults.
	if terrain.data.get_region_count() > 0:
		EditorInterface.mark_scene_as_unsaved()
		return
	# Canceling the size step must leave the empty node's directory unchanged.
	terrain.data_directory = previous_directory
	target = terrain
	_pending_directory = directory
	_region_limit = mini(1024, int(terrain.material.max_regions))
	_build_size_dialog()
	_update_size_summary()
	size_dialog.popup_centered(Vector2i(480, 260))

func _build_size_dialog() -> void:
	if is_instance_valid(size_dialog):
		return
	size_dialog = ConfirmationDialog.new()
	size_dialog.name = "TerrainGridSetup"
	size_dialog.title = "Create Terrain Grid"
	size_dialog.ok_button_text = "Create Terrain"
	size_dialog.confirmed.connect(_create_grid)
	size_dialog.canceled.connect(func():
		if is_instance_valid(target):
			_remember_dismissed(target)
		target = null
		_pending_directory = "")
	var body := VBoxContainer.new()
	body.custom_minimum_size.x = 440
	body.add_theme_constant_override("separation", 8)
	size_dialog.add_child(body)
	var grid := GridContainer.new()
	grid.columns = 2
	body.add_child(grid)
	for axis in ["Width (X blocks)", "Depth (Z blocks)"]:
		var label := Label.new()
		label.text = axis
		grid.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = 1
		spin.max_value = Terrain3DData.REGION_MAP_SIZE
		spin.step = 1
		spin.value = 1
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.value_changed.connect(_update_size_summary.unbind(1))
		grid.add_child(spin)
		if width_spin == null:
			width_spin = spin
			spin.name = "TerrainGridWidth"
		else:
			depth_spin = spin
			spin.name = "TerrainGridDepth"
	size_summary = Label.new()
	size_summary.name = "TerrainGridSummary"
	size_summary.clip_text = true
	size_summary.custom_minimum_size.x = 440
	body.add_child(size_summary)
	size_error = Label.new()
	body.add_child(size_error)
	EditorInterface.get_base_control().add_child(size_dialog)


func _is_dismissed(p_terrain: Terrain3D) -> bool:
	var index := dismissed.size() - 1
	var found := false
	while index >= 0:
		var candidate = dismissed[index].get_ref()
		if not is_instance_valid(candidate):
			dismissed.remove_at(index)
		elif candidate == p_terrain:
			found = true
		index -= 1
	return found


func _remember_dismissed(p_terrain: Terrain3D) -> void:
	if not is_instance_valid(p_terrain) or _is_dismissed(p_terrain):
		return
	dismissed.append(weakref(p_terrain))

func _update_size_summary() -> void:
	var width := int(width_spin.value)
	var depth := int(depth_spin.value)
	var total := width * depth
	size_summary.text = "%d x %d blocks = %d blocks\nEach block: 512 x 512 m\nTotal: %d x %d m (%.2f x %.2f km)\nCentered on the editor view.\nAligned to the terrain grid.\nFolder: %s" % [
		width, depth, total, width * BLOCK_METRES, depth * BLOCK_METRES,
		width * BLOCK_METRES / 1000.0, depth * BLOCK_METRES / 1000.0, _pending_directory]
	size_summary.tooltip_text = _pending_directory
	var valid := total <= _region_limit
	size_error.text = "" if valid else "Limit: %d loaded blocks.\nReduce Width or Depth." % _region_limit
	size_dialog.get_ok_button().disabled = not valid

func _focus_location(terrain: Terrain3D) -> Vector2i:
	var position := Vector3.ZERO
	var viewport := EditorInterface.get_editor_viewport_3d()
	if is_instance_valid(plugin) and is_instance_valid(plugin.viewport):
		viewport = plugin.viewport
	var camera := viewport.get_camera_3d()
	if camera:
		var center := Vector2(viewport.size) * 0.5
		var origin := camera.project_ray_origin(center)
		var direction := camera.project_ray_normal(center)
		var intersection = Plane(Vector3.UP, 0.0).intersects_ray(origin, direction)
		if intersection != null and origin.distance_to(intersection) < 2048.0:
			position = intersection
		else:
			position = origin + direction * 32.0
			position.y = 0.0
	return terrain.data.get_region_location(position)

func _build_progress_dialog() -> void:
	if is_instance_valid(progress_dialog):
		return
	progress_dialog = AcceptDialog.new()
	progress_dialog.name = "TerrainGridProgress"
	progress_dialog.title = "Creating Terrain"
	progress_dialog.ok_button_text = "Stop (keep created blocks)"
	progress_dialog.confirmed.connect(func(): _cancel_requested = true)
	progress_dialog.canceled.connect(func(): _cancel_requested = true)
	var body := VBoxContainer.new()
	progress_dialog.add_child(body)
	progress_label = Label.new()
	body.add_child(progress_label)
	progress_bar = ProgressBar.new()
	progress_bar.custom_minimum_size.x = 400
	body.add_child(progress_bar)
	EditorInterface.get_base_control().add_child(progress_dialog)

func _create_grid() -> void:
	var terrain := target
	var directory := _pending_directory
	if creating or not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.data:
		return
	var width := int(width_spin.value)
	var depth := int(depth_spin.value)
	var total := width * depth
	if width < 1 or depth < 1 or width > Terrain3DData.REGION_MAP_SIZE or depth > Terrain3DData.REGION_MAP_SIZE or total > _region_limit:
		return
	if terrain.data.get_region_count() > 0:
		return
	size_dialog.hide()
	target = null
	_pending_directory = ""
	# Loading is checked again in case the folder changed while the size dialog
	# was open. Existing region files never get overwritten with a blank grid.
	terrain.data_directory = directory
	if terrain.data.get_region_count() > 0:
		EditorInterface.mark_scene_as_unsaved()
		return
	terrain.region_size = BLOCK_METRES
	terrain.vertex_spacing = 1.0
	var center := _focus_location(terrain)
	var half := Terrain3DData.REGION_MAP_SIZE / 2
	var origin := center - Vector2i(width / 2, depth / 2)
	origin.x = clampi(origin.x, -half, half - width)
	origin.y = clampi(origin.y, -half, half - depth)
	for z in depth:
		for x in width:
			var path := directory.path_join(Terrain3DUtil.location_to_filename(origin + Vector2i(x, z)))
			if FileAccess.file_exists(path):
				push_error("Terrain creation stopped: a region file already exists at " + path)
				return
	# Only real, editable regions should be visible on a newly initialized terrain.
	terrain.material = terrain.material.duplicate()
	terrain.material.world_background = Terrain3DMaterial.NONE
	creating = true
	_cancel_requested = false
	_build_progress_dialog()
	progress_bar.max_value = total
	progress_bar.value = 0
	progress_label.text = "Creating 0 / %d blocks" % total
	progress_dialog.popup_centered()
	var physics_was_enabled := terrain.is_physics_processing()
	terrain.set_physics_process(false)
	var created := 0
	var saved := 0
	for index in total:
		if _cancel_requested or not is_instance_valid(terrain) or not terrain.is_inside_tree():
			break
		var location := origin + Vector2i(index % width, index / width)
		# Bulk addition defers the texture-array upload until all blocks are ready.
		var region := terrain.data.add_region_blank(location, false)
		if region == null:
			push_error("Terrain creation failed at " + str(location))
			break
		created += 1
		var path := directory.path_join(Terrain3DUtil.location_to_filename(location))
		if region.save(path, terrain.save_16_bit) != OK:
			push_error("Terrain block could not be saved to " + path)
			break
		saved += 1
		progress_bar.value = created
		progress_label.text = "Created and saved %d / %d blocks" % [created, total]
		if created % CREATE_BATCH_SIZE == 0:
			await get_tree().process_frame
	if is_instance_valid(terrain) and terrain.is_inside_tree():
		terrain.data.update_maps()
		terrain.set_physics_process(physics_was_enabled)
		if is_instance_valid(plugin) and is_instance_valid(plugin.asset_dock):
			plugin.asset_dock.update_assets()
	creating = false
	if is_instance_valid(progress_dialog):
		progress_dialog.hide()
	EditorInterface.mark_scene_as_unsaved()
	var filesystem := EditorInterface.get_resource_filesystem()
	if not filesystem.is_scanning():
		filesystem.scan()
	creation_finished.emit(created, saved == total)
