@tool
class_name FengRenderer
extends Resource
## Declarative FRP pipeline: a list of passes that is applied to a Compositor.
##
## apply() groups enabled passes by stage (preserving list order inside each
## stage), prepends the hidden FengTextureManager, and writes the result into
## Compositor.compositor_effects. Pass.enabled is applied natively by the
## engine (CompositorEffect::set_enabled updates the RID immediately), so
## toggling a pass does not require re-applying the renderer.

const PassBase = preload("passes/pass_base.gd")
const TextureManager = preload("passes/texture_manager.gd")

@export var passes: Array[PassBase] = []

var _manager: CompositorEffect

func _init() -> void:
	_manager = TextureManager.new()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_manager = null

func apply(compositor: Compositor) -> void:
	if compositor == null:
		return
	var effects: Array[CompositorEffect] = []
	effects.append(_manager)
	var manager_passes: Array[CompositorEffect] = []
	for p in passes:
		if p == null or not p.enabled:
			continue
		manager_passes.append(p)
		effects.append(p)
	_manager.passes = manager_passes
	compositor.compositor_effects = effects

func get_enabled_passes() -> Array[PassBase]:
	var result: Array[PassBase] = []
	for p in passes:
		if p != null and p.enabled:
			result.append(p)
	return result

func get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var output_names := {}
	var binding_keys := {}
	for p in passes:
		if p == null:
			warnings.append("Pass list contains an empty entry.")
			continue
		for warning in p.get_configuration_warnings():
			warnings.append(warning)
		for output in p.outputs:
			if output == null or output.name == &"":
				continue
			if output_names.has(output.name):
				warnings.append("Output texture '%s' is produced by more than one pass." % output.name)
			output_names[output.name] = true
		for input in p.inputs:
			if input == null:
				continue
			if input.source == PassBase.TextureInput.Source.PIPELINE:
				if not output_names.has(input.custom_name):
					warnings.append("Pass input references pipeline texture '%s' that no pass produces." % input.custom_name)
			var key := "%s:%d" % [p.get_instance_id(), input.binding]
			if binding_keys.has(key):
				warnings.append("Pass declares texture binding %d more than once." % input.binding)
			binding_keys[key] = true
	return warnings
