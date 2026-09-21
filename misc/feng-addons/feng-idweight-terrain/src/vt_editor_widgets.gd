# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Widget factories shared by the Surface VT editor's panels.
#
# Three panels in the window (settings, SVT bands, CDLOD) lay out the same label
# and spin box, and the two things that matter about them are that a settings
# label is vertically centred next to its control and that a spin box is the same
# width everywhere. Both live here once instead of in each builder.
@tool
class_name TerrainVTEditorWidgets
extends RefCounted

# Wide enough for a five digit distance or a texel density, and the same in every
# grid so the columns line up across panels.
const SPIN_WIDTH: float = 130.0


static func make_setting_label(p_text: String) -> Label:
	var label := Label.new()
	label.text = p_text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


# A spin box that never accepts a value outside its range: these controls write
# straight into the terrain, so clamping in the widget is what keeps a typed
# out-of-range number from reaching it.
static func make_spin(p_min: float, p_max: float, p_step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = p_min
	spin.max_value = p_max
	spin.step = p_step
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.custom_minimum_size.x = SPIN_WIDTH
	return spin
