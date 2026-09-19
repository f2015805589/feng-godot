@tool
class_name FengPass
extends CompositorEffect
## Base class for reusable FRP passes.
##
## A FengPass remains a native CompositorEffect, so it can be mixed with
## hand-written CompositorEffect resources. Subclasses normally implement
## _render() and use the declared inputs and outputs as their resource contract.

const TextureInput = preload("pass_texture.gd")
const OutputDeclaration = preload("pass_output.gd")

@export_enum("Pre Opaque", "Post Opaque", "Post Sky", "Pre Transparent", "Post Transparent", "Pre GBuffer", "Post GBuffer", "Pre Lighting", "Post Lighting") var stage: int = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
	set(value):
		var next_stage := clampi(value, 0, EFFECT_CALLBACK_TYPE_MAX - 1)
		if stage == next_stage and effect_callback_type == next_stage:
			return
		stage = next_stage
		effect_callback_type = stage
		emit_changed()

## The declarations the renderer and the engine read at apply time are authored
## properties, and an `@export` member of a GDScript does not emit Resource.changed on
## its own: the inspector and UndoRedo set it through Object.set(), which for a script
## member is a plain assignment. So the state the schedule collects - the texture
## contract, the provided ids, the parameters - notifies from its own setter, which is
## what makes an edit in the inspector reach the engine instead of waiting for the next
## unrelated change.
@export var inputs: Array[TextureInput] = []:
	set(value):
		inputs = value
		emit_changed()
@export var outputs: Array[OutputDeclaration] = []:
	set(value):
		outputs = value
		emit_changed()
## Native FRP passes this pass takes over, by id. Declaring an id tells the
## renderer that a schedule without the matching built-in entry is complete: the
## pass runs that entry's work itself through the FRPPassContext primitives, so
## the entry is neither re-added during normalization nor reported as missing.
## Declare only what the pass actually does - a declaration without the work
## produces an incomplete frame rather than a validation error.
@export var provides_native_ids: Array[int] = []:
	set(value):
		provides_native_ids = value
		emit_changed()
## Stable identity used by the renderer's persisted library and migration
## bookkeeping.  It is storage-only because it is an implementation detail,
## while Resource.resource_name is the readable name shown in the inspector.
@export_storage var stable_id: StringName = &""

var _setup_complete := false
var _cleanup_scheduled := false
var _last_error := ""

func _init() -> void:
	effect_callback_type = stage

func _setup(_rd: RenderingDevice) -> void:
	pass

func _render(_buffers: RenderSceneBuffersRD, _view: int, _rd: RenderingDevice) -> void:
	pass

func _cleanup(_rd: RenderingDevice) -> void:
	pass

func _report(message: String) -> void:
	if message != _last_error:
		push_error("%s: %s" % [get_class(), message])
		_last_error = message

func _clear_report() -> void:
	_last_error = ""

## Parameters this pass exposes, in the sense URP gives a render pass its settings.
##
## Custom typed `@export` properties are collected automatically. Override this
## for computed values or a narrower global schema. Volume permission is a separate
## author-owned declaration: get_volume_parameter_names(). The values are read by the engine for the few it consumes
## itself (the Temporal AA entry's `jitter_phases` sizes the viewport jitter) and by
## other passes through `FRPPassContext.get_pass_parameters(pass_id)`.
##
## The entry's own `pass_parameters` dictionary overrides these values, which is how a
## pipeline overrides a pass without editing the pass resource.
##
## The pipeline collects what this returns when it hands its schedule to the engine, so
## an exposed property has to notify when it changes: declare its setter with
## `emit_changed()`, as the pass scripts this addon ships do. An `@export` member does
## not emit on its own, so without the setter an edit in the inspector would only reach
## the engine on the next unrelated change.
func get_frp_parameters() -> Dictionary:
	var parameters := {}
	# Script exports are settings; the base protocol's exports are infrastructure.
	for property in get_property_list():
		var usage := int(property.get("usage", 0))
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0 or (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var key := String(property.name)
		if key in ["stage", "inputs", "outputs", "provides_native_ids", "pass_parameters", "overlay", "implementation"]:
			continue
		parameters[key] = get(key)
	return parameters

## Stable parameter address, independent of list order and native capabilities.
## Override this in a custom pass when several instances of one script need separate
## settings. Library passes already carry a persisted stable_id.
func get_parameter_key() -> Variant:
	if stable_id != &"":
		return String(stable_id)
	var script: Script = get_script()
	return script.resource_path if script != null else ""

func get_parameter_source() -> FengPass:
	return self

## Only the PASS AUTHOR decides which of its settings a Volume may control.
## Empty means no Volume module. This is code, never an Inspector permission list.
func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray()

## Reuses export types/ranges for the Volume UI; dictionary-only settings work too.
func get_volume_parameter_list() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var defaults := get_frp_parameters()
	var properties := {}
	for property in get_property_list():
		properties[String(property.name)] = property
	for key in get_volume_parameter_names():
		if not defaults.has(key):
			continue
		var info: Dictionary = properties.get(key, {"name": key, "type": typeof(defaults[key])}).duplicate()
		info.usage = PROPERTY_USAGE_DEFAULT
		result.append(info)
	return result

## Runtime settings belong to the frame, never written back into authored exports.
func get_resolved_parameters(ctx: FRPPassContext) -> Dictionary:
	var result := get_frp_parameters().duplicate()
	result.merge(pass_parameters, true)
	if ctx != null:
		result.merge(ctx.get_pass_parameters(get_parameter_key()), true)
	return result

## Values for the parameters above, authored in the pipeline resource. They override
## what the pass exposes, so a project can change one value without editing the pass
## resource, and a volume (see FengVolume) overrides them at runtime. The keys are
## pass parameter names for the passes this pass provides; a native entry uses the
## dictionary for its own pass.
@export var pass_parameters: Dictionary = {}:
	set(value):
		pass_parameters = value
		emit_changed()

## The object that owns this pass's resource contract: the inputs it reads, the
## outputs it produces and the resolved-attachment flags the engine needs before it
## runs. A plain pass owns its own; a native pass forwards to its overlay, because
## the overlay is the part that reads or writes textures.
func get_contract_source() -> FengPass:
	return self

## Whether the work of this pass runs this frame. Its own `enabled` is the authored
## switch; a pass that carries another pass (see carried_passes) is only running when
## that one runs too, so unchecking a carried pass turns its work off instead of
## leaving a flag nothing reads. A volume's pass state overrides the entry this pass
## belongs to (see FengVolume).
func is_enabled() -> bool:
	return enabled

## The passes this pass runs as part of itself, if any: the script that implements an
## entry's native work, or a pass's overlay. They are resources of their own, so the
## renderer observes them directly (an edit to a nested resource does not travel to the
## one holding it) and an entry's effective enabled state is the conjunction of the
## chain.
func carried_passes() -> Array[FengPass]:
	return []

func _render_callback(callback_stage: int, data: RenderData) -> void:
	if callback_stage != effect_callback_type or data == null:
		return
	refresh_resource_flags()
	var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	if not _setup_complete:
		_setup(rd)
		_setup_complete = true
	for view in buffers.get_view_count():
		if not _validate_runtime_inputs(buffers, view):
			continue
		_render(buffers, view, rd)
	_clear_report()

## FRP Core entry point. When the pass is part of an FRP pipeline the renderer calls
## this instead of `_render_callback`, so a pass can drive the frame through the
## engine's Core primitives (draw the G-buffer, run deferred lighting, resolve, tone
## map, ...) instead of reimplementing them. The default forwards to the usual
## CompositorEffect path, which is what every shader/texture pass wants; override it
## when the pass needs the Core primitives.
func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	var data := ctx.get_render_data()
	if data == null:
		return
	_render_callback(effect_callback_type, data)

func _validate_runtime_inputs(buffers: RenderSceneBuffersRD, view: int) -> bool:
	var bindings := {}
	for declaration in inputs:
		if declaration == null:
			_report("Texture declarations cannot be null.")
			return false
		if declaration.binding < 0 or declaration.binding > 31 or bindings.has(declaration.binding):
			_report("Texture declarations must use unique bindings between 0 and 31.")
			return false
		bindings[declaration.binding] = true
		if not declaration.get_texture(buffers, view).is_valid():
			_report("Texture is unavailable for binding %d." % declaration.binding)
			return false
	return true

## Turns the declared inputs into the attachment requirements the engine reads off the
## effect before it runs. The pipeline calls this on whichever object owns the contract
## (see get_contract_source), so it is part of the pass protocol rather than private.
func refresh_resource_flags() -> void:
	var color_required := false
	var depth_required := false
	var normal_required := false
	for declaration in inputs:
		if declaration == null:
			continue
		if declaration.source == TextureInput.Source.COLOR:
			color_required = true
		elif declaration.source == TextureInput.Source.DEPTH:
			depth_required = true
		elif declaration.source == TextureInput.Source.NORMAL_ROUGHNESS:
			normal_required = true
	if color_required:
		access_resolved_color = true
	if depth_required:
		access_resolved_depth = true
	if normal_required:
		needs_normal_roughness = true

func get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if stage < 0 or stage >= EFFECT_CALLBACK_TYPE_MAX:
		warnings.append("Pass stage is outside the CompositorEffect callback range.")
	if effect_callback_type != stage:
		warnings.append("Pass stage is out of sync with effect_callback_type.")
	var bindings := {}
	for declaration in inputs:
		if declaration == null:
			warnings.append("Input declarations cannot be empty.")
			continue
		for warning in declaration.get_configuration_warnings():
			warnings.append(warning)
		if bindings.has(declaration.binding):
			warnings.append("Texture binding %d is declared more than once." % declaration.binding)
		bindings[declaration.binding] = true
	var names := {}
	for declaration in outputs:
		if declaration == null:
			warnings.append("Output declarations cannot be empty.")
			continue
		for warning in declaration.get_configuration_warnings():
			warnings.append(warning)
		if names.has(declaration.name):
			warnings.append("Output texture '%s' is declared more than once." % declaration.name)
		names[declaration.name] = true
	# Stage is an advisory callback selector once a FengRenderer is used.  The
	# renderer validates texture availability from the actual list position;
	# doing numeric stage comparisons here used to report false positives for
	# passes deliberately moved around native FRP operations.
	return warnings

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or not _setup_complete or _cleanup_scheduled:
		return
	_cleanup_scheduled = true
	var weak_self: Variant = weakref(self)
	RenderingServer.call_on_render_thread(func():
		var reference = weak_self.get_ref()
		if reference != null:
			reference._cleanup(RenderingServer.get_rendering_device())
	)
