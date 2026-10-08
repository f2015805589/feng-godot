@tool
class_name FengCompositorBinding
extends RefCounted
## The addon boundary that wires a pure execution plan to a Compositor.
##
## This adapter owns the RenderingServer calls and compositor effect list. It does
## not own authored state, the renderer's manager, or the last-valid schedule.

const BuiltinPass = preload("../passes/builtin_pass.gd")

## Remove the native pipeline and effects from a compositor without reaching into a
## renderer. This is also used when a compositor loses its renderer.
static func clear(compositor: Compositor) -> void:
	if compositor == null:
		return
	RenderingServer.compositor_set_frp_pipeline(compositor.get_rid(), PackedInt32Array())
	compositor.compositor_effects = []

## Apply a valid plan or preserve the engine's last valid native schedule when the
## candidate has warnings. Callers retain ownership of last_valid_schedule.
static func apply(
	compositor: Compositor,
	manager: FengTextureManager,
	passes: Array,
	plan: Dictionary,
	warnings: PackedStringArray,
	is_entry_enabled_fn: Callable,
	provided_native_ids: PackedInt32Array,
	parameters: Dictionary
) -> Dictionary:
	if compositor == null:
		return {"applied": false, "tokens": PackedInt32Array()}

	if not warnings.is_empty():
		# Do not upload a bad candidate. The engine keeps its previous valid token list;
		# only the project's custom effects are suspended until contracts are valid again.
		if compositor.compositor_effects.has(manager):
			for effect in compositor.compositor_effects:
				if effect == manager or effect is BuiltinPass:
					continue
				RenderingServer.compositor_effect_set_enabled(effect.get_rid(), false)
			manager.passes.clear()
		for warning in warnings:
			push_warning("FengRenderer: " + warning)
		return {"applied": false, "tokens": PackedInt32Array()}

	# Contract flags must reach the native renderer before effects and schedule upload.
	for pass_entry in passes:
		if pass_entry == null:
			continue
		var contract: FengPass = pass_entry.get_contract_source()
		contract.refresh_resource_flags()
		if contract != pass_entry:
			pass_entry.access_resolved_color = contract.access_resolved_color
			pass_entry.access_resolved_depth = contract.access_resolved_depth
			pass_entry.needs_motion_vectors = contract.needs_motion_vectors
			pass_entry.needs_normal_roughness = contract.needs_normal_roughness
			pass_entry.needs_separate_specular = contract.needs_separate_specular
		RenderingServer.compositor_effect_set_enabled(pass_entry.get_rid(), is_entry_enabled_fn.call(pass_entry))

	manager.passes = plan.scripted_effects
	compositor.compositor_effects = plan.effects

	var tokens: PackedInt32Array = plan.tokens
	var names: PackedStringArray = plan.names
	upload(compositor, tokens, names, provided_native_ids, parameters)
	return {"applied": true, "tokens": tokens}

## Keep the only direct compositor_set_frp_pipeline call in this adapter.
static func upload(
	compositor: Compositor,
	tokens: PackedInt32Array,
	names: PackedStringArray,
	provided_native_ids: PackedInt32Array,
	parameters: Dictionary
) -> void:
	RenderingServer.compositor_set_frp_pipeline(
		compositor.get_rid(),
		tokens,
		names,
		provided_native_ids,
		parameters
	)
