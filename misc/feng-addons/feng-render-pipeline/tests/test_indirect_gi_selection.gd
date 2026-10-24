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
	var availability_script: Script = load("res://addons/feng-raytracing/passes/rtgi_runtime_availability.gd")
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

	rt.indirect_gi_available = false
	rt.hardware_rt_supported = false
	var unavailable_owner: Dictionary = selection.resolve(providers, Callable(self, "_enabled"))
	require(unavailable_owner.get("kind") == selection.KIND_MAGIC
			and unavailable_owner.get("key") == magic.key,
			"an enabled RTGI provider without ray-tracing capability must release the diffuse slot to MagicGI")
	var unavailable_providers: Array = unavailable_owner.get("unavailable_providers", [])
	require(not unavailable_providers.is_empty()
			and unavailable_providers[0].get("reason") == "fixture_raytracing_unavailable",
			"the fallback plan must retain a readable RTGI-unavailable reason")
	var unavailable_injected: Dictionary = selection.inject({rt.key: {"strength": 1.0}, magic.key: {}},
			providers, unavailable_owner)
	var unavailable_rt_packet: Dictionary = unavailable_injected[rt.key][selection.OWNER_PARAMETER]
	var available_magic_packet: Dictionary = unavailable_injected[magic.key][selection.OWNER_PARAMETER]
	require(not selection.is_resolved_owner(unavailable_rt_packet, rt.key, selection.KIND_RT, {"strength": 1.0})
			and selection.is_resolved_owner(available_magic_packet, magic.key, selection.KIND_MAGIC, {}),
			"unsupported RTGI must not block MagicGI or leave both diffuse writers active")
	rt.indirect_gi_available = true
	rt.hardware_rt_supported = true
	rt.omit_indirect_gi_availability_flag = true
	var malformed_owner: Dictionary = selection.resolve(providers, Callable(self, "_enabled"))
	require(malformed_owner.get("kind") == selection.KIND_MAGIC,
			"an RTGI provider with a malformed availability packet must fail closed to MagicGI")
	rt.omit_indirect_gi_availability_flag = false

	# Simulate capability passing but first diffuse dispatch failing. The state keeps
	# RTGI out of the next plan, then permits a later retry and clears after success.
	var availability_state: RefCounted = availability_script.new()
	var initial_status: Dictionary = availability_state.get_status(true, "", "Fixture GPU", 100)
	require(bool(initial_status.get("available", false))
			and initial_status.get("state") == "probe_pending",
			"supported RT hardware must get one initial diffuse attempt")
	availability_state.report_diffuse_result(false, "fixture_trace_failed", 100)
	var failed_status: Dictionary = availability_state.get_status(true, "", "Fixture GPU", 101)
	require(not bool(failed_status.get("available", true))
			and failed_status.get("reason") == "fixture_trace_failed",
			"a real diffuse attempt failure must expose its reason for the following frame")
	rt.indirect_gi_available = bool(failed_status.get("available", false))
	rt.hardware_rt_supported = bool(failed_status.get("hardware_supported", false))
	rt.indirect_gi_unavailable_reason = str(failed_status.get("reason", ""))
	var next_frame_owner: Dictionary = selection.resolve(providers, Callable(self, "_enabled"))
	var next_frame_packets: Dictionary = selection.inject({rt.key: {"strength": 1.0}, magic.key: {}},
			providers, next_frame_owner)
	var failed_rt_owner: Dictionary = next_frame_packets[rt.key][selection.OWNER_PARAMETER]
	var fallback_magic_owner: Dictionary = next_frame_packets[magic.key][selection.OWNER_PARAMETER]
	var runtime_unavailable: Array = next_frame_owner.get("unavailable_providers", [])
	require(next_frame_owner.get("kind") == selection.KIND_MAGIC
			and not runtime_unavailable.is_empty()
			and runtime_unavailable[0].get("reason") == "fixture_trace_failed",
			"the next plan after trace failure must hand diffuse ownership back to MagicGI with the failure reason")
	require(not selection.is_resolved_owner(failed_rt_owner, rt.key, selection.KIND_RT, {"strength": 1.0})
			and selection.is_resolved_owner(fallback_magic_owner, magic.key, selection.KIND_MAGIC, {}),
			"runtime fallback must leave exactly one diffuse writer after an RTGI failure")
	require(selection.is_resolved_reflection_owner(failed_rt_owner, rt.key),
			"a diffuse-only runtime failure must keep the hardware-capable RTGI reflection slot independent")
	var retry_status: Dictionary = availability_state.get_status(true, "", "Fixture GPU", 220)
	require(bool(retry_status.get("available", false))
			and retry_status.get("state") == "retry_probe",
			"a transient failure must be eligible for one later retry after the cooldown")
	rt.indirect_gi_available = true
	rt.hardware_rt_supported = true
	var retry_owner: Dictionary = selection.resolve(providers, Callable(self, "_enabled"))
	require(retry_owner.get("kind") == selection.KIND_RT,
			"a recovered RTGI probe must reclaim the diffuse slot on a later frame")
	availability_state.report_diffuse_result(true, "", 221)
	var recovered_status: Dictionary = availability_state.get_status(true, "", "Fixture GPU", 222)
	require(bool(recovered_status.get("available", false))
			and recovered_status.get("state") == "ready"
			and recovered_status.get("reason", "").is_empty(),
			"a successful diffuse composite must clear the runtime failure state")
	rt.indirect_gi_available = true

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
