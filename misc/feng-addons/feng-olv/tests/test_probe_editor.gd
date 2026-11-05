extends SceneTree
## Run with --headless --editor; only test resources under .godot are saved.
const Overlay = preload("res://addons/feng-olv/editor/olv_probe_overlay.gd")
const OUT := "res://.godot/feng-olv-tests/probe-editor/"
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
func frames(count: int) -> void:
	for frame in count: await process_frame
func button(text: String) -> Button:
	for control in EditorInterface.get_inspector().find_children("*", "Button", true, false):
		if control.text == text: return control
	return null
func click(plugin: EditorPlugin, camera: Camera3D, point: Vector2, shift := false, ctrl := false) -> void:
	for pressed in [true,false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = point
		event.shift_pressed = shift
		event.ctrl_pressed = ctrl
		check(plugin._forward_3d_gui_input(camera,event) == EditorPlugin.AFTER_GUI_INPUT_STOP,"Probe click is handled by the editor plugin")

func run() -> void:
	await frames(30)
	check(Overlay.make_points({},PackedInt32Array()) == null,"An unbaked OLV node creates no empty GPU buffer")
	EditorInterface.open_scene_from_path("res://box_test.tscn")
	await frames(30)
	var scene := EditorInterface.get_edited_scene_root()
	var volume := scene.get_node("MagicGIVolume")
	var node := volume.get_node("OLV") as FOLVVolume
	var scene_sha := FileAccess.get_sha256("res://box_test.tscn")
	var production_path := node.data_path
	var production_sha := FileAccess.get_sha256(production_path)
	var manifest: Resource = volume.bake_manifest
	var manifest_sha := FileAccess.get_sha256(manifest.resource_path)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	# Never let UI edit actions write the production sidecar.
	node.data_path = OUT + "domains.res"
	node.data = node.data.duplicate(true)
	var source := node.get_probe_source()
	var transfer: PackedFloat32Array = source.transfer
	var operators: PackedFloat32Array = source.clv_prepared_operators
	var view := node.get_probe_view()
	check(node.show_probes,"Probe display is enabled by default")
	check(view.indices.size() == source.valid_cell_count(),"Every valid baked source Probe is displayed")
	check(view.indices.size() >= 2,"Real white-box fixture has enough Probes for batch editing")
	check(view.counts[0] == 0,"All valid source Probes carry indoor/outdoor labels")
	for i in view.indices.size():
		check(view.positions[i] == source.cell_position(view.indices[i]),"Displayed positions use relocated source coordinates")
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	EditorInterface.edit_node(node)
	await frames(20)
	var plugin: EditorPlugin
	for candidate in root.find_children("*", "EditorPlugin", true, false):
		if candidate.get_script() != null and candidate.get_script().resource_path == "res://addons/feng-magic-gi/editor_plugin.gd":
			plugin = candidate
	check(plugin != null,"The real MagicGI editor plugin is enabled")
	if plugin == null: quit(1);return
	check(plugin._editing_olv == node,"Selecting OLV enables Probe editing automatically")
	check(button("显示并编辑 Probe") != null,"One combined display/edit toggle is visible")
	check(button("标记选中为室内") != null and button("标记选中为室外") != null,"Direct indoor/outdoor actions are present")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(800,600)
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.position = source.source_bounds_world.get_center()+Vector3(10,9,15)
	camera.look_at(source.source_bounds_world.get_center())
	await frames(2)
	var visible_view := node.get_visible_probe_view(camera)
	check(not node.xray_probes,"Occlusion is enabled by default")
	check(visible_view.indices.size() > 0 and visible_view.indices.size() < view.indices.size(),"Real scene meshes occlude Probes without physics collision bodies")
	print("OLV_VISIBILITY ",visible_view.indices.size()," / ",view.indices.size()," compute_us=",visible_view.elapsed_usec)
	var first := -1
	var second := -1
	var first_uv := Vector2.ZERO
	for index in view.indices:
		var uv := camera.unproject_position(source.cell_position(index))
		if node.pick_probe(camera,uv) != index: continue
		if first < 0:
			first = index
			first_uv = uv
		elif uv.distance_to(first_uv) > 50:
			second = index
			break
	check(first >= 0 and second >= 0,"Two separated visible Probes are available for clicking")
	click(plugin,camera,first_uv)
	check(node.selected_probes == PackedInt32Array([first]),"Click selects one Probe")
	var second_uv := camera.unproject_position(source.cell_position(second))
	click(plugin,camera,second_uv,true)
	check(node.selected_probes.size() == 2 and node.selected_probes.has(first) and node.selected_probes.has(second),"Shift click adds without losing the first Probe")
	click(plugin,camera,first_uv,false,true)
	check(node.selected_probes == PackedInt32Array([second]),"Ctrl click toggles only the hit Probe")
	click(plugin,camera,Vector2(-100,-100),true)
	check(node.selected_probes == PackedInt32Array([second]),"Shift click on empty space preserves selection")
	click(plugin,camera,Vector2(-100,-100))
	check(node.selected_probes.is_empty(),"Empty click clears selection")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = Vector2(799,599)
	press.pressed = true
	plugin._forward_3d_gui_input(camera,press)
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2.ZERO
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	plugin._forward_3d_gui_input(camera,motion)
	check(node.selected_probes.is_empty(),"Dragging avoids rescanning all Probes on every motion")
	press.pressed = false
	press.position = Vector2.ZERO
	plugin._forward_3d_gui_input(camera,press)
	check(node.selected_probes == visible_view.indices,"Reverse-direction marquee selects only displayed Probes")
	node.xray_probes = true
	node.select_screen_rect(camera,Rect2(0,0,800,600))
	check(node.selected_probes.size() == view.indices.size(),"Explicit X-ray can select occluded Probes")
	node.xray_probes = false
	for label in [1,2]:
		node.probe_filter = label
		check(node.get_filtered_probe_view().indices.size() == view.counts[label],"Indoor/outdoor filters retain exactly their label class")
		node.select_all_probes()
		for index in node.selected_probes: check(node.probe_label(index) == label,"Class selection never modifies hidden label classes")
	node.probe_filter = 0
	node.limit_to_batch_box = true
	var local_view := node.get_filtered_probe_view()
	check(not local_view.indices.is_empty() and local_view.indices.size() < view.indices.size(),"Local editing limits the displayed population without modifying Probe data")
	node.select_all_probes()
	check(node.selected_probes == local_view.indices,"Class selection also respects the active local editing box")
	node.limit_to_batch_box = false
	var old_projection := camera.projection
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 15
	var ortho_visible := node.get_visible_probe_view(camera)
	node.xray_probes = true
	check(ortho_visible.indices.size() < node.get_visible_probe_view(camera).indices.size(),"Orthographic editor views also respect mesh occlusion")
	node.xray_probes = false
	camera.projection = old_projection
	camera.far = 0.5
	check(node.pick_probe(camera,first_uv) == -1,"Clipped Probes cannot be clicked")
	node.select_screen_rect(camera,Rect2(0,0,800,600))
	check(node.selected_probes.is_empty(),"Marquee excludes Probes beyond the camera far plane")
	camera.far = 4000.0
	node.select_all_probes()
	var previous := node.selected_probes.duplicate()
	press.pressed = true
	press.alt_pressed = true
	check(plugin._forward_3d_gui_input(camera,press) == EditorPlugin.AFTER_GUI_INPUT_PASS,"Alt navigation passes through")
	check(node.selected_probes == previous,"Navigation does not change Probe labels or selection")
	node.show_probes = false
	press.alt_pressed = false
	check(plugin._forward_3d_gui_input(camera,press) == EditorPlugin.AFTER_GUI_INPUT_PASS,"Hiding Probes releases mouse input to the editor")
	node.show_probes = true
	EditorInterface.get_selection().clear()
	check(plugin._forward_3d_gui_input(camera,press) == EditorPlugin.AFTER_GUI_INPUT_PASS,"Deselecting the OLV node releases mouse input")
	EditorInterface.get_selection().add_node(node)
	EditorInterface.edit_node(node)
	await frames(2)
	node.select_probes(PackedInt32Array([-1,source.probe_count,first,first,second]))
	check(node.selected_probes.size() == 2,"Invalid indices and duplicate picks are discarded")
	var original_labels: PackedByteArray = node.data.payload.labels.duplicate()
	var new_label := 1 if node.probe_label(first) == 2 else 2
	var action := button("标记选中为室内" if new_label == 2 else "标记选中为室外")
	check(not action.disabled,"Label actions become active after selection")
	action.pressed.emit()
	await frames(5)
	check(node.probe_label(first) == new_label and node.probe_label(second) == new_label,"Inspector batch action updates every selected label")
	check(node.get_probe_view().counts[new_label] != view.counts[new_label] or original_labels[first] == new_label,"Display cache refreshes after a label edit")
	var history := plugin.get_undo_redo().get_history_undo_redo(plugin.get_undo_redo().get_object_history_id(node))
	check(history.has_undo(),"Label edit has an editor undo action")
	history.undo()
	check(node.data.payload.labels == original_labels,"Editor undo restores all original labels")
	history.redo()
	check(node.probe_label(first) == new_label and node.probe_label(second) == new_label,"Editor redo restores the batch correction")
	var loaded: FOLVData = ResourceLoader.load(node.data_path,"",ResourceLoader.CACHE_MODE_IGNORE)
	check(loaded.payload.labels == node.data.payload.labels and loaded.overrides == node.data.overrides,"Independent label resource persists edits on disk")
	var packed := PackedScene.new()
	check(packed.pack(scene) == OK and ResourceSaver.save(packed,OUT+"scene.tscn") == OK,"Scene with edited OLV sidecar saves")
	var reloaded := (ResourceLoader.load(OUT+"scene.tscn","",ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var reloaded_node := reloaded.get_node("MagicGIVolume/OLV") as FOLVVolume
	check(reloaded_node.data.payload.labels == node.data.payload.labels,"Saved scene reload retains corrected labels")
	reloaded.free()
	button("恢复选中为模型结果").pressed.emit()
	check(node.data.payload.labels == original_labels,"Restore action removes manual overrides for the selection")
	button("全选筛选类别（含遮挡点）").pressed.emit()
	check(node.selected_probes.size() == view.indices.size(),"Inspector select-all includes the complete source layout")
	button("清空选择").pressed.emit()
	check(node.selected_probes.is_empty(),"Inspector clear button clears selection")
	node.select_probe(first)
	var original_transform: Transform3D = volume.transform
	volume.position += Vector3(1,0,0)
	check(node.get_probe_view().is_empty() and node.selected_probes.is_empty(),"Moving the GI source invalidates stale Probe editing and clears selection")
	volume.transform = original_transform
	check(node.get_probe_view().indices.size() == view.indices.size(),"Restoring the GI transform restores its valid Probe view")
	check(source.transfer == transfer and source.clv_prepared_operators == operators,"Label editing leaves GI transfer and interpolation operators unchanged")
	check(volume.bake_manifest == manifest and FileAccess.get_sha256(manifest.resource_path) == manifest_sha,"GI manifest is not changed or rebaked")
	check(FileAccess.get_sha256(production_path) == production_sha and FileAccess.get_sha256("res://box_test.tscn") == scene_sha,"Test does not change production scene or label data")
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(volume)
	EditorInterface.edit_node(volume)
	await frames(3)
	var add_exclusion := button("添加 Probe 排除区")
	check(add_exclusion != null,"GI inspector exposes exclusion creation")
	add_exclusion.pressed.emit()
	var exclusion: Node = volume.get_children()[-1]
	check(exclusion is FMagicGIProbeExclusion and exclusion.owner == scene,"Exclusion is a saved child of the correct GI Volume")
	check(node.get_probe_view().is_empty(),"Adding an exclusion blocks editing of stale baked Probes")
	history = plugin.get_undo_redo().get_history_undo_redo(plugin.get_undo_redo().get_object_history_id(volume))
	history.undo()
	check(node.get_probe_view().indices.size() == view.indices.size(),"Undoing exclusion creation restores the unchanged baked layout")
	var report := {"checks":checks,"failures":failures,"displayed_probes":view.indices.size(),"total_slots":source.probe_count}
	var file := FileAccess.open(OUT+"report.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("OLV_PROBE_EDITOR_RESULT ",JSON.stringify(report))
	viewport.queue_free()
	EditorInterface.get_inspector().edit(null)
	await frames(2)
	quit(1 if failures else 0)
