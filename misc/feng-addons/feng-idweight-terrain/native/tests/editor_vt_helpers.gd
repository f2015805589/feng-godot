@tool
extends EditorPlugin
## Editor helpers remain usable without the optional terrain native library.

const DirectorySetup = preload("res://addons/feng-idweight-terrain/menu/directory_setup.gd")

var failures := 0
var checks := 0


class PageSource extends RefCounted:
	var reads := 0
	var pages: Variant = [
		{"kind": "avt", "slot": 1},
		{"kind": 1, "slot": 2},
		{"kind": "SVT", "slot": 3},
		{"kind": 0, "slot": 4},
		{"kind": "future", "slot": 5},
		"malformed record",
	]

	func get_region_size() -> int:
		return 256

	func get_vertex_spacing() -> float:
		return 1.0

	func get_surface_svt_page_world() -> float:
		return 64.0

	func get_surface_svt_texels_per_meter() -> float:
		return 1.0

	func is_surface_vt_enabled() -> bool:
		return true

	func is_surface_svt_enabled() -> bool:
		return true

	func get_vt_pages() -> Variant:
		reads += 1
		return pages


class AutoBakeProperty extends RefCounted:
	var auto_bake := false

	func is_svt_auto_bake() -> bool:
		return true


class AutoBakeGetter extends RefCounted:
	func is_svt_auto_bake() -> bool:
		return false


class PreviewSource extends Node:
	var enabled := false
	var gates := 0
	var reads := 0

	func is_vt_delivery_used(_method: int) -> bool:
		gates += 1
		return enabled

	func has_vt_clipmap_layer() -> bool:
		return is_vt_delivery_used(0)

	func get_avt_layout_preview(_camera: Camera3D) -> Dictionary:
		reads += 1
		return {"bounds": Rect2(0, 0, 64, 64)}

	func get_clipmap_layout_preview() -> Dictionary:
		reads += 1
		return {"layers": [{"implementation": "LOD"}]}


func _enter_tree() -> void:
	run.call_deferred()


func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("VT HELPER: " + message)


func run() -> void:
	await get_tree().process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	test_bridge_boundaries()
	test_page_snapshot()
	test_material_pages()
	test_directory_picker()
	test_preview_polling()
	if failures == 0:
		print("PASS terrain editor VT helpers: %d checks" % checks)
	get_tree().quit(1 if failures else 0)


func test_bridge_boundaries() -> void:
	require(TerrainVTBridge.call_method(null, &"get_data") == null, "null target must be unavailable")
	require(not TerrainVTBridge.has_property(null, &"auto_bake"), "null target cannot expose a property")
	var old_build := RefCounted.new()
	require(TerrainVTBridge.call_method(old_build, &"get_data") == null, "missing method must be unavailable")
	require(TerrainVTBridge.vt_settings(old_build).is_empty(), "missing settings must stay empty")
	for target in [null, old_build]:
		require(TerrainVTBridge.svt_auto_bake(target, &"auto_bake"), "unavailable auto-bake must retain its default")
	require(not TerrainVTBridge.svt_auto_bake(AutoBakeProperty.new(), &"auto_bake"), "auto-bake property must take priority over its getter")
	require(not TerrainVTBridge.svt_auto_bake(AutoBakeGetter.new(), &"auto_bake"), "getter fallback must preserve false")


func test_page_snapshot() -> void:
	var source := PageSource.new()
	var shot := TerrainVTEditorPageRows.snapshot(source, null, 3)
	require(source.reads == 1, "snapshot must read the resident page report exactly once")
	require(shot.all_pages.size() == 5, "report boundary must discard malformed records")
	require(shot.avt_pages == [source.pages[0], source.pages[3]], "AVT partition changed its order or kind decoding")
	require(shot.svt_pages == [source.pages[1], source.pages[2]], "SVT partition changed its order or kind decoding")
	require(shot.baked_mip == 3 and shot.locations.is_empty(), "snapshot defaults changed")
	require(TerrainVTEditorPageRows.pages_of(shot, "") == shot.all_pages, "all-page view lost unknown future tiers")
	for report in [[], null, {"unexpected": true}]:
		source.pages = report
		source.reads = 0
		shot = TerrainVTEditorPageRows.snapshot(source, null, 0)
		require(source.reads == 1 and shot.all_pages.is_empty() and shot.avt_pages.is_empty() and shot.svt_pages.is_empty(), "empty or unsupported reports must produce empty partitions")


func test_material_pages() -> void:
	require(TerrainVTOverviewImage.material_pages([], 0).is_empty(), "empty material page list changed")
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var selected := {"mip": 2, "preview": image}
	var pages := [null, "bad", {"mip": 2}, {"mip": 2, "preview": Image.new()}, {"mip": 1, "preview": image}, selected]
	require(TerrainVTOverviewImage.material_pages(pages, 2) == [selected], "material filtering lost mip or image validation")


func test_directory_picker() -> void:
	var wizard := DirectorySetup.new()
	add_child(wizard)
	var picker: EditorFileDialog = wizard.editor_file_dialog
	require(picker.file_mode == EditorFileDialog.FILE_MODE_OPEN_DIR, "wizard must configure its directory mode at construction")
	require(picker.filters.is_empty(), "directory picker must not retain file-only filters")
	for iteration in 2:
		wizard._on_select_file_pressed()
		require(picker.visible and picker.file_mode == EditorFileDialog.FILE_MODE_OPEN_DIR, "reopening the picker changed its mode")
		picker.hide()
	wizard.free()


func test_preview_polling() -> void:
	for script in ["vt_avt_layout_preview.gd", "vt_clipmap_preview.gd"]:
		var host := Control.new()
		EditorInterface.get_base_control().add_child(host)
		var preview = load("res://addons/feng-idweight-terrain/src/" + script).new()
		host.add_child(preview)
		preview.set_process(false)
		var availability: Array[bool] = []
		preview.availability_changed.connect(func(value: bool): availability.append(value))
		var source := PreviewSource.new()
		preview.set_terrain(source)
		require(source.gates == 1 and not preview.is_available() and not preview.visible, script + ": assignment must answer the gate once")
		poll_preview(preview)
		require(source.reads == 0, script + ": unavailable views must not request layouts")
		host.hide()
		source.enabled = true
		poll_preview(preview)
		require(preview.is_available() and source.reads == 0, script + ": hidden hosts must poll availability without layouts")
		host.show()
		poll_preview(preview)
		require(source.reads == 1 and not (preview.get("_snapshot") as Dictionary).is_empty(), script + ": shown views must read one layout")
		preview._process(0.0)
		require(source.reads == 1, script + ": repeated frames must respect the poll interval")
		source.enabled = false
		poll_preview(preview)
		require(not preview.visible and (preview.get("_snapshot") as Dictionary).is_empty(), script + ": disabling the method must clear its layout")
		source.enabled = true
		poll_preview(preview)
		require(preview.visible and source.reads == 2, script + ": re-enabling must resume layout reads")
		source.free()
		poll_preview(preview)
		require(not preview.is_available() and (preview.get("_snapshot") as Dictionary).is_empty(), script + ": freed terrains must hide and clear their layout")
		require(availability == [true, false, true, false], script + ": hosts must receive each availability change exactly once")
		if script == "vt_clipmap_preview.gd":
			require((preview.get("_layer") as Dictionary).is_empty(), "freed terrain must clear the selected clipmap layer")
		var old_build := RefCounted.new()
		preview.set_terrain(old_build)
		require(preview.is_available(), script + ": missing optional gate must preserve older-native fallback")
		preview.set_terrain(null)
		require(not preview.is_available(), script + ": clearing selection must hide immediately")
		host.free()


func poll_preview(preview: Control) -> void:
	preview.set("_last_poll_sec", -INF)
	preview.call("_process", 0.0)
