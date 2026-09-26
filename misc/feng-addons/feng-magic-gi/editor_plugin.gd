@tool
extends EditorPlugin
## Feng Magic GI: baked SH probes for the FRP pipeline.
## FMagicGIVolume registers itself through class_name; this plugin only adds
## the inspector's bake button.

const InspectorPlugin = preload("editor/magic_gi_inspector_plugin.gd")

var _inspector_plugin

func _enter_tree() -> void:
	_inspector_plugin = InspectorPlugin.new()
	add_inspector_plugin(_inspector_plugin)

func _exit_tree() -> void:
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
