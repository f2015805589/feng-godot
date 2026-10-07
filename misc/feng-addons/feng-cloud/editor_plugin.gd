@tool
extends EditorPlugin
## Registers the editor's 3D viewports with the shared per-world target registry.
## FengVolumetricCloud itself is exposed through its class_name.

const Runtime = preload("feng_cloud_runtime.gd")
const CloudExportPlugin = preload("feng_cloud_export_plugin.gd")

var _registered_viewports: Array[Viewport] = []
var _cloud_export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_cloud_export_plugin = CloudExportPlugin.new()
	add_export_plugin(_cloud_export_plugin)
	for index in range(4):
		var viewport := EditorInterface.get_editor_viewport_3d(index)
		if viewport == null:
			continue
		_registered_viewports.append(viewport)
		Runtime.register_viewport(viewport, self)


func _exit_tree() -> void:
	if _cloud_export_plugin != null:
		remove_export_plugin(_cloud_export_plugin)
		_cloud_export_plugin = null
	for viewport in _registered_viewports:
		if is_instance_valid(viewport):
			Runtime.unregister_viewport(viewport, self)
	_registered_viewports.clear()
