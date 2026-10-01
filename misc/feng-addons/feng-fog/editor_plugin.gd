@tool
extends EditorPlugin
## Feng Fog: Unreal-style exponential height fog for the FRP pipeline.
## FengHeightFog registers itself through class_name; this plugin only wires the
## editor's 3D viewports into the runtime so fog renders while editing.

const Runtime = preload("feng_fog_runtime.gd")

var _registered_viewports: Array[Viewport] = []

func _enter_tree() -> void:
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
