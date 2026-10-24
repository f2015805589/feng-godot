extends SceneTree
## Exercises the opt-in RTGI diagnostics against an empty/fake CPU-only scene state.

class SceneFixture extends RefCounted:
	var scene_rows: Array = []
	var tlas := RID()
	var surfaces := RID()
	var materials := RID()
	var emitters := RID()
	var geometry_key: Array = []
	var transform_key: Array = []

	func all_rids() -> Array[RID]:
		return []

class GPUFixture extends RefCounted:
	var pipeline := RID()

	func all_rids() -> Array[RID]:
		return []

var checks := 0
var failures := 0


func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var pass_script := load("res://addons/feng-raytracing/passes/feng_rt_gi_pass.gd") as Script
	require(pass_script != null, "RTGI pass script must load for the diagnostics fixture")
	if pass_script == null:
		_finish()
		return

	var pass_instance: Variant = pass_script.new()
	var scene := SceneFixture.new()
	scene.scene_rows = [
		{"blas": RID()},
		{},
		{"blas": "malformed"},
	]
	var gpu := GPUFixture.new()
	var state_key: Array = [RID(), 0]
	var states: Dictionary = {}
	states[state_key] = {
		"scene": scene,
		"gpu": gpu,
		"diffuse": {"resources": [], "raw": RID(), "resolved": RID(), "size": Vector2i(8, 4),
			"valid": false, "generation": 7, "denoiser": 0, "nrd_ready": false},
		"reflection": {},
		"sky_array": false,
	}
	pass_instance.set("_states", states)
	pass_instance.call("set_rtgi_diagnostics_enabled", true)
	var snapshot: Dictionary = pass_instance.call("get_rtgi_diagnostics_snapshot")
	var snapshot_states: Array = snapshot.get("states", [])
	require(bool(snapshot.get("enabled", false)), "diagnostics snapshot must remain enabled")
	require(snapshot_states.size() == 1, "snapshot must retain one registered view state")
	if snapshot_states.size() == 1:
		var state: Dictionary = snapshot_states[0]
		require(int(state.get("blas_count", -1)) == 0,
				"empty and invalid BLAS rows must report zero valid BLAS resources")
		require(state.get("diffuse_size", []) == [8, 4],
				"snapshot must return diffuse dimensions after tolerating invalid BLAS rows")
		require(not bool(state.get("tlas_valid", true)),
				"an invalid TLAS RID must be reported as not ready")
	_finish()


func _finish() -> void:
	print("RTGI_DIAGNOSTICS_SNAPSHOT checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
