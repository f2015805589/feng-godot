extends Node3D
## Small inspection camera for the existing terrain, no extra terrain or VT cache.
var _camera: Camera3D
var _terrain: Node3D
var _status: Label
var _elapsed:=0.0
var _payload_info: Dictionary = {}
func _ready() -> void:
	_terrain=$EnvironmentScene/Terrain3D
	if _terrain.vt_neural_data != null: _payload_info = _terrain.vt_neural_data.get_storage_info()
	_camera=$Camera3D
	var height: float=_terrain.data.get_surface_height(Vector3.ZERO)
	if not is_finite(height): height=0.0
	var radius:=maxf(75.0,absf(height)*2.0)
	var position:=Vector3(radius*0.55,0,radius*0.8)
	var ground: float=_terrain.data.get_surface_height(position)
	position.y=maxf(height*0.55+radius*0.6,(ground if is_finite(ground) else 0.0)+20.0)
	_camera.position=position
	_camera.look_at(Vector3(0,height*0.55,0))
	_terrain.set_camera(_camera); _terrain.set_clipmap_target(_camera)
	var hud:=CanvasLayer.new(); add_child(hud)
	_status=Label.new(); _status.position=Vector2(16,16)
	_status.add_theme_font_size_override("font_size",18)
	_status.add_theme_color_override("font_shadow_color",Color.BLACK)
	_status.add_theme_constant_override("shadow_offset_x",2); _status.add_theme_constant_override("shadow_offset_y",2)
	hud.add_child(_status)
	_status.text="NTC 地形：正在生成可见 VT 页面…\n右键转向 · WASD 移动 · Q/E 升降 · Shift 加速"
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(),true)
func _process(delta: float) -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var move:=Vector3(float(Input.is_physical_key_pressed(KEY_D))-float(Input.is_physical_key_pressed(KEY_A)),float(Input.is_physical_key_pressed(KEY_E))-float(Input.is_physical_key_pressed(KEY_Q)),float(Input.is_physical_key_pressed(KEY_S))-float(Input.is_physical_key_pressed(KEY_W)))
		_camera.position+=(_camera.basis*move).normalized()*delta*(80.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 12.0)
	_elapsed+=delta
	if _elapsed<0.5: return
	_elapsed=0.0
	var settings: Dictionary=_terrain.get_vt_settings()
	var stats: Dictionary=settings.get("producer",{})
	var neural: Dictionary=stats.get("neural_runtime",{})
	var source: Dictionary=_terrain.assets.get_texture_array_info()
	var total := int(source.get("gpu_bytes",0))+int(stats.get("material_bytes",0))+int(stats.get("neural_gpu_bytes",0))
	var resident := "GPU 压缩数据 %s · 热页缓存 %s（%d / %d 页）" % [String.humanize_size(int(neural.get("compressed_bytes",0))),String.humanize_size(int(neural.get("decoded_bytes",0))),neural.get("cache_ready",0),neural.get("cache_capacity",0)] if not neural.is_empty() else "GPU 页池 %s · 神经工作区 %s" % [String.humanize_size(int(stats.get("material_bytes",0))),String.humanize_size(int(stats.get("neural_gpu_bytes",0)))]
	_status.text="地形 VT / FRP：近景 %s · 远景 %s\n编码包（CPU）%s · 已烘焙 %d 页\n%s\n地形材质 GPU 合计 %s · 解码 %d 次\n整视口 GPU %.2f ms\n右键转向 · WASD 移动 · Q/E 升降 · Shift 加速" % [settings.get("surface_vt_compression_name","加载中"),settings.get("surface_svt_compression_name","加载中"),String.humanize_size(int(_payload_info.get("encoded_bytes",0))),_payload_info.get("pages",0),resident,String.humanize_size(total),stats.get("neural_dispatches",0),RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())]
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_camera.rotation.y-=event.relative.x*0.003
		_camera.rotation.x=clampf(_camera.rotation.x-event.relative.y*0.003,-1.55,1.55)
