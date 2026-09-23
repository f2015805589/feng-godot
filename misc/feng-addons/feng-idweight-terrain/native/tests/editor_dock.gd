@tool
extends EditorPlugin

## Graphical editor regression for the Terrain3D asset dock layout.
##
## The test plugin is copied into an isolated project by the test runner. It
## creates and selects a real Terrain3D node, then exercises the dock that the
## production terrain editor plugin instantiated. The project is launched
## with a real rendering driver; this is intentionally an editor test rather
## than a headless script check.

const MENU_TEXTURE_ARRAY: int = 1
const MENU_TERRAIN_MAPS: int = 2
const MENU_VT_EDITOR: int = 4
const MENU_DEBUG_SHADED: int = 10
const MENU_DEBUG_HEIGHTMAP: int = 11
const MENU_DEBUG_CONTROL_IDS: int = 12
const MENU_DEBUG_CONTROL_WEIGHT: int = 13
const MENU_DEBUG_SLOPE: int = 14

var _finished: bool = false


func _enter_tree() -> void:
	call_deferred("_run")


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("EDITOR_DOCK_REGRESSION: " + message)
	get_tree().quit(1)


func _require(condition: bool, message: String) -> bool:
	if condition:
		return true
	_fail(message)
	return false


func _has_property(target: Object, property_name: StringName) -> bool:
	for property_info: Dictionary in target.get_property_list():
		if StringName(property_info.get("name", "")) == property_name:
			return true
	return false


func _wait_frames(count: int = 1) -> void:
	for _i in count:
		await get_tree().process_frame


func _wait_for_editor_progress_dialog() -> bool:
	for _i in 360:
		var progress_open := false
		for candidate: Node in get_tree().root.find_children("*", "ProgressDialog", true, false):
			if candidate is Window and candidate.visible:
				progress_open = true
				break
			if candidate is Control and candidate.is_visible_in_tree():
				progress_open = true
				break
		if not progress_open:
			return true
		await get_tree().process_frame
	return false


func _wait_for_management_menu() -> MenuButton:
	var base := EditorInterface.get_base_control()
	for _i in 180:
		var candidate := base.find_child("ManagementMenu", true, false) as MenuButton
		if candidate:
			return candidate
		await get_tree().process_frame
	return null


func _dock_from_menu(menu: MenuButton) -> Control:
	var node: Node = menu
	while node:
		if node is PanelContainer and node.name == "Terrain3D":
			return node
		node = node.get_parent()
	return null


func _measure_layout(dock: Control, menu: MenuButton, width: float) -> Dictionary:
	# The editor's dock container owns the child size and would overwrite a test
	# width on the next sort. Temporarily put the real asset dock under the
	# editor base control so update_layout() sees the requested width verbatim.
	var old_parent: Node = dock.get_parent()
	var old_index: int = dock.get_index()
	var base: Control = EditorInterface.get_base_control()
	dock.reparent(base, false)
	dock.position = Vector2(-10000.0, -10000.0)
	dock.size = Vector2(width, 320.0)
	dock.call("update_layout")
	await _wait_frames(2)
	dock.size = Vector2(width, 320.0)
	dock.call("update_layout")
	await _wait_frames(2)
	var combined: Vector2 = dock.get_combined_minimum_size()
	var actual_size: Vector2 = dock.size
	var management_size: Vector2 = menu.size
	print("EDITOR_DOCK_MEASURE width=", width, " dock_size=", actual_size,
			" combined_min=", combined, " management_size=", management_size)
	dock.reparent(old_parent, false)
	old_parent.move_child(dock, old_index)
	await _wait_frames(1)
	return {"combined_min": combined, "dock_size": actual_size,
			"management_size": management_size}


func _assert_debug_state(terrain: Terrain3D, expected: int) -> bool:
	var view_index: int = expected - MENU_DEBUG_SHADED
	var heightmap := terrain.get_show_heightmap()
	var control_ids := terrain.get_show_control_texture()
	var control_weight := terrain.get_show_control_blend()
	var slope := terrain.get_show_slope()
	var expected_heightmap := view_index == 1
	var expected_control_ids := view_index == 2
	var expected_control_weight := view_index == 3
	var expected_slope := view_index == 4
	return _require(heightmap == expected_heightmap and
			control_ids == expected_control_ids and
			control_weight == expected_control_weight and
			slope == expected_slope,
			"debug menu id %d did not select the expected Terrain3D view" % expected)


func _run() -> void:
	# Let the production plugin finish its editor dock initialization and the
	# resource filesystem import before creating the test scene.
	await _wait_frames(40)
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	# A rejected search result never enters the tree. It must release both its
	# node and the resource signal connections created during initialization.
	for script_name in ["asset_dock.gd", "asset_dock_45.gd"]:
		var dock_script = load("res://addons/feng-idweight-terrain/src/" + script_name)
		var filtered_list = dock_script.ListContainer.new()
		filtered_list.search_text = "__no_matching_terrain_asset__"
		var asset := Terrain3DTextureAsset.new()
		var before := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
		for i in 100:
			filtered_list.add_item(asset)
		var after := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
		var connections := asset.get_signal_connection_list("setting_changed").size()
		filtered_list.free()
		if not _require(after == before and connections == 0,
				"%s filtered results leaked nodes (%d -> %d) or callbacks (%d)" % [script_name, before, after, connections]):
			return
	print("PASS repeated asset filtering releases rejected nodes and callbacks in both dock versions")

	var scene_root := Node3D.new()
	scene_root.name = "TerrainDockEditorTest"
	var terrain := Terrain3D.new()
	if not _require(_has_property(terrain, &"surface_svt_auto_bake"),
			"Terrain3D did not expose the SVT Auto Bake setting"):
		return
	if not _require(bool(terrain.get(&"surface_svt_auto_bake")),
			"SVT Auto Bake should default to enabled"):
		return
	# Keep fixture construction deterministic; the UI toggle below covers the
	# enabled state without starting a bake while regions are being assembled.
	terrain.set(&"surface_svt_auto_bake", false)
	terrain.name = "Terrain3D"
	terrain.region_size = 64
	terrain.vt_page_size = 32
	terrain.vt_page_border = 2
	terrain.vt_page_count = 64
	terrain.vt_pages_per_update = 4
	terrain.surface_svt_page_world = 64
	terrain.surface_svt_max_mip = 1
	DirAccess.make_dir_recursive_absolute("user://editor-vt")
	terrain.data_directory = "user://editor-vt"
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.id = id
		asset.albedo_texture = _solid_texture(32, Color("e34b4b") if id == 0 else Color("4bd36a"))
		asset.normal_texture = _solid_texture(32, Color(0.5, 0.5, 1.0, 1.0))
		terrain.assets.set_texture_asset(id, asset)
	var mesh_asset := Terrain3DMeshAsset.new()
	terrain.assets.set_mesh_asset(0, mesh_asset)
	scene_root.add_child(terrain)
	terrain.owner = scene_root
	var camera := Camera3D.new()
	camera.name = "TerrainVTTestCamera"
	camera.position = Vector3(64.0, 160.0, 32.0)
	camera.rotation_degrees.x = -90.0
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 160.0
	camera.current = true
	scene_root.add_child(camera)
	EditorInterface.add_root_node(scene_root)
	await _wait_frames(40)
	terrain.set_camera(camera)
	# Apply the compact bake geometry after Terrain3DData has adopted its
	# defaults. This keeps the fixture to two mip-0 tiles and one parent tile.
	terrain.region_size = 64
	terrain.surface_svt_page_world = 64

	terrain.data.add_region_blank(Vector2i.ZERO)
	# Selection drives the real feng-idweight-terrain EditorPlugin _edit path,
	# which assigns the plugin terrain and updates its actual asset dock.
	EditorInterface.get_selection().add_node(terrain)
	await _wait_frames(40)
	var menu := await _wait_for_management_menu()
	if not _require(menu != null, "production asset dock ManagementMenu was not created"):
		return
	var dock := _dock_from_menu(menu)
	if not _require(dock != null, "could not find production Terrain3D asset dock"):
		return
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain,
			"selecting Terrain3D did not reach the production editor plugin"):
		return
	# The production Inspector owns the VT Page foldout under Surface VT. The
	# custom control must be inside the native EditorInspectorSection so its
	# visibility follows the real subgroup, rather than living in the asset dock.
	await _wait_frames(4)
	var subgroup_names: Array[String] = []
	for property in terrain.get_property_list():
		if int(property.usage) & PROPERTY_USAGE_SUBGROUP:
			subgroup_names.append(str(property.name))
	# The native subgroups read in the order the layer assembles: the settings that decide what
	# exists (with the delivery matrix as the first thing inside them), the ring's own shape, then one
	# subgroup per method, then the pages those methods fill. The empty entry is the subgroup that
	# closes the settings group for `surface_array_enabled`. A method's subgroup sitting *above* the
	# settings that select it was the order this pins.
	var expected_subgroups := ["VT Setting", "Clipmap", "", "AVT", "SVT", "CDLOD", "VT Page"]
	if not _require(subgroup_names.size() >= expected_subgroups.size() and
			subgroup_names.slice(0, expected_subgroups.size()) == expected_subgroups,
			"native Surface VT subgroups are not in assembly order: %s" % str(subgroup_names)):
		return
	if not _require(subgroup_names.has("CDLOD"), "native CDLOD foldout is missing"): return
	var inspector := EditorInterface.get_inspector()
	if not _require(inspector.find_child("TerrainCDLODDescription", true, false) == null, "CDLOD should not inject a description above the switch"): return
	var inspector_page_section := inspector.find_child("TerrainVTPageSection", true, false) as Control
	if not _require(inspector_page_section != null,
			"Terrain3D Inspector did not create the Surface VT VT Page content"):
		return
	if not _require(bool(inspector_page_section.get_meta("native_vt_page", false)),
			"Inspector VT Page content did not come from the native Surface VT/VT Page subgroup"):
		return
	var inspector_open_button := inspector_page_section.find_child("TerrainVTPageOpenOverview", true, false) as Button
	if not _require(inspector_open_button != null,
			"Inspector VT Page section did not expose its overview action"):
		return
	var native_page_section := _find_ancestor_class(inspector_page_section, "EditorInspectorSection")
	if not _require(native_page_section != null,
			"Inspector VT Page content is not attached to the native VT Page subgroup"):
		return
	var inspector_svt_controls := inspector.find_child("TerrainSVTBakeControls", true, false) as Control
	var inspector_svt_bake_button := inspector.find_child("TerrainSVTBakeAllButton", true, false) as Button
	var inspector_svt_progress := inspector.find_child("TerrainSVTBakeProgress", true, false) as Label
	if not _require(inspector_svt_controls != null and
			bool(inspector_svt_controls.get_meta("native_svt_group", false)) and
			inspector_svt_bake_button != null and inspector_svt_progress != null,
			"native Surface VT/SVT subgroup did not add the Bake All button and progress"):
		return
	var native_svt_section := _find_ancestor_class(inspector_svt_controls, "EditorInspectorSection")
	if not _require(native_svt_section != null,
			"inspector Bake All controls are not nested under a native inspector foldout"):
		return
	var svt_inspector_sections: Array[Control] = []
	var section_node: Node = inspector_svt_controls.get_parent()
	while section_node:
		if section_node.get_class() == "EditorInspectorSection":
			svt_inspector_sections.push_front(section_node as Control)
		section_node = section_node.get_parent()
	for inspector_section: Control in svt_inspector_sections:
		inspector_section.call("unfold")
	await _wait_frames(2)
	if not _require(inspector_svt_bake_button.is_visible_in_tree(),
			"native SVT foldout did not expose Bake All SVT Cells"):
		return
	native_svt_section.call("fold")
	await _wait_frames(2)
	if not _require(not inspector_svt_bake_button.is_visible_in_tree(),
			"SVT Bake All control did not follow its native foldout visibility"):
		return
	native_svt_section.call("unfold")
	await _wait_frames(2)
	# Surface VT is itself a foldable group, so open every native section on the
	# path before checking the VT Page child. This exercises the actual nested
	# inspector hierarchy instead of relying on a detached custom control.
	var inspector_sections: Array[Control] = []
	section_node = inspector_page_section.get_parent()
	while section_node:
		if section_node.get_class() == "EditorInspectorSection":
			inspector_sections.push_front(section_node as Control)
		section_node = section_node.get_parent()
	for inspector_section: Control in inspector_sections:
		inspector_section.call("unfold")
	await _wait_frames(2)
	await _wait_frames(2)
	if not _require(inspector_open_button.is_visible_in_tree(),
			"native VT Page subgroup did not expose its folded content when unfolded"):
		return
	native_page_section.call("fold")
	await _wait_frames(2)
	if not _require(not inspector_open_button.is_visible_in_tree(),
			"native VT Page subgroup fold did not hide the custom content"):
		return
	native_page_section.call("unfold")
	await _wait_frames(2)
	# The VT Page section hosts one debug view per VT method that has a layout to draw, and each is
	# gated on the delivery matrix: showing a view of a service nobody selected is the state the two
	# gates exist to prevent. This scene's default matrix selects AVT for the near material band and
	# Clipmap nowhere, so exactly one of the two blocks is on screen.
	var avt_debug_block := inspector_page_section.find_child("TerrainAVTDebugBlock", true, false) as Control
	var clipmap_debug_block := inspector_page_section.find_child("TerrainClipmapDebugBlock", true, false) as Control
	var clipmap_view := inspector_page_section.find_child("TerrainClipmapPreview", true, false) as Control
	if not _require(avt_debug_block != null and clipmap_debug_block != null and clipmap_view != null,
			"Inspector VT Page did not create a debug view per VT method"):
		return
	if not _require(avt_debug_block.visible and not clipmap_debug_block.visible,
			"a debug view must follow the delivery matrix: AVT is selected here and Clipmap is not"):
		return
	# The clipmap's view follows the ring *object* rather than a matrix cell: this scene has never put a
	# cell on `Clipmap`, so no ring exists, the block stays hidden and nothing is scanned. The two
	# counters are what make "nothing was scanned" a reading instead of a claim. (Selecting the method
	# is what builds a ring - both channels can now name it - and the reading that an arm renders from
	# one is `vt_clipmap_render`'s and `vt_delivery`'s.)
	var calls_before := int(terrain.get_vt_settings().get("clipmap_preview_calls", 0))
	var computed_before := int(terrain.get_vt_settings().get("clipmap_preview_computed", 0))
	clipmap_view.set("_last_poll_sec", -INF)
	clipmap_view.call("_process", 0.0)
	if not _require(not bool(clipmap_view.call("is_available")) and not clipmap_debug_block.visible,
			"so its debug view stays hidden: there is no ring behind it"):
		return
	var gate_settings := terrain.get_vt_settings()
	if not _require(int(gate_settings.get("clipmap_preview_computed", 0)) == computed_before and
			int(gate_settings.get("clipmap_preview_calls", 0)) == calls_before,
			"and a hidden view with no ring behind it must not ask for a layout at all"):
		return
	inspector_open_button.pressed.emit()
	await _wait_frames(4)
	var inspector_vt_editor: Window = dock.vt_editor
	if not _require(inspector_vt_editor != null and inspector_vt_editor.visible,
			"Inspector VT Page overview action did not open Surface VT Editor"):
		return
	if not _require(inspector_vt_editor.hierarchy.get_selected() != null and
			inspector_vt_editor.hierarchy.get_selected().get_metadata(0) == "pages",
			"Inspector VT Page overview action did not select the VT Page view"):
		return
	inspector_vt_editor.hide()

	var progress_dialog_closed := await _wait_for_editor_progress_dialog()
	if not _require(progress_dialog_closed,
			"editor ProgressDialog did not close before dock pointer regression"):
		return
	await _click(dock.meshes_btn)
	if not _require(dock.current_list == dock.mesh_list, "routed click on Meshes failed"):
		return
	await _click(dock.current_list.entries[0].button_enabled)
	if not _require(not mesh_asset.is_enabled(), "routed mesh visibility click did not disable asset"):
		return
	await _click(dock.textures_btn)
	if not _require(dock.current_list == dock.texture_list, "routed click on Textures failed"):
		return
	var asset: Terrain3DTextureAsset = terrain.assets.get_texture_asset(0)
	await _click(dock.current_list.entries[0].button_highlight)
	if not _require(asset.is_highlighted(), "routed Highlight click did not toggle asset"):
		return
	await _click(dock.current_list.entries[1].button_edit)
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain.assets.get_texture_asset(1), "routed Edit click did not inspect asset"):
		return
	await _click(dock.current_list.entries[1].button_clear)
	if not _require(dock.confirm_dialog.visible, "routed Clear click did not open confirmation"):
		return
	# The native confirmation window is off-screen in this fixture. Cancel
	# it explicitly after verifying the routed Clear click opened it.
	dock.confirm_dialog.canceled.emit()
	dock.confirm_dialog.hide()
	await _wait_frames(4)
	if not _require(not dock.confirm_dialog.visible and terrain.assets.get_texture_count() == 2, "cancel did not preserve texture assets"):
		return
	await _click(menu)
	if not _require(menu.get_popup().visible, "routed click on Terrain menu failed"):
		return
	menu.get_popup().hide()
	await _wait_frames(3)
	var wide_measure: Dictionary = await _measure_layout(dock, menu, 900.0)
	var wide_min: Vector2 = wide_measure["combined_min"]
	var wide_menu_size: Vector2 = wide_measure["management_size"]
	var narrow_measure: Dictionary = await _measure_layout(dock, menu, 500.0)
	var narrow_min: Vector2 = narrow_measure["combined_min"]
	var narrow_menu_size: Vector2 = narrow_measure["management_size"]
	if not _require(is_equal_approx(wide_measure["dock_size"].x, 900.0) and
			is_equal_approx(narrow_measure["dock_size"].x, 500.0),
			"editor dock container overwrote requested measurement widths: wide=%s narrow=%s" %
			[wide_measure["dock_size"], narrow_measure["dock_size"]]):
		return
	var editor_scale: float = EditorInterface.get_editor_scale()
	var row_limit: float = 48.0 * maxf(1.0, editor_scale)
	if not _require(wide_menu_size.y > 0.0 and wide_menu_size.y <= row_limit,
			"wide management menu is taller than one editor row: %s" % wide_menu_size):
		return
	if not _require(narrow_menu_size.y > 0.0 and narrow_menu_size.y <= row_limit,
			"narrow management menu is taller than one editor row: %s" % narrow_menu_size):
		return
	if not _require(wide_min.y < 220.0 * maxf(1.0, editor_scale) and
			narrow_min.y < 220.0 * maxf(1.0, editor_scale),
			"asset dock minimum height remains too large: wide=%s narrow=%s" % [wide_min, narrow_min]):
		return

	var management_popup := menu.get_popup()
	management_popup.id_pressed.emit(MENU_TEXTURE_ARRAY)
	await _wait_frames(4)
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain.assets,
			"Texture Array menu action did not inspect terrain.assets"):
		return
	management_popup.id_pressed.emit(MENU_TERRAIN_MAPS)
	await _wait_frames(4)
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain.data,
			"Terrain Maps menu action did not inspect terrain.data"):
		return
	terrain.data.add_region_blank(Vector2i(1, 0))
	management_popup.id_pressed.emit(MENU_VT_EDITOR)
	await _wait_frames(4)
	var vt_editor: Window = dock.vt_editor
	if not _require(vt_editor != null and vt_editor.visible,
			"Surface VT Editor menu action did not open the editor window"):
		return
	var surface_item: TreeItem = vt_editor.hierarchy.get_root().get_first_child()
	if not _require(surface_item != null and surface_item.get_text(0) == "Surface VT",
			"VT editor did not create the Surface VT hierarchy root"):
		return
	var settings_item: TreeItem = surface_item.get_first_child()
	var clipmap_item: TreeItem = settings_item.get_next() if settings_item else null
	var avt_item: TreeItem = clipmap_item.get_next() if clipmap_item else null
	var svt_item: TreeItem = avt_item.get_next() if avt_item else null
	var cdlod_item: TreeItem = svt_item.get_next() if svt_item else null
	var pages_item: TreeItem = cdlod_item.get_next() if cdlod_item else null
	# The tree reads in the order the layer assembles: the settings that select a method, the ring's
	# own shape, then one node per method, then the physical pages. `Clipmap` between the settings and
	# AVT is the node the matrix's third method was missing.
	if not _require(settings_item != null and settings_item.get_text(0) == "VT Setting" and
			clipmap_item != null and clipmap_item.get_text(0) == "Clipmap" and
			avt_item != null and avt_item.get_text(0) == "AVT" and
			svt_item != null and svt_item.get_text(0) == "SVT" and
			cdlod_item != null and cdlod_item.get_text(0) == "CDLOD" and
			pages_item != null and pages_item.get_text(0) == "VT Page",
			"VT editor hierarchy did not expose VT Setting, Clipmap, AVT, SVT, CDLOD and VT Page in assembly order"):
		return
	var clipmap_child: TreeItem = clipmap_item.get_first_child()
	if not _require(clipmap_child != null and clipmap_child.get_metadata(0) == "clipmap",
			"Clipmap hierarchy group did not expose the ring's own settings"):
		return
	var avt_pages: TreeItem = avt_item.get_first_child()
	var svt_pages: TreeItem = svt_item.get_first_child()
	if not _require(avt_pages != null and avt_pages.get_text(0) == "VT Page" and
			svt_pages != null and svt_pages.get_text(0) == "VT Page" and
			avt_pages.get_metadata(0) == "avt_pages" and
			svt_pages.get_metadata(0) == "svt_pages",
			"VT editor hierarchy did not expose collapsible AVT/SVT VT Page groups"):
		return
	var surface_was_collapsed: bool = surface_item.collapsed
	surface_item.collapsed = true
	if not _require(surface_item.collapsed and not surface_was_collapsed,
			"Surface VT hierarchy root did not collapse"):
		return
	surface_item.collapsed = false
	var pages_was_collapsed: bool = pages_item.collapsed
	pages_item.collapsed = true
	if not _require(pages_item.collapsed and not pages_was_collapsed,
			"VT Page hierarchy group did not collapse"):
		return
	pages_item.collapsed = false
	cdlod_item.select(0)
	vt_editor.hierarchy.item_selected.emit()
	await _wait_frames(2)
	var cdlod_toggle := vt_editor.find_child("CDLODEnabled", true, false) as CheckButton
	if not _require(cdlod_toggle != null, "CDLOD settings panel was not created"): return
	cdlod_toggle.set_pressed_no_signal(true)
	cdlod_toggle.toggled.emit(true)
	if not _require(terrain.cdlod_enabled, "CDLOD toggle did not update native setting"): return
	cdlod_toggle.set_pressed_no_signal(false)
	cdlod_toggle.toggled.emit(false)
	settings_item.select(0)
	await _wait_frames(2)
	if not _require(vt_editor.settings_panel.visible and vt_editor.page_size_spin != null and
			vt_editor.page_border_spin != null and vt_editor.page_count_spin != null and
			vt_editor.pages_per_update_spin != null and vt_editor.adaptive_button != null,
			"VT Setting group did not expose unified page controls"):
		return
	# The ring's shape and its budget are their own node, and a write there has to land on the native
	# property rather than on a widget the report will overwrite on the next refresh.
	clipmap_item.select(0)
	vt_editor.hierarchy.item_selected.emit()
	await _wait_frames(2)
	if not _require(vt_editor.clipmap_panel.visible and vt_editor.clipmap_size_spin != null and
			vt_editor.clipmap_levels_spin != null and vt_editor.clipmap_base_spin != null and
			vt_editor.clipmap_budget_spin != null and vt_editor.clipmap_hint != null,
			"Clipmap hierarchy group did not expose the ring's shape and budget"):
		return
	var saved_clipmap_size: int = terrain.vt_clipmap_size
	var saved_clipmap_budget: int = terrain.vt_clipmap_budget_texels
	# Both controls carry the same three states, so both are written and read back. The budget box
	# steps in 1024 (`vt_editor.gd` builds it with `_make_spin(0, 1048576, 1024)`) and `Range` snaps a
	# written value to its step, so the value below is a multiple of it: asking for 512 would land on 0
	# and read as a control that did nothing.
	vt_editor.clipmap_size_spin.value = 32.0
	if not _require(terrain.vt_clipmap_size == 32, "the clipmap level edge control did not update the native setting"):
		return
	vt_editor.clipmap_budget_spin.value = 1024.0
	if not _require(terrain.vt_clipmap_budget_texels == 1024, "the clipmap budget control did not update the native setting"):
		return
	vt_editor.clipmap_size_spin.value = float(saved_clipmap_size)
	vt_editor.clipmap_budget_spin.value = float(saved_clipmap_budget)
	if not _require(terrain.vt_clipmap_size == saved_clipmap_size and terrain.vt_clipmap_budget_texels == saved_clipmap_budget,
			"the clipmap controls did not restore the settings they read"):
		return
	# The VT Page's clipmap view is the same control the Inspector hosts. The gate is asked natively
	# here as well, so a scene whose matrix selects Clipmap nowhere must not even pay for a payload.
	var resident_item: TreeItem = pages_item.get_first_child()
	var baked_item: TreeItem = resident_item.get_next() if resident_item else null
	var clipmap_page: TreeItem = baked_item.get_next() if baked_item else null
	if not _require(clipmap_page != null and clipmap_page.get_text(0) == "Clipmap ring" and
			clipmap_page.get_metadata(0) == "clipmap_debug",
			"VT Page did not expose the clipmap debug view"):
		return
	clipmap_page.select(0)
	vt_editor.hierarchy.item_selected.emit()
	await _wait_frames(2)
	var dock_clipmap_view := vt_editor.find_child("ClipmapDebugPreview", true, false) as Control
	if not _require(vt_editor.clipmap_debug_panel.visible and dock_clipmap_view != null,
			"VT Page's clipmap view was not created"):
		return
	var preview_calls_before := int(terrain.get_vt_settings().get("clipmap_preview_computed", 0))
	if not _require(not terrain.is_vt_delivery_used(2) and terrain.get_clipmap_layout_preview().is_empty() and
			int(terrain.get_vt_settings().get("clipmap_preview_computed", 0)) == preview_calls_before,
			"the clipmap preview must refuse a method that no delivery cell selects"):
		return
	if not _require(not bool(dock_clipmap_view.call("is_available")),
			"and the VT Page's clipmap view must report itself unavailable in that state"):
		return
	if not _require(vt_editor.baked_mip_selector != null,
			"VT Page view did not expose a baked mip selector"):
		return
	var avt_density: SpinBox = vt_editor.avt_density_spin
	var svt_density: SpinBox = vt_editor.svt_density_spin
	if not _require(avt_density != null and svt_density != null, "independent VT density controls missing"):
		return
	var saved_avt: float = terrain.surface_vt_texels_per_meter
	var saved_svt: float = terrain.surface_svt_texels_per_meter
	for density in [128.0, 256.0, 512.0, 1024.0]:
		avt_density.value = density
		if not _require(is_equal_approx(terrain.surface_vt_texels_per_meter, density) and
				is_equal_approx(terrain.surface_svt_texels_per_meter, saved_svt),
				"AVT density control must update AVT independently"):
			return
	for density in [0.25, 0.5, 1.0, 2.0]:
		svt_density.value = density
		if not _require(is_equal_approx(terrain.surface_svt_texels_per_meter, density) and
				is_equal_approx(terrain.surface_vt_texels_per_meter, 1024.0),
				"SVT density control must update SVT independently"):
			return
	terrain.surface_vt_texels_per_meter = saved_avt
	terrain.surface_svt_texels_per_meter = saved_svt
	vt_editor._refresh_settings_controls()
	svt_item.select(0)
	await _wait_frames(2)
	if not _require(vt_editor.auto_bake_hint.text.contains("paused during editor live preview"),
			"live preview must explain why automatic baking is paused"):
		return
	terrain.vt_editor_preview = false
	vt_editor._refresh_settings_controls()
	if not _require(vt_editor.svt_panel.visible and vt_editor.svt_auto_bake_button != null and
			vt_editor.auto_bake_hint != null and vt_editor.bake_button != null and
			vt_editor.bake_status != null,
			"SVT section did not expose Auto Bake, full-bake, and progress controls"):
		return
	if not _require(not vt_editor.svt_auto_bake_button.button_pressed and
			vt_editor.auto_bake_hint.text.find("500 ms") >= 0 and
			vt_editor.bake_button.text == "Bake All SVT Cells",
			"SVT controls did not reflect the disabled fixture setting and full-bake guidance"):
		return
	vt_editor.svt_auto_bake_button.set_pressed_no_signal(true)
	vt_editor.svt_auto_bake_button.toggled.emit(true)
	if not _require(bool(terrain.get(&"surface_svt_auto_bake")) and
			vt_editor.auto_bake_hint.text.find("incrementally") >= 0 and
			vt_editor.auto_bake_hint.text.find("500 ms") >= 0,
			"Auto Bake did not update the native setting and 500 ms incremental guidance"):
		return
	vt_editor._refresh_bake_status({
		"auto_bake": true,
		"auto_pending_regions": 2,
		"bake_incremental": true,
		"bake_total": 4,
		"bake_done": 1,
		"bake_pending": 3,
	})
	if not _require(vt_editor.bake_status.text.find("Automatic incremental SVT bake") >= 0 and
			vt_editor.bake_status.text.find("1/4") >= 0 and
			vt_editor.bake_status.text.find("2 changed regions") >= 0,
			"SVT status did not display automatic incremental progress"):
		return
	vt_editor.svt_auto_bake_button.set_pressed_no_signal(false)
	vt_editor.svt_auto_bake_button.toggled.emit(false)
	if not _require(not bool(terrain.get(&"surface_svt_auto_bake")) and
			vt_editor.auto_bake_hint.text.find("Auto Bake is off") >= 0,
			"Auto Bake did not disable through the SVT control"):
		return
	vt_editor._refresh_bake_status({
		"auto_bake": false,
		"auto_pending_regions": 2,
		"bake_incremental": false,
		"bake_total": 0,
		"bake_done": 0,
		"bake_pending": 0,
	})
	if not _require(vt_editor.bake_status.text.find("Auto Bake off") >= 0 and
			vt_editor.bake_status.text.find("queued") < 0,
			"disabled Auto Bake must not imply queued regions will be rebaked"):
		return
	vt_editor._refresh_bake_status({
		"auto_bake": false,
		"bake_incremental": false,
		"bake_total": 4,
		"bake_done": 2,
		"bake_pending": 2,
	})
	if not _require(vt_editor.bake_status.text.find("Manual full SVT bake progress") >= 0 and
			vt_editor.bake_status.text.find("2/4") >= 0,
			"SVT status did not display manual full-bake progress"):
		return
	settings_item.select(0)
	await _wait_frames(2)
	vt_editor._refresh_overview()
	await _wait_frames(2)
	if not _require(vt_editor.overview.overview_texture != null,
			"VT editor did not build the cached terrain height overview"):
		return
	var overview_size: Vector2 = vt_editor.overview.overview_texture.get_size()
	if not _require(maxf(overview_size.x, overview_size.y) >= 256.0,
			"VT overview must preserve detail within a region, not one pixel per region"):
		return
	if not _require(is_equal_approx(overview_size.x / overview_size.y, 2.0),
			"stitched overview must preserve a two-region world's aspect ratio"):
		return
	if not _require(vt_editor.overview_label.text.find("overview") >= 0,
			"VT overview must state whether it is a material stitch or height fallback"):
		return
	pages_item.select(0)
	await _wait_frames(2)
	vt_editor._refresh_all()
	if not _require(vt_editor._selected_hierarchy_kind == "pages",
			"VT Page view was not selected before the full bake"):
		return
	# Exercise the offline SVT producer: two 64 m regions each persist a cell
	# source with its mip chain, which the overview then stitches.
	vt_editor.bake_button.pressed.emit()
	var queued_bake := int(terrain.get_vt_settings().get("bake_total", 0))
	if not _require(queued_bake == 2, "SVT bake should queue one source per terrain cell"):
		return
	if not _require(vt_editor.bake_status.text.find("Manual full SVT bake queued") >= 0,
			"Bake All SVT Cells did not report that the manual full bake was queued"):
		return
	for _frame in 360:
		await get_tree().process_frame
		if int(terrain.get_vt_settings().get("bake_pending", 1)) == 0:
			break
	var completed_generation := int(terrain.get_vt_settings().get("bake_generation", 0))
	for _frame in 120:
		if vt_editor._last_bake_refresh_generation == completed_generation:
			break
		await get_tree().process_frame
	var baked_pages: Array = terrain.get_svt_baked_pages()
	print("EDITOR_SVT_BAKE queued=", queued_bake, " settings=", terrain.get_vt_settings(), " records=", baked_pages.size())
	if not _require(baked_pages.size() >= 2,
			"SVT bake should expose at least two persisted material page records"):
		return
	var baked_previews := 0
	for baked_page: Dictionary in baked_pages:
		if baked_page.get("preview", null) is Image and not baked_page.preview.is_empty():
			baked_previews += 1
	if not _require(baked_previews >= 2, "SVT records should contain material preview images"):
		return
	if not _require(completed_generation > 0 and
			vt_editor._last_bake_refresh_generation == completed_generation and
			vt_editor._selected_hierarchy_kind == "pages" and
			vt_editor.overview_label.text.to_lower().contains("baked cell") and
			vt_editor.overview.overview_texture != null,
			"completed bake should refresh the VT Page list and stitched material overview once"):
		return
	var baked_overview_size: Vector2 = vt_editor.overview.overview_texture.get_size()
	if not _require(maxf(baked_overview_size.x, baked_overview_size.y) >= 256.0,
			"baked VT overview must retain detail within a region"):
		return
	vt_editor.get_texture().get_image().save_png("user://vt_editor_baked.png")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	var image_rect: Rect2 = vt_editor.overview._image_rect(Rect2(Vector2.ZERO, vt_editor.overview.size))
	click.position = image_rect.position + image_rect.size * Vector2(0.25, 0.5)
	if not _require(vt_editor.overview._location_at(click.position) == Vector2i.ZERO,
			"VT overview hit testing must map the center to its terrain region"):
		return
	vt_editor.overview._gui_input(click)
	await _wait_frames(4)
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain.data.get_region(Vector2i.ZERO),
			"clicking the VT overview did not inspect the corresponding terrain region"):
		return
	click.position = image_rect.position + image_rect.size * Vector2(0.75, 0.5)
	vt_editor.overview._gui_input(click)
	await _wait_frames(4)
	if not _require(EditorInterface.get_inspector().get_edited_object() == terrain.data.get_region(Vector2i(1, 0)),
			"clicking the second stitched region must inspect its own data"):
		return
	vt_editor.get_texture().get_image().save_png("user://vt_editor.png")
	EditorInterface.inspect_object(terrain)
	await _wait_frames(6)
	var inspector_svt_button_after_bake := EditorInterface.get_inspector().find_child("TerrainSVTBakeAllButton", true, false) as Button
	var inspector_svt_status_after_bake := EditorInterface.get_inspector().find_child("TerrainSVTBakeProgress", true, false) as Label
	if not _require(inspector_svt_button_after_bake != null and inspector_svt_status_after_bake != null,
			"SVT inspector Bake All controls disappeared after selecting Terrain3D again"):
		return
	var inspector_generation_before := int(terrain.get_vt_settings().get("bake_generation", 0))
	inspector_svt_button_after_bake.pressed.emit()
	var inspector_bake_settings: Dictionary = terrain.get_vt_settings()
	if not _require(int(inspector_bake_settings.get("bake_generation", 0)) > inspector_generation_before and
			int(inspector_bake_settings.get("bake_total", 0)) >= 2 and
			inspector_svt_status_after_bake.text.find("Manual full SVT bake queued") >= 0,
			"Inspector Bake All button did not call Terrain3D.bake_svt()"):
		return
	for _frame in 900:
		await get_tree().process_frame
		if int(terrain.get_vt_settings().get("bake_pending", 1)) == 0:
			break
	for _frame in 120:
		if inspector_svt_status_after_bake.text.find("Manual full SVT bake complete") >= 0:
			break
		await get_tree().process_frame
	var inspector_bake_finished: Dictionary = terrain.get_vt_settings()
	if not _require(int(inspector_bake_finished.get("bake_pending", 1)) == 0 and
			inspector_svt_status_after_bake.text.find("Manual full SVT bake complete") >= 0,
			"Inspector SVT progress did not report the completed full bake"):
		return
	# Exercise the stale-object guard before closing the window. A closed or
	# deselected terrain must not make refresh calls dereference old native data.
	vt_editor.set_terrain(null)
	vt_editor._refresh_overview()
	vt_editor.hide()

	var debug_menu := management_popup.find_child("DebugViews", true, false) as PopupMenu
	if not _require(debug_menu != null, "Debug Views submenu was not created"):
		return
	for debug_id in [MENU_DEBUG_SHADED, MENU_DEBUG_HEIGHTMAP, MENU_DEBUG_CONTROL_IDS,
			MENU_DEBUG_CONTROL_WEIGHT, MENU_DEBUG_SLOPE]:
		debug_menu.id_pressed.emit(debug_id)
		await _wait_frames(2)
		if not _assert_debug_state(terrain, debug_id):
			return

	# Let pending inspector and shader updates finish before the editor tears
	# down the scene tree; the last menu action schedules deferred UI work.
	EditorInterface.get_selection().clear()
	EditorInterface.inspect_object(null)
	await _wait_frames(8)
	print("PASS graphical Terrain3D asset dock layout and management menu actions")
	_finished = true
	get_tree().quit(0)


func _click(control: Control) -> void:
	await _wait_frames(4)
	var point := control.get_global_rect().get_center()
	var viewport := control.get_viewport()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	viewport.push_input(motion, true)
	await _wait_frames(1)
	if not _require(viewport.gui_get_hovered_control() == control, "mouse event did not reach %s at %s; hovered=%s" % [control.get_path(), point, viewport.gui_get_hovered_control()]):
		return
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		viewport.push_input(event, true)
		await _wait_frames(1)


func _find_ancestor_class(p_control: Control, p_class: String) -> Control:
	var node: Node = p_control.get_parent()
	while node:
		if node.get_class() == p_class:
			return node as Control
		node = node.get_parent()
	return null


func _solid_texture(p_size: int, p_color: Color) -> Texture2D:
	var image := Image.create(p_size, p_size, false, Image.FORMAT_RGBA8)
	image.fill(p_color)
	return ImageTexture.create_from_image(image)
