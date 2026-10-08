# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Shared VT panel label alignment and spin-box metrics.
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


# Clamp edits to the supplied range; callers may opt into a soft limit.
static func make_spin(p_min: float, p_max: float, p_step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = p_min
	spin.max_value = p_max
	spin.step = p_step
	spin.allow_greater = false
	spin.allow_lesser = false
	spin.custom_minimum_size.x = SPIN_WIDTH
	return spin
