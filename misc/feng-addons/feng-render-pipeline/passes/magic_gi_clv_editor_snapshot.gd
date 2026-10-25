@tool
extends RefCounted
## Explicit editor-only requests for the actual prepared CLV resident field.
## Requests/results cross the main/render threads under a mutex. GPU bytes are
## decoded on a worker; ordinary rendering never reads back or solves SH here.

static var _mutex := Mutex.new()
static var _requests: Dictionary = {}
static var _snapshots: Dictionary = {}
static var _tasks: Array[int] = []
static var _reap_scheduled := false
static var _serial := 0
static var _revision := 0

static func set_request(volume_id: int, enabled: bool, include_sh := true,
		interval_msec := 500, target_id := 0) -> void:
	_reap_completed_tasks()
	# Object.get_instance_id() is a signed int64 and may be negative; only zero
	# is reserved as the "no owner" sentinel in this editor-only broker.
	if volume_id == 0:
		return
	_mutex.lock()
	if not enabled:
		_requests.erase(volume_id)
		_snapshots.erase(volume_id)
		_mutex.unlock()
		return
	var interval := maxi(250, interval_msec)
	var previous: Dictionary = _requests.get(volume_id, {})
	if not previous.is_empty() and bool(previous.include_sh) == include_sh \
			and int(previous.target_id) == target_id and int(previous.interval_msec) == interval:
		_mutex.unlock()
		return
	_serial += 1
	_requests[volume_id] = {"epoch": _serial, "include_sh": include_sh,
		"target_id": target_id, "interval_msec": interval, "last_enqueue_msec": -interval,
		"pending_token": 0, "completed_key": "", "status": "waiting_for_current_clv"}
	_snapshots.erase(volume_id)
	_mutex.unlock()

static func has_requests() -> bool:
	_mutex.lock()
	var requested := not _requests.is_empty()
	_mutex.unlock()
	return requested

static func has_request(volume_id: int, target_id: int) -> bool:
	_mutex.lock()
	var request: Dictionary = _requests.get(volume_id, {})
	var requested := not request.is_empty() and int(request.target_id) in [0, target_id]
	_mutex.unlock()
	return requested

static func get_status(volume_id: int) -> Dictionary:
	_reap_completed_tasks()
	_mutex.lock()
	var request: Dictionary = _requests.get(volume_id, {})
	var snapshot: Dictionary = _snapshots.get(volume_id, {})
	var result := {"requested": not request.is_empty(),
		"pending": int(request.get("pending_token", 0)) != 0,
		"status": request.get("status", "disabled"),
		"revision": int(snapshot.get("revision", 0)),
		"current_available": bool(snapshot.get("current_available", false)),
		"layout_key": snapshot.get("layout_key", ""),
		"target_id": snapshot.get("target_id", request.get("target_id", 0))}
	_mutex.unlock()
	return result

static func get_snapshot(volume_id: int) -> Dictionary:
	_reap_completed_tasks()
	_mutex.lock()
	var result: Dictionary = _snapshots.get(volume_id, {}).duplicate(true)
	_mutex.unlock()
	return result

## Render-thread producer handshake. No metadata copies or readback until a
## request's target/revision/throttle admit this frame. Only one read is in flight.
static func claim(volume_id: int, target_id: int, layout_key: String,
		relight_revision: int, clipmap_revision: int) -> Dictionary:
	_mutex.lock()
	var request: Dictionary = _requests.get(volume_id, {})
	if request.is_empty() or not int(request.target_id) in [0, target_id]:
		_mutex.unlock()
		return {}
	var lighting_revision := relight_revision if bool(request.include_sh) else 0
	var key := "%s:%d:%d:%d" % [layout_key, target_id, lighting_revision, clipmap_revision]
	if String(request.get("producer_layout_key", "")) != layout_key:
		# A source/cache replacement invalidates old in-flight bytes. Ordinary
		# relighting may advance while an async snapshot travels back to the UI.
		_serial += 1
		request.epoch = _serial
		request.pending_token = 0
		request.completed_key = ""
		request.producer_layout_key = layout_key
		_snapshots.erase(volume_id)
		_requests[volume_id] = request
	var now := Time.get_ticks_msec()
	if int(request.pending_token) != 0 or String(request.completed_key) == key \
			or now - int(request.last_enqueue_msec) < int(request.interval_msec):
		_mutex.unlock()
		return {}
	_serial += 1
	request.pending_token = _serial
	request.last_enqueue_msec = now
	request.status = "readback_pending" if bool(request.include_sh) else "topology_pending"
	var result := {"volume_id": volume_id, "target_id": target_id,
		"epoch": int(request.epoch), "token": _serial, "revision_key": key,
		"layout_key": layout_key, "relight_revision": relight_revision,
		"clipmap_revision": clipmap_revision, "include_sh": bool(request.include_sh),
		"request_msec": now}
	_requests[volume_id] = request
	_mutex.unlock()
	return result

static func fail(metadata: Dictionary, reason: String) -> void:
	_mutex.lock()
	var request: Dictionary = _requests.get(int(metadata.get("volume_id", 0)), {})
	if _matches(request, metadata):
		request.pending_token = 0
		request.status = reason
	_mutex.unlock()

## RenderingDevice callback; retain its data before the driver reuses storage.
static func receive_readback(data: PackedByteArray, metadata: Dictionary) -> void:
	if not _is_current(metadata):
		return
	var task := WorkerThreadPool.add_task(
		_decode_and_publish.bind(data.duplicate(), metadata), false,
		"Magic GI editor CLV snapshot")
	_mutex.lock()
	_tasks.append(task)
	var schedule_reap := not _reap_scheduled
	_reap_scheduled = true
	_mutex.unlock()
	if schedule_reap:
		_reap_when_done.call_deferred()

static func _is_current(metadata: Dictionary) -> bool:
	_mutex.lock()
	var current := _matches(_requests.get(int(metadata.get("volume_id", 0)), {}), metadata)
	_mutex.unlock()
	return current

static func _matches(request: Dictionary, metadata: Dictionary) -> bool:
	return not request.is_empty() and int(request.get("epoch", -1)) == int(metadata.get("epoch", -2)) \
		and int(request.get("pending_token", 0)) == int(metadata.get("token", -1))

static func _decode_and_publish(data: PackedByteArray, metadata: Dictionary) -> void:
	if not _is_current(metadata):
		return
	var started := Time.get_ticks_usec()
	var result := decode_snapshot(data, metadata)
	if not bool(result.get("current_available", false)):
		fail(metadata, String(result.get("status", "decode_failed")))
		return
	result["decode_usec"] = Time.get_ticks_usec() - started
	_mutex.lock()
	var volume_id := int(metadata.get("volume_id", 0))
	var request: Dictionary = _requests.get(volume_id, {})
	if _matches(request, metadata):
		_revision += 1
		result["revision"] = _revision
		result["published_msec"] = Time.get_ticks_msec()
		_snapshots[volume_id] = result
		request.pending_token = 0
		request.completed_key = metadata.revision_key
		request.status = result.status
	_mutex.unlock()

static func _reap_completed_tasks() -> void:
	var completed: Array[int] = []
	_mutex.lock()
	for task in _tasks:
		if WorkerThreadPool.is_task_completed(task):
			completed.append(task)
	for task in completed:
		_tasks.erase(task)
	_mutex.unlock()
	for task in completed:
		# Completion is checked first: this never waits for an active decoder.
		WorkerThreadPool.wait_for_task_completion(task)

static func _reap_when_done() -> void:
	# Runs on the main thread and yields between polls; disabling/deleting the
	# requester still retires its completed worker without a blocking join.
	while true:
		_reap_completed_tasks()
		_mutex.lock()
		var pending := not _tasks.is_empty()
		if not pending: _reap_scheduled = false
		_mutex.unlock()
		if not pending: return
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null: return
		await tree.process_frame

## Pure decoder for the compact prepared SH2 response. response_sh contains
## four raw signed L0+L1 coefficients, coefficient-major RGB.
static func decode_snapshot(data: PackedByteArray, metadata: Dictionary) -> Dictionary:
	var dimensions: Vector3i = metadata.get("dimensions", Vector3i.ZERO)
	var indices: PackedInt32Array = metadata.get("resident_indices", PackedInt32Array())
	var origins: PackedVector3Array = metadata.get("lod_origins", PackedVector3Array())
	var steps: PackedFloat32Array = metadata.get("lod_spacings", PackedFloat32Array())
	var layout_version := int(metadata.get("layout_version", 0))
	var lod_count := origins.size()
	var include_sh := bool(metadata.get("include_sh", true))
	var half_fields := bool(metadata.get("half_fields", false))
	var scale := float(metadata.get("decode_scale", 1.0))
	var cell_count := dimensions.x * dimensions.y * dimensions.z
	var bytes_per_lane := 2 if half_fields else 4
	if layout_version not in [7, 8] or int(metadata.get("operator_schema_version", 0)) != 2 \
			or int(metadata.get("response_field_count", 0)) != 4 \
			or lod_count < 1 or lod_count > 10 \
			or dimensions.x <= 0 or dimensions.y != dimensions.x or dimensions.z != dimensions.x * lod_count \
			or indices.size() != cell_count or steps.size() != lod_count \
			or not is_finite(scale) or scale <= 0.0:
		return {"current_available": false, "status": "invalid_clv_metadata"}
	if include_sh and data.size() != cell_count * 4 * 4 * bytes_per_lane:
		return {"current_available": false, "status": "invalid_clv_readback_size"}
	for lod in lod_count:
		if not origins[lod].is_finite() or not is_finite(steps[lod]) or steps[lod] <= 0.0:
			return {"current_available": false, "status": "invalid_clv_lod_geometry"}
	var positions := PackedVector3Array()
	var spacings := PackedFloat32Array()
	var lods := PackedInt32Array()
	var cells := PackedInt32Array()
	var sources := PackedInt32Array()
	var response := PackedFloat32Array()
	var capacity := 0
	for source_index in indices:
		if source_index >= 0: capacity += 1
	positions.resize(capacity); spacings.resize(capacity); lods.resize(capacity)
	cells.resize(capacity); sources.resize(capacity)
	if include_sh: response.resize(capacity * 12)
	var packed := PackedFloat32Array()
	packed.resize(16)
	var count := 0
	var cells_per_lod := dimensions.x * dimensions.y * dimensions.x
	for cell in cell_count:
		if indices[cell] < 0: continue
		var lod := cell / cells_per_lod
		if include_sh:
			var finite := true
			for field in 4:
				var offset := (field * cell_count + cell) * 4 * bytes_per_lane
				for lane in 4:
					var value := data.decode_half(offset + lane * 2) if half_fields \
						else data.decode_float(offset + lane * 4)
					packed[field * 4 + lane] = value
					finite = finite and is_finite(value)
			if not finite or packed[15] <= 0.5: continue
			var coefficients := [
				Vector3(packed[0], packed[1], packed[2]),
				Vector3(packed[3], packed[4], packed[5]),
				Vector3(packed[6], packed[7], packed[8]),
				Vector3(packed[9], packed[10], packed[11]),
			]
			for coefficient in 4:
				var coefficient_vector: Vector3 = coefficients[coefficient]
				for channel in 3:
					var value: float = coefficient_vector[channel] * scale
					response[count * 12 + coefficient * 3 + channel] = value
					finite = finite and is_finite(value)
			for component in 12:
				finite = finite and is_finite(response[count * 12 + component])
			if not finite: continue
		var local_cell := cell % cells_per_lod
		var coordinate := Vector3i(local_cell % dimensions.x,
			(local_cell / dimensions.x) % dimensions.y, local_cell / (dimensions.x * dimensions.y))
		positions[count] = origins[lod] + Vector3(coordinate) * steps[lod]
		spacings[count] = steps[lod]
		lods[count] = lod
		cells[count] = cell
		sources[count] = indices[cell]
		count += 1
	positions.resize(count); spacings.resize(count); lods.resize(count)
	cells.resize(count); sources.resize(count)
	if include_sh: response.resize(count * 12)
	var levels: Array[Dictionary] = []
	for lod in lod_count:
		levels.append({"lod": lod, "origin_world": origins[lod], "spacing": steps[lod],
			"bounds": AABB(origins[lod], Vector3.ONE * float(dimensions.x - 1) * steps[lod])})
	return {"volume_probe_preview": true, "current_available": true,
		"status": "ready" if include_sh else "topology_ready", "layout_version": layout_version,
		"clipmap_resolution": dimensions.x, "clipmap_lod_count": lod_count,
		"resident_capacity": cell_count,
		"layout_key": metadata.get("layout_key", ""), "positions": positions,
		"spacings": spacings, "lods": lods, "response_sh": response,
		"cell_indices": cells, "source_indices": sources, "clv_levels": levels,
		"clip_bounds_world": metadata.get("domain_bounds_world", AABB()),
		"volume_id": metadata.get("volume_id", 0), "target_id": metadata.get("target_id", 0),
		"relight_revision": metadata.get("relight_revision", 0),
		"clipmap_revision": metadata.get("clipmap_revision", 0),
		"request_msec": metadata.get("request_msec", 0), "include_sh": include_sh,
		"response_sh_semantics": "raw_signed_world_incident_radiance_sh2_l0_l1_coefficient_major_rgb",
		"response_coefficient_count": 4,
		"source": "actual_gpu_relit_prepared_clv" if include_sh else "actual_resident_clv_topology"}
