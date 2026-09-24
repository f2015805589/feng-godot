# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# The delivery matrix of the Surface VT editor: two distance bands by two channel groups, one
# OptionButton a cell, and the hint that spells out what the four choices mean together.
#
# The cells are not a second copy of the native rule. `get_vt_settings()` publishes
# `delivery_supported` - the methods this build can deliver for each group - and
# `delivery_unsupported`, the sentence for each one it cannot, so an option with no arm behind it is
# disabled with the setter's own words as its tooltip, and the setter refuses the same pair. A write
# the setter refuses leaves the cell where it was: the refresh after it re-reads the cells rather
# than the widget's own selection, so a method that was somehow chosen while disabled snaps back to
# the one the terrain actually holds instead of showing a value nothing stored.
@tool
class_name TerrainVTEditorDeliveryRows
extends RefCounted

# The delivery methods in the order of the native `TerrainVT::Delivery` enum, which is also the
# item id the OptionButtons store: the widget, the property and the C++ value are one number, so a
# method added natively appears here as one more string and no mapping has to be kept in step.
const DELIVERY_METHODS: Array[String] = ["Direct (pure RVT)", "AVT", "Clipmap", "SVT"]
const DELIVERY_BANDS: Array[String] = ["near", "far"]
const DELIVERY_GROUPS: Array[String] = ["material", "height"]
const DELIVERY_GROUP_LABELS: Dictionary = {"material": "Diffuse + normal", "height": "Height"}

## The terrain the cells read and write. The window owns it and hands it over on every refresh.
var terrain: Object
## The one sentence under the grid, which the window keeps a reference to as `delivery_hint`.
var hint: Label
## The window's own refresh after a cell was written, so an edit re-reads the panel it changed.
var changed: Callable

## A cell's widget by band and group. The window aliases the four into the members its own tests and
## its own layout read (`delivery_near_material` and so on), so the grid has one owner either way.
var rows: Dictionary = {}
## True while this grid writes its own selection, so the write does not bounce straight back.
var _updating: bool = false


func build(p_panel: VBoxContainer) -> void:
	hint = Label.new()
	hint.name = "DeliveryHint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.text = _hint_text({})
	p_panel.add_child(hint)
	var grid := GridContainer.new()
	grid.name = "DeliveryGrid"
	grid.columns = 3
	grid.add_child(TerrainVTEditorWidgets.make_setting_label("Band"))
	for group in DELIVERY_GROUPS:
		grid.add_child(TerrainVTEditorWidgets.make_setting_label(DELIVERY_GROUP_LABELS[group]))
	for band in DELIVERY_BANDS:
		grid.add_child(TerrainVTEditorWidgets.make_setting_label(band.capitalize()))
		for group in DELIVERY_GROUPS:
			var option := OptionButton.new()
			option.name = "Delivery%s%s" % [band.capitalize(), group.capitalize()]
			option.tooltip_text = "Delivery method for %s in the %s band." % [DELIVERY_GROUP_LABELS[group], band]
			for method in DELIVERY_METHODS.size():
				option.add_item(DELIVERY_METHODS[method], method)
			option.item_selected.connect(select.bind(band, group))
			grid.add_child(option)
			rows["%s_%s" % [band, group]] = option
	p_panel.add_child(grid)


func option(p_band: String, p_group: String) -> OptionButton:
	return rows.get("%s_%s" % [p_band, p_group], null)


# Reads the four cells from the settings dictionary the native side publishes rather than from four
# separate getters: one call, one snapshot, and a widget cannot show a state the rest of the panel
# was not read with. A native build that predates the matrix has no keys and no property, and the
# rows disable themselves instead of offering a choice the build cannot honour.
func refresh(p_settings: Dictionary) -> void:
	var supported := TerrainVTBridge.has_property(terrain, &"vt_delivery_near_material")
	var allowed: Dictionary = p_settings.get("delivery_supported", {})
	var refused: Dictionary = p_settings.get("delivery_unsupported", {})
	_updating = true
	for band in DELIVERY_BANDS:
		for group in DELIVERY_GROUPS:
			var cell := option(band, group)
			if cell == null:
				continue
			cell.disabled = not supported
			if not supported:
				continue
			_apply_availability(cell, group, allowed, refused)
			var value := int(p_settings.get("delivery_%s_%s" % [band, group], 0))
			var index := cell.get_item_index(value)
			if index >= 0:
				cell.select(index)
	_updating = false
	if hint != null:
		hint.text = _hint_text(refused)


# Disables the items this build cannot deliver for the group, with the setter's own sentence as the
# tooltip. A build that publishes no `delivery_supported` key (an older binary) keeps every item
# enabled: the grid has nothing to say about it then, and the setter remains the authority.
func _apply_availability(p_option: OptionButton, p_group: String, p_allowed: Dictionary, p_refused: Dictionary) -> void:
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


func _hint_text(p_refused: Dictionary) -> String:
	var text := "How each channel group reaches the shader, per distance band. Direct samples the region arrays and builds no service; AVT is the sectored adaptive page table, SVT the world-space page grid, Clipmap the one toroidal layer whose storage the Clipmap group's implementation selector chooses - the LOD level array or the packed block atlas. A method no row selects owns no object, no array and no shader code."
	for group in DELIVERY_GROUPS:
		var reasons: Dictionary = p_refused.get(group, {})
		for name: Variant in reasons:
			text += "\nUnavailable here: %s %s: %s." % [DELIVERY_GROUP_LABELS[group], str(name), str(reasons[name])]
	return text


# One cell written. The property is the cell's own name, so the widget, the property and the native
# value stay one number; the write goes through the terrain's setter, which is what refuses a pair
# this build cannot deliver.
func select(p_index: int, p_band: String, p_group: String) -> void:
	if _updating or terrain == null or not is_instance_valid(terrain):
		return
	var cell := option(p_band, p_group)
	if cell == null or p_index < 0 or p_index >= cell.item_count:
		return
	var property := StringName("vt_delivery_%s_%s" % [p_band, p_group])
	if not TerrainVTBridge.has_property(terrain, property):
		return
	terrain.set(property, cell.get_item_id(p_index))
	if changed.is_valid():
		changed.call()
