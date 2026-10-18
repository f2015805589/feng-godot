extends SceneTree

const SkyLightScript = preload("res://addons/feng-sky/feng_sky_light.gd")

var failures := 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("REGRESSION: " + message)


func run() -> void:
	var light: Variant = SkyLightScript.new()
	light._output_sky = Sky.new()
	light._output_source_mode = SkyLightScript.SourceMode.CAPTURED_SCENE
	light._capture_environment_id = 101
	light._bound_capture_sky = Sky.new()
	light._output_source_identity = light._capture_source_identity()
	var epoch: int = int(light._current_source_registration_revision())
	check(epoch == 1, "the first active output source must receive a registration epoch")

	light._native_radiance_revision = 10
	light._native_radiance_exposure = 0.5
	check(light._current_source_registration_revision() == epoch,
			"content revision and capture exposure must not change source identity")
	light._native_radiance_revision = 11
	light._native_radiance_exposure = 1.0
	check(light._current_source_registration_revision() == epoch,
			"another realtime capture must preserve the source registration epoch")

	light._capture_in_flight = true
	light._capture_environment_id = 102
	light._bound_capture_sky = Sky.new()
	light._capture_submitted_source_identity = light._capture_source_identity()
	light._complete_inflight_capture(1000)
	var captured_epoch: int = int(light._current_source_registration_revision())
	check(captured_epoch == epoch + 1,
			"a committed capture from a replacement environment/Sky must advance the epoch")
	light._native_radiance_revision = 12
	check(light._current_source_registration_revision() == captured_epoch,
			"content-only updates on the replacement source must preserve its epoch")

	light._output_sky = Sky.new()
	var output_epoch: int = int(light._current_source_registration_revision())
	check(output_epoch == captured_epoch + 1,
			"replacing the FRP output Sky must advance the epoch")
	light._output_source_mode = SkyLightScript.SourceMode.SPECIFIED_SKY
	light._output_source_identity = ["specified_sky", int(light._output_source_mode),
			light._resource_instance_id(Sky.new())]
	check(light._current_source_registration_revision() == output_epoch + 1,
			"changing the active source mode/resource must advance the epoch")
	var cubemap_a: Cubemap = Cubemap.new()
	light.cubemap = cubemap_a
	light._output_source_identity = light._cubemap_source_identity()
	var cubemap_epoch: int = int(light._current_source_registration_revision())
	var cubemap_b: Cubemap = Cubemap.new()
	light.cubemap = cubemap_b
	light._output_source_identity = light._cubemap_source_identity()
	check(light._current_source_registration_revision() == cubemap_epoch + 1,
			"replacing the selected cubemap resource must advance the epoch")

	var bake_a: FengSkyLightBakeData = FengSkyLightBakeData.new()
	bake_a.radiance = Cubemap.new()
	light.bake_data = bake_a
	light._output_source_identity = light._baked_source_identity()
	var bake_epoch: int = int(light._current_source_registration_revision())
	bake_a.radiance = Cubemap.new()
	light._output_source_identity = light._baked_source_identity()
	check(light._current_source_registration_revision() == bake_epoch + 1,
			"replacing the radiance resource within an active baked source must advance the epoch")

	light._output_sky = null
	light._bound_capture_sky = null
	light.cubemap = null
	light.bake_data = null
	light.free()
	cubemap_a = null
	cubemap_b = null
	bake_a = null
	await process_frame
	if failures == 0:
		print("SKY LIGHT SOURCE EPOCH PASS")
	quit(1 if failures > 0 else 0)
