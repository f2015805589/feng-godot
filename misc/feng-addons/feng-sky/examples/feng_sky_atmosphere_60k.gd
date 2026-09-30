extends Node3D
## A small runnable scene bootstrap. The project's renderer must already be FRP;
## a scene cannot switch the renderer after the RenderingServer starts.

const FengRendererScript = preload("res://addons/feng-render-pipeline/renderer.gd")
const FengCompositorScript = preload("res://addons/feng-render-pipeline/compositor.gd")
const PHYSICAL_LIGHT_UNITS_SETTING := "rendering/lights_and_shadows/use_physical_light_units"

var _camera: Camera3D
var _renderer: Resource
var _compositor: Compositor


func _ready() -> void:
	_camera = $Camera3D
	if RenderingServer.get_current_rendering_method() != "frp":
		push_warning("Feng Sky 60k example: run with the FRP rendering method to enable height fog and eye adaptation.")
		return
	if not ProjectSettings.get_setting(PHYSICAL_LIGHT_UNITS_SETTING, false):
		push_warning("Feng Sky 60k example: enable Physical Light Units in Project Settings and restart to use the authored 60,000 lux sun.")

	_renderer = FengRendererScript.new()
	var found_eye_adaptation := false
	for pass_entry in _renderer.get("passes"):
		var stable_id: StringName = pass_entry.get("stable_id")
		if stable_id == &"library:eye_adaptation":
			pass_entry.set("enabled", true)
			pass_entry.set("extend_default_luminance_range", true)
			pass_entry.set("pre_exposure", true)
			found_eye_adaptation = true
		elif stable_id == &"library:magic_gi":
			# The example isolates atmosphere/fog/exposure and does not need GI.
			pass_entry.set("enabled", false)
	if not found_eye_adaptation:
		push_error("Feng Sky 60k example: the FRP renderer did not seed Eye Adaptation.")
		_renderer = null
		return

	_compositor = FengCompositorScript.new()
	_compositor.set("renderer", _renderer)
	_camera.compositor = _compositor


func _exit_tree() -> void:
	if is_instance_valid(_camera) and _camera.compositor == _compositor:
		_camera.compositor = null
	_compositor = null
	_renderer = null
