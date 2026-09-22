# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# The plumbing the two VT layout previews share: the terrain they describe (held weakly), the one
# boolean that says whether there is anything to draw, and the poll interval that decides when to ask.
# What a preview does with that - the AVT sector scan, or the clipmap's two panels - stays in its own
# script, because that is the half that differs.
#
# It is a base *script* rather than a helper object because both previews are Controls that own their
# own visibility: a control that consulted a helper for `visible` would have two owners of one
# property. `asset_dock_common.gd` is the same shape for the two dock versions.
@tool
extends Control

## Emitted when the view starts or stops having something to draw. The host hides the heading and the
## description around this control with it; the host hides the *panel* the control lives in, never the
## control itself, because the control owns its own visibility.
signal availability_changed(p_available: bool)

## How long one poll's answer is trusted. The gate is one cheap question - whether a cell selects the
## method, or whether a ring exists - so polling it is affordable even while the view is hidden, while
## the expensive call each preview makes (a grid scan, a ring walk) waits for visibility inside the
## preview itself.
const POLL_INTERVAL_SEC := 0.20

var _terrain_ref: WeakRef
var _terrain_instance_id: int = 0
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
		_terrain_instance_id = p_terrain.get_instance_id()
	else:
		_terrain_ref = null
		_terrain_instance_id = 0
	_reset_preview_state()
	_last_poll_sec = -INF
	# The gate is answered once here as well, so a host that builds the control and hands it a terrain
	# does not show a view for a poll interval before the first timer tick hides it.
	_set_available(_terrain_ref != null and _gate(p_terrain))
	queue_redraw()


func _get_terrain() -> Object:
	if _terrain_ref == null:
		return null
	var terrain: Object = _terrain_ref.get_ref()
	if terrain == null or not is_instance_valid(terrain):
		return null
	if _terrain_instance_id != 0 and terrain.get_instance_id() != _terrain_instance_id:
		return null
	return terrain


func _set_available(p_available: bool) -> void:
	# `visible` is synced on every call rather than only on a change: a control whose initial state is
	# already "unavailable" has to be hidden by the first reading too, and it starts visible.
	visible = p_available
	if _available == p_available:
		return
	_available = p_available
	availability_changed.emit(p_available)


## Whether there is anything to draw for this terrain, which is the question each preview answers for
## itself and the one its host's heading depends on. Every subclass implements it, and the default
## refuses: a gate nobody wrote is a view with nothing behind it.
func _gate(_p_terrain: Object) -> bool:
	return false


## Drops what the subclass holds from the previous terrain. Called when a new one is handed over, so a
## host never draws the old terrain's layout over the new one's name.
func _reset_preview_state() -> void:
	pass
