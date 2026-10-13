@tool
class_name FengReflectProbeInspectorPlugin
extends EditorInspectorPlugin

const Probe = preload("../feng_reflect_probe.gd")

var _pending_bakes: Dictionary = {}

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
	bake.tooltip_text = "Capture and persist a portable HDR Cubemap. Save the edited scene to keep embedded Probe Data across restarts."
	bake.disabled = not scene_source or not bool(object.get("enabled"))
	bake.pressed.connect(_on_bake_pressed.bind(object as Probe))
	panel.add_child(bake)
	var note := Label.new()
	note.text = "External Cubemaps are copied on the GPU. Realtime refresh polls at the configured interval; mip filtering follows the per-frame budget."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(note)
	add_custom_control(panel)

func _on_bake_pressed(probe: Probe) -> void:
	if not is_instance_valid(probe):
		return
	var owner_id := probe.get_instance_id()
	_disconnect_pending_bake(owner_id)
	var completed := Callable(self, "_on_bake_completed").bind(owner_id)
	var failed := Callable(self, "_on_bake_failed").bind(owner_id)
	var exiting := Callable(self, "_on_probe_exiting").bind(owner_id)
	_pending_bakes[owner_id] = {
		"probe": weakref(probe),
		"completed": completed,
		"failed": failed,
		"exiting": exiting,
	}
	probe.bake_completed.connect(completed, CONNECT_ONE_SHOT)
	probe.capture_failed.connect(failed, CONNECT_ONE_SHOT)
	probe.tree_exiting.connect(exiting, CONNECT_ONE_SHOT)
	probe.request_bake()

func _on_bake_completed(_data: Resource, owner_id: int) -> void:
	var pending: Dictionary = _pending_bakes.get(owner_id, {})
	var probe_ref: Variant = pending.get("probe", null)
	var probe: Object = probe_ref.get_ref() if probe_ref is WeakRef else null
	if is_instance_valid(probe):
		EditorInterface.mark_scene_as_unsaved()
	_disconnect_pending_bake(owner_id)

func _on_bake_failed(message: String, owner_id: int) -> void:
	push_warning("FengReflectProbe bake failed: %s" % message)
	_disconnect_pending_bake(owner_id)

func _on_probe_exiting(owner_id: int) -> void:
	_disconnect_pending_bake(owner_id)

func _disconnect_pending_bake(owner_id: int) -> void:
	var pending: Variant = _pending_bakes.get(owner_id, {})
	if not pending is Dictionary:
		return
	var probe_ref: Variant = pending.get("probe", null)
	var probe: Object = probe_ref.get_ref() if probe_ref is WeakRef else null
	if is_instance_valid(probe):
		for pair in [["bake_completed", "completed"], ["capture_failed", "failed"],
				["tree_exiting", "exiting"]]:
			var signal_name: String = pair[0]
			var callback_name: String = pair[1]
			var callback: Callable = pending.get(callback_name, Callable())
			if callback.is_valid() and probe.is_connected(signal_name, callback):
				probe.disconnect(signal_name, callback)
	_pending_bakes.erase(owner_id)

func shutdown() -> void:
	for owner_id in _pending_bakes.keys():
		_disconnect_pending_bake(int(owner_id))
