@tool
class_name FengReflectProbeRuntime
extends RefCounted
## Thread-safe immutable render packets. Cubemap packets carry an opaque lease that
## keeps the assigned Resource alive; render code may only retain or drop that lease.

class ExternalSourceLease extends RefCounted:
	var _source: Resource

	func _init(source: Resource) -> void:
		_source = source

static var _mutex := Mutex.new()
static var _probes_by_target: Dictionary = {} # render target RID -> {owner id: snapshot}
static var _external_sources: Dictionary = {} # owner id -> latest values plus opaque source lease
static var _completed_capture_snapshots: Dictionary = {} # owner id -> latest complete scene cube values
static var _capture_by_target: Dictionary = {} # render target RID -> immutable capture state
static var _capture_status: Dictionary = {} # owner id -> capture progress and owned output RIDs
static var _bake_payloads: Dictionary = {} # owner id -> six RGBAH byte arrays

static func publish_probe(target: RID, owner_id: int, snapshot: Dictionary) -> void:
	if not target.is_valid() or owner_id <= 0 or snapshot.is_empty():
		return
	_mutex.lock()
	var probes: Dictionary = _probes_by_target.get(target, {})
	probes[owner_id] = snapshot.duplicate(true)
	_probes_by_target[target] = probes
	_mutex.unlock()

## Merge owner-authored transforms/settings into the last complete published version.
## Omitting radiance_rid preserves the old cubemap while a replacement is captured.
static func update_probe_targets(targets: Array, owner_id: int, metadata: Dictionary) -> void:
	if owner_id <= 0 or metadata.is_empty():
		return
	_mutex.lock()
	for target_value in targets:
		if not target_value is RID or not target_value.is_valid():
			continue
		var probes: Dictionary = _probes_by_target.get(target_value, {})
		var snapshot: Dictionary = probes.get(owner_id, {}).duplicate(true)
		if String(metadata.get("source_mode", "")) == "scene_capture":
			var completed: Dictionary = _completed_capture_snapshots.get(owner_id, {})
			if _is_completed_scene_capture(completed):
				snapshot.merge(completed, true)
			else:
				# A previous external source may still be present in this target's
				# snapshot. Scene mode may use only a completed scene capture or its
				# separately tagged saved seed, never that stale RID.
				for key in ["radiance_rid", "ready_generation", "source_faces", "source_size",
						"capture_position", "source_basis"]:
					snapshot.erase(key)
		if not bool(metadata.get("has_saved_seed", false)):
			snapshot.erase("saved_seed_size")
			snapshot.erase("saved_seed_revision")
		snapshot.merge(metadata, true)
		probes[owner_id] = snapshot
		_probes_by_target[target_value] = probes
	_mutex.unlock()

## Swap a fully filtered cube into every target route in one critical section.
static func publish_probe_targets(targets: Array, owner_id: int, snapshot: Dictionary) -> void:
	if owner_id <= 0 or snapshot.is_empty():
		return
	_mutex.lock()
	for target_value in targets:
		if not target_value is RID or not target_value.is_valid():
			continue
		var probes: Dictionary = _probes_by_target.get(target_value, {})
		var merged: Dictionary = probes.get(owner_id, {}).duplicate(true)
		merged.merge(snapshot, true)
		probes[owner_id] = merged
		_probes_by_target[target_value] = probes
	_mutex.unlock()

## Atomically accepts a completed capture only while its target still owns the same
## active batch. Disabling or replacing a batch removes/changes that lease first.
static func publish_capture_probe_targets(capture_target: RID, targets: Array, owner_id: int,
			batch_id: int, snapshot: Dictionary) -> bool:
	if not capture_target.is_valid() or owner_id <= 0 or batch_id <= 0 or snapshot.is_empty():
		return false
	_mutex.lock()
	var capture_value: Dictionary = _capture_by_target.get(capture_target, {})
	if not bool(capture_value.get("active", false)) \
			or int(capture_value.get("owner_id", -1)) != owner_id \
			or int(capture_value.get("batch_id", -1)) != batch_id:
		_mutex.unlock()
		return false
	_completed_capture_snapshots[owner_id] = snapshot.duplicate(true)
	for target_value in targets:
		if not target_value is RID or not target_value.is_valid():
			continue
		var probes: Dictionary = _probes_by_target.get(target_value, {})
		if not probes.has(owner_id):
			continue
		var merged: Dictionary = probes.get(owner_id, {}).duplicate(true)
		merged.merge(snapshot, true)
		probes[owner_id] = merged
		_probes_by_target[target_value] = probes
	_mutex.unlock()
	return true

static func has_probe_owner(target: RID, owner_id: int) -> bool:
	if not target.is_valid() or owner_id <= 0:
		return false
	_mutex.lock()
	var probes: Dictionary = _probes_by_target.get(target, {})
	var found := probes.has(owner_id)
	_mutex.unlock()
	return found

static func remove_probe_targets(targets: Array, owner_id: int) -> void:
	if owner_id <= 0:
		return
	_mutex.lock()
	for target_value in targets:
		if not target_value is RID or not target_value.is_valid():
			continue
		var probes: Dictionary = _probes_by_target.get(target_value, {})
		probes.erase(owner_id)
		if probes.is_empty():
			_probes_by_target.erase(target_value)
		else:
			_probes_by_target[target_value] = probes
	_mutex.unlock()

static func remove_completed_capture(owner_id: int) -> void:
	if owner_id <= 0:
		return
	_mutex.lock()
	_completed_capture_snapshots.erase(owner_id)
	_mutex.unlock()

static func completed_scene_capture_for_owner(owner_id: int) -> Dictionary:
	if owner_id <= 0:
		return {}
	_mutex.lock()
	var value: Dictionary = _completed_capture_snapshots.get(owner_id, {})
	var result: Dictionary = value.duplicate(true) if _is_completed_scene_capture(value) else {}
	_mutex.unlock()
	return result

static func _is_completed_scene_capture(value: Dictionary) -> bool:
	if String(value.get("source_mode", "")) != "scene_capture" \
			or int(value.get("ready_generation", 0)) <= 0:
		return false
	var radiance: Variant = value.get("radiance_rid", RID())
	return radiance is RID and radiance.is_valid()

static func create_external_source_lease(source: Resource) -> RefCounted:
	if source == null or not is_instance_valid(source):
		return null
	return ExternalSourceLease.new(source)

## The latest external packet is shared by owner instead of copied into every
## viewport snapshot. Primitive values are immutable; source_lease only extends
## the source Resource lifetime and is never inspected by render code.
static func publish_external_source(owner_id: int, packet: Dictionary) -> bool:
	var revision := int(packet.get("revision", -1))
	var size := int(packet.get("size", 0))
	var source_rid: Variant = packet.get("source_rid", RID())
	var source_lease: Variant = packet.get("source_lease", null)
	if owner_id <= 0 or revision < 0 or size <= 0 or not source_rid is RID \
			or not source_rid.is_valid() or not source_lease is RefCounted:
		return false
	_mutex.lock()
	var previous: Dictionary = _external_sources.get(owner_id, {})
	if int(previous.get("revision", -1)) == revision \
			and String(previous.get("source_kind", "external_cubemap")) \
			== String(packet.get("source_kind", "external_cubemap")):
		_mutex.unlock()
		return true
	_external_sources[owner_id] = packet.duplicate(false)
	_mutex.unlock()
	return true

static func external_source_for_owner(owner_id: int) -> Dictionary:
	_mutex.lock()
	var result: Dictionary = _external_sources.get(owner_id, {}).duplicate(false)
	_mutex.unlock()
	return result

static func remove_external_source(owner_id: int) -> void:
	if owner_id <= 0:
		return
	_mutex.lock()
	_external_sources.erase(owner_id)
	_mutex.unlock()

static func remove_probe(target: RID, owner_id: int) -> void:
	remove_probe_targets([target], owner_id)

static func snapshots_for_target(target: RID) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	_mutex.lock()
	var probes: Dictionary = _probes_by_target.get(target, {})
	for owner_id in probes:
		var value: Dictionary = probes[owner_id]
		if not value.is_empty():
			result.append(value.duplicate(true))
	_mutex.unlock()
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left := int(a.get("priority", 0))
		var right := int(b.get("priority", 0))
		return left > right if left != right else int(a.get("owner_id", 0)) < int(b.get("owner_id", 0)))
	return result

static func publish_capture_target(target: RID, snapshot: Dictionary) -> void:
	if not target.is_valid() or snapshot.is_empty():
		return
	_mutex.lock()
	_capture_by_target[target] = snapshot.duplicate(true)
	_mutex.unlock()

static func remove_capture_target(target: RID, owner_id: int) -> void:
	_mutex.lock()
	var value: Dictionary = _capture_by_target.get(target, {})
	if int(value.get("owner_id", -1)) == owner_id:
		_capture_by_target.erase(target)
	_mutex.unlock()

static func capture_snapshot_for_target(target: RID) -> Dictionary:
	_mutex.lock()
	var result: Dictionary = _capture_by_target.get(target, {}).duplicate(true)
	_mutex.unlock()
	return result

static func is_capture_current(target: RID, owner_id: int, batch_id: int, step: int = -1) -> bool:
	if not target.is_valid() or owner_id <= 0 or batch_id <= 0:
		return false
	_mutex.lock()
	var value: Dictionary = _capture_by_target.get(target, {})
	var matches := bool(value.get("active", false)) \
			and int(value.get("owner_id", -1)) == owner_id \
			and int(value.get("batch_id", -1)) == batch_id \
			and (step < 0 or int(value.get("step", -1)) == step)
	_mutex.unlock()
	return matches

static func publish_capture_status(owner_id: int, status: Dictionary) -> void:
	if owner_id <= 0:
		return
	_mutex.lock()
	_capture_status[owner_id] = status.duplicate(true)
	_mutex.unlock()

static func complete_capture_step(owner_id: int, batch_id: int, step: int,
			patch: Dictionary = {}) -> void:
	if owner_id <= 0 or batch_id <= 0 or step < 0:
		return
	_mutex.lock()
	var status: Dictionary = _capture_status.get(owner_id, {}).duplicate(true)
	# Only the owner can start a batch; late callbacks cannot resurrect it.
	if int(status.get("batch_id", -1)) == batch_id:
		status["batch_id"] = batch_id
		status["completed_step"] = step
		status.merge(patch, true)
		_capture_status[owner_id] = status
	_mutex.unlock()

static func capture_status_for_owner(owner_id: int) -> Dictionary:
	_mutex.lock()
	var result: Dictionary = _capture_status.get(owner_id, {}).duplicate(true)
	_mutex.unlock()
	return result

static func remove_capture_owner(owner_id: int) -> void:
	_mutex.lock()
	_capture_status.erase(owner_id)
	_bake_payloads.erase(owner_id)
	for target in _capture_by_target.keys():
		var value: Dictionary = _capture_by_target[target]
		if int(value.get("owner_id", -1)) == owner_id:
			_capture_by_target.erase(target)
	_mutex.unlock()

## Called by RenderingDevice's async readback callback. This stores only bytes and
## integers under the runtime mutex; no scene object or Resource crosses threads.
static func publish_bake_face(bytes: PackedByteArray, owner_id: int, batch_id: int,
			face: int) -> void:
	if owner_id <= 0 or batch_id <= 0 or face < 0 or face >= 6 or bytes.is_empty():
		return
	_mutex.lock()
	var status: Dictionary = _capture_status.get(owner_id, {})
	if int(status.get("batch_id", -1)) != batch_id:
		_mutex.unlock()
		return
	var state: Dictionary = _bake_payloads.get(owner_id, {}).duplicate(true)
	if int(state.get("batch_id", -1)) != batch_id:
		var empty_faces: Array[PackedByteArray] = []
		empty_faces.resize(6)
		state = {"batch_id": batch_id, "faces": empty_faces, "mask": 0, "complete": false}
	var faces: Array = state["faces"]
	faces[face] = bytes
	state["faces"] = faces
	state["mask"] = int(state.get("mask", 0)) | (1 << face)
	state["complete"] = int(state["mask"]) == 63
	_bake_payloads[owner_id] = state
	_mutex.unlock()

static func take_bake_payload(owner_id: int) -> Dictionary:
	_mutex.lock()
	var result: Dictionary = _bake_payloads.get(owner_id, {}).duplicate(true)
	if bool(result.get("complete", false)):
		_bake_payloads.erase(owner_id)
	else:
		result = {}
	_mutex.unlock()
	return result
