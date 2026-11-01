extends SceneTree

const Runner = preload("../feng_magic_gi_olv_inference_runner.gd")

var _failures := 0
var _checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var reader: RefCounted = Runner.new()
	var root := ProjectSettings.globalize_path("res://.godot/feng-magic-gi").path_join(
		"progress-reader-test-%d" % Time.get_ticks_usec())
	var path := root.path_join("progress.json")
	if DirAccess.make_dir_recursive_absolute(root) != OK:
		_check(false, "create isolated progress-reader test directory")
		print("MAGIC_GI_OLV_PROGRESS_READER_RESULT failures=", _failures,
			" checks=", _checks)
		quit(1)
		return
	_check(_write(path, "{\"stage\":\"inference\",\"done\":4,\"total\":8}"),
		"write initial complete snapshot")
	var first: Dictionary = reader.call("_read_json", path)
	_check(String(first.get("stage", "")) == "inference" \
			and int(first.get("done", -1)) == 4 and int(first.get("total", -1)) == 8,
		"read initial valid progress snapshot")
	_check(_write(path, "{\"stage\":\"infer"), "write partial replacement")
	var partial: Dictionary = reader.call("_read_json", path)
	_check(partial == first, "malformed concurrent replacement keeps last-good state")
	_check(_write(path, ""), "write empty replacement")
	var empty: Dictionary = reader.call("_read_json", path)
	_check(empty == first, "empty concurrent replacement keeps last-good state")
	_check(_write(path, "{\"stage\":\"complete\",\"done\":8,\"total\":8}"),
		"write final complete snapshot")
	var final: Dictionary = reader.call("_read_json", path)
	_check(String(final.get("stage", "")) == "complete" \
			and int(final.get("done", -1)) == 8 and int(final.get("total", -1)) == 8,
		"accept next complete progress snapshot")
	var snapshots := path + ".snapshots"
	_check(DirAccess.make_dir_absolute(snapshots) == OK, "create immutable mailbox")
	_check(_write(snapshots.path_join(".00000000000000000001.tmp"), "{"),
		"simulate worker writing an unpublished snapshot")
	_check(reader.call("_read_json", path) == final, "ignore incomplete unpublished files")
	_check(_write(snapshots.path_join("00000000000000000001.json"), "{\"done\":9}"),
		"publish closed snapshot")
	_check(int(reader.call("_read_json", path).get("done", -1)) == 9,
		"consume immutable snapshot instead of legacy mutable file")
	_check(_write(snapshots.path_join("00000000000000000002.json"), "{\"done\":10}"),
		"publish next snapshot without modifying the previous file")
	_check(int(reader.call("_read_json", path).get("done", -1)) == 10,
		"select newest snapshot")
	_check(int(reader.call("_read_json", path).get("done", -1)) == 10,
		"unchanged snapshot uses cached state")
	reader.call("_forget_json_under", root)
	_check(not reader.get("_last_good_json_by_path").has(path),
		"forget cached snapshots after request cleanup")
	_check(not reader.get("_last_snapshot_by_path").has(path), "forget snapshot generation")
	await reader.call("_remove_tree", root)
	print("MAGIC_GI_OLV_PROGRESS_READER_RESULT failures=", _failures,
		" checks=", _checks)
	quit(1 if _failures > 0 else 0)

func _write(path: String, content: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(content)
	file.close()
	return true

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + message)
	else:
		print("PASS: ", message)
