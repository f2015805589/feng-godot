extends SceneTree
var _tracy: Object

func _initialize() -> void:
	call_deferred("_run")

func _exercise(prefix: String) -> bool:
	for index in 1000:
		_tracy.call("begin_zone", prefix)
		_tracy.call("begin_zone", "nested UTF-8 zone 中文")
		if int(_tracy.call("get_zone_depth")) != 2:
			return false
		_tracy.call("end_zone")
		_tracy.call("end_all_zones")
		_tracy.call("message", "dynamic message 中文 %d" % index)
		_tracy.call("message_colored", "colored message 中文 %d" % index, Color.ORANGE)
		_tracy.call("plot", "stable script plot 中文", float(index))
		_tracy.call("frame_mark", "stable script frame 中文")
	return int(_tracy.call("get_zone_depth")) == 0

func _run() -> void:
	if not Engine.has_singleton("FengGodotTracy"):
		push_error("FengGodotTracy module is required")
		quit(1)
		return
	_tracy = Engine.get_singleton("FengGodotTracy")
	if not bool(_tracy.call("is_available")) or not _exercise("disconnected repeated zone"):
		push_error("disconnected Tracy lifetime exercise failed")
		quit(1)
		return
	print("TRACY_READY_TO_CONNECT")
	var deadline := Time.get_ticks_msec() + 20000
	while not bool(_tracy.call("is_profiler_connected")) and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	if not bool(_tracy.call("is_profiler_connected")):
		push_error("Tracy test driver did not connect")
		quit(1)
		return
	if not _exercise("connected repeated zone"):
		push_error("connected Tracy lifetime exercise failed")
		quit(1)
		return
	# Let the real profiler worker consume the transferred source locations and
	# message payloads before application teardown.
	await create_timer(0.25).timeout
	print("PASS Tracy actual client lifetime: disconnected and connected repeated zones/messages/categories")
	quit()
