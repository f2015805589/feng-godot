# Region chunk streaming regression. Run with a graphical driver; see README.md.
# Verifies Terrain3DStreamer ring residency, per-update budgets, missing-file
# caching, modified-region protection, save-on-unload and file preservation.
extends SceneTree

const REGION_SIZE := 64
const GRID_MIN := -2
const GRID_MAX := 2
const BASE_HEIGHT := 100.0

var terrain: Terrain3D
var streamer: Terrain3DStreamer
var camera: Camera3D
var scene: Node3D
var data_dir := "user://stream_regions"
var finished := false
var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if value:
		return
	failed = true
	push_error("REGRESSION: " + message)

func watchdog() -> void:
	await create_timer(120.0).timeout
	if not finished:
		push_error("REGRESSION: region streaming test timed out")
		quit(1)

# Global position of a region's center, for region_size 64 and spacing 1.
func center_of(loc: Vector2i) -> Vector3:
	return Vector3(loc.x * REGION_SIZE + REGION_SIZE * 0.5, 0.0, loc.y * REGION_SIZE + REGION_SIZE * 0.5)

func region_path(loc: Vector2i) -> String:
	return data_dir + "/" + Terrain3DUtil.location_to_filename(loc)

func expected_height(loc: Vector2i) -> float:
	return BASE_HEIGHT + float(loc.x) * 10.0 + float(loc.y)

func resident(loc: Vector2i) -> bool:
	return terrain.data.get_region(loc) != null

func sample_position(loc: Vector2i) -> Vector3:
	return Vector3(loc.x * REGION_SIZE + 10, 0.0, loc.y * REGION_SIZE + 20)

func sorted_locations() -> Array:
	var out := []
	for loc in terrain.data.get_region_locations():
		out.append(loc)
	out.sort_custom(func(a, b): return a.y < b.y if a.y != b.y else a.x < b.x)
	return out

func same_ring(actual: Array, expected: Array) -> bool:
	if actual.size() != expected.size():
		return false
	for i in actual.size():
		if actual[i] != expected[i]:
			return false
	return true

func ring(center: Vector2i, radius: int) -> Array:
	var out := []
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			out.append(center + Vector2i(dx, dz))
	out.sort_custom(func(a, b): return a.y < b.y if a.y != b.y else a.x < b.x)
	return out

func sorted_locations_of(locs: Array) -> Array:
	var out := locs.duplicate()
	out.sort_custom(func(a, b): return a.y < b.y if a.y != b.y else a.x < b.x)
	return out

func build_fixture() -> void:
	# The directory must be empty so set_data_directory keeps the live data.
	var da := DirAccess.open("user://")
	if da != null and da.dir_exists("stream_regions"):
		da.remove_absolute(data_dir)
	DirAccess.make_dir_recursive_absolute(data_dir)

	terrain.region_size = Terrain3D.SIZE_64
	terrain.vertex_spacing = 1.0
	terrain.data_directory = data_dir
	require(terrain.data.get_region_count() == 0, "fixture terrain should start empty")

	for z in range(GRID_MIN, GRID_MAX + 1):
		for x in range(GRID_MIN, GRID_MAX + 1):
			var loc := Vector2i(x, z)
			require(terrain.data.add_region_blank(loc) != null, "add_region_blank " + str(loc))
			# One distinctive sample per region, on its own vertex grid.
			terrain.data.set_height(sample_position(loc), expected_height(loc))
	terrain.data.update_maps(Terrain3DRegion.TYPE_MAX)
	require(terrain.data.get_region_count() == 25, "fixture should hold 25 regions")

	terrain.data.save_directory(data_dir)
	for z in range(GRID_MIN, GRID_MAX + 1):
		for x in range(GRID_MIN, GRID_MAX + 1):
			require(FileAccess.file_exists(region_path(Vector2i(x, z))), "saved file " + str(Vector2i(x, z)))

	# Drop everything from memory so the streamer has to read the files back.
	for loc in terrain.data.get_regions_all().keys():
		terrain.data.unload_region(loc, false)
	terrain.data.update_maps(Terrain3DRegion.TYPE_MAX)
	require(terrain.data.get_region_count() == 0, "fixture should be empty after unload")

func test_ring_and_budget() -> void:
	var center := center_of(Vector2i.ZERO)
	var desired := streamer.get_desired_locations(center)
	require(desired.size() == 9, "radius 1 should want 9 regions, got " + str(desired.size()))

	# One update may only load loads_per_update regions.
	require(streamer.update(center), "first update should change the resident set")
	require(streamer.get_last_loads() == 1, "budget should cap loads at 1, got " + str(streamer.get_last_loads()))
	require(terrain.data.get_region_count() == 1, "one region should be resident")

	var steps := streamer.flush(center)
	require(steps >= 8, "flush should need at least 8 more steps, got " + str(steps))
	require(terrain.data.get_region_count() == 9, "ring should be 9 regions, got " + str(terrain.data.get_region_count()))
	require(streamer.get_streamed_count() == 9, "streamer should track 9 regions")
	require(streamer.get_loaded_total() == 9, "loaded_total should be 9, got " + str(streamer.get_loaded_total()))
	require(streamer.get_missing_count() == 0, "no region should be missing")
	require(streamer.get_failed_total() == 0, "no load should fail")
	require(same_ring(sorted_locations(), ring(Vector2i.ZERO, 1)), "resident set should be the 3x3 ring")

	# A stable center must not reload anything.
	require(not streamer.update(center), "a settled ring should not change")
	require(streamer.get_last_loads() == 0 and streamer.get_last_unloads() == 0, "settled ring should be idle")

	# Content survived the file round trip.
	require(is_equal_approx(terrain.data.get_height(sample_position(Vector2i.ZERO)), expected_height(Vector2i.ZERO)),
			"region (0,0) height after streaming")
	require(is_equal_approx(terrain.data.get_height(sample_position(Vector2i(-1, -1))), expected_height(Vector2i(-1, -1))),
			"region (-1,-1) height after streaming")

func test_move() -> void:
	# Move one region diagonally: the 3x3 ring shares exactly four regions with
	# the previous ring, so five load and five unload.
	var center := center_of(Vector2i(1, 1))
	# The slot allocator reuses the layer slots of the regions this step unloads, so
	# the step must not reallocate any texture array: map_create_count counts GPU
	# array allocations and map_update_count counts single layer uploads.
	terrain.data.reset_map_stats()
	require(streamer.update(center), "moving should change the resident set")
	require(streamer.get_last_loads() <= 1 and streamer.get_last_unloads() <= 1,
			"per-update budgets must hold while moving")
	streamer.flush(center)
	require(same_ring(sorted_locations(), ring(Vector2i(1, 1), 1)), "resident set should follow the center")
	require(streamer.get_unloaded_total() == 5, "five trailing regions should unload, got " + str(streamer.get_unloaded_total()))
	require(streamer.get_loaded_total() == 14, "fourteen regions should have loaded, got " + str(streamer.get_loaded_total()))
	require(streamer.get_missing_count() == 0, "the fixture covers this ring")
	var stats := terrain.data.get_map_stats()
	require(int(stats["map_create_count"]) == 0,
			"a ring step reallocated the texture arrays " + str(stats["map_create_count"]) + " times")
	# Five loaded regions, four slot maps each: one layer upload per map per region.
	require(int(stats["map_update_count"]) == 5 * 4,
			"a five region ring step should upload 20 layers, got " + str(stats["map_update_count"]))
	print("SLOTS ring step stats=", stats)
	# Unloading never deletes files.
	for loc in ring(Vector2i.ZERO, 1):
		require(FileAccess.file_exists(region_path(loc)), "unload must keep " + str(loc) + " on disk")

func test_missing_files() -> void:
	var center := center_of(Vector2i(1, 1))
	streamer.set_load_radius(3)
	var desired := streamer.get_desired_locations(center)
	require(desired.size() == 49, "radius 3 should want 49 regions, got " + str(desired.size()))
	var with_file := 0
	for loc in desired:
		if FileAccess.file_exists(region_path(loc)):
			with_file += 1
	require(with_file == 25, "the fixture should cover 25 of the 49, got " + str(with_file))
	require(with_file < desired.size(), "the fixture must not cover the whole ring")

	streamer.flush(center)
	require(terrain.data.get_region_count() == 25, "all 25 saved regions should be resident, got " + str(terrain.data.get_region_count()))
	require(streamer.get_missing_count() == desired.size() - with_file,
			"missing cache should hold " + str(desired.size() - with_file) + " locations, got " + str(streamer.get_missing_count()))
	var skipped := streamer.get_skipped_missing_total()
	require(skipped > 0, "absent files should be counted as skipped")
	require(streamer.get_failed_total() == 0, "an absent file is not a load failure")

	# Absent regions are probed once, not every update.
	streamer.update(center)
	require(streamer.get_skipped_missing_total() == skipped, "absent regions must not be re-probed")
	require(streamer.get_last_loads() == 0, "nothing left to load")

	# reset_missing() allows a deliberate re-probe.
	streamer.reset_missing()
	streamer.update(center)
	require(streamer.get_missing_count() == desired.size() - with_file, "reset_missing should re-probe")

func test_modified_protection() -> void:
	var center := center_of(Vector2i.ZERO)
	streamer.set_load_radius(1)
	streamer.set_unload_radius(1)
	streamer.set_protect_modified(true)
	streamer.set_save_on_unload(false)
	streamer.flush(center)
	require(same_ring(sorted_locations(), ring(Vector2i.ZERO, 1)), "protection setup should settle on the ring")

	# (-1,-1) is a ring corner and leaves the ring when the center moves away.
	terrain.data.set_region_modified(Vector2i(-1, -1), true)
	var protected_before := streamer.get_protected_total()
	streamer.flush(center_of(Vector2i(1, 1)))
	require(resident(Vector2i(-1, -1)), "a modified region must stay resident")
	require(streamer.get_protected_total() > protected_before, "protection should be counted")
	require(same_ring(sorted_locations(), sorted_locations_of(ring(Vector2i(1, 1), 1) + [Vector2i(-1, -1)])),
			"resident set should be the new ring plus the protected region")
	require(not streamer.update(center_of(Vector2i(1, 1))), "a blocked unload must not report a change")

func test_save_on_unload() -> void:
	streamer.set_protect_modified(false)
	streamer.set_save_on_unload(true)
	require(resident(Vector2i(-1, -1)), "(-1,-1) should still be resident and modified")
	var path := region_path(Vector2i(-1, -1))
	var saved_before := streamer.get_saved_total()
	streamer.flush(center_of(Vector2i(1, 1)))
	require(not resident(Vector2i(-1, -1)), "an unprotected region should unload")
	require(streamer.get_saved_total() > saved_before, "save_on_unload should write the region first")
	require(FileAccess.file_exists(path), "save_on_unload must leave the file in place")

	# It must load back with the same content.
	streamer.set_load_radius(3)
	streamer.flush(center_of(Vector2i.ZERO))
	require(resident(Vector2i(-1, -1)), "region should stream back in")
	require(is_equal_approx(terrain.data.get_height(sample_position(Vector2i(-1, -1))), expected_height(Vector2i(-1, -1))),
			"region (-1,-1) height after reload")

func test_bounds_and_manual_api() -> void:
	require(Terrain3DStreamer.chebyshev_distance(Vector2i(-1, 2), Vector2i(1, 0)) == 2, "chebyshev_distance")
	# The chunk directory is a texture now, so the world grid is REGION_MAP_SIZE (128,
	# i.e. +-64) instead of the 32x32 (+-16) the uniform int array forced. (20,0) used
	# to be out of bounds.
	require(Terrain3DData.get_region_map_index(Vector2i(20, 0)) >= 0,
			"the world grid should accept region (20,0)")
	require(Terrain3DData.get_region_map_index(Vector2i(0, -20)) >= 0,
			"the world grid should accept region (0,-20)")
	require(Terrain3DData.get_region_map_index(Vector2i(-64, 63)) >= 0, "the grid should reach its own corners")
	require(Terrain3DData.get_region_map_index(Vector2i(64, 0)) < 0, "one chunk past the grid edge must be rejected")
	require(Terrain3DData.get_region_map_index(Vector2i(0, -65)) < 0, "one chunk past the grid edge must be rejected")
	require(terrain.data.get_region_map().size() == 128 * 128,
			"the region map should be REGION_MAP_SIZE squared, got " + str(terrain.data.get_region_map().size()))
	# Region locations outside the grid are rejected.
	require(streamer.load_region(Vector2i(70, 0)) == Terrain3DStreamer.LOAD_FAILED,
			"out of bounds region must not load")
	require(streamer.load_region(Vector2i(0, -70)) == Terrain3DStreamer.LOAD_FAILED,
			"out of bounds region must not load")
	require(resident(Vector2i(0, 0)), "(0,0) should be resident from the last flush")
	require(streamer.load_region(Vector2i(0, 0)) == Terrain3DStreamer.LOAD_OK, "in bounds load should succeed")
	require(streamer.unload_region(Vector2i(0, 0)), "manual unload should succeed")
	require(not resident(Vector2i(0, 0)), "manual unload should remove the region")
	require(not streamer.unload_region(Vector2i(0, 0)), "a second unload should be a no-op")
	require(streamer.load_region(Vector2i(0, 0)) == Terrain3DStreamer.LOAD_OK, "manual load should work again")

func test_directory_switch_keeps_working() -> void:
	# Terrain3D::set_data_directory recreates Terrain3DData; the streamer must
	# re-resolve it instead of dereferencing a freed pointer.
	var original := terrain.data_directory
	terrain.data_directory = ""
	require(terrain.data.get_region_count() == 0, "clearing the directory should drop the data")
	terrain.data_directory = original
	require(terrain.data_directory == original, "directory should be restored")
	require(terrain.data.get_region_count() == 25, "restoring the directory should load all 25 regions")
	require(streamer.get_directory() == original, "streamer should follow the terrain directory")

	streamer.clear_tracking()
	require(streamer.get_streamed_count() == 0, "clear_tracking should empty the streamed set")
	require(streamer.load_region(Vector2i(1, 1)) == Terrain3DStreamer.LOAD_OK, "load after a data rebuild")
	require(streamer.get_streamed_count() == 1, "the reloaded region should be tracked")
	require(streamer.unload_region(Vector2i(1, 1)), "unload after a data rebuild")
	require(not resident(Vector2i(1, 1)), "the region should be gone")

func test_save_without_directory() -> void:
	var unsaved := Terrain3D.new()
	unsaved.region_size = REGION_SIZE
	scene.add_child(unsaved)
	unsaved.set_camera(camera)
	unsaved.set_clipmap_target(camera)
	unsaved.set_physics_process(false)
	unsaved.data.add_region_blank(Vector2i.ZERO)
	var loader := unsaved.get_streamer()
	loader.load_region(Vector2i.ZERO)
	loader.set_protect_modified(false)
	loader.set_save_on_unload(true)
	unsaved.data.get_region(Vector2i.ZERO).set_modified(true)
	require(not loader.unload_region(Vector2i.ZERO), "save-on-unload without a directory must keep edits resident")
	require(unsaved.data.get_region(Vector2i.ZERO) != null, "failed save preserves region data")
	require(loader.get_streamed_count() == 1, "failed save preserves streaming ownership for retry")
	require(loader.get_failed_total() == 1, "failed save is reported in telemetry")
	unsaved.queue_free()

func test_desired_order() -> void:
	var previous_radius := streamer.get_load_radius()
	var previous_unload := streamer.get_unload_radius()
	for radius in [0, 1, 3, 16]:
		streamer.set_load_radius(radius)
		for center in [Vector2i.ZERO, Vector2i(-64, 63), Vector2i(63, -64)]:
			var expected := []
			for y in range(-radius, radius + 1):
				for x in range(-radius, radius + 1):
					var location: Vector2i = center + Vector2i(x, y)
					if Terrain3DData.get_region_map_index(location) >= 0:
						expected.append(location)
			expected.sort_custom(func(a, b):
				var da: int = maxi(absi(a.x - center.x), absi(a.y - center.y))
				var db: int = maxi(absi(b.x - center.x), absi(b.y - center.y))
				if da != db: return da < db
				return a.y < b.y if a.y != b.y else a.x < b.x)
			require(streamer.get_desired_locations(center_of(center)) == expected,
				"desired region order matches distance/y/x priority at radius %d" % radius)
	streamer.set_load_radius(previous_radius)
	streamer.set_unload_radius(previous_unload)

func run() -> void:
	watchdog()
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.name = "Terrain3D"
	terrain.assets = Terrain3DAssets.new()
	scene.add_child(terrain)
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(32, 40, 32)
	scene.add_child(camera)
	root.add_child(scene)
	await process_frame
	await process_frame
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)

	streamer = terrain.get_streamer()
	require(streamer != null, "Terrain3D should own a Terrain3DStreamer")
	require(streamer.is_initialized(), "streamer should be initialized")
	require(terrain.get_streamer() == streamer, "get_streamer should be stable")

	streamer.set_use_terrain_directory(true)
	streamer.set_load_radius(1)
	streamer.set_unload_radius(1)
	streamer.set_loads_per_update(1)
	streamer.set_unloads_per_update(1)
	streamer.set_protect_modified(true)
	streamer.set_save_on_unload(false)
	streamer.set_max_resident(0)

	build_fixture()
	test_desired_order()
	test_save_without_directory()

	if not failed:
		test_ring_and_budget()
	if not failed:
		test_move()
	if not failed:
		test_missing_files()
	if not failed:
		test_modified_protection()
	if not failed:
		test_save_on_unload()
	if not failed:
		test_bounds_and_manual_api()
	if not failed:
		test_directory_switch_keeps_working()

	finished = true
	if failed:
		quit(1)
		return
	print("PASS region streaming ring, budgets, missing-file cache, modified protection, save on unload and file preservation")
	quit(0)
