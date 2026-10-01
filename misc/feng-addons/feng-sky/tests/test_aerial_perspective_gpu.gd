extends SceneTree
## End-to-end: opaque, forward fallback, transparent AP and direct sunlight.
## No FengHeightFog node is needed; affect_height_fog remains false throughout.
const Atmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
var failed := false
var viewport: SubViewport
var sky: FengSkyAtmosphere
var sun: DirectionalLight3D
var wall: MeshInstance3D
var renderer
var compositor: Compositor
var camera: Camera3D
var volume: Node3D
const Volume = preload("res://addons/feng-render-pipeline/volume/feng_volume.gd")
const Profile = preload("res://addons/feng-render-pipeline/volume/feng_volume_profile.gd")
const Module = preload("res://addons/feng-render-pipeline/volume/feng_volume_module.gd")
const VolumeRuntime = preload("res://addons/feng-render-pipeline/volume/volume_runtime.gd")

func _initialize() -> void:
	call_deferred("run")

func require(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("REGRESSION: " + message)

func settle(frames := 20) -> void:
	for _i in frames:
		await process_frame
		await RenderingServer.frame_post_draw

func capture(label: String) -> Color:
	if volume != null:
		VolumeRuntime.evaluate_camera([volume], camera, compositor)
	else:
		renderer.apply(compositor)
	await settle()
	var image := viewport.get_texture().get_image()
	var color := image.get_pixel(32, 32)
	require(is_finite(color.r) and is_finite(color.g) and is_finite(color.b), "Non-finite AP result: " + label)
	print("AERIAL GPU ", label, " ", color)
	return color

func material_for(mode: String) -> Material:
	if mode == "opaque":
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.6, 0.6, 0.6)
		return material
	var shader := Shader.new()
	if mode == "fallback":
		shader.code = "shader_type spatial; render_mode unshaded; uniform sampler2D screen : hint_screen_texture, filter_nearest; void fragment() { ALBEDO = vec3(0.6) + textureLod(screen, SCREEN_UV, 0.0).rgb * 0.000001; }"
	else:
		shader.code = "shader_type spatial; render_mode unshaded; void fragment() { ALBEDO = vec3(0.6); ALPHA = 0.99; }"
	var material := ShaderMaterial.new()
	material.shader = shader
	return material

func run() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(65, 65)
	viewport.world_3d = World3D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene := Node3D.new()
	viewport.add_child(scene)
	camera = Camera3D.new()
	camera.position = Vector3(0.0, 100.0, 0.0)
	camera.far = 30000.0
	camera.current = true
	scene.add_child(camera)
	sky = Atmosphere.new()
	sky.affect_height_fog = false
	sky.multi_scattering_factor = 0.0
	sky.rayleigh_scattering_scale = 0.0
	sky.mie_scattering_scale = 0.0
	sky.other_absorption_scale = 0.0
	sky.mie_absorption = Vector3(0.08, 0.16, 0.24)
	sky.mie_exponential_distribution = 1000.0
	sky.aerial_perspective_start_depth = 0.0
	sky.environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	scene.add_child(sky)
	sun = DirectionalLight3D.new()
	sun.light_energy = 0.0
	sun.rotation_degrees = Vector3(-60.0, 0.0, 0.0)
	scene.add_child(sun)
	require(sun.get_base().is_valid(), "Light3D must publish its base RID for exact atmosphere-light matching")
	sky.sun_light = sun
	wall = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(10000.0, 10000.0, 1.0)
	wall.mesh = box
	wall.position = Vector3(0.0, 100.0, -5000.0)
	scene.add_child(wall)
	renderer = load("res://addons/feng-render-pipeline/renderer.gd").new()
	var enabled_count := 0
	for pass_entry in renderer.passes:
		if pass_entry != null and pass_entry.enabled:
			enabled_count += 1
		if pass_entry != null and pass_entry.stable_id == "library:eye_adaptation":
			pass_entry.metering_mode = 2
			pass_entry.apply_physical_camera_exposure = false
			pass_entry.pre_exposure = true
			pass_entry.speed_up = 100.0
			pass_entry.speed_down = 100.0
	require(enabled_count == 13, "AP regression must preserve 13 enabled default passes")
	require(renderer.passes.size() == 14, "AP must not add a new default pass")
	compositor = Compositor.new()
	camera.compositor = compositor
	for mode in ["opaque", "fallback", "transparent"]:
		wall.material_override = material_for(mode)
		sky.aerial_perspective_view_distance_scale = 0.0
		var clear: Color = await capture(mode + "_clear")
		sky.aerial_perspective_view_distance_scale = 1.0
		var hazy: Color = await capture(mode + "_spectral_absorption")
		require(clear.r > 0.05 and hazy.r < clear.r * 0.97, mode + " did not receive AP")
		require(hazy.r > hazy.g and hazy.g > hazy.b, mode + " collapsed RGB extinction")
		sky.render_in_main_pass = false
		var main_disabled: Color = await capture(mode + "_main_pass_disabled")
		require(absf(main_disabled.r - clear.r) < 0.025, mode + " main-pass gate left aerial transport active")
		sky.render_in_main_pass = true
		sky.aerial_perspective_start_depth = 6.0
		var excluded: Color = await capture(mode + "_start_depth")
		require(absf(excluded.r - clear.r) < 0.025, mode + " ignored AP start depth")
		sky.aerial_perspective_start_depth = 0.0
	# Direct scene-light attenuation must happen before deferred lighting and
	# before native forward material BRDFs, without changing authored Light3D.
	sky.aerial_perspective_view_distance_scale = 0.0
	sky.mie_absorption = Vector3.ONE * 0.01
	sun.light_energy = 1.0
	sun.light_intensity_lux = 6.0
	for mode in ["opaque", "vertex", "fallback", "transparent"]:
		if mode == "opaque" or mode == "vertex":
			var material := StandardMaterial3D.new()
			material.albedo_color = Color(0.6, 0.6, 0.6)
			material.roughness = 1.0
			if mode == "vertex":
				material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
			wall.material_override = material
		else:
			var shader := Shader.new()
			shader.code = "shader_type spatial; uniform sampler2D screen : hint_screen_texture; void fragment() { ALBEDO = vec3(0.6) + textureLod(screen, SCREEN_UV, 0.0).rgb * 0.000001; ROUGHNESS = 1.0; }" if mode == "fallback" else "shader_type spatial; void fragment() { ALBEDO = vec3(0.6); ROUGHNESS = 1.0; ALPHA = 0.99; }"
			var material := ShaderMaterial.new()
			material.shader = shader
			wall.material_override = material
		sky.atmosphere_enabled = false
		var raw: Color = await capture(mode + "_direct_unattenuated")
		sky.atmosphere_enabled = true
		var transmitted: Color = await capture(mode + "_direct_atmospheric_transmittance")
		require(raw.r > 0.03 and transmitted.r < raw.r * 0.97, mode + " sunlight ignored atmosphere transmission")
		sky.render_in_main_pass = false
		var main_disabled_direct: Color = await capture(mode + "_main_disabled_direct_transmission")
		require(absf(main_disabled_direct.r - transmitted.r) < 0.025, mode + " main-pass gate suppressed secondary direct-light transport")
		sky.render_in_main_pass = true
	# An actual active Volume uses ViewPass wrappers around the executor.
	# Its preflight must still arrive before direct-light buffer consumption.
	var fog_pass: FengPass
	for entry in renderer.passes:
		if entry.stable_id == "library:height_fog":
			fog_pass = entry
	var module := Module.from_pass(fog_pass)
	module.set("parameters/parameters", Vector4(0.75, 1.0, 1.0, 1.0))
	var profile := Profile.new()
	profile.modules = [module]
	volume = Volume.new()
	volume.unbound = true
	volume.profile = profile
	scene.add_child(volume)
	compositor = load("res://addons/feng-render-pipeline/compositor.gd").new()
	compositor.renderer = renderer
	camera.compositor = compositor
	sky.atmosphere_enabled = false
	var volume_raw: Color = await capture("active_volume_direct_unattenuated")
	sky.atmosphere_enabled = true
	var volume_transmitted: Color = await capture("active_volume_direct_transmittance")
	require(not compositor.get_volume_parameters().is_empty(), "Volume fixture did not activate overrides")
	require(volume_transmitted.r < volume_raw.r * 0.97, "ViewPass lost atmospheric metadata before Lighting")
	# Secondary slot is selected by identity, even when both light directions
	# are identical and the primary slot has zero energy.
	var secondary := DirectionalLight3D.new()
	secondary.rotation = sun.rotation
	secondary.light_energy = 1.0
	secondary.light_intensity_lux = 6.0
	scene.add_child(secondary)
	sun.light_energy = 0.0
	sky.secondary_sun_light = secondary
	sky.atmosphere_enabled = false
	var secondary_raw: Color = await capture("secondary_slot_unattenuated")
	sky.atmosphere_enabled = true
	var secondary_transmitted: Color = await capture("secondary_slot_transmittance")
	require(secondary_transmitted.r < secondary_raw.r * 0.97, "Secondary light RID did not reach the matching native slot")
	# Isolate AP in-scattering against an unlit black surface, proving the
	# documented UE distinction: MS affects slot 0, never slot 1.
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color.BLACK
	wall.material_override = black
	sky.aerial_perspective_view_distance_scale = 1.0
	sky.rayleigh_scattering_scale = 1.0
	sky.rayleigh_scattering = Vector3(0.03, 0.05, 0.1)
	sky.mie_scattering_scale = 1.0
	sky.mie_scattering = Vector3.ONE * 0.01
	sky.mie_absorption = Vector3.ONE * 0.001
	sky.mie_exponential_distribution = 1.2
	sky.multi_scattering_factor = 0.0
	var secondary_single: Color = await capture("secondary_single_scattering")
	sky.multi_scattering_factor = 2.0
	var secondary_ms_control: Color = await capture("secondary_ignores_multiple_scattering")
	require(absf(secondary_single.r - secondary_ms_control.r) + absf(secondary_single.g - secondary_ms_control.g) + absf(secondary_single.b - secondary_ms_control.b) < 0.03,
		"Secondary AP light incorrectly received multiple scattering")
	secondary.light_energy = 0.0
	sun.light_energy = 1.0
	sky.multi_scattering_factor = 0.0
	var primary_single: Color = await capture("primary_single_scattering")
	sky.multi_scattering_factor = 2.0
	var primary_multiple: Color = await capture("primary_multiple_scattering")
	require(primary_multiple.r + primary_multiple.g + primary_multiple.b > primary_single.r + primary_single.g + primary_single.b + 0.005,
		"Primary AP light did not receive multiple scattering")
	VolumeRuntime.forget_camera(compositor)
	require(sun.light_energy == 1.0 and sun.light_color == Color.WHITE and sun.light_intensity_lux == 6.0, "Atmosphere mutated authored light parameters")
	viewport.free()
	await process_frame
	print("AERIAL PERSPECTIVE GPU PASS" if not failed else "AERIAL PERSPECTIVE GPU FAIL")
	quit(0 if not failed else 1)
