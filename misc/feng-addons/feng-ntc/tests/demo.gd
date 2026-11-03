extends Node3D
const MemoryInfo = preload("res://addons/feng-ntc/memory_info.gd")
const MaterialTools = preload("res://addons/feng-ntc/material_tools.gd")
const TextureSet = preload("res://addons/feng-ntc/texture_set.gd")
const NTMaterial = preload("res://addons/feng-ntc/material.gd")
const VTMaterial = preload("res://addons/feng-ntc/virtual_material.gd")
const NeuralMaterial = preload("res://addons/feng-ntc/neural_material.gd")
var mode := 2
var yaw := 0.0
var pitch := 32.0
var distance := 13.0
var _summary := ""
var _elapsed := 0.0

func _ready() -> void:
	# Production NTC materials sample compressed data; full RGBA8 is an explicit diagnostic mode.
	for pair in [["岩石","gray_rocks"],["草地","grass_ground"]]:
		var source: StandardMaterial3D=load("res://materials/%s_original.tres" % pair[1])
		var imported_bytes := 0
		for slot in ["albedo_texture","normal_texture"]:
			var texture: Texture2D=source.get(slot)
			if texture != null: imported_bytes+=texture.get_image().get_data_size()
		var asset: Resource=load("res://materials/%s.ntc.res" % pair[1])
		var file := FileAccess.open(asset.resource_path,FileAccess.READ)
		_summary += "%s：原材质纹理 %s | NTC 模型文件 %s（非显存）\n" % [pair[0],String.humanize_size(imported_bytes),String.humanize_size(file.get_length())]
	_update_hud()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--mode="): _set_mode(clampi(int(argument.trim_prefix("--mode=")),1,4))
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			if mode==2:
				for name in ["RockNTC","GrassNTC"]:
					var session: RefCounted=get_node(name).material_override.texture_set.get_sample_session()
					while not session.ready and session.last_error.is_empty(): await get_tree().process_frame
					if not session.last_error.is_empty(): push_error(session.last_error); get_tree().quit(1); return
			elif mode==4:
				for name in ["RockNTC","GrassNTC"]: await get_node(name).material_override.texture_set.prepare_async()
			# Let histogram auto exposure settle in real time, independent of frame rate.
			await get_tree().create_timer(4.0).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(argument.trim_prefix("--capture="))
			print("FRP_CAPTURE_OK")
			get_tree().quit()

func _process(delta: float) -> void:
	_elapsed+=delta
	if _elapsed>=0.25:
		_elapsed=0.0
		_update_hud()

func _set_mode(value: int) -> void:
	mode=value
	for pair in [["Rock","gray_rocks"],["Grass","grass_ground"]]:
		var source: StandardMaterial3D=load("res://materials/%s_original.tres" % pair[1])
		var material: Material=source
		if mode==2:
			material=load("res://materials/%s_ntc.tres" % pair[1])
		elif mode==3:
			# A VT resource must not keep an already decoded full-load session alive.
			var stored: Resource=load("res://materials/%s.ntc.res" % pair[1])
			var asset := TextureSet.new()
			asset.package=stored.package
			material=MaterialTools.make_virtual(source,asset)
		elif mode==4:
			var stored: Resource=load("res://materials/%s.ntc.res" % pair[1])
			var asset := TextureSet.new(); asset.package=stored.package
			var full := NTMaterial.new(); MaterialTools.copy_material_properties(source,full)
			full.texture_set=asset; material=full
		get_node(pair[0]+"NTC").material_override=material
		get_node(pair[0]+"NTCTile").material_override=material
	_update_hud()

func _update_hud() -> void:
	var text := "Feng NTC / FRP  左：原材质  右：%s\n" % ["原材质","NTC 压缩数据直接采样 · 完整 2K","VT 缓存（容量不足会降 mip）","完整 RGBA8（诊断模式）"][mode-1]
	text+=_summary
	for name in ["RockNTC","GrassNTC"]:
		var material: Material=get_node(name).material_override
		var stats: Dictionary={}
		if material is NTMaterial: stats=material.texture_set.get_runtime_stats()
		elif material is VTMaterial: stats=material.get_runtime_stats()
		elif material is NeuralMaterial: stats=material.get_runtime_stats()
		if stats.is_empty(): continue
		text+="%s NTC GPU 资源：%s" % ["岩石" if name=="RockNTC" else "草地",String.humanize_size(MemoryInfo.gpu_bytes(stats))]
		if material is VTMaterial:
			var resolution: Vector2i=stats.get("requested_resolution",Vector2i.ZERO)
			text+=" | 全 UV mip %d，%d×%d%s" % [stats.get("requested_mip",0),resolution.x,resolution.y,"（缓存容量限制）" if stats.get("capacity_limited",false) else ""]
		text+="\n"
	$HUD/Help.text=text+"统计单组材质纹理/缓冲，不含驱动开销。\n1 原材质 · 2 NTC · 3 VT · 4 RGBA8 诊断 | 右键旋转 · 滚轮缩放"

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		yaw -= event.relative.x * 0.25
		pitch = clampf(pitch + event.relative.y * 0.25, 5, 80)
		_move_camera()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: distance = maxf(4, distance - 0.5)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN: distance = minf(30, distance + 0.5)
		_move_camera()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_set_mode(1 if mode!=1 else 2)
	if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_1,KEY_2,KEY_3,KEY_4]:
		_set_mode(event.keycode-KEY_1+1)

func _move_camera() -> void:
	var direction := Vector3(sin(deg_to_rad(yaw)) * cos(deg_to_rad(pitch)), sin(deg_to_rad(pitch)), cos(deg_to_rad(yaw)) * cos(deg_to_rad(pitch)))
	$Camera3D.position = Vector3(0, 0.7, 0) + direction * distance
	$Camera3D.look_at(Vector3(0, 0.7, 0))
