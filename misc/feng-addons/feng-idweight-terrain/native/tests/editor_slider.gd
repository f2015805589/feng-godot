@tool
extends EditorPlugin
## Enabled only by test_feng_addons.py in an isolated editor fixture.

const Settings = preload("res://addons/feng-idweight-terrain/src/tool_settings.gd")
var debug := 0
var last_setting
var events := 0

func _enter_tree() -> void:
	call_deferred("run")

func run() -> void:
	await get_tree().process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	var settings := Settings.new()
	settings.plugin = self
	var row := HBoxContainer.new()
	settings.add_setting({"name":"slope_blend_sharpness", "type":Settings.SettingType.SLIDER, "list":row, "default":1000.0, "range":Vector3(0,1000,1), "flags":Settings.NO_SAVE | Settings.NO_LABEL})
	EditorInterface.get_base_control().add_child(row)
	settings.setting_changed.connect(func(control):
		last_setting = control
		events += 1)
	var slider: Range = settings.settings["slope_blend_sharpness"]
	slider.value = 100.0
	var passed: bool = last_setting == slider and events == 1
	slider.set_value_no_signal(250.0)
	passed = passed and events == 1 and slider.value == 250.0
	row.free()
	settings.free()
	if passed:
		print("PASS real slope slider identity and silent selection synchronization")
	else:
		push_error("Slope slider lost its control identity or emitted during selection synchronization")
	get_tree().quit(0 if passed else 1)
