@tool
extends RefCounted
## Owns hidden reflection passes and derives their placement from authored entries.
## Capture plans omit recursive reflection work; authored resources stay unchanged.

const BuiltinPass = preload("../passes/builtin_pass.gd")
const NativeSpec = preload("native_spec.gd")
const ResolvePass = preload("../passes/reflection_resolve_pass.gd")
const Settings = preload("../reflection_settings.gd")
const PROBE_PATH := "res://addons/feng-reflect-probe/passes/feng_reflect_probe_pass.gd"

var _resolve: FengPass
var _probe: FengPass
var _probe_checked := false

func build(passes: Array[FengPass], enabled_fn: Callable, legacy_priority: Array[int], capture: bool) -> Array[FengPass]:
	var entries: Array[FengPass] = []
	var sky_index := -1
	var resolve_index := -1
	var authored_resolve: FengPass
	var has_probe := false
	for entry in passes:
		var source := entry.get_parameter_source() if entry != null else null
		var kind := source.get_reflection_source_kind() if source != null else &""
		if capture and kind in [&"resolve", &"feng_probe"]:
			continue
		if sky_index < 0 and entry is BuiltinPass and entry.native_id == NativeSpec.PASS_SKY:
			sky_index = entries.size()
		if entry != null and enabled_fn.call(entry):
			if kind == &"resolve" and authored_resolve == null:
				authored_resolve = source
				resolve_index = entries.size()
			elif kind == &"feng_probe":
				has_probe = true
		entries.append(entry)
	if capture:
		return entries

	var resolver := authored_resolve if authored_resolve != null else _get_resolve()
	var priority: Array = legacy_priority
	if authored_resolve != null:
		var authored_priority: Variant = authored_resolve.get("source_priority")
		if authored_priority is Array:
			priority = authored_priority
	Settings.publish_legacy_fallback_priority(resolver.get_instance_id(), priority)

	var insertion_index := sky_index if sky_index >= 0 else entries.size()
	if resolve_index >= 0:
		insertion_index = mini(insertion_index, resolve_index)
	var probe := _get_probe() if not has_probe else null
	if probe != null:
		entries.insert(insertion_index, probe)
		if sky_index >= insertion_index:
			sky_index += 1
	if authored_resolve == null:
		entries.insert(sky_index if sky_index >= 0 else entries.size(), resolver)
	return entries

func _get_resolve() -> FengPass:
	if _resolve == null:
		_resolve = ResolvePass.new()
		_resolve.resource_name = "Reflection Resolve (Internal)"
		_resolve.stable_id = &"internal:reflection_resolve"
		_resolve.enabled = true
	return _resolve

func _get_probe() -> FengPass:
	if _probe_checked:
		return _probe
	_probe_checked = true
	if not FileAccess.file_exists(PROBE_PATH):
		return null
	var script := load(PROBE_PATH) as Script
	if script == null or not script.can_instantiate():
		push_warning("FengRenderer: optional FengReflectProbe pass could not be loaded or compiled; reflection falls back to GI/SSR/Sky.")
		return null
	var candidate = script.new()
	if not candidate is FengPass or candidate.get_reflection_source_kind() != &"feng_probe":
		push_warning("FengRenderer: optional FengReflectProbe script does not implement the feng_probe candidate contract.")
		return null
	candidate.resource_name = "Feng Reflect Probe"
	candidate.stable_id = &"internal:feng_reflect_probe"
	candidate.enabled = true
	_probe = candidate
	return _probe
