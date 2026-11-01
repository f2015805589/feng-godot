@tool
class_name FMagicGIOlvInferenceRunner
extends RefCounted
## Owns one isolated offline R5 worker for the duration of a MagicGI bake.
## The worker receives only captured geometry and source-probe positions,
## validity and bake bindings. It never receives labels or portal annotations.

const Payload = preload("feng_magic_gi_olv_probe_domain_payload.gd")
const FORMAT_JOB := "feng_magic_gi_olv_offline_inference_geometry_job_v1"
const FORMAT_RESULT := "feng_magic_gi_olv_offline_inference_result_v1"
const FORMAT_WORKER_STATUS := "feng_magic_gi_olv_inference_worker_status_v1"
## Production 200,052-parameter teacher at step 64,000; offline OLV updates only.
const MODEL_BUNDLE_PATH := "res://addons/feng-olv/model"
const EXPECTED_MODEL_BUNDLE_SHA256 := "fd077cc2ca7d9fc6f4a38b4d9f8f0604406cfcebb624a6bec2f0340453af4567"
const EXPECTED_FEATURE_SCHEMA_ID := "feng_magic_gi_olv_surface_patch_horizon16_center4origin_ray_geometry_v2"
const EXPECTED_FEATURE_SCHEMA_SHA256 := "c13e9ab78c57ab52010a589c09ebb07726372c3a363245b6e80c4eed2425f383"
const EXPECTED_DECISION_POLICY_ID := "olv_binary2000_center_single_view_argmax_v2"
const TARGET_CELL_SPACINGS_M := [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0]
const MAX_WORKER_START_MSEC := 300000
const MAX_WORKER_STOP_MSEC := 30000

var _root := ""
var _worker_dir := ""
var _process_id := -1
var _tree: SceneTree
var _closed := false
var _bundle_path := MODEL_BUNDLE_PATH
var _expected_bundle_sha256 := EXPECTED_MODEL_BUNDLE_SHA256
var _last_good_json_by_path: Dictionary = {}
var _last_snapshot_by_path: Dictionary = {}


static func begin_bake(progress := Callable(), cancelled := Callable(),
		bundle_path := MODEL_BUNDLE_PATH, bundle_sha256 := EXPECTED_MODEL_BUNDLE_SHA256) -> Dictionary:
	var runner := FMagicGIOlvInferenceRunner.new()
	runner._bundle_path = bundle_path
	runner._expected_bundle_sha256 = bundle_sha256
	var started: Dictionary = await runner._start(progress, cancelled)
	if not bool(started.get("ok", false)):
		await runner.close()
		return started
	return {"ok": true, "runner": runner}


func infer_source(source: Resource, geometry: RefCounted, binding: Dictionary,
		progress := Callable(), cancelled := Callable()) -> Dictionary:
	if _closed or _process_id <= 0 or not OS.is_process_running(_process_id):
		return _failure("OLV offline worker is not running.")
	if source == null or geometry == null or not geometry.get("bvh_ready"):
		return _failure("OLV inference needs the classified source and captured triangle geometry.")
	for key in ["scene_id", "volume_id", "layout_revision", "target_layout_signature"]:
		if not binding.has(key):
			return _failure("OLV inference layout binding is missing: " + key)
	var source_binding: Dictionary = Payload.source_binding(source)
	if not bool(source_binding.get("ok", false)):
		return _failure("Could not bind source probes for OLV inference: " + String(source_binding.get("error", "unknown")))
	var faces: PackedByteArray = geometry.faces.to_byte_array()
	if faces.is_empty() or faces.size() % 36 != 0 \
			or Payload.sha256_bytes(faces) != String(source.geometry_triangles_sha256):
		return _failure("Captured Placement.faces do not match the source chunk's exact triangle SHA-256.")
	if source.probe_count <= 0 or source.probe_count > Payload.MAX_PROBES \
			or source.validity.size() != source.probe_count:
		return _failure("OLV inference source probe count or validity array is invalid.")
	var positions := PackedFloat32Array()
	positions.resize(source.probe_count * 3)
	var logical_positions := PackedVector3Array()
	logical_positions.resize(source.probe_count)
	for index in source.probe_count:
		var point: Vector3 = source.cell_position(index)
		if not point.is_finite():
			return _failure("Source probe position is not finite at logical index %d." % index)
		logical_positions[index] = point
		positions[index * 3] = point.x
		positions[index * 3 + 1] = point.y
		positions[index * 3 + 2] = point.z
	var position_bytes := positions.to_byte_array()
	var validity_bytes: PackedByteArray = source.validity.duplicate()
	if position_bytes.size() != source.probe_count * 12 or validity_bytes.size() != source.probe_count:
		return _failure("OLV geometry job arrays do not match the source logical probe count.")
	var request_id := "r_%d_%d_%d" % [Time.get_ticks_usec(), OS.get_process_id(), randi()]
	var jobs_root := _worker_dir.path_join("jobs")
	var pending_root := jobs_root.path_join("." + request_id + ".pending")
	var request_root := jobs_root.path_join(request_id)
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(jobs_root)) != OK \
			or DirAccess.make_dir_absolute(ProjectSettings.globalize_path(pending_root)) != OK:
		return _failure("Could not create an isolated OLV inference request directory.")
	var file_records := {
		"geometry_faces.f32": faces,
		"source_positions.f32": position_bytes,
		"source_validity.u8": validity_bytes,
	}
	var file_hashes: Dictionary = {}
	for name: String in file_records:
		var bytes: PackedByteArray = file_records[name]
		var file := FileAccess.open(pending_root.path_join(name), FileAccess.WRITE)
		if file == null:
			await _remove_tree(pending_root)
			return _failure("Could not write OLV inference input %s (error %d)." % [name, FileAccess.get_open_error()])
		file.store_buffer(bytes)
		file.close()
		file_hashes[name] = Payload.sha256_bytes(bytes)
	var target_sha: Variant = binding.get("target_label_set_sha256")
	if target_sha != null and String(target_sha).is_empty():
		target_sha = null
	var job := {
		"format": FORMAT_JOB,
		"schema_version": 1,
		"probe_count": source.probe_count,
		"source_spacing_m": float(source.spacing_m),
		"source_geometry_signature": int(source.geometry_signature),
		"source_directional_signature": String(source.directional_source_signature),
		"source_layout_sha256": String(source_binding.source_layout_sha256),
		"probe_position_sha256": String(source_binding.probe_position_sha256),
		"geometry_triangles_sha256": String(source.geometry_triangles_sha256),
		"geometry_faces_file": {"path": "geometry_faces.f32", "sha256": file_hashes["geometry_faces.f32"]},
		"source_positions_file": {"path": "source_positions.f32", "sha256": file_hashes["source_positions.f32"]},
		"source_validity_file": {"path": "source_validity.u8", "sha256": file_hashes["source_validity.u8"]},
		"feature_context_extent_m": [0.5, 0.5, 0.5],
		"supported_target_cell_spacings_m": TARGET_CELL_SPACINGS_M.duplicate(),
		"scene_id": String(binding.scene_id),
		"volume_id": String(binding.volume_id),
		"layout_revision": int(binding.layout_revision),
		"target_layout_signature": String(binding.target_layout_signature),
		"target_label_set_sha256": target_sha,
	}
	var job_file := FileAccess.open(pending_root.path_join("job.json"), FileAccess.WRITE)
	if job_file == null:
		await _remove_tree(pending_root)
		return _failure("Could not write OLV geometry job JSON (error %d)." % FileAccess.get_open_error())
	job_file.store_string(JSON.stringify(job, "", true, true) + "\n")
	job_file.close()
	var rename_error := DirAccess.rename_absolute(ProjectSettings.globalize_path(pending_root),
			ProjectSettings.globalize_path(request_root))
	if rename_error != OK:
		await _remove_tree(pending_root)
		return _failure("Could not atomically publish OLV inference request (error %d)." % rename_error)
	var result := await _wait_for_request(request_id, request_root, source,
			source_binding, file_hashes, logical_positions, progress, cancelled)
	_forget_json_under(request_root)
	await _remove_tree(request_root)
	return result


func close() -> void:
	if _closed:
		return
	_closed = true
	if _process_id > 0 and OS.is_process_running(_process_id):
		var shutdown := FileAccess.open(_worker_dir.path_join("shutdown"), FileAccess.WRITE)
		if shutdown != null:
			shutdown.store_string("stop\n")
			shutdown.close()
		var deadline := Time.get_ticks_msec() + MAX_WORKER_STOP_MSEC
		while OS.is_process_running(_process_id) and Time.get_ticks_msec() < deadline:
			var status: Dictionary = _read_json(_worker_dir.path_join("worker_status.json"))
			if String(status.get("status", "")) == "stopped":
				break
			if _tree != null:
				await _tree.create_timer(0.1).timeout
			else:
				OS.delay_msec(100)
		if OS.is_process_running(_process_id):
			# This is the child process created by this runner; never search for or
			# terminate another Python/Godot process by name.
			OS.kill(_process_id)
			if _tree != null:
				await _tree.create_timer(0.1).timeout
		_process_id = -1
	if not _root.is_empty():
		_forget_json_under(_root)
		await _remove_tree(_root)


func _start(progress: Callable, cancelled: Callable) -> Dictionary:
	_tree = Engine.get_main_loop() as SceneTree
	if _tree == null:
		return _failure("OLV offline inference requires the editor SceneTree to remain responsive.")
	var base := ProjectSettings.globalize_path("res://.godot/feng-magic-gi/olv-inference")
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base)) != OK:
		return _failure("Could not create OLV's project cache directory: " + base)
	_root = base.path_join("bake_%d_%d_%d" % [Time.get_ticks_usec(), OS.get_process_id(), randi()])
	_worker_dir = _root.path_join("worker")
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_worker_dir)) != OK \
			or DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_worker_dir.path_join("jobs"))) != OK:
		return _failure("Could not create the isolated OLV worker directory.")
	var python := _python_executable()
	var script_path := ProjectSettings.globalize_path("res://addons/feng-olv/tools/inference.py")
	var bundle_path := ProjectSettings.globalize_path(_bundle_path)
	if not FileAccess.file_exists(script_path):
		return _failure("OLV offline inference script is missing: " + script_path)
	if not FileAccess.file_exists(bundle_path.path_join("inference_manifest.json")):
		return _failure("Frozen OLV model bundle is missing its inference manifest: " + bundle_path)
	var args := PackedStringArray([script_path, "--worker-dir", _worker_dir,
		"--bundle", bundle_path, "--device", "auto", "--batch-size", "32",
		"--poll-interval-ms", "100"])
	_process_id = OS.create_process(python, args, false)
	if _process_id <= 0:
		return _failure("Could not start the configured OLV Python worker (%s). Check the Python runtime and model dependencies." % python)
	var started_at := Time.get_ticks_msec()
	var last_report := 0
	while Time.get_ticks_msec() - started_at < MAX_WORKER_START_MSEC:
		if cancelled.is_valid() and bool(cancelled.call()):
			await close()
			return _failure("OLV inference was cancelled while loading the offline model.")
		var worker_status: Dictionary = _read_json(_worker_dir.path_join("worker_status.json"))
		if String(worker_status.get("format", "")) == FORMAT_WORKER_STATUS:
			var status := String(worker_status.get("status", ""))
			if status == "ready":
				if String(worker_status.get("bundle_sha256", "")) != _expected_bundle_sha256:
					return _failure("OLV worker loaded a model bundle different from the one pinned by this add-on.")
				return {"ok": true}
			if status == "failed":
				return _failure("OLV offline model worker failed: " + String(worker_status.get("error", "unknown startup error")))
		if not OS.is_process_running(_process_id):
			var exit_code := OS.get_process_exit_code(_process_id)
			return _failure("OLV offline model worker exited before becoming ready (exit %d): %s" % [
				exit_code, String(worker_status.get("error", "no worker status was written"))])
		if Time.get_ticks_msec() - last_report >= 500:
			last_report = Time.get_ticks_msec()
			if progress.is_valid():
				progress.call("加载 OLV 离线模型", 0, 1, 0, 0)
		await _tree.create_timer(0.1).timeout
	return _failure("OLV offline model worker did not become ready within %d seconds." % (MAX_WORKER_START_MSEC / 1000))


func _wait_for_request(request_id: String, request_root: String, source: Resource,
		source_binding: Dictionary, file_hashes: Dictionary,
		logical_positions: PackedVector3Array, progress: Callable,
		cancelled: Callable) -> Dictionary:
	var status_path := request_root.path_join("status.json")
	var progress_path := request_root.path_join("progress.json")
	var cancel_path := request_root.path_join("cancel")
	var last_progress_key := ""
	var cancel_written := false
	while true:
		if not cancel_written and cancelled.is_valid() and bool(cancelled.call()):
			var cancel_file := FileAccess.open(cancel_path, FileAccess.WRITE)
			if cancel_file != null:
				cancel_file.store_string("cancel\n")
				cancel_file.close()
				cancel_written = true
		var progress_event: Dictionary = _read_json(progress_path)
		var progress_key := "%s:%s:%s" % [String(progress_event.get("stage", "")),
			str(progress_event.get("done", 0)), str(progress_event.get("total", 0))]
		if progress_key != last_progress_key and progress.is_valid():
			last_progress_key = progress_key
			var stage := "OLV Transformer 离线推理"
			if not String(progress_event.get("stage", "")).is_empty():
				stage += " · " + String(progress_event.stage)
			progress.call(stage, int(progress_event.get("done", 0)),
				int(progress_event.get("total", 0)), 0, 0)
		var status: Dictionary = _read_json(status_path)
		var state := String(status.get("status", ""))
		if state == "complete":
			return _load_request_result(request_id, request_root, source,
				source_binding, file_hashes, logical_positions, status)
		if state in ["failed", "cancelled"]:
			var error := String(status.get("error", progress_event.get("error", state)))
			return _failure("OLV inference %s: %s" % [state, error])
		if not OS.is_process_running(_process_id):
			var worker_status: Dictionary = _read_json(_worker_dir.path_join("worker_status.json"))
			return _failure("OLV inference worker exited unexpectedly (exit %d, state %s): %s" % [
				OS.get_process_exit_code(_process_id), state,
				String(worker_status.get("error", "request status was not completed"))])
		await _tree.create_timer(0.1).timeout
	return _failure("OLV inference worker request ended without a terminal status.")


func _load_request_result(request_id: String, request_root: String, source: Resource,
		source_binding: Dictionary, file_hashes: Dictionary,
		logical_positions: PackedVector3Array, status: Dictionary) -> Dictionary:
	if String(status.get("request_id", "")) != request_id \
			or int(status.get("probe_count", -1)) != source.probe_count:
		return _failure("OLV worker completion status is not bound to this request/source.")
	var output_root := request_root.path_join("output")
	var result: Dictionary = _read_json(output_root.path_join("result.json"))
	if String(result.get("format", "")) != FORMAT_RESULT \
			or int(result.get("schema_version", -1)) != 1 \
			or String(result.get("status", "")) != "complete" \
			or int(result.get("probe_count", -1)) != source.probe_count \
			or int(result.get("label_byte_count", -1)) != source.probe_count \
			or String(result.get("labels_file", "")) != "labels.bin":
		return _failure("OLV inference result header or logical label byte count is invalid.")
	if String(status.get("labels_sha256", "")) != String(result.get("labels_sha256", "")):
		return _failure("OLV worker status and result disagree on the labels SHA-256.")
	var model: Dictionary = result.get("model_bundle", {})
	var metadata: Dictionary = result.get("payload_metadata_for_configure_for_source", {})
	if String(model.get("inference_manifest_sha256", "")) != _expected_bundle_sha256 \
			or String(metadata.get("model_sha256", "")) != _expected_bundle_sha256 \
			or String(metadata.get("feature_schema_id", "")) != EXPECTED_FEATURE_SCHEMA_ID \
			or String(metadata.get("feature_schema_sha256", "")) != EXPECTED_FEATURE_SCHEMA_SHA256 \
			or String(metadata.get("decision_policy_id", "")) != EXPECTED_DECISION_POLICY_ID:
		return _failure("OLV inference output does not match the frozen candidate, feature contract, and decision policy pinned by this add-on.")
	var result_binding: Dictionary = result.get("source_binding", {})
	for pair in [["probe_count", source.probe_count],
		["source_spacing_m", float(source.spacing_m)],
		["source_geometry_signature", int(source.geometry_signature)],
		["source_directional_signature", String(source.directional_source_signature)],
		["source_layout_sha256", String(source_binding.source_layout_sha256)],
		["probe_position_sha256", String(source_binding.probe_position_sha256)],
		["geometry_triangles_sha256", String(source.geometry_triangles_sha256)],
		["geometry_faces_file_sha256", String(file_hashes["geometry_faces.f32"])],
		["source_positions_file_sha256", String(file_hashes["source_positions.f32"])],
		["source_validity_file_sha256", String(file_hashes["source_validity.u8"])]]:
		if not result_binding.has(pair[0]) or result_binding[pair[0]] != pair[1]:
			return _failure("OLV inference source binding mismatch: " + String(pair[0]))
	for pair in [["scene_id", String(metadata.get("scene_id", ""))],
		["volume_id", String(metadata.get("volume_id", ""))],
		["layout_revision", int(metadata.get("layout_revision", -1))],
		["target_layout_signature", String(metadata.get("target_layout_signature", ""))]]:
		if not metadata.has(pair[0]) or metadata[pair[0]] != pair[1]:
			return _failure("OLV inference layout metadata is incomplete: " + String(pair[0]))
	var labels_path := output_root.path_join("labels.bin")
	var labels := FileAccess.get_file_as_bytes(labels_path)
	if labels.size() != source.probe_count \
			or Payload.sha256_bytes(labels) != String(result.get("labels_sha256", "")):
		return _failure("OLV inference labels.bin failed byte count or SHA-256 validation.")
	for index in labels.size():
		var label := int(labels[index])
		if (not source.cell_is_valid(index) and label != 0) \
				or (source.cell_is_valid(index) and label not in [1, 2]):
			return _failure("OLV inference label code disagrees with source validity at logical probe %d." % index)
	metadata["supported_target_cell_spacings_m"] = PackedFloat32Array(TARGET_CELL_SPACINGS_M)
	metadata["feature_context_extent_m"] = Vector3(0.5, 0.5, 0.5)
	metadata["supported_feature_context_extents_m"] = PackedVector3Array([Vector3(0.5, 0.5, 0.5)])
	metadata["source_probe_positions"] = logical_positions
	metadata["target_label_set_sha256"] = ""
	return {"ok": true, "labels": labels, "metadata": metadata,
		"result": result, "worker_request_id": request_id}


func _python_executable() -> String:
	var configured := OS.get_environment("FENG_OLV_PYTHON")
	if not configured.is_empty() and FileAccess.file_exists(configured):
		return configured
	var local_app_data := OS.get_environment("LOCALAPPDATA")
	if not local_app_data.is_empty():
		var bundled := local_app_data.path_join("Temp/feng-olv-r3-torch-cu130/Scripts/python.exe")
		if FileAccess.file_exists(bundled):
			return bundled
	return "python" if OS.has_feature("windows") else "python3"


func _read_json(path: String) -> Dictionary:
	var cached: Dictionary = _last_good_json_by_path.get(path, {})
	var read_path := path
	var snapshots := path + ".snapshots"
	if DirAccess.dir_exists_absolute(snapshots):
		var latest := ""
		for name in DirAccess.get_files_at(snapshots):
			if name.ends_with(".json") and name > latest:
				latest = name
		if latest.is_empty() or latest == String(_last_snapshot_by_path.get(path, "")):
			return cached.duplicate(true)
		read_path = snapshots.path_join(latest)
	# The worker creates status/progress files after process startup. Avoid a
	# noisy FileAccess error during that normal first-poll window. A file can
	# still disappear between this check and open, so keep the fallback below.
	if not FileAccess.file_exists(read_path):
		return cached.duplicate(true)
	var file := FileAccess.open(read_path, FileAccess.READ)
	if file == null:
		return cached.duplicate(true)
	var content := file.get_as_text()
	file.close()
	if content.strip_edges().is_empty():
		return cached.duplicate(true)
	var parser := JSON.new()
	if parser.parse(content) != OK or not parser.data is Dictionary:
		return cached.duplicate(true)
	var parsed: Dictionary = parser.data
	_last_good_json_by_path[path] = parsed.duplicate(true)
	if read_path != path:
		_last_snapshot_by_path[path] = read_path.get_file()
	return parsed


func _forget_json_under(path: String) -> void:
	var prefix := path.trim_suffix("/") + "/"
	for cached_path in _last_good_json_by_path.keys():
		var key := String(cached_path)
		if key == path or key.begins_with(prefix):
			_last_good_json_by_path.erase(key)
			_last_snapshot_by_path.erase(key)


func _remove_tree(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(absolute):
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(absolute)
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var child := directory.get_next()
	while not child.is_empty():
		if child != "." and child != "..":
			var child_path := path.path_join(child)
			if directory.current_is_dir():
				await _remove_tree(child_path)
			else:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(child_path))
		child = directory.get_next()
	directory.list_dir_end()
	directory = null
	DirAccess.remove_absolute(absolute)


static func _failure(error: String) -> Dictionary:
	return {"ok": false, "error": error}
