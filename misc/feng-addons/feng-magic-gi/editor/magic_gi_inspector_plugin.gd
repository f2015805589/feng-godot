@tool
extends EditorInspectorPlugin
## Inspector for FMagicGIVolume: bake controls and streamed/legacy status.

const Volume = preload("../feng_magic_gi_volume.gd")
const Data = preload("../feng_magic_gi_data.gd")
const Runtime = preload("../feng_magic_gi_runtime.gd")

func _can_handle(object: Object) -> bool:
	return object is Volume

func _parse_begin(_object: Object) -> void:
	var volume := _object as Volume
	var container := VBoxContainer.new()
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var ui := {"info": info}
	var status_callback := Callable(self, "_update_status").bind(volume, info, ui)
	volume.bake_status_changed.connect(status_callback)
	info.tree_exiting.connect(_disconnect_status_callback.bind(volume, status_callback), CONNECT_ONE_SHOT)
	container.add_child(info)

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

	var chunk_row := HBoxContainer.new()
	var chunk_label := Label.new()
	chunk_label.text = "Chunk X/Z"
	chunk_row.add_child(chunk_label)
	var chunk_x := _make_chunk_coordinate()
	chunk_row.add_child(chunk_x)
	var chunk_z := _make_chunk_coordinate()
	chunk_row.add_child(chunk_z)
	var chunk_button := Button.new()
	chunk_button.text = "Bake Selected Block"
	chunk_button.pressed.connect(_on_chunk_bake_pressed.bind(volume, chunk_x, chunk_z, ui))
	chunk_row.add_child(chunk_button)
	container.add_child(chunk_row)
	ui["chunk_row"] = chunk_row
	ui["chunk_button"] = chunk_button

	var quality_label := Label.new()
	quality_label.text = "Bake quality (rays per point)"
	container.add_child(quality_label)
	ui["quality_label"] = quality_label
	var quality := OptionButton.new()
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
	refresh.text = "Refresh Surface Points"
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
	if volume.is_surfel_mode():
		info.text = "Surfel MagicGI: realtime surface cache"
		_update_controls(volume, ui)
		return
	if volume.bake_manifest != null and is_instance_valid(volume.bake_manifest):
		var stream: Dictionary = Runtime.streaming_status(volume)
		var progress: Vector2i = volume.streamed_bake_progress()
		var page_count := volume.bake_manifest.get_page_count()
		var cpu_current := int(stream.get("cpu_committed_bytes", stream.get("cpu_resident_bytes", 0)))
		var gpu_current := int(stream.get("gpu_committed_bytes", stream.get("gpu_resident_bytes", 0)))
		info.text = "分块 Bake：%d 个管理页，%d 个烘焙点；已驻留 %d，加载中 %d。CPU %.1f / %.0f MiB；GPU 估算 %.1f / %.0f MiB；上传预算 %.0f MiB/帧。" % [
			page_count, volume.saved_probe_count(), int(stream.get("resident_pages", 0)), int(stream.get("loading_pages", 0)),
			float(cpu_current) / 1048576.0, float(volume.cpu_resident_budget_bytes) / 1048576.0,
			float(gpu_current) / 1048576.0, float(volume.gpu_resident_budget_bytes) / 1048576.0,
			float(volume.upload_budget_bytes_per_frame) / 1048576.0]
		if volume.is_baking():
			info.text += "\n烘焙进度：%d / %d 页。" % [progress.x, progress.y]
		if volume.needs_rebake():
			info.text += "\n当前场景或设置与这份分块 Bake 不匹配；仍保留可用的旧结果。"
		var stream_warning := String(stream.get("warning", ""))
		if not stream_warning.is_empty():
			info.text += "\n" + stream_warning
	elif volume.has_bake() and volume.bake_data != null:
		info.text = "%d surface samples baked with %d rays/point (randomized QMC sampler r%d, bake v%d)." % [
			volume.bake_data.probe_count(), volume.bake_data.bake_samples,
			Data.SAMPLER_REVISION, volume.bake_data.bake_version]
		if not volume.has_nonzero_indirect_transfer():
			info.text += "\n" + Volume.ZERO_TRANSFER_DIAGNOSTIC
	elif volume.bake_data != null and volume.has_usable_bake() and volume.needs_rebake():
		var details := "; ".join(volume.bake_staleness_reasons())
		info.text = "当前显示上次烘焙，仅供预览；场景或烘焙设置已变化，请重新 Bake。\n%d 个采样点，烘焙 %d rays/point，当前设置 %d rays/point。\n%s" % [
			volume.bake_data.probe_count(), volume.bake_data.bake_samples, volume.bake_samples, details]
	elif volume.bake_data != null and not volume.has_usable_bake():
		info.text = "Bake 数据无效或不完整，Magic GI 不会使用它。请重新 Bake。"
	elif volume.bake_data != null:
		info.text = "正在检查场景与上次 Bake 的匹配状态…"
	else:
		var point_count := volume.candidate_probe_count() if volume.candidate_probe_count() > 0 else volume.probe_count()
		info.text = "No bake yet: %d surface points, %.2f m spacing, %d rays/point." % [
			point_count, volume.probe_spacing, volume.bake_samples]
	if volume.is_refreshing():
		info.text += "\n" + volume.surface_refresh_progress() + "."
	elif volume.candidate_probe_count() > 0:
		info.text += "\n已采集 %d 个候选表面点%s。" % [volume.candidate_probe_count(),
			"（设置变化后已过期）" if not volume.is_candidate_layout_current() else ""]
	_update_controls(volume, ui)

func _update_controls(volume: FMagicGIVolume, ui: Dictionary) -> void:
	var prt_visible := not volume.is_surfel_mode()
	var bake_row: HBoxContainer = ui.get("bake_row")
	if is_instance_valid(bake_row):
		bake_row.visible = prt_visible
	var quality_label: Label = ui.get("quality_label")
	if is_instance_valid(quality_label):
		quality_label.visible = prt_visible
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
		bake_button.text = "Baking..." if baking else ("Bake Streamed PRT" if volume.chunked_baking else "Bake PRT Transfer")
		bake_button.disabled = baking
	var cancel_button: Button = ui.get("cancel_button")
	if is_instance_valid(cancel_button):
		cancel_button.visible = baking or refreshing
		cancel_button.disabled = cancel_requested or not (baking or refreshing)
		cancel_button.text = "Canceling..." if cancel_requested else ("Cancel Refresh" if refreshing and not baking else "Cancel Bake")
	quality = ui.get("quality")
	if is_instance_valid(quality):
		quality.disabled = baking
	var chunk_row: HBoxContainer = ui.get("chunk_row")
	if is_instance_valid(chunk_row):
		chunk_row.visible = volume.chunked_baking
		var chunk_label := chunk_row.get_child(0) as Label
		if chunk_label != null:
			chunk_label.text = "Chunk X/Z · %.0f m" % volume.management_block_size
	var chunk_button: Button = ui.get("chunk_button")
	if is_instance_valid(chunk_button):
		chunk_button.disabled = baking or not volume.chunked_baking
	refresh = ui.get("refresh_button")
	if is_instance_valid(refresh):
		refresh.disabled = baking
		refresh.text = "Refresh Again" if refreshing else "Refresh Surface Points"

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
