@tool
class_name FMagicGIRuntime
extends RefCounted
## Static bridge between baked FMagicGIVolume nodes and the FRP Magic GI pass.
##
## Volumes publish on the main thread; the pass reads on the render thread. The
## handoff is a single swapped Dictionary (`bake_snapshot`) built once per bake:
## dictionaries are copy-on-write, so the render thread only ever sees a complete,
## frozen snapshot — either the previous bake or the new one, never a half-edit.
##
## The pass reaches this script by `load()`ing its res:// path at runtime instead
## of naming it, so the FRP addon keeps working when feng-magic-gi is absent.
const SCRIPT_PATH := "res://addons/feng-magic-gi/feng_magic_gi_runtime.gd"

static var _volumes: Dictionary = {}        # instance_id -> WeakRef
static var bake_snapshot: Dictionary = {}   # {data: FMagicGIData, version: int}

static func register(volume: FMagicGIVolume) -> void:
	_volumes[volume.get_instance_id()] = weakref(volume)
	_publish()

static func unregister(volume: FMagicGIVolume) -> void:
	_volumes.erase(volume.get_instance_id())
	_publish()

static func publish(volume: FMagicGIVolume) -> void:
	if not _volumes.has(volume.get_instance_id()):
		_volumes[volume.get_instance_id()] = weakref(volume)
	_publish()

## The most recently baked enabled volume wins. FMagicGI v1 applies exactly one
## volume per frame - layering several baked volumes is a follow-up.
static func _publish() -> void:
	var best: FMagicGIVolume = null
	for id in _volumes.keys():
		var volume: FMagicGIVolume = _volumes[id].get_ref()
		if volume == null:
			_volumes.erase(id)
			continue
		if not volume.is_inside_tree() or not volume.enabled or not volume.has_bake():
			continue
		if best == null or volume.bake_data.bake_version > best.bake_data.bake_version:
			best = volume
	var snapshot := {}
	if best != null:
		snapshot = {"data": best.bake_data, "version": best.bake_data.bake_version,
				"strength": best.gi_strength}
	bake_snapshot = snapshot
