extends Node3D
## Standalone lab: it does not add simulation load to the domino benchmark.

@onready var camera: Camera3D = $Camera3D
@onready var actor = $RagdollActor
var projectiles: Array[RigidBody3D] = []
var _last_shot := -1000
var _projectile_mesh: SphereMesh
var _projectile_shape: SphereShape3D

func _ready() -> void:
	_projectile_mesh = SphereMesh.new()
	_projectile_mesh.radius = 0.3
	_projectile_mesh.height = 0.6
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("ebc966")
	material.roughness = 0.45
	_projectile_mesh.material = material
	_projectile_shape = SphereShape3D.new()
	_projectile_shape.radius = 0.3
	camera.look_at(Vector3(0, 1.7, 0))
	_build_ui()
	actor.rigid_body_contact.connect(_on_actor_contact)
	if PhysicsServer3D.get_class() != "Box3DPhysicsServer3D":
		push_error("软体实验室需要 Box3D Physics 后端，请在项目设置选择并重启。")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		elif event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var point: Vector2 = get_viewport().get_visible_rect().size * 0.5 if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else event.position
			shoot_ray(camera.project_ray_origin(point), camera.project_ray_normal(point))
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			camera.position += camera.basis.z * (-0.6 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.6)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera.rotation.y -= event.relative.x * 0.0025
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * 0.0025, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_T: toggle_ragdoll()
			KEY_R: reset_lab()
			KEY_K: $SoftBodies.cut_cloth()
			KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_EXIT_TREE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _process(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var motion := Vector3(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	camera.position += camera.basis * motion.normalized() * delta * (12.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 4.0)
	camera.position.y = maxf(camera.position.y, 0.15)

func toggle_ragdoll() -> void:
	actor.set_ragdoll(not actor.ragdoll_active, Vector3(8, 2, 35))

func _on_actor_contact(body: RigidBody3D) -> void:
	if not actor.ragdoll_active and body in projectiles:
		actor.call_deferred("set_ragdoll", true, body.get_meta("impact_impulse", Vector3.ZERO))

func reset_lab() -> void:
	actor.reset_actor()
	$SoftBodies.reset_bodies()
	for ball in projectiles:
		if is_instance_valid(ball):
			ball.queue_free()
	projectiles.clear()

func return_to_playground() -> void:
	if ResourceLoader.exists("res://main.tscn") and get_tree().current_scene.scene_file_path != "res://main.tscn":
		get_tree().change_scene_to_file("res://main.tscn")

func shoot_ray(origin: Vector3, direction: Vector3) -> RigidBody3D:
	if Time.get_ticks_msec() - _last_shot < 150:
		return null
	_last_shot = Time.get_ticks_msec()
	if projectiles.size() >= 20:
		projectiles.pop_front().queue_free()
	var ball := RigidBody3D.new()
	ball.mass = 4.0
	ball.continuous_cd = true
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	var visual := MeshInstance3D.new()
	# Keep the vertex/material/shape resources resident across shots. Creating
	# identical meshes here forces fresh render uploads on every mouse click.
	visual.mesh = _projectile_mesh
	ball.add_child(visual)
	var collision := CollisionShape3D.new()
	collision.shape = _projectile_shape
	ball.add_child(collision)
	ball.position = origin + direction.normalized()
	ball.set_meta("impact_impulse", direction.normalized() * 35.0)
	add_child(ball)
	ball.linear_velocity = direction.normalized() * 20.0
	# Defer collision/simulator changes out of the physics notification.
	ball.body_entered.connect(func(body: Node):
		if body == actor and not actor.ragdoll_active:
			actor.call_deferred("set_ragdoll", true, direction.normalized() * 35.0)
	)
	projectiles.append(ball)
	return ball

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.position = Vector2(20, 16)
	canvas.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var title := Label.new()
	title.text = "Box3D · 2048 粒子布料 · 左键发球 · T 布娃娃 · K 切开布料 · R 重置"
	title.add_theme_font_size_override("font_size", 20)
	column.add_child(title)
	var help := Label.new()
	help.text = "按住右键转向 + WASD 移动，Q/E 升降，Shift 加速；滚轮缩放；Esc 释放鼠标"
	column.add_child(help)
	var row := HBoxContainer.new()
	column.add_child(row)
	for entry in [["切换布娃娃", toggle_ragdoll], ["切开布料", $SoftBodies.cut_cloth], ["重置", reset_lab], ["返回多米诺 / 方块墙", return_to_playground]]:
		var button := Button.new()
		button.text = entry[0]
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(entry[1])
		row.add_child(button)
