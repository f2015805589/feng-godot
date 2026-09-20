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
const Dock := preload("res://addons/feng-idweight-terrain/src/asset_dock_common.gd")
const TerrainObjects := preload("res://addons/feng-idweight-terrain/utils/terrain_3d_objects.gd")
const TerrainSetup := preload("res://addons/feng-idweight-terrain/src/terrain_setup.gd")


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

	func is_terrain_valid(_terrain = null) -> bool:
		return valid and is_instance_valid(terrain) and is_instance_valid(terrain.assets)


class TestTerrainObjects extends TerrainObjects:

	var maps_edit_count := 0

	func _get_terrain_height(_global_position: Vector3) -> float:
		return 0.0

	func _on_maps_edited(_edited_area: AABB) -> void:
		maps_edit_count += 1


var failed := false


func _enter_tree() -> void:
	run.call_deferred()


func expect(value: bool, message: String) -> bool:
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

	await _test_list_entry(harness)
	await _test_list_container(harness)
	await _test_dock_reparent(harness)
	await _test_terrain_objects(harness)
	await _test_dismissed_weakrefs(harness)

	harness.free()
	if failed:
		get_tree().quit(1)
		return
	print("PASS Terrain editor lifecycle behaviour: resource signals, dock reparent, objects and dismissed weakrefs")
	get_tree().quit(0)


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
	var dock := Dock.new()
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
	expect(objects._child_transform_callbacks.size() == 1,
			"TerrainObjects did not retain exactly one child callback")
	objects.remove_child(child)
	await get_tree().process_frame
	expect(objects._child_transform_callbacks.is_empty(),
			"TerrainObjects retained a callback after child exit")
	if is_instance_valid(helper):
		expect(helper.transform_changed.get_connections().is_empty(),
			"TerrainObjects retained helper signal connection after child exit")
	objects.add_child(child)
	await get_tree().process_frame
	helper = child.get_node_or_null(^"TransformChangedSignaller")
	expect(is_instance_valid(helper), "TerrainObjects did not restore child helper on re-entry")
	if is_instance_valid(helper):
		expect(helper.transform_changed.get_connections().size() == 1,
			"TerrainObjects duplicated child callback after re-entry")
	expect(objects._child_transform_callbacks.size() == 1,
			"TerrainObjects did not restore exactly one child callback")
	objects.remove_child(child)
	await get_tree().process_frame
	child.free()

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
