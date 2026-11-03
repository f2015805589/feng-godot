@tool
extends VBoxContainer
const Baker = preload("terrain_vt_baker.gd")
var editor: EditorInterface
var undo_manager: EditorUndoRedoManager
var bpp: SpinBox
var steps: SpinBox
var _button: Button
var _cancel: Button
var _label: Label
var _progress: ProgressBar
var _dialog: EditorFileDialog
var _thread: Thread
var _codec: Object
var _terrain: Node
var _path := ""
var _signature := ""
var _busy := false
var _cancelled := false
var _restore: Array = []


func _ready() -> void:
	var row := HBoxContainer.new()
	add_child(row)
	_button = Button.new()
	_button.text = "所选地形：烘焙当前视域 VT → NTC…"
	_button.tooltip_text = "压缩最终 VT 页，保留原始密度、通道和边框。当前视域之外或修改后的页面使用实时生产器；可走到其他位置再追加烘焙。"
	_button.pressed.connect(_choose)
	row.add_child(_button)
	_cancel = Button.new()
	_cancel.text = "取消 VT 压缩"
	_cancel.visible = false
	_cancel.pressed.connect(func():
		_cancelled = true
		if _codec != null: _codec.cancel())
	row.add_child(_cancel)
	_progress = ProgressBar.new()
	_progress.visible = false
	add_child(_progress)
	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.text = "地形近景 / 远景 Compression 可选 NTC；缺页解码并缓存。物理页缓存可单独选择 Auto、BC7、BC3 或 RGBA16F。"
	add_child(_label)
	_dialog = EditorFileDialog.new()
	_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_dialog.add_filter("*.res", "NTC VT 页数据")
	_dialog.file_selected.connect(_start)
	add_child(_dialog)
	set_process(false)


func _choose() -> void:
	if _busy: return
	_terrain = null
	for node: Node in editor.get_selection().get_selected_nodes():
		if node.has_method("export_vt_neural_pages"): _terrain = node; break
	if _terrain == null:
		_label.text = "请在场景树选中 Terrain3D 地形。"
		return
	if not ClassDB.class_exists(&"FengNTCCodec"):
		_label.text = "未安装 NTC 制作 SDK；请运行 tools/setup_sdk.py 和 native/build.py。"
		return
	_codec = ClassDB.instantiate(&"FengNTCCodec")
	if not _codec.has_method("compress_terrain_pages"):
		_label.text = "请更新 Feng NTC 制作扩展。"
		return
	_dialog.current_file = "terrain_vt_ntc.res"
	_dialog.popup_centered_ratio(0.65)


func _start(path: String) -> void:
	if _busy or not is_instance_valid(_terrain): return
	_path = path
	_busy = true
	_cancelled = false
	_button.disabled = true
	_cancel.visible = true
	_progress.visible = true
	_progress.indeterminate = true
	_label.text = "生成原始 VT 页…"
	_restore = [_terrain.surface_vt_compression, _terrain.surface_svt_compression, _terrain.vt_editor_preview, _terrain.is_physics_processing()]
	_terrain.surface_vt_compression = 0
	_terrain.surface_svt_compression = 0
	_terrain.vt_editor_preview = false
	_terrain.set_physics_process(true)
	var stable := 0
	var previous := -1
	for frame in range(900):
		await get_tree().process_frame
		if _cancelled or not is_instance_valid(_terrain): break
		var stats: Dictionary = _terrain.get_vt_settings().get("producer", {})
		var ready := int(stats.get("ready_pages", 0))
		stable = stable+1 if ready > 0 and ready == previous and int(stats.get("pending", 0)) == 0 else 0
		previous = ready
		if frame > 60 and stable >= 24: break
	if _cancelled or not is_instance_valid(_terrain): _finish({"ok": false, "error": "已取消。"}); return
	_terrain.set_physics_process(false)
	await RenderingServer.frame_post_draw
	_signature = _terrain.get_vt_neural_signature()
	var pages: Array = _terrain.export_vt_neural_pages()
	_restore_terrain()
	_label.text = "已捕获 %d 个最终 VT 页，正在分组压缩…" % pages.size()
	_thread = Thread.new()
	var error := _thread.start(Baker.compress.bind(_codec, pages, _signature, float(bpp.value), int(steps.value)))
	if error != OK: _finish({"ok": false, "error": error_string(error)}); return
	set_process(true)


func _process(_delta: float) -> void:
	if _thread == null: return
	if not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		_finish(result)
		return
	var status: Dictionary = _codec.get_status()
	_progress.indeterminate = int(status.phase) != 2
	_progress.max_value = steps.value
	_progress.value = status.steps
	_label.text = "VT NTC 烘焙：分组 %d / %d，%d / %d 步" % [status.get("batch", 0), status.get("batches", 0), status.steps, int(steps.value)]


func _restore_terrain() -> void:
	if not _restore.is_empty() and is_instance_valid(_terrain):
		_terrain.surface_vt_compression = _restore[0]
		_terrain.surface_svt_compression = _restore[1]
		_terrain.vt_editor_preview = _restore[2]
		_terrain.set_physics_process(_restore[3])
	_restore.clear()


func _finish(result: Dictionary) -> void:
	set_process(false)
	_restore_terrain()
	_busy = false
	_button.disabled = false
	_cancel.visible = false
	_progress.visible = false
	_codec = null
	if not result.get("ok", false): _label.text = "VT NTC 未完成：" + str(result.get("error", "未知错误")); return
	var asset: Resource = result.asset
	# Merge only entries with the identical source identity; never recycle stale
	# models after a paint/sculpt edit. This lets several camera positions accumulate.
	if is_instance_valid(_terrain) and _terrain.vt_neural_data != null:
		var previous: Resource = _terrain.vt_neural_data
		if previous.get_script() == preload("terrain_vt_data.gd") and previous.source_signature == asset.source_signature:
			var offset: int = asset.packages.size()
			asset.packages.append_array(previous.packages)
			for key: String in previous.pages:
				if asset.pages.has(key): continue
				var page: Dictionary = previous.pages[key].duplicate()
				page.model = int(page.model)+offset
				asset.pages[key] = page
	asset.compact()
	var error := ResourceSaver.save(asset, _path, ResourceSaver.FLAG_COMPRESS | ResourceSaver.FLAG_CHANGE_PATH)
	if error != OK: _label.text = "VT NTC 保存失败：" + error_string(error); return
	editor.get_resource_filesystem().update_file(_path)
	if not is_instance_valid(_terrain) or _terrain.get_vt_neural_signature() != _signature:
		_label.text = "已保存；地形源在压缩期间发生变化，请重新烘焙。"
		return
	undo_manager.create_action("应用 NTC VT 页压缩")
	for change: Array in [["vt_neural_data", asset], ["surface_vt_compression", 4], ["surface_svt_compression", 4]]:
		undo_manager.add_do_property(_terrain, change[0], change[1])
		undo_manager.add_undo_property(_terrain, change[0], _terrain.get(change[0]))
	undo_manager.commit_action()
	editor.mark_scene_as_unsaved()
	var info: Dictionary = asset.get_storage_info()
	_label.text = "完成：%d 页，NTC 数据 %s，同页 BC7 数据 %s。请保存场景；缓存格式可在页数据资源中设置。" % [info.pages, String.humanize_size(info.encoded_bytes), String.humanize_size(info.bc7_page_bytes)]


func _exit_tree() -> void:
	_cancelled = true
	if _codec != null: _codec.cancel()
	if _thread != null and _thread.is_started(): _thread.wait_to_finish()
	_restore_terrain()
