# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Terrain3D Inspector integration for Surface VT pages.
@tool
extends EditorInspectorPlugin
class_name TerrainVTInspectorPlugin

## The production EditorPlugin owns the Surface VT editor window. Keeping that
## ownership in one place lets this inspector entry work for the selected
## Terrain3D node without creating a second window or duplicating its state.
var editor_plugin: EditorPlugin

const AVT_LAYOUT_PREVIEW_SCRIPT: Script = preload("res://addons/feng-idweight-terrain/src/vt_avt_layout_preview.gd")
const CLIPMAP_PREVIEW_SCRIPT: Script = preload("res://addons/feng-idweight-terrain/src/vt_clipmap_preview.gd")
## `TerrainVT::Delivery::AVT`, which is also the value of the property that selects it. Named so the
## block below says which method it describes rather than carrying a bare number; the clipmap's block
## has no constant here because its gate is the layer's existence rather than a delivery value.
const DELIVERY_AVT := 1


func _can_handle(p_object: Object) -> bool:
	return p_object != null and (p_object is Terrain3D or p_object.has_method("get_vt_settings"))


func _parse_group(p_object: Object, p_group: String) -> void:
	if not _can_handle(p_object):
		return
	# One host, not two: the native binary always publishes `vt_page_status`, so
	# the "SVT but no VT Page subgroup" shape this entry used to fall back to
	# cannot occur and there is nothing to build for it.
	var native_page_group := p_group == "Surface VT/VT Page" or p_group.ends_with("/VT Page")
	if not native_page_group:
		return

	var section := VBoxContainer.new()
	section.name = "TerrainVTPageSection"
	section.set_meta("native_vt_page", native_page_group)
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# The native subgroup already supplies the foldout container. This control is
	# the content inside it, and keeps a stable name for editor tests and
	# inspection tools.
	var body: VBoxContainer = section
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 2)

	# The debug views, one per VT method that has a layout to draw, each gated on the delivery
	# matrix: a method no cell selects owns no layout, so its whole block - heading, view and note -
	# is hidden rather than shown empty, and its preview never runs the scan behind it. The control
	# owns that decision and reports it through `availability_changed`, because a group's controls
	# are not rebuilt when one property changes: the matrix can move under an open section, and a
	# block whose visibility was decided once at parse time would stay wrong.
	var avt_block := VBoxContainer.new()
	avt_block.name = "TerrainAVTDebugBlock"
	avt_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	avt_block.add_theme_constant_override("separation", 2)
	body.add_child(avt_block)

	var avt_header := Label.new()
	avt_header.name = "TerrainAVTVTPageHeader"
	avt_header.text = "AVT VT Page · camera layout / allocation"
	avt_header.tooltip_text = "Read-only AVT world-sector layout and current virtual allocations for the editor camera"
	avt_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	avt_block.add_child(avt_header)

	var avt_preview = AVT_LAYOUT_PREVIEW_SCRIPT.new()
	avt_preview.name = "TerrainAVTLayoutPreview"
	# The preview computes its minimum height from the Inspector width so a
	# narrow dock keeps a square map while a wide dock gives the map more room.
	avt_preview.custom_minimum_size = Vector2.ZERO
	avt_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	avt_preview.set_terrain(p_object)
	avt_block.add_child(avt_preview)

	var description := Label.new()
	description.name = "TerrainVTPageDescription"
	description.text = "Near-field AVT layout follows the editor camera; outside the radius uses SVT."
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	avt_block.add_child(description)

	# The clipmap's debug view is the same kind of page as the AVT one and sits beside it: the
	# matrix's two *VT* methods each have a layout, and the two bands' pages are what the physical
	# residency list below cannot show.
	var clipmap_block := VBoxContainer.new()
	clipmap_block.name = "TerrainClipmapDebugBlock"
	clipmap_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clipmap_block.add_theme_constant_override("separation", 2)
	body.add_child(clipmap_block)

	var clipmap_header := Label.new()
	clipmap_header.name = "TerrainClipmapDebugHeader"
	clipmap_header.text = "Clipmap VT Page · layer units / world"
	clipmap_header.tooltip_text = "Read-only clipmap layer: its units' world squares and addressing for the selected implementation, and the strips it still has queued"
	clipmap_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clipmap_block.add_child(clipmap_header)

	var clipmap_preview = CLIPMAP_PREVIEW_SCRIPT.new()
	clipmap_preview.name = "TerrainClipmapPreview"
	clipmap_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clipmap_preview.set_terrain(p_object)
	clipmap_block.add_child(clipmap_preview)

	var clipmap_note := Label.new()
	clipmap_note.name = "TerrainClipmapDebugNote"
	clipmap_note.text = "One clipmap delivery, two storages: the LOD level array and the packed block atlas. A unit is snapped to its own texel size, so moving the target costs strips rather than a rebuild; the stored content never moves."
	clipmap_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	clipmap_block.add_child(clipmap_note)
	_connect_debug_block(clipmap_preview, clipmap_block, p_object, &"has_vt_clipmap_layer")

	_connect_debug_block(avt_preview, avt_block, p_object, &"is_vt_delivery_used", DELIVERY_AVT)

	var open_button := Button.new()
	open_button.name = "TerrainVTPageOpenOverview"
	open_button.text = "Open VT Page overview"
	open_button.tooltip_text = "Open Surface VT and show the VT Page overview"
	open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_button.pressed.connect(_open_vt_page_overview.bind(p_object))
	body.add_child(open_button)

	add_custom_control(section)


func _parse_property(
		p_object: Object,
		p_type: Variant.Type,
		p_name: String,
		p_hint_type: PropertyHint,
		p_hint_string: String,
		p_usage_flags: int,
		p_wide: bool) -> bool:
	if not _can_handle(p_object) or p_name != "surface_svt_auto_bake":
		return false

	# This control is parsed with the native Auto Bake property, so it remains
	# inside the real Surface VT / SVT inspector subgroup. Returning false keeps
	# Godot's built-in boolean editor visible.
	var controls := VBoxContainer.new()
	controls.name = "TerrainSVTBakeControls"
	controls.set_meta("native_svt_group", true)
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_theme_constant_override("separation", 3)

	var bake_button := Button.new()
	bake_button.name = "TerrainSVTBakeAllButton"
	bake_button.text = "Bake All SVT Pages"
	bake_button.tooltip_text = "Force a full persisted material bake for all loaded regions and mip levels"
	bake_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bake_button.pressed.connect(_on_bake_all_svt_pressed.bind(p_object, controls))
	controls.add_child(bake_button)

	var progress_label := Label.new()
	progress_label.name = "TerrainSVTBakeProgress"
	progress_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	progress_label.text = _svt_bake_status(p_object)
	controls.add_child(progress_label)

	var status_timer := Timer.new()
	status_timer.name = "TerrainSVTBakeStatusTimer"
	status_timer.wait_time = 0.25
	status_timer.autostart = true
	status_timer.timeout.connect(_update_svt_bake_status.bind(p_object, progress_label))
	controls.add_child(status_timer)

	add_custom_control(controls)
	return false


# Ties a debug block's visibility to whether its view has something to draw: a cell selecting the
# method for AVT, a ring existing for the clipmap. The synchronous read keeps the block from flashing
# before the control's first poll and answers correctly on a terrain that has no matrix to ask; the
# signal keeps it in step afterwards, because that answer can change while the section is open and
# this group is not rebuilt when it does. `p_argument` is what the query takes, for the one gate that
# is a question about a method rather than about an object.
func _connect_debug_block(p_preview: Control, p_block: Control, p_object: Object, p_query: StringName, p_argument: Variant = null) -> void:
	if p_preview == null or p_block == null:
		return
	if p_preview.has_signal("availability_changed"):
		p_preview.connect("availability_changed", func(p_available: bool) -> void: p_block.visible = p_available)
	if p_object != null and p_object.has_method(p_query):
		var answer: Variant = p_object.call(p_query, p_argument) if p_argument != null else p_object.call(p_query)
		p_block.visible = bool(answer)


func _open_vt_page_overview(p_terrain: Object) -> void:
	if p_terrain == null or not is_instance_valid(p_terrain):
		return
	if editor_plugin == null or not is_instance_valid(editor_plugin):
		return
	if editor_plugin.has_method("open_vt_page_overview"):
		editor_plugin.call("open_vt_page_overview", p_terrain)


func _on_bake_all_svt_pressed(p_terrain: Object, p_controls: VBoxContainer) -> void:
	var status := p_controls.get_node_or_null("TerrainSVTBakeProgress") as Label
	if status == null:
		return
	if p_terrain == null or not is_instance_valid(p_terrain) or \
			(p_terrain is Node and not p_terrain.is_inside_tree()) or not p_terrain.has_method("bake_svt"):
		status.text = "Terrain unavailable"
		return
	var queued := int(p_terrain.call("bake_svt"))
	_update_svt_bake_status(p_terrain, status)
	if queued > 0:
		status.text = "Manual full SVT bake queued: %d pages." % queued
	else:
		status.text = "No SVT pages are available to bake."


func _update_svt_bake_status(p_terrain: Object, p_status: Label) -> void:
	if p_status == null or not is_instance_valid(p_status):
		return
	if not p_status.is_visible_in_tree():
		return
	p_status.text = _svt_bake_status(p_terrain)


func _svt_bake_status(p_terrain: Object) -> String:
	if p_terrain == null or not is_instance_valid(p_terrain) or \
			(p_terrain is Node and not p_terrain.is_inside_tree()) or not p_terrain.has_method("get_vt_settings"):
		return "Terrain unavailable"
	var value: Variant = p_terrain.call("get_vt_settings")
	if typeof(value) != TYPE_DICTIONARY:
		return "SVT status unavailable"
	var settings: Dictionary = value
	var auto_enabled := bool(settings.get("auto_bake", p_terrain.get("surface_svt_auto_bake")))
	var dirty_regions := int(settings.get("auto_pending_regions", 0))
	var incremental := bool(settings.get("bake_incremental", false))
	if bool(settings.get("bake_failed", false)):
		var mode := "Automatic incremental" if incremental else "Manual full"
		return "%s SVT bake failed: %s" % [mode, str(settings.get("bake_error", "unknown error"))]
	var total := int(settings.get("bake_total", 0))
	var done := int(settings.get("bake_done", 0))
	var pending := int(settings.get("bake_pending", 0))
	if pending > 0 or total > 0 or done > 0:
		var mode := "Automatic incremental" if incremental else "Manual full"
		var state := "complete" if total > 0 and done >= total and pending == 0 else "progress"
		return "%s SVT bake %s: %d/%d pages, %d pending." % [mode, state, done, total, pending]
	if auto_enabled and dirty_regions > 0:
		return "Auto Bake: %d changed region(s) queued; updates merge after 500 ms idle." % dirty_regions
	if auto_enabled:
		return "Auto Bake on · changed regions rebake 500 ms after editing stops."
	return "Auto Bake off · use Bake All SVT Pages for a full persisted bake."
