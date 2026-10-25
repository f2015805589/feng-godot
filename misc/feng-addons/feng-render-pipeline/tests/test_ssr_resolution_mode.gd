extends SceneTree
## CPU-only checks for the SSR resolution setting and its Volume override.

const SSRPass = preload("res://addons/feng-render-pipeline/passes/ssr_pass.gd")
const VolumeModule = preload("res://addons/feng-render-pipeline/volume/feng_volume_module.gd")

var failures := 0
var checks := 0

func _initialize() -> void:
	call_deferred("run")

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func run() -> void:
	var ssr = SSRPass.new()
	require(ssr.get("resolution_mode") == 0,
			"SSR must default to half resolution for the existing performance profile")
	require(ssr.get_volume_parameter_names().has("resolution_mode"),
			"SSR resolution mode must be authorable from a Volume")
	var volume = VolumeModule.from_pass(ssr, {"resolution_mode": 1})
	require(volume.get_parameters().get("resolution_mode", -1) == 1,
			"SSR Volume resolution mode must resolve the authored full-resolution override")
	print("[SSR_RESOLUTION_MODE_TEST] checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
