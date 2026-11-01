@tool
extends EditorInspectorPlugin
const Volume = preload("../feng_olv_volume.gd")
var undo_redo: EditorUndoRedoManager
func _can_handle(object: Object) -> bool: return object is Volume
func _parse_begin(object: Object) -> void:
	var node := object as FOLVVolume
	var box := VBoxContainer.new()
	var status := Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status)
	var progress := ProgressBar.new()
	box.add_child(progress)
	var enabled := CheckButton.new()
	enabled.text = "启用 OLV 防漏光"
	enabled.button_pressed = node.enabled
	enabled.toggled.connect(func(value: bool):
		undo_redo.create_action("切换 OLV 防漏光")
		undo_redo.add_do_property(node,"enabled",value)
		undo_redo.add_undo_property(node,"enabled",node.enabled)
		undo_redo.commit_action())
	box.add_child(enabled)
	var update := Button.new()
	update.text = "烘焙 / 更新 OLV 标签"
	update.tooltip_text = "使用所选模型重新识别；保留当前 GI 传输和手工标记。"
	update.pressed.connect(func():
		if await node.update_labels(): EditorInterface.mark_scene_as_unsaved())
	box.add_child(update)
	var adopt := Button.new()
	adopt.text = "导入已有 OLV（无需推理）"
	adopt.pressed.connect(func():
		if node.import_existing_labels(): EditorInterface.mark_scene_as_unsaved())
	box.add_child(adopt)
	var cancel := Button.new()
	cancel.text = "取消更新"
	cancel.pressed.connect(node.cancel)
	box.add_child(cancel)
	var help := Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = "打开「显示 Probe」和「编辑 Probe」后点击点选，Ctrl 多选。也可调整批量框后框选；0 为无效槽位，不能编辑。"
	box.add_child(help)
	var selected := Label.new()
	box.add_child(selected)
	var pick_row := HBoxContainer.new()
	var id := SpinBox.new()
	id.min_value = 0
	id.max_value = 262143
	id.step = 1
	id.custom_minimum_size.x = 110
	pick_row.add_child(id)
	var pick := Button.new()
	pick.text = "按编号选择 Probe"
	pick.pressed.connect(func(): node.select_probe(int(id.value)))
	pick_row.add_child(pick)
	box.add_child(pick_row)
	var select_box := Button.new()
	select_box.text = "选中批量框内的 Probe"
	select_box.pressed.connect(node.select_in_box)
	box.add_child(select_box)
	var buttons: Array[Button] = []
	for item in [["标记选中为室内",2],["标记选中为室外",1],["恢复选中为模型结果",0]]:
		var button := Button.new()
		button.text = item[0]
		button.pressed.connect(_edit_labels.bind(node,int(item[1])))
		box.add_child(button)
		buttons.append(button)
	var refresh := func():
		if not is_instance_valid(status): return
		status.text = node.status
		progress.visible = node.busy
		progress.indeterminate = node.progress_total <= 0
		progress.max_value = maxi(1,node.progress_total)
		progress.value = node.progress_done
		update.disabled = node.busy
		adopt.visible = node.data == null
		adopt.disabled = node.busy
		cancel.visible = node.busy
		enabled.set_pressed_no_signal(node.enabled)
		selected.text = "已选中 %d 个 Probe" % node.selected_probes.size()
		if node.selected_probes.size() == 1:
			selected.text += " · 编号 %d · %s" % [node.selected_probes[0],"室内" if node.probe_label(node.selected_probes[0]) == 2 else "室外"]
		for button in buttons: button.disabled = node.busy or node.selected_probes.is_empty()
	node.status_changed.connect(refresh)
	node.selection_changed.connect(refresh)
	box.tree_exiting.connect(func():
		if is_instance_valid(node):
			if node.status_changed.is_connected(refresh): node.status_changed.disconnect(refresh)
			if node.selection_changed.is_connected(refresh): node.selection_changed.disconnect(refresh))
	refresh.call()
	add_custom_control(box)
func _edit_labels(node: FOLVVolume, label: int) -> void:
	if node.data == null and not node.import_existing_labels(): return
	var previous := node.data.overrides.duplicate(true)
	var next := node.overrides_for_selection(label)
	undo_redo.create_action("修改 OLV Probe 标签")
	undo_redo.add_do_method(node,"set_probe_overrides",next,node.data.source_layout_sha256)
	undo_redo.add_undo_method(node,"set_probe_overrides",previous,node.data.source_layout_sha256)
	undo_redo.commit_action()
	EditorInterface.mark_scene_as_unsaved()
