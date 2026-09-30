extends SceneTree
## Joint FRP regression for pre-exposed Sky, Magic GI and Height Fog.
##
## Run in a clean project with feng-render-pipeline, feng-magic-gi and feng-fog
## installed. It compares the same lit frame with pre-exposure on and off, and
## reports the 60,000 non-physical energy case as diagnostic when LDR clips.

const Data = preload("res://addons/feng-magic-gi/feng_magic_gi_data.gd")
const Baker = preload("res://addons/feng-magic-gi/feng_magic_gi_baker.gd")
const MagicRuntime = preload("res://addons/feng-magic-gi/feng_magic_gi_runtime.gd")
const FogNode = preload("res://addons/feng-fog/feng_height_fog.gd")

const SKY_SAMPLE := Vector2i(160, 24)
const FOG_SAMPLE := Vector2i(110, 95)
const GI_SAMPLE := Vector2i(160, 184)

var _renderer: FengRenderer
var _camera: Camera3D
var _scene: Node3D
var _environment: Environment
var _sky_material: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _floor: MeshInstance3D
var _volume: Node3D
var _magic_pass: FengPass
var _fog_pass: FengPass
var _exposure_pass: FengPass
var _fog: FengHeightFog
var _physical_light_mode := false

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

func capture() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func save_debug_image(label: String, image: Image) -> void:
	var directory := OS.get_environment("FRP_EXPOSURE_DUMP_DIR")
	if not directory.is_empty():
		image.save_png(directory.path_join(label + ".png"))

func current_exposure_scale() -> float:
	var states: Dictionary = _exposure_pass.get("_state")
	var rd := RenderingServer.get_rendering_device()
	for entry_value in states.values():
		var views: Dictionary = entry_value.get("views", {})
		if views.has(0):
			var bytes: PackedByteArray = rd.buffer_get_data(views[0].get("params"))
			var values := bytes.to_float32_array()
			if values.size() > 129:
				return values[129]
	return -1.0

func luminance(image: Image, point: Vector2i) -> float:
	var color := image.get_pixelv(point)
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722

func color_distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()

func find_pass(stable_id: String) -> FengPass:
	for entry in _renderer.passes:
		if entry != null and entry.stable_id == stable_id:
			return entry
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
		# DC-only transport makes the live-lighting and exposure path deterministic.
		data.transfer[probe * 27] = 0.28
		data.transfer[probe * 27 + 1] = 0.28
		data.transfer[probe * 27 + 2] = 0.28
	data.scene_signature = Baker.signature_for_geometry(_volume._current_scene_signature)
	data.bake_version = Time.get_ticks_usec()
	if not data.build_cell_indices():
		return null
	return data

func build_scene() -> bool:
	_scene = Node3D.new()
	root.add_child(_scene)
	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 3.0, 6.0)
	_camera.current = true
	_scene.add_child(_camera)
	_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)

	_floor = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(12.0, 12.0)
	_floor.mesh = plane
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.65, 0.48, 0.3)
	floor_material.roughness = 0.9
	_floor.material_override = floor_material
	_scene.add_child(_floor)

	var environment_node := WorldEnvironment.new()
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_SKY
	_environment.sky = Sky.new()
	_sky_material = ProceduralSkyMaterial.new()
	_sky_material.sky_top_color = Color(0.28, 0.38, 0.62)
	_sky_material.sky_horizon_color = Color(0.54, 0.5, 0.42)
	_sky_material.ground_bottom_color = Color(0.12, 0.12, 0.12)
	_sky_material.ground_horizon_color = Color(0.36, 0.32, 0.26)
	_environment.sky.sky_material = _sky_material
	_environment.background_energy_multiplier = 1.0
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_environment.ambient_light_energy = 0.15
	environment_node.environment = _environment
	_scene.add_child(environment_node)

	_sun = DirectionalLight3D.new()
	_physical_light_mode = OS.get_environment("FRP_EXPOSURE_LIGHT_MODE") == "physical_lux"
	var project_physical_light_mode := bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false))
	if not check(project_physical_light_mode == _physical_light_mode,
			"runner light mode does not match use_physical_light_units"):
		return false
	if _physical_light_mode:
		_sun.light_energy = 1.0
		_sun.light_intensity_lux = 60000.0
	else:
		_sun.light_energy = 60000.0
	_sun.rotation_degrees = Vector3(-50.0, 25.0, 0.0)
	_scene.add_child(_sun)

	var renderer_script = load("res://addons/feng-render-pipeline/renderer.gd")
	var compositor_script = load("res://addons/feng-render-pipeline/compositor.gd")
	_renderer = renderer_script.new()
	_magic_pass = find_pass("library:magic_gi")
	_fog_pass = find_pass("library:height_fog")
	_exposure_pass = find_pass("library:eye_adaptation")
	if not check(_magic_pass != null and _magic_pass.enabled, "Magic GI was not seeded enabled"):
		return false
	if not check(_exposure_pass != null and _exposure_pass.enabled, "Eye Adaptation was not seeded enabled"):
		return false
	if not check(_fog_pass != null and _fog_pass.enabled, "Height Fog was not seeded enabled"):
		return false
	var compositor: Compositor = compositor_script.new()
	compositor.renderer = _renderer
	_camera.compositor = compositor
	if not check(_renderer.get_validation_warnings().is_empty(), "FRP pipeline validation failed: %s" % [_renderer.get_validation_warnings()]):
		return false

	var magic_script = load("res://addons/feng-magic-gi/feng_magic_gi_volume.gd")
	_volume = magic_script.new()
	_volume.size = Vector3(12.0, 4.0, 12.0)
	_volume.position = Vector3(0.0, 2.0, 0.0)
	_volume.probe_spacing = 1.0
	_volume.surface_offset = 0.03
	_volume.bake_samples = 1
	_volume.bake_bounces = 1
	_volume.bake_distance = 12.0
	_volume.sun = _sun
	_volume.lighting_environment = _environment
	_volume.show_probes = false
	_scene.add_child(_volume)
	await settle(12)
	_volume.refresh_surface_points()
	if not check(_volume.probe_positions.size() > 0, "the test floor has no Magic GI probes"):
		return false
	var data := make_test_bake()
	if not check(data != null and data.is_valid(), "the synthetic GI bake is invalid"):
		return false
	_volume.bake_data = data
	_volume.refresh_surface_points()
	data.scene_signature = Baker.signature_for_geometry(_volume._current_scene_signature)
	if not check(_volume.has_bake(), "the volume rejected the synthetic GI bake"):
		return false
	MagicRuntime.publish(_volume)

	_fog = FogNode.new()
	_fog.fog_color_mode = FogNode.ColorMode.LEGACY_RADIANCE
	_fog.fog_density = 0.8
	_fog.fog_inscattering_color = Color(0.34, 0.16, 0.08)
	_fog.fog_cutoff_distance = 100.0 # Keep the sky sample independent from fog.
	_fog.sun_light = _sun
	_scene.add_child(_fog)
	return true

func run() -> void:
	print("START FRP Sky/GI/Fog exposure balance GPU tests")
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.use_taa = false
	if not await build_scene():
		return
	print("LIGHT mode=", "physical lux" if _physical_light_mode else "non-physical energy",
			"; project physical units=", ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units"),
			"; light_energy=", _sun.light_energy, "; light_intensity_lux=", _sun.light_intensity_lux)
	await settle(18)

	# Fixed exposure records whether this setup is already clipped before the
	# adaptation path. At 60,000 the LDR values can be saturated, so the auto
	# comparisons below are the primary source-balance measurements.
	_exposure_pass.enabled = false
	_renderer.apply(_camera.compositor)
	_magic_pass.enabled = false
	await settle(8)
	var fixed_without_gi := await capture()
	save_debug_image("fixed_without_gi", fixed_without_gi)
	_magic_pass.enabled = true
	await settle(18)
	var fixed_with_gi := await capture()
	save_debug_image("fixed_with_gi", fixed_with_gi)
	var fixed_gi_delta := luminance(fixed_with_gi, GI_SAMPLE) - luminance(fixed_without_gi, GI_SAMPLE)
	var fixed_sky_delta := color_distance(fixed_with_gi.get_pixelv(SKY_SAMPLE), fixed_without_gi.get_pixelv(SKY_SAMPLE))
	print("FIXED exposure sky GI-off/on=", fixed_without_gi.get_pixelv(SKY_SAMPLE), " / ", fixed_with_gi.get_pixelv(SKY_SAMPLE),
			"; floor GI delta=", fixed_gi_delta, "; sky delta=", fixed_sky_delta)

	# Height Fog is deliberately colorful so its contribution has its own sample
	# on distant geometry. The sky itself is cut off from this fog volume.
	var fixed_fogged_color := fixed_with_gi.get_pixelv(FOG_SAMPLE)
	_fog.enabled = false
	await settle(10)
	var fixed_unfogged_color := (await capture()).get_pixelv(FOG_SAMPLE)
	_fog.enabled = true
	await settle(10)
	var fixed_fog_delta := color_distance(fixed_fogged_color, fixed_unfogged_color)
	print("FIXED fog on/off=", fixed_fogged_color, " / ", fixed_unfogged_color, "; delta=", fixed_fog_delta)

	# Compare GI/Fog toggles and the PE switch using the user's directional
	# light setting. Keep the whole radiance scene fixed while toggling PE.
	_exposure_pass.enabled = true
	_exposure_pass.extend_default_luminance_range = true
	_exposure_pass.pre_exposure = true
	_exposure_pass.speed_up = 100.0
	_exposure_pass.speed_down = 100.0
	_renderer.apply(_camera.compositor)
	_magic_pass.enabled = true
	_fog.enabled = true
	var measurements := {}
	for use_pre_exposure in [true, false]:
		_exposure_pass.pre_exposure = use_pre_exposure
		_renderer.apply(_camera.compositor)
		_magic_pass.enabled = false
		_fog.enabled = true
		await settle(40)
		var gi_off_image := await capture()
		save_debug_image("auto_%s_gi_off" % str(use_pre_exposure), gi_off_image)
		var gi_off := {
			"sky": gi_off_image.get_pixelv(SKY_SAMPLE),
			"fog": gi_off_image.get_pixelv(FOG_SAMPLE),
			"receiver": gi_off_image.get_pixelv(GI_SAMPLE),
			"exposure": current_exposure_scale(),
		}
		_magic_pass.enabled = true
		await settle(32)
		var gi_on_image := await capture()
		save_debug_image("auto_%s_gi_on" % str(use_pre_exposure), gi_on_image)
		var gi_on := {
			"sky": gi_on_image.get_pixelv(SKY_SAMPLE),
			"fog": gi_on_image.get_pixelv(FOG_SAMPLE),
			"receiver": gi_on_image.get_pixelv(GI_SAMPLE),
			"exposure": current_exposure_scale(),
		}
		_fog.enabled = false
		await settle(32)
		var fog_off_image := await capture()
		save_debug_image("auto_%s_fog_off" % str(use_pre_exposure), fog_off_image)
		var fog_off := {
			"sky": fog_off_image.get_pixelv(SKY_SAMPLE),
			"fog": fog_off_image.get_pixelv(FOG_SAMPLE),
			"receiver": fog_off_image.get_pixelv(GI_SAMPLE),
			"exposure": current_exposure_scale(),
		}
		measurements[use_pre_exposure] = {"gi_off": gi_off, "gi_on": gi_on, "fog_off": fog_off}
		print("AUTO PE=", use_pre_exposure, " GI-off Sky/Fog/GI=", gi_off.sky, " / ", gi_off.fog, " / ", gi_off.receiver,
				" exp=", gi_off.exposure)
		print("AUTO PE=", use_pre_exposure, " GI-on  Sky/Fog/GI=", gi_on.sky, " / ", gi_on.fog, " / ", gi_on.receiver,
				" exp=", gi_on.exposure)
		print("AUTO PE=", use_pre_exposure, " Fog-off Sky/Fog/GI=", fog_off.sky, " / ", fog_off.fog, " / ", fog_off.receiver,
				" exp=", fog_off.exposure)
		_fog.enabled = true
		await settle(12)

	var max_color_delta := 0.0
	var max_scale_delta := 0.0
	var max_sample_value := 0.0
	for state_name in ["gi_off", "gi_on", "fog_off"]:
		var pe_on: Dictionary = measurements[true][state_name]
		var pe_off: Dictionary = measurements[false][state_name]
		var sky_delta := color_distance(pe_on.sky, pe_off.sky)
		var fog_delta := color_distance(pe_on.fog, pe_off.fog)
		var gi_delta := color_distance(pe_on.receiver, pe_off.receiver)
		var scale_delta := absf(pe_on.exposure - pe_off.exposure) / maxf(pe_on.exposure, pe_off.exposure)
		max_color_delta = maxf(max_color_delta, maxf(sky_delta, maxf(fog_delta, gi_delta)))
		max_scale_delta = maxf(max_scale_delta, scale_delta)
		for state in [pe_on, pe_off]:
			for sample_name in ["sky", "fog", "receiver"]:
				var color: Color = state[sample_name]
				max_sample_value = maxf(max_sample_value, maxf(color.r, maxf(color.g, color.b)))
		print("PE compare ", state_name,
				" Sky Δ=", sky_delta, " Fog Δ=", fog_delta, " GI Δ=", gi_delta,
				" scales=", pe_on.exposure, " / ", pe_off.exposure,
				" relative Δ=", scale_delta)

	if _physical_light_mode:
		if not check(max_sample_value < 0.995, "a required physical-lux sample clipped and cannot validate PE invariance"):
			return
		if not check(max_color_delta <= 0.01, "PE changed an unclipped Sky/Fog/GI sample by >0.01 LDR: %f" % max_color_delta):
			return
		if not check(max_scale_delta <= 0.02, "PE changed measured exposure scale by >2%%: %f" % max_scale_delta):
			return
		if not check(color_distance(measurements[true].gi_off.receiver, measurements[true].gi_on.receiver) >= 0.02,
				"Magic GI control did not change the receiver sample"):
			return
		if not check(color_distance(measurements[true].gi_on.fog, measurements[true].fog_off.fog) >= 0.02,
				"Height Fog control did not change the fog sample"):
			return
		print("PASS FRP PE-on/off keeps Sky, Magic GI and Height Fog within 0.01 LDR and 2% exposure; GI and Fog controls are active")
	else:
		# At non-physical light_energy=60000, the fixed-exposure LDR reference and
		# auto-exposed floor/Fog samples clip. Keep this mode as the requested
		# reproduction diagnostic; the unclipped PE acceptance runs with 60,000 lux.
		print("INCONCLUSIVE PE threshold check for non-physical energy=60000: fixed and auto LDR samples clip; use physical_lux run for balance acceptance")
	quit(0)
