@tool
extends RefCounted
## Per-view Volume evaluation and preparation cache.
##
## This object only knows the Volume and renderer protocols. It does not own a
## view, compositor, editor object, or renderer reference. Runtime owns one
## instance of this evaluator for each view.

const Resolver = preload("volume_resolver.gd")

var _signature: Array = []
var _recent: Array = []
var _prepared: Dictionary = {}

## Evaluate one view. `renderer` is intentionally untyped: only the renderer
## protocol (`get_instance_id`, `get_parameter_revision`, and
## `get_volume_context`) is needed. An unchanged signature returns `{}`; a
## changed signature returns the parameter and pass-state dictionaries to push.
##
func evaluate(volumes: Array, point: Vector3, renderer) -> Dictionary:
	var renderer_id: int = renderer.get_instance_id() if renderer != null else 0
	var renderer_revision: int = renderer.get_parameter_revision() if renderer != null else 0
	var configuration: Array = [renderer_id, renderer_revision]
	var signature: Array = [configuration]
	var influenced := false
	for volume in volumes:
		# A volume's spatial contribution is sampled exactly once. The same value
		# is used for the signature and for blending below.
		var influence: float = volume.influence_at(point)
		# Outside volumes do not hash profile data. An entry into the volume then
		# includes the current profile key before a cached preset can be reused.
		configuration.append(volume.evaluation_key() if influence > 0.0 else volume.get_instance_id())
		signature.append(influence)
		influenced = influenced or influence > 0.0

	if not _signature.is_empty() and _signature == signature:
		return {}

	# Two recent influence states cover fixed-preset enter/exit while bounding
	# the cache. `prepared` is one mutable dictionary reused for camera motion.
	var resolved: Dictionary = {}
	var found := false
	for cached in _recent:
		if cached.signature == signature:
			resolved = cached.resolved
			found = true
			break

	if not found:
		resolved = {"parameters": {}, "pass_states": {}}
		if influenced:
			# Build weights only after the signature changed. On the unchanged hot
			# path the influence samples above are the only per-volume work.
			var influences := {}
			for i in volumes.size():
				influences[volumes[i].get_instance_id()] = signature[i + 1]
			# Camera motion changes weights, not module fields or priority order.
			# Rebuild the preparation only when the renderer/volume configuration
			# changes; no context query is made on the stationary hot path.
			if _prepared.is_empty() or _prepared.configuration != configuration:
				var settings := {}
				for volume in volumes:
					if influences[volume.get_instance_id()] > 0.0:
						settings[volume.get_instance_id()] = volume.profile.get_parameters()
				_prepared = {
					"configuration": configuration,
					"context": renderer.get_volume_context() if renderer != null else {},
					"ordered": Resolver.ordered(volumes),
					"settings": settings,
				}
				_prepared.program = Resolver.compile(_prepared)
			# Update the single prepared dictionary in place for this sample.
			_prepared.influences = influences
			resolved = Resolver.evaluate_compiled(_prepared.program, influences)
		if _recent.size() == 2:
			_recent.pop_front()
		_recent.append({"signature": signature, "resolved": resolved})

	_signature = signature
	return resolved

func clear() -> void:
	_signature.clear()
	_recent.clear()
	_prepared.clear()
