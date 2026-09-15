@tool
extends EditorPlugin

## Starts the Tracy profiler from the editor's **Debug** menu, next to the
## deployment and debug-draw options. One click, no questions asked.
##
## The profiler lives in this addon's `bin` folder, so it is simply started from
## there and nothing has to be configured. Editor Settings > Tracy > Profiler >
## Executable Path, `FENG_TRACY_PATH`, a copy next to the editor and the
## downloads folder are only consulted when that file is missing, and a missing
## profiler is downloaded once from the matching Tracy release.
##
## If the Debug menu cannot be found (for example with a collapsed main menu),
## the same action is added as a toolbar button instead.
##
## The engine module that provides the client is optional, so the singleton is
## looked up at runtime. Naming `FengGodotTracy` directly would stop this script
## from parsing in an editor that was built without the module.

const SETTING_PATH := "tracy/profiler/executable_path"
const ENV_PATH := "FENG_TRACY_PATH"
const EXECUTABLE := "tracy-profiler.exe"
## Folder of this addon, next to src.
const BIN_DIR := "bin"
const RELEASES_URL := "https://github.com/wolfpld/tracy/releases"
## Used when the editor has no Tracy client to ask for its version.
const FALLBACK_VERSION := "0.11.1"

const MENU_LABEL := "Tracy Profiler"
## Private id: the Debug menu ignores ids it does not know.
const MENU_ID := 0x7F700001
## The main menu is named after its translated title.
const DEBUG_MENU_NAME := "Debug"
## Menu order of this engine: Scene, Project, Debug, Editor, Help.
const DEBUG_MENU_INDEX := 2

var _debug_menu: PopupMenu
var _button: Button
var _downloading := false


func _enter_tree() -> void:
	_configure_setting()

	_debug_menu = _find_debug_menu()
	if _debug_menu != null:
		if _debug_menu.item_count > 0:
			_debug_menu.add_separator()
		_debug_menu.add_item(MENU_LABEL, MENU_ID)
		_debug_menu.id_pressed.connect(_on_menu_id_pressed)
		return

	# Collapsed or unknown main menu: keep the profiler reachable from the
	# toolbar instead.
	push_warning("feng-godottracy: the Debug menu was not found, the profiler is in the toolbar instead.")
	_button = Button.new()
	_button.text = "Tracy"
	_button.icon = EditorInterface.get_base_control().get_theme_icon("Time", "EditorIcons")
	_button.flat = true
	_button.tooltip_text = "Launch the Tracy profiler."
	_button.pressed.connect(_launch_or_install)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, _button)


func _exit_tree() -> void:
	if _debug_menu != null and is_instance_valid(_debug_menu):
		if _debug_menu.id_pressed.is_connected(_on_menu_id_pressed):
			_debug_menu.id_pressed.disconnect(_on_menu_id_pressed)
		var index := _debug_menu.get_item_index(MENU_ID)
		if index > 0 and _debug_menu.is_item_separator(index - 1):
			_debug_menu.remove_item(index - 1)
		index = _debug_menu.get_item_index(MENU_ID)
		if index != -1:
			_debug_menu.remove_item(index)
	_debug_menu = null
	if is_instance_valid(_button):
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, _button)
		_button.queue_free()
	_button = null


func _on_menu_id_pressed(p_id: int) -> void:
	if p_id == MENU_ID:
		_launch_or_install()


## Starts the profiler, installing it next to the editor first if needed.
func _launch_or_install() -> void:
	var path := _profiler_path()
	if not path.is_empty():
		_launch(path)
		return
	_download_profiler()


func _configure_setting() -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(SETTING_PATH):
		settings.set_setting(SETTING_PATH, "")
	settings.add_property_info({
		"name": SETTING_PATH,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "*.exe" if OS.get_name() == "Windows" else "*",
	})
	settings.set_basic(SETTING_PATH, true)


## The profiler executable, or an empty string when it has to be installed.
func _profiler_path() -> String:
	var settings := EditorInterface.get_editor_settings()
	if settings.has_setting(SETTING_PATH):
		var stored := str(settings.get_setting(SETTING_PATH))
		if not stored.is_empty() and FileAccess.file_exists(stored):
			return stored
	if FileAccess.file_exists(_installed_path()):
		return _installed_path()
	var from_env := OS.get_environment(ENV_PATH)
	if not from_env.is_empty():
		var candidate := from_env.path_join(EXECUTABLE) if DirAccess.dir_exists_absolute(from_env) else from_env
		if FileAccess.file_exists(candidate):
			return candidate
	var beside_editor := OS.get_executable_path().get_base_dir().path_join(EXECUTABLE)
	if FileAccess.file_exists(beside_editor):
		return beside_editor
	var downloads := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if FileAccess.file_exists(downloads.path_join(EXECUTABLE)):
		return downloads.path_join(EXECUTABLE)
	# Tracy releases unpack into a versioned folder inside the downloads folder.
	var dir := DirAccess.open(downloads)
	if dir != null:
		for name in dir.get_directories():
			if not name.begins_with("Tracy"):
				continue
			var nested := downloads.path_join(name).path_join(EXECUTABLE)
			if FileAccess.file_exists(nested):
				return nested
	return ""


## The profiler ships in this addon's bin folder.
func _installed_path() -> String:
	var script_path: String = get_script().resource_path
	var addon_dir := script_path.get_base_dir().get_base_dir()
	return ProjectSettings.globalize_path(addon_dir.path_join(BIN_DIR).path_join(EXECUTABLE))


func _client_version() -> String:
	if Engine.has_singleton("FengGodotTracy"):
		var version := str(Engine.get_singleton("FengGodotTracy").call("get_version"))
		if not version.is_empty():
			return version
	return FALLBACK_VERSION


func _download_profiler() -> void:
	if _downloading:
		return
	if not _ensure_bin_dir():
		_warning("Could not create " + _installed_path().get_base_dir() + ".")
		return
	_downloading = true
	var version := _client_version()
	var url := "%s/download/v%s/windows-%s.zip" % [RELEASES_URL, version, version]
	_status("Downloading the Tracy profiler %s ..." % version)

	var request := HTTPRequest.new()
	request.use_threads = true
	request.download_file = _installed_path().get_basename() + ".zip"
	request.request_completed.connect(_on_download_completed.bind(request))
	add_child(request)
	var err := request.request(url)
	if err != OK:
		request.queue_free()
		_downloading = false
		_warning("Could not start the download of %s (%s)." % [url, error_string(err)])


## Keeps the downloaded profiler out of the project's resource scan, like the
## native addons keep their libraries out of it.
func _ensure_bin_dir() -> bool:
	var dir_path := _installed_path().get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path) and DirAccess.make_dir_recursive_absolute(dir_path) != OK:
		return false
	var gdignore := dir_path.path_join(".gdignore")
	if not FileAccess.file_exists(gdignore):
		var file := FileAccess.open(gdignore, FileAccess.WRITE)
		if file != null:
			file.store_line("// The Tracy profiler executable. Not part of the Godot project.")
	return true


func _on_download_completed(p_result: int, p_code: int, _p_headers: PackedStringArray, _p_body: PackedByteArray, p_request: HTTPRequest) -> void:
	p_request.queue_free()
	_downloading = false
	var zip_path := _installed_path().get_basename() + ".zip"
	if p_result != HTTPRequest.RESULT_SUCCESS or p_code != 200:
		DirAccess.remove_absolute(zip_path)
		_warning("Could not download the Tracy profiler (result %d, HTTP %d). Get it from %s" % [p_result, p_code, RELEASES_URL])
		return
	var data := _read_profiler(zip_path)
	DirAccess.remove_absolute(zip_path)
	if data.is_empty():
		_warning("The downloaded archive does not contain " + EXECUTABLE + ". Get it from " + RELEASES_URL + ".")
		return
	var file := FileAccess.open(_installed_path(), FileAccess.WRITE)
	if file == null:
		_warning("Could not write " + _installed_path() + ".")
		return
	file.store_buffer(data)
	file.close()
	_ensure_bin_dir()
	_status("Tracy profiler installed in the feng-godottracy addon.")
	_launch(_installed_path())


func _read_profiler(p_zip_path: String) -> PackedByteArray:
	var reader := ZIPReader.new()
	if reader.open(p_zip_path) != OK:
		return PackedByteArray()
	for path in reader.get_files():
		if path.get_file() == EXECUTABLE:
			var data := reader.read_file(path)
			reader.close()
			return data
	reader.close()
	return PackedByteArray()


func _launch(p_path: String) -> void:
	if OS.create_process(p_path, PackedStringArray()) <= 0:
		_warning("Could not start " + p_path + ".")
		return
	if Engine.has_singleton("FengGodotTracy") and bool(Engine.get_singleton("FengGodotTracy").call("is_available")):
		_status("Tracy profiler started. Connect to this editor in its window.")
	else:
		_warning("Tracy profiler started, but this editor has no Tracy client. Rebuild with module_feng_godottracy_enabled=yes to profile it.")


func _status(p_message: String) -> void:
	EditorInterface.get_editor_toaster().push_toast(p_message)


func _warning(p_message: String) -> void:
	EditorInterface.get_editor_toaster().push_toast(p_message, EditorToaster.SEVERITY_WARNING)


## The Debug popup of the editor's main menu bar.
func _find_debug_menu() -> PopupMenu:
	var menu_bar := _find_menu_bar(EditorInterface.get_base_control())
	if menu_bar == null:
		return null
	var menus: Array[PopupMenu] = []
	for child in menu_bar.get_children():
		if child is PopupMenu:
			menus.append(child)
	var names := [DEBUG_MENU_NAME, str(TranslationServer.translate(DEBUG_MENU_NAME))]
	for menu in menus:
		if names.has(str(menu.name)):
			return menu
	if menus.size() > DEBUG_MENU_INDEX:
		return menus[DEBUG_MENU_INDEX]
	return null


func _find_menu_bar(p_node: Node) -> MenuBar:
	for child in p_node.get_children():
		if child is MenuBar and child.get_theme_type_variation() == "MainMenuBar":
			return child
		var found := _find_menu_bar(child)
		if found != null:
			return found
	return null
