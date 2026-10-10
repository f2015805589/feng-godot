extends SceneTree
## Keeps diffuse provider ownership independent from RTGI reflection execution.

var failures := 0
var checks := 0

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _enabled(entry: Variant) -> bool:
	return entry.enabled

func _volume_enabled(entry: Variant) -> bool:
	return true

func _has_warning(warnings: PackedStringArray, fragment: String) -> bool:
	for message in warnings:
		if message.contains(fragment):
			return true
	return false

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var selection: Script = load("res://addons/feng-render-pipeline/pipeline/indirect_gi_selection.gd")
	var validator: Script = load("res://addons/feng-render-pipeline/pipeline/pipeline_validator.gd")
	var native_spec: Script = load("res://addons/feng-render-pipeline/pipeline/native_spec.gd")
	var native_pass_script: Script = load("res://addons/feng-render-pipeline/passes/builtin_pass.gd")
	var provider_script: Script = load("res://addons/feng-render-pipeline/tests/indirect_gi_provider_fixture.gd")
	var rt: Variant = provider_script.new()
	rt.kind = selection.KIND_RT
	rt.key = "test:rt"
	rt.strength = 0.0 # Reflection-only authored default remains a diffuse candidate.
	rt.enabled = true
	var magic: Variant = provider_script.new()
	magic.kind = selection.KIND_MAGIC
	magic.key = "test:magic"
	magic.enabled = true
	var providers: Array = [rt, magic]
	var owner: Dictionary = selection.resolve(providers, Callable(self, "_enabled"))
	require(owner.get("kind") == selection.KIND_RT and owner.get("key") == rt.key,
			"RTGI must retain its planned diffuse slot when authored diffuse strength is zero")
	require(owner.get("fallback_kind") == selection.KIND_MAGIC and owner.get("fallback_key") == magic.key,
			"the unique MagicGI candidate must be retained as a frame-resolved fallback")

	var injected: Dictionary = selection.inject({rt.key: {"strength": 0.0}, magic.key: {}}, providers, owner)
	var rt_owner: Dictionary = injected[rt.key][selection.OWNER_PARAMETER]
	var magic_owner: Dictionary = injected[magic.key][selection.OWNER_PARAMETER]
	require(rt_owner.get("fallback_key", "") == magic.key and magic_owner.get("fallback_key", "") == magic.key,
			"injection must preserve fallback fields for every pass parameter source")
	require(not selection.is_resolved_owner(rt_owner, rt.key, selection.KIND_RT, {"strength": 0.0}),
			"resolved zero strength must release RTGI diffuse ownership")
	require(selection.is_resolved_owner(magic_owner, magic.key, selection.KIND_MAGIC, {"strength": 0.0}),
			"resolved zero RTGI strength must transfer diffuse ownership to MagicGI")
	require(selection.is_resolved_owner(rt_owner, rt.key, selection.KIND_RT, {"strength": 2.0}),
			"a Volume override to positive RTGI strength must restore RTGI diffuse ownership")
	require(not selection.is_resolved_owner(magic_owner, magic.key, selection.KIND_MAGIC, {"strength": 2.0}),
			"MagicGI must release the diffuse slot when a Volume enables RTGI")
	require(selection.is_resolved_owner(magic_owner, magic.key, selection.KIND_MAGIC, {}),
			"a missing RT strength must fail closed and leave diffuse ownership to MagicGI")
	require(selection.is_resolved_owner(magic_owner, magic.key, selection.KIND_MAGIC, {"strength": NAN}),
			"a non-finite RT strength must fail closed and leave diffuse ownership to MagicGI")

	var rt_only: Dictionary = selection.resolve([rt], Callable(self, "_enabled"))
	var rt_only_packet: Dictionary = selection.inject({rt.key: {}}, [rt], rt_only)[rt.key][selection.OWNER_PARAMETER]
	require(not selection.is_resolved_owner(rt_only_packet, rt.key, selection.KIND_RT, {}),
			"reflection-only RTGI must not claim diffuse ownership without positive resolved strength")
	require(selection.is_resolved_reflection_owner(rt_only_packet, rt.key),
			"reflection ownership must remain active when diffuse strength is zero")

	var second_rt: Variant = provider_script.new()
	second_rt.kind = selection.KIND_RT
	second_rt.key = "test:rt_second"
	second_rt.enabled = true
	var multiple_rt: Dictionary = selection.resolve([rt, second_rt, magic], Callable(self, "_enabled"))
	var multiple_injected: Dictionary = selection.inject({rt.key: {}, second_rt.key: {}, magic.key: {}},
			[rt, second_rt, magic], multiple_rt)
	var first_rt_packet: Dictionary = multiple_injected[rt.key][selection.OWNER_PARAMETER]
	var second_rt_packet: Dictionary = multiple_injected[second_rt.key][selection.OWNER_PARAMETER]
	require(bool(multiple_rt.get("blocked", false))
			and not selection.is_resolved_reflection_owner(first_rt_packet, rt.key)
			and not selection.is_resolved_reflection_owner(second_rt_packet, second_rt.key),
			"multiple enabled RTGI candidates must fail closed for the shared replacement slot")
	second_rt.enabled = false
	var single_enabled_rt: Dictionary = selection.resolve([rt, second_rt, magic], Callable(self, "_enabled"))
	var single_enabled_packet: Dictionary = selection.inject({rt.key: {}, magic.key: {}},
			[rt, second_rt, magic], single_enabled_rt)[rt.key][selection.OWNER_PARAMETER]
	require(selection.is_resolved_reflection_owner(single_enabled_packet, rt.key),
			"disabled duplicate RTGI passes must not block the sole enabled reflection provider")

	var late_rt = native_pass_script.new(native_spec.PASS_LIGHTING, "Lighting")
	var late_transparent = native_pass_script.new(native_spec.PASS_TRANSPARENT, "Transparent")
	var late_rtgi: Variant = provider_script.new()
	late_rtgi.kind = selection.KIND_RT
	late_rtgi.key = "test:late_rt"
	late_rtgi.required_before = PackedInt32Array([native_spec.PASS_TRANSPARENT])
	var schedule: Array = [late_rt, late_transparent, late_rtgi]
	var warnings: PackedStringArray = validator.validate_schedule(schedule, {}, {}, Callable(self, "_enabled"))
	require(_has_warning(warnings, "must precede native 'Transparent'"),
			"schedule validation must reject RTGI placed after the transparent/fog stage")
	var wrapped_late_rtgi: Variant = provider_script.new()
	wrapped_late_rtgi.kind = selection.KIND_RT
	wrapped_late_rtgi.key = "test:wrapped_late_rtgi"
	wrapped_late_rtgi.required_before = PackedInt32Array([native_spec.PASS_TRANSPARENT])
	var wrapped_native = native_pass_script.new(native_spec.PASS_LIGHTING, "Lighting")
	wrapped_native.implementation = wrapped_late_rtgi
	var wrapped_schedule: Array = [late_rt, late_transparent, wrapped_native]
	var wrapped_warnings: PackedStringArray = validator.validate_schedule(wrapped_schedule, {}, {}, Callable(self, "_enabled"))
	require(_has_warning(wrapped_warnings, "must precede native 'Transparent'"),
			"a late RTGI implementation carried by BuiltinPass must be rejected too")
	wrapped_late_rtgi.enabled = false
	var volume_enabled_warnings: PackedStringArray = validator.validate_schedule(wrapped_schedule, {}, {}, Callable(self, "_volume_enabled"))
	require(_has_warning(volume_enabled_warnings, "must precede native 'Transparent'"),
			"a Volume-enabled wrapped RTGI pass must retain its required native order when authored disabled")

	provider_script = null
	native_pass_script = null
	native_spec = null
	validator = null
	selection = null
	call_deferred("_finish", failures)

func _finish(exit_code: int) -> void:
	print("INDIRECT_GI_SELECTION checks=", checks, " failures=", exit_code)
	quit(1 if exit_code else 0)
