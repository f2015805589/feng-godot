extends SceneTree
## CPU-only timing helper. Pass the copied TempCornell scene with --scene=;
## it instantiates the read-only packed scene but never enters the tree.

const SHFilter = preload("res://addons/feng-magic-gi/feng_magic_gi_sh_filter.gd")
const LARGE_PROBE_COUNT := 8192

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var scene_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--scene="):
			scene_path = argument.substr("--scene=".length())
	if scene_path.is_empty():
		push_error("Pass -- --scene=res://path/to/TempCornell.tscn")
		quit(1)
		return
	var packed_scene := load(scene_path) as PackedScene
	if packed_scene == null:
		push_error("Could not load the read-only benchmark scene: " + scene_path)
		quit(1)
		return
	var scene := packed_scene.instantiate()
	var volume := scene.get_node_or_null("FMagicGIVolume")
	if volume == null:
		push_error("Cornell scene does not contain FMagicGIVolume.")
		scene.free()
		quit(1)
		return
	var data: Resource = volume.get("bake_data")
	if data == null or data.get("positions").size() != 634:
		push_error("Expected the embedded 634-probe Cornell bake.")
		scene.free()
		quit(1)
		return
	var source: PackedFloat32Array = data.get("transfer")
	var actual_checksum := _time_filter(source, 634)
	var large := PackedFloat32Array()
	large.resize(LARGE_PROBE_COUNT * 27)
	for probe in LARGE_PROBE_COUNT:
		var source_base := (probe % 634) * 27
		var target_base := probe * 27
		for coefficient in 27:
			large[target_base + coefficient] = source[source_base + coefficient]
	var large_checksum := _time_filter(large, LARGE_PROBE_COUNT)
	print("MAGIC_GI_SH_FILTER_CPU actual_probes=634 elapsed_ms=", actual_checksum.y,
		" scale_checksum=", actual_checksum.x,
		" representative_probes=", LARGE_PROBE_COUNT,
		" elapsed_ms=", large_checksum.y,
		" scale_checksum=", large_checksum.x)
	scene.free()
	quit(0)

func _time_filter(transfer: PackedFloat32Array, probe_count: int) -> Vector2:
	var checksum := 0.0
	var start := Time.get_ticks_usec()
	for probe in probe_count:
		var scale: Vector3 = SHFilter.high_band_scale(transfer, probe * 27)
		checksum += scale.x + scale.y + scale.z
	var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
	return Vector2(checksum, elapsed_ms)
