@tool
class_name FengRendererInspectorPlugin
extends EditorInspectorPlugin
## Inspector plugin for rendering FRP schedule warnings on FengRenderer resources.

var _renderer_script: Script

func _init(renderer_script: Script) -> void:
	_renderer_script = renderer_script

func _can_handle(object: Object) -> bool:
	return object != null and object.get_script() == _renderer_script

func _parse_begin(object: Object) -> void:
	if object == null or not object.has_method("get_configuration_warnings"):
		return
	var warnings: PackedStringArray = object.call("get_configuration_warnings")
	if warnings.is_empty():
		return
	var warning_panel := VBoxContainer.new()
	warning_panel.name = "FengRendererConfigurationWarnings"
	var warning_heading := Label.new()
	warning_heading.text = "FRP schedule warnings"
	warning_heading.add_theme_color_override("font_color", Color(1.0, 0.76, 0.34))
	warning_panel.add_child(warning_heading)
	for warning in warnings:
		var label := Label.new()
		label.text = "• " + warning
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warning_panel.add_child(label)
	add_custom_control(warning_panel)
