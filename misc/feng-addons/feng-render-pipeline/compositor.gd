@tool
class_name FengCompositor
extends Compositor
## Keeps the native schedule and custom effects synchronized with a renderer.

const Renderer = preload("renderer.gd")
const CompositorBinding = preload("pipeline/compositor_binding.gd")

var _renderer: Renderer
var _apply_pending := false
var _runtime_renderer: Renderer
var _volume_parameters := {}
var _volume_pass_states := {}

@export var renderer: Renderer:
	get:
		return _renderer
	set(value):
		if _renderer == value:
			return
		if _renderer != null and _renderer.changed.is_connected(_on_renderer_changed):
			_renderer.changed.disconnect(_on_renderer_changed)
		_renderer = value
		_runtime_renderer = null
		if _renderer != null:
			_renderer.changed.connect(_on_renderer_changed)
		_apply()
		emit_changed()

func _apply() -> void:
	_apply_pending = false
	if _renderer != null:
		if not _volume_parameters.is_empty() or not _volume_pass_states.is_empty():
			if _runtime_renderer == null:
				# Isolate effect RIDs as well as values: shared pipelines must not let
				# one camera's Volume change another camera's pass enabled state.
				_runtime_renderer = _renderer.duplicate(true) as Renderer
			_runtime_renderer.set_volume_parameters(_volume_parameters, _volume_pass_states)
			_runtime_renderer.apply(self)
		else:
			# Keep this camera's compiled effects warm while outside the Volume.
			# Crossing a boundary must not recreate every shader and GPU pipeline.
			_renderer.apply(self)
	else:
		CompositorBinding.clear(self)

func _on_renderer_changed() -> void:
	_runtime_renderer = null
	# Coalesce nested property/undo notifications and finish resource loading
	# before applying. Never rebuild the list inside a render callback.
	if not _apply_pending:
		_apply_pending = true
		_apply.call_deferred()

## Pass parameter overrides a volume resolved for the camera using this compositor,
## plus the pass states it switches on or off (see FengVolume). The renderer layers
## them over the authored values.
func set_volume_parameters(parameters: Dictionary, pass_states: Dictionary = {}) -> void:
	if parameters == _volume_parameters and pass_states == _volume_pass_states:
		return
	_volume_parameters = parameters.duplicate(true)
	_volume_pass_states = pass_states.duplicate()
	if not _apply_pending:
		_apply_pending = true
		_apply.call_deferred()

func get_volume_parameters() -> Dictionary:
	return _volume_parameters.duplicate(true)

func get_volume_pass_states() -> Dictionary:
	return _volume_pass_states.duplicate()
