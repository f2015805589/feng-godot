extends SceneTree
## Fixed schedule contracts still honor custom FengPass implementations and bad authorship.
const PassBase = preload("res://addons/feng-render-pipeline/passes/pass_base.gd")
const BuiltinPass = preload("res://addons/feng-render-pipeline/passes/builtin_pass.gd")
const Plan = preload("res://addons/feng-render-pipeline/pipeline/execution_plan.gd")
const Validator = preload("res://addons/feng-render-pipeline/pipeline/pipeline_validator.gd")
const Binding = preload("res://addons/feng-render-pipeline/pipeline/compositor_binding.gd")
const TextureManager = preload("res://addons/feng-render-pipeline/passes/texture_manager.gd")
const NativeSpec = preload("res://addons/feng-render-pipeline/pipeline/native_spec.gd")

class SettingsPass extends PassBase:
	var defaults := {"enabled": true, "amount": 1.0}
	func get_parameter_key() -> Variant:
		return "custom-source"
	func get_frp_parameters() -> Dictionary:
		return defaults.duplicate()

class CarriedPass extends PassBase:
	var source: FengPass
	func get_parameter_key() -> Variant:
		return "custom-entry"
	func get_parameter_source() -> FengPass:
		return source
	func get_contract_source() -> FengPass:
		return source
	func is_enabled() -> bool:
		return enabled and source.is_enabled()
	func carried_passes() -> Array[FengPass]:
		return [source]

class KeyedBuiltinPass extends BuiltinPass:
	func get_parameter_key() -> Variant:
		return "custom-native-key"

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	_test_enabled_layers()
	_test_schedule_slots()
	_test_texture_dependencies()
	_test_binding_fallback()
	print("PASS FRP fixed schedule contracts, custom parameter layers, texture dependencies and binding fallback")
	quit()

func _test_enabled_layers() -> void:
	assert(not Plan.is_scripted(null) and not Plan.is_entry_enabled(null))
	assert(Plan.declared_provides(null).is_empty())
	var plain := PassBase.new()
	plain.pass_parameters = {"enabled": false}
	assert(Plan.is_entry_enabled(plain), "an undeclared enabled setting must not control a pass")
	var source := SettingsPass.new()
	var entry := CarriedPass.new()
	entry.source = source
	entry.provides_native_ids = [NativeSpec.PASS_SKY]
	assert(Plan.is_entry_enabled(entry))
	source.enabled = false
	assert(not Plan.is_entry_enabled(entry), "custom is_enabled overrides remain authoritative")
	source.pass_parameters = {"enabled": true}
	assert(Plan.is_entry_enabled(entry), "source settings override the authored switch")
	entry.pass_parameters = {"enabled": false}
	assert(not Plan.is_entry_enabled(entry), "entry settings are the last authored layer")
	entry.pass_parameters = {"enabled": "invalid"}
	assert(Plan.is_entry_enabled(entry), "non-boolean authored values do not override switches")
	source.pass_parameters = {"enabled": 1}
	assert(not Plan.is_entry_enabled(entry))
	source.enabled = true
	assert(Plan.is_entry_enabled(entry))
	source.defaults.enabled = 0
	entry.pass_parameters = {"enabled": false}
	assert(Plan.is_entry_enabled(entry), "only a boolean enabled declaration accepts the authored override")
	source.defaults.enabled = true
	var states := {"custom-entry": true, "custom-source": false, NativeSpec.PASS_SKY: false}
	var original_states := states.duplicate(true)
	assert(Plan.is_entry_enabled(entry, states), "entry key wins over source and native aliases")
	assert(states == original_states and entry.pass_parameters.enabled == false)
	states.erase("custom-entry")
	states["custom-source"] = true
	assert(Plan.is_entry_enabled(entry, states), "custom source key wins over native aliases")
	states.erase("custom-source")
	assert(not Plan.is_entry_enabled(entry, states))
	states[NativeSpec.PASS_SKY] = true
	assert(Plan.is_entry_enabled(entry, states), "provided native ids remain legacy state aliases")
	assert(Plan.declared_provides(entry) == [NativeSpec.PASS_SKY])
	var native := KeyedBuiltinPass.new(NativeSpec.PASS_SKY)
	native.implementation = source
	assert(not Plan.is_entry_enabled(native, {NativeSpec.PASS_SKY: false}))
	assert(Plan.is_entry_enabled(native, {"custom-source": true, NativeSpec.PASS_SKY: false}))
	assert(not Plan.is_entry_enabled(native, {"custom-native-key": false, "custom-source": true}))

func _test_schedule_slots() -> void:
	var manager := TextureManager.new()
	var first := PassBase.new()
	first.resource_name = "Disabled custom"
	first.enabled = false
	var token := BuiltinPass.new(NativeSpec.PASS_SKY, "Native token")
	var carried := BuiltinPass.new(NativeSpec.PASS_LIGHTING, "Disabled implementation")
	carried.implementation = PassBase.new()
	carried.enabled = false
	var last := PassBase.new()
	last.stable_id = &"last-custom"
	var entries := [first, null, token, carried, last]
	var schedule := Plan.build(entries, manager, Plan.is_scripted, Plan.is_entry_enabled)
	assert(schedule.effects == [manager, first, carried, last])
	assert(schedule.scripted_effects == [first, carried, last])
	assert(schedule.tokens == PackedInt32Array([-1, -2, NativeSpec.PASS_SKY, -3, -4]),
			"disabled script effects must retain their token slots")
	assert(schedule.names == PackedStringArray(["Texture Preparation", "00 Disabled custom", "02 Native token", "03 Disabled implementation", "04 last-custom"]))
	var view_schedule := Plan.build(entries, null, Plan.is_scripted, Plan.is_entry_enabled)
	assert(view_schedule.tokens == schedule.tokens and view_schedule.effects == schedule.scripted_effects)
	token.enabled = false
	assert(Plan.build(entries, manager, Plan.is_scripted, Plan.is_entry_enabled).tokens == PackedInt32Array([-1, -2, -3, -4]))
	carried.enabled = true
	carried.implementation.provides_native_ids = [NativeSpec.PASS_GBUFFER]
	last.provides_native_ids = [NativeSpec.PASS_TRANSPARENT]
	var provided := Plan.provided_native_ids(entries, Plan.is_entry_enabled)
	assert(provided == {NativeSpec.PASS_LIGHTING: true, NativeSpec.PASS_GBUFFER: true, NativeSpec.PASS_TRANSPARENT: true})
	assert(Plan.declared_provided_ids(entries, Plan.is_entry_enabled) == {NativeSpec.PASS_TRANSPARENT: true})

func _test_texture_dependencies() -> void:
	var producer := PassBase.new()
	producer.resource_name = "Producer"
	var output := FengPassOutput.new()
	output.name = &"result"
	producer.outputs = [output]
	var consumer := PassBase.new()
	consumer.resource_name = "Consumer"
	var input := FengPassTexture.new()
	input.source = FengPassTexture.Source.PIPELINE
	input.custom_name = &"result"
	consumer.inputs = [input]
	assert(_texture_warnings([producer, consumer]).is_empty())
	assert(_texture_warnings([consumer, producer]) == PackedStringArray([
		"Pass 'Consumer' reads pipeline texture 'result' before its producer; reorder the authored list."
	]))
	producer.enabled = false
	assert(_texture_warnings([producer, consumer]) == PackedStringArray([
		"Pass 'Consumer' references pipeline texture 'result', but no pass produces it."
	]))
	producer.enabled = true
	consumer.outputs = [output]
	assert(_texture_warnings([producer, consumer]) == PackedStringArray([
		"Output texture 'result' is produced by more than one pass."
	]))
	assert(_texture_warnings([consumer]) == PackedStringArray([
		"Pass 'Consumer' reads pipeline texture 'result' before its producer; reorder the authored list."
	]))
	input.binding_type = FengPassTexture.BindingType.STORAGE_IMAGE
	assert(_texture_warnings([consumer]).is_empty(), "same-pass storage images are allowed")
	# These guards protect missing producers and reading HDR color after tonemapping.
	input.source = FengPassTexture.Source.COLOR
	assert(Validator._validate_custom_contracts([consumer], {}, {}, {}, Plan.is_entry_enabled).size() == 1)
	var native_positions := {NativeSpec.PASS_LIGHTING: -2, NativeSpec.PASS_POST_PROCESS: -1}
	var native_states := {NativeSpec.PASS_LIGHTING: true, NativeSpec.PASS_POST_PROCESS: true}
	assert(Validator._validate_custom_contracts([consumer], native_positions, native_states, {}, Plan.is_entry_enabled) == PackedStringArray([
		"Pass 'Consumer' reads Color after Post Process / Tonemap; writes to the internal HDR color are no longer presented."
	]))

func _texture_warnings(entries: Array) -> PackedStringArray:
	return Validator._validate_custom_contracts(entries, {}, {}, {}, Plan.is_entry_enabled)

func _test_binding_fallback() -> void:
	var manager := TextureManager.new()
	var compositor := Compositor.new()
	var custom := PassBase.new()
	var native := BuiltinPass.new(NativeSpec.PASS_SKY)
	native.implementation = PassBase.new()
	var entries := [custom, native]
	var schedule := Plan.build(entries, manager, Plan.is_scripted, Plan.is_entry_enabled)
	var contract_source := func(entry: FengPass): return entry.get_contract_source()
	var provided := func(): return PackedInt32Array([NativeSpec.PASS_SKY])
	var parameters := func(): return {"custom": {"amount": 3.0}}
	# Include every required native operation while exercising two effect slots.
	for native_id in NativeSpec.seed_order():
		if native_id != NativeSpec.PASS_SKY:
			schedule.tokens.append(native_id)
			schedule.names.append(NativeSpec.pass_name(native_id))
	var result := Binding.apply(compositor, manager, entries, schedule, PackedStringArray(),
			contract_source, Plan.is_entry_enabled, provided, parameters)
	assert(result.applied and result.tokens == schedule.tokens)
	assert(manager.passes == schedule.scripted_effects and compositor.compositor_effects == schedule.effects)
	var original_effects := compositor.compositor_effects.duplicate()
	# Invalid candidates intentionally have no plan fields, so they must return
	# before fixed plan reads and leave the previously attached effect list intact.
	result = Binding.apply(compositor, manager, entries, {}, PackedStringArray(["expected invalid candidate"]),
			contract_source, Plan.is_entry_enabled, provided, parameters)
	assert(not result.applied and result.tokens.is_empty())
	assert(compositor.compositor_effects == original_effects and manager.passes.is_empty())
	assert(custom.is_enabled() and native.is_enabled(), "execution fallback must not edit authored enabled flags")
	# An unrelated compositor must not have its effects or manager changed.
	var unrelated := Compositor.new()
	var unrelated_effect := PassBase.new()
	unrelated.compositor_effects = [unrelated_effect]
	Binding.apply(unrelated, manager, entries, {}, PackedStringArray(["expected unrelated candidate"]),
			contract_source, Plan.is_entry_enabled, provided, parameters)
	assert(unrelated_effect.is_enabled() and unrelated.compositor_effects == [unrelated_effect])
	Binding.clear(compositor)
	Binding.clear(unrelated)
	assert(compositor.compositor_effects.is_empty() and unrelated.compositor_effects.is_empty())
