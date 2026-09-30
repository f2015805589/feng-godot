extends SceneTree

const FogRuntime = preload("res://addons/feng-fog/feng_fog_runtime.gd")


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var before_install := FogRuntime._sky_snapshot_for_world(42)
	if not before_install.is_empty():
		_fail("an absent Feng Sky runtime unexpectedly returned a snapshot")
		return

	# The host runner waits for this signal, rechecks that the project is a
	# regular scratch tree, and creates the mock runtime there. This script never
	# writes under addons/feng-sky, where an editor junction could escape scratch.
	var request_file := FileAccess.open("res://.late_sky_runtime_mock_requested", FileAccess.WRITE)
	if request_file == null:
		_fail("could not signal the isolated test runner")
		return
	request_file.store_string("create mock runtime in validated scratch project")
	request_file.close()
	var runtime_path := "res://addons/feng-sky/feng_sky_runtime.gd"
	var runtime_appeared := false
	for attempt in range(600):
		if FileAccess.file_exists(runtime_path):
			runtime_appeared = true
			break
		await create_timer(0.05).timeout
	if not runtime_appeared:
		_fail("the isolated test runner did not create the mock runtime")
		return

	await create_timer(0.55).timeout
	var after_install := FogRuntime._sky_snapshot_for_world(42)
	if after_install.get("world_id") != 42:
		_fail("the fog runtime did not discover Feng Sky after the retry interval")
		return

	var fog_snapshot := {"fog_color": Vector3.ONE}
	FogRuntime._add_sky_ambient(fog_snapshot, 42)
	if fog_snapshot["fog_color"] != Vector3(2.0, 2.5, 3.0):
		_fail("the fog consumer rejected the provider's gated snapshot or applied its scale incorrectly")
		return
	var nonfinite_scale_snapshot := {"fog_color": Vector3.ONE}
	FogRuntime._add_sky_ambient(nonfinite_scale_snapshot, 43)
	if nonfinite_scale_snapshot["fog_color"] != Vector3(3.0, 4.0, 5.0):
		_fail("a non-finite sky contribution scale contaminated the linear fog source")
		return

	print("feng_fog late sky runtime load test passed")
	quit()


func _fail(message: String) -> void:
	push_error("REGRESSION: " + message)
	quit(1)
