@tool
extends EditorPlugin

## Focused graphical regression for the native Surface VT / SVT Inspector action.

var _finished: bool = false


func _enter_tree() -> void:
	call_deferred("_run")


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("EDITOR_SVT_INSPECTOR_REGRESSION: " + message)
	get_tree().quit(1)


func _require(condition: bool, message: String) -> bool:
	if condition:
		return true
	_fail(message)
	return false


func _wait_frames(count: int = 1) -> void:
	for _i in count:
		await get_tree().process_frame


func _has_property(target: Object, property_name: StringName) -> bool:
	for property_info: Dictionary in target.get_property_list():
		if StringName(property_info.get("name", "")) == property_name:
			return true
	return false


func _find_ancestor_class(node: Node, p_class: String) -> Control:
	var parent := node.get_parent()
	while parent:
		if parent.get_class() == p_class:
			return parent as Control
		parent = parent.get_parent()
	return null


func _solid_texture(size: int, color: Color) -> Texture2D:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _unfold_ancestors(node: Node) -> void:
	var sections: Array[Control] = []
	var parent := node.get_parent()
	while parent:
		if parent.get_class() == "EditorInspectorSection":
			sections.push_front(parent as Control)
		parent = parent.get_parent()
	for section: Control in sections:
		section.call("unfold")


func _run() -> void:
	await _wait_frames(40)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame

	var scene_root := Node3D.new()
	scene_root.name = "TerrainSVTInspectorTest"
	var terrain := Terrain3D.new()
	if not _require(_has_property(terrain, &"surface_svt_auto_bake"),
			"Terrain3D did not expose surface_svt_auto_bake"):
		return
	if not _require(bool(terrain.get(&"surface_svt_auto_bake")),
			"SVT Auto Bake should default to enabled"):
		return
	# This focused test invokes the full-bake action directly, so keep scene
	# construction from scheduling its own incremental bake.
	terrain.set(&"surface_svt_auto_bake", false)
	terrain.name = "Terrain3D"
	terrain.region_size = 64
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 64
	terrain.vt_pages_per_update = 4
	terrain.surface_svt_page_world = 64
	terrain.surface_svt_max_mip = 1
	DirAccess.make_dir_recursive_absolute("user://editor-svt-inspector")
	terrain.data_directory = "user://editor-svt-inspector"
	terrain.assets = Terrain3DAssets.new()
	for asset_id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.id = asset_id
		asset.albedo_texture = _solid_texture(32, Color("e34b4b") if asset_id == 0 else Color("4bd36a"))
		asset.normal_texture = _solid_texture(32, Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(asset_id, asset)
	terrain.assets.set_mesh_asset(0, Terrain3DMeshAsset.new())
	scene_root.add_child(terrain)
	terrain.owner = scene_root
	var camera := Camera3D.new()
	camera.name = "TerrainSVTInspectorCamera"
	camera.position = Vector3(64.0, 160.0, 32.0)
	camera.rotation_degrees.x = -90.0
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 160.0
	camera.current = true
	scene_root.add_child(camera)
	EditorInterface.add_root_node(scene_root)
	await _wait_frames(40)
	terrain.set_camera(camera)
	terrain.data.add_region_blank(Vector2i.ZERO)
	terrain.data.add_region_blank(Vector2i(1, 0))
	EditorInterface.get_selection().add_node(terrain)
	await _wait_frames(40)

	var inspector := EditorInterface.get_inspector()
	if not _require(inspector.get_edited_object() == terrain,
			"selecting Terrain3D did not populate the real Inspector"):
		return
	var controls: Control = null
	var bake_button: Button = null
	var progress_label: Label = null
	for _i in 60:
		controls = inspector.find_child("TerrainSVTBakeControls", true, false) as Control
		bake_button = inspector.find_child("TerrainSVTBakeAllButton", true, false) as Button
		progress_label = inspector.find_child("TerrainSVTBakeProgress", true, false) as Label
		if controls != null and bake_button != null and progress_label != null:
			break
		await get_tree().process_frame
	if not _require(controls != null and bake_button != null and progress_label != null and
			bool(controls.get_meta("native_svt_group", false)),
			"native SVT Inspector subgroup did not add its full-bake controls"):
		return
	var svt_section := _find_ancestor_class(controls, "EditorInspectorSection")
	if not _require(svt_section != null,
			"Bake All controls are not inside an EditorInspectorSection"):
		return
	_unfold_ancestors(controls)
	await _wait_frames(2)
	if not _require(bake_button.is_visible_in_tree(),
			"Bake All SVT Cells is hidden when the native SVT section is unfolded"):
		return
	if not _require(progress_label.text.find("Auto Bake off") >= 0,
			"Inspector progress did not reflect the disabled Auto Bake setting"):
		return

	var previous_generation := int(terrain.get_vt_settings().get("bake_generation", 0))
	bake_button.pressed.emit()
	var queued_settings: Dictionary = terrain.get_vt_settings()
	if not _require(int(queued_settings.get("bake_generation", 0)) > previous_generation and
			int(queued_settings.get("bake_total", 0)) >= 2 and
			progress_label.text.find("Manual full SVT bake queued") >= 0,
			"Inspector Bake All button did not invoke Terrain3D.bake_svt()"):
		return

	for _frame in 900:
		await get_tree().process_frame
		if int(terrain.get_vt_settings().get("bake_pending", 1)) == 0:
			break
	for _frame in 120:
		if progress_label.text.find("Manual full SVT bake complete") >= 0:
			break
		await get_tree().process_frame
	var completed: Dictionary = terrain.get_vt_settings()
	if not _require(int(completed.get("bake_pending", 1)) == 0 and
			progress_label.text.find("Manual full SVT bake complete") >= 0 and
			terrain.get_svt_baked_pages().size() >= 2,
			"Inspector progress did not report a completed full SVT bake"):
		return
	if not _require(inspector.find_child("TerrainVTPageOpenOverview", true, false) != null,
			"adding Bake All removed the existing native VT Page entry"):
		return

	# Save the fixture scene and use the normal editor close path. SceneTree.quit
	# bypasses the editor's resource cleanup and produces shutdown errors here.
	EditorInterface.save_scene_as("res://svt_inspector_test.tscn", false)
	await _wait_frames(8)
	if not _require(FileAccess.file_exists("res://svt_inspector_test.tscn"),
			"focused test scene did not save before editor shutdown"):
		return
	print("PASS native SVT Inspector full-bake action and progress")
	_finished = true
	EditorInterface.get_base_control().get_parent().call_deferred("notification", NOTIFICATION_WM_CLOSE_REQUEST)
