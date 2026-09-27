@tool
extends EditorInspectorPlugin
## Inspector for FMagicGIVolume: the bake button plus a status line.

const Volume = preload("../feng_magic_gi_volume.gd")
const Baker = preload("../feng_magic_gi_baker.gd")

var _baking := false

func _can_handle(object: Object) -> bool:
	return object is Volume

func _parse_begin(_object: Object) -> void:
	var volume := _object as Volume
	var container := VBoxContainer.new()
	var button := Button.new()
	button.text = "Bake PRT Transfer" if not _baking else "Baking..."
	button.disabled = _baking
	button.pressed.connect(_on_bake_pressed.bind(volume, button))
	container.add_child(button)
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	_update_status(volume, info)
	container.add_child(info)
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
	if volume.has_bake():
		info.text = "%d surface samples baked with %d rays/point (randomized QMC sampler r%d, bake v%d)." % [
			volume.bake_data.probe_count(), volume.bake_data.bake_samples,
			Baker.SAMPLER_REVISION, volume.bake_data.bake_version]
		if not volume.has_nonzero_indirect_transfer():
			info.text += "\n" + Volume.ZERO_TRANSFER_DIAGNOSTIC
	elif volume.bake_data != null:
		var details := "; ".join(volume.bake_staleness_reasons())
		info.text = "Stale bake: %d samples at %d rays/point; selected quality requests %d rays/point. Re-bake to update.\n%s" % [
			volume.bake_data.probe_count(), volume.bake_data.bake_samples, volume.bake_samples, details]
	else:
		info.text = "No bake yet: %d surface points, %.2f m spacing, %d rays/point." % [
			volume.probe_count(), volume.probe_spacing, volume.bake_samples]

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
