# Run with a graphical rendering driver; see README.md in this directory.
#
# The root pyramid is intentionally configured beyond the normal editor setting. The
# regression is that root_mips=16 must remain bounded by the physical cache and by a
# finite CPU scan, even when the detail distance is effectively the whole world.
extends "res://vt_scene_base.gd"


func _initialize() -> void:
	call_deferred("run")

func check_bounded(terrain: Terrain3D, label: String, max_usec: int) -> void:
	var start := Time.get_ticks_usec()
	var produced: int = terrain.update_surface_svt()
	var elapsed: int = Time.get_ticks_usec() - start
	var stats: Dictionary = terrain.get_surface_svt().get_stats()
	var page_count := int(stats.get("page_count", 0))
	var protected_count := int(stats.get("protected_count", 0))
	require(elapsed < max_usec,
			"%s update must stay within the CPU budget (%d us, limit %d)" % [label, elapsed, max_usec])
	require(page_count > 0 and protected_count <= page_count / 2,
			"%s root protection must leave half the physical cache available (%d/%d)" % [label, protected_count, page_count])
	print("VTROOT label=%s elapsed_us=%d produced=%d protected=%d pages=%d" % [
			label, elapsed, produced, protected_count, page_count])

func make_terrain() -> Terrain3D:
	var terrain := Terrain3D.new()
	terrain.free_editor_textures = false
	root.add_child(terrain)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 200.0, 0.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.current = true
	terrain.add_child(camera)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	await process_frame
	return terrain

func run() -> void:
	# Direct-material mode preserves the legacy full-grid root walk. With the largest
	# root setting it used to inspect every texel in a 1024^2 indirection before detail
	# work, despite the atlas only holding 256 pages.
	var full_grid := await make_terrain()
	full_grid.set_vt_debug_direct_material(true)
	full_grid.surface_svt_page_size = 16
	full_grid.surface_svt_page_border = 1
	full_grid.surface_svt_page_count = 256
	full_grid.surface_svt_page_world = 16.0
	full_grid.surface_svt_distance = 1000000000.0
	full_grid.surface_svt_root_mips = 16
	full_grid.surface_svt_enabled = true
	check_bounded(full_grid, "legacy-full-grid", 1000000)
	full_grid.queue_free()
	await process_frame

	# Automatic mode considers loaded terrain as the root candidate set. Keep the shared
	# baker pool small so this phase also proves the cap is applied to the shared cache.
	var automatic := await make_terrain()
	automatic.vt_page_size = 16
	automatic.vt_page_border = 1
	automatic.vt_page_count = 16
	automatic.surface_svt_page_world = 64.0
	automatic.surface_svt_distance = 1000000000.0
	automatic.surface_svt_root_mips = 16
	automatic.surface_svt_enabled = true
	automatic.region_size = 64
	automatic.data.add_region_blank(Vector2i(0, 0))
	automatic.data.update_maps()
	await physics_frame
	check_bounded(automatic, "loaded-terrain", 500000)
	var auto_stats: Dictionary = automatic.get_surface_svt().get_stats()
	require(int(auto_stats.get("protected_count", 0)) <= int(auto_stats.get("page_count", 0)) / 2,
			"automatic roots must not consume the shared AVT/SVT cache")
	automatic.queue_free()
	await process_frame

	if failed:
		quit(1)
		return
	print("PASS bounded SVT root and detail scheduling")
	quit()
