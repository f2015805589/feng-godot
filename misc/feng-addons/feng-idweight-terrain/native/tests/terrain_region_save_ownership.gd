extends SceneTree
## Saving a quantized copy must not change the live resource graph.
var failed := false

func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)

func _initialize() -> void:
	var region := Terrain3DRegion.new()
	region.set_region_size(64)
	region.set_location(Vector2i.ZERO)
	region.sanitize_maps()
	var original := region.get_height_map()
	original.fill(Color(1.234567, 0, 0, 1))
	var bytes := original.get_data()
	var shared := region.duplicate(false) as Terrain3DRegion
	var expect_failure := OS.get_environment("FENG_REGION_SAVE_FAILURE") == "1"
	var path := "user://missing-save-directory/region.res" if expect_failure else "user://region-save-ownership.res"
	var result := region.save(path, true)
	require(result != OK if expect_failure else result == OK, "unexpected 16-bit save result")
	require(region.is_modified() == expect_failure, "save changed the success/failure dirty-state contract")
	require(region.get_height_map() == original, "save replaced the live height image identity")
	require(original.get_format() == Image.FORMAT_RF, "save changed an external height image to half precision")
	require(original.get_data() == bytes, "save quantized the external live height bytes")
	require(shared.get_height_map() == original and shared.get_height_map().get_data() == bytes, "save mutated a shallow region copy")
	if not expect_failure:
		var loaded := ResourceLoader.load(path, "Terrain3DRegion", ResourceLoader.CACHE_MODE_IGNORE) as Terrain3DRegion
		require(loaded != null, "saved 16-bit region cannot reload")
		if loaded != null:
			require(absf(loaded.get_height_map().get_pixel(0, 0).r - 1.234375) < 0.00001, "file did not contain half-precision heights")
	if not failed:
		print("PASS 16-bit region save preserves live shared height images")
	quit(1 if failed else 0)
