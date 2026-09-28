extends SceneTree
## End-to-end GPU checks for the FRP Height Fog consumer (Unreal exponential
## height fog port) and its FengHeightFog producer.

const FogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")
const FogNode = preload("res://addons/feng-fog/feng_height_fog.gd")

var _renderer: FengRenderer
var _fog_pass: FengPass
var _camera: Camera3D
var _fog: FengHeightFog
var _light: DirectionalLight3D
var _environment: Environment

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> bool:
	if value:
		return true
	push_error("REGRESSION: " + message)
	quit(1)
	return false

func settle(frames := 8) -> void:
	for _index in frames:
		await process_frame
	await RenderingServer.frame_post_draw

func image() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func center(image_value: Image) -> Color:
	return image_value.get_pixel(image_value.get_width() / 2, image_value.get_height() / 2)

func sky_pixel(image_value: Image) -> Color:
	return image_value.get_pixel(image_value.get_width() / 2, image_value.get_height() / 8)

func luminance(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722

func run() -> void:
	print("START FRP Height Fog tests")
	root.msaa_3d = Viewport.MSAA_4X
	var scene := Node3D.new()
	root.add_child(scene)
	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 8.0, 9.0)
	_camera.current = true
	scene.add_child(_camera)
	_camera.look_at(_camera.position + Vector3(0.0, 0.0, -20.0), Vector3.UP)
	var floor_instance := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	floor_instance.mesh = plane
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.15, 0.35, 0.12)
	floor_material.roughness = 0.9
	floor_instance.material_override = floor_material
	scene.add_child(floor_instance)
	# A tall pole into thin air: height falloff is verified on a finite receiver
	# rising above the fog, not on the sky (a sky ray is effectively infinite and
	# saturates under any nonzero density).
	var pole := MeshInstance3D.new()
	var pole_mesh := BoxMesh.new()
	pole_mesh.size = Vector3(2.0, 44.0, 2.0)
	var pole_material := StandardMaterial3D.new()
	pole_material.albedo_color = Color(0.1, 0.15, 0.35)
	pole_material.roughness = 0.9
	pole_mesh.material = pole_material
	pole.mesh = pole_mesh
	pole.position = Vector3(4.0, 22.0, -30.0)
	scene.add_child(pole)

	var world_environment := WorldEnvironment.new()
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_SKY
	_environment.sky = Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.25, 0.35, 0.55)
	sky_material.sky_horizon_color = Color(0.4, 0.4, 0.4)
	sky_material.ground_bottom_color = Color(0.12, 0.12, 0.12)
	sky_material.ground_horizon_color = Color(0.35, 0.3, 0.25)
	_environment.sky.sky_material = sky_material
	world_environment.environment = _environment
	scene.add_child(world_environment)
	_light = DirectionalLight3D.new()
	_light.light_energy = 1.5
	_light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	scene.add_child(_light)

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	var compositor_script = load("res://addons/feng-render-pipeline/compositor.gd")
	_renderer = renderer_script.new()
	for pass_entry in _renderer.passes:
		if pass_entry.stable_id == &"library:height_fog":
			_fog_pass = pass_entry
	if not check(_fog_pass != null and _fog_pass.enabled, "fresh renderer did not seed the enabled Height Fog pass"):
		return
	var compositor: Compositor = compositor_script.new()
	compositor.renderer = _renderer
	_camera.compositor = compositor
	if not check(_renderer.get_validation_warnings().is_empty(), "the default pipeline does not validate: %s" % [_renderer.get_validation_warnings()]):
		return

	# No FengHeightFog node: the seeded pass is a true no-op.
	await settle(14)
	var baseline := await image()
	var baseline_center := center(baseline)
	var baseline_sky := sky_pixel(baseline)
	if not check(luminance(baseline_center) > 0.02, "baseline floor pixel is unexpectedly dark: %s" % baseline_center):
		return
	if not check(baseline_sky.b > baseline_sky.r, "baseline sky is not blue-ish: %s" % baseline_sky):
		return

	# A strong red exponential fog: the sky saturates to the inscattering colour
	# and the floor blends toward it.
	_fog = FogNode.new()
	_fog.fog_density = 2.0
	_fog.fog_inscattering_color = Color(1.0, 0.05, 0.05)
	scene.add_child(_fog)
	await settle(14)
	var target := RenderingServer.viewport_get_render_target(root.get_viewport_rid())
	var matched := false
	for snapshot in FogRuntime.snapshots():
		if snapshot.get("render_targets", []).has(target):
			matched = true
			if not check(absf(float(snapshot.get("fog_density", 0.0)) - 0.2) < 0.001,
					"published snapshot does not carry the meter-scaled fog density"):
				return
	if not check(matched, "fog runtime did not publish a snapshot for this render target"):
		return
	var fogged := await image()
	var fogged_center := center(fogged)
	var fogged_sky := sky_pixel(fogged)
	print("Fogged pixels: floor ", baseline_center, " -> ", fogged_center, "  sky ", baseline_sky, " -> ", fogged_sky)
	if not check(fogged_sky.r > fogged_sky.g * 3.0 and fogged_sky.r > fogged_sky.b * 2.0,
			"the saturated sky did not take the fog inscattering colour: %s" % fogged_sky):
		return
	if not check(fogged_center.r > baseline_center.r * 1.5,
			"the floor did not blend toward the fog colour: %s -> %s" % [baseline_center, fogged_center]):
		return

	# Height falloff attenuates density with altitude: sampled down the pole's
	# screen column, the fogged redness increases monotonically toward the
	# ground while the sky above the horizon stays thin.
	_fog.fog_density = 3.0
	_fog.fog_height_falloff = 4.0
	await settle(12)
	var thin_image := await image()
	var pole_x := 176
	var thin_top := thin_image.get_pixel(pole_x, 45)
	var thin_bottom := thin_image.get_pixel(pole_x, thin_image.get_height() - 95)
	var thin_sky := sky_pixel(thin_image)
	print("Steep falloff: pole top ", thin_top, " pole bottom ", thin_bottom, " sky ", thin_sky)
	if not check(thin_bottom.r > thin_bottom.b + 0.15,
			"a steep falloff should keep the low pole covered: %s" % thin_bottom):
		return
	if not check(thin_bottom.r - thin_bottom.b > thin_top.r - thin_top.b + 0.2,
			"fog density should fall off with height on the pole: top %s bottom %s" % [thin_top, thin_bottom]):
		return
	if not check(thin_sky.b > thin_sky.r,
			"the sky above the horizon should stay thin under a steep falloff: %s" % thin_sky):
		return
	_fog.fog_height_falloff = 0.02
	await settle(12)
	var dense_top := (await image()).get_pixel(pole_x, 45)
	if not check(dense_top.r > dense_top.b, "a flat falloff should fog even the high pole top: %s" % dense_top):
		return
	_fog.fog_height_falloff = 0.2
	await settle(10)

	# Start Distance removes the fog up to the exclusion distance: the floor a
	# few metres ahead of the camera unfogs while the sky keeps the full effect.
	var near_uv := Vector2i(baseline.get_width() / 2, baseline.get_height() - 35)
	var baseline_near := baseline.get_pixelv(near_uv)
	_fog.start_distance = 40.0
	await settle(12)
	var near_image := await image()
	var near_clear := near_image.get_pixelv(near_uv)
	var far_sky := sky_pixel(near_image)
	if not check(absf(near_clear.r - baseline_near.r) < 0.08,
			"Start Distance did not unfog the near floor: %s vs baseline %s" % [near_clear, baseline_near]):
		return
	if not check(far_sky.r > far_sky.b, "Start Distance incorrectly unfogged the sky: %s" % far_sky):
		return
	_fog.start_distance = 0.0

	# Fog Cutoff Distance reverts distant pixels, including the sky.
	_fog.fog_cutoff_distance = 20.0
	await settle(12)
	var cutoff_sky := sky_pixel(await image())
	if not check(cutoff_sky.b > cutoff_sky.r, "Fog Cutoff Distance did not unfog the sky: %s" % cutoff_sky):
		return
	_fog.fog_cutoff_distance = 0.0
	await settle(8)

	# Directional inscattering adds the sun lobe along the view direction. With
	# the fog colour black the sky is dark except in the sun's direction: aim the
	# camera at the sun and the lobe brightens the frame.
	_fog.fog_inscattering_color = Color(0.0, 0.0, 0.0)
	_light.rotation_degrees = Vector3(0.0, 180.0, 0.0)
	_fog.directional_inscattering_color = Color(1.0, 1.0, 1.0)
	_fog.directional_inscattering_exponent = 4.0
	var home_transform := _camera.global_transform
	_camera.look_at_from_position(_camera.position, _camera.position + Vector3(0.0, 0.0, -20.0), Vector3.UP)
	await settle(14)
	var sun_pixel := center(await image())
	_camera.global_transform = home_transform
	if not check(luminance(sun_pixel) > 0.05, "directional inscattering did not brighten the sky toward the sun: %s" % sun_pixel):
		return
	_fog.directional_inscattering_color = Color(0.0, 0.0, 0.0)
	_fog.fog_inscattering_color = Color(1.0, 0.05, 0.05)
	_light.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	await settle(10)

	# Disabling the component returns the frame to the baseline.
	_fog.enabled = false
	await settle(12)
	var off_center := center(await image())
	var off_sky := sky_pixel(await image())
	if not check(off_sky.b > off_sky.r and absf(off_center.r - baseline_center.r) < 0.06,
			"disabling the fog component left fog in the frame: center %s sky %s" % [off_center, off_sky]):
		return
	_fog.enabled = true
	await settle(10)

	# A second viewport renders its own World3D with no FengHeightFog; the
	# world-scoped snapshot must not leak into its target.
	var second_viewport := SubViewport.new()
	second_viewport.size = Vector2i(160, 120)
	second_viewport.own_world_3d = true
	second_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(second_viewport)
	var second_camera := Camera3D.new()
	second_camera.position = Vector3(0.0, 8.0, 9.0)
	second_camera.current = true
	second_viewport.add_child(second_camera)
	second_camera.look_at(second_camera.position + Vector3(0.0, 0.0, -20.0), Vector3.UP)
	var second_floor := MeshInstance3D.new()
	second_floor.mesh = plane
	second_floor.material_override = floor_material
	second_viewport.add_child(second_floor)
	var second_environment := WorldEnvironment.new()
	second_environment.environment = _environment
	second_viewport.add_child(second_environment)
	var second_compositor: Compositor = compositor_script.new()
	second_compositor.renderer = _renderer
	second_camera.compositor = second_compositor
	await settle(18)
	var foreign := second_viewport.get_texture().get_image()
	var foreign_sky := foreign.get_pixel(foreign.get_width() / 2, foreign.get_height() / 8)
	if not check(foreign_sky.b > foreign_sky.r, "height fog leaked into another World3D target: %s" % foreign_sky):
		return

	# Removing the node unpublishes the snapshot and unfogs the frame.
	_fog.queue_free()
	await settle(12)
	var removed := center(await image())
	if not check(absf(removed.r - baseline_center.r) < 0.06, "removing the fog node left fog on screen: %s" % removed):
		return
	print("PASS FRP Height Fog nodes, world isolation, height falloff, start/cutoff distance and sun inscattering")
	quit(0)
