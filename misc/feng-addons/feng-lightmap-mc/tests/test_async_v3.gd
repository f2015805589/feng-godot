extends SceneTree
const Volume = preload("res://addons/feng-lightmap-mc/feng_lightmap_volume.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var mesh := MeshInstance3D.new()
	mesh.mesh = PlaneMesh.new()
	mesh.mesh.add_uv2 = true
	mesh.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	mesh.material_override = StandardMaterial3D.new()
	scene.add_child(mesh)
	var volume := Volume.new()
	scene.add_child(volume)
	volume.environment_mode = Volume.EnvironmentMode.UNIFORM_OVERRIDE
	volume.environment_radiance = Color(1,1,1)
	volume.atlas_resolution = 128
	volume.samples_per_texel = 1048576
	volume.output_resource_path = "user://feng_lightmap_mc_test/cancel_%d_%d.tres" % [Time.get_unix_time_from_system(),Time.get_ticks_usec()]
	volume.request_inspector_bake()
	var deadline := Time.get_ticks_msec() + 20000
	var frames := 0
	while volume._bake_thread == null and Time.get_ticks_msec() < deadline:
		await process_frame
		frames += 1
	if volume._bake_thread == null:
		push_error("Inspector native worker did not start")
		quit(1)
		return
	for frame in 3:
		await process_frame
		frames += 1
	volume.cancel_bake()
	while volume._inspector_bake_pending and Time.get_ticks_msec() < deadline:
		await process_frame
		frames += 1
	var passed: bool = volume.last_bake_report.get("cancelled",false) and not FileAccess.file_exists(volume.output_resource_path) and frames >= 3
	print("FengLightmap async cancel: responsive_frames=%d cancelled=%s no_partial_output=%s" % [frames,volume.last_bake_report.get("cancelled",false),not FileAccess.file_exists(volume.output_resource_path)])
	current_scene = null
	scene.free()
	quit(0 if passed else 1)
