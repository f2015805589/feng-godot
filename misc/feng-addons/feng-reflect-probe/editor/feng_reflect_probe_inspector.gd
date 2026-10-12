@tool
class_name FengReflectProbeInspectorPlugin
extends EditorInspectorPlugin

const Probe = preload("../feng_reflect_probe.gd")

func _can_handle(object: Object) -> bool:
	return object is Probe

func _parse_begin(object: Object) -> void:
	if not object is Probe:
		return
	var panel := VBoxContainer.new()
	panel.name = "FengReflectProbeActions"
	var heading := Label.new()
	heading.text = "Feng Reflection Probe"
	panel.add_child(heading)
	var scene_source := int(object.get("source_mode")) == Probe.SourceMode.SCENE_CAPTURE
	var capture := Button.new()
	capture.name = "FengReflectProbeCaptureNow"
	capture.text = "Capture Now"
	capture.tooltip_text = "Capture all six HDR cubemap faces and prefilter them before publication."
	capture.disabled = not scene_source or not bool(object.get("enabled"))
	capture.pressed.connect(Callable(object, "request_update"))
	panel.add_child(capture)
	var refresh_external := Button.new()
	refresh_external.name = "FengReflectProbeRefreshCubemap"
	refresh_external.text = "Refresh Cubemap"
	refresh_external.tooltip_text = "Snapshot the assigned External Cubemap and rebuild its filtered mips."
	refresh_external.disabled = scene_source or not bool(object.get("enabled"))
	refresh_external.pressed.connect(Callable(object, "request_update"))
	panel.add_child(refresh_external)
	var bake := Button.new()
	bake.name = "FengReflectProbeBake"
	bake.text = "Bake Cubemap Resource"
	bake.tooltip_text = "Capture a portable HDR Cubemap. Save the updated Probe Data resource after the bake completes."
	bake.disabled = not scene_source or not bool(object.get("enabled"))
	bake.pressed.connect(Callable(object, "request_bake"))
	panel.add_child(bake)
	var note := Label.new()
	note.text = "External Cubemaps are copied on the GPU. Realtime refresh polls at the configured interval; mip filtering follows the per-frame budget."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(note)
	add_custom_control(panel)
