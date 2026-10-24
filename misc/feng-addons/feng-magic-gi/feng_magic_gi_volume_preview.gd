@tool
extends RefCounted
## Editor-only preview coordination. Source relighting runs on a worker and CLV
## snapshots come from the renderer's actual resident fields, never a second grid.
const SourcePreview = preload("feng_magic_gi_source_preview.gd")
const BrickPreview = preload("feng_magic_gi_prepared_brick_preview.gd")
const Page = preload("feng_magic_gi_page.gd")
const CLVPreview = preload("../feng-render-pipeline/passes/magic_gi_clv_editor_snapshot.gd")
const REFRESH_MSEC := 500

class SourceJob:
	extends RefCounted
	var result: Dictionary = {}
	var task_id := -1
	var key := ""
	var epoch := 0
	var mutex := Mutex.new()
	var cancelled := false
	func cancel() -> void:
		mutex.lock()
		cancelled = true
		mutex.unlock()
	func is_cancelled() -> bool:
		mutex.lock()
		var value := cancelled
		mutex.unlock()
		return value
	func run(chunk: Resource, lighting: PackedFloat32Array, sky: PackedFloat32Array,
			emission: PackedFloat32Array) -> void:
		result = SourcePreview.build(chunk, lighting, sky, emission, is_cancelled)
		if not result.is_empty(): result["source_kind"] = "original_source_probe"
	func run_prepared(pages: Array, lighting: PackedFloat32Array, sky: PackedFloat32Array) -> void:
		result = BrickPreview.build(pages, lighting, sky, is_cancelled)

static var _requested: Dictionary = {}
static var _epochs: Dictionary = {}
static var _jobs: Dictionary = {}
static var _cached: Dictionary = {}
static var _next_update: Dictionary = {}
static var _filtered_clv: Dictionary = {}
static var _clv_raw: Dictionary = {}
static var _poll_pending := false
static var _debug_sources: Dictionary = {}
static var _debug_loads: Dictionary = {}
static var _debug_failures: Dictionary = {}

static func set_requested(id: int, enabled: bool) -> void:
	if enabled:
		_requested[id] = true
		return
	_requested.erase(id)
	_epochs[id] = int(_epochs.get(id, 0)) + 1
	_cached.erase(id)
	_filtered_clv.erase(id)
	_clv_raw.erase(id)
	_next_update.erase(id)
	_release_debug_source(id)
	_debug_failures.erase(id)
	if _jobs.has(id):
		(_jobs[id] as SourceJob).cancel()
	CLVPreview.set_request(id, false)

static func snapshot(volume: Object, pages: Array, lighting: PackedFloat32Array,
		sky: PackedFloat32Array, editor_views: Array) -> Dictionary:
	var id: int = volume.get_instance_id()
	if not _requested.has(id):
		return {}
	var result: Dictionary
	if bool(volume.display_probes_by_clv):
		_release_debug_source(id)
		if _jobs.has(id):
			(_jobs[id] as SourceJob).cancel()
		var view_index: int = int(volume.probe_clv_view)
		var target_id := 0
		for view in editor_views:
			if int(view.get("viewport_index", 0)) == view_index:
				target_id = int(view.get("target_id", 0))
				break
		if target_id == 0:
			CLVPreview.set_request(id, false)
			return _pending("Selected editor viewport is not active", true)
		CLVPreview.set_request(id, true, true, REFRESH_MSEC, target_id)
		var status := CLVPreview.get_status(id)
		var raw: Dictionary = _clv_raw.get(id, {})
		if int(raw.get("revision", -1)) != int(status.get("revision", 0)) \
				or int(raw.get("target_id", 0)) != target_id:
			raw = CLVPreview.get_snapshot(id)
			_clv_raw[id] = raw
		result = raw
		if result.is_empty():
			return _pending("Waiting for the selected view's resident CLV lighting", true)
		result = _filter_clv(id, result, int(volume.probe_clv_level))
	else:
		CLVPreview.set_request(id, false)
		_filtered_clv.erase(id)
		_clv_raw.erase(id)
		var source_page: Dictionary = {}
		for page in pages:
			if page.get("free_space_volume_source") != null:
				source_page = page
				break
		var prepared_pages: Array = []
		for page in pages:
			if page.get("prepared_transfer_brick") != null: prepared_pages.append(page)
		var manifest: Resource = volume.get("bake_manifest")
		var debug_path := String(manifest.get("prepared_debug_source_path")) if manifest != null else ""
		if source_page.is_empty() and not debug_path.is_empty():
			var diagnostic := _debug_source(id, debug_path)
			if diagnostic.get("page") is Page:
				var debug_page: Page = diagnostic.page
				var emission := PackedFloat32Array()
				if not prepared_pages.is_empty(): emission = prepared_pages[0].get("emission_sources", PackedFloat32Array())
				source_page = {"free_space_volume_source": debug_page.free_space_volume_source,
					"cache_key": debug_path, "emission_sources": emission}
			elif not bool(diagnostic.get("failed", false)):
				return _pending("Loading original source probes for this debug view", false)
		elif debug_path.is_empty():
			_release_debug_source(id)
		if source_page.is_empty() and prepared_pages.is_empty():
			return _pending("Waiting for resident prepared bricks or a baked source page", false)
		var chunk: Resource = source_page.get("free_space_volume_source")
		var emission: PackedFloat32Array = source_page.get("emission_sources", PackedFloat32Array())
		var page_identity: Array = []
		for page in prepared_pages:
			page_identity.append([page.prepared_transfer_brick.get_instance_id(), page.get("cache_key", ""), page.get("emission_sources")])
		var source_key := "%d:%s" % [chunk.get_instance_id(), source_page.get("cache_key", "")] if chunk != null \
				else "prepared:%d" % hash(page_identity)
		var key := "%s:%d" % [source_key, hash([lighting, sky, emission])]
		var cached: Dictionary = _cached.get(id, {})
		if String(cached.get("_source_key", "")) != source_key:
			cached = {}
		if not _jobs.has(id) and String(cached.get("_key", "")) != key \
				and Time.get_ticks_msec() >= int(_next_update.get(id, 0)):
			var job := SourceJob.new()
			job.key = key
			job.epoch = int(_epochs.get(id, 0))
			_jobs[id] = job
			job.task_id = WorkerThreadPool.add_task(job.run.bind(chunk, lighting, sky, emission)) if chunk != null \
					else WorkerThreadPool.add_task(job.run_prepared.bind(prepared_pages, lighting, sky))
			if job.task_id < 0:
				_jobs.erase(id)
				return _pending("Could not schedule source preview worker", false)
			_next_update[id] = Time.get_ticks_msec() + REFRESH_MSEC
			_schedule_poll()
		result = cached.duplicate()
		if result.is_empty():
			return _pending("Relighting source probes for the editor preview", false)
	result = result.duplicate()
	result["volume_probe_preview"] = true
	result["display_by_clv"] = bool(volume.display_probes_by_clv)
	result["selected_clv_level"] = int(volume.probe_clv_level)
	return result

static func _pending(status: String, by_clv: bool) -> Dictionary:
	return {"volume_probe_preview": true, "current_available": false,
		"positions": PackedVector3Array(), "response_sh": PackedFloat32Array(),
		"display_by_clv": by_clv, "status": status, "revision": hash([status, by_clv]),
		"layout_key": status}

static func _schedule_poll() -> void:
	if _poll_pending or (_jobs.is_empty() and _debug_loads.is_empty()):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_poll_pending = true
	tree.create_timer(0.05).timeout.connect(_poll_jobs, CONNECT_ONE_SHOT)

static func _poll_jobs() -> void:
	_poll_pending = false
	_poll_debug_loads()
	for id in _jobs.keys():
		var job: SourceJob = _jobs[id]
		if not WorkerThreadPool.is_task_completed(job.task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(job.task_id)
		_jobs.erase(id)
		if not _requested.has(id) or job.is_cancelled() \
				or job.epoch != int(_epochs.get(id, 0)) or job.result.is_empty():
			continue
		var result := job.result
		result["_key"] = job.key
		result["_source_key"] = job.key.substr(0, job.key.rfind(":"))
		result["revision"] = hash(job.key)
		_cached[id] = result
	_schedule_poll()

static func _release_debug_source(id: int) -> void:
	_debug_sources.erase(id)
	if _debug_loads.has(id):
		_debug_loads[id]["discard"] = true
		_schedule_poll()

static func _debug_source(id: int, path: String) -> Dictionary:
	var cached: Dictionary = _debug_sources.get(id, {})
	if cached.get("path", "") == path: return cached
	if _debug_failures.get(id, "") == path: return {"failed": true}
	if _debug_loads.has(id):
		if _debug_loads[id].path != path: _debug_loads[id]["discard"] = true
		return {}
	_debug_sources.erase(id)
	var error := ResourceLoader.load_threaded_request(path, "", true, ResourceLoader.CACHE_MODE_IGNORE)
	if error != OK:
		_debug_failures[id] = path
		return {"failed": true}
	_debug_loads[id] = {"path": path, "epoch": int(_epochs.get(id, 0)), "discard": false}
	_schedule_poll()
	return {}

static func _poll_debug_loads() -> void:
	for id in _debug_loads.keys():
		var record: Dictionary = _debug_loads[id]
		var status := ResourceLoader.load_threaded_get_status(record.path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS: continue
		var page: Resource
		if status == ResourceLoader.THREAD_LOAD_LOADED: page = ResourceLoader.load_threaded_get(record.path)
		_debug_loads.erase(id)
		if bool(record.discard) or not _requested.has(id) or int(record.epoch) != int(_epochs.get(id, 0)): continue
		if page is Page and page.free_space_volume_source != null and page.is_header_valid():
			_debug_sources[id] = {"path": record.path, "page": page}
		else:
			_debug_failures[id] = record.path

static func _filter_clv(id: int, input: Dictionary, level: int) -> Dictionary:
	var key := "%s:%s:%d" % [input.get("revision", 0), input.get("layout_key", ""), level]
	var previous: Dictionary = _filtered_clv.get(id, {})
	if previous.get("_filter_key", "") == key:
		return previous
	var positions: PackedVector3Array = input.get("positions", PackedVector3Array())
	var spacings: PackedFloat32Array = input.get("spacings", PackedFloat32Array())
	var lods: PackedInt32Array = input.get("lods", PackedInt32Array())
	var coefficients: PackedFloat32Array = input.get("response_sh", PackedFloat32Array())
	if spacings.size() != positions.size() or lods.size() != positions.size():
		return _pending("Resident CLV preview layout is not ready", true)
	var levels: Array = input.get("clv_levels", [])
	var bounds_by_level: Dictionary = {}
	for entry in levels:
		bounds_by_level[int(entry.get("lod", 0))] = entry.get("bounds", entry.get("clip_bounds_world", AABB()))
	var kept := PackedInt32Array()
	for index in positions.size():
		var lod := lods[index]
		if level >= 0 and lod != level:
			continue
		if level < 0 and lod > 0 and bounds_by_level.has(lod - 1):
			var fine_bounds: AABB = bounds_by_level[lod - 1]
			var half := Vector3.ONE * spacings[index] * 0.5
			if fine_bounds.encloses(AABB(positions[index] - half, half * 2.0)):
				continue
		kept.append(index)
	var output_positions := PackedVector3Array()
	var output_spacings := PackedFloat32Array()
	var output_lods := PackedInt32Array()
	var output_sh := PackedFloat32Array()
	output_positions.resize(kept.size())
	output_spacings.resize(kept.size())
	output_lods.resize(kept.size())
	var has_sh := coefficients.size() == positions.size() * 27
	if has_sh:
		output_sh.resize(kept.size() * 27)
	for output in kept.size():
		var index := kept[output]
		output_positions[output] = positions[index]
		output_spacings[output] = spacings[index]
		output_lods[output] = lods[index]
		if has_sh:
			for channel in 27:
				output_sh[output * 27 + channel] = coefficients[index * 27 + channel]
	var result := input.duplicate()
	result.merge({"positions": output_positions, "spacings": output_spacings,
		"lods": output_lods, "response_sh": output_sh,
		"layout_key": "%s:%s:%d" % [input.get("layout_key", ""), input.get("clipmap_revision", 0), level],
		"revision": hash(key), "_filter_key": key}, true)
	_filtered_clv[id] = result
	return result
