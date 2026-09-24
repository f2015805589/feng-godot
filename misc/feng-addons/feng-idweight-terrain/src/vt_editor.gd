# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Surface VT editor. The editor intentionally keeps all expensive work behind
# explicit buttons: page previews are GPU readbacks only when requested, and the
# world thumbnail is stitched only when Refresh overview is pressed.
#
# The window is the shell: it owns the widgets, the selection state and which view
# is shown. Everything with rules of its own lives in a sibling script - the page
# rows in vt_editor_page_rows.gd, the mip distance bands in vt_editor_svt_bands.gd,
# the CDLOD controls in vt_editor_cdlod_panel.gd, the duck-typed native API in
# vt_terrain_bridge.gd and the world/image maths in vt_overview_image.gd.
@tool
extends Window
class_name TerrainVTEditor

const OVERVIEW_SCRIPT: Script = preload("res://addons/feng-idweight-terrain/src/vt_world_overview.gd")
const CLIPMAP_PREVIEW_SCRIPT: Script = preload("res://addons/feng-idweight-terrain/src/vt_clipmap_preview.gd")
const OVERVIEW_EDGE: int = 768
const INVALID_LOCATION := Vector2i(2147483647, 2147483647)
const SVT_AUTO_BAKE_PROPERTY: StringName = &"surface_svt_auto_bake"
const BAKE_STATUS_POLL_INTERVAL: float = 0.25
# The delivery methods in the order of the native `TerrainVT::Delivery` enum, which is also the
# item id the OptionButtons store: the widget, the property and the C++ value are one number, so a
# method added natively appears here as one more string and no mapping has to be kept in step.
const DELIVERY_METHODS: Array[String] = ["Direct (pure RVT)", "AVT", "Clipmap", "SVT", "Clipmap atlas"]
const DELIVERY_BANDS: Array[String] = ["near", "far"]
const DELIVERY_GROUPS: Array[String] = ["material", "height"]
const DELIVERY_GROUP_LABELS: Dictionary = {"material": "Diffuse + normal", "height": "Height"}
# The method these rows are about, by the native enum's value (`Clipmap`): the rows read the published
# capability rather than keeping a list of their own.
const DELIVERY_CLIPMAP: int = 2

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
var clipmap_panel: VBoxContainer
var clipmap_debug_panel: VBoxContainer
var clipmap_size_spin: SpinBox
var clipmap_levels_spin: SpinBox
var clipmap_base_spin: SpinBox
var clipmap_budget_spin: SpinBox
var clipmap_hint: Label
var _clipmap_preview: Control
var delivery_hint: Label
var cdlod_panel: VBoxContainer
var svt_panel: VBoxContainer
var _cdlod: TerrainVTEditorCdlodPanel
var page_size_spin: SpinBox
var page_border_spin: SpinBox
var anisotropy_spin: SpinBox
var mip_levels_spin: SpinBox
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
# The delivery matrix: one row per distance band, one column per channel group. Each cell is an
# OptionButton whose item id is the native delivery value, so the widget stores the same number the
# property does and no name lookup has to be kept in step. The four rows replace the old
# "AVT runtime material" / "SVT persisted material" check boxes, which could only express one
# method per tier for both groups at once.
var delivery_near_material: OptionButton
var delivery_near_height: OptionButton
var delivery_far_material: OptionButton
var delivery_far_height: OptionButton
var svt_auto_bake_button: CheckButton
var auto_bake_hint: Label
var bake_button: Button
var bake_status: Label
var _svt_bands: TerrainVTEditorSvtBands

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
	if _clipmap_preview != null and is_instance_valid(_clipmap_preview):
		_clipmap_preview.set_terrain(terrain)
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
	clipmap_panel = _build_clipmap_panel()
	details_box.add_child(clipmap_panel)
	clipmap_debug_panel = _build_clipmap_debug_panel()
	details_box.add_child(clipmap_debug_panel)
	svt_panel = _build_svt_panel()
	details_box.add_child(svt_panel)
	cdlod_panel = VBoxContainer.new()
	cdlod_panel.name = "CDLODSettings"
	details_box.add_child(cdlod_panel)
	_cdlod = TerrainVTEditorCdlodPanel.new(cdlod_panel)
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

	# The methods, in the order the assembly rule reads them: the matrix is what selects a method and
	# the ring's own shape sits directly after the settings that select it, ahead of the two views it
	# shares the page pool with. The tree the user reads is the order the layer assembles in.
	var clipmap := hierarchy.create_item(surface)
	clipmap.set_text(0, "Clipmap")
	clipmap.set_metadata(0, "clipmap")
	clipmap.set_tooltip_text(0, "Toroidal ring of power-of-two levels, one ring per channel group")
	clipmap.collapsed = false
	var clipmap_levels := hierarchy.create_item(clipmap)
	clipmap_levels.set_text(0, "Ring levels")
	clipmap_levels.set_metadata(0, "clipmap")

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
	# The ring is not paged, so it has no slot to list and nothing to preview from the GPU. What it
	# has is its levels and the strips still queued, which is the one debug view that belongs beside
	# the physical residency: both answer "what does this VT layer hold right now".
	var clipmap_page := hierarchy.create_item(pages)
	clipmap_page.set_text(0, "Clipmap ring")
	clipmap_page.set_metadata(0, "clipmap_debug")
	clipmap_page.set_tooltip_text(0, "The ring's levels and the rects it still has queued")


func _build_settings_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = "VTSettings"
	panel.visible = false
	# The delivery matrix first, because it decides what the rest of this panel and the two method
	# panels configure: a method no cell selects owns no view, no array, no uniform and no shader arm.
	_build_delivery_rows(panel)
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
	page_border_spin.tooltip_text = "Gutter each page carries, in texels. It bounds the near field's anisotropic filtering, which can only sample inside it: a gutter of n supports n - 0.5, so the near anisotropy setting needs a gutter of request + 1. Both views share the number."
	page_border_spin.value_changed.connect(_on_setting_value_changed.bind("border"))
	grid.add_child(page_border_spin)
	# The request the gutter above bounds. It sits here rather than in a page of its own because
	# the two numbers are one decision: the gutter admits `border - 0.5` and the request is what a
	# grazing view needs, so a caller who moves one has to see the other. A setting with no control
	# was the state that made a 3.5x ceiling silent in the first place.
	grid.add_child(_make_setting_label("Anisotropy (near field)"))
	anisotropy_spin = _make_spin(0, 16, 1)
	anisotropy_spin.name = "Anisotropy"
	anisotropy_spin.tooltip_text = "Anisotropic filtering the near field asks for: 2, 4, 8 or 16 times, or 0 to follow the viewport's filtering level. The border above is the hard bound, so a request wider than border - 0.5 is filtered at the border. The effective value is Terrain3D.get_vt_settings()[\"avt_anisotropy_effective\"]."
	anisotropy_spin.value_changed.connect(_on_setting_value_changed.bind("anisotropy"))
	grid.add_child(anisotropy_spin)
	# This count chooses the virtual image resolution tier for each fixed 64 m
	# world sector. Every allocated sector still carries its complete local page
	# mip chain, so this setting is not a local-chain truncation.
	grid.add_child(_make_setting_label("AVT resolution tiers"))
	mip_levels_spin = _make_spin(2, 16, 1)
	mip_levels_spin.name = "MipLevels"
	mip_levels_spin.tooltip_text = "Resolution tiers per fixed 64 m world sector (default 3: 64k/32k/16k, 1024/512/256 texels/m). Ten tiers extend to a 128x128 sector image (2 texels/m). Each allocated sector keeps its complete local page mip chain; cold sectors need not expose every tier immediately."
	mip_levels_spin.value_changed.connect(_on_setting_value_changed.bind("mip_levels"))
	grid.add_child(mip_levels_spin)
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
	# The native property has no ceiling, so the widget must not invent one: `allow_greater` lets a
	# typed value past the spin's soft range instead of clamping the setting behind the user's back.
	pages_per_update_spin = _make_spin(1, 32, 1)
	pages_per_update_spin.allow_greater = true
	pages_per_update_spin.name = "PagesPerUpdate"
	pages_per_update_spin.value_changed.connect(_on_setting_value_changed.bind("pages_per_update"))
	grid.add_child(pages_per_update_spin)
	grid.add_child(_make_setting_label("AVT coverage"))
	avt_mode_option = OptionButton.new()
	avt_mode_option.name = "AVTCoverage"
	avt_mode_option.add_item("Camera range / coarse base + 64m sectors", 2)
	avt_mode_option.add_item("Legacy region view", 0)
	avt_mode_option.add_item("Legacy target grid", 1)
	avt_mode_option.item_selected.connect(_on_avt_mode_selected)
	grid.add_child(avt_mode_option)
	grid.add_child(_make_setting_label("Fine max density (texels / metre)"))
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
	panel.add_child(_make_setting_label("AVT resolution tier density ceilings (texels / metre)"))
	avt_band_grid = GridContainer.new()
	avt_band_grid.columns = 2
	panel.add_child(avt_band_grid)
	grid.add_child(_make_setting_label("AVT range (metres)"))
	avt_distance_spin = _make_spin(64, 65536, 64)
	avt_distance_spin.name = "AVTRange"
	avt_distance_spin.tooltip_text = "Camera-centred AVT radius across fixed 64 m sectors and the coarse base. Outside this radius uses SVT; page count stays bounded."
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
	adaptive_button.tooltip_text = "Allow per-sector virtual resolution allocations to adapt while preserving overlapping cached pages"
	adaptive_button.toggled.connect(_on_adaptive_toggled)
	panel.add_child(adaptive_button)
	return panel


# The ring's shape and its budget, in their own panel beside the settings that select it. Three of
# the four are shape - they reconfigure every existing ring, which is why the setter resolves the
# assembly - and the fourth is the per-tick production budget, which is not a shape at all: a ring
# keeps its content and a value of 0 is a legal "produce nothing this tick".
func _build_clipmap_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = "ClipmapSettings"
	panel.visible = false
	var grid := GridContainer.new()
	grid.name = "ClipmapGrid"
	grid.columns = 2
	panel.add_child(grid)
	grid.add_child(_make_setting_label("Level edge (texels)"))
	clipmap_size_spin = _make_spin(8, 4096, 8)
	clipmap_size_spin.name = "ClipmapSize"
	clipmap_size_spin.tooltip_text = "Texels an axis on every level of the ring. It is not terrain metres: level 0 covers the base extent below in this many texels, and every coarser level doubles the extent and the texel size."
	clipmap_size_spin.value_changed.connect(_on_clipmap_setting_changed.bind("size"))
	grid.add_child(clipmap_size_spin)
	grid.add_child(_make_setting_label("Levels"))
	clipmap_levels_spin = _make_spin(1, 16, 1)
	clipmap_levels_spin.name = "ClipmapLevels"
	clipmap_levels_spin.tooltip_text = "How many levels the ring holds. Level l covers base_world * 2^l metres, so the coarsest level of n covers 2^(n-1) times the finest."
	clipmap_levels_spin.value_changed.connect(_on_clipmap_setting_changed.bind("levels"))
	grid.add_child(clipmap_levels_spin)
	grid.add_child(_make_setting_label("Base extent (metres)"))
	clipmap_base_spin = _make_spin(1.0, 4096.0, 1.0)
	clipmap_base_spin.name = "ClipmapBaseWorld"
	clipmap_base_spin.tooltip_text = "The metres the finest level covers. A texel of level l is base_world * 2^l / size metres wide, so at a 1 m vertex spacing a base of 256 m with 256 texels is 1 m per texel."
	clipmap_base_spin.value_changed.connect(_on_clipmap_setting_changed.bind("base_world"))
	grid.add_child(clipmap_base_spin)
	grid.add_child(_make_setting_label("Budget (texels / tick)"))
	clipmap_budget_spin = _make_spin(0, 1048576, 1024)
	clipmap_budget_spin.allow_greater = true
	clipmap_budget_spin.name = "ClipmapBudgetTexels"
	clipmap_budget_spin.tooltip_text = "Channel texels all rings may produce in one tick. It is spent beside the page budget rather than out of it, because the ring does not touch the shared page pool; 0 holds every ring still."
	clipmap_budget_spin.value_changed.connect(_on_clipmap_setting_changed.bind("budget"))
	grid.add_child(clipmap_budget_spin)
	clipmap_hint = Label.new()
	clipmap_hint.name = "ClipmapHint"
	clipmap_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(clipmap_hint)
	return panel


# The VT Page's clipmap view, which is the same control the Inspector's VT Page section hosts: one
# picture of the ring, two windows. The control hides itself when no delivery cell selects Clipmap,
# so the panel needs no gate of its own.
func _build_clipmap_debug_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = "ClipmapDebug"
	panel.visible = false
	_clipmap_preview = CLIPMAP_PREVIEW_SCRIPT.new()
	_clipmap_preview.name = "ClipmapDebugPreview"
	_clipmap_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clipmap_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(_clipmap_preview)
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

	_svt_bands = TerrainVTEditorSvtBands.new()
	_svt_bands.build(panel)
	return panel


func _make_setting_label(p_text: String) -> Label:
	return TerrainVTEditorWidgets.make_setting_label(p_text)


func _make_spin(p_min: float, p_max: float, p_step: float) -> SpinBox:
	return TerrainVTEditorWidgets.make_spin(p_min, p_max, p_step)


# The delivery matrix: two bands by two channel groups. A grid of four OptionButtons rather than
# the two check boxes it replaces, because a check box can only say "on or off" for one method and
# the whole point is that a group may be carried by AVT, by a clipmap, by SVT, or by nothing at all
# (`Direct`, the region arrays). The hint spells out the consequence, which is a property of the
# architecture and not visible in the widgets: a method no row selects is never built, and a method
# this build cannot deliver is refused by the setter rather than accepted and rendered from
# somewhere else.
func _build_delivery_rows(p_panel: VBoxContainer) -> void:
	delivery_hint = Label.new()
	delivery_hint.name = "DeliveryHint"
	delivery_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	delivery_hint.text = "How each channel group reaches the shader, per distance band. Direct samples the region arrays and builds no service; AVT is the sectored adaptive page table, SVT the world-space page grid, Clipmap the toroidal level ring, Clipmap atlas the same rings packed as blocks in one texture per channel (a movement republishes block rects, not whole levels). A method no row selects owns no object, no array and no shader code."
	p_panel.add_child(delivery_hint)
	var grid := GridContainer.new()
	grid.name = "DeliveryGrid"
	grid.columns = 3
	grid.add_child(_make_setting_label("Band"))
	for group in DELIVERY_GROUPS:
		grid.add_child(_make_setting_label(DELIVERY_GROUP_LABELS[group]))
	for band in DELIVERY_BANDS:
		grid.add_child(_make_setting_label(band.capitalize()))
		for group in DELIVERY_GROUPS:
			var option := OptionButton.new()
			option.name = "Delivery%s%s" % [band.capitalize(), group.capitalize()]
			option.tooltip_text = "Delivery method for %s in the %s band." % [DELIVERY_GROUP_LABELS[group], band]
			for method in DELIVERY_METHODS.size():
				option.add_item(DELIVERY_METHODS[method], method)
			option.item_selected.connect(_on_delivery_selected.bind(band, group))
			grid.add_child(option)
			_set_delivery_option(band, group, option)
	p_panel.add_child(grid)


func _set_delivery_option(p_band: String, p_group: String, p_option: OptionButton) -> void:
	match "%s_%s" % [p_band, p_group]:
		"near_material": delivery_near_material = p_option
		"near_height": delivery_near_height = p_option
		"far_material": delivery_far_material = p_option
		"far_height": delivery_far_height = p_option


func _delivery_option(p_band: String, p_group: String) -> OptionButton:
	match "%s_%s" % [p_band, p_group]:
		"near_material": return delivery_near_material
		"near_height": return delivery_near_height
		"far_material": return delivery_far_material
		"far_height": return delivery_far_height
	return null


# Reads the four cells from the settings dictionary the native side publishes rather than from four
# separate getters: one call, one snapshot, and a widget cannot show a state the rest of the panel
# was not read with. A native build that predates the matrix has no keys and no property, and the
# rows disable themselves instead of offering a choice the build cannot honour.
#
# Per method rather than per row: `delivery_supported` names the methods this build can deliver for
# each group and `delivery_unsupported` the sentence for each one it cannot, so an option this build
# has no arm for is disabled with the reason as its tooltip. The setter refuses the same pair, so a
# disabled item is a visible half of one rule rather than a second copy of it.
func _refresh_delivery_rows(p_settings: Dictionary) -> void:
	var supported := _has_object_property(terrain, &"vt_delivery_near_material")
	var allowed: Dictionary = p_settings.get("delivery_supported", {})
	var refused: Dictionary = p_settings.get("delivery_unsupported", {})
	for band in DELIVERY_BANDS:
		for group in DELIVERY_GROUPS:
			var option := _delivery_option(band, group)
			if option == null:
				continue
			option.disabled = not supported
			if not supported:
				continue
			_apply_delivery_availability(option, group, allowed, refused)
			var value := int(p_settings.get("delivery_%s_%s" % [band, group], 0))
			var index := option.get_item_index(value)
			if index >= 0:
				option.select(index)
	if delivery_hint == null:
		return
	var text := "How each channel group reaches the shader, per distance band. Direct samples the region arrays and builds no service; AVT is the sectored adaptive page table, SVT the world-space page grid, Clipmap the toroidal level ring, Clipmap atlas the same rings packed as blocks in one texture per channel (a movement republishes block rects, not whole levels). A method no row selects owns no object, no array and no shader code."
	for group in DELIVERY_GROUPS:
		var reasons: Dictionary = refused.get(group, {})
		for name: Variant in reasons:
			text += "\nUnavailable here: %s %s: %s." % [DELIVERY_GROUP_LABELS[group], str(name), str(reasons[name])]
	delivery_hint.text = text


# Disables the items this build cannot deliver for the group, with the setter's own sentence as the
# tooltip. A build that publishes no `delivery_supported` key (an older binary) keeps every item
# enabled: the panel has nothing to say about it then, and the setter remains the authority.
func _apply_delivery_availability(p_option: OptionButton, p_group: String, p_allowed: Dictionary, p_refused: Dictionary) -> void:
	if not p_allowed.has(p_group):
		return
	var methods: Array = p_allowed.get(p_group, [])
	var reasons: Dictionary = p_refused.get(p_group, {})
	for method in DELIVERY_METHODS.size():
		var index := p_option.get_item_index(method)
		if index < 0:
			continue
		var deliverable := methods.has(method)
		p_option.set_item_disabled(index, not deliverable)
		if deliverable:
			continue
		var reason: String = str(reasons.get(DELIVERY_METHODS[method], "not available in this build"))
		p_option.set_item_tooltip(index, "%s is not available for the %s group: %s" % [
			DELIVERY_METHODS[method], DELIVERY_GROUP_LABELS[p_group].to_lower(), reason])


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
		var fine_density := _fine_density(settings)
		var coarse_density := _coarse_density(settings)
		var resolution_levels := _resolution_level_count(settings)
		var local_chain_levels := _local_chain_levels(settings)
		summary_label.text += "\nAVT: %d fixed 64m sectors · %d coarse tier pages · fine max %s texel/m · coarse %s texel/m · tiers %d · local chain %s full" % [
			int(sectors.get("independent_sectors", 0)), int(settings.get("avt_coarse_pages", 0)),
			_density_text(fine_density), _density_text(coarse_density), resolution_levels, _integer_text(local_chain_levels)]
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
	page_border_spin.value = float(settings.get("border", 9))
	anisotropy_spin.value = float(settings.get("avt_anisotropy", 8))
	mip_levels_spin.value = float(settings.get("avt_mip_levels", 3))
	page_count_spin.value = float(settings.get("page_count", 256))
	auto_capacity_button.button_pressed = bool(settings.get("auto_capacity", true))
	pages_per_update_spin.value = float(settings.get("pages_per_update", 16))
	avt_density_spin.editable = mode == 2
	avt_density_spin.tooltip_text = "Fine maximum density for the highest virtual resolution tier (default 1024 texels/m). The independent coarse tier has its own budget and density."
	avt_density_spin.value = float(settings.get("avt_texels_per_meter", 1024.0))
	svt_density_spin.value = float(settings.get("svt_texels_per_meter", 1.0))
	var fine_density := _fine_density(settings)
	var coarse_density := _coarse_density(settings)
	avt_density_hint.text = "Fine max: %s texels/m (requested) · Coarse base: %s texels/m · resolution tiers: %d." % [
		_density_text(fine_density), _density_text(coarse_density), _resolution_level_count(settings)]
	avt_density_hint.text += "\nWorld sectors stay fixed at 64 m. Tiers choose each sector's virtual image by projected density; every allocation keeps its complete local page chain (%s levels). Cold sectors need not expose every tier immediately." % _integer_text(_local_chain_levels(settings))
	avt_density_hint.text += "\nSVT addressable extent: %.2f x %.2f m, centred on world origin." % [float(settings.get("svt_world_extent", 0.0)), float(settings.get("svt_world_extent", 0.0))]
	_refresh_avt_bands(settings)
	avt_distance_spin.value = float(settings.get("avt_distance", 384.0))
	editor_preview_button.set_pressed_no_signal(bool(settings.get("editor_preview", true)))


	adaptive_button.button_pressed = bool(settings.get("adaptive", false))
	_refresh_delivery_rows(settings)
	_refresh_clipmap_controls(settings)
	var auto_bake_enabled := _get_svt_auto_bake()
	svt_auto_bake_button.button_pressed = auto_bake_enabled
	svt_auto_bake_button.disabled = not _has_object_property(terrain, SVT_AUTO_BAKE_PROPERTY)
	svt_auto_bake_button.tooltip_text = "Automatically rebake changed SVT cells incrementally after editing has been idle for 500 ms" if not svt_auto_bake_button.disabled else "Auto Bake is unavailable in this Terrain3D build"
	auto_bake_hint.text = "Changed regions are merged and rebaked incrementally 500 ms after editing stops." if auto_bake_enabled else "Auto Bake is off. When enabled, changed regions merge and rebake incrementally 500 ms after editing stops. Use Bake All SVT Cells to refresh all cell sources and their mip chains."
	if bool(settings.get("editor_preview_active", false)):
		auto_bake_hint.text = "Automatic baking is paused during editor live preview. Close preview to resume, or use Bake All SVT Cells."
	_refresh_svt_bands()
	_updating_settings = false


# The ring's shape and what it cost. Like the delivery rows, this reads the one snapshot the rest of
# the panel was refreshed from, so a control cannot show a state the panel was not read with, and a
# native build that predates the ring disables the four spins instead of offering a shape it cannot
# build.
func _refresh_clipmap_controls(p_settings: Dictionary) -> void:
	if clipmap_panel == null or clipmap_size_spin == null:
		return
	var supported := _has_object_property(terrain, &"vt_clipmap_size")
	if supported:
		clipmap_size_spin.set_value_no_signal(float(p_settings.get("clipmap_size", 256)))
		clipmap_levels_spin.set_value_no_signal(float(p_settings.get("clipmap_levels_setting", 8)))
		clipmap_base_spin.set_value_no_signal(float(p_settings.get("clipmap_base_world", 256.0)))
		clipmap_budget_spin.set_value_no_signal(float(p_settings.get("clipmap_budget_texels", 65536)))
	clipmap_size_spin.editable = supported
	clipmap_levels_spin.editable = supported
	clipmap_base_spin.editable = supported
	clipmap_budget_spin.editable = supported
	clipmap_hint.text = _clipmap_hint_text(p_settings)


# The ring's consequence, in the panel that configures it: what a level is, which group carries one,
# and what the last update cost. Every number is read from the report rather than recomputed here, so
# the hint and `get_vt_settings()` cannot disagree. The first thing it has to say is whether a ring
# can exist at all: a ring is built the first time a cell selects `Clipmap` for a group, and selecting
# `Near/Height` is the one cell this build can deliver, so a terrain whose height row is left on
# `Direct` has no ring and the four spins below configure one that does not exist yet.
func _clipmap_hint_text(p_settings: Dictionary) -> String:
	if not _has_object_property(terrain, &"vt_clipmap_size"):
		return "This Terrain3D build has no clipmap ring."
	var levels := int(p_settings.get("clipmap_levels_setting", 0))
	var base := float(p_settings.get("clipmap_base_world", 0.0))
	var text := "Level l covers base * 2^l metres: at %d texels an axis the finest is %.1f m and the coarsest %.1f m. A level is addressed by arithmetic, so a move costs strips rather than a rebuild and the stored content never moves." % [
			int(p_settings.get("clipmap_size", 0)), base, base * pow(2.0, float(maxi(0, levels - 1)))]
	if not bool(p_settings.get("clipmap_ring", false)):
		var supported: Dictionary = p_settings.get("delivery_supported", {})
		var unsupported: Dictionary = p_settings.get("delivery_unsupported", {})
		if (supported.get("height", []) as Array).has(DELIVERY_CLIPMAP):
			text += "\nNo ring: no cell selects Clipmap yet, so nothing is built, ticked or uploaded. Select it in the height row above, or measure the mechanism through debug_update_vt_clipmap() (native/tests/vt_clipmap)."
		else:
			text += "\nNo ring: %s. Nothing here is built, ticked or uploaded by a terrain." % str(
					(unsupported.get("height", {}) as Dictionary).get("Clipmap", "no delivery cell may select Clipmap in this build"))
		text += "\nLast update produced %d channel texels." % int(p_settings.get("clipmap_produced_texels", 0))
		return text
	var rings: Dictionary = p_settings.get("clipmap", {})
	for group in DELIVERY_GROUPS:
		var entry: Dictionary = rings.get(group, {})
		if typeof(entry) != TYPE_DICTIONARY or entry.is_empty():
			continue
		var label: String = DELIVERY_GROUP_LABELS[group]
		if bool(entry.get("configured", false)):
			text += "\n%s: %d/%d levels valid · %d queued · %d texels produced · %.1f KB uploaded" % [
					label, int(entry.get("valid_levels", 0)), int(entry.get("levels", 0)), int(entry.get("pending_jobs", 0)),
					int(entry.get("produced_texels", 0)), float(entry.get("upload_bytes", 0)) / 1024.0]
		else:
			text += "\n%s: no ring object for this group" % label
	text += "\nLast update produced %d channel texels." % int(p_settings.get("clipmap_produced_texels", 0))
	return text


# Three of the four settings are the ring's shape: the native setter reconfigures every existing ring,
# so a write here is a shape change and not a setting parked for later. The budget is not a shape, and
# the native setter says so by not reconfiguring anything.
func _on_clipmap_setting_changed(p_value: float, p_key: String) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	# The property the write is addressed by and the setter it calls, in one entry, because the two have
	# to name the same setting: the budget's property carries the `_texels` suffix its setter does, which
	# a `"vt_clipmap_%s" % p_key` probe cannot know - so the budget control used to be refused here and
	# never reached the terrain at all.
	var setting: Array = {
		"size": ["vt_clipmap_size", "set_vt_clipmap_size"],
		"levels": ["vt_clipmap_levels", "set_vt_clipmap_levels"],
		"base_world": ["vt_clipmap_base_world", "set_vt_clipmap_base_world"],
		"budget": ["vt_clipmap_budget_texels", "set_vt_clipmap_budget_texels"],
	}.get(p_key, [])
	if setting.is_empty() or not _has_object_property(terrain, setting[0]):
		return
	var argument: Variant = p_value if p_key == "base_world" else int(round(p_value))
	_call(terrain, setting[1], [argument])
	_refresh_header()
	_refresh_settings_controls()


# The band table is its own editor: it owns the spin boxes, the automatic rule and
# the hint that describes both. The window only decides when to refresh it.
func _refresh_svt_bands() -> void:
	if _svt_bands == null:
		return
	_svt_bands.refresh(terrain)


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
		"anisotropy": "set_surface_vt_anisotropy",
		"mip_levels": "set_surface_vt_mip_levels",
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
	# A density change moves the automatic band edges, so the table has to rebuild.
	if _svt_bands != null:
		_svt_bands.invalidate()
	_overview_dirty = true
	_refresh_header()
	_refresh_settings_controls()


func _refresh_avt_bands(settings: Dictionary) -> void:
	var levels := _resolution_level_count(settings)
	if avt_band_spins.size() != levels:
		for child in avt_band_grid.get_children():
			avt_band_grid.remove_child(child)
			child.queue_free()
		avt_band_spins.clear()
		for mip in levels:
			avt_band_grid.add_child(_make_setting_label("tier %d max texel/m" % mip))
			var spin := _make_spin(1.0 / pow(2.0, mip), 8192.0 / pow(2.0, mip), 1.0 / pow(2.0, mip))
			spin.name = "AVTBandMip%d" % mip
			spin.tooltip_text = "Maximum density for virtual resolution tier %d. Tiers are selected per fixed 64 m sector from projected density; they do not truncate that sector's local page mip chain." % mip
			spin.value_changed.connect(_on_avt_band_changed.bind(mip))
			avt_band_grid.add_child(spin)
			avt_band_spins.append(spin)
	var fine_density := _fine_density(settings)
	for mip in levels:
		avt_band_spins[mip].set_value_no_signal(fine_density / pow(2.0, mip))


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


func _on_delivery_selected(p_index: int, p_band: String, p_group: String) -> void:
	if _updating_settings or terrain == null or not is_instance_valid(terrain):
		return
	var option: OptionButton = _delivery_option(p_band, p_group)
	if option == null or p_index < 0 or p_index >= option.item_count:
		return
	var property := StringName("vt_delivery_%s_%s" % [p_band, p_group])
	if not TerrainVTBridge.has_property(terrain, property):
		return
	# A write the setter refuses leaves the cell where it was, and the refresh below re-reads the cells
	# rather than the widget's own selection, so an option that is somehow chosen while disabled snaps
	# back to the method the terrain actually holds instead of showing a value nothing stored.
	terrain.set(property, option.get_item_id(p_index))
	if Engine.is_editor_hint() and plugin != null and is_instance_valid(plugin):
		EditorInterface.mark_scene_as_unsaved()
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
	clipmap_panel.visible = false
	clipmap_debug_panel.visible = false
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
		"clipmap":
			details_label.text = "Clipmap · toroidal ring levels"
			clipmap_panel.visible = true
			_refresh_settings_controls()
			_add_clipmap_details(root)
		"clipmap_debug":
			details_label.text = "VT Page · clipmap ring"
			clipmap_debug_panel.visible = true
			_refresh_settings_controls()
			_add_clipmap_details(root)
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


# The rows themselves are built by TerrainVTEditorPageRows, which reads one
# snapshot of the terrain instead of a live scene, so the window keeps only the
# dispatch above and the panel visibility. These stay as methods because the
# window's own refresh paths and the editor regression suite drive them by name.
func _page_snapshot() -> TerrainVTEditorPageRows.Snapshot:
	return TerrainVTEditorPageRows.snapshot(terrain, _data, _selected_baked_mip)


func _add_settings_summary(p_root: TreeItem) -> void:
	TerrainVTEditorPageRows.add_settings_summary(page_tree, p_root, _page_snapshot())


func _add_clipmap_details(p_root: TreeItem) -> void:
	TerrainVTEditorPageRows.add_clipmap_details(page_tree, p_root, _page_snapshot())


func _add_surface_details(p_root: TreeItem) -> void:
	TerrainVTEditorPageRows.add_surface_details(page_tree, p_root, _page_snapshot())


func _add_avt_details(p_root: TreeItem) -> void:
	TerrainVTEditorPageRows.add_avt_details(page_tree, p_root, _page_snapshot())


func _add_svt_details(p_root: TreeItem) -> void:
	TerrainVTEditorPageRows.add_svt_details(page_tree, p_root, _page_snapshot())


func _add_all_page_details(p_root: TreeItem) -> void:
	TerrainVTEditorPageRows.add_all_page_details(page_tree, p_root, _page_snapshot())


func _add_resident_page_rows(p_root: TreeItem, p_kind: String) -> void:
	TerrainVTEditorPageRows.add_resident_page_rows(page_tree, p_root, _page_snapshot(), p_kind)


func _add_baked_page_rows(p_root: TreeItem) -> void:
	TerrainVTEditorPageRows.add_baked_page_rows(page_tree, p_root, _page_snapshot())


func _add_region_rows(p_root: TreeItem) -> void:
	TerrainVTEditorPageRows.add_region_rows(page_tree, p_root, _page_snapshot())


func _add_page_row(p_parent: TreeItem, p_name: String, p_state: String, p_address: String, p_details: String) -> TreeItem:
	return TerrainVTEditorPageRows.add_row(page_tree, p_parent, p_name, p_state, p_address, p_details)


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
	return TerrainVTOverviewImage.material_pages(p_pages, _selected_baked_mip)


func _make_height_thumbnail(p_bounds: Rect2, p_size: Vector2i) -> Image:
	var global_range: Vector2 = _call(_data, "get_height_range")
	return TerrainVTOverviewImage.height_thumbnail(p_bounds, p_size, _region_locations(_data),
			_region_world_size(), global_range,
			func(p_location: Vector2i) -> Object: return _call(_data, "get_region", [p_location]))


func _blit_material_preview(p_image: Image, p_record: Dictionary, p_bounds: Rect2) -> void:
	var border := int(_vt_settings().get("border", 4))
	TerrainVTOverviewImage.blit_material_preview(p_image, p_record, p_bounds, border)


func _display_preview_texture(p_value: Variant) -> Texture2D:
	return TerrainVTOverviewImage.display_texture(p_value)


func _overview_image_size(p_bounds: Rect2) -> Vector2i:
	return TerrainVTOverviewImage.overview_size(p_bounds, OVERVIEW_EDGE)


func _world_to_image(p_world: Vector2, p_bounds: Rect2, p_size: Vector2i) -> Vector2i:
	return TerrainVTOverviewImage.world_to_image(p_world, p_bounds, p_size)


func _region_world_bounds(p_locations: Array, p_region_world: Vector2) -> Rect2:
	return TerrainVTOverviewImage.region_world_bounds(p_locations, p_region_world)


func _region_rect_world(p_location: Vector2i, p_region_world: Vector2) -> Rect2:
	return TerrainVTOverviewImage.region_rect_world(p_location, p_region_world)


func _region_world_size() -> Vector2:
	return TerrainVTEditorPageRows.region_world_size(terrain)


func _location_for_world_rect(p_rect: Rect2) -> Vector2i:
	return TerrainVTEditorPageRows.location_for_world_rect(p_rect, _region_world_size())


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
	return TerrainVTBridge.data_of(p_terrain)


func _vt_settings() -> Dictionary:
	return TerrainVTBridge.vt_settings(terrain)


func _fine_density(p_settings: Dictionary) -> float:
	# The native report's effective_texels_per_meter is the fine target density
	# in the new contract. Keep the requested property as a fallback for a
	# partially upgraded binary, rather than displaying the coarse density here.
	var density := float(p_settings.get("avt_effective_texels_per_meter",
			p_settings.get("avt_texels_per_meter", 1024.0)))
	return density if density > 0.0 else float(p_settings.get("avt_texels_per_meter", 1024.0))


func _coarse_density(p_settings: Dictionary) -> float:
	var density := float(p_settings.get("avt_coarse_texels_per_meter", 0.0))
	return density if density > 0.0 else 0.0


func _resolution_level_count(p_settings: Dictionary) -> int:
	var requested := clampi(int(p_settings.get("avt_mip_levels", 3)), 2, 16)
	return clampi(int(p_settings.get("avt_sector_resolution_levels", p_settings.get("avt_effective_mip_levels", requested))), 2, 16)


func _local_chain_levels(p_settings: Dictionary) -> int:
	var levels := int(p_settings.get("avt_local_mip_levels", 0))
	return levels if levels > 0 else 0


func _density_text(p_density: float) -> String:
	return "—" if p_density <= 0.0 else "%.0f" % p_density


func _integer_text(p_value: int) -> String:
	return "—" if p_value <= 0 else str(p_value)


func _get_svt_auto_bake() -> bool:
	return TerrainVTBridge.svt_auto_bake(terrain, SVT_AUTO_BAKE_PROPERTY)


func _has_object_property(p_target: Object, p_property: StringName) -> bool:
	return TerrainVTBridge.has_property(p_target, p_property)


func _resident_pages(p_kind: String = "") -> Array:
	return TerrainVTBridge.resident_pages(terrain, p_kind)


func _baked_pages() -> Array:
	return TerrainVTBridge.baked_pages(terrain)


func _region_locations(p_data: Object) -> Array:
	return TerrainVTBridge.region_locations(p_data)


func _is_valid_image(p_value: Variant) -> bool:
	return TerrainVTBridge.is_valid_image(p_value)


func _call(p_target: Object, p_method: StringName, p_args: Array = []) -> Variant:
	return TerrainVTBridge.call_method(p_target, p_method, p_args)


# The CDLOD controls are terrain geometry rather than virtual texturing, so they
# live in their own panel module. The window keeps the container, when it is on
# screen, and the delegations below.
func _refresh_cdlod_panel() -> void:
	if _cdlod == null:
		return
	_cdlod.refresh(terrain)


func _sync_cdlod_panel() -> void:
	if _cdlod == null:
		return
	_cdlod.sync(terrain)
