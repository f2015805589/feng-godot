@tool
extends EditorPlugin

## Behavioural editor lifecycle regression for the Terrain3D addon.
##
## This deliberately creates the editor-side nodes in a headless editor and
## observes their real Signal connections.  The test is kept independent of the
## full plugin UI so it can exercise reparenting and teardown without opening a
## scene or a rendering viewport.

const ListEntry := preload("res://addons/feng-idweight-terrain/src/asset_dock_list_entry.gd")
const ListContainer := preload("res://addons/feng-idweight-terrain/src/asset_dock_list_container.gd")
const Dock := preload("res://addons/feng-idweight-terrain/src/asset_dock.gd")
const TerrainObjects := preload("res://addons/feng-idweight-terrain/utils/terrain_3d_objects.gd")
const TerrainSetup := preload("res://addons/feng-idweight-terrain/src/terrain_setup.gd")
const LayoutPreview := preload("res://addons/feng-idweight-terrain/src/vt_layout_preview.gd")
const ChannelPacker := preload("res://addons/feng-idweight-terrain/menu/channel_packer.gd")
const VTEditor := preload("res://addons/feng-idweight-terrain/src/vt_editor.gd")


class TestListContainer extends ListContainer:

	var swap_count := 0
	var update_count := 0

	func set_selected_after_swap(_type, _old_id: int, _new_id: int) -> void:
		swap_count += 1

	func update_asset_list() -> void:
		update_count += 1


class TestTerrain extends RefCounted:

	var assets: Terrain3DAssets


class TestPlugin extends EditorPlugin:

	var terrain: TestTerrain
	var valid := true
	var debug := 0
	var editor_settings = EditorInterface.get_editor_settings()
	var ui := SelectionUI.new()

	func is_terrain_valid(_terrain = null) -> bool:
		return valid and is_instance_valid(terrain) and is_instance_valid(terrain.assets)


class SelectionUI extends RefCounted:
	var pair_background_id := -1
	var pair_overlay_id := -1

	func _on_setting_changed() -> void:
		pass

	func set_button_editor_icon(_button: Button, _icon: String) -> void:
		pass


class TestDock extends Dock:
	func update_layout() -> void:
		pass


class OverviewSource extends RefCounted:
	var settings_reads := 0
	var pages: Array = []

	func get_data() -> Object:
		return self

	func get_vt_settings() -> Dictionary:
		settings_reads += 1
		return {"border": 0}

	func get_region_locations() -> Array:
		return [Vector2i.ZERO]

	func get_region_size() -> int:
		return 1

	func get_vertex_spacing() -> float:
		return 1.0

	func get_svt_baked_pages() -> Array:
		return pages


class OverviewProbe extends VTEditor:
	func _make_height_thumbnail(_bounds: Rect2, image_size: Vector2i) -> Image:
		return Image.create_empty(image_size.x, image_size.y, false, Image.FORMAT_RGBA8)


class BandSource extends RefCounted:
	var surface_svt_mip_distances := PackedFloat32Array()
	var max_mip := 2
	var page_world := 64.0
	var writes := 0

	func get_surface_svt_max_mip() -> int: return max_mip
	func get_surface_svt_page_world() -> float: return page_world
	func get_surface_svt_mip_distances() -> PackedFloat32Array: return surface_svt_mip_distances
	func set_surface_svt_mip_distances(value: PackedFloat32Array) -> void:
		writes += 1
		surface_svt_mip_distances = value.duplicate()
		for i in value.size():
			surface_svt_mip_distances[i] = maxf(1.0, value[i])


class PreviewProbe extends LayoutPreview:
	func _gate(_terrain: Object) -> bool: return true


class PackerProbe extends ChannelPacker:
	var packed_channels := Vector2i(-1, -1)
	func _pack_textures(_rgb: Image, _alpha: Image, _ao: Image, _path: String,
			_green: bool, _smooth: bool, _align: bool, _normalize: bool,
			alpha_channel: int, ao_channel: int = 0) -> Error:
		packed_channels = Vector2i(alpha_channel, ao_channel)
		return FAILED


class TestTerrainObjects extends TerrainObjects:

	var maps_edit_count := 0

	func _get_terrain_height(_global_position: Vector3) -> float:
		return 0.0

	func _on_maps_edited(_edited_area: AABB) -> void:
		maps_edit_count += 1


var failed := false
var checks := 0


func _enter_tree() -> void:
	run.call_deferred()


func expect(value: bool, message: String) -> bool:
	checks += 1
	if value:
		return true
	push_error("REGRESSION: " + message)
	failed = true
	return false


func _new_texture() -> Terrain3DTextureAsset:
	return Terrain3DTextureAsset.new()


func _new_mesh() -> Terrain3DMeshAsset:
	return Terrain3DMeshAsset.new()


func run() -> void:
	var harness := Node.new()
	harness.name = "TerrainLifecycleHarness"
	get_tree().root.add_child(harness)
	_test_asset_selection_bounds(harness)
	_test_overview_settings_snapshot()
	_test_detail_dispatch()
	_test_band_controls(harness)
	_test_preview_weak_lifetime()
	_test_packer_channels()

	await _test_list_entry(harness)
	await _test_list_container(harness)
	await _test_dock_reparent(harness)
	await _test_terrain_objects(harness)
	await _test_dismissed_weakrefs(harness)

	harness.free()
	if failed:
		get_tree().quit(1)
		return
	print("PASS Terrain editor lifecycle behaviour: %d checks" % checks)
	get_tree().quit(0)


func _test_asset_selection_bounds(harness: Node) -> void:
	var plugin := TestPlugin.new()
	var list := ListContainer.new()
	list.plugin = plugin
	harness.add_child(list)
	for index in Terrain3DAssets.MAX_TEXTURES:
		var entry := ListEntry.new()
		var asset := _new_texture()
		asset.id = index
		entry.set_edited_resource(asset)
		list.add_child(entry)
		list.entries.append(entry)
	var last_asset := Terrain3DAssets.MAX_TEXTURES - 1
	for query in ["", "matching filter"]:
		list.search_text = query
		list.set_selected_id(last_asset)
		expect(list.selected_id == last_asset and list.get_selected_asset_id() == last_asset,
				"full asset list excluded its last actual asset (search '%s')" % query)
	var empty := ListEntry.new()
	list.add_child(empty)
	list.entries.append(empty)
	for query in ["", "matching filter"]:
		list.search_text = query
		list.set_selected_id(last_asset + 1)
		expect(list.selected_id == last_asset and list.get_selected_asset_id() == last_asset,
				"empty add tile became an asset selection (search '%s')" % query)
	list.clear()
	expect(list._max_selectable_id() == 0 and list.get_selected_asset_id() == 0,
			"empty asset list lost its safe selection sentinel")
	list.free()
	plugin.free()


func _test_overview_settings_snapshot() -> void:
	var window := OverviewProbe.new()
	var source := OverviewSource.new()
	window.set_terrain(source)
	window._built = true
	window.overview = TerrainVTWorldOverview.new()
	window.overview_label = Label.new()
	window.add_child(window.overview)
	window.add_child(window.overview_label)
	for index in 4:
		var image := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
		image.fill(Color.WHITE)
		source.pages.append({"mip": 0, "preview": image,
				"world_rect": Rect2(Vector2(index % 2, index / 2) * 0.5, Vector2.ONE * 0.5)})
	window._refresh_overview()
	expect(source.settings_reads == 1, "overview reread the native settings report for each material page")
	var stitched: Image = window.overview.overview_texture.get_image()
	for point in [Vector2i(1, 1), Vector2i(766, 1), Vector2i(1, 766), Vector2i(766, 766)]:
		expect(stitched.get_pixelv(point).is_equal_approx(Color.WHITE), "overview lost a stitched material page")
	window.free()


func _test_detail_dispatch() -> void:
	var source := OverviewSource.new()
	var window := VTEditor.new()
	window.initialize(null)
	window.terrain = source
	window._selected_hierarchy_kind = "cdlod"
	window._refresh_page_details()
	expect(source.settings_reads == 0, "CDLOD details unnecessarily read the VT page snapshot")
	expect(window.cdlod_panel.visible and not window.settings_panel.visible,
			"details dispatch showed the wrong panel")
	window.free()


func _test_band_controls(harness: Node) -> void:
	var source := BandSource.new()
	var panel := VBoxContainer.new()
	harness.add_child(panel)
	var bands := TerrainVTEditorSvtBands.new()
	bands.build(panel)
	bands.refresh(source)
	expect(bands.spins.size() == 3 and bands.spins[2].value == 512.0,
			"automatic bands changed their world-distance rule")
	var first := bands.spins[0]
	bands.refresh(source)
	expect(bands.spins[0] == first and source.writes == 0,
			"unchanged band refresh rebuilt controls or wrote back")
	bands.spins[0].value = 200.0
	expect(source.writes == 1 and source.surface_svt_mip_distances == PackedFloat32Array([200, 256, 512]),
			"editing one band did not pin exactly one complete table")
	bands.automatic()
	expect(source.writes == 2 and source.surface_svt_mip_distances.is_empty() and bands.spins[0].value == 128.0,
			"automatic did not clear the explicit table and restore distances")
	source.page_world = 32.0
	bands.refresh(source)
	bands.fit_to_page_size()
	expect(source.writes == 3 and source.surface_svt_mip_distances == PackedFloat32Array([64, 128, 256]),
			"pinning automatic bands ignored the current page size")
	source.max_mip = 0
	bands.refresh(source)
	expect(bands.spins.size() == 1 and bands.grid.get_child_count() == 2,
			"shrinking the band table left old controls attached")
	panel.free()


func _test_preview_weak_lifetime() -> void:
	var preview := PreviewProbe.new()
	var changes: Array[bool] = []
	preview.availability_changed.connect(func(value: bool): changes.append(value))
	var terrain := RefCounted.new()
	preview.set_terrain(terrain)
	expect(preview._get_terrain() == terrain and preview.visible, "preview did not bind its terrain")
	terrain = null
	expect(preview._get_terrain() == null, "preview retained its released terrain")
	preview.set_terrain(null)
	expect(not preview.visible and changes == [true, false], "preview availability changed incorrectly on release")
	preview.free()


func _test_packer_channels() -> void:
	var plugin := TestPlugin.new()
	var packer := PackerProbe.new()
	packer.plugin = plugin
	for iteration in 2:
		packer.pack_textures_popup()
		for channel in 4:
			packer.height_channel[channel].button_pressed = true
			packer.height_channel[channel].pressed.emit()
			packer.packing_albedo = true
			packer._on_save_file_selected("user://channel-test.png")
			expect(packer.packed_channels.x == channel, "packer ignored the selected height channel")
			packer.roughness_channel[channel].button_pressed = true
			packer.roughness_channel[channel].pressed.emit()
			packer.occlusion_channel[3 - channel].button_pressed = true
			packer.occlusion_channel[3 - channel].pressed.emit()
			packer.packing_albedo = false
			packer._on_save_file_selected("user://channel-test.png")
			expect(packer.packed_channels == Vector2i(channel, 3 - channel), "packer ignored the selected material channels")
		packer._on_close_requested()
	plugin.free()


func _test_list_entry(harness: Node) -> void:
	var entry: Node = ListEntry.new()
	harness.add_child(entry)
	await get_tree().process_frame

	var first := _new_texture()
	var second := _new_texture()
	expect(entry.button_enabled == null, "texture entry allocated an unparented enabled button")
	var entry_orphans_before := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	for _i in 4:
		entry.setup_buttons()
	expect(entry.button_enabled == null, "texture entry gained an enabled button after rebuilding controls")
	var entry_orphans_after := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	expect(entry_orphans_after <= entry_orphans_before,
			"rebuilding texture entry controls increased orphan nodes (%d -> %d)" % [entry_orphans_before, entry_orphans_after])
	var changed_count := [0]
	entry.changed.connect(func(_resource): changed_count[0] += 1)
	entry.set_edited_resource(first)
	entry.set_edited_resource(second)
	first.emit_signal(&"setting_changed")
	expect(changed_count[0] == 0, "ListEntry still receives setting_changed from its replaced resource")
	second.emit_signal(&"setting_changed")
	expect(changed_count[0] == 1, "ListEntry did not receive setting_changed from its current resource")
	entry.set_edited_resource(first)
	second.emit_signal(&"file_changed")
	expect(changed_count[0] == 1, "ListEntry still receives file_changed from an old resource")
	first.emit_signal(&"file_changed")
	expect(changed_count[0] == 2, "ListEntry did not rebind file_changed to the new resource")

	# The count callback is installed only after count_label exists. Replacing
	# mesh assets must release the old callback and leave the current one usable.
	var mesh_entry: Node = ListEntry.new()
	mesh_entry.type = Terrain3DAssets.TYPE_MESH
	harness.add_child(mesh_entry)
	await get_tree().process_frame
	var old_mesh := _new_mesh()
	var new_mesh := _new_mesh()
	expect(is_instance_valid(mesh_entry.button_enabled) and mesh_entry.button_enabled.get_parent() == mesh_entry.button_row,
			"mesh entry enabled button is not owned by its button row")
	var mesh_orphans_before := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	for _i in 4:
		mesh_entry.setup_buttons()
	expect(is_instance_valid(mesh_entry.button_enabled) and mesh_entry.button_enabled.get_parent() == mesh_entry.button_row,
			"mesh entry lost button ownership after rebuilding controls")
	var mesh_orphans_after := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	expect(mesh_orphans_after <= mesh_orphans_before,
			"rebuilding mesh entry controls increased orphan nodes (%d -> %d)" % [mesh_orphans_before, mesh_orphans_after])
	mesh_entry.set_edited_resource(old_mesh)
	mesh_entry.set_edited_resource(new_mesh)
	expect(not old_mesh.instance_count_changed.is_connected(mesh_entry.update_count_label),
			"ListEntry retained instance_count_changed on a replaced mesh")
	expect(new_mesh.instance_count_changed.is_connected(mesh_entry.update_count_label),
			"ListEntry did not connect instance_count_changed on its current mesh")
	old_mesh.emit_signal(&"instance_count_changed")
	new_mesh.emit_signal(&"instance_count_changed")
	var destroy_orphans_before := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	mesh_entry.free()
	entry.free()
	first = null
	second = null
	old_mesh = null
	new_mesh = null
	await get_tree().process_frame
	var destroy_orphans_after := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	expect(destroy_orphans_after <= destroy_orphans_before,
			"destroying entries increased orphan nodes (%d -> %d)" % [destroy_orphans_before, destroy_orphans_after])


func _test_list_container(harness: Node) -> void:
	var parent_a := Node.new()
	var parent_b := Node.new()
	harness.add_child(parent_a)
	harness.add_child(parent_b)
	var container := TestListContainer.new()
	container.focus_style = StyleBoxFlat.new()
	parent_a.add_child(container)
	await get_tree().process_frame

	var first := _new_texture()
	container.add_item(first)
	expect(first.id_changed.is_connected(container.set_selected_after_swap),
			"ListContainer did not observe the first resource")
	first.emit_signal(&"id_changed", Terrain3DAssets.TYPE_TEXTURE, 0, 1)
	expect(container.swap_count == 1, "ListContainer did not receive the current resource id_changed")

	container.clear()
	expect(not first.id_changed.is_connected(container.set_selected_after_swap),
			"ListContainer retained id_changed after clear")
	first.emit_signal(&"id_changed", Terrain3DAssets.TYPE_TEXTURE, 1, 2)
	expect(container.swap_count == 1, "ListContainer received id_changed after clear")

	var second := _new_texture()
	container.add_item(second)
	expect(second.id_changed.is_connected(container.set_selected_after_swap),
			"ListContainer did not observe a resource after clear")
	second.emit_signal(&"id_changed", Terrain3DAssets.TYPE_TEXTURE, 0, 1)
	expect(container.swap_count == 2, "ListContainer current resource signal stopped working after clear")

	# The list itself is reparented. Its entry survives, so _exit_tree must
	# disconnect and _enter_tree must restore the source callback.
	parent_a.remove_child(container)
	expect(not second.id_changed.is_connected(container.set_selected_after_swap),
			"ListContainer retained id_changed while outside the tree")
	parent_b.add_child(container)
	await get_tree().process_frame
	expect(second.id_changed.is_connected(container.set_selected_after_swap),
			"ListContainer did not restore id_changed after reparent")
	second.emit_signal(&"id_changed", Terrain3DAssets.TYPE_TEXTURE, 1, 2)
	expect(container.swap_count == 3, "ListContainer restored connection is not active")

	container.clear()
	container.free()
	parent_a.free()
	parent_b.free()
	first = null
	second = null
	await get_tree().process_frame


func _test_dock_reparent(harness: Node) -> void:
	var assets_a := Terrain3DAssets.new()
	var assets_b := Terrain3DAssets.new()
	var terrain := TestTerrain.new()
	terrain.assets = assets_a
	var plugin := TestPlugin.new()
	plugin.terrain = terrain

	var texture_list := TestListContainer.new()
	var mesh_list := TestListContainer.new()
	var dock := TestDock.new()
	dock.plugin = plugin
	dock._initialized = true
	dock.texture_list = texture_list
	dock.mesh_list = mesh_list
	dock.add_child(texture_list)
	dock.add_child(mesh_list)
	var parent_a := Node.new()
	var parent_b := Node.new()
	harness.add_child(parent_a)
	harness.add_child(parent_b)
	parent_a.add_child(dock)
	await get_tree().process_frame

	expect(assets_a.textures_changed.is_connected(texture_list.update_asset_list),
			"dock did not bind its initial assets resource")
	assets_a.emit_signal(&"textures_changed")
	expect(texture_list.update_count == 1, "dock initial assets callback is not active")

	parent_a.remove_child(dock)
	expect(not assets_a.textures_changed.is_connected(texture_list.update_asset_list),
			"dock retained assets callback while outside the tree")
	assets_a.emit_signal(&"textures_changed")
	expect(texture_list.update_count == 1, "dock callback fired after leaving the tree")

	parent_b.add_child(dock)
	await get_tree().process_frame
	expect(assets_a.textures_changed.is_connected(texture_list.update_asset_list),
			"dock did not restore assets callback after reparent")
	assets_a.emit_signal(&"textures_changed")
	expect(texture_list.update_count == 2, "dock restored callback is not active")

	# A scene/terrain switch must release the old source before binding the new one.
	dock.unbind_assets()
	expect(not assets_a.textures_changed.is_connected(texture_list.update_asset_list),
			"dock.unbind_assets did not release the old source")
	plugin.terrain.assets = assets_b
	dock._bind_assets_signals(assets_b)
	expect(assets_b.textures_changed.is_connected(texture_list.update_asset_list),
			"dock did not bind the replacement assets source")
	assets_a.emit_signal(&"textures_changed")
	assets_b.emit_signal(&"textures_changed")
	expect(texture_list.update_count == 3, "dock replacement source binding is incorrect")

	dock.free()
	parent_a.free()
	parent_b.free()
	plugin.free()
	plugin = null
	terrain = null
	assets_a = null
	assets_b = null
	await get_tree().process_frame


func _test_terrain_objects(harness: Node) -> void:
	var terrain := Terrain3D.new()
	harness.add_child(terrain)
	await get_tree().process_frame
	var data_a = terrain.data
	expect(is_instance_valid(data_a), "Terrain3D did not create data for objects lifecycle test")
	var terrain_b := Terrain3D.new()
	harness.add_child(terrain_b)
	await get_tree().process_frame
	var data_b = terrain_b.data
	expect(is_instance_valid(data_b), "second Terrain3D did not create data for rebinding test")

	var objects := TestTerrainObjects.new()
	harness.add_child(objects)
	objects.call("_bind_terrain_data", data_a)
	expect(data_a.maps_edited.is_connected(objects._on_maps_edited),
			"TerrainObjects did not bind the first data source")
	objects.call("_bind_terrain_data", data_b)
	expect(not data_a.maps_edited.is_connected(objects._on_maps_edited),
			"TerrainObjects retained maps_edited on its replaced data source")
	expect(data_b.maps_edited.is_connected(objects._on_maps_edited),
			"TerrainObjects did not bind the replacement data source")
	objects.call("_bind_terrain_data", data_b)
	data_a.emit_signal(&"maps_edited", AABB(Vector3.ZERO, Vector3.ONE))
	expect(objects.maps_edit_count == 0, "TerrainObjects received maps_edited from old data")
	data_b.emit_signal(&"maps_edited", AABB(Vector3.ZERO, Vector3.ONE))
	expect(objects.maps_edit_count == 1, "TerrainObjects did not receive maps_edited from current data")
	data_b.emit_signal(&"maps_edited", AABB(Vector3.ZERO, Vector3.ONE))
	expect(objects.maps_edit_count == 2, "TerrainObjects duplicated maps_edited after same-source bind")

	# Entering and leaving the same parent repeatedly must create one helper
	# callback and release it before the next entry.
	var child := Node3D.new()
	objects.add_child(child)
	await get_tree().process_frame
	var helper: Node = child.get_node_or_null(^"TransformChangedSignaller")
	expect(is_instance_valid(helper), "TerrainObjects did not create a child transform helper")
	if is_instance_valid(helper):
		expect(helper.transform_changed.get_connections().size() == 1,
			"TerrainObjects connected more than one child transform callback")
	objects.remove_child(child)
	if is_instance_valid(helper):
		expect(helper.transform_changed.get_connections().is_empty(),
			"TerrainObjects retained helper signal connection after child exit")
	await get_tree().process_frame
	objects.add_child(child)
	await get_tree().process_frame
	helper = child.get_node_or_null(^"TransformChangedSignaller")
	expect(is_instance_valid(helper), "TerrainObjects did not restore child helper on re-entry")
	if is_instance_valid(helper):
		expect(helper.transform_changed.get_connections().size() == 1,
			"TerrainObjects duplicated child callback after re-entry")
	objects.remove_child(child)
	await get_tree().process_frame
	child.free()

	var moved := Node3D.new()
	objects.add_child(moved)
	objects.remove_child(moved)
	harness.add_child(moved)
	await get_tree().process_frame
	expect(not objects._offsets.has(moved.get_instance_id()),
			"deferred setup retained a child already reparented elsewhere")
	expect(moved.get_node_or_null(^"TransformChangedSignaller") == null,
			"rapid reparent left an orphan transform helper")
	moved.free()

	harness.remove_child(objects)
	expect(not data_b.maps_edited.is_connected(objects._on_maps_edited),
			"TerrainObjects retained data signal after leaving the tree")
	objects.free()
	terrain.free()
	terrain_b.free()
	await get_tree().process_frame


func _test_dismissed_weakrefs(harness: Node) -> void:
	var setup := TerrainSetup.new()
	harness.add_child(setup)
	var live := Terrain3D.new()
	var dead := Terrain3D.new()
	setup.call("_remember_dismissed", live)
	setup.call("_remember_dismissed", dead)
	expect(setup.dismissed.size() == 2, "dismissed did not retain live and pending terrain objects")
	expect(setup.call("_is_dismissed", live), "dismissed lost a still-live terrain object")
	dead.free()
	var probe := Terrain3D.new()
	expect(not setup.call("_is_dismissed", probe), "dismissed matched an unrelated terrain object")
	expect(setup.dismissed.size() == 1, "dismissed did not prune a released WeakRef during an event")
	expect(setup.call("_is_dismissed", live), "dismissed live WeakRef was pruned as dead")
	setup.free()
	live.free()
	probe.free()
	await get_tree().process_frame
