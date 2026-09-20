@tool
extends RefCounted
## Camera-owned binding and parameters over a shared renderer definition.
## Custom/stateful passes are isolated individually; the Renderer is never cloned.

const ViewPass = preload("view_pass.gd")
const TextureManager = preload("../passes/texture_manager.gd")
const Binding = preload("compositor_binding.gd")
const Parameters = preload("parameter_resolver.gd")

var _manager := TextureManager.new()
var _bindings: Dictionary = {}
var _executors: Dictionary = {}
var _effects: Array[CompositorEffect] = []
var _plan: Dictionary = {}
var _parameters: Dictionary = {}
var _resolved: Dictionary = {}
var _states: Dictionary = {}
var _revision := -1
var _renderer_id := 0
var _valid := false

func apply(compositor: Compositor, renderer: FengRenderer, parameters: Dictionary, states: Dictionary) -> void:
	var changed_definition := _renderer_id != renderer.get_instance_id() or _revision != renderer.get_parameter_revision()
	if changed_definition:
		_bindings = {}
		_executors = {}
		_plan = {}
		_valid = false
		_renderer_id = renderer.get_instance_id()
		_revision = renderer.get_parameter_revision()
	if not _valid or states != _states:
		var candidate := renderer.compile_view_plan(states)
		if not candidate.warnings.is_empty():
			# Keep the previous native frame; suspend only custom work owned by us.
			var had_view_binding := false
			for effect in compositor.compositor_effects:
				if effect is ViewPass and not effect.source is FengBuiltinPass:
					effect.enabled = false
				if effect is ViewPass:
					had_view_binding = true
			if had_view_binding:
				for effect in compositor.compositor_effects:
					if effect is TextureManager:
						effect.passes.clear()
			for warning in candidate.warnings:
				push_warning("FengRenderer: " + warning)
			_valid = false
			return
		_plan = candidate
		_states = states.duplicate(true)
		_effects = [_manager]
		var scripted: Array[CompositorEffect] = []
		for index in candidate.sources.size():
			var source: FengPass = candidate.sources[index]
			var active: bool = candidate.enabled[index]
			if not _bindings.has(source):
				_bindings[source] = ViewPass.new()
			if active and not _executors.has(source):
				_executors[source] = source if renderer.is_view_shareable(source) else source.duplicate(true)
			var effect = _bindings[source]
			effect.configure(source, _executors.get(source), active)
			_effects.append(effect)
			scripted.append(effect)
		_manager.passes = scripted
		_parameters = parameters.duplicate(true)
		_resolved = Parameters.resolve_context([], parameters, candidate.context)
		_valid = true
		_revision = renderer.get_parameter_revision()
	elif parameters != _parameters:
		_parameters = parameters.duplicate(true)
		_resolved = Parameters.resolve_context([], parameters, _plan.context)
	if compositor.compositor_effects != _effects:
		compositor.compositor_effects = _effects
	Binding.upload(compositor, _plan.tokens, _plan.names, _plan.provided, _resolved)
