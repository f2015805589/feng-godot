extends SceneTree
## End-to-end GPU checks for the FRP Magic GI consumer and its debug output.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const Runtime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")

var _renderer: FengRenderer
var _compositor: FengCompositor
var _magic_pass: FengPass
var _debug_pass: FengPass
var _volume: Node3D
var _camera: Camera3D
var _surface: MeshInstance3D
var _material: StandardMaterial3D
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

func luminance(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722

func max_channel(color: Color) -> float:
	return maxf(color.r, maxf(color.g, color.b))

func color_delta(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()

func find_pass(stable_id: String) -> FengPass:
	for pass_entry in _renderer.passes:
		if pass_entry.stable_id == stable_id:
			return pass_entry
	return null

func make_test_bake() -> Resource:
	var data = Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = _volume.grid_dimensions()
	data.volume_size = _volume.size
	data.spacing = _volume.probe_spacing
	data.surface_offset = _volume.surface_offset
	data.volume_transform = _volume.global_transform
	data.world_to_grid = _volume.world_to_grid_transform()
	data.bake_samples = _volume.bake_samples
	data.bake_bounces = _volume.bake_bounces
	data.bake_distance = _volume.bake_distance
	data.terrain_reflectance = _volume.terrain_reflectance
	data.material_reflectance = _volume.fallback_material_reflectance
	data.positions = _volume.probe_positions.duplicate()
	data.normals = _volume.probe_normals.duplicate()
	data.transfer.resize(data.positions.size() * 27)
	data.transfer.fill(0.0)
	for probe in data.positions.size():
		# A stable DC-only fixture isolates the live SH lighting, receiver material,
		# world reconstruction and GPU lookup from the CPU baker's ray variance.
		data.transfer[probe * 27] = 0.28
		data.transfer[probe * 27 + 1] = 0.28
		data.transfer[probe * 27 + 2] = 0.28
	data.scene_signature = Baker.signature_for_geometry(_volume._current_scene_signature)
	data.bake_version = Time.get_ticks_usec()
	if not data.build_cell_indices():
		return null
	return data

func frame_for(mode: int) -> Image:
	_debug_pass.set("buffer", mode)
	await settle()
	return await image()

func nonzero_texels(image_value: Image, threshold := 0.04) -> int:
	var count := 0
	for y in image_value.get_height():
		for x in image_value.get_width():
			if max_channel(image_value.get_pixel(x, y)) > threshold:
				count += 1
	return count

func changed_texels(a: Image, b: Image, threshold := 0.02) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			if color_delta(a.get_pixel(x, y), b.get_pixel(x, y)) > threshold:
				count += 1
	return count

func run() -> void:
	print("START FRP Magic GI D3D12 tests")
	root.msaa_3d = Viewport.MSAA_4X
	root.use_taa = false
	var scene := Node3D.new()
	root.add_child(scene)
	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 3.0, 5.0)
	_camera.current = true
	scene.add_child(_camera)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	_surface = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8.0, 8.0)
	_surface.mesh = plane
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.75, 0.4, 0.2)
	_material.metallic = 0.2
	_material.roughness = 0.35
	_surface.material_override = _material
	scene.add_child(_surface)

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
	_light.light_color = Color(1.0, 0.1, 0.05)
	_light.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
	scene.add_child(_light)

	var magic_script = load("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
	if not check(magic_script != null, "Magic GI Volume script did not load"):
		return
	_volume = magic_script.new()
	_volume.size = Vector3(8.0, 4.0, 8.0)
	_volume.position = Vector3(0.0, 2.0, 0.0) # The floor lies exactly on the volume's minimum Y face.
	_volume.probe_spacing = 1.0
	_volume.surface_offset = 0.03
	_volume.bake_samples = 1
	_volume.bake_bounces = 1
	_volume.bake_distance = 8.0
	_volume.sun = _light
	_volume.lighting_environment = _environment
	_volume.show_probes = false
	scene.add_child(_volume)
	await settle(12)
	_volume.refresh_surface_points()
	if not check(_volume.probe_positions.size() > 0, "surface placement found no floor probes on the volume minimum face"):
		return

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	var compositor_script = load("res://addons/feng-render-pipeline/compositor.gd")
	_renderer = renderer_script.new()
	_magic_pass = find_pass("library:magic_gi")
	_debug_pass = find_pass("library:debug_buffers")
	if not check(_magic_pass != null and _magic_pass.enabled, "fresh renderer did not seed enabled Magic GI"):
		return
	if not check(_debug_pass != null and not _debug_pass.enabled, "fresh renderer did not seed disabled Debug Buffers"):
		return
	_compositor = compositor_script.new()
	_compositor.renderer = _renderer
	_camera.compositor = _compositor
	if not check(_renderer.get_validation_warnings().is_empty(), "the default pipeline does not validate: %s" % [_renderer.get_validation_warnings()]):
		return

	# The managed debug output is already black with no bake and remains a valid
	# pipeline. This checks the optional producer path before creating any bake.
	_debug_pass.enabled = true
	_debug_pass.set("buffer", 6)
	await settle(12)
	var no_bake := center(await image())
	if not check(max_channel(no_bake) < 0.02, "Magic GI debug output was not black with no producer: %s" % [no_bake]):
		return

	var data := make_test_bake()
	if not check(data != null and data.is_valid(), "synthetic v2 surface transfer fixture failed validation"):
		return
	_volume.bake_data = data
	_volume.refresh_surface_points()
	data.scene_signature = Baker.signature_for_geometry(_volume._current_scene_signature)
	if not check(_volume.has_bake(), "volume rejected the v2 surface bake layout or scene signature"):
		return
	Runtime.publish(_volume)
	await settle(16)
	var current_target: RID = RenderingServer.viewport_get_render_target(root.get_viewport_rid())
	var matching_snapshot := false
	for snapshot in Runtime.snapshots():
		if snapshot.get("render_targets", []).has(current_target):
			matching_snapshot = true
	if not check(matching_snapshot, "runtime did not publish a snapshot for the current render target"):
		return
	var gi_on := await image()
	var gi_pixel := center(gi_on)
	print("Synthetic PRT GI pixel: ", gi_pixel, " probes=", data.probe_count())
	if not check(max_channel(gi_pixel) > 0.08, "GPU Magic GI pass produced no indirect contribution at the floor center"):
		return

	# Changing a light colour updates the live SH coefficients without rebuilding or
	# changing the geometry-only transfer payload.
	var transfer_version: int = data.bake_version
	_light.light_color = Color(0.05, 0.15, 1.0)
	await settle(12)
	var blue_pixel := center(await image())
	print("Live sun changed GI pixel: ", blue_pixel)
	if not check(blue_pixel.r < gi_pixel.r * 0.6 and blue_pixel.b > gi_pixel.b * 1.5,
			"changing the directional sun did not update the GI colour"):
		return
	if not check(data.bake_version == transfer_version, "dynamic lighting unexpectedly rebaked the PRT data"):
		return

	# Remove the explicit sun and vary the actual sky material. Runtime projects the
	# refreshed panorama into lighting SH while preserving the same PRT bake.
	_volume.sun = null
	_light.visible = false
	var sky_blue := center(await image())
	sky_material.sky_top_color = Color(1.0, 0.05, 0.02)
	await create_timer(0.4).timeout # The environment panorama cache refreshes at 250 ms.
	await settle(4)
	var sky_red := center(await image())
	print("Live environment changed GI pixel: ", sky_blue, " -> ", sky_red)
	if not check(max_channel(sky_blue) > 0.03 and sky_red.r > sky_red.b * 1.3,
			"changing the World3D sky did not update the GI colour"):
		return

	# At the center the ray remains aimed at the same floor point while the camera
	# translates and rotates. This catches a projection inverse being mistaken for a
	# complete world-to-view transform and a view-space normal left in view space.
	var camera_reference := center(await image())
	_camera.position = Vector3(0.35, 3.4, 4.8)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	await settle(10)
	var camera_moved := center(await image())
	print("Camera motion GI pixel: ", camera_reference, " -> ", camera_moved)
	if not check(color_delta(camera_moved, camera_reference) < 0.12,
			"moving/rotating the camera changed the center GI contribution or detached it from the world surface"):
		return

	# All seven declarations must route to actual GBuffer/pipeline inputs. The motion
	# channel gets a moving camera; the others are checked against material attributes.
	_camera.position = Vector3(0.0, 3.0, 5.0)
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	var debug_pixels: Array[Color] = []
	for mode in 7:
		var view := await frame_for(mode)
		var pixel := center(view)
		debug_pixels.append(pixel)
		print("Debug buffer ", mode, " center=", pixel, " nonzero=", nonzero_texels(view))
		if not check(mode == 5 or nonzero_texels(view) > 8,
				"debug buffer %d did not produce a visible diagnostic" % mode):
			return
	if not check(debug_pixels[0].r > debug_pixels[0].g and debug_pixels[0].g > debug_pixels[0].b * 1.2,
			"Diffuse debug view did not preserve the receiver albedo"):
		return
	if not check(debug_pixels[2].r > debug_pixels[3].r and debug_pixels[4].r > 0.02,
			"AO, roughness and metallic debug channels are not independently readable"):
		return
	_debug_pass.set("buffer", 5)
	await settle(10)
	if not check(_debug_pass.needs_motion_vectors,
			"selecting Motion Vectors did not request the FRP velocity attachment"):
		return
	var motion_reference := await image()
	var motion_view: Image
	for _frame in 8:
		_camera.position.x += 0.05
		await process_frame
		await RenderingServer.frame_post_draw
		motion_view = root.get_texture().get_image()
	var changed_motion_texels := changed_texels(motion_reference, motion_view)
	var moving_center := center(motion_view)
	var center_velocity := maxf(absf(moving_center.r - 0.5), absf(moving_center.g - 0.5))
	print("Motion debug camera movement changed ", changed_motion_texels,
		" pixels; center=", center(motion_reference), " -> ", moving_center)
	if not check(nonzero_texels(motion_view) > 8 and changed_motion_texels > 16 and center_velocity > 0.01,
			"motion-vector debug view did not reflect a moving camera"):
		return

	# A second viewport renders the same floor in a distinct World3D, but it has no
	# Magic GI volume. The world-scoped snapshot must not leak into this target.
	var second_viewport := SubViewport.new()
	second_viewport.size = Vector2i(160, 120)
	second_viewport.own_world_3d = true
	second_viewport.msaa_3d = Viewport.MSAA_4X
	second_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(second_viewport)
	var second_camera := Camera3D.new()
	second_camera.position = Vector3(0.0, 3.0, 5.0)
	second_camera.current = true
	second_viewport.add_child(second_camera)
	second_camera.look_at(Vector3.ZERO, Vector3.UP)
	var second_plane := MeshInstance3D.new()
	second_plane.mesh = plane
	second_plane.material_override = _material
	second_viewport.add_child(second_plane)
	var second_compositor = compositor_script.new()
	second_compositor.renderer = _renderer
	second_camera.compositor = second_compositor
	_debug_pass.set("buffer", 6)
	await settle(18)
	var foreign_pixel := second_viewport.get_texture().get_image().get_pixel(80, 60)
	if not check(max_channel(foreign_pixel) < 0.02, "Magic GI lighting leaked into a different World3D render target: %s" % [foreign_pixel]):
		return

	# Turn off the producer after it has rendered nonzero data. The texture manager
	# drops its output scope, and the debug pass must clear/present black instead of a
	# stale previous-frame image.
	_magic_pass.enabled = false
	await settle(12)
	var disabled_pixel := center(await image())
	if not check(max_channel(disabled_pixel) < 0.02, "disabling Magic GI left stale output in the debug view: %s" % [disabled_pixel]):
		return
	_magic_pass.enabled = true
	await settle(12)
	if not check(max_channel(center(await image())) > 0.03, "reenabling Magic GI did not recreate its output"):
		return

	# Consume a bake produced by the CPU baker through the real D3D12 pass as well.
	# This also exercises cache replacement (synthetic fixture -> persisted PRT v2)
	# before the process exits and releases the pass-owned GPU resources.
	var red_wall := MeshInstance3D.new()
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(0.08, 3.0, 4.0)
	var wall_material := StandardMaterial3D.new()
	wall_material.albedo_color = Color.WHITE
	wall_mesh.material = wall_material
	red_wall.mesh = wall_mesh
	red_wall.position = Vector3(1.0, 1.5, 0.0)
	scene.add_child(red_wall)
	_volume.bake_samples = 128
	_volume.bake_bounces = 1
	_volume.sun = _light
	_light.visible = true
	_light.light_color = Color.RED
	_volume.refresh_surface_points()
	await settle(4)
	var real_bake_succeeded: bool = await _volume.bake()
	if not check(real_bake_succeeded and _volume.has_bake(), "CPU baker did not produce a valid PRT v2 resource for the GPU pass"):
		return
	var actual_data: Resource = _volume.bake_data
	var actual_transfer_energy := 0.0
	for coefficient in actual_data.transfer:
		actual_transfer_energy += absf(coefficient)
	if not check(actual_transfer_energy > 0.001, "real bake produced no geometry transfer coefficients"):
		return
	Runtime.publish(_volume)
	await settle(20)
	var actual_red_pixel := center(await image())
	print("Actual baked PRT GI pixel: ", actual_red_pixel, " probes=", actual_data.probe_count(),
		" transfer_l1=", actual_transfer_energy)
	if not check(max_channel(actual_red_pixel) > 0.02,
			"the actual CPU-baked PRT resource produced a black D3D12 GI result"):
		return
	var actual_transfer_version: int = actual_data.bake_version
	_light.light_color = Color.BLUE
	await settle(12)
	var actual_blue_pixel := center(await image())
	print("Actual baked PRT live-sun pixel: ", actual_blue_pixel)
	if not check(color_delta(actual_blue_pixel, actual_red_pixel) > 0.015,
			"changing sunlight did not change the actual baked PRT GPU result"):
		return
	if not check(actual_data.bake_version == actual_transfer_version,
			"live sunlight changed the actual baked transfer version"):
		return
	var remaining: Array[FengPass] = _renderer.passes.duplicate()
	remaining.erase(_magic_pass)
	_renderer.passes = remaining
	await settle(12)
	var deleted_pixel := center(await image())
	if not check(max_channel(deleted_pixel) < 0.02 and _renderer._deleted_library_ids.has("library:magic_gi"),
			"deleting Magic GI did not blacken the debug output and record its tombstone"):
		return
	if not check(_renderer.get_validation_warnings().is_empty(), "removing the optional GI producer invalidated the pipeline"):
		return

	print("PASS Magic GI dynamic lighting, camera transform, seven debug channels and viewport routing")
	second_viewport.queue_free()
	scene.queue_free()
	await process_frame
	quit()
