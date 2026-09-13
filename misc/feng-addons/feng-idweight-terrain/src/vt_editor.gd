# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Surface VT editor. The editor intentionally keeps all expensive work behind
# explicit buttons: page previews are GPU readbacks only when requested, and the
# world thumbnail is stitched only when Refresh overview is pressed.
@tool
extends Window
class_name TerrainVTEditor

const OVERVIEW_SCRIPT: Script = preload("res://addons/feng-idweight-terrain/src/vt_world_overview.gd")
const OVERVIEW_EDGE: int = 768
const MAX_PAGE_ROWS: int = 512
const INVALID_LOCATION := Vector2i(2147483647, 2147483647)
const SVT_AUTO_BAKE_PROPERTY: StringName = &"surface_svt_auto_bake"
const BAKE_STATUS_POLL_INTERVAL: float = 0.25

var plugin: EditorPlugin
var terrain: Object
var _data: Object

var hierarchy: Tree
var page_tree: Tree
var overview: TerrainVTWorldOverview
var summary_label: Label
var overview_label: Label
var details_label: Label
var preview_label: Label
var preview_texture: TextureRect
var refresh_preview_button: Button
var refresh_pages_button: Button
var refresh_overview_button: Button
var inspect_button: Button
var mip_label: Label
var baked_mip_selector: OptionButton

var settings_panel: VBoxContainer
var cdlod_panel: VBoxContainer
var svt_panel: VBoxContainer
var page_size_spin: SpinBox
var page_border_spin: SpinBox
var page_count_spin: SpinBox
var auto_capacity_button: CheckButton
var pages_per_update_spin: SpinBox
var avt_distance_spin: SpinBox
var editor_preview_button: CheckButton
var adaptive_button: CheckButton
var avt_density_spin: SpinBox
var svt_density_spin: SpinBox
var avt_band_grid: GridContainer
var avt_band_spins: Array[SpinBox] = []
var avt_density_hint: Label
var avt_mode_option: OptionButton
var avt_enabled_button: CheckButton
var svt_enabled_button: CheckButton
var svt_auto_bake_button: CheckButton
var auto_bake_hint: Label
var bake_button: Button
var bake_status: Label
var svt_band_hint: Label
var svt_band_grid: GridContainer
var svt_band_auto_button: Button
var svt_band_spins: Array[SpinBox] = []
var _svt_band_signature: String = ""

var _overview_texture: Texture2D
var _overview_dirty: bool = true
var _selected_slot: int = -1
var _selected_location: Vector2i = INVALID_LOCATION
var _selected_kind: String = ""
var _selected_hierarchy_kind: String = "surface"
var _selected_baked_mip: int = 0
var _updating_settings: bool = false
var _updating_mip: bool = false
var _bake_status_elapsed: float = 0.0
var _last_bake_refresh_generation: int = -1
var _built: bool = false


func _init() -> void:
	title = "Surface VT Editor"
	size = Vector2i(1024, 760)
	min_size = Vector2i(760, 560)
	set_process(true)
	close_requested.connect(_on_close_requested)


func _process(p_delta: float) -> void:
	if not visible or terrain == null or not is_instance_valid(terrain):
		return
	_bake_status_elapsed += p_delta
	if _bake_status_elapsed < BAKE_STATUS_POLL_INTERVAL:
		return
	_bake_status_elapsed = 0.0
	var settings := _vt_settings()
	_refresh_bake_status(settings)
	_sync_cdlod_panel()
	var generation := int(settings.get("bake_generation", 0))
	if generation > 0 and int(settings.get("bake_pending", 0)) == 0 and generation != _last_bake_refresh_generation:
		_last_bake_refresh_generation = generation
		_overview_dirty = true
		_refresh_all()


func initialize(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	if not _built:
		_build_ui()


func open_for_terrain(p_terrain: Object) -> void:
	if not _built:
		_build_ui()
	set_terrain(p_terrain)
	popup_centered()
	_refresh_all()


## Entry point used by the Terrain3D Inspector's VT Page foldout. Selecting
## the hierarchy row keeps the window useful even when no baked pages exist;
## the overview then shows the explicit height fallback or stitched SVT data.
func open_vt_page_view() -> void:
	if not _built:
		_build_ui()
	var root := hierarchy.get_root()
	var item := _find_hierarchy_item(root, "pages") if root else null
	if item != null:
		item.select(0)
	_selected_hierarchy_kind = "pages"
	_overview_dirty = true
	_refresh_all()


func _find_hierarchy_item(p_parent: TreeItem, p_metadata: String) -> TreeItem:
	if p_parent == null:
		return null
	var child := p_parent.get_first_child()
	while child:
		if str(child.get_metadata(0)) == p_metadata:
			return child
		var nested := _find_hierarchy_item(child, p_metadata)
		if nested != null:
			return nested
		child = child.get_next()
	return null


func set_terrain(p_terrain: Object) -> void:
	if p_terrain != null and not is_instance_valid(p_terrain):
		p_terrain = null
	terrain = p_terrain
	_data = _get_data(terrain)
	_selected_slot = -1
	_selected_location = INVALID_LOCATION
	_selected_kind = ""
	_overview_dirty = true
	_last_bake_refresh_generation = -1
	if not _built:
		return
	_clear_preview()
	if hierarchy:
		hierarchy.deselect_all()
		var root := hierarchy.get_root()
		if root:
			var first := root.get_first_child()
			if first:
				first.select(0)
	_refresh_baked_mip_selector()
	_refresh_header()
	_refresh_page_details()
	if overview:
		overview.clear_overview()


func _build_ui() -> void:
	_built = true
	var background := VBoxContainer.new()
	background.name = "SurfaceVTContent"
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.add_theme_constant_override("separation", 6)
	add_child(background)

	var toolbar := HFlowContainer.new()
	toolbar.name = "Toolbar"
	toolbar.custom_minimum_size.y = 58
	toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_theme_constant_override("h_separation", 6)
	toolbar.add_theme_constant_override("v_separation", 4)
	background.add_child(toolbar)
	var heading := Label.new()
	heading.text = "Surface VT"
	heading.tooltip_text = "Shared virtual texture residency and baked material pages"
	heading.custom_minimum_size.x = 118
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toolbar.add_child(heading)
	mip_label = Label.new()
	mip_label.text = "Baked mip"
	mip_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toolbar.add_child(mip_label)
	baked_mip_selector = OptionButton.new()
	baked_mip_selector.name = "BakedMipSelector"
	baked_mip_selector.custom_minimum_size.x = 100
	baked_mip_selector.tooltip_text = "Choose which persisted SVT mip level is listed"
	baked_mip_selector.item_selected.connect(_on_baked_mip_selected)
	toolbar.add_child(baked_mip_selector)
	refresh_pages_button = Button.new()
	refresh_pages_button.text = "Refresh pages"
	refresh_pages_button.pressed.connect(_on_refresh_pages_pressed)
	toolbar.add_child(refresh_pages_button)
	refresh_preview_button = Button.new()
	refresh_preview_button.text = "Refresh preview"
	refresh_preview_button.tooltip_text = "Explicitly read the selected physical page from the GPU"
	refresh_preview_button.disabled = true
	refresh_preview_button.pressed.connect(_refresh_page_preview)
	toolbar.add_child(refresh_preview_button)
	refresh_overview_button = Button.new()
	refresh_overview_button.text = "Refresh overview"
	refresh_overview_button.pressed.connect(_refresh_overview)
	toolbar.add_child(refresh_overview_button)
	inspect_button = Button.new()
	inspect_button.text = "Inspect Terrain3D"
	inspect_button.pressed.connect(_inspect_terrain)
	toolbar.add_child(inspect_button)

	summary_label = Label.new()
	summary_label.name = "Summary"
	summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary_label.custom_minimum_size.y = 34
	var summary_toggle := Button.new()
	summary_toggle.text = "统计信息"
	summary_toggle.toggle_mode = true
	summary_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	summary_toggle.toggled.connect(func(expanded: bool): summary_label.visible = expanded)
	background.add_child(summary_toggle)
	summary_label.visible = false
	background.add_child(summary_label)

	var split := VSplitContainer.new()
	split.name = "EditorSplit"
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	background.add_child(split)
	var upper := HSplitContainer.new()
	upper.name = "HierarchyAndDetails"
	upper.size_flags_vertical = Control.SIZE_EXPAND_FILL
	upper.custom_minimum_size.y = 240
	split.add_child(upper)
	split.split_offset = 0
	split.dragger_visibility = SplitContainer.DRAGGER_VISIBLE

	var hierarchy_panel := PanelContainer.new()
	hierarchy_panel.custom_minimum_size.x = 250
	upper.add_child(hierarchy_panel)
	hierarchy = Tree.new()
	hierarchy.name = "Hierarchy"
	hierarchy.columns = 1
	hierarchy.hide_root = true
	hierarchy.set_column_expand(0, true)
	hierarchy.set_column_custom_minimum_width(0, 230)
	hierarchy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hierarchy.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hierarchy.tooltip_text = "Surface VT settings, producers, and physical page views"
	hierarchy.item_selected.connect(_on_hierarchy_item_selected)
	hierarchy_panel.add_child(hierarchy)
	_build_hierarchy()

	var details_panel := PanelContainer.new()
	details_panel.name = "DetailsPanel"
	details_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upper.add_child(details_panel)
	var details_scroll := ScrollContainer.new()
	details_scroll.name = "DetailsScroll"
	details_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	details_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details_scroll.size_flags_vertical = Control.SIZE_FILL
	details_scroll.custom_minimum_size.y = 72
	var page_layout := VBoxContainer.new()
	page_layout.name = "PageLayout"
	details_panel.add_child(page_layout)
	page_layout.add_child(details_scroll)
	var details_box := VBoxContainer.new()
	details_box.name = "DetailsBox"
	details_box.add_theme_constant_override("separation", 4)
	details_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	details_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details_scroll.add_child(details_box)
	details_label = Label.new()
	details_label.name = "DetailsLabel"
	details_label.text = "Select a Surface VT section"
	details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details_box.add_child(details_label)
	settings_panel = _build_settings_panel()
	details_box.add_child(settings_panel)
	svt_panel = _build_svt_panel()
	details_box.add_child(svt_panel)
	cdlod_panel = VBoxContainer.new()
	cdlod_panel.name = "CDLODSettings"
	details_box.add_child(cdlod_panel)
	page_tree = Tree.new()
	page_tree.name = "PageDetails"
	page_tree.columns = 4
	page_tree.hide_root = true
	page_tree.set_column_title(0, "Page")
	page_tree.set_column_title(1, "State")
	page_tree.set_column_title(2, "Address")
	page_tree.set_column_title(3, "Details")
	page_tree.column_titles_visible = true
	page_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page_tree.custom_minimum_size = Vector2(0, 120)
	for column in range(4):
		page_tree.set_column_custom_minimum_width(column, [180, 100, 160, 420][column])
		page_tree.set_column_expand(column, column == 3)
	page_tree.item_selected.connect(_on_page_item_selected)
	page_layout.add_child(page_tree)

	var preview_box := VBoxContainer.new()
	preview_box.name = "PagePreview"
	preview_box.visible = false
	preview_box.size_flags_vertical = Control.SIZE_SHRINK_END
	var preview_toggle := Button.new()
	preview_toggle.text = "单页预览"
	preview_toggle.toggle_mode = true
	preview_toggle.toggled.connect(func(expanded: bool): preview_box.visible = expanded)
	page_layout.add_child(preview_toggle)
	page_layout.add_child(preview_box)
	preview_label = Label.new()
	preview_label.text = "No physical page selected"
	preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_box.add_child(preview_label)
	preview_texture = TextureRect.new()
	preview_texture.name = "PagePreviewTexture"
	preview_texture.custom_minimum_size = Vector2(256, 256)
	preview_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_texture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_texture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview_box.add_child(preview_texture)

	var overview_panel := PanelContainer.new()
	overview_panel.name = "WorldOverviewPanel"
	overview_panel.custom_minimum_size.y = 220
	split.add_child(overview_panel)
	var overview_box := VBoxContainer.new()
	overview_panel.add_child(overview_box)
	overview_label = Label.new()
	overview_label.text = "Terrain height overview (material VT bake unavailable)"
	overview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var overview_toolbar := HBoxContainer.new()
	overview_box.add_child(overview_toolbar)
	overview_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overview_toolbar.add_child(overview_label)
	var overview_mode := OptionButton.new()
	overview_mode.name = "OverviewMode"
	overview_mode.add_item("全部平铺")
	overview_mode.add_item("适应")
	overview_toolbar.add_child(overview_mode)
	overview = OVERVIEW_SCRIPT.new()
	overview.name = "WorldOverview"
	overview.custom_minimum_size.y = 180
	overview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	overview.region_clicked.connect(_on_overview_region_clicked)
	var overview_scroll := ScrollContainer.new()
	overview_scroll.name = "OverviewScroll"
	overview_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	overview_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	overview_box.add_child(overview_scroll)
	overview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overview_scroll.add_child(overview)
	overview_mode.item_selected.connect(func(index: int):
		overview.set_fit_mode(index == 1)
		overview_scroll.scroll_vertical = 0
	)

	_refresh_baked_mip_selector()
	_refresh_page_details()


func _build_hierarchy() -> void:
	hierarchy.clear()
	# Keep an invisible Tree root so the visible hierarchy has one explicit
	# Surface VT node. This also makes get_root().get_first_child() stable for
	# editor integrations that inspect the dock tree.
	var tree_root := hierarchy.create_item()
	var surface := hierarchy.create_item(tree_root)
	surface.set_text(0, "Surface VT")
	surface.set_metadata(0, "surface")
	surface.set_tooltip_text(0, "Shared physical atlas with separate AVT and SVT addressing")
	surface.collapsed = false

	var settings := hierarchy.create_item(surface)
	settings.set_text(0, "VT Setting")
	settings.set_metadata(0, "settings")
	settings.set_tooltip_text(0, "Shared page size, border, page budget, and producer settings")
	settings.collapsed = false
	var settings_child := hierarchy.create_item(settings)
	settings_child.set_text(0, "Atlas config")
	settings_child.set_metadata(0, "settings")

	var avt := hierarchy.create_item(surface)
	avt.set_text(0, "AVT")
	avt.set_metadata(0, "avt")
	avt.set_tooltip_text(0, "AVT runtime material view")
	avt.collapsed = false
	var avt_pages := hierarchy.create_item(avt)
	avt_pages.set_text(0, "VT Page")
	avt_pages.set_metadata(0, "avt_pages")

	var svt := hierarchy.create_item(surface)
	svt.set_text(0, "SVT")
	svt.set_metadata(0, "svt")
	svt.set_tooltip_text(0, "SVT persisted material view")
	svt.collapsed = false
	var svt_pages := hierarchy.create_item(svt)
	svt_pages.set_text(0, "VT Page")
	svt_pages.set_metadata(0, "svt_pages")
	var baked := hierarchy.create_item(svt)
	baked.set_text(0, "Baked cell sources")
	baked.set_metadata(0, "baked_pages")

	var cdlod := hierarchy.create_item(surface)
	cdlod.set_text(0, "CDLOD")
	cdlod.set_metadata(0, "cdlod")
	var mesh_settings := hierarchy.create_item(cdlod)
	mesh_settings.set_text(0, "Geometry batching")
	mesh_settings.set_metadata(0, "cdlod")

	var pages := hierarchy.create_item(surface)
	pages.set_text(0, "VT Page")
	pages.set_metadata(0, "pages")
	pages.set_tooltip_text(0, "All current shared physical residency and persisted SVT tiles")
	pages.collapsed = false
	var resident := hierarchy.create_item(pages)
	resident.set_text(0, "Resident pages")
	resident.set_metadata(0, "all_pages")
	var baked_all := hierarchy.create_item(pages)
	baked_all.set_text(0, "Baked cell sources")
	baked_all.set_metadata(0, "baked_pages")


func _build_settings_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = "VTSettings"
	panel.visible = false
	var grid := GridContainer.new()
	grid.name = "SettingsGrid"
	grid.columns = 2
	panel.add_child(grid)
	grid.add_child(_make_setting_label("Physical page edge (texels)"))
	page_size_spin = _make_spin(16, 1024, 16)
	page_size_spin.name = "PageSize"
	page_size_spin.tooltip_text = "Texture cache page dimensions in texels, not terrain metres. At 1024 texels/metre, a 256-texel page covers 0.25 metres per edge."
	page_size_spin.value_changed.connect(_on_setting_value_changed.bind("page_size"))
	grid.add_child(page_size_spin)
	grid.add_child(_make_setting_label("Border (texels)"))
	page_border_spin = _make_spin(1, 16, 1)
	page_border_spin.name = "PageBorder"
	page_border_spin.value_changed.connect(_on_setting_value_changed.bind("border"))
	grid.add_child(page_border_spin)
	grid.add_child(_make_setting_label("Shared page count"))
	page_count_spin = _make_spin(8, 1024, 1)
	page_count_spin.name = "PageCount"
	page_count_spin.value_changed.connect(_on_setting_value_changed.bind("page_count"))
	grid.add_child(page_count_spin)
	grid.add_child(_make_setting_label("Automatic cache capacity"))
	auto_capacity_button = CheckButton.new()
	auto_capacity_button.name = "AutoCapacity"
	auto_capacity_button.tooltip_text = "Reserve Shared page count for visible demand and camera transitions, up to 1024 pages. Uses more video memory; texel density and the 16-page generation limit stay unchanged."
	auto_capacity_button.toggled.connect(_on_auto_capacity_toggled)
	grid.add_child(auto_capacity_button)
	grid.add_child(_make_setting_label("Pages per update"))
	pages_per_update_spin = _make_spin(1, 16, 1)
	pages_per_update_spin.name = "PagesPerUpdate"
	pages_per_update_spin.value_changed.connect(_on_setting_value_changed.bind("pages_per_update"))
	grid.add_child(pages_per_update_spin)
	grid.add_child(_make_setting_label("AVT coverage"))
	avt_mode_option = OptionButton.new()
	avt_mode_option.name = "AVTCoverage"
	avt_mode_option.add_item("Camera range / 64 m sectors", 2)
	avt_mode_option.add_item("Legacy region view", 0)
	avt_mode_option.add_item("Legacy target grid", 1)
	avt_mode_option.item_selected.connect(_on_avt_mode_selected)
	grid.add_child(avt_mode_option)
	grid.add_child(_make_setting_label("AVT texels / metre"))
	avt_density_spin = _make_spin(1, 8192, 1)
	avt_density_spin.name = "AVTTexelsPerMeter"
	avt_density_spin.value_changed.connect(_on_density_changed.bind("vt"))
	grid.add_child(avt_density_spin)
	grid.add_child(_make_setting_label("SVT texels / metre"))
	svt_density_spin = _make_spin(0.01, 8192, 0.01)
	svt_density_spin.name = "SVTTexelsPerMeter"
	svt_density_spin.value_changed.connect(_on_density_changed.bind("svt"))
	grid.add_child(svt_density_spin)
	avt_density_hint = Label.new()
	avt_density_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(avt_density_hint)
	panel.add_child(_make_setting_label("AVT automatic mip density (texels / metre)"))
	avt_band_grid = GridContainer.new()
	avt_band_grid.columns = 2
	panel.add_child(avt_band_grid)
	grid.add_child(_make_setting_label("AVT range (metres)"))
	avt_distance_spin = _make_spin(64, 65536, 64)
	avt_distance_spin.name = "AVTRange"
	avt_distance_spin.tooltip_text = "Camera-centred near field across terrain blocks. The outer 25% blends into SVT; page count stays bounded."
	avt_distance_spin.value_changed.connect(_on_avt_range_changed)
	grid.add_child(avt_distance_spin)
	editor_preview_button = CheckButton.new()
	editor_preview_button.name = "VTEditorPreview"
	editor_preview_button.text = "Editor live material preview"
	editor_preview_button.tooltip_text = "Editor only: show brush edits directly and pause VT streaming and automatic baking. Disable to inspect runtime VT. Explicit Bake remains available."
	editor_preview_button.toggled.connect(_on_editor_preview_toggled)
	panel.add_child(editor_preview_button)
	adaptive_button = CheckButton.new()
	adaptive_button.name = "AdaptiveAVT"
	adaptive_button.text = "Adaptive AVT allocation"
	adaptive_button.tooltip_text = "Allow adaptive blocks to resize while preserving overlapping cached pages"
	adaptive_button.toggled.connect(_on_adaptive_toggled)
	panel.add_child(adaptive_button)
	avt_enabled_button = CheckButton.new()
	avt_enabled_button.name = "AVTRuntimeMaterial"
	avt_enabled_button.text = "AVT runtime material"
	avt_enabled_button.toggled.connect(_on_view_enabled_toggled.bind("avt"))
	panel.add_child(avt_enabled_button)
	svt_enabled_button = CheckButton.new()
	svt_enabled_button.name = "SVTPersistedMaterial"
	svt_enabled_button.text = "SVT persisted material"
	svt_enabled_button.toggled.connect(_on_view_enabled_toggled.bind("svt"))
	panel.add_child(svt_enabled_button)
	return panel


func _build_svt_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = "SVTSettings"
	panel.visible = false
	svt_auto_bake_button = CheckButton.new()
	svt_auto_bake_button.name = "SVTAutoBake"
	svt_auto_bake_button.text = "Auto Bake"
	svt_auto_bake_button.tooltip_text = "Automatically rebake changed SVT cells incrementally after editing has been idle for 500 ms"
	svt_auto_bake_button.toggled.connect(_on_svt_auto_bake_toggled)
	panel.add_child(svt_auto_bake_button)
	auto_bake_hint = Label.new()
	auto_bake_hint.name = "SVTAutoBakeHint"
	auto_bake_hint.text = "Changed regions are merged and rebaked incrementally 500 ms after editing stops."
	auto_bake_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(auto_bake_hint)
	bake_button = Button.new()
	bake_button.name = "BakeSVT"
	bake_button.text = "Bake All SVT Cells"
	bake_button.tooltip_text = "Run a one-click full bake of persisted SVT material tiles across every mip level for loaded terrain regions"
	bake_button.pressed.connect(_on_bake_svt_pressed)
	panel.add_child(bake_button)
	bake_status = Label.new()
	bake_status.name = "BakeStatus"
	bake_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(bake_status)

	# Distance -> mip level bands. One entry per level: the furthest camera distance at
	# which the shader samples that level, and the level the page producer fills for it.
	# Both read this one table, so the rendered detail is a function of distance rather
	# than of whichever page happens to be resident.
	var band_header := Label.new()
	band_header.name = "SVTBandHeader"
	band_header.text = "Mip distance bands"
	panel.add_child(band_header)
	svt_band_hint = Label.new()
	svt_band_hint.name = "SVTBandHint"
	svt_band_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(svt_band_hint)
	svt_band_grid = GridContainer.new()
	svt_band_grid.name = "SVTBandGrid"
	svt_band_grid.columns = 2
	panel.add_child(svt_band_grid)
	var band_buttons := HBoxContainer.new()
	band_buttons.name = "SVTBandButtons"
	svt_band_auto_button = Button.new()
	svt_band_auto_button.name = "SVTBandAutomatic"
	svt_band_auto_button.text = "Automatic"
	svt_band_auto_button.tooltip_text = "Clear the table and derive one level per doubling of the far-field page size"
	svt_band_auto_button.pressed.connect(_on_svt_band_auto_pressed)
	band_buttons.add_child(svt_band_auto_button)
	var band_fit_button := Button.new()
	band_fit_button.name = "SVTBandFromPageSize"
	band_fit_button.text = "From page size"
	band_fit_button.tooltip_text = "Pin the bands explicitly to the automatic rule, as a starting point to edit"
	band_fit_button.pressed.connect(_on_svt_band_fit_pressed)
	band_buttons.add_child(band_fit_button)
	panel.add_child(band_buttons)
	return panel


func _make_setting_label(p_text: String) -> Label:
	var label := Label.new()
	label.text = p_text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _make_spin(p_min: float, p_max: float, p_step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = p_min
	spin.max_value = p_max
	spin.step = p_step
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.custom_minimum_size.x = 130
	return spin


func _refresh_all() -> void:
	if not _built:
		return
	_refresh_header()
	_refresh_baked_mip_selector()
	_refresh_settings_controls()
	_refresh_page_details()
	if _overview_dirty:
		_refresh_overview()


func _refresh_header() -> void:
	if not summary_label:
		return
	if terrain == null or not is_instance_valid(terrain):
		summary_label.text = "No Terrain3D selected"
		return
	var data := _get_data(terrain)
	var regions := int(_call(data, "get_region_count"))
	var locations := _region_locations(data)
	var region_size := int(_call(terrain, "get_region_size"))
	var spacing := float(_call(terrain, "get_vertex_spacing"))
	if spacing <= 0.0:
		spacing = 1.0
	var density := int(_call(terrain, "get_surface_density"))
	if density <= 0:
		density = 1
	var settings := _vt_settings()
	var shared := bool(settings.get("shared_pool", false))
	var adaptive := bool(settings.get("adaptive", false))
	var resident := _resident_pages().size()
	var baked_pages := _baked_pages()
	var baked := baked_pages.size()
	var cached_blocks := {}
	for page: Dictionary in baked_pages:
		if int(page.get("mip", -1)) == 0:
			cached_blocks[_location_for_world_rect(page.get("world_rect", Rect2()))] = true
	var pending := int(settings.get("bake_pending", 0))
	summary_label.text = "Regions: %d (%d listed)  |  Terrain block: %.1f m  |  Paint grid: %.2f texel/m  |  Shared atlas: %s  |  Adaptive AVT: %s  |  Resident physical pages: %d  |  SVT blocks with cache: %d  |  Baked SVT sources: %d  |  Bake pending: %d" % [
		regions, locations.size(), float(region_size) * spacing, float(density) / spacing,
		"ready" if shared else "pending", "on" if adaptive else "off", resident, cached_blocks.size(), baked, pending]
	if int(settings.get("avt_selection_mode", 0)) == 2:
		var sectors: Dictionary = settings.get("avt_sector_stats", {})
		summary_label.text += "\nFull AVT · 64 m sectors: %d visible, %d independent · %d shared coarse pages · max allocated %d texels" % [
			int(sectors.get("visible_sectors", 0)), int(sectors.get("independent_sectors", 0)),
			int(sectors.get("coarse_pages", 0)), int(sectors.get("max_allocated_resolution", 0))]
	if bool(settings.get("editor_preview_active", false)):
		summary_label.text += "\nEditor live preview: VT streaming and automatic baking paused."
	_refresh_bake_status(settings)


func _refresh_settings_controls() -> void:
	if not settings_panel:
		return
	var settings := _vt_settings()
	_updating_settings = true
	var mode := int(settings.get("avt_selection_mode", 2))
	avt_mode_option.select(avt_mode_option.get_item_index(mode))
	page_size_spin.value = float(settings.get("page_size", 256))
	page_border_spin.value = float(settings.get("border", 4))
	page_count_spin.value = float(settings.get("page_count", 256))
	auto_capacity_button.button_pressed = bool(settings.get("auto_capacity", true))
	pages_per_update_spin.value = float(settings.get("pages_per_update", 16))
	avt_density_spin.editable = mode == 2
	avt_density_spin.tooltip_text = "Material texels per metre for sector AVT. Select Camera range / 64 m sectors to use this setting."
	avt_density_spin.value = float(settings.get("avt_texels_per_meter", 1024.0))
	svt_density_spin.value = float(settings.get("svt_texels_per_meter", 1.0))
	avt_density_hint.text = "64 m sector: %.0f x %.0f virtual texels; %d x %d page-table allocation. Physical pages load on demand. Source material detail still limits sharpness." % [64.0 * avt_density_spin.value, 64.0 * avt_density_spin.value, int(settings.get("avt_base_block_size", 256)), int(settings.get("avt_base_block_size", 256))]
	avt_density_hint.text += "\nSVT addressable extent: %.2f x %.2f m, centred on world origin." % [float(settings.get("svt_world_extent", 0.0)), float(settings.get("svt_world_extent", 0.0))]
	_refresh_avt_bands(settings)
	avt_distance_spin.value = float(settings.get("avt_distance", 512.0))
	editor_preview_button.set_pressed_no_signal(bool(settings.get("editor_preview", true)))


	adaptive_button.button_pressed = bool(settings.get("adaptive", false))
	avt_enabled_button.button_pressed = bool(_call(terrain, "is_surface_vt_enabled"))
	svt_enabled_button.button_pressed = bool(_call(terrain, "is_surface_svt_enabled"))
	var auto_bake_enabled := _get_svt_auto_bake()
	svt_auto_bake_button.button_pressed = auto_bake_enabled
	svt_auto_bake_button.disabled = not _has_object_property(terrain, SVT_AUTO_BAKE_PROPERTY)
	svt_auto_bake_button.tooltip_text = "Automatically rebake changed SVT cells incrementally after editing has been idle for 500 ms" if not svt_auto_bake_button.disabled else "Auto Bake is unavailable in this Terrain3D build"
	auto_bake_hint.text = "Changed regions are merged and rebaked incrementally 500 ms after editing stops." if auto_bake_enabled else "Auto Bake is off. When enabled, changed regions merge and rebake incrementally 500 ms after editing stops. Use Bake All SVT Cells to refresh all cell sources and their mip chains."
	if bool(settings.get("editor_preview_active", false)):
		auto_bake_hint.text = "Automatic baking is paused during editor live preview. Close preview to resume, or use Bake All SVT Cells."
	_refresh_svt_bands()
	_updating_settings = false


# One spin box per world mip level: the furthest camera distance still sampled at that
# level. Both the page producer and the shader resolve a level through this table, so a
# value here is where the level boundary sits for the whole far field, not a hint.
func _refresh_svt_bands() -> void:
	if svt_band_grid == null or terrain == null or not is_instance_valid(terrain):
		return
	if not _has_object_property(terrain, &"surface_svt_mip_distances"):
		return
	var view := _call(terrain, "get_surface_svt")
	var max_mip := int(_call(view, "get_world_max_mip"))
	if max_mip < 0:
		max_mip = int(_call(terrain, "get_surface_svt_max_mip"))
	var levels := maxi(1, max_mip + 1)
	var configured_value: Variant = _call(terrain, "get_surface_svt_mip_distances")
	var configured: PackedFloat32Array = configured_value if configured_value is PackedFloat32Array else PackedFloat32Array()
	var page_world := maxf(0.001, float(_call(terrain, "get_surface_svt_page_world")))
	# Rebuilding a grid of spin boxes while the user types in one of them would drop the
	# edit, so only rebuild when the level count or the stored table actually changed.
	var signature := "%d|%s|%s" % [levels, str(configured), str(page_world)]
	if signature == _svt_band_signature:
		return
	_svt_band_signature = signature
	var rebuilding := svt_band_spins.size() != levels
	_updating_settings = true
	if rebuilding:
		for child in svt_band_grid.get_children():
			child.queue_free()
		svt_band_spins.clear()
		for mip in levels:
			svt_band_grid.add_child(_make_setting_label("mip %d ≤" % mip))
			var spin := _make_spin(1.0, 100000000.0, 1.0)
			spin.name = "SVTBandMip%d" % mip
			spin.custom_minimum_size.x = 130
			spin.tooltip_text = "Furthest camera distance in metres sampled at world mip %d" % mip
			spin.value_changed.connect(_on_svt_band_value_changed.bind(mip))
			svt_band_grid.add_child(spin)
			svt_band_spins.append(spin)
	for mip in svt_band_spins.size():
		# An empty table is the automatic rule: show the edge that rule produces, so the
		# boxes always read as real distances.
		var automatic_edge := maxf(1.0, page_world * 2.0) * pow(2.0, float(mip))
		svt_band_spins[mip].set_value_no_signal(float(configured[mip]) if mip < configured.size() else automatic_edge)
	_updating_settings = false
	var parts: PackedStringArray = []
	var previous := 0.0
	for mip in svt_band_spins.size():
		var edge := float(svt_band_spins[mip].value)
		parts.append("%s–%s m → mip %d" % [_format_distance(previous), _format_distance(edge), mip])
		previous = edge
	var mode := "Explicit bands: every level named here is produced at exactly that distance." if not configured.is_empty() else "Automatic bands: one level per doubling of the %.0f m page. Editing a distance pins all bands explicitly." % page_world
	svt_band_hint.text = "%s\n%s" % [mode, " · ".join(parts)]


func _format_distance(p_metres: float) -> String:
	if p_metres >= 1000.0:
		return "%.1f km" % (p_metres / 1000.0)
	return "%.0f" % p_metres


func _on_svt_band_value_changed(_p_value: float, _p_mip: int) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	var distances := PackedFloat32Array()
	for spin in svt_band_spins:
		distances.append(float(spin.value))
	_call(terrain, "set_surface_svt_mip_distances", [distances])
	# The setter normalises the table, so read back what it stored.
	_svt_band_signature = ""
	_refresh_svt_bands()


func _on_svt_band_auto_pressed() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	_call(terrain, "set_surface_svt_mip_distances", [PackedFloat32Array()])
	_svt_band_signature = ""
	_refresh_svt_bands()


func _on_svt_band_fit_pressed() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	var page_world := maxf(0.001, float(_call(terrain, "get_surface_svt_page_world")))
	var distances := PackedFloat32Array()
	for mip in maxi(1, svt_band_spins.size()):
		distances.append(maxf(1.0, page_world * 2.0) * pow(2.0, float(mip)))
	_call(terrain, "set_surface_svt_mip_distances", [distances])
	_svt_band_signature = ""
	_refresh_svt_bands()


func _refresh_bake_status(p_settings: Dictionary = {}) -> void:
	if not bake_status:
		return
	if p_settings.is_empty():
		p_settings = _vt_settings()
	var auto_enabled := bool(p_settings.get("auto_bake", _get_svt_auto_bake()))
	var auto_regions := int(p_settings.get("auto_pending_regions", 0))
	var incremental := bool(p_settings.get("bake_incremental", false))
	if bool(p_settings.get("bake_failed", false)):
		var error_text := str(p_settings.get("bake_error", "unknown error"))
		var failed_label := "Automatic incremental SVT bake failed" if incremental else "Manual full SVT bake failed"
		bake_status.text = "%s: %s" % [failed_label, error_text]
		return
	var total := int(p_settings.get("bake_total", 0))
	var done := int(p_settings.get("bake_done", 0))
	var pending := int(p_settings.get("bake_pending", 0))
	if pending > 0 or total > 0 or done > 0:
		var mode := "Automatic incremental SVT bake" if incremental else "Manual full SVT bake"
		var state := "complete" if total > 0 and done >= total and pending == 0 else "progress"
		var queued_regions := " · %d changed regions queued" % auto_regions if auto_enabled and incremental and auto_regions > 0 else ""
		bake_status.text = "%s %s: %d/%d pages, %d pending%s" % [mode, state, done, total, pending, queued_regions]
	elif auto_enabled and auto_regions > 0:
		bake_status.text = "Auto Bake: %d changed region(s) queued; updates merge after 500 ms without edits." % auto_regions
	elif auto_enabled:
		bake_status.text = "Auto Bake on · changed SVT cells rebake incrementally 500 ms after editing stops."
	else:
		bake_status.text = "Auto Bake off · use Bake All SVT Cells for a full persisted bake."


func _on_auto_capacity_toggled(p_enabled: bool) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	_call(terrain, "set_vt_auto_capacity", [p_enabled])
	_refresh_settings_controls()


func _on_setting_value_changed(p_value: float, p_key: String) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	var method := {
		"page_size": "set_vt_page_size",
		"border": "set_vt_page_border",
		"page_count": "set_vt_page_count",
		"pages_per_update": "set_vt_pages_per_update",
	}.get(p_key, "")
	if method.is_empty():
		return
	_call(terrain, method, [int(round(p_value))])
	_overview_dirty = true
	_refresh_header()
	_refresh_baked_mip_selector()
	_refresh_settings_controls()


func _on_avt_mode_selected(p_index: int) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	_call(terrain, "set_surface_vt_selection_mode", [avt_mode_option.get_item_id(p_index)])
	_overview_dirty = true
	_refresh_header()
	_refresh_settings_controls()


func _on_density_changed(p_value: float, p_view: String) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	_call(terrain, "set_surface_%s_texels_per_meter" % p_view, [p_value])
	_svt_band_signature = ""
	_overview_dirty = true
	_refresh_header()
	_refresh_settings_controls()


func _refresh_avt_bands(settings: Dictionary) -> void:
	var levels := 3
	if avt_band_spins.size() != levels:
		for child in avt_band_grid.get_children():
			avt_band_grid.remove_child(child)
			child.queue_free()
		avt_band_spins.clear()
		for mip in levels:
			avt_band_grid.add_child(_make_setting_label("mip %d texels / metre" % mip))
			var spin := _make_spin(1.0 / pow(2.0, mip), 8192.0 / pow(2.0, mip), 1.0 / pow(2.0, mip))
			spin.name = "AVTBandMip%d" % mip
			spin.tooltip_text = "Automatic screen-footprint mip selection. Standard mip levels halve density; editing any level updates the whole chain."
			spin.value_changed.connect(_on_avt_band_changed.bind(mip))
			avt_band_grid.add_child(spin)
			avt_band_spins.append(spin)
	for mip in levels:
		avt_band_spins[mip].set_value_no_signal(float(settings.get("avt_texels_per_meter", 1024.0)) / pow(2.0, mip))


func _on_avt_band_changed(value: float, mip: int) -> void:
	if _updating_settings:
		return
	_on_density_changed(value * pow(2.0, mip), "vt")


func _on_adaptive_toggled(p_enabled: bool) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	_call(terrain, "set_vt_adaptive_enabled", [p_enabled])
	_refresh_header()


func _on_avt_range_changed(value: float) -> void:
	if _updating_settings: return
	_call(terrain, "set_surface_vt_distance", [value])
	_refresh_header()


func _on_editor_preview_toggled(enabled: bool) -> void:
	if _updating_settings: return
	_call(terrain, "set_vt_editor_preview", [enabled])
	_refresh_header()
	_refresh_settings_controls()


func _on_view_enabled_toggled(p_enabled: bool, p_kind: String) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	var method := "set_surface_vt_enabled" if p_kind == "avt" else "set_surface_svt_enabled"
	_call(terrain, method, [p_enabled])
	_refresh_header()
	_refresh_settings_controls()


func _on_svt_auto_bake_toggled(p_enabled: bool) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	if not _has_object_property(terrain, SVT_AUTO_BAKE_PROPERTY):
		return
	terrain.set(SVT_AUTO_BAKE_PROPERTY, p_enabled)
	if Engine.is_editor_hint() and plugin != null and is_instance_valid(plugin):
		EditorInterface.mark_scene_as_unsaved()
	_refresh_settings_controls()
	_refresh_bake_status(_vt_settings())


func _on_bake_svt_pressed() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	var queued := int(_call(terrain, "bake_svt"))
	_refresh_header()
	_refresh_baked_mip_selector()
	if queued > 0:
		bake_status.text = "Manual full SVT bake queued: %d cells · progress will update here." % queued


func _on_refresh_pages_pressed() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	_refresh_header()
	_refresh_baked_mip_selector()
	_refresh_page_details()


func _on_baked_mip_selected(p_index: int) -> void:
	if _updating_mip or baked_mip_selector == null:
		return
	_selected_baked_mip = baked_mip_selector.get_item_id(p_index)
	_refresh_page_details()
	_overview_dirty = true
	_refresh_overview()


func _refresh_baked_mip_selector() -> void:
	if not baked_mip_selector:
		return
	var pages := _baked_pages()
	var mips: Array[int] = []
	for record in pages:
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var mip := int(record.get("mip", 0))
		if not mips.has(mip):
			mips.append(mip)
	mips.sort()
	if mips.is_empty():
		mips.append(0)
	_updating_mip = true
	baked_mip_selector.clear()
	var selected_index := 0
	for index in mips.size():
		var mip: int = mips[index]
		baked_mip_selector.add_item("mip %d" % mip, mip)
		if mip == _selected_baked_mip:
			selected_index = index
	if not mips.has(_selected_baked_mip):
		_selected_baked_mip = 0 if mips.has(0) else mips[0]
		selected_index = mips.find(_selected_baked_mip)
	baked_mip_selector.select(selected_index)
	baked_mip_selector.disabled = pages.is_empty()
	_updating_mip = false


func _on_hierarchy_item_selected() -> void:
	var item := hierarchy.get_selected()
	if not item:
		return
	var value = item.get_metadata(0)
	_selected_hierarchy_kind = str(value) if value != null else "surface"
	_refresh_page_details()


func _refresh_page_details() -> void:
	if not page_tree:
		return
	page_tree.clear()
	_clear_preview()
	settings_panel.visible = false
	svt_panel.visible = false
	cdlod_panel.visible = false
	var root := page_tree.create_item()
	if terrain == null or not is_instance_valid(terrain):
		details_label.text = "No Terrain3D selected"
		_add_page_row(root, "Surface VT", "Unavailable", "", "Select a valid Terrain3D")
		return
	match _selected_hierarchy_kind:
		"cdlod":
			details_label.text = "CDLOD · terrain geometry"
			_refresh_cdlod_panel()
		"settings":
			details_label.text = "VT Setting · shared Surface VT atlas"
			settings_panel.visible = true
			_refresh_settings_controls()
			_add_settings_summary(root)
		"avt", "avt_pages":
			details_label.text = "AVT · runtime material view"
			_add_avt_details(root)
		"svt", "svt_pages":
			details_label.text = "SVT · persisted material view"
			svt_panel.visible = true
			_refresh_settings_controls()
			_add_svt_details(root)
		"baked_pages":
			details_label.text = "SVT baked cell sources · mip %d" % _selected_baked_mip
			svt_panel.visible = true
			_refresh_settings_controls()
			_add_baked_page_rows(root)
		"pages", "all_pages":
			details_label.text = "VT Page · shared physical residency"
			_add_all_page_details(root)
		_:
			details_label.text = "Surface VT · shared residency"
			_add_surface_details(root)


func _add_settings_summary(p_root: TreeItem) -> void:
	var settings := _vt_settings()
	_add_page_row(p_root, "Shared atlas", "Ready" if bool(settings.get("shared_pool", false)) else "Pending", "", "%d pages · %d + %d border texels" % [int(settings.get("page_count", 0)), int(settings.get("page_size", 0)), int(settings.get("border", 0))])
	_add_page_row(p_root, "Adaptive AVT", "Enabled" if bool(settings.get("adaptive", false)) else "Disabled", "", "Adaptive blocks can resize while retaining overlap")
	_add_page_row(p_root, "Producer", "Active" if settings.has("producer") else "Unavailable", "", "Material pages are produced by the Surface VT baker")


func _add_surface_details(p_root: TreeItem) -> void:
	var settings := _vt_settings()
	_add_page_row(p_root, "Surface VT", "Shared", "", "AVT and SVT keep separate virtual addressing")
	_add_page_row(p_root, "AVT", "Enabled" if bool(_call(terrain, "is_surface_vt_enabled")) else "Disabled", "", "%d resident pages" % _resident_pages("AVT").size())
	_add_page_row(p_root, "SVT", "Enabled" if bool(_call(terrain, "is_surface_svt_enabled")) else "Disabled", "", "%d resident · %d baked" % [_resident_pages("SVT").size(), _baked_pages().size()])
	_add_page_row(p_root, "Shared pool", "Ready" if bool(settings.get("shared_pool", false)) else "Pending", "", "One physical slot budget is shared by both views")


func _add_avt_details(p_root: TreeItem) -> void:
	var stats := _view_stats("AVT")
	_add_page_row(p_root, "AVT runtime material", "Runtime", "", "AVT uses surface ID/weight source data; it is not an offline material bake")
	_add_page_row(p_root, "Resident", str(_resident_pages("AVT").size()), "", _stats_text(stats))
	_add_page_row(p_root, "Adaptive", "Enabled" if bool(_vt_settings().get("adaptive", false)) else "Disabled", "", "Shared page blocks may resize for demand")
	_add_resident_page_rows(p_root, "AVT")
	_add_region_rows(p_root)


func _add_svt_details(p_root: TreeItem) -> void:
	var stats := _view_stats("SVT")
	var page_world := float(_call(terrain, "get_surface_svt_page_world"))
	_add_page_row(p_root, "SVT persisted material", "Runtime", "", "One baked source with a full mip chain per terrain block; GPU copies runtime cache pages")
	_add_page_row(p_root, "Resident", str(_resident_pages("SVT").size()), "", _stats_text(stats))
	var region_world := _region_world_size()
	var density := float(_call(terrain, "get_surface_svt_texels_per_meter"))
	var resolution := Vector2i(ceil(region_world.x * density), ceil(region_world.y * density))
	var page_edge := maxi(1, int(_vt_settings().get("page_size", 256)))
	var page_grid := Vector2i(ceili(float(resolution.x) / page_edge), ceili(float(resolution.y) / page_edge))
	_add_page_row(p_root, "Result per terrain block", "%d x %d texels" % [resolution.x, resolution.y], "%.2f texels/m" % density, "%d x %d internal pages at mip 0; not separate terrain blocks" % [page_grid.x, page_grid.y])
	_add_page_row(p_root, "Physical page footprint", "%.3f m" % page_world, "mip 0", "%d baked cell sources, each containing its mip chain" % _baked_pages().size())
	_add_resident_page_rows(p_root, "SVT")
	_add_baked_page_rows(p_root)


func _add_all_page_details(p_root: TreeItem) -> void:
	_add_resident_page_rows(p_root, "")
	_add_baked_page_rows(p_root)


func _add_resident_page_rows(p_root: TreeItem, p_kind: String) -> void:
	var pages := _resident_pages(p_kind)
	if pages.is_empty():
		_add_page_row(p_root, "Resident pages", "None", "", "No physical pages are currently published")
		return
	var count := 0
	for record in pages:
		if count >= MAX_PAGE_ROWS:
			_add_page_row(p_root, "…", "Truncated", "", "%d more pages" % (pages.size() - count))
			break
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var slot := int(record.get("slot", -1))
		var kind := _record_kind(record)
		var address: Vector2i = record.get("address", Vector2i())
		var mip := int(record.get("mip", 0))
		var ready := bool(record.get("ready", false))
		var rect: Rect2 = record.get("world_rect", Rect2())
		var owners: Array = record.get("owners", [])
		var location := _location_for_world_rect(rect)
		var row := _add_page_row(p_root, "Slot %d · %s" % [slot, kind], str(record.get("state", "Ready" if ready else "Pending")), "%s m%d" % [address, mip], "%s · owners %d" % [_rect_text(rect), owners.size()])
		var cache_reason := str(record.get("cache_reason", "")).strip_edges()
		if not cache_reason.is_empty():
			row.set_tooltip_text(1, cache_reason)
		row.set_metadata(0, {"slot": slot, "kind": kind, "location": location})
		for owner in owners:
			if typeof(owner) != TYPE_DICTIONARY:
				continue
			var child := _add_page_row(row, "Owner", str(owner.get("owner_type", kind)), str(owner.get("virtual", address)), "sector %s · mip %d" % [owner.get("sector", Vector2i()), int(owner.get("mip", mip))])
			child.set_metadata(0, {"slot": slot, "kind": kind, "location": location})
		count += 1


func _add_baked_page_rows(p_root: TreeItem) -> void:
	var pages := _baked_pages()
	var filtered: Array = []
	for record in pages:
		if typeof(record) == TYPE_DICTIONARY and (record.get("storage", "") == "Baked cell mip chain" or int(record.get("mip", 0)) == _selected_baked_mip):
			filtered.append(record)
	if filtered.is_empty() and not pages.is_empty() and _selected_baked_mip != 0:
		_add_page_row(p_root, "Baked material tiles", "No selected mip", "mip %d" % _selected_baked_mip, "Choose another mip from Baked mip")
		return
	if filtered.is_empty():
		_add_page_row(p_root, "Baked material tiles", "None", "mip %d" % _selected_baked_mip, "Bake SVT cells to create persisted sources")
		return
	var groups := {}
	var region_world := _region_world_size()
	for record: Dictionary in filtered:
		var rect: Rect2 = record.get("world_rect", Rect2())
		var group_key: Variant = "shared" if rect.size.x > region_world.x or rect.size.y > region_world.y else _location_for_world_rect(rect)
		if not groups.has(group_key):
			groups[group_key] = []
		groups[group_key].append(record)
	var density := float(_call(terrain, "get_surface_svt_texels_per_meter"))
	var resolution := Vector2i(ceil(region_world.x * density / pow(2.0, _selected_baked_mip)), ceil(region_world.y * density / pow(2.0, _selected_baked_mip)))
	var rows_left := MAX_PAGE_ROWS
	for group_key: Variant in groups:
		var entries: Array = groups[group_key]
		var shared := group_key is String
		var name_text := "Shared coarse coverage" if shared else "Terrain block %s" % group_key
		var parent := _add_page_row(p_root, name_text, "%d source files" % entries.size(), "mip %d" % _selected_baked_mip, "Shared by multiple blocks" if shared else "%d x %d texels per block" % [resolution.x, resolution.y])
		parent.collapsed = true
		if not shared:
			parent.set_metadata(0, {"location": group_key, "kind": "SVT"})
		for record: Dictionary in entries:
			if rows_left <= 0:
				_add_page_row(parent, "More internal pages", "Not expanded", "", "The block summary includes all stored pages")
				break
			rows_left -= 1
			var rect: Rect2 = record.get("world_rect", Rect2())
			var preview = record.get("preview", null)
			var row := _add_page_row(parent, "Cell source %s" % record.get("address", Vector2i()), "Preview ready" if _is_valid_image(preview) else "File only", "mip %d" % _selected_baked_mip, _rect_text(rect))
			row.set_metadata(0, {"slot": int(record.get("slot", -1)), "kind": "SVT", "baked": true, "location": _location_for_world_rect(rect), "preview": preview})


func _add_region_rows(p_root: TreeItem) -> void:
	var locations := _region_locations(_data)
	if locations.is_empty():
		_add_page_row(p_root, "Terrain regions", "None", "", "No loaded regions")
		return
	var root := _add_page_row(p_root, "Terrain regions", str(locations.size()), "", "Click a region to inspect its Terrain3DRegion data")
	for location in locations:
		var child := _add_page_row(root, "Region %s" % location, "Loaded", str(location), "Terrain3DRegion")
		child.set_metadata(0, {"location": location})


func _add_page_row(p_parent: TreeItem, p_name: String, p_state: String, p_address: String, p_details: String) -> TreeItem:
	var item := page_tree.create_item(p_parent)
	item.set_text(0, p_name)
	item.set_text(1, p_state)
	item.set_text(2, p_address)
	item.set_text(3, p_details)
	return item


func _on_page_item_selected() -> void:
	var item := page_tree.get_selected()
	if not item:
		return
	var value = item.get_metadata(0)
	if typeof(value) != TYPE_DICTIONARY:
		return
	if value.has("location"):
		_selected_location = value.location
		_inspect_region(_selected_location)
	if value.has("slot"):
		_selected_slot = int(value.slot)
		_selected_kind = str(value.get("kind", ""))
		refresh_preview_button.disabled = _selected_slot < 0
		preview_label.text = "Slot %d · %s selected. Press Refresh preview for an explicit GPU readback." % [_selected_slot, _selected_kind]
	if value.get("baked", false) and _is_valid_image(value.get("preview", null)):
		preview_texture.texture = _display_preview_texture(value.preview)
		preview_label.text = "Persisted SVT cell preview · mip %d" % int(value.get("mip", _selected_baked_mip))


func _refresh_page_preview() -> void:
	if terrain == null or not is_instance_valid(terrain) or _selected_slot < 0:
		return
	# This is the sole call site for the GPU page readback API. It is never run
	# from _process, a timer, or a redraw callback.
	var image = _call(terrain, "get_vt_page_preview", [_selected_slot])
	if _is_valid_image(image):
		preview_texture.texture = _display_preview_texture(image)
		preview_label.text = "Slot %d · %s · GPU preview refreshed" % [_selected_slot, _selected_kind]
	else:
		preview_label.text = "Slot %d has no material preview available" % _selected_slot


func _clear_preview() -> void:
	_selected_slot = -1
	_selected_kind = ""
	if refresh_preview_button:
		refresh_preview_button.disabled = true
	if preview_texture:
		preview_texture.texture = null
	if preview_label:
		preview_label.text = "No physical page selected"
	preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _refresh_overview() -> void:
	if not _built or not overview:
		return
	if terrain == null or not is_instance_valid(terrain):
		overview.clear_overview()
		overview_label.text = "Terrain height overview (material VT bake unavailable)"
		_overview_dirty = false
		return
	var locations := _region_locations(_data)
	if locations.is_empty():
		overview.clear_overview()
		overview_label.text = "Terrain height overview (no terrain regions)"
		_overview_dirty = false
		return
	var region_world := _region_world_size()
	var bounds := _region_world_bounds(locations, region_world)
	var baked := _baked_pages()
	var material_pages := _overview_material_pages(baked)
	var image_size := _overview_image_size(bounds)
	var image := _make_height_thumbnail(bounds, image_size)
	for record in material_pages:
		_blit_material_preview(image, record, bounds)
	var entries: Array = []
	for location in locations:
		var has_material := false
		for record in material_pages:
			if typeof(record) == TYPE_DICTIONARY and Rect2(record.get("world_rect", Rect2())).intersects(_region_rect_world(location, region_world)):
				has_material = true
				break
		entries.append({"location": location, "has_height": true, "has_material": has_material})
	_overview_texture = ImageTexture.create_from_image(image)
	overview.set_overview(entries, bounds, region_world, _overview_texture)
	if material_pages.is_empty():
		overview_label.text = "Terrain height overview (material VT bake unavailable) · click a region to inspect terrain data"
	else:
		overview_label.text = "Stitched baked cell overview · %d cells · click a region to inspect terrain data" % material_pages.size()
	_overview_dirty = false


func _overview_material_pages(p_pages: Array) -> Array:
	if p_pages.is_empty():
		return []
	var selected_mip := _selected_baked_mip
	var result: Array = []
	for record in p_pages:
		if typeof(record) == TYPE_DICTIONARY and int(record.get("mip", 0)) == selected_mip and _is_valid_image(record.get("preview", null)):
			result.append(record)
	return result


func _make_height_thumbnail(p_bounds: Rect2, p_size: Vector2i) -> Image:
	var image := Image.create(p_size.x, p_size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color("202a31"))
	# Read each region's CPU height image once and downsample it in memory. The
	# previous implementation called Terrain3DData.get_height() for every
	# thumbnail pixel, which made an explicit 768px overview issue hundreds of
	# thousands of native calls. Sampling is capped at 128x128 per region and the
	# small image is then enlarged into the stitched overview.
	var locations := _region_locations(_data)
	var region_world := _region_world_size()
	var global_range: Vector2 = _call(_data, "get_height_range")
	for location in locations:
		var region := _call(_data, "get_region", [location])
		var height_image = _call(region, "get_height_map")
		if not _is_valid_image(height_image):
			continue
		var world_rect := _region_rect_world(location, region_world)
		var dst_position := _world_to_image(world_rect.position, p_bounds, p_size)
		var dst_end := _world_to_image(world_rect.end, p_bounds, p_size)
		var dst_size := Vector2i(max(1, dst_end.x - dst_position.x), max(1, dst_end.y - dst_position.y))
		var sample_size := mini(128, maxi(8, maxi(dst_size.x, dst_size.y)))
		var sample := Image.create(sample_size, sample_size, false, Image.FORMAT_RGBA8)
		var region_range: Vector2 = _call(region, "get_height_range")
		if region_range.y <= region_range.x:
			region_range = global_range
		var low := region_range.x
		var span := maxf(region_range.y - region_range.x, 0.001)
		for y in sample_size:
			var source_y := mini(height_image.get_height() - 1, floori(float(y) * height_image.get_height() / sample_size))
			for x in sample_size:
				var source_x := mini(height_image.get_width() - 1, floori(float(x) * height_image.get_width() / sample_size))
				var value: float = height_image.get_pixel(source_x, source_y).r
				var normalized := clampf((value - low) / span, 0.0, 1.0)
				sample.set_pixel(x, y, Color(normalized * 0.65 + 0.12, normalized * 0.8 + 0.12, normalized * 0.95 + 0.12, 1.0))
		sample.resize(dst_size.x, dst_size.y, Image.INTERPOLATE_BILINEAR)
		image.blit_rect(sample, Rect2i(Vector2i.ZERO, sample.get_size()), dst_position)
	return image


func _blit_material_preview(p_image: Image, p_record: Dictionary, p_bounds: Rect2) -> void:
	var preview = p_record.get("preview", null)
	if not _is_valid_image(preview):
		return
	var tile: Image = preview.duplicate()
	var border := int(p_record.get("border", _vt_settings().get("border", 4)))
	var crop := Rect2i(border, border, tile.get_width() - 2 * border, tile.get_height() - 2 * border)
	if crop.size.x > 0 and crop.size.y > 0:
		tile = tile.get_region(crop)
	var rect: Rect2 = p_record.get("world_rect", Rect2())
	if not rect.has_area() or not p_bounds.has_area():
		return
	# A coarse SVT tile can cover more world space than the loaded terrain. Clip
	# in world coordinates before resizing so an enormous page never allocates a
	# giant intermediate image and only the visible source UVs are copied.
	var visible_rect := rect.intersection(p_bounds)
	if not visible_rect.has_area():
		return
	var source_uv := Rect2(
		(visible_rect.position - rect.position) / rect.size,
		visible_rect.size / rect.size)
	var source_rect := Rect2i(
		floori(source_uv.position.x * tile.get_width()),
		floori(source_uv.position.y * tile.get_height()),
		ceili(source_uv.size.x * tile.get_width()),
		ceili(source_uv.size.y * tile.get_height()))
	source_rect = source_rect.intersection(Rect2i(Vector2i.ZERO, tile.get_size()))
	if source_rect.size.x <= 0 or source_rect.size.y <= 0:
		return
	tile = tile.get_region(source_rect)
	var position := _world_to_image(visible_rect.position, p_bounds, p_image.get_size())
	var end := _world_to_image(visible_rect.end, p_bounds, p_image.get_size())
	var size := Vector2i(max(1, end.x - position.x), max(1, end.y - position.y))
	# Resize before colour conversion so a large baked page never incurs a full
	# native-resolution per-pixel display pass in the editor.
	tile.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
	if tile.get_format() != Image.FORMAT_RGBA8:
		tile.convert(Image.FORMAT_RGBA8)
	# Baker previews carry height in alpha, not opacity, and GPU output is in
	# linear RGB. Work on this duplicate only: the serialized channel image must
	# remain untouched for later page inspection/export.
	for y in tile.get_height():
		for x in tile.get_width():
			var color := tile.get_pixel(x, y).linear_to_srgb()
			color.a = 1.0
			tile.set_pixel(x, y, color)
	p_image.blit_rect(tile, Rect2i(Vector2i.ZERO, tile.get_size()), position)


func _display_preview_texture(p_value: Variant) -> Texture2D:
	if not _is_valid_image(p_value):
		return null
	var image: Image = p_value.duplicate()
	# Keep the inspector responsive when a full page is larger than the preview
	# panel. The baked image's alpha stores height, so it must be made opaque for
	# display; its RGB values are linear GPU output and need sRGB conversion.
	var edge := 512
	var longest := maxi(image.get_width(), image.get_height())
	if longest > edge:
		var scale := float(edge) / longest
		image.resize(maxi(1, roundi(image.get_width() * scale)), maxi(1, roundi(image.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y).linear_to_srgb()
			color.a = 1.0
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)


func _overview_image_size(p_bounds: Rect2) -> Vector2i:
	var longest := maxf(p_bounds.size.x, p_bounds.size.y)
	var scale := float(OVERVIEW_EDGE) / maxf(longest, 1.0)
	return Vector2i(max(1, roundi(p_bounds.size.x * scale)), max(1, roundi(p_bounds.size.y * scale)))


func _world_to_image(p_world: Vector2, p_bounds: Rect2, p_size: Vector2i) -> Vector2i:
	var uv := (p_world - p_bounds.position) / Vector2(maxf(p_bounds.size.x, 0.001), maxf(p_bounds.size.y, 0.001))
	return Vector2i(floori(uv.x * p_size.x), floori(uv.y * p_size.y))


func _region_world_bounds(p_locations: Array, p_region_world: Vector2) -> Rect2:
	var result := Rect2()
	var first := true
	for location in p_locations:
		var rect := _region_rect_world(location, p_region_world)
		if first:
			result = rect
			first = false
		else:
			result = result.merge(rect)
	return result


func _region_rect_world(p_location: Vector2i, p_region_world: Vector2) -> Rect2:
	return Rect2(Vector2(p_location) * p_region_world, p_region_world)


func _region_world_size() -> Vector2:
	var region_size := float(_call(terrain, "get_region_size"))
	var spacing := float(_call(terrain, "get_vertex_spacing"))
	return Vector2(maxf(region_size * spacing, 1.0), maxf(region_size * spacing, 1.0))


func _location_for_world_rect(p_rect: Rect2) -> Vector2i:
	var region_world := _region_world_size()
	return Vector2i(floori((p_rect.position.x + p_rect.size.x * 0.5) / region_world.x), floori((p_rect.position.y + p_rect.size.y * 0.5) / region_world.y))


func _rect_text(p_rect: Rect2) -> String:
	return "world %.1f,%.1f %.1fx%.1f" % [p_rect.position.x, p_rect.position.y, p_rect.size.x, p_rect.size.y]


func _on_overview_region_clicked(p_location: Vector2i) -> void:
	_selected_location = p_location
	_inspect_region(p_location)
	if overview:
		overview.set_selected_location(p_location)


func _inspect_region(p_location: Vector2i) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	var data := _get_data(terrain)
	var region := _call(data, "get_region", [p_location])
	if region != null and is_instance_valid(region):
		EditorInterface.inspect_object(region)


func _inspect_terrain() -> void:
	if terrain != null and is_instance_valid(terrain):
		EditorInterface.inspect_object(terrain)


func _on_close_requested() -> void:
	hide()


func _get_data(p_terrain: Object) -> Object:
	var value := _call(p_terrain, "get_data")
	return value as Object


func _vt_settings() -> Dictionary:
	var value := _call(terrain, "get_vt_settings")
	return value if typeof(value) == TYPE_DICTIONARY else {}


func _get_svt_auto_bake() -> bool:
	if terrain == null or not is_instance_valid(terrain):
		return true
	if _has_object_property(terrain, SVT_AUTO_BAKE_PROPERTY):
		return bool(terrain.get(SVT_AUTO_BAKE_PROPERTY))
	var getter_value := _call(terrain, "is_svt_auto_bake")
	return bool(getter_value) if getter_value != null else true


func _has_object_property(p_target: Object, p_property: StringName) -> bool:
	if p_target == null or not is_instance_valid(p_target):
		return false
	for property_info: Dictionary in p_target.get_property_list():
		if StringName(property_info.get("name", "")) == p_property:
			return true
	return false


func _resident_pages(p_kind: String = "") -> Array:
	var value := _call(terrain, "get_vt_pages")
	var result: Array = []
	if typeof(value) != TYPE_ARRAY:
		return result
	for record in value:
		if typeof(record) != TYPE_DICTIONARY:
			continue
		if p_kind.is_empty() or _record_kind(record) == p_kind:
			result.append(record)
	return result


func _baked_pages() -> Array:
	var value := _call(terrain, "get_svt_baked_pages")
	return value if typeof(value) == TYPE_ARRAY else []


func _record_kind(p_record: Dictionary) -> String:
	var value = p_record.get("kind", "")
	if typeof(value) == TYPE_STRING:
		return str(value).to_upper()
	if int(value) == 1:
		return "SVT"
	return "AVT"


func _view_stats(p_kind: String) -> Dictionary:
	var method := "get_surface_vt" if p_kind == "AVT" else "get_surface_svt"
	var view := _call(terrain, method)
	var value := _call(view, "get_stats")
	return value if typeof(value) == TYPE_DICTIONARY else {}


func _stats_text(p_stats: Dictionary) -> String:
	if p_stats.is_empty():
		return "stats unavailable"
	return "hits %d · misses %d · evictions %d · free %d" % [int(p_stats.get("hit_count", 0)), int(p_stats.get("miss_count", 0)), int(p_stats.get("evict_count", 0)), int(p_stats.get("free_count", 0))]


func _region_locations(p_data: Object) -> Array:
	var value := _call(p_data, "get_region_locations")
	if typeof(value) != TYPE_ARRAY:
		return []
	var result: Array = []
	for location in value:
		result.append(Vector2i(location))
	return result


func _is_valid_image(p_value: Variant) -> bool:
	return p_value is Image and not p_value.is_empty() and p_value.get_width() > 0 and p_value.get_height() > 0


func _call(p_target: Object, p_method: StringName, p_args: Array = []) -> Variant:
	if p_target == null or not is_instance_valid(p_target) or not p_target.has_method(p_method):
		return null
	return p_target.callv(p_method, p_args)


func _refresh_cdlod_panel() -> void:
	for child in cdlod_panel.get_children():
		cdlod_panel.remove_child(child)
		child.queue_free()
	cdlod_panel.show()
	if not terrain.has_method("get_cdlod_stats"):
		cdlod_panel.add_child(_make_setting_label("Rebuild the terrain extension to enable CDLOD."))
		return
	var enabled := CheckButton.new()
	enabled.name = "CDLODEnabled"
	enabled.text = "Enable CDLOD"
	enabled.set_pressed_no_signal(bool(terrain.get("cdlod_enabled")))
	enabled.toggled.connect(_on_cdlod_setting.bind("cdlod_enabled"))
	cdlod_panel.add_child(enabled)
	cdlod_panel.add_child(_make_setting_label("LOD distance scale"))
	var scale := _make_spin(8, 32, 0.5)
	scale.name = "CDLODLODScale"
	scale.set_value_no_signal(float(terrain.get("cdlod_lod_scale")))
	scale.value_changed.connect(_on_cdlod_setting.bind("cdlod_lod_scale"))
	cdlod_panel.add_child(scale)
	var status := Label.new()
	status.name = "CDLODMode"
	cdlod_panel.add_child(status)
	_sync_cdlod_panel()


func _sync_cdlod_panel() -> void:
	if not is_instance_valid(cdlod_panel) or not cdlod_panel.visible:
		return
	var enabled := cdlod_panel.get_node_or_null("CDLODEnabled") as CheckButton
	var status := cdlod_panel.get_node_or_null("CDLODMode") as Label
	if enabled == null or status == null:
		return
	enabled.set_pressed_no_signal(bool(terrain.get("cdlod_enabled")))
	var stats: Dictionary = terrain.get_cdlod_stats()
	status.text = "Current mode: " + str(stats.get("backend", "Clipmap"))



func _on_cdlod_setting(p_value: Variant, p_property: String) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	terrain.set(p_property, p_value)
	_sync_cdlod_panel()
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()
