@tool
extends EditorInspectorPlugin
## Inspector for FMagicGIVolume: the bake button plus a status line.

const Volume = preload("../feng_magic_gi_volume.gd")

var _baking := false

func _can_handle(object: Object) -> bool:
	return object is Volume

func _parse_begin(_object: Object) -> void:
	var volume: FMagicGIVolume = _object
	var container := VBoxContainer.new()
	var button := Button.new()
	button.text = "Bake Probes" if not _baking else "Baking..."
	button.disabled = _baking
	button.pressed.connect(_on_bake_pressed.bind(volume, button))
	container.add_child(button)
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if volume.has_bake():
		info.text = "%d probes baked (v%d)." % [
			volume.probe_count(), volume.bake_data.bake_version]
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
	# Async: the bake awaits one rendered frame per face.
	var ok: bool = await volume.bake()
	_baking = false
	button.text = "Bake Probes"
	button.disabled = false
	if not ok:
		push_warning("FMagicGI: bake did not run (volume not in tree?).")
	EditorInterface.inspect_object(volume)
