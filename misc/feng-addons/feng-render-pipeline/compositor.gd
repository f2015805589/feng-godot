@tool
class_name FengCompositor
extends Compositor
## Keeps the native schedule and custom effects synchronized with a renderer.

const Renderer = preload("renderer.gd")

var _renderer: Renderer
var _apply_pending := false

@export var renderer: Renderer:
	get:
		return _renderer
	set(value):
		if _renderer == value:
			return
		if _renderer != null and _renderer.changed.is_connected(_on_renderer_changed):
			_renderer.changed.disconnect(_on_renderer_changed)
		_renderer = value
		if _renderer != null:
			_renderer.changed.connect(_on_renderer_changed)
		_apply()
		emit_changed()

func _apply() -> void:
	_apply_pending = false
	if _renderer != null:
		_renderer.apply(self)
	else:
		if RenderingServer.has_method("compositor_set_frp_pipeline"):
			RenderingServer.call("compositor_set_frp_pipeline", get_rid(), PackedInt32Array())
		compositor_effects = []

func _on_renderer_changed() -> void:
	# Coalesce nested property/undo notifications and finish resource loading
	# before applying. Never rebuild the list inside a render callback.
	if not _apply_pending:
		_apply_pending = true
		_apply.call_deferred()

## Pass parameter overrides a volume resolved for the camera using this compositor,
## plus the pass states it switches on or off (see FengVolume). The renderer layers
## them over the authored values.
func set_volume_parameters(parameters: Dictionary, pass_states: Dictionary = {}) -> void:
	if _renderer == null:
		return
	_renderer.set_volume_parameters(parameters, pass_states)
