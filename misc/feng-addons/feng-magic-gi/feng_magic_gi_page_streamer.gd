@tool
extends RefCounted
## Main-thread manifest paging with bounded threaded loads and CPU packing.

const Manifest = preload("feng_magic_gi_manifest.gd")
const Page = preload("feng_magic_gi_page.gd")
const Data = preload("feng_magic_gi_data.gd")
const DirectionalData = preload("feng_magic_gi_directional_data.gd")
const PrepareJob = preload("feng_magic_gi_page_prepare_job.gd")
const EmissionJob = preload("feng_magic_gi_page_emission_job.gd")
const Emission = preload("feng_magic_gi_emission.gd")
const VolumeSourceChunk = preload("feng_magic_gi_volume_source_chunk.gd")
const PreparedBrick = preload("feng_magic_gi_prepared_transfer_brick.gd")
const PreparedHeader = preload("feng_magic_gi_prepared_source_header.gd")
const PreparedLayout = preload("feng_magic_gi_prepared_clip_layout.gd")

const INACTIVE_VIEW_MSEC := 750

var warning := ""
var _failure_warning := ""
var _manifest: Manifest
var _manifest_token := ""
var _views: Dictionary = {} # target_id:view_id -> last bounded camera request
var _active_metadata: Dictionary = {} # active page key -> metadata + priority distance
var _resident: Dictionary = {} # page key -> descriptor, source tracker and LRU time
var _loads: Dictionary = {} # page key -> threaded ResourceLoader/prepare transaction
var _emission_tasks: Dictionary = {} # WorkerThreadPool task id -> immutable page update
var _failed_versions: Dictionary = {} # generation/key/hash -> terminal load failure
var _budget_blocked_versions: Dictionary = {} # page identity -> CPU/GPU limits that blocked it
var _revision := 0
var _layout_revision := 0
var _last_emission_refresh := 0
var _budget_blocked_pages := 0
var prepared_source_header: Resource
var _prepared_emission := Emission.new()
var _prepared_emission_values := PackedFloat32Array()

func set_manifest(manifest: Manifest) -> void:
	var next_token := ""
	if manifest != null and is_instance_valid(manifest):
		next_token = "%s:%s" % [manifest.manifest_key, manifest.generation]
	if next_token == _manifest_token and _manifest == manifest:
		return
	_manifest = manifest
	prepared_source_header = PreparedHeader.from_manifest(manifest)
	if _manifest != null:
		_manifest.has_baked_indirect_sh() # Validation is cached for this immutable generation.
	_manifest_token = next_token
	_failure_warning = ""
	warning = ""
	if _manifest != null and _manifest.transport_domain == "prepared_free_space_bricks_v1" \
			and _manifest.prepared_operator_schema_version != 2:
		_failure_warning = "Prepared CLV cache uses the legacy SH9 operator schema. Rebake it to SH2 before runtime use."
		warning = _failure_warning
	_revision += 1
	_layout_revision += 1
	_active_metadata.clear()
	_resident.clear()
	_prepared_emission_values.clear()
	_failed_versions.clear()
	_budget_blocked_versions.clear()
	for page_key in _loads:
		var record: Dictionary = _loads[page_key]
		record["discard"] = true

## The render thread submits values only. Resource and viewport Objects never
## cross this boundary; Runtime applies requests from its main-thread tick.
func request_view(target_id: int, view_id: int, camera: Vector3, bounds: AABB, now_msec: int,
		resolution := 16) -> void:
	if target_id <= 0 or not camera.is_finite():
		return
	var key := _view_key(target_id, view_id)
	_views[key] = {"target_id": target_id, "view_id": view_id, "camera": camera,
		"bounds": bounds, "last_seen": now_msec, "resolution": resolution,
		"layout_state": _views.get(key, {}).get("layout_state", {}), "page_keys": PackedStringArray()}

func refresh(volume: FMagicGIVolume, now_msec: int) -> void:
	if volume == null or not is_instance_valid(volume):
		return
	if volume.bake_manifest != _manifest:
		set_manifest(volume.bake_manifest)
	warning = _failure_warning
	_budget_blocked_pages = 0
	_prune_views(now_msec)
	_rebuild_active_metadata(volume)
	_evict_inactive_pages()
	_rebalance_residency(volume)
	_advance_page_loads(volume)
	_advance_emission_updates(volume)
	_start_page_loads(volume, now_msec)
	if _budget_blocked_pages > 0 and warning.is_empty():
		warning = "%d Magic GI pages or emission updates are waiting for the CPU/GPU residency budget." % _budget_blocked_pages

func deactivate() -> void:
	_views.clear()
	_active_metadata.clear()
	_evict_inactive_pages()
	for key in _loads:
		var record: Dictionary = _loads[key]
		record["discard"] = true
	for task_id_value in _emission_tasks.keys():
		var task_id := int(task_id_value)
		var task_record: Dictionary = _emission_tasks[task_id]
		task_record["discard"] = true
		_emission_tasks[task_id] = task_record

func drain_completed() -> void:
	## Retired or inactive streamers keep their async handles until completion.
	## Polling is nonblocking; completed work is joined and its result released.
	for key_value in _loads.keys():
		var key := String(key_value)
		var record: Dictionary = _loads[key]
		record["discard"] = true
		if String(record.get("stage", "")) == "resource":
			var path := String(record.get("path", ""))
			var status := ResourceLoader.load_threaded_get_status(path)
			if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				continue
			if status == ResourceLoader.THREAD_LOAD_LOADED:
				ResourceLoader.load_threaded_get(path)
			_loads.erase(key)
			continue
		var task_id := int(record.get("task_id", -1))
		if task_id >= 0 and WorkerThreadPool.is_task_completed(task_id):
			WorkerThreadPool.wait_for_task_completion(task_id)
			_loads.erase(key)
	for task_id_value in _emission_tasks.keys():
		var task_id := int(task_id_value)
		if WorkerThreadPool.is_task_completed(task_id):
			WorkerThreadPool.wait_for_task_completion(task_id)
			_emission_tasks.erase(task_id)

func is_drained() -> bool:
	return _loads.is_empty() and _emission_tasks.is_empty() and _resident.is_empty()

func status() -> Dictionary:
	var loading_count := 0
	for record in _loads.values():
		if String(record.get("stage", "")) in ["resource", "prepare"]:
			loading_count += 1
	var cpu_inflight := inflight_cpu_bytes()
	var gpu_inflight := inflight_gpu_bytes()
	var cpu_resident := resident_cpu_bytes()
	var gpu_resident := resident_gpu_bytes()
	var transfer_state := directional_transfer_status()
	return {
		"page_count": _manifest.get_page_count() if _manifest != null else 0,
		"active_pages": _active_metadata.size(),
		"resident_pages": resident_page_count(),
		"loading_pages": loading_count,
		"emission_updates": _emission_tasks.size(),
		"budget_blocked_pages": _budget_blocked_pages,
		"cpu_resident_bytes": cpu_resident,
		"gpu_resident_bytes": gpu_resident,
		"cpu_inflight_bytes": cpu_inflight,
		"gpu_inflight_bytes": gpu_inflight,
		"cpu_committed_bytes": cpu_resident + cpu_inflight,
		"gpu_committed_bytes": gpu_resident + gpu_inflight,
		"directional_transfer_ready": bool(transfer_state.get("ready", false)),
		"directional_transfer_status": String(transfer_state.get("status", "unknown")),
		"directional_transfer_resident_pages": int(transfer_state.get("resident_pages", 0)),
		"warning": warning,
	}

func directional_transfer_status() -> Dictionary:
	var active_pages := 0
	for metadata in _active_metadata.values():
		if not bool(metadata.get("empty", false)):
			active_pages += 1
	var resident_transfer_pages := 0
	for page_key_value in _resident.keys():
		var page_key := String(page_key_value)
		var record: Dictionary = _resident[page_key]
		var admission := _resident_dynamic_transfer_admission(page_key, record)
		if bool(admission.get("ready", false)):
			resident_transfer_pages += 1
	var status := "ready"
	var message := "Resident pages contain validated directional TransferMatrix data."
	if resident_transfer_pages == 0:
		if active_pages == 0:
			status = "waiting_for_view"
			message = "Waiting for an active camera view to request streamed pages."
		elif not _failure_warning.is_empty():
			status = "page_transfer_rejected"
			message = _failure_warning
		else:
			status = "loading_pages"
			message = "Waiting for streamed pages with valid directional TransferMatrix data."
	return {
		"ready": resident_transfer_pages > 0,
		"status": status,
		"message": message,
		"active_pages": active_pages,
		"resident_pages": _resident.size(),
		"resident_transfer_pages": resident_transfer_pages,
	}

func _resident_dynamic_transfer_admission(page_key: String, record: Dictionary) -> Dictionary:
	var descriptor: Dictionary = record.get("descriptor", {})
	var brick: Variant = descriptor.get("brick", null)
	if brick is PreparedBrick:
		var ready: bool = int(record.get("validated_source_chunk_id", -1)) == brick.get_instance_id() \
			and String(record.get("validated_source_signature", "")) == brick.directional_source_signature \
			and prepared_source_header != null \
			and brick.directional_source_signature == prepared_source_header.directional_source_signature
		return {"ready": ready, "status": "ready_prepared_brick" if ready else "invalid_prepared_brick"}
	var chunk: Variant = descriptor.get("free_space_volume_source", null)
	if chunk is VolumeSourceChunk:
		var chunk_id := int(chunk.get_instance_id())
		var chunk_signature := String(chunk.directional_source_signature)
		var validated_id := int(record.get("validated_source_chunk_id", -1))
		var validated_signature := String(record.get("validated_source_signature", ""))
		if descriptor.get("data", null) != null \
				or validated_id != chunk_id or validated_signature != chunk_signature \
				or not chunk.is_header_valid(int(descriptor.get("geometry_signature", 0))):
			return {"ready": false, "status": "invalid_free_space_transfer",
				"message": "Free-space transfer page is not the deeply validated immutable chunk currently resident."}
		return {"ready": true, "status": "ready_free_space_volume",
			"message": "Resident page contains deeply validated regular free-space TransferMatrix data.",
			"probe_count": chunk.probe_count, "source_count": chunk.emitter_count}
	var data: Variant = descriptor.get("data", null)
	if not data is Data:
		return {"ready": false, "status": "unsupported_data"}
	var data_id: int = data.get_instance_id()
	var cached_data_id := int(record.get("dynamic_transfer_data_id", -1))
	var admission: Dictionary = record.get("dynamic_transfer_admission", {})
	if cached_data_id != data_id or admission.is_empty():
		admission = dynamic_transfer_admission(data)
		record["dynamic_transfer_data_id"] = data_id
		record["dynamic_transfer_admission"] = admission
		_resident[page_key] = record
	return admission

static func dynamic_transfer_admission(data: Resource) -> Dictionary:
	if data == null or not data is Data:
		return {"ready": false, "status": "unsupported_data", "message": "Page has no supported FMagicGIData payload."}
	if data.directional == null:
		if not data.is_valid():
			return {"ready": false, "status": "invalid_geometry_or_probe_data", "message": "Page geometry/probe data is invalid."}
		return {"ready": false, "status": "missing_directional_transfer", "message": "Page has no directional TransferMatrix. Baked-SH-only pages cannot drive dynamic CLV PRT; rebuild this page generation."}
	if not data.directional is DirectionalData:
		return {"ready": false, "status": "invalid_directional_transfer", "message": "Page directional TransferMatrix has an unsupported resource type."}
	if not data.is_valid():
		return {"ready": false, "status": "invalid_geometry_probe_or_transfer", "message": "Page geometry/probe data or directional TransferMatrix is invalid."}
	return {
		"ready": true,
		"status": "ready",
		"message": "Page geometry/probe data and directional TransferMatrix are valid.",
		"probe_count": data.probe_count(),
		"source_count": data.emitter_count(),
	}

func revision() -> int:
	return _revision

func layout_revision() -> int:
	return _layout_revision

func ready_pages(lighting: PackedFloat32Array, sky_lighting: PackedFloat32Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var keys: Array = _active_metadata.keys()
	keys.sort()
	for key_value in keys:
		var key := String(key_value)
		var record: Dictionary = _resident.get(key, {})
		var descriptor: Dictionary = record.get("descriptor", {})
		if descriptor.is_empty():
			continue
		record["last_used"] = Time.get_ticks_msec()
		_resident[key] = record
		var page := descriptor.duplicate(false)
		page["lighting"] = lighting
		page["sky_lighting"] = sky_lighting
		result.append(page)
	return result

func pending_pages() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var keys: Array = _active_metadata.keys()
	keys.sort()
	for key_value in keys:
		var key := String(key_value)
		if _resident.has(key) or _active_metadata[key].get("empty", false):
			continue
		var metadata: Dictionary = _active_metadata[key]
		result.append({
			"page_key": key,
			"core_bounds": metadata.get("core_bounds", AABB()),
			"cache_identity": _page_identity(metadata),
		})
	return result

func pending_page_keys() -> PackedStringArray:
	var result := PackedStringArray()
	for descriptor in pending_pages():
		result.append(String(descriptor.page_key))
	return result

func resident_page_count() -> int:
	return _resident.size()

func active_page_count() -> int:
	return _active_metadata.size()

func has_active_pages() -> bool:
	for metadata in _active_metadata.values():
		if not bool(metadata.get("empty", false)):
			return true
	return false

func inflight_count() -> int:
	return _loads.size() + _emission_tasks.size()

func resident_cpu_bytes() -> int:
	var total := 0
	for value in _resident.values():
		total += int(value.get("cpu_bytes", 0))
	return total

func resident_gpu_bytes() -> int:
	var total := 0
	for value in _resident.values():
		total += int(value.get("gpu_bytes", 0))
	return total

func inflight_cpu_bytes() -> int:
	var total := 0
	for record in _loads.values():
		total += int(record.get("reserved_cpu_bytes", 0))
	for record in _emission_tasks.values():
		total += int(record.get("transient_cpu_bytes", 0))
	return total

func inflight_gpu_bytes() -> int:
	var total := 0
	for record in _loads.values():
		total += int(record.get("reserved_gpu_bytes", 0))
	return total

func emission_warning() -> String:
	if prepared_source_header != null:
		return _prepared_emission.get_warning()
	var messages := PackedStringArray()
	for value in _resident.values():
		var state: Emission = value.get("emission_state")
		if state != null and not state.warning.is_empty() and not messages.has(state.warning):
			messages.append(state.warning)
	return "; ".join(messages)

func _rebuild_active_metadata(volume: FMagicGIVolume) -> void:
	_active_metadata.clear()
	if _manifest == null or not is_instance_valid(_manifest) or not _manifest.is_valid():
		return
	if prepared_source_header != null:
		_rebuild_prepared_active_metadata(volume)
		return
	var candidates: Dictionary = {}
	for view in _views.values():
		var camera: Vector3 = view.get("camera", Vector3.ZERO)
		var distance := maxf(volume.stream_distance, 0.1)
		var hysteresis := maxf(volume.stream_hysteresis, 0.0)
		var query: AABB = view.get("bounds", AABB())
		if not _valid_bounds(query):
			query = AABB(camera - Vector3.ONE * distance, Vector3.ONE * distance * 2.0)
		query = query.grow(hysteresis)
		var page_keys := _manifest.get_page_keys_for_bounds(query)
		view["page_keys"] = page_keys
		for page_key in page_keys:
			var metadata := _manifest.get_page_metadata(page_key)
			if metadata.is_empty() or bool(metadata.get("empty", false)):
				continue
			var core: AABB = metadata.get("core_bounds", AABB())
			var priority := core.get_center().distance_to(camera)
			var existing: Dictionary = candidates.get(page_key, metadata)
			metadata["_priority"] = minf(float(existing.get("_priority", INF)), priority)
			candidates[page_key] = metadata
	for key in candidates:
		_active_metadata[String(key)] = candidates[key]

func _rebuild_prepared_active_metadata(volume: FMagicGIVolume) -> void:
	# Each level requests its own bounded window. A 512 m L0 request would
	# accidentally load the entire high-resolution world into RAM.
	for view in _views.values():
		var camera: Vector3 = view.camera
		var layout := PreparedLayout.build(prepared_source_header, camera,
			int(view.get("resolution", 16)), volume.gi_radius_m, view.get("layout_state", {}))
		if not bool(layout.get("valid", false)):
			continue
		view["layout_state"] = layout.state
		var keys := PackedStringArray()
		for lod in layout.lods:
			var query: AABB = lod.clip_bounds_world
			var candidates: PackedStringArray = _manifest.get_page_keys_for_level_bounds(int(lod.lod), query)
			for key in candidates:
				var metadata := _manifest.get_page_metadata(key)
				var core: AABB = metadata.get("core_bounds", AABB())
				if bool(metadata.get("empty", false)) \
						or not PreparedLayout.intersects_sphere(core, camera, volume.gi_radius_m):
					continue
				keys.append(key)
				var priority := core.get_center().distance_to(camera)
				var existing: Dictionary = _active_metadata.get(key, {})
				metadata["_priority"] = minf(priority, float(existing.get("_priority", INF)))
				_active_metadata[key] = metadata
		view["page_keys"] = keys

func prepared_emission_sources() -> PackedFloat32Array:
	return _prepared_emission_values

func _prune_views(now_msec: int) -> void:
	for key in _views.keys():
		if now_msec - int(_views[key].get("last_seen", 0)) > INACTIVE_VIEW_MSEC:
			_views.erase(key)

func _evict_inactive_pages() -> void:
	var changed := false
	for key in _resident.keys():
		if not _active_metadata.has(key):
			_resident.erase(key)
			changed = true
	for key in _loads.keys():
		if not _active_metadata.has(key):
			var record: Dictionary = _loads[key]
			if not bool(record.get("discard", false)):
				record["discard"] = true
				changed = true
	if changed:
		_revision += 1
		_layout_revision += 1

func _rebalance_residency(volume: FMagicGIVolume) -> void:
	var resident_keys: Array = _resident.keys()
	resident_keys.sort_custom(func(a: String, b: String) -> bool:
		var a_priority := _priority_for_key(a)
		var b_priority := _priority_for_key(b)
		if not is_equal_approx(a_priority, b_priority):
			return a_priority > b_priority # Evict the farther page first.
		return int(_resident[a].get("last_used", 0)) < int(_resident[b].get("last_used", 0)))
	var evicted := false
	for key_value in resident_keys:
		if resident_cpu_bytes() + inflight_cpu_bytes() <= volume.cpu_resident_budget_bytes \
				and resident_gpu_bytes() + inflight_gpu_bytes() <= volume.gpu_resident_budget_bytes:
			break
		var key := String(key_value)
		if _resident.erase(key):
			evicted = true
			_revision += 1
			_layout_revision += 1
	if evicted:
		warning = "Page residency was reduced to fit the current CPU/GPU budgets."
	if resident_cpu_bytes() + inflight_cpu_bytes() <= volume.cpu_resident_budget_bytes \
			and resident_gpu_bytes() + inflight_gpu_bytes() <= volume.gpu_resident_budget_bytes:
		return
	# ResourceLoader requests and running worker tasks cannot be cancelled. Mark
	# farthest transactions discard-only; their reserved bytes remain accounted
	# until the main-thread drain joins them.
	var load_keys: Array = _loads.keys()
	load_keys.sort_custom(func(a: String, b: String) -> bool:
		return _priority_for_key(a) > _priority_for_key(b))
	for key_value in load_keys:
		if resident_cpu_bytes() + inflight_cpu_bytes() <= volume.cpu_resident_budget_bytes \
				and resident_gpu_bytes() + inflight_gpu_bytes() <= volume.gpu_resident_budget_bytes:
			break
		var key := String(key_value)
		var record: Dictionary = _loads.get(key, {})
		record["discard"] = true
		_loads[key] = record
	warning = "Waiting for in-flight page work to release memory after a budget reduction."

func _priority_for_key(key: String) -> float:
	return float(_active_metadata.get(key, {}).get("_priority", INF))

func _advance_page_loads(volume: FMagicGIVolume) -> void:
	for key_value in _loads.keys():
		var key := String(key_value)
		var record: Dictionary = _loads[key]
		if String(record.get("stage", "")) == "resource":
			var status := ResourceLoader.load_threaded_get_status(String(record.path))
			if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				continue
			if bool(record.get("discard", false)) or not _active_metadata.has(key) \
					or not _record_matches_current_manifest(key, record):
				if status == ResourceLoader.THREAD_LOAD_LOADED:
					ResourceLoader.load_threaded_get(String(record.path))
				_loads.erase(key)
				continue
			if status != ResourceLoader.THREAD_LOAD_LOADED:
				_fail_load(key, record, "Page resource load failed or was cancelled.")
				continue
			var loaded := ResourceLoader.load_threaded_get(String(record.path)) as Page
			if bool(record.get("discard", false)) or not _active_metadata.has(key) \
					or not _record_matches_current_manifest(key, record):
				_loads.erase(key)
				continue
			if loaded == null:
				_fail_load(key, record, "Page resource is not a FMagicGIPage.")
				continue
			var loaded_data := loaded.data
			var loaded_chunk: Variant = loaded.free_space_volume_source
			var prepared := loaded.prepared_transfer_brick is PreparedBrick
			if prepared:
				loaded_chunk = loaded.prepared_transfer_brick
			var source_only := loaded_chunk is VolumeSourceChunk or prepared
			if source_only:
				if volume.clv_cache_backend != 1 or loaded_data != null \
						or not loaded.is_header_valid(String(record.get("page_generation", "")), key):
					_fail_load(key, record,
						"Free-space source page failed header admission, has a conflicting legacy payload, or requires dynamic CLV backend 1.")
					continue
				if prepared and (prepared_source_header == null \
						or loaded_chunk.directional_source_signature != prepared_source_header.directional_source_signature \
						or not loaded_chunk.is_header_valid(prepared_source_header.geometry_signature,
							prepared_source_header.emitter_ids, prepared_source_header.emitter_static_signatures)):
					_fail_load(key, record, "Prepared brick does not belong to this immutable manifest.")
					continue
			else:
				if loaded_data == null or not loaded_data is Data:
					_fail_load(key, record, "Page resource has no supported FMagicGIData payload.")
					continue
				if volume.clv_cache_backend == 1:
					var admission := dynamic_transfer_admission(loaded_data)
					if not bool(admission.get("ready", false)):
						_fail_load(key, record, "%s Rebuild this page generation." % String(admission.get("message", "Dynamic CLV PRT page data is invalid.")))
						continue
					if not loaded.is_valid(String(record.get("page_generation", "")), key):
						_fail_load(key, record,
							"Page geometry/probe data or directional TransferMatrix is invalid; rebuild this page generation.")
						continue
			# Older manifests may undercount generated payloads. Reserve the full
			# source chunk or legacy page before creating worker results.
			var minimum_cpu_bytes := 0
			var minimum_gpu_bytes := 0
			if source_only:
				minimum_cpu_bytes = loaded_chunk.estimated_cpu_resident_bytes()
				minimum_gpu_bytes = 0 if prepared else loaded_chunk.estimated_gpu_payload_bytes()
			else:
				minimum_cpu_bytes = loaded_data.estimate_cpu_bytes() \
						+ loaded_data.estimate_gpu_bytes() + loaded_data.probe_count() * 3 * 4
				minimum_gpu_bytes = loaded_data.estimate_gpu_bytes()
			record["reserved_cpu_bytes"] = maxi(int(record.get("reserved_cpu_bytes", 0)),
				maxi(loaded.cpu_bytes, minimum_cpu_bytes))
			record["reserved_gpu_bytes"] = maxi(int(record.get("reserved_gpu_bytes", 0)),
				maxi(loaded.gpu_bytes, minimum_gpu_bytes))
			if prepared:
				record["reserved_gpu_bytes"] = 0
			_loads[key] = record
			if int(record.reserved_cpu_bytes) > volume.cpu_resident_budget_bytes \
					or int(record.reserved_gpu_bytes) > volume.gpu_resident_budget_bytes:
				_budget_blocked_versions[_page_identity(record)] = {
					"cpu": volume.cpu_resident_budget_bytes,
					"gpu": volume.gpu_resident_budget_bytes,
				}
				_loads.erase(key)
				_budget_blocked_pages += 1
				warning = "Page %s exceeds the current CPU/GPU residency budget." % key
				continue
			var emission_state := Emission.new()
			var sources := PackedFloat32Array()
			if prepared:
				sources = _prepared_emission_values
			elif source_only:
				sources = emission_state.read_volume_source_values(volume, loaded_chunk)
			else:
				sources = emission_state.read_source_values(volume, loaded_data)
			var job := PrepareJob.new()
			job.configure(loaded, String(record.page_generation), key,
					String(record.path), String(record.content_hash), sources)
			var task_id := WorkerThreadPool.add_task(Callable(job, "run"), false, "Magic GI Page Prepare")
			if task_id < 0:
				_fail_load(key, record, "Could not queue worker preparation for the loaded page.")
				continue
			record["stage"] = "prepare"
			record["task_id"] = task_id
			record["job"] = job
			record["emission_state"] = emission_state
			record["page"] = loaded
			_loads[key] = record
			continue
		var stage := String(record.get("stage", ""))
		if stage != "prepare" and stage != "prepared":
			continue
		var job: PrepareJob = record.get("job")
		if stage == "prepare":
			var task_id := int(record.get("task_id", -1))
			if task_id < 0 or not WorkerThreadPool.is_task_completed(task_id):
				continue
			WorkerThreadPool.wait_for_task_completion(task_id)
		if bool(record.get("discard", false)) or not _active_metadata.has(key) \
				or not _record_matches_current_manifest(key, record):
			_loads.erase(key)
			continue
		if job == null or not job.valid:
			_fail_load(key, record, job.error if job != null else "Page worker disappeared.")
			continue
		if stage == "prepare":
			record["stage"] = "prepared"
			record["reserved_cpu_bytes"] = job.cpu_bytes
			record["reserved_gpu_bytes"] = job.gpu_bytes
			_loads[key] = record
			_rebalance_residency(volume)
			record = _loads.get(key, {})
			if record.is_empty():
				continue
		if bool(record.get("discard", false)) or not _active_metadata.has(key) \
				or not _record_matches_current_manifest(key, record):
			_loads.erase(key)
			continue
		var metadata: Dictionary = _active_metadata[key]
		if job.gpu_bytes > int(metadata.get("gpu_bytes", 0)):
			_fail_load(key, record, "Manifest GPU memory metadata underestimates its validated payload.")
			continue
		if job.cpu_bytes > int(metadata.get("cpu_bytes", 0)):
			warning = "Page %s memory metadata was lower than its validated CPU payload; using the measured estimate." % key
		if resident_cpu_bytes() + inflight_cpu_bytes() > volume.cpu_resident_budget_bytes \
				or resident_gpu_bytes() + inflight_gpu_bytes() > volume.gpu_resident_budget_bytes:
			if job.cpu_bytes > volume.cpu_resident_budget_bytes \
					or job.gpu_bytes > volume.gpu_resident_budget_bytes:
				_budget_blocked_versions[_page_identity(record)] = {
					"cpu": volume.cpu_resident_budget_bytes,
					"gpu": volume.gpu_resident_budget_bytes,
				}
				_loads.erase(key)
				_budget_blocked_pages += 1
				warning = "Prepared page %s exceeds the current CPU/GPU residency budget." % key
			continue
		_revision += 1
		_layout_revision += 1
		var page: Page = job.page
		var brick: Resource = page.prepared_transfer_brick
		var source_chunk: Resource = brick if brick != null else page.free_space_volume_source
		var source_only := source_chunk != null
		var version: int = brick.format_version if brick != null else (source_chunk.source_schema_revision if source_only else int(page.data.bake_version))
		var content_identity := String(source_chunk.directional_source_signature) \
				if source_only else String(record.content_hash)
		var base_identity := "%s/%s/%s/%d" % [page.generation, key,
				content_identity, version]
		var descriptor := {
			"page_key": key,
			"page_generation": page.generation,
			"core_bounds": page.core_bounds,
			"support_bounds": page.support_bounds,
			"data": page.data,
			"free_space_volume_source": page.free_space_volume_source,
			"brick": brick,
			"prepared_transfer_brick": brick,
			"prepared_transfer_validated": brick != null,
			"geometry_signature": page.geometry_signature,
			"version": version,
			"gpu_bytes": job.gpu_bytes,
			"cpu_bytes": job.cpu_bytes,
			"render_upload": job.render_upload,
			"lighting": PackedFloat32Array(),
			"sky_lighting": PackedFloat32Array(),
			"emission_payload": job.emission_payload,
			"emission_sources": job.emission_sources,
			"emission_warning": record.emission_state.get_warning() \
					if record.get("emission_state") != null else "",
			"identity": base_identity,
			"cache_key": base_identity,
			"free_space_source_validated": page.free_space_volume_source != null,
			"free_space_source_instance_id": source_chunk.get_instance_id() if source_only else 0,
			"free_space_source_signature": source_chunk.directional_source_signature if source_only else "",
			"revision": version,
			"emission_revision": _revision,
			"emission_image": job.emission_image,
			"replacement_enabled": source_only or page.data.format_version == Data.FORMAT_VERSION,
		}
		var resident_record := {"descriptor": descriptor, "page": page,
			"cpu_bytes": job.cpu_bytes, "content_hash": String(record.content_hash),
			"gpu_bytes": job.gpu_bytes, "version": version,
			"page_generation": page.generation, "path": String(record.path),
			"last_used": Time.get_ticks_msec(),
			"emission_state": record.emission_state,
			"base_identity": base_identity}
		if source_only:
			resident_record["validated_source_chunk_id"] = source_chunk.get_instance_id()
			resident_record["validated_source_signature"] = source_chunk.directional_source_signature
		_resident[key] = resident_record
		_loads.erase(key)

func _start_page_loads(volume: FMagicGIVolume, now_msec: int) -> void:
	if _manifest == null or not is_instance_valid(_manifest):
		return
	var candidates: Array[String] = []
	for key_value in _active_metadata.keys():
		var key := String(key_value)
		var metadata: Dictionary = _active_metadata[key]
		if _resident_page_matches(key, metadata) or _loads.has(key):
			continue
		var failure_key := _page_identity(metadata)
		if _failed_versions.has(failure_key):
			continue
		var budget_block: Dictionary = _budget_blocked_versions.get(failure_key, {})
		if not budget_block.is_empty():
			if int(budget_block.get("cpu", -1)) == volume.cpu_resident_budget_bytes \
					and int(budget_block.get("gpu", -1)) == volume.gpu_resident_budget_bytes:
				_budget_blocked_pages += 1
				continue
			_budget_blocked_versions.erase(failure_key)
		candidates.append(key)
	candidates.sort_custom(func(a: String, b: String) -> bool:
			return float(_active_metadata[a].get("_priority", INF)) \
					< float(_active_metadata[b].get("_priority", INF)))
	var inflight_limit := clampi(volume.max_inflight_page_loads, 1, 2)
	for key in candidates:
		if _loads.size() + _emission_tasks.size() >= inflight_limit:
			break
		var metadata: Dictionary = _active_metadata[key]
		var estimated_bytes := int(metadata.get("cpu_bytes", 0))
		var estimated_gpu_bytes := int(metadata.get("gpu_bytes", 0))
		if estimated_bytes <= 0 or estimated_gpu_bytes <= 0:
			_failed_versions[_page_identity(metadata)] = true
			_failure_warning = "Page %s has invalid residency metadata." % key
			warning = _failure_warning
			continue
		if prepared_source_header != null:
			estimated_gpu_bytes = 0 # Renderer accounts its actual resident cell pool.
		if estimated_bytes > volume.cpu_resident_budget_bytes \
				or estimated_gpu_bytes > volume.gpu_resident_budget_bytes:
			_budget_blocked_versions[_page_identity(metadata)] = {
				"cpu": volume.cpu_resident_budget_bytes,
				"gpu": volume.gpu_resident_budget_bytes,
			}
			_budget_blocked_pages += 1
			warning = "Page %s exceeds the current CPU/GPU residency budget." % key
			continue
		if resident_cpu_bytes() + inflight_cpu_bytes() + estimated_bytes > volume.cpu_resident_budget_bytes \
				or resident_gpu_bytes() + inflight_gpu_bytes() + estimated_gpu_bytes > volume.gpu_resident_budget_bytes:
			_budget_blocked_pages += candidates.size() - candidates.find(key)
			continue
		var path := String(metadata.get("resource_path", ""))
		if path.is_empty() or not ResourceLoader.exists(path):
			_failed_versions[_page_identity(metadata)] = true
			_failure_warning = "Page %s is missing its immutable resource path." % key
			warning = _failure_warning
			continue
		var load_error := ResourceLoader.load_threaded_request(path)
		if load_error != OK and load_error != ERR_BUSY:
			_failure_warning = "Could not start asynchronous load for page %s." % key
			warning = _failure_warning
			continue
		_loads[key] = {
			"stage": "resource", "path": path,
			"page_key": key,
			"page_generation": String(metadata.get("page_generation", _manifest.generation)),
			"version": int(metadata.get("version", 0)),
			"content_hash": String(metadata.get("content_hash", "")),
			"manifest_token": _manifest_token,
			"reserved_cpu_bytes": estimated_bytes,
			"reserved_gpu_bytes": estimated_gpu_bytes,
			"priority": float(metadata.get("_priority", INF)),
			"started": now_msec,
		}

func _advance_emission_updates(volume: FMagicGIVolume) -> void:
	var now := Time.get_ticks_msec()
	if prepared_source_header != null:
		var values := _prepared_emission.read_prepared_source_values(volume, prepared_source_header)
		if values != _prepared_emission_values:
			_prepared_emission_values = values
			_revision += 1
		# One global binding read, shared by every immutable brick in the generation.
		for resident in _resident.values():
			var descriptor: Dictionary = resident.get("descriptor", {})
			if descriptor.get("brick", null) != null:
				descriptor["emission_sources"] = _prepared_emission_values
				descriptor["emission_warning"] = _prepared_emission.get_warning()
				descriptor["emission_revision"] = _revision
	for task_id_value in _emission_tasks.keys():
		var task_id := int(task_id_value)
		if not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		var record: Dictionary = _emission_tasks[task_id]
		_emission_tasks.erase(task_id)
		var job: EmissionJob = record.get("job")
		var key := String(record.get("page_key", ""))
		var resident: Dictionary = _resident.get(key, {})
		if resident.get("emission_task", -1) == task_id:
			resident.erase("emission_task")
		if bool(record.get("discard", false)) or job == null or not job.valid or resident.is_empty() \
				or int(resident.get("version", -1)) != int(record.get("version", -2)) \
				or String(resident.get("base_identity", "")) != String(record.get("identity", "")):
			if not resident.is_empty():
				_resident[key] = resident
			continue
		_revision += 1
		var descriptor: Dictionary = resident.descriptor
		descriptor["emission_payload"] = job.payload
		descriptor["emission_sources"] = record.sources
		descriptor["emission_image"] = job.image
		descriptor["emission_revision"] = _revision
		resident["descriptor"] = descriptor
		resident["last_used"] = now
		_resident[key] = resident
	# Free-space PRT keeps one stable emitter binding per baked source and consumes
	# current six-float material weights. Refresh those small snapshots on every
	# streamer publication; a disabled material produces zero and re-enabling it
	# restores the same slot without rebaking or reordering the matrix.
	for key_value in _active_metadata.keys():
		var source_key := String(key_value)
		var source_resident: Dictionary = _resident.get(source_key, {})
		if source_resident.is_empty():
			continue
		var source_page: Page = source_resident.get("page")
		if source_page == null or source_page.data != null \
				or not source_page.free_space_volume_source is VolumeSourceChunk:
			continue
		var source_descriptor: Dictionary = source_resident.descriptor
		var source_state: Emission = source_resident.get("emission_state")
		if source_state == null:
			continue
		var source_values := source_state.read_volume_source_values(volume,
				source_page.free_space_volume_source)
		if source_values == source_descriptor.get("emission_sources", PackedFloat32Array()):
			source_descriptor["emission_warning"] = source_state.get_warning()
			source_resident["descriptor"] = source_descriptor
			_resident[source_key] = source_resident
			continue
		_revision += 1
		source_descriptor["emission_sources"] = source_values
		source_descriptor["emission_revision"] = _revision
		source_descriptor["emission_warning"] = source_state.get_warning()
		source_resident["descriptor"] = source_descriptor
		source_resident["last_used"] = now
		_resident[source_key] = source_resident
	if now < _last_emission_refresh + 500:
		return
	_last_emission_refresh = now
	var max_async_tasks := clampi(volume.max_inflight_page_loads, 1, 2)
	for key_value in _active_metadata.keys():
		if _loads.size() + _emission_tasks.size() >= max_async_tasks:
			break
		var key := String(key_value)
		var resident: Dictionary = _resident.get(key, {})
		if resident.is_empty() or resident.has("emission_task"):
			continue
		var descriptor: Dictionary = resident.descriptor
		var page: Page = resident.page
		if page == null or page.data == null:
			continue # Source-only pages were refreshed above without legacy payload jobs.
		var source_state: Emission = resident.emission_state
		var source_values: PackedFloat32Array = source_state.read_source_values(volume, page.data)
		if source_values == descriptor.get("emission_sources", PackedFloat32Array()):
			continue
		var job := EmissionJob.new()
		job.configure(page.data, source_values)
		var transient_bytes := _estimate_emission_transient_bytes(page.data, source_values)
		if resident_cpu_bytes() + inflight_cpu_bytes() + transient_bytes > volume.cpu_resident_budget_bytes:
			_budget_blocked_pages += 1
			warning = "Dynamic emission refresh is waiting for the CPU residency budget."
			continue
		var task_id := WorkerThreadPool.add_task(Callable(job, "run"), false, "Magic GI Emission Refresh")
		if task_id < 0:
			continue
		resident["emission_task"] = task_id
		_resident[key] = resident
		_emission_tasks[task_id] = {"page_key": key, "version": int(descriptor.version),
			"identity": String(descriptor.identity), "job": job, "sources": source_values,
			"transient_cpu_bytes": transient_bytes}

func _estimate_emission_transient_bytes(data: Data, source_values: PackedFloat32Array) -> int:
	var probe_count := data.probe_count()
	var payload_bytes := probe_count * 3 * 4
	var image_bytes := Data.ATLAS_COLUMNS * ceili(float(probe_count) / Data.ATLAS_COLUMNS) * 16
	return payload_bytes * 2 + source_values.size() * 4 + image_bytes

func _resident_page_matches(page_key: String, metadata: Dictionary) -> bool:
	var resident: Dictionary = _resident.get(page_key, {})
	return not resident.is_empty() \
			and resident.get("content_hash", "") == metadata.get("content_hash", "") \
			and resident.get("page_generation", "") == metadata.get("page_generation", _manifest.generation) \
			and resident.get("path", "") == metadata.get("resource_path", "")

func _record_matches_current_manifest(page_key: String, record: Dictionary) -> bool:
	if _manifest == null or not is_instance_valid(_manifest):
		return false
	var metadata := _manifest.get_page_metadata(page_key)
	return not metadata.is_empty() and not bool(metadata.get("empty", false)) \
			and String(metadata.get("resource_path", "")) == String(record.get("path", "")) \
			and String(metadata.get("content_hash", "")) == String(record.get("content_hash", ""))

func _fail_load(page_key: String, record: Dictionary, reason: String) -> void:
	var identity := _page_identity(record)
	if not identity.is_empty():
		_failed_versions[identity] = true
	warning = "Magic GI page %s could not be prepared: %s" % [page_key, reason]
	_failure_warning = warning
	_loads.erase(page_key)

func _page_identity(metadata: Dictionary) -> String:
	var manifest_generation := _manifest.generation if _manifest != null else ""
	return "%s/%s/%s/%s" % [str(metadata.get("page_generation", manifest_generation)),
		str(metadata.get("page_key", "")), str(metadata.get("version", "")),
		str(metadata.get("content_hash", ""))]

func _view_key(target_id: int, view_id: int) -> String:
	return "%d:%d" % [target_id, view_id]

static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
			and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0
