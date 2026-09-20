@tool
class_name FengCompositor
extends Compositor
## Keeps the native schedule and custom effects synchronized with a renderer.

const Renderer = preload("renderer.gd")
const CompositorBinding = preload("pipeline/compositor_binding.gd")
const VolumeMetrics = preload("volume/volume_metrics.gd")
const ViewState = preload("pipeline/view_state.gd")

var _renderer: Renderer
var _apply_pending := false
var _view_state: RefCounted
var _volume_parameters := {}
var _volume_pass_states := {}
var _volume_apply_pending := false

@export var renderer: Renderer:
	get:
		return _renderer
	set(value):
		if _renderer == value:
			return
		if _renderer != null and _renderer.changed.is_connected(_on_renderer_changed):
			_renderer.changed.disconnect(_on_renderer_changed)
		_renderer = value
		_view_state = null
		if _renderer != null:
			_renderer.changed.connect(_on_renderer_changed)
		_apply()
		emit_changed()

func _apply() -> void:
	var measure := _volume_apply_pending
	_volume_apply_pending = false
	var started := Time.get_ticks_usec() if measure else 0
	_apply_renderer()
	if measure:
		VolumeMetrics.record(2, Time.get_ticks_usec() - started)

func _apply_renderer() -> void:
	_apply_pending = false
	if _renderer != null:
		if not _volume_parameters.is_empty() or not _volume_pass_states.is_empty():
			if _view_state == null:
				_view_state = ViewState.new()
			_view_state.apply(self, _renderer, _volume_parameters, _volume_pass_states)
		else:
			# Keep this camera's compiled effects warm while outside the Volume.
			# Crossing a boundary must not recreate every shader and GPU pipeline.
			_renderer.apply_volume(self, {}, {})
	else:
		CompositorBinding.clear(self)

func _on_renderer_changed() -> void:
	_view_state = null
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
	_volume_apply_pending = true
	if not _apply_pending:
		_apply_pending = true
		_apply.call_deferred()

func get_volume_parameters() -> Dictionary:
	return _volume_parameters.duplicate(true)

func get_volume_pass_states() -> Dictionary:
	return _volume_pass_states.duplicate()


func _validate_property(property: Dictionary) -> void:
	if property.name == "compositor_effects":
		# This array is derived from renderer.passes on every apply. Exposing it made
		# the Compositor asset look like a second editable pipeline: reordering or
		# toggling those generated effects is overwritten immediately and never
		# changes the FRP schedule. Do not serialize the derived copies either; the
		# renderer setter rebuilds them after load.
		property.usage = PROPERTY_USAGE_NONE
