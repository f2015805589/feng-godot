@tool
class_name FengPipelineValidator
extends RefCounted
## Validates an authored FRP schedule: the native entries, the passes a schedule lets a
## script provide, and the resource contracts custom passes declare.
##
## The pass list and the runtime state behind it (a volume can switch an entry on or off
## for the camera inside it) are owned by the renderer, so they are passed in: the
## dictionaries it built, and the renderer's own predicates for "runs this frame",
## "owns this resource contract" and "is dispatched by a pass script".

const NativeSpec = preload("native_spec.gd")
const PassTexture = preload("../passes/pass_texture.gd")
const BuiltinPass = preload("../passes/builtin_pass.gd")

## Validates the given passes array. Returns a list of unique human-readable warning
## strings.
static func validate_schedule(
	passes: Array,
	provided_native_ids: Dictionary,
	declared_provided_ids: Dictionary,
	is_entry_enabled_fn: Callable,
	contract_source_fn: Callable,
	is_scripted_fn: Callable
) -> PackedStringArray:
	var warnings := PackedStringArray()
	var native_positions := {}
	var native_states := {}
	var native_tokens := {}

	for i in passes.size():
		var pass_entry = passes[i]
		if pass_entry == null:
			warnings.append("Pass list contains an empty entry.")
			continue

		var enabled: bool = is_entry_enabled_fn.call(pass_entry)
		if enabled:
			for warning in pass_entry.get_configuration_warnings():
				warnings.append(warning)

			var contract = contract_source_fn.call(pass_entry)
			if contract != null and contract != pass_entry:
				for warning in contract.get_configuration_warnings():
					warnings.append("Pass '%s': %s" % [_pass_display_name(pass_entry), warning])

		if pass_entry is BuiltinPass:
			var native := pass_entry as BuiltinPass
			if native.native_id < 0 or native.native_id >= NativeSpec.pass_count():
				warnings.append("Native pass '%s' has invalid native id %d." % [native.resource_name, native.native_id])
				continue

			# An entry whose id and name disagree was authored against an older pass set:
			# ids are what a schedule is read by, so a stale resource otherwise looks
			# like a valid schedule of the current passes.
			if not native.resource_name.is_empty():
				for definition in NativeSpec.pass_definitions():
					if int(definition["id"]) != native.native_id and String(definition["name"]) == native.resource_name:
						warnings.append("Native entry id %d is named '%s', which is the engine's pass %d: this renderer was authored against an older pass set. Build the pass list on a current FENG renderer instead of editing this one." % [native.native_id, native.resource_name, int(definition["id"])])
						break

			if native_positions.has(native.native_id):
				warnings.append("Native pass id %d appears more than once; schedule was not changed." % native.native_id)
			else:
				native_positions[native.native_id] = i
				native_states[native.native_id] = enabled
				if enabled and not is_scripted_fn.call(native):
					native_tokens[native.native_id] = true

	# Mandatory passes must either be in the schedule or provided by a pass script.
	for mandatory_id in NativeSpec.mandatory_ids():
		if provided_native_ids.has(mandatory_id):
			continue
		if not native_positions.has(mandatory_id):
			warnings.append("Required native pass '%s' (id %d) is missing; re-add the entry or declare it in a custom pass's provides_native_ids." % [NativeSpec.pass_name(mandatory_id), mandatory_id])
		elif not native_states[mandatory_id]:
			warnings.append("Required native pass '%s' (id %d) is disabled; enable it or declare it in a custom pass's provides_native_ids." % [NativeSpec.pass_name(mandatory_id), mandatory_id])

	# Check custom pass provided IDs.
	for provided_id in declared_provided_ids:
		if not NativeSpec.is_valid_id(provided_id):
			warnings.append("A custom pass declares provides_native_ids %d, which is not a native pass id." % provided_id)
		elif native_tokens.has(provided_id):
			warnings.append("Native pass '%s' (id %d) is declared as provided by a custom pass but its own entry is still enabled; disable the entry or drop the declaration." % [NativeSpec.pass_name(provided_id), provided_id])

	# Order constraints between native passes.
	for edge in NativeSpec.order_edges():
		var before_id: int = edge[0]
		var after_id: int = edge[1]
		if not native_positions.has(before_id) or not native_positions.has(after_id):
			continue
		if not native_states[before_id] or not native_states[after_id]:
			continue
		if native_positions[before_id] > native_positions[after_id]:
			warnings.append("Native pass '%s' must precede '%s'; authored order was retained and the previous valid schedule remains active." % [NativeSpec.pass_name(before_id), NativeSpec.pass_name(after_id)])

	warnings.append_array(_validate_custom_contracts(passes, native_positions, native_states, declared_provided_ids, is_entry_enabled_fn))
	return _unique_warnings(warnings)

## Checks what a custom pass declared about itself against the schedule it was placed
## in: one producer per output texture, every pipeline input produced before it is read,
## the native operation behind a source still enabled and earlier, and no pass reading
## the HDR colour after the tone mapping took it away.
static func _validate_custom_contracts(
	passes: Array,
	native_positions: Dictionary,
	native_states: Dictionary,
	provided_natives: Dictionary,
	is_entry_enabled_fn: Callable
) -> PackedStringArray:
	var warnings := PackedStringArray()
	var output_producers := {}

	for i in passes.size():
		var pass_entry = passes[i]
		if pass_entry == null or pass_entry is BuiltinPass or not is_entry_enabled_fn.call(pass_entry):
			continue
		for output in pass_entry.outputs:
			if output == null or output.name == &"":
				continue
			if output_producers.has(output.name):
				warnings.append("Output texture '%s' is produced by more than one pass." % output.name)
			else:
				output_producers[output.name] = {"index": i, "enabled": is_entry_enabled_fn.call(pass_entry)}

	for i in passes.size():
		var pass_entry = passes[i]
		if pass_entry == null or pass_entry is BuiltinPass or not is_entry_enabled_fn.call(pass_entry):
			continue
		for input in pass_entry.inputs:
			if input == null:
				continue
			if input.source == PassTexture.Source.PIPELINE:
				if not output_producers.has(input.custom_name):
					warnings.append("Pass '%s' references pipeline texture '%s', but no pass produces it." % [_pass_display_name(pass_entry), input.custom_name])
				else:
					var producer: Dictionary = output_producers[input.custom_name]
					if not producer["enabled"]:
						warnings.append("Pass '%s' reads pipeline texture '%s' from a disabled producer." % [_pass_display_name(pass_entry), input.custom_name])
					elif producer["index"] >= i and not (producer["index"] == i and input.binding_type == PassTexture.BindingType.STORAGE_IMAGE):
						warnings.append("Pass '%s' reads pipeline texture '%s' before its producer; reorder the authored list." % [_pass_display_name(pass_entry), input.custom_name])

			var required_native := PassTexture.required_native_pass(input.source)
			if required_native >= 0:
				if provided_natives.has(required_native):
					pass
				elif not native_positions.has(required_native) or not native_states.get(required_native, false):
					warnings.append("Pass '%s' requires native '%s' for its texture input, but that operation is disabled or missing." % [_pass_display_name(pass_entry), NativeSpec.pass_name(required_native)])
				elif native_positions[required_native] >= i:
					warnings.append("Pass '%s' reads a texture before native '%s'; move it after that operation." % [_pass_display_name(pass_entry), NativeSpec.pass_name(required_native)])

			# A pass reading HDR Color after Post Process / Tonemap cannot be presented.
			var post_id: int = NativeSpec.PASS_POST_PROCESS
			if input.source == PassTexture.Source.COLOR and native_positions.has(post_id) and native_states.get(post_id, false) and native_positions[post_id] < i:
				warnings.append("Pass '%s' reads Color after Post Process / Tonemap; writes to the internal HDR color are no longer presented." % _pass_display_name(pass_entry))

	return warnings

static func _pass_display_name(pass_entry: Object) -> String:
	if pass_entry == null:
		return ""
	if pass_entry.get("resource_name") != null and pass_entry.resource_name != "":
		return pass_entry.resource_name
	return pass_entry.get_class()

static func _unique_warnings(warnings: PackedStringArray) -> PackedStringArray:
	var result := PackedStringArray()
	var seen := {}
	for warning in warnings:
		if warning == "" or seen.has(warning):
			continue
		seen[warning] = true
		result.append(warning)
	return result
