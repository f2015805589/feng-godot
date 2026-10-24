extends SceneTree
## CPU-only contract checks for the runtime Magic GI display source and controls.

const DebugPass = preload("res://addons/feng-render-pipeline/passes/debug_buffers_pass.gd")
const TextureInput = preload("res://addons/feng-render-pipeline/passes/pass_texture.gd")
const MagicGIDebugRequest = preload("res://addons/feng-render-pipeline/passes/magic_gi_debug_request.gd")

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var debug_pass := DebugPass.new()
	_check(debug_pass.gi_display_mode == 0,
		"Magic GI debug must default to display-only ACES HDR mapping")
	debug_pass.buffer = 6
	_check(debug_pass.inputs.size() == 2, "Magic GI debug keeps its producer and output bindings")
	if debug_pass.inputs.size() == 2:
		var source: Resource = debug_pass.inputs[1]
		_check(int(source.get("source")) == TextureInput.Source.CUSTOM
				and source.get("custom_scope") == TextureInput.PIPELINE_SCOPE
				and source.get("custom_name") == &"magic_gi",
			"Debug Buffers Magic GI must read the actual Magic GI producer output")
	var params: Dictionary = debug_pass.get_frp_parameters()
	_check(int(params.get("gi_display_mode", -1)) == 0,
		"default ACES selection must reach the shader parameters")
	debug_pass.gi_display_mode = 1
	params = debug_pass.get_frp_parameters()
	_check(int(params.get("gi_display_mode", -1)) == 1,
		"the unmapped diagnostic option must remain selectable")
	_check(float(params.get("gi_exposure", INF)) == 0.0,
		"display exposure must remain a debug-only pass parameter")
	debug_pass.enabled = true
	MagicGIDebugRequest.set_target_request(9001, debug_pass, true)
	_check(MagicGIDebugRequest.is_requested(9001),
		"an enabled Magic GI debug pass must request its producer sidecar")
	_check(MagicGIDebugRequest.is_requested(9002),
		"a live selected debug pass must bootstrap before the first render-target registration")
	debug_pass.enabled = false
	_check(not MagicGIDebugRequest.is_requested(9001),
		"disabling Debug Buffers must stop requesting standalone GI work")
	debug_pass.enabled = true
	_check(MagicGIDebugRequest.is_requested(9001),
		"reenabling the live debug pass must request the sidecar again")
	debug_pass.buffer = 0
	_check(not MagicGIDebugRequest.is_requested(9001),
		"switching away from Magic GI must clear the target request")
	print("DEBUG_BUFFERS_GI_DISPLAY checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)
