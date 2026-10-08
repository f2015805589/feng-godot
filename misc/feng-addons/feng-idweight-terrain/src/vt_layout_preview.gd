# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Shared weak terrain reference, availability and polling policy for VT layout previews.
@tool
extends Control

## Hosts follow availability for their surrounding panel; this control owns its visibility.
signal availability_changed(p_available: bool)

## Poll cheap availability queries while hidden; subclasses defer layout reads until visible.
const POLL_INTERVAL_SEC := 0.20

var _terrain_ref: WeakRef
var _available := false
var _last_poll_sec := -INF


## Whether the view has something to draw. The host reads it to decide whether the heading around this
## control is worth showing at all.
func is_available() -> bool:
	return _available


## Keep only a weak reference: an Inspector control can outlive the node it describes while the scene
## is being reloaded.
func set_terrain(p_terrain: Object) -> void:
	if p_terrain != null and is_instance_valid(p_terrain):
		_terrain_ref = weakref(p_terrain)
	else:
		_terrain_ref = null
	_reset_preview_state()
	_last_poll_sec = -INF
	# The gate is answered once here as well, so a host that builds the control and hands it a terrain
	# does not show a view for a poll interval before the first timer tick hides it.
	_set_available(_terrain_ref != null and _gate(p_terrain))
	queue_redraw()


func _get_terrain() -> Object:
	if _terrain_ref == null:
		return null
	return _terrain_ref.get_ref()


func _set_available(p_available: bool) -> void:
	# `visible` is synced on every call rather than only on a change: a control whose initial state is
	# already "unavailable" has to be hidden by the first reading too, and it starts visible.
	visible = p_available
	if _available == p_available:
		return
	_available = p_available
	availability_changed.emit(p_available)


## Subclasses decide whether a layout exists; the default hides the preview.
func _gate(_p_terrain: Object) -> bool:
	return false


## Drops what the subclass holds from the previous terrain. Called when a new one is handed over, so a
## host never draws the old terrain's layout over the new one's name.
func _reset_preview_state() -> void:
	pass
