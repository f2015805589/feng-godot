@tool
extends EditorPlugin
## Feng Magic GI: surface PRT transport and dynamic lighting for the FRP pipeline.
## FMagicGIVolume registers itself through class_name; this plugin only adds
## the inspector's bake button.

const InspectorPlugin = preload("editor/magic_gi_inspector_plugin.gd")
const Runtime = preload("feng_magic_gi_runtime.gd")

var _inspector_plugin
var _registered_viewports: Array[Viewport] = []

func _enter_tree() -> void:
	_inspector_plugin = InspectorPlugin.new()
	add_inspector_plugin(_inspector_plugin)
	for i in 4:
		var viewport := EditorInterface.get_editor_viewport_3d(i)
		if viewport != null:
			_registered_viewports.append(viewport)
			Runtime.register_viewport(viewport, self)

func _exit_tree() -> void:
	for viewport in _registered_viewports:
		if is_instance_valid(viewport):
			Runtime.unregister_viewport(viewport, self)
	_registered_viewports.clear()
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
