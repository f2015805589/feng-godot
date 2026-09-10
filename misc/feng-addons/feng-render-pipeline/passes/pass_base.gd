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

@export var inputs: Array[TextureInput] = []
@export var outputs: Array[OutputDeclaration] = []
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

func _render_callback(callback_stage: int, data: RenderData) -> void:
	if callback_stage != effect_callback_type or data == null:
		return
	_refresh_resource_flags()
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

func _refresh_resource_flags() -> void:
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
