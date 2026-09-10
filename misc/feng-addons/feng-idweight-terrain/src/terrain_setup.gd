@tool
extends Node

var plugin: EditorPlugin
var dialog: EditorFileDialog
var target: Terrain3D
var dismissed: Array[int] = []

func _exit_tree() -> void:
	if is_instance_valid(dialog):
		dialog.queue_free()

func request(terrain: Terrain3D, retry: bool = false) -> void:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.data:
		return
	if terrain.data.get_region_count() > 0:
		return
	if not retry and terrain.get_instance_id() in dismissed:
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
				dismissed.append(target.get_instance_id())
			target = null)
		EditorInterface.get_base_control().add_child(dialog)
	dialog.current_dir = "res://"
	dialog.popup_centered_ratio(0.6)

func initialize_directory(directory: String) -> void:
	var terrain := target
	target = null
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.data:
		return
	if terrain.data.get_region_count() > 0:
		return
	terrain.data_directory = directory
	# Selecting an existing terrain folder loads its regions. Do not replace
	# their size, material, or background configuration with new-terrain defaults.
	if terrain.data.get_region_count() > 0:
		EditorInterface.mark_scene_as_unsaved()
		return
	terrain.region_size = 64
	var position := Vector3.ZERO
	var viewport := EditorInterface.get_editor_viewport_3d()
	if is_instance_valid(plugin.viewport):
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
	var location := terrain.data.get_region_location(position)
	var region := terrain.data.add_region_blank(location)
	if region == null:
		push_error("Terrain initialization could not create a region at " + str(location))
		return
	# Only real, editable regions should be visible on a newly initialized terrain.
	terrain.material = terrain.material.duplicate()
	terrain.material.world_background = Terrain3DMaterial.NONE
	terrain.data.save_directory(directory)
	var saved_file := directory.path_join(Terrain3DUtil.location_to_filename(location))
	if not FileAccess.file_exists(saved_file):
		push_error("Terrain region was created but could not be saved to " + saved_file)
	EditorInterface.mark_scene_as_unsaved()
	plugin.asset_dock.update_assets()
