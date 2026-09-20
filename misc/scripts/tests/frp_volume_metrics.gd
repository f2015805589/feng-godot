extends SceneTree
const Metrics = preload("res://addons/feng-render-pipeline/volume/volume_metrics.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var first := FengVolume.new()
	var second := FengVolume.new()
	root.add_child(first)
	root.add_child(second)
	first.set_process(false)
	second.set_process(false)
	assert(Performance.has_custom_monitor("volume/total_cpu_ms"))
	await process_frame
	Metrics.record(0, 1000)
	Metrics.record(1, 2000)
	Metrics.record(2, 3000)
	await process_frame
	assert(is_equal_approx(Performance.get_custom_monitor("volume/total_cpu_ms"), 6.0))
	assert(is_equal_approx(Performance.get_custom_monitor("volume/runtime_cpu_ms"), 1.0))
	assert(is_equal_approx(Performance.get_custom_monitor("volume/editor_cpu_ms"), 2.0))
	assert(is_equal_approx(Performance.get_custom_monitor("volume/apply_cpu_ms"), 3.0))
	await process_frame
	assert(Performance.get_custom_monitor("volume/total_cpu_ms") == 0.0)
	first.free()
	assert(Performance.has_custom_monitor("volume/total_cpu_ms"))
	second.free()
	assert(not Performance.has_custom_monitor("volume/total_cpu_ms"))
	print("PASS volume CPU monitors: frame totals, units, idle reset and registration lifetime")
	quit()
