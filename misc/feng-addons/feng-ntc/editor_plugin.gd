@tool
extends EditorPlugin

const TextureSet = preload("texture_set.gd")
const NTMaterial = preload("material.gd")
const VTMaterial = preload("virtual_material.gd")
const NeuralMaterial = preload("neural_material.gd")
const MemoryInfo = preload("memory_info.gd")
const MaterialTools = preload("material_tools.gd")
const CompressionCache = preload("compression_cache.gd")
const Importer = preload("importer.gd")
const Exporter = preload("export_plugin.gd")
const Inspector = preload("inspector.gd")
const TerrainVTEditor = preload("terrain_vt_editor.gd")
const MENU := "Feng NTC 材质压缩…"
var _panel: VBoxContainer
var _picker: EditorResourcePicker
var _bpp: SpinBox
var _steps: SpinBox
var _surface: SpinBox
var _mode: OptionButton
var _progress: ProgressBar
var _status: Label
var _compress_button: Button
var _cancel_button: Button
var _apply_button: Button
var _portable_button: Button
var _convert_button: Button
var _save_dialog: EditorFileDialog
var _portable_dialog: EditorFileDialog
var _importer: EditorImportPlugin
var _exporter: EditorExportPlugin
var _inspector: EditorInspectorPlugin
var _thread: Thread
var _codec: Object
var _result: Material
var _template: StandardMaterial3D
var _busy := false
var _output := ""
var _started := 0
var _snapshot: Dictionary
var _reuse_asset: Resource


func _enter_tree() -> void:
	# Authoring extension lives in tools/.gdignore: games do not load or export it.
	if OS.has_feature("windows") and not ClassDB.class_exists(&"FengNTCCodec") and FileAccess.file_exists("res://addons/feng-ntc/bin/feng_ntc.dll"):
		GDExtensionManager.load_extension("res://addons/feng-ntc/tools/feng_ntc.gdextension")
	_importer = Importer.new()
	add_import_plugin(_importer)
	_exporter = Exporter.new()
	add_export_plugin(_exporter)
	_inspector=Inspector.new()
	add_inspector_plugin(_inspector)
	_build_ui()
	add_control_to_bottom_panel(_panel, "Feng NTC")
	add_tool_menu_item(MENU, _show)
	set_process(false)


func _exit_tree() -> void:
	if _codec != null: _codec.cancel()
	if _thread != null and _thread.is_started(): _thread.wait_to_finish()
	remove_tool_menu_item(MENU)
	remove_import_plugin(_importer)
	remove_export_plugin(_exporter)
	remove_inspector_plugin(_inspector)
	remove_control_from_bottom_panel(_panel)
	_panel.queue_free()
	_save_dialog.queue_free()
	_portable_dialog.queue_free()


func _handles(object: Object) -> bool:
	return object is StandardMaterial3D or object is VTMaterial or object is NeuralMaterial


func _edit(object: Object) -> void:
	if not _busy and _handles(object):
		_picker.edited_resource = object
		_source_changed(object)


func _show() -> void:
	make_bottom_panel_item_visible(_panel)
	if not ClassDB.class_exists(&"FengNTCCodec") and not _is_ntc(_picker.edited_resource):
		_status.text = "请先运行插件的 tools/setup_sdk.py 和 native/build.py，然后重启编辑器。"


func _build_ui() -> void:
	_panel = VBoxContainer.new()
	_panel.name = "FengNTC"
	_panel.custom_minimum_size = Vector2(600, 220)
	var help := Label.new()
	help.text = "NTC 直接采样保留压缩潜变量与网络，不生成整张 RGBA8。制作一次，游戏端无需 CUDA。"
	_panel.add_child(help)
	var source_row := HBoxContainer.new()
	_panel.add_child(source_row)
	_picker = EditorResourcePicker.new()
	_picker.base_type = "Material"
	_picker.resource_changed.connect(_source_changed)
	_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_row.add_child(_picker)
	var select := Button.new()
	select.text = "读取选中模型的材质"
	select.pressed.connect(_from_selection)
	source_row.add_child(select)
	_surface = SpinBox.new()
	_surface.min_value = 0
	_surface.max_value = 1024
	_surface.prefix = "表面"
	_surface.tooltip_text = "模型的材质表面编号，从 0 开始。"
	source_row.add_child(_surface)
	var options := HBoxContainer.new()
	_panel.add_child(options)
	_bpp = SpinBox.new()
	_bpp.min_value = 1
	_bpp.max_value = 20
	_bpp.step = 0.5
	_bpp.value = 2
	_bpp.prefix = "码率 bpp"
	_bpp.tooltip_text = "整组材质的目标码率；实际值由 SDK 选择。码率越大，一般细节保留越好。"
	options.add_child(_bpp)
	_steps = SpinBox.new()
	_steps.min_value = 128
	_steps.max_value = 100000
	_steps.step = 128
	_steps.value = 16384
	_steps.prefix = "训练步数"
	options.add_child(_steps)
	_mode = OptionButton.new()
	_mode.add_item("完整 RGBA8 · 仅省包体")
	_mode.add_item("VT 页缓存 · 不透明 PBR")
	_mode.add_item("NTC 压缩数据直接采样")
	_mode.select(2)
	_mode.tooltip_text = "直接采样常驻压缩数据，保留原始分辨率；逐片元推理增加计算量。VT 可缓存部分解码页。完整 RGBA8 仅用于诊断或兼容标准材质功能。"
	options.add_child(_mode)
	_compress_button = Button.new()
	_compress_button.text = "压缩并创建 NTC 材质…"
	_compress_button.pressed.connect(_choose_output)
	options.add_child(_compress_button)
	_cancel_button = Button.new()
	_cancel_button.text = "取消"
	_cancel_button.visible = false
	_cancel_button.pressed.connect(func():
		if _codec != null: _codec.cancel()
		_status.text = "正在取消，保留原始材质。")
	options.add_child(_cancel_button)
	_progress = ProgressBar.new()
	_progress.visible = false
	_panel.add_child(_progress)
	_status = Label.new()
	_status.text = "运行端需要支持 Compute 的 RenderingDevice 渲染器。Vulkan / D3D12 已接入，其他平台需实机验证。"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(_status)
	var actions := HBoxContainer.new()
	_panel.add_child(actions)
	_convert_button = Button.new()
	_convert_button.text = "已有 NTC 改采样方式（无需重训）…"
	_convert_button.disabled = true
	_convert_button.pressed.connect(_choose_sampling_mode)
	actions.add_child(_convert_button)
	_apply_button = Button.new()
	_apply_button.text = "应用到选中模型（可撤销）"
	_apply_button.disabled = true
	_apply_button.pressed.connect(_apply)
	actions.add_child(_apply_button)
	_portable_button = Button.new()
	_portable_button.text = "另存为普通 BC7 材质…"
	_portable_button.disabled = true
	_portable_button.pressed.connect(func(): _portable_dialog.popup_centered_ratio(0.65))
	actions.add_child(_portable_button)
	_save_dialog = EditorFileDialog.new()
	_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_save_dialog.add_filter("*.tres", "NTC 材质")
	_save_dialog.title = "保存 NTC 材质"
	_save_dialog.file_selected.connect(_start)
	get_editor_interface().get_base_control().add_child(_save_dialog)
	_portable_dialog = EditorFileDialog.new()
	_portable_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_portable_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_portable_dialog.add_filter("*.res", "普通 BC7 材质（无需 NTC 解码器）")
	_portable_dialog.file_selected.connect(_save_portable)
	get_editor_interface().get_base_control().add_child(_portable_dialog)
	var terrain_tools := TerrainVTEditor.new()
	terrain_tools.editor = get_editor_interface()
	terrain_tools.undo_manager = get_undo_redo()
	terrain_tools.bpp = _bpp
	terrain_tools.steps = _steps
	_panel.add_child(HSeparator.new())
	_panel.add_child(terrain_tools)


func _selected_mesh() -> MeshInstance3D:
	for node: Node in get_editor_interface().get_selection().get_selected_nodes():
		if node is MeshInstance3D and node.mesh != null: return node
	return null


func _from_selection() -> void:
	if _busy: return
	var node := _selected_mesh()
	if node == null:
		_status.text = "请在场景树中选中一个 MeshInstance3D。"
		return
	var index := int(_surface.value)
	if index >= node.mesh.get_surface_count():
		_status.text = "表面编号超出这个模型的范围。"
		return
	var material := node.get_active_material(index)
	if not _handles(material):
		_status.text = "请选择 StandardMaterial3D 或 Feng NTC 材质。"
		return
	_picker.edited_resource = material
	_source_changed(material)
	if not _is_ntc(material):
		_status.text = "已读取 %s 的表面 %d。" % [node.name, index]


func _source_changed(resource: Resource) -> void:
	_convert_button.disabled = _busy or not _is_ntc(resource)
	if _is_ntc(resource):
		var asset: Resource = resource.texture_set
		if asset != null:
			_status.text = MemoryInfo.sample_summary(asset.package) if resource is NeuralMaterial else MemoryInfo.summary(asset.package,resource is VTMaterial,resource.cache_axis if resource is VTMaterial else 8)


func _is_ntc(resource: Object) -> bool:
	return resource is NTMaterial or resource is VTMaterial or resource is NeuralMaterial


func _choose_sampling_mode() -> void:
	if _busy: return
	var source: Material = _picker.edited_resource
	if not _is_ntc(source) or source.texture_set == null: return
	_template=MaterialTools.sampler_template(source)
	if _mode.selected!=0:
		var unsupported := MaterialTools.virtual_unsupported(_template)
		if not unsupported.is_empty(): _status.text = unsupported; return
	if not source.texture_set.ensure_portable(): _status.text = source.texture_set.last_error; return
	_reuse_asset = source.texture_set
	_save_dialog.current_file = "material_ntc_sample.tres"
	_save_dialog.popup_centered_ratio(0.65)


func _choose_output() -> void:
	if _busy: return
	_reuse_asset = null
	var material := _picker.edited_resource as StandardMaterial3D
	_snapshot = MaterialTools.snapshot(material)
	if not _snapshot.get("ok", false):
		_status.text = _snapshot.error
		return
	if _mode.selected != 0:
		var unsupported := MaterialTools.virtual_unsupported(material)
		if not unsupported.is_empty(): _status.text = unsupported; return
	if not ClassDB.class_exists(&"FengNTCCodec"):
		_show()
		return
	_codec = ClassDB.instantiate(&"FengNTCCodec")
	var status: Dictionary = _codec.get_sdk_status()
	if not status.get("ok", false):
		_status.text = status.error
		return
	_template = StandardMaterial3D.new()
	MaterialTools.copy_material_properties(material, _template)
	_save_dialog.current_file = "material_ntc.tres"
	_save_dialog.popup_centered_ratio(0.65)


func _start(path: String) -> void:
	if _busy: return
	_output = path
	if _reuse_asset != null:
		if _save_material(_reuse_asset):
			_status.text = "已保存材质（复用模型，未重新训练）：%s\n%s" % [_output,_memory_summary(_reuse_asset.package)]
		_reuse_asset = null
		return
	if _snapshot.is_empty(): return
	_started = Time.get_ticks_msec()
	_busy = true
	_compress_button.disabled = true
	_picker.editable = false
	_mode.disabled = true
	_cancel_button.visible = true
	_apply_button.disabled = true
	_portable_button.disabled = true
	_convert_button.disabled = true
	_progress.visible = true
	_progress.indeterminate = true
	_progress.max_value = _steps.value
	_status.text = "准备材质并初始化压缩器…"
	_thread = Thread.new()
	var error := _thread.start(_compress_worker.bind(_codec, _snapshot, float(_bpp.value), int(_steps.value)))
	if error != OK:
		_finish({"ok": false, "error": "无法启动压缩线程。"})
		return
	set_process(true)


static func _compress_worker(codec: Object, snapshot_data: Dictionary, bpp: float, steps: int) -> Dictionary:
	return CompressionCache.compress(codec, MaterialTools.pack(snapshot_data), bpp, steps)


func _process(_delta: float) -> void:
	if not _busy or _thread == null: return
	if not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_finish(result)
		return
	var status: Dictionary = _codec.get_status()
	_progress.indeterminate = status.phase != 2
	_progress.value = status.steps
	_status.text = ["准备材质…", "初始化 CUDA、上传贴图…", "压缩中：%d / %d 步" % [status.steps, int(_progress.max_value)], "验证解码结果…", "整理通用数据…", "保存结果…"][clampi(status.phase, 0, 5)]


func _finish(result: Dictionary) -> void:
	set_process(false)
	_busy = false
	_compress_button.disabled = false
	_picker.editable = true
	_mode.disabled = false
	_cancel_button.visible = false
	_progress.visible = false
	_thread = null
	_codec = null
	_snapshot.clear()
	_convert_button.disabled = not _is_ntc(_picker.edited_resource)
	if not result.get("ok", false):
		_status.text = "压缩未完成：" + str(result.get("error", "未知错误"))
		return
	var asset := TextureSet.new()
	asset.package = result.package
	if not _save_material(asset): return
	_status.text = "已保存 %s\n耗时 %.1f 秒 · 实际码率 %.2f bpp · SDK PSNR %.2f dB\n%s" % [_output, (Time.get_ticks_msec() - _started) / 1000.0, result.actual_bpp, result.psnr,_memory_summary(asset.package)]
	if result.get("compression_cache_hit", false): _status.text += " · 复用已有压缩结果"


func _save_material(asset: Resource) -> bool:
	# Content-addressed assets never replace data referenced by another existing material.
	var asset_path: String = asset.resource_path
	if asset_path.is_empty() or not FileAccess.file_exists(asset_path):
		asset_path = _output.get_basename() + ".ntc-" + asset.fingerprint().left(16) + ".res"
		var save_error := ResourceSaver.save(asset, asset_path, ResourceSaver.FLAG_COMPRESS | ResourceSaver.FLAG_CHANGE_PATH)
		if save_error != OK:
			_status.text = "无法保存压缩数据：" + error_string(save_error)
			return false
		asset.take_over_path(asset_path)
	var material: Material
	if _mode.selected == 1:
		material = MaterialTools.make_virtual(_template,asset)
	elif _mode.selected == 2:
		material = MaterialTools.make_neural(_template,asset)
	else:
		material = NTMaterial.new()
		MaterialTools.copy_material_properties(_template,material)
		material.texture_set = asset
	var error := ResourceSaver.save(material, _output, ResourceSaver.FLAG_CHANGE_PATH)
	if error != OK:
		_status.text = "无法保存材质：" + error_string(error)
		return false
	material.take_over_path(_output)
	_result = material
	get_editor_interface().get_resource_filesystem().update_file(asset_path)
	get_editor_interface().get_resource_filesystem().update_file(_output)
	_apply_button.disabled = false
	_portable_button.disabled = not material is NTMaterial
	return true


func _memory_summary(data: Dictionary) -> String:
	return MemoryInfo.sample_summary(data) if _mode.selected==2 else MemoryInfo.summary(data,_mode.selected==1)


func _apply() -> void:
	var node := _selected_mesh()
	if _result == null or node == null or int(_surface.value) >= node.mesh.get_surface_count():
		_status.text = "请选择要应用结果的模型和有效表面编号。"
		return
	var index := int(_surface.value)
	var undo := get_undo_redo()
	undo.create_action("应用 Feng NTC 材质")
	if node.material_override != null:
		undo.add_do_property(node,"material_override",_result)
		undo.add_undo_property(node,"material_override",node.material_override)
	else:
		undo.add_do_method(node, "set_surface_override_material", index, _result)
		undo.add_undo_method(node, "set_surface_override_material", index, node.get_surface_override_material(index))
	undo.commit_action()


func _save_portable(path: String) -> void:
	if _result == null: return
	var material := await MaterialTools.make_portable(_result as NTMaterial)
	if material == null:
		_status.text = _result.texture_set.last_error
		return
	var error := ResourceSaver.save(material, path, ResourceSaver.FLAG_COMPRESS)
	_status.text = "普通 BC7 材质已保存：" + path if error == OK else "保存失败：" + error_string(error)
	if error == OK: get_editor_interface().get_resource_filesystem().update_file(path)
