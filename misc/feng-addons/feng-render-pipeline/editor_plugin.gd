@tool
extends EditorPlugin
## Adds an "Add Pass from Library" menu that instantiates library pass
## templates into the selected FengRenderer.

const Renderer = preload("renderer.gd")
const CompositorScript = preload("compositor.gd")
const PassBase = preload("passes/pass_base.gd")

var _menu: PopupMenu
var _library_paths: Array[String] = []

func _enter_tree() -> void:
	# add_tool_submenu_item() reparents the popup into the editor tool menu and
	# requires it to be parentless; adding it as a child first trips the
	# ERR_FAIL_COND in EditorNode::add_tool_submenu_item.
	if _menu != null:
		if _menu.get_parent() != null:
			_menu.get_parent().remove_child(_menu)
		_menu.free()
	_menu = PopupMenu.new()
	_menu.name = "FengRenderPipeline"
	_menu.id_pressed.connect(_on_library_item)
	add_tool_submenu_item("Add Pass from Library", _menu)
	_refresh_library()

func _exit_tree() -> void:
	if _menu != null:
		# The menu is parented to the editor tool menu, not to this plugin.
		# remove_tool_menu_item() detaches and deletes it; queue_free() alone
		# would leave a dangling submenu entry behind.
		remove_tool_menu_item("Add Pass from Library")
		_menu = null

func _refresh_library() -> void:
	_menu.clear()
	_library_paths.clear()
	var dir := DirAccess.open("res://addons/feng-render-pipeline/library")
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			var sub := DirAccess.open("res://addons/feng-render-pipeline/library/" + entry)
			if sub != null:
				sub.list_dir_begin()
				var file := sub.get_next()
				while file != "":
					if not sub.current_is_dir() and file.ends_with(".tres"):
						var path := "res://addons/feng-render-pipeline/library/%s/%s" % [entry, file]
						_menu.add_item(entry.capitalize(), _library_paths.size())
						_library_paths.append(path)
					file = sub.get_next()
				sub.list_dir_end()
		entry = dir.get_next()
	dir.list_dir_end()

func _on_library_item(id: int) -> void:
	if id < 0 or id >= _library_paths.size():
		return
	var template = load(_library_paths[id])
	if template == null:
		push_error("FengRenderPipeline: cannot load library template %s" % _library_paths[id])
		return
	var renderer = _find_selected_renderer()
	if renderer == null:
		push_error("FengRenderPipeline: select a FengRenderer resource in the inspector first.")
		return
	var instance = template.duplicate()
	renderer.passes.append(instance)
	# Mark the library path as synced so the auto-sync does not add a second
	# copy of the same pass.
	renderer.mark_library_pass(_library_paths[id])
	EditorInterface.get_inspector().refresh()

func _find_selected_renderer():
	var selection := EditorInterface.get_selection()
	if selection == null:
		return null
	for node in selection.get_selected_nodes():
		var script: Script = node.get_script()
		if script == Renderer:
			return node
		if script == CompositorScript:
			return node.renderer
	return null