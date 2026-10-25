# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Terrain3D Inspector integration for Surface VT pages.
@tool
extends EditorInspectorPlugin
class_name TerrainVTInspectorPlugin

## The host supplies the action; the inspector does not own the dock or window.
var open_overview: Callable

const AVT_LAYOUT_PREVIEW_SCRIPT: Script = preload("res://addons/feng-idweight-terrain/src/vt_avt_layout_preview.gd")
const CLIPMAP_PREVIEW_SCRIPT: Script = preload("res://addons/feng-idweight-terrain/src/vt_clipmap_preview.gd")


func _can_handle(p_object: Object) -> bool:
	return p_object != null and (p_object is Terrain3D or p_object.has_method("get_vt_settings"))


func _parse_group(p_object: Object, p_group: String) -> void:
	if not _can_handle(p_object):
		return
	if p_group != "Surface VT/VT Page" and not p_group.ends_with("/VT Page"):
		return
	var section := VBoxContainer.new()
	section.name = "TerrainVTPageSection"
	section.set_meta("native_vt_page", true)
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_theme_constant_override("separation", 2)
	_add_debug_preview(section, p_object, AVT_LAYOUT_PREVIEW_SCRIPT,
		["TerrainAVTDebugBlock", "TerrainAVTVTPageHeader", "TerrainAVTLayoutPreview", "TerrainVTPageDescription"],
		"AVT VT Page · camera layout / allocation",
		"Read-only AVT world-sector layout and current virtual allocations for the editor camera",
		"Near-field AVT layout follows the editor camera; outside the radius uses SVT.")
	_add_debug_preview(section, p_object, CLIPMAP_PREVIEW_SCRIPT,
		["TerrainClipmapDebugBlock", "TerrainClipmapDebugHeader", "TerrainClipmapPreview", "TerrainClipmapDebugNote"],
		"Clipmap VT Page · layer units / world",
		"Read-only clipmap world units, addressing and queued strips",
		"Clipmap supports LOD arrays and packed block atlases. Units snap to their texel size; moving the target updates exposed strips.")

	var open_button := Button.new()
	open_button.name = "TerrainVTPageOpenOverview"
	open_button.text = "Open VT Page overview"
	open_button.tooltip_text = "Open Surface VT and show the VT Page overview"
	open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_button.pressed.connect(_open_vt_page_overview.bind(p_object))
	section.add_child(open_button)

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


# Both blocks share construction and availability wiring; each preview owns its native gate.
func _add_debug_preview(p_section: VBoxContainer, p_terrain: Object, p_script: Script,
		p_names: Array[String], p_title: String, p_tooltip: String, p_description: String) -> void:
	var block := VBoxContainer.new()
	block.name = p_names[0]
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block.add_theme_constant_override("separation", 2)
	p_section.add_child(block)
	var header := Label.new()
	header.name = p_names[1]
	header.text = p_title
	header.tooltip_text = p_tooltip
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block.add_child(header)
	var preview: TerrainVTLayoutPreview = p_script.new()
	preview.name = p_names[2]
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.set_terrain(p_terrain)
	block.add_child(preview)
	var description := Label.new()
	description.name = p_names[3]
	description.text = p_description
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	block.add_child(description)
	preview.availability_changed.connect(func(available: bool): block.visible = available)
	block.visible = preview.is_available()


func _open_vt_page_overview(p_terrain: Object) -> void:
	if is_instance_valid(p_terrain) and open_overview.is_valid():
		open_overview.call(p_terrain)


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
	var settings := TerrainVTBridge.vt_settings(p_terrain)
	if settings.is_empty():
		return "SVT status unavailable"
	# The sentence itself is the bridge's, which the VT window's status label reads too.
	return TerrainVTBridge.svt_bake_status(settings,
			TerrainVTBridge.svt_auto_bake(p_terrain, &"surface_svt_auto_bake"))
