extends SceneTree
## A rejected split must retain identity, payload, flags, layout and saved data.
var failed := false

func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var terrain := Terrain3D.new()
	terrain.vt_delivery_near_material = 0
	terrain.vt_delivery_far_material = 0
	terrain.vt_delivery_near_height = 0
	terrain.vt_delivery_far_height = 0
	root.add_child(terrain)
	terrain.collision_mode = 0
	terrain.set_physics_process(false)
	terrain.region_size = 128
	for location in [Vector2i(63, 0), Vector2i(-64, 0)]:
		var region := terrain.data.add_region_blank(location, false)
		region.get_height_map().fill(Color(123.5, 0, 0, 1))
		region.ensure_surface_map()
		var bytes := region.get_height_map().get_data()
		var surface := region.get_surface_map().get_data()
		var directory := "user://resize_" + str(location.x)
		DirAccess.make_dir_recursive_absolute(directory)
		var saved_path := directory.path_join(Terrain3DUtil.location_to_filename(location))
		require(region.save(saved_path) == OK, "could not prepare saved original")
		terrain.data.change_region_size(64)
		require(terrain.region_size == 128, "rejected resize changed region size")
		require(terrain.data.get_region(location) == region, "rejected resize replaced original")
		require(not region.is_deleted() and not region.is_modified(), "rejected resize changed save flags")
		require(region.get_height_map().get_data() == bytes, "rejected resize changed heights")
		require(region.get_surface_map().get_data() == surface, "rejected resize changed material IDs")
		require(terrain.data.get_region_locations().has(location), "rejected resize lost active location")
		terrain.data.save_directory(directory)
		require(FileAccess.file_exists(saved_path), "save after rejected resize deleted original file")
		var saved := ResourceLoader.load(saved_path, "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE) as Terrain3DRegion
		require(saved != null and saved.get_height_map().get_data() == bytes, "save after rejected resize changed persisted data")
		terrain.data.unload_region(location, false)
	# An ordinary merge and split must still work.
	var valid := terrain.data.add_region_blank(Vector2i.ZERO, false)
	valid.get_height_map().fill(Color(37.0, 0, 0, 1))
	terrain.data.change_region_size(64)
	require(terrain.region_size == 64 and terrain.data.get_region_count() == 4, "valid split rejected")
	require(terrain.data.get_height(Vector3(90, 0, 90)) == 37.0, "valid split lost data")
	terrain.data.change_region_size(128)
	require(terrain.region_size == 128 and terrain.data.get_region_count() == 1, "valid merge changed layout")
	require(terrain.data.get_height(Vector3(90, 0, 90)) == 37.0, "valid merge lost data")
	terrain.free()
	if not failed:
		print("PASS terrain region resize bounds preserve original data")
	quit(1 if failed else 0)
