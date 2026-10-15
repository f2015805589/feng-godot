@tool
extends RefCounted
## One GPU byte budget shared by every view rendered in an engine frame.
## The runtime owns CPU-page residency; this ledger owns only FRP GPU pages.

const Stream = preload("magic_gi_page_stream.gd")

var _entries: Dictionary = {}
var _active: Dictionary = {}
var _clock := 0
var _resident_bytes := 0
var _uploaded_this_frame := 0
var _allocations_this_frame := 0
var _frame_token := -1
var _gpu_budget_bytes := Stream.GPU_RESIDENT_BUDGET_BYTES
var _upload_budget_bytes := Stream.GPU_UPLOAD_BUDGET_BYTES_PER_FRAME
var _reserved_bytes := Stream.GPU_GLOBAL_RESERVE_BYTES
var _allocation_budget := 4


func begin_frame(frame_token := -1, gpu_budget_bytes := Stream.GPU_RESIDENT_BUDGET_BYTES,
		upload_budget_bytes := Stream.GPU_UPLOAD_BUDGET_BYTES_PER_FRAME,
		reserved_bytes := Stream.GPU_GLOBAL_RESERVE_BYTES, allocation_budget := 4,
		active_keys := PackedStringArray()) -> PackedStringArray:
	if frame_token < 0:
		frame_token = _frame_token + 1
	var new_frame := frame_token != _frame_token
	if new_frame:
		_frame_token = frame_token
		_clock += 1
		_uploaded_this_frame = 0
		_allocations_this_frame = 0
		_active.clear()
	for key in active_keys:
		if _entries.has(String(key)):
			_active[String(key)] = true
	# Multiple views can publish distinct limits during the same frame. Honor the
	# tightest snapshot instead of resetting/raising the global page allowance.
	_gpu_budget_bytes = mini(_gpu_budget_bytes, maxi(0, gpu_budget_bytes)) if not new_frame \
			else maxi(0, gpu_budget_bytes)
	_upload_budget_bytes = mini(_upload_budget_bytes, maxi(0, upload_budget_bytes)) if not new_frame \
			else maxi(0, upload_budget_bytes)
	_reserved_bytes = maxi(_reserved_bytes, maxi(0, reserved_bytes)) if not new_frame \
			else maxi(0, reserved_bytes)
	_allocation_budget = mini(_allocation_budget, maxi(0, allocation_budget)) if not new_frame \
			else maxi(0, allocation_budget)
	# A budget can shrink between frames or between two views in one frame. Trim
	# every inactive page we can now, and return the exact keys so the RenderingDevice
	# owner can release their RIDs in the same safe render-thread turn. Entries used
	# earlier in this frame remain protected; if they alone exceed the new budget,
	# admission applies backpressure until the next frame can retire them.
	return _trim_inactive_to_budget()


func effective_gpu_budget_bytes() -> int:
	return maxi(0, _gpu_budget_bytes - _reserved_bytes)


func admit(key: String, page_key: String, gpu_bytes: int) -> Dictionary:
	var budget := effective_gpu_budget_bytes()
	if key.is_empty() or gpu_bytes <= 0 or gpu_bytes > budget:
		return {"admitted": false, "evicted": PackedStringArray()}
	if _entries.has(key):
		var existing: Dictionary = _entries[key]
		existing["last_used"] = _clock
		_entries[key] = existing
		_active[key] = true
		return {"admitted": true, "existing": true, "evicted": PackedStringArray()}
	var evicted := PackedStringArray()
	while _resident_bytes + gpu_bytes > budget:
		var oldest_key := ""
		var oldest := 0x7fffffff
		for candidate in _entries:
			if _active.has(candidate):
				continue
			var candidate_entry: Dictionary = _entries[candidate]
			if int(candidate_entry.get("last_used", 0)) < oldest:
				oldest = int(candidate_entry.get("last_used", 0))
				oldest_key = str(candidate)
		if oldest_key.is_empty():
			return {"admitted": false, "evicted": evicted}
		var retired: Dictionary = _entries[oldest_key]
		_resident_bytes -= int(retired.get("gpu_bytes", 0))
		_entries.erase(oldest_key)
		evicted.append(oldest_key)
	_entries[key] = {"page_key": page_key, "gpu_bytes": gpu_bytes,
		"last_used": _clock, "state": "uploading", "ready": false}
	_resident_bytes += gpu_bytes
	_active[key] = true
	return {"admitted": true, "existing": false, "evicted": evicted}


func _trim_inactive_to_budget() -> PackedStringArray:
	var evicted := PackedStringArray()
	var budget := effective_gpu_budget_bytes()
	while _resident_bytes > budget:
		var oldest_key := ""
		var oldest := 0x7fffffff
		for candidate in _entries:
			if _active.has(candidate):
				continue
			var candidate_entry: Dictionary = _entries[candidate]
			var last_used := int(candidate_entry.get("last_used", 0))
			if last_used < oldest:
				oldest = last_used
				oldest_key = str(candidate)
		if oldest_key.is_empty():
			break
		var retired: Dictionary = _entries[oldest_key]
		_resident_bytes -= int(retired.get("gpu_bytes", 0))
		_entries.erase(oldest_key)
		evicted.append(oldest_key)
	return evicted


func is_ready(key: String) -> bool:
	return _entries.has(key) and bool(_entries[key].get("ready", false))


func mark_ready(key: String) -> void:
	if not _entries.has(key):
		return
	var entry: Dictionary = _entries[key]
	entry["ready"] = true
	entry["state"] = "ready"
	entry["last_used"] = _clock
	_entries[key] = entry


## Correct a page reservation after the optional probe-cluster buffer falls back
## to its disabled header. This path only permits reducing an existing charge.
func reduce_gpu_bytes(key: String, new_gpu_bytes: int) -> bool:
	if not _entries.has(key) or new_gpu_bytes <= 0:
		return false
	var entry: Dictionary = _entries[key]
	var old_gpu_bytes := int(entry.get("gpu_bytes", 0))
	if new_gpu_bytes > old_gpu_bytes:
		return false
	_resident_bytes = maxi(0, _resident_bytes - old_gpu_bytes + new_gpu_bytes)
	entry["gpu_bytes"] = new_gpu_bytes
	_entries[key] = entry
	return true


func touch(key: String) -> void:
	if not _entries.has(key):
		return
	var entry: Dictionary = _entries[key]
	entry["last_used"] = _clock
	_entries[key] = entry
	_active[key] = true


func account_upload(byte_count: int) -> bool:
	if byte_count < 0 or byte_count > _upload_budget_bytes \
			or _uploaded_this_frame + byte_count > _upload_budget_bytes:
		return false
	_uploaded_this_frame += byte_count
	return true


func allocation_budget_remaining() -> int:
	return maxi(0, _allocation_budget - _allocations_this_frame)


func account_allocations(count: int) -> bool:
	if count < 0 or count > allocation_budget_remaining():
		return false
	_allocations_this_frame += count
	return true


func remove(key: String) -> bool:
	if not _entries.has(key):
		return false
	var entry: Dictionary = _entries[key]
	_resident_bytes = maxi(0, _resident_bytes - int(entry.get("gpu_bytes", 0)))
	_entries.erase(key)
	_active.erase(key)
	return true


func entry(key: String) -> Dictionary:
	return _entries.get(key, {}).duplicate()


func resident_bytes() -> int:
	return _resident_bytes


func over_budget_bytes() -> int:
	return maxi(0, _resident_bytes - effective_gpu_budget_bytes())


func upload_bytes_this_frame() -> int:
	return _uploaded_this_frame


func upload_budget_remaining() -> int:
	return maxi(0, _upload_budget_bytes - _uploaded_this_frame)


func resident_keys() -> PackedStringArray:
	var result := PackedStringArray()
	for key in _entries:
		result.append(str(key))
	result.sort()
	return result
