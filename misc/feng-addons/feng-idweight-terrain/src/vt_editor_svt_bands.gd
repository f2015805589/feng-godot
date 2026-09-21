# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Mip distance bands of the Surface VT editor: one spin box per world mip level,
# holding the furthest camera distance still sampled at that level.
#
# Both the page producer and the shader resolve a level through this table, so a
# value here is where the level boundary sits for the whole far field, not a hint.
# The table is stored on the terrain as surface_svt_mip_distances, and an empty
# table is not "no bands": it means derive one band per doubling of the page size.
# Those two states are what the Automatic and From page size buttons switch
# between, so this editor owns the table's representation as well as its widgets.
@tool
class_name TerrainVTEditorSvtBands
extends RefCounted

var terrain: Object
var grid: GridContainer
var hint: Label
var spins: Array[SpinBox] = []

# Rebuilding a grid of spin boxes while the user types in one of them would drop
# the edit, so a refresh compares this signature of (level count, stored table,
# page size) first and returns when nothing it displays has changed.
var _signature: String = ""
# True while this editor writes its own controls, so their value_changed does not
# bounce straight back into the terrain.
var _updating: bool = false


# Creates the controls in display order: header, live hint, the per level grid and
# the two rule buttons. The window decides which panel they belong to.
func build(p_panel: VBoxContainer) -> void:
	var header := Label.new()
	header.name = "SVTBandHeader"
	header.text = "Mip distance bands"
	p_panel.add_child(header)
	hint = Label.new()
	hint.name = "SVTBandHint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p_panel.add_child(hint)
	grid = GridContainer.new()
	grid.name = "SVTBandGrid"
	grid.columns = 2
	p_panel.add_child(grid)
	var buttons := HBoxContainer.new()
	buttons.name = "SVTBandButtons"
	var automatic_button := Button.new()
	automatic_button.name = "SVTBandAutomatic"
	automatic_button.text = "Automatic"
	automatic_button.tooltip_text = "Clear the table and derive one level per doubling of the far-field page size"
	automatic_button.pressed.connect(automatic)
	buttons.add_child(automatic_button)
	var fit_button := Button.new()
	fit_button.name = "SVTBandFromPageSize"
	fit_button.text = "From page size"
	fit_button.tooltip_text = "Pin the bands explicitly to the automatic rule, as a starting point to edit"
	fit_button.pressed.connect(fit_to_page_size)
	buttons.add_child(fit_button)
	p_panel.add_child(buttons)


# Makes the next refresh rebuild, for when something else changed the table.
func invalidate() -> void:
	_signature = ""


func refresh(p_terrain: Object) -> void:
	terrain = p_terrain
	if grid == null or terrain == null or not is_instance_valid(terrain):
		return
	if not TerrainVTBridge.has_property(terrain, &"surface_svt_mip_distances"):
		return
	var view := TerrainVTBridge.call_method(terrain, "get_surface_svt")
	var max_mip := int(TerrainVTBridge.call_method(view, "get_world_max_mip"))
	if max_mip < 0:
		max_mip = int(TerrainVTBridge.call_method(terrain, "get_surface_svt_max_mip"))
	var levels := maxi(1, max_mip + 1)
	var configured_value: Variant = TerrainVTBridge.call_method(terrain, "get_surface_svt_mip_distances")
	var configured: PackedFloat32Array = configured_value if configured_value is PackedFloat32Array else PackedFloat32Array()
	var page_world := maxf(0.001, float(TerrainVTBridge.call_method(terrain, "get_surface_svt_page_world")))
	var signature := "%d|%s|%s" % [levels, str(configured), str(page_world)]
	if signature == _signature:
		return
	_signature = signature
	var rebuilding := spins.size() != levels
	_updating = true
	if rebuilding:
		for child in grid.get_children():
			child.queue_free()
		spins.clear()
		for mip in levels:
			grid.add_child(TerrainVTEditorWidgets.make_setting_label("mip %d ≤" % mip))
			var spin := TerrainVTEditorWidgets.make_spin(1.0, 100000000.0, 1.0)
			spin.name = "SVTBandMip%d" % mip
			spin.tooltip_text = "Furthest camera distance in metres sampled at world mip %d" % mip
			spin.value_changed.connect(value_changed.bind(mip))
			grid.add_child(spin)
			spins.append(spin)
	for mip in spins.size():
		# An empty table is the automatic rule: show the edge that rule produces, so the
		# boxes always read as real distances.
		var automatic_edge := maxf(1.0, page_world * 2.0) * pow(2.0, float(mip))
		spins[mip].set_value_no_signal(float(configured[mip]) if mip < configured.size() else automatic_edge)
	_updating = false
	var parts: PackedStringArray = []
	var previous := 0.0
	for mip in spins.size():
		var edge := float(spins[mip].value)
		parts.append("%s–%s m → mip %d" % [_format_distance(previous), _format_distance(edge), mip])
		previous = edge
	var mode := "Explicit bands: every level named here is produced at exactly that distance." if not configured.is_empty() else "Automatic bands: one level per doubling of the %.0f m page. Editing a distance pins all bands explicitly." % page_world
	hint.text = "%s\n%s" % [mode, " · ".join(parts)]


# Any edit pins the whole chain, so what is stored is every box, not just the one
# the user touched.
func value_changed(_p_value: float, _p_mip: int) -> void:
	if _updating or terrain == null or not is_instance_valid(terrain):
		return
	var distances := PackedFloat32Array()
	for spin in spins:
		distances.append(float(spin.value))
	TerrainVTBridge.call_method(terrain, "set_surface_svt_mip_distances", [distances])
	invalidate()
	# The setter normalises the table, so read back what it stored.
	refresh(terrain)


# Back to the automatic rule: an empty table.
func automatic() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	TerrainVTBridge.call_method(terrain, "set_surface_svt_mip_distances", [PackedFloat32Array()])
	invalidate()
	refresh(terrain)


# Writes the automatic rule out as explicit distances, as a starting point to edit.
func fit_to_page_size() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	var page_world := maxf(0.001, float(TerrainVTBridge.call_method(terrain, "get_surface_svt_page_world")))
	var distances := PackedFloat32Array()
	for mip in maxi(1, spins.size()):
		distances.append(maxf(1.0, page_world * 2.0) * pow(2.0, float(mip)))
	TerrainVTBridge.call_method(terrain, "set_surface_svt_mip_distances", [distances])
	invalidate()
	refresh(terrain)


func _format_distance(p_metres: float) -> String:
	if p_metres >= 1000.0:
		return "%.1f km" % (p_metres / 1000.0)
	return "%.0f" % p_metres
