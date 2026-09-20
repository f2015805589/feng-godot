extends SceneTree
## A snap must discard the old angular lead and bypass the normal plan debounce.
## Small turns still use the interval so the fix does not turn ordinary motion into
## a full re-plan every frame.

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var failed := false

func _initialize() -> void:
	_run.call_deferred()

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

func _tick() -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	terrain.notification(Node.NOTIFICATION_PHYSICS_PROCESS)

func sector_stats() -> Dictionary:
	return terrain.get_vt_settings().get("avt_sector_stats", {})

func stat_int(stats: Dictionary, key: String) -> int:
	return int(stats.get(key, 0))

func wait_for_retained_discard(previous_chain: int, label: String) -> Dictionary:
	var last := sector_stats()
	for _i in 240:
		last = sector_stats()
		var installed := stat_int(last, "chain_ticks") > previous_chain \
				and not bool(last.get("discard_retained_pending", true)) \
				and stat_int(last, "retained_requests") == 0
		if installed:
			return last
		await _tick()
	require(false, "%s plan did not consume the retained discard" % label)
	return last

func motion_turn_lead() -> float:
	return float(terrain.get_vt_settings().get("motion_turn_lead_deg", 0.0))

func build_scene() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	terrain.vt_editor_preview = false
	terrain.free_editor_textures = false
	DirAccess.make_dir_recursive_absolute("user://snap-turn")
	terrain.data_directory = "user://snap-turn"
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.region_size = 256
	terrain.data.add_region_blank(Vector2i.ZERO)
	terrain.data.update_maps()
	camera = Camera3D.new()
	camera.position = Vector3(128, 24, 128)
	# Level gaze makes a 180-degree yaw an exact forward-vector reversal.
	# A pitched camera would only turn through 180 - 2*abs(pitch) degrees.
	camera.rotation_degrees = Vector3.ZERO
	camera.current = true
	scene.add_child(camera)
	terrain.set_camera(camera)
	terrain.surface_vt_enabled = true
	terrain.surface_svt_enabled = false
	terrain.surface_vt_distance = 64.0
	terrain.set_physics_process(false)

func turn_to_build_lead() -> void:
	for _i in 12:
		camera.rotation.y += 0.02
		await _tick()

func _run() -> void:
	build_scene()
	for _i in 12:
		await _tick()
	await turn_to_build_lead()
	var lead_before := motion_turn_lead()
	require(lead_before > 0.01, "the setup did not establish an angular lead")

	var before_snap := sector_stats()
	var chain_before := stat_int(before_snap, "chain_ticks")
	camera.rotation.y += PI
	await _tick()
	var lead_after_180 := motion_turn_lead()
	var after_180 := sector_stats()
	require(lead_after_180 < 0.00001, "180-degree snap kept the previous angular lead")
	require(stat_int(after_180, "chain_ticks") > chain_before,
			"180-degree snap did not bypass the plan refresh interval")
	require(bool(after_180.get("discard_retained_pending", false)),
			"180-degree snap did not mark old retained requests for discard")
	await wait_for_retained_discard(chain_before, "180-degree snap")

	await turn_to_build_lead()
	var before_reverse := sector_stats()
	var reverse_chain_before := stat_int(before_reverse, "chain_ticks")
	camera.rotation.y -= deg_to_rad(60.0)
	await _tick()
	var lead_after_reverse := motion_turn_lead()
	var after_reverse := sector_stats()
	require(lead_after_reverse < 0.00001, "reverse snap kept the old angular lead")
	require(stat_int(after_reverse, "chain_ticks") > reverse_chain_before,
			"reverse snap did not submit a fresh plan immediately")
	require(bool(after_reverse.get("discard_retained_pending", false)),
			"reverse snap did not mark old retained requests for discard")
	await wait_for_retained_discard(reverse_chain_before, "reverse snap")

	# A large position step must take the same bounded path. The standing plan stays drawable while
	# the replacement is produced, but its old retained source tail must not reserve the new view.
	var before_displacement := sector_stats()
	var displacement_chain_before := stat_int(before_displacement, "chain_ticks")
	camera.position.x += 16.0
	await _tick()
	var after_displacement := sector_stats()
	require(stat_int(after_displacement, "chain_ticks") > displacement_chain_before,
			"large position displacement did not force a fresh plan")
	require(bool(after_displacement.get("plan_spatial_refresh", false)),
			"large position displacement did not trip the standing-plan spatial guard")
	require(bool(after_displacement.get("discard_retained_pending", false)),
			"large position displacement did not mark old retained requests for discard")
	await wait_for_retained_discard(displacement_chain_before, "large position displacement")

	var slow_chain_before := stat_int(sector_stats(), "chain_ticks")
	for _i in 3:
		camera.rotation.y += deg_to_rad(1.0)
		await _tick()
	var slow_chain_after := stat_int(sector_stats(), "chain_ticks")
	require(slow_chain_after - slow_chain_before < 3,
			"slow turn bypassed debounce and re-planned every frame")

	var exit_code := 1 if failed else 0
	if not failed:
		print("PASS snap/displacement turns discard old retention and preserve slow-turn debounce")
	scene.queue_free()
	await process_frame
	await process_frame
	quit(exit_code)
