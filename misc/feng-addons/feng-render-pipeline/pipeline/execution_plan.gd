@tool
class_name FengExecutionPlan
extends RefCounted
## Pure schedule queries shared by the renderer and its compositor binding.
##
## The renderer owns authored resources, migration, observation and runtime state.
## This object only derives a candidate schedule from the already-normalized pass
## list. It must not change a pass, a contract, or a volume dictionary.

const BuiltinPass = preload("../passes/builtin_pass.gd")
const NativeSpec = preload("native_spec.gd")
const PipelineValidator = preload("pipeline_validator.gd")
const ParameterResolver = preload("parameter_resolver.gd")

const MANAGER_TOKEN := -1

## A native entry with an implementation is dispatched as a compositor effect. A
## plain custom FengPass is also dispatched as a compositor effect; a BuiltinPass
## without an implementation is the engine's native token.
static func is_scripted(pass_entry) -> bool:
	if pass_entry == null:
		return false
	if pass_entry is BuiltinPass:
		return (pass_entry as BuiltinPass).implementation != null
	return true

## Read a pass's declared native ownership without mutating the declaration.
static func declared_provides(pass_entry) -> Array:
	if pass_entry == null:
		return []
	var declared = pass_entry.get("provides_native_ids")
	if declared == null:
		return []
	return declared

## Resolve the effective enabled state for one frame. A Volume may address either
## the authored entry key or the carried source key (custom stable key or native
## id); the explicit key wins before the legacy native/provided-id aliases.
static func is_entry_enabled(pass_entry, volume_pass_states: Dictionary = {}) -> bool:
	if pass_entry == null:
		return false

	var entry_key: Variant = null
	if pass_entry.has_method("get_parameter_key"):
		entry_key = pass_entry.get_parameter_key()
	if entry_key != null and volume_pass_states.has(entry_key):
		return bool(volume_pass_states[entry_key])

	var source = pass_entry
	if pass_entry.has_method("get_parameter_source"):
		var resolved = pass_entry.get_parameter_source()
		if resolved != null:
			source = resolved
	if source != null and source.has_method("get_parameter_key"):
		var source_key: Variant = source.get_parameter_key()
		if source_key != null and volume_pass_states.has(source_key):
			return bool(volume_pass_states[source_key])

	var enabled := bool(pass_entry.is_enabled())
	# `enabled` follows the same authored layering as every other pass parameter:
	# the entry's effective default, then the implementing source's pipeline
	# dictionary, then the containing entry's dictionary. Only a pass that actually
	# exposes a boolean enabled parameter participates; the CompositorEffect base
	# property alone is not an FRP parameter.
	if source != null and source.has_method("get_frp_parameters"):
		var authored: Dictionary = source.get_frp_parameters()
		if authored.has("enabled") and authored["enabled"] is bool:
			var source_parameters = source.get("pass_parameters")
			if source_parameters is Dictionary and source_parameters.get("enabled") is bool:
				enabled = bool(source_parameters["enabled"])
			var entry_parameters = pass_entry.get("pass_parameters")
			if entry_parameters is Dictionary and entry_parameters.get("enabled") is bool:
				enabled = bool(entry_parameters["enabled"])

	if pass_entry is BuiltinPass:
		var native := pass_entry as BuiltinPass
		if volume_pass_states.has(native.native_id):
			return bool(volume_pass_states[native.native_id])
		return enabled

	for native_id in declared_provides(pass_entry):
		if volume_pass_states.has(int(native_id)):
			return bool(volume_pass_states[int(native_id)])
	return enabled

## Native ids provided by enabled pass implementations. The enabled predicate is
## supplied by the renderer so this query stays independent of renderer storage.
static func provided_native_ids(passes: Array, is_entry_enabled_fn: Callable) -> Dictionary:
	var provided := {}
	for pass_entry in passes:
		if pass_entry == null or not is_entry_enabled_fn.call(pass_entry):
			continue
		if pass_entry is BuiltinPass:
			var native := pass_entry as BuiltinPass
			if native.implementation == null:
				continue
			if NativeSpec.is_valid_id(native.native_id):
				provided[native.native_id] = true
			for native_id in declared_provides(native.implementation):
				provided[int(native_id)] = true
		for native_id in declared_provides(pass_entry):
			provided[int(native_id)] = true
	return provided

## Native ids custom passes explicitly declare. Builtin entries are excluded: their
## own id is handled by provided_native_ids when an implementation exists.
static func declared_provided_ids(passes: Array, is_entry_enabled_fn: Callable) -> Dictionary:
	var declared := {}
	for pass_entry in passes:
		if pass_entry == null or pass_entry is BuiltinPass or not is_entry_enabled_fn.call(pass_entry):
			continue
		for native_id in declared_provides(pass_entry):
			declared[int(native_id)] = true
	return declared

## Build effects and the native token/name arrays in one traversal. Keeping these
## products together is what preserves compositor effect indices for disabled
## scripted passes.
static func build(passes: Array, manager, is_scripted_fn: Callable, is_entry_enabled_fn: Callable) -> Dictionary:
	var tokens: Array[int] = [MANAGER_TOKEN]
	var names := PackedStringArray(["Texture Preparation"])
	var effects: Array[CompositorEffect] = []
	var scripted_effects: Array[CompositorEffect] = []
	if manager != null:
		effects.append(manager)
	var effect_index := 1
	for i in passes.size():
		var pass_entry = passes[i]
		if pass_entry == null:
			continue
		if is_scripted_fn.call(pass_entry):
			scripted_effects.append(pass_entry)
			effects.append(pass_entry)
			tokens.append(-(effect_index + 1))
			effect_index += 1
			names.append(schedule_name(pass_entry, i))
			continue
		var native := pass_entry as BuiltinPass
		if is_entry_enabled_fn.call(native):
			tokens.append(native.native_id)
			names.append(schedule_name(pass_entry, i))
	return {
		"effects": effects,
		"scripted_effects": scripted_effects,
		"tokens": PackedInt32Array(tokens),
		"names": names,
	}

static func schedule_name(pass_entry, index: int) -> String:
	var display_name: String = pass_entry.resource_name
	if display_name.is_empty():
		display_name = str(pass_entry.stable_id) if not pass_entry.stable_id.is_empty() else "Custom Pass"
	return "%02d %s" % [index, display_name]

## Keep validation pure and preserve the validator's warning ordering and de-duplication.
static func validation_warnings(
	passes: Array,
	provided: Dictionary,
	declared: Dictionary,
	is_entry_enabled_fn: Callable,
	contract_source_fn: Callable,
	is_scripted_fn: Callable
) -> PackedStringArray:
	var warnings := PipelineValidator.validate_schedule(
		passes,
		provided,
		declared,
		is_entry_enabled_fn,
		contract_source_fn,
		is_scripted_fn
	)
	warnings.append_array(ParameterResolver.warnings(passes))
	return warnings
