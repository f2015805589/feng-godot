@tool
extends RefCounted
class_name FengEditorPreviewExposureCache
## Small editor-only bridge for preview shaders that need Eye Adaptation's
## per-render-target exposure scale. Values are sampled asynchronously so the
## render thread never stalls for editor diagnostics.

const SCALE_OFFSET_BYTES := 64 * 8 + 4
const MAX_SCALE_AGE_USEC := 500000
const MAX_EDITOR_VIEWPORTS := 4

static var _mutex := Mutex.new()
static var _targets: Dictionary = {}
static var _viewports: Dictionary = {}
static var _preview_owners: Dictionary = {}
static var _snapshots: Dictionary = {}
static var _inflight: Dictionary = {}
static var _target_epochs: Dictionary = {}
static var _next_token := 1
static var _sequence := 0

static func register_editor_viewport(viewport: Viewport, owner: Object) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	var viewport_id := viewport.get_instance_id()
	var owner_id := owner.get_instance_id() if owner != null and is_instance_valid(owner) else viewport_id
	var target := RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
	if not target.is_valid():
		return
	var target_id := target.get_id()
	_mutex.lock()
	var previous: Dictionary = _viewports.get(viewport_id, {})
	var previous_target := int(previous.get("target_id", 0))
	if previous_target != 0 and previous_target != target_id:
		_remove_viewport_owner_locked(previous_target, viewport_id, owner_id)
	if previous_target == 0 and not _targets.has(target_id) and _targets.size() >= MAX_EDITOR_VIEWPORTS:
		_mutex.unlock()
		return
	var target_entry: Dictionary = _targets.get(target_id, {})
	if target_entry.is_empty():
		target_entry = {"wr": weakref(viewport), "viewport_id": viewport_id, "owners": {}}
	target_entry["wr"] = weakref(viewport)
	target_entry["viewport_id"] = viewport_id
	var owners: Dictionary = target_entry.get("owners", {})
	owners[owner_id] = true
	target_entry["owners"] = owners
	_targets[target_id] = target_entry
	_viewports[viewport_id] = {"target_id": target_id, "wr": weakref(viewport), "owners": owners}
	_target_epochs[target_id] = int(_target_epochs.get(target_id, 0)) + 1 if previous_target != target_id else int(_target_epochs.get(target_id, 0))
	_mutex.unlock()

static func target_id_for_viewport(viewport: Viewport) -> int:
	if viewport == null or not is_instance_valid(viewport):
		return 0
	var target := RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())
	return target.get_id() if target.is_valid() else 0

static func unregister_editor_viewport(viewport: Viewport, owner: Object) -> void:
	if viewport == null or not is_instance_valid(viewport):
		return
	var viewport_id := viewport.get_instance_id()
	var owner_id := owner.get_instance_id() if owner != null and is_instance_valid(owner) else viewport_id
	_mutex.lock()
	var entry: Dictionary = _viewports.get(viewport_id, {})
	var target_id := int(entry.get("target_id", 0))
	if target_id != 0:
		_remove_viewport_owner_locked(target_id, viewport_id, owner_id)
	_mutex.unlock()

static func _remove_viewport_owner_locked(target_id: int, viewport_id: int, owner_id: int) -> void:
	var target_entry: Dictionary = _targets.get(target_id, {})
	var owners: Dictionary = target_entry.get("owners", {})
	owners.erase(owner_id)
	if owners.is_empty():
		_targets.erase(target_id)
		_invalidate_target_locked(target_id)
	else:
		target_entry["owners"] = owners
		_targets[target_id] = target_entry
	var viewport_entry: Dictionary = _viewports.get(viewport_id, {})
	var viewport_owners: Dictionary = viewport_entry.get("owners", {})
	viewport_owners.erase(owner_id)
	if viewport_owners.is_empty():
		_viewports.erase(viewport_id)
	else:
		viewport_entry["owners"] = viewport_owners
		_viewports[viewport_id] = viewport_entry

static func refresh_editor_viewport(viewport: Viewport, owner: Object) -> void:
	register_editor_viewport(viewport, owner)

static func set_preview_requested(owner_id: int, requested: bool) -> void:
	_mutex.lock()
	if requested:
		_preview_owners[owner_id] = true
	else:
		_preview_owners.erase(owner_id)
	if _preview_owners.is_empty():
		for target_id in _targets.keys():
			_invalidate_target_locked(int(target_id))
	_mutex.unlock()

static func should_sample(target: RID, view: int) -> bool:
	if not target.is_valid() or view < 0:
		return false
	var target_id := target.get_id()
	_mutex.lock()
	if _preview_owners.is_empty():
		_mutex.unlock()
		return false
	_prune_dead_targets_locked()
	var enabled := _targets.has(target_id)
	_mutex.unlock()
	return enabled

static func request_scale_readback(rd: RenderingDevice, buffer: RID, target: RID,
		view: int, producer: Object) -> Error:
	if rd == null or not buffer.is_valid() or not target.is_valid() \
			or producer == null or not is_instance_valid(producer) \
			or view < 0 or view >= MAX_EDITOR_VIEWPORTS:
		return ERR_INVALID_PARAMETER
	var target_id := target.get_id()
	var key := _cache_key(target_id, view)
	var token := 0
	var epoch := 0
	_mutex.lock()
	_prune_dead_targets_locked()
	if _preview_owners.is_empty() or not _targets.has(target_id):
		_mutex.unlock()
		return ERR_UNAVAILABLE
	if _inflight.has(key):
		_mutex.unlock()
		return OK
	token = _next_token
	_next_token += 1
	epoch = int(_target_epochs.get(target_id, 0))
	_inflight[key] = {"token": token, "epoch": epoch, "producer_id": producer.get_instance_id(),
			"target_id": target_id}
	_mutex.unlock()
	var callback := Callable(FengEditorPreviewExposureCache, "_finish_scale_readback").bind(
			weakref(producer), target_id, view, token, epoch)
	var error := rd.buffer_get_data_async(buffer, callback, SCALE_OFFSET_BYTES, 4)
	if error != OK:
		_mutex.lock()
		var pending: Dictionary = _inflight.get(key, {})
		if int(pending.get("token", 0)) == token:
			_inflight.erase(key)
		_mutex.unlock()
	return error

static func _finish_scale_readback(data: PackedByteArray, producer_ref: WeakRef,
		target_id: int, view: int, token: int, epoch: int) -> void:
	var producer: Object = producer_ref.get_ref() if producer_ref != null else null
	var scale := data.decode_float(0) if data.size() >= 4 else 0.0
	var key := _cache_key(target_id, view)
	_mutex.lock()
	var pending: Dictionary = _inflight.get(key, {})
	var valid := int(pending.get("token", 0)) == token \
			and int(pending.get("epoch", -1)) == epoch \
			and producer != null and is_instance_valid(producer) \
			and bool(producer.get("enabled")) \
			and int(pending.get("producer_id", 0)) == producer.get_instance_id() \
			and not _preview_owners.is_empty() and _targets.has(target_id) \
			and is_finite(scale) and scale > 0.0
	if int(pending.get("token", 0)) == token:
		_inflight.erase(key)
	if valid:
		_sequence += 1
		_snapshots[key] = {
			"target_id": target_id,
			"view": view,
			"exposure_scale": scale,
			"sequence": _sequence,
			"producer_id": producer.get_instance_id(),
			"producer_ref": weakref(producer),
			"published_usec": Time.get_ticks_usec(),
		}
	_mutex.unlock()

static func get_snapshot(target_id: int, view: int) -> Dictionary:
	var key := _cache_key(target_id, view)
	_mutex.lock()
	var stored: Dictionary = _snapshots.get(key, {})
	var producer_ref: WeakRef = stored.get("producer_ref", null)
	var producer: Object = producer_ref.get_ref() if producer_ref != null else null
	var producer_active := producer != null and is_instance_valid(producer) \
			and bool(producer.get("enabled"))
	if not stored.is_empty() and not producer_active:
		_invalidate_target_locked(target_id)
	var stale := stored.is_empty() or not producer_active or not _targets.has(target_id) \
			or _preview_owners.is_empty() \
			or Time.get_ticks_usec() - int(stored.get("published_usec", 0)) > MAX_SCALE_AGE_USEC
	if stale:
		_snapshots.erase(key)
	else:
		stored = stored.duplicate()
		stored["valid"] = true
	_mutex.unlock()
	if stale:
		return {"target_id": target_id, "view": view, "valid": false,
			"exposure_scale": 1.0, "sequence": 0}
	return stored

static func retire_producer(producer_id: int) -> void:
	_mutex.lock()
	for key in _snapshots.keys():
		if int(_snapshots[key].get("producer_id", 0)) == producer_id:
			_snapshots.erase(key)
	for key in _inflight.keys():
		if int(_inflight[key].get("producer_id", 0)) == producer_id:
			_inflight.erase(key)
	_mutex.unlock()

static func _prune_dead_targets_locked() -> void:
	for target_id in _targets.keys():
		var entry: Dictionary = _targets[target_id]
		var viewport: Object = entry.get("wr", null).get_ref() if entry.get("wr", null) is WeakRef else null
		if viewport == null or not is_instance_valid(viewport):
			_viewports.erase(int(entry.get("viewport_id", 0)))
			_targets.erase(target_id)
			_invalidate_target_locked(int(target_id))

static func _invalidate_target_locked(target_id: int) -> void:
	_target_epochs[target_id] = int(_target_epochs.get(target_id, 0)) + 1
	for key in _snapshots.keys():
		if int(_snapshots[key].get("target_id", 0)) == target_id:
			_snapshots.erase(key)
	for key in _inflight.keys():
		if int(_inflight[key].get("target_id", 0)) == target_id:
			_inflight.erase(key)

static func _cache_key(target_id: int, view: int) -> String:
	return "%d:%d" % [target_id, view]
