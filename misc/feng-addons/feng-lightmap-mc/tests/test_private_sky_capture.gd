extends SceneTree
## GPU regression: isolate a represented analytic solar disk without editing
## the visible scene, clearing panorama pixels, or removing sky scattering.
const Volume = preload("res://addons/feng-lightmap-mc/feng_lightmap_volume.gd")
const Atmosphere = preload("res://addons/feng-sky/feng_sky_atmosphere.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String, detail: Variant = null) -> void:
	checks += 1
	print("PRIVATE_SKY ", message, " ", condition, " ", detail)
	if not condition:
		failures += 1

func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45,0,0)
	sun.light_bake_mode = Light3D.BAKE_DYNAMIC
	scene.add_child(sun)
	var second := DirectionalLight3D.new()
	second.rotation_degrees = Vector3(-60,90,0)
	second.sky_mode = DirectionalLight3D.SKY_MODE_SKY_ONLY
	scene.add_child(second)
	var atmosphere := Atmosphere.new()
	atmosphere.sun_light = sun
	atmosphere.secondary_sun_light = second
	atmosphere.sun_source_angle_deg = 5.0
	atmosphere.secondary_sun_source_angle_deg = 5.0
	atmosphere.atmosphere_enabled = true
	scene.add_child(atmosphere)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.current = true
	var volume := Volume.new()
	volume.sky_capture_width = 128
	scene.add_child(volume)
	for frame in 60:
		await process_frame
	var environment: Environment = atmosphere.environment
	var sky := environment.sky
	var material := sky.sky_material as ShaderMaterial
	var selected := volume._represented_sun_disk_parameters(scene,environment)
	_check(selected == PackedStringArray(["sun_disk_color_scale"]), "only the represented analytic primary disk is selected",selected)
	var private := volume._private_capture_environment(environment,selected)
	_check(private != environment and private.sky != sky and private.sky.sky_material != material, "environment, sky and material are separate resources")
	_check((private.sky.sky_material as ShaderMaterial).get_shader_parameter("sun_disk_color_scale") == Vector3.ZERO, "private primary disk is removed")
	_check((private.sky.sky_material as ShaderMaterial).get_shader_parameter("secondary_sun_disk_color_scale") == material.get_shader_parameter("secondary_sun_disk_color_scale"), "unrepresented sky-only secondary disk is retained")
	_check((private.sky.sky_material as ShaderMaterial).get_shader_parameter("sun_irradiance") == material.get_shader_parameter("sun_irradiance"), "atmospheric scattering source energy is retained")
	var synchronous := volume._resolve_environment(scene)
	_check(not synchronous.ok and synchronous.get("requires_prepared_capture",false), "synchronous resolution refuses a disk-containing fallback")
	var before_signature: String = volume._sky_capture_signature(environment,selected)
	var before := RenderingServer.environment_bake_panorama(environment.get_rid(),false,Vector2i(128,64))
	var result: Dictionary = await volume.prepare_environment_capture()
	_check(result.get("ok",false), "asynchronous private GPU capture succeeds", result.get("error",""))
	_check(volume._sky_capture_signature(environment,selected) == before_signature and atmosphere.environment == environment and environment.sky == sky and sky.sky_material == material, "authored resources and parameters are unchanged")
	if result.get("ok",false) and before != null:
		var pixels: PackedColorArray = result.inputs.environment_pixels
		var total_before := 0.0
		var total_after := 0.0
		var scatter_error := 0.0
		var scatter_energy := 0.0
		for y in 64:
			for x in 128:
				var a := before.get_pixel(x,y)
				var b := pixels[y*128+x]
				var phi := TAU*(float(x)+0.5)/128.0
				var theta := PI*(float(y)+0.5)/64.0
				var direction := Vector3(-sin(phi)*sin(theta),cos(theta),-cos(phi)*sin(theta))
				total_before += a.r+a.g+a.b
				total_after += b.r+b.g+b.b
				if direction.dot(sun.global_basis.z) < cos(deg_to_rad(15)) and direction.dot(second.global_basis.z) < cos(deg_to_rad(15)):
					scatter_error += absf(a.r-b.r)+absf(a.g-b.g)+absf(a.b-b.b)
					scatter_energy += a.r+a.g+a.b
		_check(total_after > 0.0 and total_before > total_after, "disk removal decreases energy without blacking out the sky", [total_before,total_after])
		_check(scatter_error/maxf(scatter_energy,0.000001) < 0.03, "off-disk atmospheric scattering is preserved", scatter_error/maxf(scatter_energy,0.000001))
		_check(volume._resolve_environment(scene).ok, "prepared capture is reusable by synchronous bake preparation")
	print("PRIVATE_SKY_RESULT checks=",checks," failures=",failures)
	quit(1 if failures else 0)
