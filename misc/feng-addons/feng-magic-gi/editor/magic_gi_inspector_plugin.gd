@tool
extends EditorInspectorPlugin
## Inspector for FMagicGIVolume: bake controls and current progress.

const Volume = preload("../feng_magic_gi_volume.gd")

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
	cancel_button.pressed.connect(volume.cancel_bake)
	bake_row.add_child(cancel_button)
	ui["cancel_button"] = cancel_button
	container.add_child(bake_row)

	var olv_row := HBoxContainer.new()
	var olv_button := Button.new()
	olv_button.text = "打开 OLV 子节点"
	olv_button.tooltip_text = "OLV 节点提供开关、模型更新和单个/批量 Probe 标签编辑。"
	olv_button.pressed.connect(_on_olv_bake_pressed.bind(volume, ui))
	olv_row.add_child(olv_button)
	ui["olv_row"] = olv_row
	ui["olv_button"] = olv_button
	container.add_child(olv_row)

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
	_update_status(volume, info, ui)
	add_custom_control(container)

func _make_chunk_coordinate() -> SpinBox:
	var coordinate := SpinBox.new()
	coordinate.min_value = -1000000.0
	coordinate.max_value = 1000000.0
	coordinate.step = 1.0
	coordinate.rounded = true
	coordinate.custom_minimum_size.x = 84.0
	return coordinate

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
	elif refreshing:
		info.text = "正在更新采样点…"
		if is_instance_valid(progress): progress.indeterminate = true
	elif volume.has_usable_bake():
		info.text = "场景已变化，请重新烘焙" if volume.needs_rebake() else "烘焙完成"
	else:
		info.text = "尚未烘焙"
	if is_instance_valid(progress): progress.visible = info.visible and (baking or refreshing)
	_update_controls(volume, ui)

func _update_controls(volume: FMagicGIVolume, ui: Dictionary) -> void:
	var prt_visible := not volume.is_surfel_mode()
	var source_bake := volume.uses_free_space_clv_bake()
	var bake_row: HBoxContainer = ui.get("bake_row")
	if is_instance_valid(bake_row):
		bake_row.visible = prt_visible
	var olv_row: HBoxContainer = ui.get("olv_row")
	if is_instance_valid(olv_row):
		olv_row.visible = prt_visible and source_bake
	var quality_label: Label = ui.get("quality_label")
	if is_instance_valid(quality_label):
		quality_label.visible = prt_visible
		quality_label.text = "每个源 Probe 的烘焙射线数" if source_bake \
				else "每个采样点的烘焙射线数"
	var quality: OptionButton = ui.get("quality")
	if is_instance_valid(quality):
		quality.visible = prt_visible
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
		bake_button.disabled = baking
	var olv_button: Button = ui.get("olv_button")
	if is_instance_valid(olv_button):
		olv_button.text = "打开 OLV 子节点"
		olv_button.disabled = baking or refreshing or not source_bake
	var cancel_button: Button = ui.get("cancel_button")
	if is_instance_valid(cancel_button):
		cancel_button.visible = baking or refreshing
		cancel_button.disabled = cancel_requested or not (baking or refreshing)
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
