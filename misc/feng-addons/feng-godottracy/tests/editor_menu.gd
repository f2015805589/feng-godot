@tool
extends EditorPlugin
## Enabled only by misc/scripts/test_feng_godottracy.py in an isolated fixture.
##
## Checks the FengGodotTracy script API and the Debug menu item against the
## running engine, then quits the editor with the result. It never starts the
## profiler.

var _failures: Array[String] = []


func _enter_tree() -> void:
	call_deferred("run")


func run() -> void:
	await get_tree().process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame

	if not Engine.has_singleton("FengGodotTracy"):
		_fail("the engine did not register the FengGodotTracy singleton")
		_finish()
		return
	var tracy: Variant = Engine.get_singleton("FengGodotTracy")

	var status: Variant = tracy.call("get_status")
	_check(typeof(status) == TYPE_DICTIONARY, "get_status() did not return a dictionary")
	if typeof(status) == TYPE_DICTIONARY:
		_check(bool(status.get("available", false)), "the client reports itself as unavailable")
		_check(int(status.get("protocol", 0)) == 69, "unexpected protocol version %s" % status.get("protocol", 0))
		_check(int(status.get("port", 0)) == 8086, "unexpected port %s" % status.get("port", 0))
		_check(not str(status.get("version", "")).is_empty(), "the client version is empty")
		_check(not bool(status.get("connected", true)), "a profiler is unexpectedly connected")

	# Markers must be callable from scripts.
	tracy.call("set_thread_name", "feng-godottracy test")
	tracy.call("message", "feng-godottracy test marker")
	tracy.call("message_colored", "feng-godottracy test marker", Color(0.2, 0.6, 1.0))
	tracy.call("plot", "feng-godottracy/test", 1.0)
	tracy.call("frame_mark", "feng-godottracy test")

	# Zone pairs must nest and close.
	_check(int(tracy.call("get_zone_depth")) == 0, "a zone was left open")
	tracy.call("begin_zone", "outer")
	tracy.call("begin_zone", "inner")
	_check(int(tracy.call("get_zone_depth")) == 2, "begin_zone() did not nest")
	tracy.call("end_zone")
	_check(int(tracy.call("get_zone_depth")) == 1, "end_zone() did not close the inner zone")
	tracy.call("end_all_zones")
	_check(int(tracy.call("get_zone_depth")) == 0, "end_all_zones() left a zone open")

	# The plugin has to have added its item to the editor's Debug menu, and
	# registered the setting that selects the profiler.
	var menu: PopupMenu = _debug_menu()
	_check(menu != null, "the editor's Debug menu was not found")
	if menu != null:
		var index := -1
		for item in menu.item_count:
			if menu.get_item_text(item) == "Tracy Profiler":
				index = item
		_check(index != -1, "the Debug menu ('%s') has no Tracy Profiler item" % menu.name)
		print("profiler menu item: '%s' menu, index %d of %d" % [menu.name, index, menu.item_count])
	_check(
		EditorInterface.get_editor_settings().has_setting("tracy/profiler/executable_path"),
		"the plugin did not register tracy/profiler/executable_path"
	)
	# One click has to be enough: the profiler ships in the addon's bin folder.
	var installed := ProjectSettings.globalize_path("res://addons/feng-godottracy/bin/tracy-profiler.exe")
	_check(FileAccess.file_exists(installed), "no profiler at " + installed + ", the menu would download it first")

	_finish()


## The Debug popup of the editor's main menu bar, found independently of the
## plugin to check where the item landed.
func _debug_menu() -> PopupMenu:
	var menu_bar: MenuBar = _menu_bar(EditorInterface.get_base_control())
	if menu_bar == null:
		return null
	var menus: Array[PopupMenu] = []
	for child in menu_bar.get_children():
		if child is PopupMenu:
			menus.append(child)
	return menus[2] if menus.size() > 2 else null


func _menu_bar(p_node: Node) -> MenuBar:
	for child in p_node.get_children():
		if child is MenuBar and child.get_theme_type_variation() == "MainMenuBar":
			return child
		var found: MenuBar = _menu_bar(child)
		if found != null:
			return found
	return null


func _check(p_condition: bool, p_message: String) -> void:
	if not p_condition:
		_failures.append(p_message)


func _fail(p_message: String) -> void:
	_failures.append(p_message)


func _finish() -> void:
	if _failures.is_empty():
		print("PASS feng-godottracy API, script zones and profiler menu item")
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error("feng-godottracy: " + failure)
	get_tree().quit(1)
