# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Terrain3D Inspector integration for Surface VT pages.
@tool
extends EditorInspectorPlugin
class_name TerrainVTInspectorPlugin

## The production EditorPlugin owns the Surface VT editor window. Keeping that
## ownership in one place lets this inspector entry work for the selected
## Terrain3D node without creating a second window or duplicating its state.
var editor_plugin: EditorPlugin


func _can_handle(p_object: Object) -> bool:
	return p_object != null and (p_object is Terrain3D or p_object.has_method("get_vt_settings"))


func _parse_group(p_object: Object, p_group: String) -> void:
	if not _can_handle(p_object):
		return
	var native_page_group := p_group == "Surface VT/VT Page" or p_group.ends_with("/VT Page")
	var svt_fallback_group := (p_group == "Surface VT/SVT" or p_group.ends_with("/SVT")) and \
			not _has_property(p_object, "vt_page_status")
	if not native_page_group and not svt_fallback_group:
		return

	var section := VBoxContainer.new()
	section.name = "TerrainVTPageSection"
	section.set_meta("native_vt_page", native_page_group)
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var body: VBoxContainer = section
	if not native_page_group:
		# Compatibility for an older native binary that has SVT but no VT Page
		# subgroup. The current native subgroup path below is the authoritative UI.
		var header := Button.new()
		header.name = "TerrainVTPageHeader"
		header.text = "VT Page"
		header.tooltip_text = "Shared physical residency and persisted SVT material pages"
		header.alignment = HORIZONTAL_ALIGNMENT_LEFT
		header.toggle_mode = true
		header.button_pressed = true
		header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_child(header)
		body = VBoxContainer.new()
		body.name = "TerrainVTPageContent"
		section.add_child(body)
		header.toggled.connect(_toggle_section.bind(body))
	else:
		# The native subgroup already supplies the foldout container. Keep the
		# custom control's stable name for editor tests and inspection tools.
		pass
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 2)

	var description := Label.new()
	description.name = "TerrainVTPageDescription"
	description.text = "Inspect resident pages and stitched SVT material pages."
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(description)

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


func _has_property(p_object: Object, p_name: String) -> bool:
	if p_object == null or not is_instance_valid(p_object):
		return false
	for property_info in p_object.get_property_list():
		if typeof(property_info) == TYPE_DICTIONARY and str(property_info.get("name", "")) == p_name:
			return true
	return false


func _toggle_section(p_expanded: bool, p_body: Control) -> void:
	if is_instance_valid(p_body):
		p_body.visible = p_expanded


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
