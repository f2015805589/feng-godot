@tool
extends EditorInspectorPlugin
## Inspector for FMagicGIVolume: the bake button plus a status line.

const Volume = preload("../feng_magic_gi_volume.gd")

var _baking := false

func _can_handle(object: Object) -> bool:
	return object is Volume

func _parse_begin(_object: Object) -> void:
	var volume := _object as Volume
	var container := VBoxContainer.new()
	var button := Button.new()
	button.text = "Bake Probes" if not _baking else "Baking..."
	button.disabled = _baking
	button.pressed.connect(_on_bake_pressed.bind(volume, button))
	container.add_child(button)
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if volume.has_bake():
		info.text = "%d/%d probes baked (v%d)." % [
			volume.bake_data.live_count(), volume.probe_count(),
			volume.bake_data.bake_version]
	elif volume.bake_data != null:
		info.text = "Stale bake (%d x %d x %d) - re-bake for %d probes at %d px/face." % [
			volume.bake_data.grid_dims.x, volume.bake_data.grid_dims.y,
			volume.bake_data.grid_dims.z, volume.probe_count(), volume.bake_resolution]
	else:
		info.text = "No bake yet: %d probes at %d px/face." % [
			volume.probe_count(), volume.bake_resolution]
	container.add_child(info)
	add_custom_control(container)

func _on_bake_pressed(volume: FMagicGIVolume, button: Button) -> void:
	if _baking:
		return
	_baking = true
	button.text = "Baking..."
	button.disabled = true
	# Async: the bake awaits one rendered frame per face. The inspector may be
	# rebuilt (or the volume deleted) while it runs, so both refs are re-checked.
	var ok: bool = await volume.bake()
	_baking = false
	if is_instance_valid(button):
		button.text = "Bake Probes"
		button.disabled = false
	if not ok:
		push_warning("FMagicGI: bake did not run (volume not in tree?).")
	if is_instance_valid(volume):
		EditorInterface.inspect_object(volume)
