extends SceneTree
## Graphical smoke test, run against PROJECT/Box3D物理测试 with its FRP renderer.
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var scene: Node3D = load("res://addons/box3d/examples/soft_ragdoll_lab.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	var valid := PhysicsServer3D.get_class() == "Box3DPhysicsServer3D"
	var camera: Camera3D = scene.get_node("Camera3D")
	var camera_pose := camera.transform
	var drag := InputEventMouseButton.new()
	drag.button_index = MOUSE_BUTTON_RIGHT
	drag.pressed = true
	scene._unhandled_input(drag)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(80, -20)
	scene._unhandled_input(motion)
	valid = valid and camera.rotation.distance_to(camera_pose.basis.get_euler()) > 0.1
	drag.pressed = false
	scene._unhandled_input(drag)
	valid = valid and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
	camera.transform = camera_pose
	for i in 120:
		await process_frame
		RenderingServer.force_draw(false, 1.0 / 60.0)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/softbody-ragdoll-standing.png")
	var cloth: SoftBody3D = scene.get_node("SoftBodies/Cloth")
	var before := PhysicsServer3D.soft_body_get_bounds(cloth.get_physics_rid())
	scene.toggle_ragdoll()
	var projectile: RigidBody3D = scene.shoot_ray(Vector3(0, 3.3, 5), Vector3(0, 0, -1))
	var initial: Dictionary = cloth.call("get_solver_statistics")
	var energy_budget: float = 0.5 * projectile.mass * 400 + projectile.mass * 9.8 * projectile.position.y + initial.kinetic_energy + 9.8 * initial.center_of_mass.y
	var peak_energy := 0.0
	var peak_speed := 0.0
	for i in 360:
		await physics_frame
		var stats: Dictionary = cloth.call("get_solver_statistics")
		var energy: float = stats.kinetic_energy + 9.8 * stats.center_of_mass.y + 0.5 * projectile.mass * projectile.linear_velocity.length_squared() + projectile.mass * 9.8 * projectile.position.y
		peak_energy = maxf(peak_energy, energy)
		peak_speed = maxf(peak_speed, stats.maximum_speed)
		valid = valid and is_finite(energy) and is_finite(stats.maximum_speed)
		RenderingServer.force_draw(false, 1.0 / 60.0)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/softbody-ragdoll-impact.png")
	var after := PhysicsServer3D.soft_body_get_bounds(cloth.get_physics_rid())
	valid = valid and after.size.z > before.size.z + 0.01
	valid = valid and peak_energy < energy_budget * 1.1 and after.position.is_finite() and after.size.is_finite()
	for bone: PhysicalBone3D in scene.actor.physical_bones:
		valid = valid and bone.global_position.y > -0.1
	valid = valid and scene.actor.physical_bones[2].global_position.y < 0.8
	scene.reset_lab()
	await physics_frame
	RenderingServer.force_draw(false, 1.0 / 60.0)
	await RenderingServer.frame_post_draw
	valid = valid and not scene.actor.ragdoll_active
	cloth = scene.get_node("SoftBodies/Cloth")
	var intact: Dictionary = cloth.call("get_solver_statistics")
	valid = valid and intact.tearing_enabled and intact.particles == 2048
	scene.get_node("SoftBodies").cut_cloth()
	var torn: Dictionary = cloth.call("get_solver_statistics")
	valid = valid and torn.torn_seams > 0 and torn.particles > intact.particles
	scene.shoot_ray(Vector3(-3.5, 1.1, 5), Vector3(0, 0, -1))
	for i in 120:
		await physics_frame
		RenderingServer.force_draw(false, 1.0 / 60.0)
	valid = valid and scene.actor.ragdoll_active
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/softbody-ragdoll-torn.png")
	print("BOX3D_SHOWCASE_COMPLETED ", valid, " energy_budget=", energy_budget, " peak_energy=", peak_energy, " peak_speed=", peak_speed, " cloth_before=", before, " cloth_after=", after, " intact=", intact, " torn=", torn)
	scene.queue_free()
	await process_frame
	quit(0 if valid else 1)
