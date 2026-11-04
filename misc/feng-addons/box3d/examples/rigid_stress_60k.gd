extends Node3D
## Identical RID workload for Jolt and Box3D; MultiMesh upload is timed separately.

@export_range(1, 60000, 1) var body_count := 10000
var batch: RefCounted
var camera: Camera3D
var multimesh: MultiMesh
var visual: MultiMeshInstance3D
var status: Label
var notice: Label
var headless := false
var automatic := false
var case_name := "pile"
var allow_sleep := false
var warmup := 240
var sample_steps := 600
var tick := 0
var step_start := 0
var frame_start := 0
var last_step_ms := 0.0
var upload_ms := 0.0
var hud_physics_samples: Array[float] = []
var hud_upload_samples: Array[float] = []
var measured_start := 0
var physics_samples: Array[float] = []
var frame_samples: Array[float] = []
var upload_samples: Array[float] = []
var gpu_samples: Array[float] = []
var collect_core_profile := false
var core_profiles: Dictionary = {}
var initial_hash := ""
var build_ms := 0.0
var ready_to_run := false
var finishing := false
var elapsed_ui := 0.0
var inspection: Dictionary = {}
var snapshot_path := ""
var previous_physics_ticks := 120
var previous_max_physics_steps := 8
var previous_vsync := DisplayServer.VSYNC_ENABLED

func _ready() -> void:
	headless = DisplayServer.get_name() == "headless"
	for arg in OS.get_cmdline_user_args():
		if arg == "--stress-benchmark": automatic = true
		elif arg == "--core-profile": collect_core_profile = true
		elif arg.begins_with("--count="): body_count = clampi(int(arg.get_slice("=", 1)), 1, 60000)
		elif arg.begins_with("--case="): case_name = arg.get_slice("=", 1)
		elif arg.begins_with("--warmup="): warmup = int(arg.get_slice("=", 1))
		elif arg.begins_with("--samples="): sample_steps = int(arg.get_slice("=", 1))
		elif arg.begins_with("--snapshot="): snapshot_path = arg.trim_prefix("--snapshot=")
	previous_physics_ticks = Engine.physics_ticks_per_second
	previous_max_physics_steps = Engine.max_physics_steps_per_frame
	previous_vsync = DisplayServer.window_get_vsync_mode()
	Engine.physics_ticks_per_second = 120
	# Avoid catch-up spirals in the interactive stress view. Automated comparison
	# also uses --fixed-fps 120, exactly one identical simulation step per frame.
	Engine.max_physics_steps_per_frame = 1
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_build_environment()
	if not headless: _build_ui()
	call_deferred("_create_bodies")

func _create_bodies() -> void:
	if not ClassDB.class_exists("FengPhysicsStressBatch"):
		push_error("需要新版 box3d 插件中的 FengPhysicsStressBatch，请重启编辑器。")
		get_tree().quit(1)
		return
	var started := Time.get_ticks_usec()
	batch = ClassDB.instantiate("FengPhysicsStressBatch")
	batch.call("create", get_world_3d().space, body_count, allow_sleep)
	build_ms = (Time.get_ticks_usec() - started) / 1000.0
	var initial: PackedFloat32Array = batch.call("initial_buffer")
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(initial.to_byte_array())
	initial_hash = hash.finish().hex_encode()
	if not headless:
		var target := Vector3(0, maxf(2.0, ceilf(body_count / 2000.0) * 0.3), 0)
		camera.position = target + Vector3(29, 25, 34)
		camera.look_at(target)
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.roughness = 0.85
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE * 0.6
		mesh.material = material
		multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = mesh
		multimesh.instance_count = body_count
		multimesh.buffer = initial
		multimesh.custom_aabb = AABB(Vector3(-24, -2, -20), Vector3(48, 60, 40))
		visual = MultiMeshInstance3D.new()
		visual.multimesh = multimesh
		add_child(visual)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	inspection = batch.call("inspect")
	print("RIGID_STRESS_READY ", JSON.stringify({"bodies": body_count, "creation_ms": build_ms, "backend_body_state": inspection.backend_body_state, "initial_sha256": initial_hash}))
	ready_to_run = true
	frame_start = 0

func _physics_process(_delta: float) -> void:
	if not ready_to_run or finishing: return
	tick += 1
	if case_name == "stir" and tick % 120 == 0: batch.call("agitate", tick / 120)
	# Use matching clocks around the actual engine step. Performance's built-in
	# TIME_PHYSICS_PROCESS monitor is a one-second maximum, not a per-step sample.
	step_start = Time.get_ticks_usec()

func _process(delta: float) -> void:
	if not ready_to_run or finishing: return
	var now := Time.get_ticks_usec()
	var has_step := step_start != 0
	if has_step:
		last_step_ms = (now - step_start) / 1000.0
		if not headless: hud_physics_samples.append(last_step_ms)
		if automatic and tick > warmup and measured_start == 0: measured_start = step_start
		step_start = 0
		if automatic and tick > warmup and tick <= warmup + sample_steps:
			physics_samples.append(last_step_ms)
			if collect_core_profile:
				var profile: Dictionary = batch.call("core_profile")
				for key in profile:
					if not core_profiles.has(key):
						var samples: Array[float] = []
						core_profiles[key] = samples
					core_profiles[key].append(float(profile[key]))
	if automatic and tick > warmup and tick <= warmup + sample_steps and frame_start != 0:
		frame_samples.append((now - frame_start) / 1000.0)
	frame_start = now
	if not headless:
		# A render frame without a physics step has exactly the same body poses.
		# Keep its existing GPU buffer instead of reading/uploading all bodies again.
		if has_step:
			var upload_start := Time.get_ticks_usec()
			batch.call("sync_visuals", multimesh.get_rid())
			upload_ms = (Time.get_ticks_usec() - upload_start) / 1000.0
			hud_upload_samples.append(upload_ms)
		if automatic and has_step and tick > warmup and tick <= warmup + sample_steps:
			upload_samples.append(upload_ms)
			gpu_samples.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
		_move_camera(delta)
		elapsed_ui += delta
		if elapsed_ui > 0.35:
			elapsed_ui = 0
			_update_ui()
			hud_physics_samples.clear()
			hud_upload_samples.clear()
	if automatic and has_step and tick % 120 == 0:
		print("RIGID_STRESS_PROGRESS ", tick, "/", warmup + sample_steps, " step_ms=", snappedf(last_step_ms, 0.001))
	if automatic and tick >= warmup + sample_steps:
		finishing = true
		_finish.call_deferred()

func _summary(values: Array[float]) -> Dictionary:
	if values.is_empty(): return {}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted: total += value
	return {"median_ms": sorted[sorted.size() / 2], "mean_ms": total / sorted.size(), "p95_ms": sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))], "max_ms": sorted[sorted.size() - 1], "samples": sorted.size()}

func _finish() -> void:
	inspection = batch.call("inspect")
	var final_state: PackedFloat32Array = batch.call("final_state_buffer")
	var state_hash := HashingContext.new()
	state_hash.start(HashingContext.HASH_SHA256)
	state_hash.update(final_state.to_byte_array())
	var rigid_state_sha256: String = state_hash.finish().hex_encode()
	var result := {
		"case": case_name, "count": body_count, "ticks_hz": Engine.physics_ticks_per_second,
		"headless": headless, "renderer": RenderingServer.get_current_rendering_method(),
		"initial_sha256": initial_hash, "rigid_state_sha256": rigid_state_sha256, "creation_ms": build_ms,
		"box3d_workers": ProjectSettings.get_setting("physics/box3d/worker_count", 0),
		"godot_worker_threads": ProjectSettings.get_setting("threading/worker_pool/max_threads", -1),
		"logical_processors": OS.get_processor_count(),
		"simulation_steps_per_wall_second": sample_steps * 1000000.0 / maxi(1, Time.get_ticks_usec() - measured_start),
		"physics_step_window": _summary(physics_samples), "frame_interval": _summary(frame_samples),
		"visual_sync": _summary(upload_samples), "viewport_gpu": _summary(gpu_samples),
		"validation": inspection,
		"static_memory_bytes": OS.get_static_memory_usage(),
		"collision_pairs": PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_COLLISION_PAIRS),
		"active_objects": PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS),
		"island_count": PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ISLAND_COUNT),
		"solver": "Box3D 4 substeps" if str(inspection.backend_body_state).begins_with("Box3D") else "Jolt 10 velocity / 2 position iterations"}
	if collect_core_profile:
		var summaries: Dictionary = {}
		for key in core_profiles: summaries[key] = _summary(core_profiles[key])
		result["box3d_core_profile"] = summaries
	print("RIGID_STRESS_RESULT ", JSON.stringify(result))
	var success := int(inspection.bodies) == body_count and int(inspection.invalid) == 0 and int(inspection.escaped) == 0 and physics_samples.size() == sample_steps
	if not allow_sleep: success = success and int(inspection.awake) == body_count
	if not headless and not snapshot_path.is_empty():
		_update_ui()
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(snapshot_path)
	get_tree().quit(0 if success else 1)

func _build_environment() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("263643")
	environment.environment.background_intensity = 1.0
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("bed5e5")
	environment.environment.ambient_light_energy = 0.7
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -28, 0)
	sun.light_energy = 1.3
	sun.light_intensity_lux = 2.0
	sun.shadow_enabled = true
	add_child(sun)
	_make_boundary(Vector3(46, 1, 38), Vector3(0, -0.5, 0))
	_make_boundary(Vector3(1, 35, 38), Vector3(-23, 17, 0))
	_make_boundary(Vector3(1, 35, 38), Vector3(23, 17, 0))
	_make_boundary(Vector3(46, 35, 1), Vector3(0, 17, -19))
	_make_boundary(Vector3(46, 35, 1), Vector3(0, 17, 19))
	camera = Camera3D.new()
	camera.position = Vector3(29, 27, 34)
	camera.fov = 50
	camera.far = 300
	add_child(camera)
	camera.look_at(Vector3(0, 2, 0))
	camera.current = true

func _make_boundary(size: Vector3, position_: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = position_
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	add_child(body)
	# Side walls constrain the pile but remain invisible for an unobstructed view.
	if size.y > 1: return
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("283e4b")
	material.roughness = 0.95
	mesh.material = material
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	body.add_child(visual)

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.position = Vector2(18, 16)
	canvas.add_child(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.045, 0.065, 0.94)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var title := Label.new()
	title.text = "刚体碰撞压力测试 / 1 万 · 3 万 · 6 万"
	title.add_theme_font_size_override("font_size", 24)
	column.add_child(title)
	status = Label.new()
	status.text = "正在创建物理刚体……"
	column.add_child(status)
	var row := HBoxContainer.new()
	column.add_child(row)
	var counts := OptionButton.new()
	for count in [10000, 30000, 60000]: counts.add_item("%d 万刚体" % (count / 10000), count)
	counts.select(maxi(0, [10000, 30000, 60000].find(body_count)))
	counts.item_selected.connect(func(index: int) -> void: _change_count(counts.get_item_id(index)))
	row.add_child(counts)
	for entry in [["重置堆叠（R）", _reset], ["持续扰动", _toggle_stir], ["允许休眠：关", _toggle_sleep], ["返回试验场", _return]]:
		var button := Button.new()
		button.text = entry[0]
		button.focus_mode = Control.FOCUS_NONE
		if entry[0] == "允许休眠：关": button.pressed.connect(entry[1].bind(button))
		else: button.pressed.connect(entry[1])
		row.add_child(button)
	notice = Label.new()
	notice.text = "右键转向 + WASD 移动 / Q、E 升降 / Shift 加速\n120 Hz，每画面最多推进一步；帧率不足时模拟会慢放。"
	notice.add_theme_font_size_override("font_size", 15)
	column.add_child(notice)

func _update_ui() -> void:
	var backend := "Box3D" if str(inspection.get("backend_body_state", "")).begins_with("Box3D") else "Jolt"
	if backend == "Box3D":
		var mode := "自动" if int(ProjectSettings.get_setting("physics/box3d/worker_count", 0)) == 0 else "手动"
		backend += "（%s %d，含调用线程）" % [mode, int(inspection.get("actual_box3d_workers", 1))]
	var physics_ms := float(_summary(hud_physics_samples).get("median_ms", last_step_ms))
	var sync_ms := float(_summary(hud_upload_samples).get("median_ms", upload_ms))
	status.text = "%s  ·  %s 个动态刚体  ·  %d FPS\n物理步窗口 %.2f ms  /  显示同步 %.2f ms（中位数） /  %s" % [backend, str(body_count), Engine.get_frames_per_second(), physics_ms, sync_ms, "持续扰动" if case_name == "stir" else "堆叠碰撞"]

func _reset() -> void:
	if ready_to_run and not automatic: batch.call("reset")

func _change_count(count: int) -> void:
	if not ready_to_run or automatic: return
	ready_to_run = false
	batch.call("clear")
	if is_instance_valid(visual): visual.queue_free()
	body_count = count
	tick = 0
	_create_bodies.call_deferred()

func _toggle_stir() -> void:
	case_name = "stir" if case_name == "pile" else "pile"

func _toggle_sleep(button: Button) -> void:
	if not ready_to_run or automatic: return
	allow_sleep = not allow_sleep
	batch.call("set_sleep_enabled", allow_sleep)
	button.text = "允许休眠：" + ("开" if allow_sleep else "关")

func _return() -> void:
	if ResourceLoader.exists("res://main.tscn"):
		get_tree().change_scene_to_file("res://main.tscn")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera.rotation.y -= event.relative.x * 0.0025
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * 0.0025, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_R: _reset()
		elif event.physical_keycode == KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _move_camera(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return
	var direction := Vector3(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)), float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q)), float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	camera.position += camera.basis * direction.normalized() * delta * (40.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 15.0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif what == NOTIFICATION_EXIT_TREE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Engine.physics_ticks_per_second = previous_physics_ticks
		Engine.max_physics_steps_per_frame = previous_max_physics_steps
		DisplayServer.window_set_vsync_mode(previous_vsync)
		if batch != null: batch.call("clear")
