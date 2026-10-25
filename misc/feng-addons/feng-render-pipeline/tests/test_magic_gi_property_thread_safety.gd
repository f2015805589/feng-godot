extends SceneTree
## Exercises CompositorEffect property validation on a worker without a Node tree.
## Run with --headless --editor --path <project-with-addons> --script
## res://addons/feng-render-pipeline/tests/test_magic_gi_property_thread_safety.gd

const MagicGIPass = preload("../passes/magic_gi_pass.gd")
const Runtime = preload("../../feng-magic-gi/feng_magic_gi_runtime.gd")

var checks := 0
var failures := 0

class ValidationJob:
	extends RefCounted
	var result: Dictionary = {}
	func run(pass_resource: Resource) -> void:
		var property := {"name": "clv_debug_view_status", "usage": 0}
		pass_resource._validate_property(property)
		result = {"selected": pass_resource._magicdawn_backend_selected_for_inspector(),
			"usage": int(property.usage)}

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _set_runtime_snapshots(value: Array[Dictionary]) -> void:
	Runtime._mutex.lock()
	Runtime._snapshots = value
	Runtime._mutex.unlock()

func _run_worker_validate(pass_resource: Resource) -> Dictionary:
	var job := ValidationJob.new()
	var task_id := WorkerThreadPool.add_task(Callable(job, "run").bind(pass_resource), false,
		"Magic GI property thread safety regression")
	if task_id < 0:
		return {"error": "worker_task_start_failed"}
	while not WorkerThreadPool.is_task_completed(task_id):
		await process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)
	return job.result

func run() -> void:
	check(Engine.is_editor_hint(), "run this regression with --editor so inspector validation is enabled")
	var gi_pass := MagicGIPass.new()
	# Resolve the runtime provider on the main thread first. The worker callback
	# then reads only the mutex-protected immutable snapshot publication.
	check(gi_pass._get_runtime_script() != null, "Magic GI runtime provider resolves on main thread")
	var original_snapshots := Runtime.snapshots()

	_set_runtime_snapshots([{"clv_cache_backend": 1, "use_clv": true}])
	var selected := await _run_worker_validate(gi_pass)
	check(selected.get("selected", false), "worker sees selected backend in published snapshot")
	check(int(selected.get("usage", 0)) == (PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY),
		"selected status is read-only in the worker-validated property list")

	_set_runtime_snapshots([])
	var missing := await _run_worker_validate(gi_pass)
	check(not missing.get("selected", true), "worker handles an absent runtime snapshot")
	check(int(missing.get("usage", 0)) == PROPERTY_USAGE_STORAGE,
		"absent snapshot keeps status out of editor/serialization")

	_set_runtime_snapshots([{"clv_cache_backend": 1, "use_clv": false},
		{"clv_cache_backend": 0, "use_clv": true}])
	var ineligible := await _run_worker_validate(gi_pass)
	check(not ineligible.get("selected", true), "legacy and disabled snapshots are ignored")

	# A pass without its runtime script cache/path must degrade to legacy inspector
	# metadata, with no EditorInterface lookup or Node traversal.
	gi_pass._runtime_script_checked = true
	gi_pass._runtime_script = null
	var no_runtime_path := await _run_worker_validate(gi_pass)
	check(not no_runtime_path.get("selected", true), "missing runtime script path is safe")
	check(int(no_runtime_path.get("usage", 0)) == PROPERTY_USAGE_STORAGE,
		"missing runtime path keeps the status property hidden")

	_set_runtime_snapshots(original_snapshots)
	print("[MAGIC_GI_PROPERTY_THREAD_SAFETY] checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
