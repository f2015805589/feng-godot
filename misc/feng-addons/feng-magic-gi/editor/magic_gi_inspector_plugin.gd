@tool
extends EditorInspectorPlugin
## Inspector for FMagicGIVolume: the bake button plus a status line.

const Volume = preload("../feng_magic_gi_volume.gd")
const Data = preload("../feng_magic_gi_data.gd")

var _baking := false

func _can_handle(object: Object) -> bool:
	return object is Volume

func _parse_begin(_object: Object) -> void:
	var volume := _object as Volume
	var container := VBoxContainer.new()
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var status_callback := Callable(self, "_update_status").bind(volume, info)
	volume.bake_status_changed.connect(status_callback)
	info.tree_exiting.connect(_disconnect_status_callback.bind(volume, status_callback), CONNECT_ONE_SHOT)
	_update_status(volume, info)
	container.add_child(info)
	var button := Button.new()
	button.text = "Bake PRT Transfer" if not _baking else "Baking..."
	button.disabled = _baking
	button.pressed.connect(_on_bake_pressed.bind(volume, button))
	container.add_child(button)
	var quality_label := Label.new()
	quality_label.text = "Bake quality (rays per point)"
	container.add_child(quality_label)
	var quality := OptionButton.new()
	quality.disabled = _baking
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
	quality.item_selected.connect(_on_quality_selected.bind(quality, volume, info))
	container.add_child(quality)
	var refresh := Button.new()
	refresh.text = "Refresh Surface Points"
	refresh.pressed.connect(volume.refresh_surface_points)
	container.add_child(refresh)
	add_custom_control(container)

func _on_quality_selected(index: int, quality: OptionButton, volume: FMagicGIVolume, info: Label) -> void:
	if not is_instance_valid(volume):
		return
	var samples: int = quality.get_item_id(index)
	if volume.bake_samples == samples:
		return
	volume.bake_samples = samples
	EditorInterface.mark_scene_as_unsaved()
	_update_status(volume, info)

func _update_status(volume: FMagicGIVolume, info: Label) -> void:
	if not is_instance_valid(volume) or not is_instance_valid(info):
		return
	if volume.has_bake():
		info.text = "%d surface samples baked with %d rays/point (randomized QMC sampler r%d, bake v%d)." % [
			volume.bake_data.probe_count(), volume.bake_data.bake_samples,
			Data.SAMPLER_REVISION, volume.bake_data.bake_version]
		if not volume.has_nonzero_indirect_transfer():
			info.text += "\n" + Volume.ZERO_TRANSFER_DIAGNOSTIC
	elif volume.has_usable_bake() and volume.needs_rebake():
		var details := "; ".join(volume.bake_staleness_reasons())
		info.text = "当前显示上次烘焙，仅供预览；场景或烘焙设置已变化，请重新 Bake。\n%d 个采样点，烘焙 %d rays/point，当前设置 %d rays/point。\n%s" % [
			volume.bake_data.probe_count(), volume.bake_data.bake_samples, volume.bake_samples, details]
	elif volume.bake_data != null and not volume.has_usable_bake():
		info.text = "Bake 数据无效或不完整，Magic GI 不会使用它。请重新 Bake。"
	elif volume.bake_data != null:
		info.text = "正在检查场景与上次 Bake 的匹配状态…"
	else:
		info.text = "No bake yet: %d surface points, %.2f m spacing, %d rays/point." % [
			volume.probe_count(), volume.probe_spacing, volume.bake_samples]

func _disconnect_status_callback(volume: FMagicGIVolume, callback: Callable) -> void:
	if is_instance_valid(volume) and volume.bake_status_changed.is_connected(callback):
		volume.bake_status_changed.disconnect(callback)

func _on_bake_pressed(volume: FMagicGIVolume, button: Button) -> void:
	if _baking:
		return
	_baking = true
	button.text = "Baking..."
	button.disabled = true
	# Async CPU path tracing yields in small probe batches. The inspector may be
	# rebuilt (or the volume deleted) while it runs, so both refs are re-checked.
	var ok: bool = await volume.bake()
	_baking = false
	if is_instance_valid(button):
		button.text = "Bake PRT Transfer"
		button.disabled = false
	if not ok:
		push_warning("FMagicGI: bake did not run (volume not in tree?).")
	if is_instance_valid(volume):
		if ok:
			EditorInterface.mark_scene_as_unsaved()
		EditorInterface.inspect_object(volume)
