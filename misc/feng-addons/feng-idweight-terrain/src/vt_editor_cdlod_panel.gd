# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# CDLOD settings panel of the Surface VT editor.
#
# CDLOD is terrain geometry, not virtual texturing, so nothing here talks about
# pages: one toggle, the LOD distance scale, and the backend label that says which
# geometry the terrain is actually drawing. The window owns the container and when
# the panel is on screen; this owns the controls inside it.
#
# The extension is loaded at runtime, so every read is guarded: a build without
# get_cdlod_stats() predates CDLOD and must say so rather than break the panel.
@tool
class_name TerrainVTEditorCdlodPanel
extends RefCounted

var panel: VBoxContainer
var terrain: Object


func _init(p_panel: VBoxContainer) -> void:
	panel = p_panel


# Rebuilds the controls for one terrain. Called when the CDLOD view is selected
# and whenever the terrain it describes is replaced.
func refresh(p_terrain: Object) -> void:
	terrain = p_terrain
	if panel == null or not is_instance_valid(panel):
		return
	for child in panel.get_children():
		panel.remove_child(child)
		child.queue_free()
	panel.show()
	if terrain == null or not is_instance_valid(terrain) or not terrain.has_method("get_cdlod_stats"):
		panel.add_child(TerrainVTEditorWidgets.make_setting_label("Rebuild the terrain extension to enable CDLOD."))
		return
	var enabled := CheckButton.new()
	enabled.name = "CDLODEnabled"
	enabled.text = "Enable CDLOD"
	enabled.set_pressed_no_signal(bool(terrain.get("cdlod_enabled")))
	enabled.toggled.connect(setting.bind("cdlod_enabled"))
	panel.add_child(enabled)
	panel.add_child(TerrainVTEditorWidgets.make_setting_label("LOD distance scale"))
	var scale := TerrainVTEditorWidgets.make_spin(8, 32, 0.5)
	scale.name = "CDLODLODScale"
	scale.set_value_no_signal(float(terrain.get("cdlod_lod_scale")))
	scale.value_changed.connect(setting.bind("cdlod_lod_scale"))
	panel.add_child(scale)
	var status := Label.new()
	status.name = "CDLODMode"
	panel.add_child(status)
	sync(terrain)


# Refreshes the controls from the terrain. Skipped while the panel is off screen,
# so an unselected CDLOD view costs nothing on the window's poll.
func sync(p_terrain: Object) -> void:
	terrain = p_terrain
	if panel == null or not is_instance_valid(panel) or not panel.visible:
		return
	var enabled := panel.get_node_or_null("CDLODEnabled") as CheckButton
	var status := panel.get_node_or_null("CDLODMode") as Label
	if enabled == null or status == null or terrain == null or not is_instance_valid(terrain):
		return
	enabled.set_pressed_no_signal(bool(terrain.get("cdlod_enabled")))
	var stats: Dictionary = terrain.get_cdlod_stats()
	status.text = "Current mode: " + str(stats.get("backend", "Clipmap"))


# Writes one control back to the terrain. The scene is marked unsaved because
# cdlod_enabled and cdlod_lod_scale are scene properties, not runtime settings.
func setting(p_value: Variant, p_property: String) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	terrain.set(p_property, p_value)
	sync(terrain)
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()
