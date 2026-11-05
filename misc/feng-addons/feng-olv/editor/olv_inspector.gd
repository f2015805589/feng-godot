@tool
extends EditorInspectorPlugin
const Volume = preload("../feng_olv_volume.gd")
var undo_redo: EditorUndoRedoManager
func _can_handle(object: Object) -> bool: return object is Volume
func _parse_property(_object: Object, _type: int, name: String, _hint: int, _hint_string: String, _usage: int, _wide: bool) -> bool:
	return name in ["show_probes","probe_filter","xray_probes","limit_to_batch_box"]

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
		undo_redo.create_action("切换 OLV 防漏光", UndoRedo.MERGE_DISABLE, node)
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
	box.add_child(HSeparator.new())
	var show := CheckButton.new()
	show.text = "显示并编辑 Probe"
	show.toggled.connect(func(value: bool):
		undo_redo.create_action("切换 OLV Probe 显示", UndoRedo.MERGE_DISABLE, node)
		undo_redo.add_do_property(node,"show_probes",value)
		undo_redo.add_undo_property(node,"show_probes",node.show_probes)
		undo_redo.commit_action())
	box.add_child(show)
	var filter := OptionButton.new()
	filter.add_item("全部标签",0)
	filter.add_item("仅室内",2)
	filter.add_item("仅室外",1)
	filter.item_selected.connect(func(index: int):
		undo_redo.create_action("筛选 OLV Probe",UndoRedo.MERGE_DISABLE,node)
		undo_redo.add_do_property(node,"probe_filter",filter.get_item_id(index))
		undo_redo.add_undo_property(node,"probe_filter",node.probe_filter)
		undo_redo.commit_action())
	box.add_child(filter)
	var xray := CheckButton.new()
	xray.text = "透视显示 / 选择（包含遮挡点）"
	xray.tooltip_text = "默认关闭，墙后的 Probe 不显示也不会被框选。需要穿墙批量编辑时再开启。"
	xray.toggled.connect(func(value: bool):
		undo_redo.create_action("切换 OLV 透视选择",UndoRedo.MERGE_DISABLE,node)
		undo_redo.add_do_property(node,"xray_probes",value)
		undo_redo.add_undo_property(node,"xray_probes",node.xray_probes)
		undo_redo.commit_action())
	box.add_child(xray)
	var local_only := CheckButton.new()
	local_only.text = "仅显示空间批量框内的 Probe"
	local_only.tooltip_text = "点太多时开启，在下方「空间批量框」调整中心和大小，只编辑这块区域。"
	local_only.toggled.connect(func(value: bool):
		undo_redo.create_action("限制 OLV 编辑范围",UndoRedo.MERGE_DISABLE,node)
		undo_redo.add_do_property(node,"limit_to_batch_box",value)
		undo_redo.add_undo_property(node,"limit_to_batch_box",node.limit_to_batch_box)
		undo_redo.add_undo_property(node,"show_batch_box",node.show_batch_box)
		undo_redo.commit_action())
	box.add_child(local_only)
	var legend := HBoxContainer.new()
	for item in [["室内",Volume.probe_display_color(2)],["室外",Volume.probe_display_color(1)]]:
		var swatch := ColorRect.new()
		swatch.color = item[1]
		swatch.custom_minimum_size = Vector2(14,14)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		legend.add_child(swatch)
		var label := Label.new()
		label.text = item[0] + "  "
		legend.add_child(label)
	box.add_child(legend)
	var counts := Label.new()
	counts.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(counts)
	var help := Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = "点击单选，Shift 追加，Ctrl 切换；拖框多选，Ctrl+A 选中当前视野中显示的点。白环表示选中。默认不选遮挡点；右键转向、Alt 导航不受影响。"
	box.add_child(help)
	var selected := Label.new()
	selected.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(selected)
	var buttons: Array[Button] = []
	for item in [["标记选中为室内",2],["标记选中为室外",1],["恢复选中为模型结果",0]]:
		var button := Button.new()
		button.text = item[0]
		button.pressed.connect(_edit_labels.bind(node,int(item[1])))
		box.add_child(button)
		buttons.append(button)
	var selection_row := HBoxContainer.new()
	var select_all := Button.new()
	select_all.text = "全选筛选类别（含遮挡点）"
	select_all.tooltip_text = "选择该标签的全部有效 Probe，不限视野。仅选视野内显示的点请在视口按 Ctrl+A。"
	select_all.pressed.connect(node.select_all_probes)
	selection_row.add_child(select_all)
	var clear := Button.new()
	clear.text = "清空选择"
	clear.tooltip_text = "也可点击视口空白处或按 Esc。"
	clear.pressed.connect(node.clear_probe_selection)
	selection_row.add_child(clear)
	box.add_child(selection_row)
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
		show.set_pressed_no_signal(node.show_probes)
		filter.select(filter.get_item_index(node.probe_filter))
		xray.set_pressed_no_signal(node.xray_probes)
		local_only.set_pressed_no_signal(node.limit_to_batch_box)
		var view := node.get_probe_view()
		var totals: PackedInt32Array = view.get("counts", PackedInt32Array([0,0,0]))
		counts.text = "全部有效 Probe：%d · 室内 %d · 室外 %d" % [totals[0]+totals[1]+totals[2],totals[2],totals[1]]
		if totals[0] > 0: counts.text += "\n%d 个尚无标签（灰色），请先烘焙 / 更新 OLV。" % totals[0]
		if view.is_empty(): counts.text = "尚无 Probe，请先烘焙父节点 MagicGI。"
		id.max_value = maxi(0,int(view.get("slot_count",1))-1)
		select_all.disabled = view.is_empty()
		select_box.disabled = view.is_empty()
		clear.disabled = node.selected_probes.is_empty()
		pick.disabled = view.is_empty()
		selected.text = "已选中 %d 个 Probe" % node.selected_probes.size()
		if node.selected_probes.size() == 1:
			var label := node.probe_label(node.selected_probes[0])
			selected.text += " · 编号 %d · %s" % [node.selected_probes[0],"室内" if label == 2 else "室外" if label == 1 else "未标记"]
		var volume := node.get_source_volume()
		var stale := node.data != null and (volume == null or volume.bake_manifest == null or not node.data.matches_manifest(volume.bake_manifest))
		for button in buttons:
			button.disabled = node.busy or node.selected_probes.is_empty() or totals[0] > 0 or stale
			button.tooltip_text = "GI 格点已变化，请先更新 OLV。" if stale else "立即更新标签；支持撤销 / 重做，不重新烘焙 GI。"
	node.status_changed.connect(refresh)
	node.selection_changed.connect(refresh)
	box.tree_exiting.connect(func():
		if is_instance_valid(node):
			if node.status_changed.is_connected(refresh): node.status_changed.disconnect(refresh)
			if node.selection_changed.is_connected(refresh): node.selection_changed.disconnect(refresh))
	refresh.call()
	add_custom_control(box)
func _edit_labels(node: FOLVVolume, label: int) -> void:
	if node.busy or node.selected_probes.is_empty(): return
	if node.data == null and not node.import_existing_labels(): return
	var previous := node.data.overrides.duplicate(true)
	var next := node.overrides_for_selection(label)
	if previous == next: return
	undo_redo.create_action("修改 OLV Probe 标签", UndoRedo.MERGE_DISABLE, node)
	undo_redo.add_do_method(node,"set_probe_overrides",next,node.data.source_layout_sha256)
	undo_redo.add_undo_method(node,"set_probe_overrides",previous,node.data.source_layout_sha256)
	undo_redo.commit_action()
	EditorInterface.mark_scene_as_unsaved()
