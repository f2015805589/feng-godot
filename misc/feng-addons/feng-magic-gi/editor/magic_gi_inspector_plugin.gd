@tool
extends EditorInspectorPlugin
## Inspector for FMagicGIVolume: bake controls and current progress.

const Volume = preload("../feng_magic_gi_volume.gd")
const ProbeExclusion = preload("../feng_magic_gi_probe_exclusion.gd")
var undo_redo: EditorUndoRedoManager

class BakeNumberEditor:
	extends EditorProperty
	var number := SpinBox.new()
	var integer_value := false
	func _init(minimum: float, maximum: float, increment: float, suffix: String, hint: String) -> void:
		integer_value = increment == 1.0 and suffix.is_empty()
		number.min_value = minimum
		number.max_value = maximum
		number.step = increment
		number.suffix = suffix
		number.tooltip_text = hint
		tooltip_text = hint
		add_child(number)
		add_focusable(number.get_line_edit())
		number.value_changed.connect(func(value: float):
			emit_changed(get_edited_property(), int(value) if integer_value else value))
	func _update_property() -> void:
		var object := get_edited_object()
		if object != null: number.set_value_no_signal(float(object.get(get_edited_property())))
	func _set_read_only(value: bool) -> void:
		number.editable = not value

class BakeSamplesEditor:
	extends EditorProperty
	var options := OptionButton.new()
	func _init() -> void:
		tooltip_text = "每个 Probe 的射线数，控制采样噪声；反弹次数单独设置。"
		options.tooltip_text = tooltip_text
		add_child(options)
		add_focusable(options)
		options.item_selected.connect(func(index: int):
			emit_changed(get_edited_property(), options.get_item_id(index)))
	func _update_property() -> void:
		var object := get_edited_object()
		if object == null: return
		var samples := int(object.get(get_edited_property()))
		options.clear()
		for index in Volume.BAKE_QUALITY_SAMPLES.size():
			var preset: int = Volume.BAKE_QUALITY_SAMPLES[index]
			options.add_item("%s — %d rays" % [Volume.BAKE_QUALITY_NAMES[index], preset], preset)
		var selected := options.get_item_index(samples)
		if selected < 0:
			options.add_item("Custom — %d rays" % samples, samples)
			selected = options.item_count - 1
		options.select(selected)
	func _set_read_only(value: bool) -> void:
		options.disabled = value

func _can_handle(object: Object) -> bool:
	return object is Volume

func _parse_begin(_object: Object) -> void:
	var volume := _object as Volume
	var container := VBoxContainer.new()
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var progress := ProgressBar.new()
	progress.visible = false
	var ui := {"info": info, "progress": progress}
	var spacing_info := Label.new()
	spacing_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui["spacing_info"] = spacing_info
	var status_callback := Callable(self, "_update_status").bind(volume, info, ui)
	volume.bake_status_changed.connect(status_callback)
	info.tree_exiting.connect(_disconnect_status_callback.bind(volume, status_callback), CONNECT_ONE_SHOT)
	container.add_child(info)
	container.add_child(progress)

	var bake_row := HBoxContainer.new()
	ui["bake_row"] = bake_row
	var bake_button := Button.new()
	bake_button.pressed.connect(_on_bake_pressed.bind(volume, ui))
	bake_row.add_child(bake_button)
	ui["bake_button"] = bake_button
	var cancel_button := Button.new()
	cancel_button.pressed.connect(func():
		var node := volume.get_olv_controller()
		if node != null and bool(node.get("busy")): node.call("cancel")
		else: volume.cancel_bake())
	bake_row.add_child(cancel_button)
	ui["cancel_button"] = cancel_button
	container.add_child(bake_row)

	var olv_row := VBoxContainer.new()
	var olv_enabled := CheckButton.new()
	olv_enabled.text = "启用 OLV 防漏光"
	olv_enabled.toggled.connect(_on_olv_toggled.bind(volume))
	container.add_child(olv_enabled)
	ui["olv_enabled"] = olv_enabled
	var olv_update := Button.new()
	olv_update.text = "更新 OLV 标记"
	olv_update.tooltip_text = "使用当前已烘焙的 Probe 更新室内/室外标签；不重新计算 GI。"
	olv_update.pressed.connect(_on_olv_update_pressed.bind(volume, ui))
	olv_row.add_child(olv_update)
	ui["olv_update"] = olv_update
	var olv_button := Button.new()
	olv_button.text = "OLV 模型 / 手工修正"
	olv_button.tooltip_text = "OLV 节点提供开关、模型更新和单个/批量 Probe 标签编辑。"
	olv_button.pressed.connect(_on_olv_bake_pressed.bind(volume, ui))
	olv_row.add_child(olv_button)
	ui["olv_row"] = olv_row
	ui["olv_button"] = olv_button
	container.add_child(olv_row)
	var olv_status := Label.new()
	olv_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	container.add_child(olv_status)
	ui["olv_status"] = olv_status
	var exclusion := Button.new()
	exclusion.text = "添加 Probe 排除区"
	exclusion.tooltip_text = "与本 MagicGI Volume 相交的区域不生成 Probe；移动、旋转或调整 Size 后重新烘焙 GI。"
	exclusion.visible = volume.uses_free_space_clv_bake()
	exclusion.pressed.connect(_add_probe_exclusion.bind(volume))
	container.add_child(exclusion)

	var chunk_row := HBoxContainer.new()
	var chunk_label := Label.new()
	chunk_label.text = "Chunk X/Z"
	chunk_row.add_child(chunk_label)
	var chunk_x := _make_chunk_coordinate()
	chunk_row.add_child(chunk_x)
	var chunk_z := _make_chunk_coordinate()
	chunk_row.add_child(chunk_z)
	var chunk_button := Button.new()
	chunk_button.text = "烘焙选中区域"
	chunk_button.pressed.connect(_on_chunk_bake_pressed.bind(volume, chunk_x, chunk_z, ui))
	chunk_row.add_child(chunk_button)
	container.add_child(chunk_row)
	ui["chunk_row"] = chunk_row
	ui["chunk_button"] = chunk_button

	var quality_label := Label.new()
	quality_label.text = "烘焙射线数"
	container.add_child(quality_label)
	ui["quality_label"] = quality_label
	var quality := OptionButton.new()
	quality.tooltip_text = "每个采样点的射线数；反弹次数单独设置。"
	for preset_index in Volume.BAKE_QUALITY_SAMPLES.size():
		var samples: int = Volume.BAKE_QUALITY_SAMPLES[preset_index]
		quality.add_item("%s — %d rays" % [Volume.BAKE_QUALITY_NAMES[preset_index], samples], samples)
	var selected_index := -1
	for item_index in quality.item_count:
		if quality.get_item_id(item_index) == volume.bake_samples:
			selected_index = item_index
			break
	if selected_index < 0:
		quality.add_item("Custom — %d rays" % volume.bake_samples, volume.bake_samples)
		selected_index = quality.item_count - 1
	quality.select(selected_index)
	quality.item_selected.connect(_on_quality_selected.bind(quality, volume, info, ui))
	container.add_child(quality)
	ui["quality"] = quality

	var refresh := Button.new()
	refresh.text = "更新采样点"
	refresh.pressed.connect(volume.refresh_surface_points)
	container.add_child(refresh)
	ui["refresh_button"] = refresh
	container.add_child(spacing_info)
	_update_status(volume, info, ui)
	add_custom_control(container)

func _parse_property(object: Object, _type: Variant.Type, name: String,
		_hint: PropertyHint, _hint_string: String, _usage: int, _wide: bool) -> bool:
	# Keep settings in the native, collapsible section below the bake controls.
	# Native property registration preserves undo, revert and saved values.
	if not object is Volume or not object.uses_free_space_clv_bake(): return false
	match name:
		"clv_cell_size":
			add_property_editor(name, BakeNumberEditor.new(0.1, 5.0, 0.025, "m",
				"相邻 Probe 的世界空间距离。越小越密、烘焙越慢；越大越稀疏。GI 和 OLV 共用这一套 Probe，修改后先烘焙 GI，再更新 OLV。"), false, "Probe 间距")
		"bake_samples":
			add_property_editor(name, BakeSamplesEditor.new(), false, "每点射线数")
		"bake_bounces":
			add_property_editor(name, BakeNumberEditor.new(1, 8, 1, "",
				"间接光反弹次数。"), false, "反弹次数")
		"bake_distance":
			add_property_editor(name, BakeNumberEditor.new(1.0, 4096.0, 1.0, "m",
				"单段烘焙射线的最大长度，与 Probe 间距不同。"), false, "追踪距离")
		_: return false
	return true

func _make_chunk_coordinate() -> SpinBox:
	var coordinate := SpinBox.new()
	coordinate.min_value = -1000000.0
	coordinate.max_value = 1000000.0
	coordinate.step = 1.0
	coordinate.rounded = true
	coordinate.custom_minimum_size.x = 84.0
	return coordinate

func _add_probe_exclusion(volume: FMagicGIVolume) -> void:
	if not is_instance_valid(volume) or volume.is_baking(): return
	var exclusion := ProbeExclusion.new()
	exclusion.name = "ProbeExclusion"
	undo_redo.create_action("添加 Probe 排除区",UndoRedo.MERGE_DISABLE,volume)
	undo_redo.add_do_method(volume,"add_child",exclusion,true)
	undo_redo.add_do_property(exclusion,"owner",EditorInterface.get_edited_scene_root())
	undo_redo.add_do_reference(exclusion)
	undo_redo.add_undo_method(volume,"remove_child",exclusion)
	undo_redo.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(exclusion)
	EditorInterface.edit_node(exclusion)
	EditorInterface.mark_scene_as_unsaved()

func _on_quality_selected(index: int, quality: OptionButton, volume: FMagicGIVolume,
		info: Label, ui: Dictionary) -> void:
	if not is_instance_valid(volume):
		return
	var samples: int = quality.get_item_id(index)
	if volume.bake_samples == samples:
		return
	volume.bake_samples = samples
	EditorInterface.mark_scene_as_unsaved()
	_update_status(volume, info, ui)

func _update_status(volume: FMagicGIVolume, info: Label, ui: Dictionary) -> void:
	if not is_instance_valid(volume) or not is_instance_valid(info):
		return
	var baking := volume.is_baking()
	var refreshing := volume.is_refreshing()
	var olv := volume.get_olv_controller()
	var olv_busy := olv != null and bool(olv.get("busy"))
	if olv != null and ui.get("olv_node") != olv:
		var callback := Callable(self, "_update_status").bind(volume, info, ui)
		olv.connect("status_changed", callback)
		info.tree_exiting.connect(func():
			if is_instance_valid(olv) and olv.is_connected("status_changed", callback):
				olv.disconnect("status_changed", callback), CONNECT_ONE_SHOT)
		ui["olv_node"] = olv
	var progress: ProgressBar = ui.get("progress")
	info.visible = not volume.is_surfel_mode()
	if baking:
		var counts := volume.streamed_bake_progress()
		info.text = "正在更新 OLV…" if volume.is_olv_bake_requested() else "正在烘焙 GI…"
		if counts.y > 0:
			info.text += " %d / %d" % [counts.x, counts.y]
		if is_instance_valid(progress):
			progress.indeterminate = counts.y <= 0
			progress.max_value = maxi(1, counts.y)
			progress.value = clampi(counts.x, 0, maxi(1, counts.y))
	elif olv_busy:
		info.text = "正在更新 OLV…"
		if is_instance_valid(progress):
			progress.indeterminate = int(olv.get("progress_total")) <= 0
			progress.max_value = maxi(1, int(olv.get("progress_total")))
			progress.value = int(olv.get("progress_done"))
	elif refreshing:
		info.text = "正在更新采样点…"
		if is_instance_valid(progress): progress.indeterminate = true
	elif volume.has_usable_bake():
		info.text = "设置或场景已变化，请重新烘焙 GI" if volume.needs_rebake() else "烘焙完成"
	else:
		info.text = "尚未烘焙"
	var spacing_info: Label = ui.get("spacing_info")
	spacing_info.visible = volume.uses_free_space_clv_bake()
	if spacing_info.visible:
		var bounds: AABB = volume.global_transform * AABB(-volume.size * 0.5, volume.size)
		var dims := Vector3i((bounds.size / volume.clv_cell_size).ceil())
		spacing_info.text = "间距越小越密 · 网格 %d × %d × %d" % [dims.x, dims.y, dims.z]
		if volume.bake_manifest != null:
			var baked := volume.bake_manifest.prepared_source_spacing_m
			spacing_info.text += "\n已烘焙 %s m" % str(baked)
			if not is_equal_approx(baked, volume.clv_cell_size):
				spacing_info.text += " → 当前 %s m，请先烘焙 GI" % str(volume.clv_cell_size)
	var olv_status: Label = ui.get("olv_status")
	olv_status.visible = volume.uses_free_space_clv_bake()
	if olv_status.visible:
		if olv == null or olv.get("data") == null:
			olv_status.text = "OLV：尚未标记，完成 GI 烘焙后更新"
		elif volume.bake_manifest == null or not olv.get("data").matches_manifest(volume.bake_manifest):
			olv_status.text = "OLV：Probe 已变化，请更新标记"
		else:
			olv_status.text = "OLV：已匹配当前烘焙" if bool(olv.get("enabled")) else "OLV：已关闭"
		if olv != null and not String(olv.get("last_error")).is_empty():
			olv_status.text = "OLV：" + String(olv.get("last_error"))
	if is_instance_valid(progress): progress.visible = info.visible and (baking or refreshing or olv_busy)
	_update_controls(volume, ui)

func _update_controls(volume: FMagicGIVolume, ui: Dictionary) -> void:
	var prt_visible := not volume.is_surfel_mode()
	var source_bake := volume.uses_free_space_clv_bake()
	var olv := volume.get_olv_controller()
	var olv_busy := olv != null and bool(olv.get("busy"))
	var olv_enabled: CheckButton = ui.get("olv_enabled")
	olv_enabled.visible = source_bake
	olv_enabled.set_pressed_no_signal(olv != null and bool(olv.get("enabled")))
	olv_enabled.disabled = volume.is_baking() or olv_busy
	var olv_update: Button = ui.get("olv_update")
	olv_update.disabled = not volume.has_bake() or volume.is_baking() or olv_busy
	var bake_row: HBoxContainer = ui.get("bake_row")
	if is_instance_valid(bake_row):
		bake_row.visible = prt_visible
	var olv_row: VBoxContainer = ui.get("olv_row")
	if is_instance_valid(olv_row):
		olv_row.visible = prt_visible and source_bake
	var quality_label: Label = ui.get("quality_label")
	if is_instance_valid(quality_label):
		quality_label.visible = prt_visible and not source_bake
		quality_label.text = "每个源 Probe 的烘焙射线数" if source_bake \
				else "每个采样点的烘焙射线数"
	var quality: OptionButton = ui.get("quality")
	if is_instance_valid(quality):
		quality.visible = prt_visible and not source_bake
	var refresh: Button = ui.get("refresh_button")
	if is_instance_valid(refresh):
		refresh.visible = prt_visible
	if not prt_visible:
		var chunk_row: HBoxContainer = ui.get("chunk_row")
		if is_instance_valid(chunk_row):
			chunk_row.visible = false
		return
	var baking := volume.is_baking()
	var refreshing := volume.is_refreshing()
	var cancel_requested := volume.is_bake_cancel_requested()
	var bake_button: Button = ui.get("bake_button")
	if is_instance_valid(bake_button):
		var default_bake_label := "分块烘焙 GI" if volume.chunked_baking else "烘焙 GI"
		if volume.uses_free_space_clv_bake():
			default_bake_label = "烘焙 GI"
		bake_button.text = "正在烘焙…" if baking else default_bake_label
		bake_button.disabled = baking or olv_busy
	var olv_button: Button = ui.get("olv_button")
	if is_instance_valid(olv_button):
		olv_button.text = "OLV 模型 / 手工修正"
		olv_button.disabled = baking or refreshing or olv_busy or not source_bake
	var cancel_button: Button = ui.get("cancel_button")
	if is_instance_valid(cancel_button):
		cancel_button.visible = baking or refreshing or olv_busy
		cancel_button.disabled = cancel_requested or not (baking or refreshing or olv_busy)
		cancel_button.text = "正在取消…" if cancel_requested else "取消"
	quality = ui.get("quality")
	if is_instance_valid(quality):
		quality.disabled = baking
	var chunk_row: HBoxContainer = ui.get("chunk_row")
	if is_instance_valid(chunk_row):
		chunk_row.visible = volume.chunked_baking and not volume.uses_free_space_clv_bake()
		var chunk_label := chunk_row.get_child(0) as Label
		if chunk_label != null:
			chunk_label.text = "Chunk X/Z · %.0f m" % volume.management_block_size
	var chunk_button: Button = ui.get("chunk_button")
	if is_instance_valid(chunk_button):
		chunk_button.disabled = baking or not volume.chunked_baking or volume.uses_free_space_clv_bake()
	refresh = ui.get("refresh_button")
	if is_instance_valid(refresh):
		refresh.visible = not volume.uses_free_space_clv_bake()
		refresh.disabled = baking or volume.uses_free_space_clv_bake()
		refresh.text = "重新更新" if refreshing else "更新采样点"

func _disconnect_status_callback(volume: FMagicGIVolume, callback: Callable) -> void:
	if is_instance_valid(volume) and volume.bake_status_changed.is_connected(callback):
		volume.bake_status_changed.disconnect(callback)

func _on_bake_pressed(volume: FMagicGIVolume, ui: Dictionary) -> void:
	if not is_instance_valid(volume) or volume.is_baking():
		return
	var info: Label = ui.get("info")
	if is_instance_valid(info):
		_update_status(volume, info, ui)
	var ok: bool = await volume.bake()
	if not is_instance_valid(volume):
		return
	if ok:
		EditorInterface.mark_scene_as_unsaved()
	if is_instance_valid(info):
		_update_status(volume, info, ui)
	EditorInterface.inspect_object(volume)

func _on_olv_toggled(value: bool, volume: FMagicGIVolume) -> void:
	if not is_instance_valid(volume): return
	var node := volume.ensure_olv_controller()
	undo_redo.create_action("切换 OLV 防漏光")
	undo_redo.add_do_property(node, "enabled", value)
	undo_redo.add_undo_property(node, "enabled", node.get("enabled"))
	undo_redo.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	EditorInterface.inspect_object(volume)

func _on_olv_update_pressed(volume: FMagicGIVolume, ui: Dictionary) -> void:
	if not is_instance_valid(volume) or not volume.has_bake() or volume.is_baking(): return
	var node := volume.ensure_olv_controller()
	EditorInterface.mark_scene_as_unsaved()
	_update_status(volume, ui.info, ui)
	if await node.call("update_labels"):
		EditorInterface.mark_scene_as_unsaved()

func _on_olv_bake_pressed(volume: FMagicGIVolume, _ui: Dictionary) -> void:
	if not is_instance_valid(volume): return
	var existed := volume.get_olv_controller() != null
	var node := volume.ensure_olv_controller()
	if not existed: EditorInterface.mark_scene_as_unsaved()
	EditorInterface.edit_node(node)

func _on_chunk_bake_pressed(volume: FMagicGIVolume, chunk_x: SpinBox,
		chunk_z: SpinBox, ui: Dictionary) -> void:
	if not is_instance_valid(volume) or volume.is_baking():
		return
	var info: Label = ui.get("info")
	var ok: bool = await volume.bake_chunk(roundi(chunk_x.value), roundi(chunk_z.value))
	if not is_instance_valid(volume):
		return
	if ok:
		EditorInterface.mark_scene_as_unsaved()
	if is_instance_valid(info):
		_update_status(volume, info, ui)
	EditorInterface.inspect_object(volume)
