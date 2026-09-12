extends SceneTree

var scene: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var failed := false

func _initialize() -> void:
	call_deferred("run")

func capture() -> Image:
	for frame in 12: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func mean_center(image: Image) -> Vector3:
	var result := Vector3.ZERO
	var center := image.get_size() / 2
	for y in range(center.y - 3, center.y + 4):
		for x in range(center.x - 3, center.x + 4):
			var c := image.get_pixel(x, y)
			result += Vector3(c.r, c.g, c.b)
	return result / 49.0

func run() -> void:
	scene = Node3D.new()
	root.add_child(scene)
	var plane := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(128, 128)
	plane.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.5, 0.3, 0.1)
	material.roughness = 1.0
	plane.material_override = material
	scene.add_child(plane)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 150, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 100
	scene.add_child(sun)
	camera = Camera3D.new()
	camera.position = Vector3(750, 300, 0)
	camera.far = 4000
	scene.add_child(camera)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	var far_shadow := await capture()
	sun.shadow_enabled = false
	var far_clear := await capture()
	var shadow_color := mean_center(far_shadow)
	var clear_color := mean_center(far_clear)
	var delta := shadow_color.distance_to(clear_color)
	print("SHADOW_RANGE far_on=", shadow_color, " far_off=", clear_color, " delta=", delta)
	if clear_color.x < 0.15 or delta > 0.02:
		push_error("REGRESSION distant geometry samples shadows outside cascade coverage")
		failed = true
	# Verify the repair preserves real nearby shadows.
	camera.position = Vector3(18, 22, 30)
	camera.look_at(Vector3.ZERO)
	var caster := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(5, 7, 5)
	caster.mesh = box
	caster.position.y = 3.5
	caster.material_override = material
	scene.add_child(caster)
	var near_clear := await capture()
	sun.shadow_enabled = true
	var near_shadow := await capture()
	var shadow_pixels := 0
	for y in near_clear.get_height():
		for x in near_clear.get_width():
			if near_clear.get_pixel(x, y).r - near_shadow.get_pixel(x, y).r > 0.04: shadow_pixels += 1
	print("SHADOW_RANGE near_shadow_pixels=", shadow_pixels)
	if shadow_pixels < 20:
		push_error("REGRESSION nearby cast shadows disappeared")
		failed = true
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		far_shadow.save_png(args[0].path_join("far-shadow.png"))
		far_clear.save_png(args[0].path_join("far-reference.png"))
		near_shadow.save_png(args[0].path_join("near-shadow.png"))
	scene.queue_free()
	await process_frame
	if not failed: print("PASS FRP distant shadow fade and nearby shadow preservation")
	quit(1 if failed else 0)
