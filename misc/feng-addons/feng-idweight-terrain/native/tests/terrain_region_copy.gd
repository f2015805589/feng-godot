extends SceneTree
## Resource ownership regression; runs headlessly without a renderer or editor plugin.

var failed := false

func require(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error("REGRESSION: " + message)

func _initialize() -> void:
	call_deferred("run")

func check_metadata(source: Terrain3DRegion, copy: Terrain3DRegion, edited: bool) -> void:
	var original := source.get_data()
	var actual := copy.get_data()
	require(actual.size() == original.size(), "copy lost serialized metadata keys")
	for key in original:
		if key in ["height_map", "control_map", "color_map", "surface_map", "instances", "edited"]:
			continue
		require(actual[key] == original[key], "copy changed metadata: " + key)
	require(copy.is_edited() == edited, "copy changed edit-transaction semantics")

func run() -> void:
	# A new resource and a region with only one loaded map are both valid states.
	var empty := Terrain3DRegion.new()
	var empty_copy := empty.duplicate(true) as Terrain3DRegion
	require(empty_copy != null, "empty region did not duplicate")
	check_metadata(empty, empty_copy, false)
	for key in ["height_map", "control_map", "color_map", "surface_map"]:
		require(empty_copy.get_data()[key] == null, "empty copy created a missing map: " + key)
	var partial := Terrain3DRegion.new()
	var control := Image.create(64, 64, false, Image.FORMAT_RF)
	control.fill(Color(0.0, 0.0, 0.0, 1.0))
	partial.set_control_map(control)
	partial.set_location(Vector2i(-2, 3))
	partial.set_vertex_spacing(2.0)
	partial.set_surface_density(2)
	partial.set_height_range(Vector2(-7, 19))
	partial.set_edited(true)
	partial.set_deleted(true)
	partial.set_modified(true)
	partial.set_instances({3: {Vector2i.ZERO: [[Transform3D.IDENTITY], PackedColorArray([Color.RED]), true]}})
	var shallow := partial.duplicate(false) as Terrain3DRegion
	var deep := partial.duplicate(true) as Terrain3DRegion
	check_metadata(partial, shallow, true)
	check_metadata(partial, deep, false)
	require(shallow.get_control_map() == control, "shallow copy lost shared image identity")
	require(deep.get_control_map() != control and deep.get_control_map().get_data() == control.get_data(), "deep copy did not isolate control bytes")
	require(deep.get_height_map() == null and deep.get_color_map() == null, "partial copy filled absent maps")
	deep.get_control_map().set_pixel(0, 0, Color(1, 0, 0, 1))
	require(control.get_pixel(0, 0).r == 0.0, "deep image mutation reached the source")
	deep.get_instances()[3][Vector2i.ZERO][0].append(Transform3D.IDENTITY)
	require(partial.get_instances()[3][Vector2i.ZERO][0].size() == 1, "deep nested instance mutation reached source")
	shallow.get_instances()[3][Vector2i.ZERO][0].append(Transform3D.IDENTITY)
	require(partial.get_instances()[3][Vector2i.ZERO][0].size() == 2, "shallow instance ownership changed")

	# Explicit conversion retains working flags and missing maps, and replaces the
	# surface payload at authored density without aliasing the source resources.
	var converted := partial.create_surface_conversion()
	require(bool(converted.get("success", false)), "partial legacy region conversion failed")
	if bool(converted.get("success", false)):
		var region := converted["region"] as Terrain3DRegion
		require(region.is_edited() and region.is_deleted() and region.is_modified(), "conversion lost working flags")
		require(region.get_location() == partial.get_location() and region.get_vertex_spacing() == 2.0, "conversion lost location/spacing")
		require(region.get_surface_density() == 2 and region.get_surface_map().get_width() == 128, "conversion lost density")
		require(region.get_height_map() == null and region.get_color_map() == null, "conversion filled missing maps")
		require(region.get_control_map() != control and region.get_control_map().get_data() == control.get_data(), "conversion shares legacy control")
		region.get_instances()[3][Vector2i.ZERO][0].clear()
		require(partial.get_instances()[3][Vector2i.ZERO][0].size() == 2, "conversion shares instance arrays")
		require(partial.get_surface_map() == null, "conversion mutated source surface")

	# Fully initialized undo snapshots must retain every image byte and isolate all
	# four images, including the optional packed-ID surface map.
	partial.sanitize_maps()
	partial.ensure_surface_map()
	var complete := partial.duplicate(true) as Terrain3DRegion
	check_metadata(partial, complete, false)
	for key in ["height_map", "control_map", "color_map", "surface_map"]:
		var source_image: Image = partial.get_data()[key]
		var copied_image: Image = complete.get_data()[key]
		require(source_image != copied_image and source_image.get_data() == copied_image.get_data(), "full snapshot does not isolate " + key)
		copied_image.fill(Color(0.3, 0.4, 0.5, 1.0))
		require(source_image.get_data() != copied_image.get_data(), "copied image remains aliased: " + key)
	if not failed:
		print("PASS terrain region copy preserves metadata and resource ownership")
	quit(1 if failed else 0)
