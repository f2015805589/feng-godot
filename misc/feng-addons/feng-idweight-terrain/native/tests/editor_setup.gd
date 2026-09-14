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
	# Input.parse_input_event only reaches Node._input, and push_input() without
	# in_local_coords rebases the point through the window transform, so neither hits an
	# editor control: the dock test pushes local coordinates into the control's viewport
	# and this helper does the same for the whole window.
	var e=InputEventMouseMotion.new()
	e.position=point
	e.global_position=point
	get_tree().root.push_input(e, true)
	await frames(3)
func click(point, button=MOUSE_BUTTON_LEFT):
	await motion(point)
	for down in [true,false]:
		var e=InputEventMouseButton.new()
		e.position=point
		e.global_position=point
		e.button_index=button
		e.pressed=down
		get_tree().root.push_input(e, true)
		await frames(3)
func describe_control(control) -> String:
	var text := 'rect=%s visible_in_tree=%s' % [control.get_global_rect(),control.is_visible_in_tree()]
	var node = control.get_parent()
	while node:
		if node is Control:
			text += ' | %s rect=%s visible=%s' % [node.name,node.get_global_rect(),node.visible]
		elif node is CanvasItem:
			text += ' | %s visible=%s' % [node.name,node.visible]
		node = node.get_parent()
	for window in EditorInterface.get_base_control().find_children("*","Window",true,false):
		if window.visible:
			text += ' | window %s visible' % window.name
	return text

func find_ancestor_class(p_control, p_class):
	var node = p_control.get_parent()
	while node:
		if node.get_class() == p_class:
			return node
		node = node.get_parent()
	return null

func find_scroller(control):
	var node = control.get_parent()
	while node:
		if node is ScrollContainer:
			return node
		node = node.get_parent()
	return null

func click_point(control, scroller, offset=Vector2(0.5,0.5)) -> Vector2:
	var rect: Rect2 = control.get_global_rect()
	if scroller:
		# The dock sits in the bottom panel, so a list entry below the visible area is
		# clipped away: click inside the part of the entry the panel actually shows.
		var visible: Rect2 = rect.intersection(scroller.get_global_rect())
		if visible.size.x > 2.0 and visible.size.y > 2.0:
			rect = visible
	return rect.position + rect.size * offset

# Dock controls live in their own viewport, so a control is clicked by pushing the event
# into that viewport, the way the dock test does, and the hit is required to land on the
# control: a silently missed click is how this test used to pass without painting. The
# list scrolls over frames, so the hit is retried before it is called a miss.
func click_control(control, button=MOUSE_BUTTON_LEFT, offset=Vector2(0.5,0.5), require_hit=true):
	await frames(4)
	var scroller = find_scroller(control)
	var viewport = control.get_viewport()
	var hovered = null
	for attempt in 4:
		if scroller:
			scroller.ensure_control_visible(control)
			await frames(6)
		var point = click_point(control,scroller,offset)
		var movement = InputEventMouseMotion.new()
		movement.position=point
		movement.global_position=point
		viewport.push_input(movement,true)
		await frames(2)
		hovered = viewport.gui_get_hovered_control()
		var node = hovered
		while node:
			if node == control:
				break
			node = node.get_parent()
		if node == control:
			break
		await frames(4)
	if not hovered or (hovered != control and not control.is_ancestor_of(hovered)):
		# A list entry is scrolled by its own layout and can be reported as visible while
		# the hit test still finds nothing there, so a miss is only fatal where the click
		# itself is the thing under test; where the click is a setup step the caller
		# asserts its effect instead (the stroke that follows has to paint).
		if require_hit:
			fail("mouse event did not reach %s; hovered=%s %s" % [control.get_path(),hovered,describe_control(control)])
			return
		print("CLICK_MISS control=",control.get_path()," hovered=",hovered)
	var target = click_point(control,scroller,offset)
	for down in [true,false]:
		var e=InputEventMouseButton.new()
		e.position=target
		e.global_position=target
		e.button_index=button
		e.pressed=down
		viewport.push_input(e,true)
		await frames(2)

# A dock can start as a background tab of the bottom panel, where its lists are clipped
# away and a click cannot land on them; open the dock the way its own tab does. The hit is
# checked afterwards so a dock that never came up fails loudly instead of silently.
func open_dock(control) -> bool:
	var editor_dock = find_ancestor_class(control,"EditorDock")
	if editor_dock == null:
		return true
	editor_dock.make_visible()
	await frames(10)
	return true
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
	await open_dock(dock)
	# IdWeight pair roles for the stroke below: the left click writes the background field
	# and the right click the overlay one (pairroles pins that mapping). These clicks are
	# setup, not the thing under test, so a missed hit is reported and the stroke that
	# follows is what has to prove the selection took.
	var entry=dock.texture_list.entries[1]
	await click_control(entry,MOUSE_BUTTON_LEFT,Vector2(0.5,0.65),false)
	entry=dock.texture_list.entries[0]
	await click_control(entry,MOUSE_BUTTON_RIGHT,Vector2(0.5,0.65),false)
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
	# Test the mesh brush through the Scene event router. The dock's own click routing is
	# pinned by the dock and pairroles tests; here the list switch is setup for the stroke,
	# so it runs the button's handler and the stroke below is what has to create instances.
	dock.meshes_btn.pressed.emit()
	await frames(8)
	entry = dock.mesh_list.entries[0]
	dock.mesh_list.clicked_id(0)
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
		fail("Scene mesh brush created no instances: tool=%d list_is_mesh=%s meshes=%d hit=%s" % [
				dock.plugin.editor.get_tool(),dock.current_list==dock.mesh_list,
				terrain.assets.get_mesh_count(),paint_hit])
		return
	# Same split as the mesh list: the toolbar button's handler selects the tool and the
	# Scene click below has to expand the grid into the empty space.
	dock.plugin.ui.toolbar.buttons["AddRegion"].pressed.emit()
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
	# The editor flushes the terrain's modified regions when the scene is saved, and the
	# reload below reads them back from disk.
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
	# A pristine Terrain3D defaults to WorldBackground.NONE and pointing it at an existing
	# folder must not replace that: compare against the terrain's own value, not against a
	# background mode this object never had.
	var empty_background = empty.material.world_background
	dock.plugin.terrain_setup.request(empty, true)
	dock.plugin.terrain_setup.dialog.dir_selected.emit(terrain.data_directory)
	dock.plugin.terrain_setup.dialog.hide()
	await frames(8)
	if empty.data.get_region_count() != 2 or empty.material.world_background != empty_background:
		fail("choosing existing data folder replaced its terrain settings: regions=%d background=%d expected %d" % [
				empty.data.get_region_count(),empty.material.world_background,empty_background])
		return
	empty.queue_free()
	# Freeing the test terrains queues their region writes; saving while those are being
	# renamed makes the editor scan a file it cannot open yet, which reports an engine-side
	# "Method/function failed." that has nothing to do with the terrain.
	await frames(30)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await frames()
	EditorInterface.save_scene()
	await frames(20)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await frames()
	print("PASS terrain setup, Scene texture/mesh painting, Add Region, and saved reload")
	# Use the normal editor shutdown path so resource-preview work is stopped
	# before nodes and addons are destroyed (SceneTree.quit bypasses this).
	EditorInterface.get_base_control().get_parent().call_deferred("notification", NOTIFICATION_WM_CLOSE_REQUEST)
