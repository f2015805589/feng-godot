@tool
class_name FengCompositor
extends Compositor
## Compositor that keeps its effects in sync with a FengRenderer.
##
## Assign renderer to drive compositor_effects; any change to the renderer
## resource (pass list edits, reordering) emits Resource.changed and triggers
## a re-apply. Pass.enabled toggles are applied natively by the engine and do
## not need a re-apply.

const Renderer = preload("renderer.gd")

var _renderer: Renderer

@export var renderer: Renderer:
	get:
		return _renderer
	set(value):
		if _renderer == value:
			return
		if _renderer != null and _renderer.is_connected("changed", _on_renderer_changed):
			_renderer.disconnect("changed", _on_renderer_changed)
		_renderer = value
		if _renderer != null:
			_renderer.connect("changed", _on_renderer_changed)
		_apply()

func _apply() -> void:
	if _renderer != null:
		_renderer.apply(self)

func _on_renderer_changed() -> void:
	_apply()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _renderer != null and _renderer.is_connected("changed", _on_renderer_changed):
		_renderer.disconnect("changed", _on_renderer_changed)
