@tool
extends EditorPlugin
var dock: Control
var terrain: Terrain3D
func _enter_tree():
	call_deferred("run")
func frames(n=1):
	for i in n:
		await get_tree().process_frame
func fail(message):
	push_error(message)
	get_tree().quit(1)
func motion(point):
	var e=InputEventMouseMotion.new()
	e.position=point
	Input.parse_input_event(e)
	await frames(3)
func click(point, button=MOUSE_BUTTON_LEFT):
	await motion(point)
	for down in [true,false]:
		var e=InputEventMouseButton.new()
		e.position=point
		e.button_index=button
		e.pressed=down
		Input.parse_input_event(e)
		await frames(3)
func run():
	await frames(40)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await frames()
	EditorInterface.open_scene_from_path("res://render/test.tscn")
	await frames(40)
	var root=EditorInterface.get_edited_scene_root()
	terrain=root.get_node("Terrain3D")
	if terrain.assets.get_texture_count() < 2:
		for id in 2:
			var asset = Terrain3DTextureAsset.new()
			asset.id = id
			var image = Image.create(16,16,false,Image.FORMAT_RGBA8)
			image.fill(Color.RED if id == 0 else Color.GREEN)
			asset.albedo_texture = ImageTexture.create_from_image(image)
			terrain.assets.set_texture_asset(id,asset)
	if terrain.assets.get_mesh_count() == 0:
		var asset = Terrain3DMeshAsset.new()
		asset.generated_type = 1
		terrain.assets.set_mesh_asset(0,asset)
	terrain.assets.get_mesh_asset(0).density = 10.0
	EditorInterface.get_selection().add_node(terrain)
	EditorInterface.edit_node(terrain)
	EditorInterface.set_main_screen_editor("3D")
	await frames(20)
	print("USER_SCENE regions=",terrain.data.get_region_count()," directory=",terrain.data_directory," background=",terrain.material.world_background)
	var menu=EditorInterface.get_base_control().find_child("ManagementMenu",true,false)
	dock=menu.get_parent()
	while not dock is PanelContainer:
		dock=dock.get_parent()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(root)
	EditorInterface.edit_node(root)
	await frames(5)
	if not dock.plugin.terrain_setup.dialog.visible:
		fail("new terrain did not request a data folder")
		return
	DirAccess.make_dir_recursive_absolute("res://terrain_data")
	dock.plugin.terrain_setup.dialog.dir_selected.emit("res://terrain_data")
	dock.plugin.terrain_setup.dialog.hide()
	if not dock.plugin.terrain_setup.size_dialog.visible:
		fail("new terrain did not offer grid dimensions")
		return
	dock.plugin.terrain_setup.size_dialog.confirmed.emit()
	dock.plugin.terrain_setup.size_dialog.hide()
	await frames(20)
	print("INITIALIZED regions=",terrain.data.get_region_count()," size=",terrain.region_size," background=",terrain.material.world_background)
	if terrain.data.get_region_count()!=1 or terrain.region_size!=512 or terrain.material.world_background!=0:
		fail("initialization failed")
		return
	var region_world := float(terrain.region_size) * terrain.vertex_spacing
	var entry=dock.texture_list.entries[1]
	await click(entry.get_global_rect().position+entry.size*Vector2(0.5,0.65))
	entry=dock.texture_list.entries[0]
	await click(entry.get_global_rect().position+entry.size*Vector2(0.5,0.65),MOUSE_BUTTON_RIGHT)
	var vp=EditorInterface.get_editor_viewport_3d()
	var container=vp.get_parent()
	var initial_loc = terrain.data.get_region_locations()[0]
	var initial_cam = vp.get_camera_3d()
	var center = Vector2(vp.size) * 0.5
	var initial_hit = Plane(Vector3.UP,0).intersects_ray(initial_cam.project_ray_origin(center),initial_cam.project_ray_normal(center))
	initial_hit.x = clampf(initial_hit.x, initial_loc.x * region_world + 0.5, initial_loc.x * region_world + region_world - 0.5)
	initial_hit.z = clampf(initial_hit.z, initial_loc.y * region_world + 0.5, initial_loc.y * region_world + region_world - 0.5)
	var point=container.get_global_rect().position + initial_cam.unproject_position(initial_hit)
	await motion(point)
	await click(point)
	await frames(5)
	var painted=0
	for image in terrain.data.get_surface_maps():
		for y in image.get_height():
			for x in image.get_width():
				if roundi(image.get_pixel(x,y).r*65535)>0:
					painted+=1
	print("PAINTED=",painted," context=",dock.plugin.terrain," hit=",dock.plugin.mouse_global_position," tool=",dock.plugin.editor.get_tool())
	if painted==0:
		fail("Actual Scene texture stroke did not change R16 maps")
		return
	# Test the mesh brush through the dock and the Scene event router as well.
	await click(dock.meshes_btn.get_global_rect().get_center())
	await frames(8)
	entry = dock.mesh_list.entries[0]
	await click(entry.get_global_rect().position + entry.size * Vector2(0.5, 0.65))
	await frames(8)
	var location = terrain.data.get_region_locations()[0]
	var paint_hit = dock.plugin.mouse_global_position
	paint_hit.x = clampf(paint_hit.x, location.x * region_world + 0.5, location.x * region_world + region_world - 0.5)
	paint_hit.z = clampf(paint_hit.z, location.y * region_world + 0.5, location.y * region_world + region_world - 0.5)
	paint_hit.y = 0.0
	point = container.get_global_rect().position + vp.get_camera_3d().unproject_position(paint_hit)
	for stroke in 3:
		await click(point)
	await frames(8)
	var instances = 0
	for region in terrain.data.get_regions_active():
		for cells in region.instances.values():
			for cell in cells.values():
				instances += cell[0].size()
	print("MESH_INSTANCES=", instances)
	if instances == 0:
		fail("Scene mesh brush created no instances")
		return
	await click(dock.plugin.ui.toolbar.buttons["AddRegion"].get_global_rect().get_center())
	await frames(8)
	var found = false
	for u in [0.2, 0.5, 0.8]:
		for v in [0.3, 0.6, 0.85]:
			var pixel = Vector2(vp.size) * Vector2(u,v)
			var cam = vp.get_camera_3d()
			var hit = Plane(Vector3.UP,0).intersects_ray(cam.project_ray_origin(pixel),cam.project_ray_normal(pixel))
			if hit != null and not terrain.data.has_regionp(hit):
				point = container.get_global_rect().position + container.size * Vector2(u,v)
				found = true
				break
		if found:
			break
	if not found:
		fail("fixture needs visible empty space for Add Region")
		return
	await click(point)
	await frames(8)
	print("ADD_REGION tool=",dock.plugin.editor.get_tool()," op=",dock.plugin.editor.get_operation()," hit=",dock.plugin.mouse_global_position," point=",point," count=",terrain.data.get_region_count())
	if terrain.data.get_region_count() != 2:
		fail("Add Region did not expand into empty space with background disabled")
		return
	EditorInterface.save_scene()
	await frames(15)
	var reload = Terrain3D.new()
	reload.data_directory = terrain.data_directory
	root.add_child(reload)
	await frames(8)
	if reload.data.get_region_count()!=2:
		fail("saved terrain regions did not reload")
		return
	var original_background = reload.material.world_background
	dock.plugin.terrain_setup.request(reload, true)
	if reload.data.get_region_count() != 2 or reload.material.world_background != original_background:
		fail("initialization modified an existing terrain")
		return
	reload.queue_free()
	var empty = Terrain3D.new()
	root.add_child(empty)
	await frames(5)
	dock.plugin.terrain_setup.request(empty, true)
	dock.plugin.terrain_setup.dialog.canceled.emit()
	dock.plugin.terrain_setup.dialog.hide()
	if empty.data.get_region_count() != 0 or not empty.data_directory.is_empty():
		fail("canceling initialization created terrain data")
		return
	dock.plugin.terrain_setup.request(empty, true)
	dock.plugin.terrain_setup.dialog.dir_selected.emit(terrain.data_directory)
	dock.plugin.terrain_setup.dialog.hide()
	await frames(8)
	if empty.data.get_region_count() != 2 or empty.material.world_background != Terrain3DMaterial.FLAT:
		fail("choosing existing data folder replaced its terrain settings")
		return
	empty.queue_free()
	print("PASS terrain setup, Scene texture/mesh painting, Add Region, and saved reload")
	await frames(20)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await frames()
	EditorInterface.save_scene()
	await frames(5)
	# Use the normal editor shutdown path so resource-preview work is stopped
	# before nodes and addons are destroyed (SceneTree.quit bypasses this).
	EditorInterface.get_base_control().get_parent().call_deferred("notification", NOTIFICATION_WM_CLOSE_REQUEST)
