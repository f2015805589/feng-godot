@tool
extends EditorPlugin

const MENU_NAME := "Box3D 物理后端…"
const SETTING := "physics/3d/physics_engine"
const BACKEND := "Box3D Physics"

var _dialog: AcceptDialog
var _status: Label
var _enable: Button


func _enter_tree() -> void:
	_dialog = AcceptDialog.new()
	_dialog.title = "Box3D 物理后端"
	_dialog.min_size = Vector2i(540, 170)
	_dialog.get_ok_button().text = "关闭"
	_status = Label.new()
	_dialog.add_child(_status)
	_enable = _dialog.add_button("使用 Box3D（下次启动生效）", true, "enable_box3d")
	_dialog.custom_action.connect(_on_action)
	get_editor_interface().get_base_control().add_child(_dialog)
	add_tool_menu_item(MENU_NAME, _show_dialog)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_NAME)
	if is_instance_valid(_dialog):
		_dialog.queue_free()


func _show_dialog() -> void:
	var loaded := ClassDB.class_exists(&"Box3DPhysicsServer3D")
	var configured := str(ProjectSettings.get_setting(SETTING, "DEFAULT"))
	var active := PhysicsServer3D.get_class()
	_enable.disabled = not loaded or configured == BACKEND
	_status.text = "项目设置：%s\n当前运行：%s\n\n" % [configured, active]
	if not loaded:
		_status.text += "Box3D 原生库尚未加载。请确认插件已构建，然后重启编辑器。"
	elif configured == BACKEND and active != "Box3DPhysicsServer3D":
		_status.text += "已选择 Box3D，请保存场景并重启编辑器。"
	else:
		_status.text += "也可在 项目设置 → 物理 → 3D → Physics Engine 中切换。\n切换后需要重启；现有物理节点可继续使用。"
	_dialog.popup_centered()


func _on_action(action: StringName) -> void:
	if action != &"enable_box3d" or not ClassDB.class_exists(&"Box3DPhysicsServer3D"):
		return
	var previous: Variant = ProjectSettings.get_setting(SETTING, "DEFAULT")
	ProjectSettings.set_setting(SETTING, BACKEND)
	var error := ProjectSettings.save()
	if error != OK:
		ProjectSettings.set_setting(SETTING, previous)
		_status.text = "无法保存项目设置：%s" % error_string(error)
		return
	_show_dialog()
