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

## RefCounted may stop dispatching derived script fields during PREDELETE. Keep
## only detached, owned RID values here so the base notification can still
## release them without retaining a pass, Resource, or callable.
static var _owned_rid_snapshots: Dictionary = {}
static var _owned_rid_snapshots_mutex := Mutex.new()

@export_enum("Pre Opaque", "Post Opaque", "Post Sky", "Pre Transparent", "Post Transparent", "Pre GBuffer", "Post GBuffer", "Pre Lighting", "Post Lighting") var stage: int = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
	set(value):
		var next_stage := clampi(value, 0, EFFECT_CALLBACK_TYPE_MAX - 1)
		if stage == next_stage and effect_callback_type == next_stage:
			return
		stage = next_stage
		effect_callback_type = stage
		emit_changed()

## Authored declarations emit changed so Inspector and UndoRedo edits rebuild the
## schedule. Nested declaration resources forward their changes through this pass.
@export var inputs: Array[TextureInput] = []:
	set(value):
		inputs = value
		_observe_contract_resources()
		emit_changed()
@export var outputs: Array[OutputDeclaration] = []:
	set(value):
		outputs = value
		_observe_contract_resources()
		emit_changed()
## Native FRP work implemented by this pass through FRPPassContext primitives.
## These ids satisfy the schedule's native requirements; the implementation must
## perform that work for the frame to be complete.
@export var provides_native_ids: Array[int] = []:
	set(value):
		provides_native_ids = value
		emit_changed()
## Persisted identity for library synchronization and migration. The Inspector
## displays Resource.resource_name; this identifier is storage-only.
@export_storage var stable_id: StringName = &""

var _setup_complete := false
var _last_error := ""
var _parameter_layout_ready := false
var _parameter_properties: Dictionary = {}
var _parameter_exports := PackedStringArray()
var _contract_resources: Array[Resource] = []

## Declaration changes are events, not per-frame dependency polling. Observe here
## so Renderer only needs the Pass.changed protocol, including for custom passes.
func _observe_contract_resources() -> void:
	for resource in _contract_resources:
		if resource.changed.is_connected(_on_contract_resource_changed):
			resource.changed.disconnect(_on_contract_resource_changed)
	_contract_resources.clear()
	for declarations in [inputs, outputs]:
		for resource in declarations:
			if resource != null and not _contract_resources.has(resource):
				_contract_resources.append(resource)
				resource.changed.connect(_on_contract_resource_changed)

func _on_contract_resource_changed() -> void:
	emit_changed()

func _init() -> void:
	effect_callback_type = stage
	property_list_changed.connect(_invalidate_parameter_layout)
	script_changed.connect(_invalidate_parameter_layout)

func _invalidate_parameter_layout() -> void:
	_parameter_layout_ready = false
	_parameter_properties = {}
	_parameter_exports = PackedStringArray()
	# Dynamic schema changes also invalidate renderer and Volume snapshots.
	emit_changed()

## Cache metadata, never values: direct field edits still read fresh values.
## Dynamic property schemas invalidate through Godot's property_list_changed.
func _ensure_parameter_layout() -> void:
	if _parameter_layout_ready:
		return
	_parameter_properties = {}
	_parameter_exports = PackedStringArray()
	for property in get_property_list():
		var key := String(property.name)
		_parameter_properties[key] = property
		var usage := int(property.get("usage", 0))
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0 or (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if key in ["stage", "inputs", "outputs", "provides_native_ids", "pass_parameters", "overlay", "implementation"]:
			continue
		_parameter_exports.append(key)
	_parameter_layout_ready = true

## Optional frame preparation and persisted-contract repair hooks.
func _frp_prepare(_ctx: FRPPassContext) -> void:
	pass

func ensure_frp_contract() -> bool:
	return false

func _setup(_rd: RenderingDevice) -> void:
	pass

func _render(_buffers: RenderSceneBuffersRD, _view: int, _rd: RenderingDevice) -> void:
	pass

## Transfer only owned RIDs and clear their fields before returning. Subclasses
## append to super's result; borrowed frame/producer resources never belong here.
## Both explicit cleanup and destruction use this one ownership inventory.
func _take_owned_rids() -> Array[RID]:
	_setup_complete = false
	return []

## Subclasses publish their current owned-only RID inventory while they are
## alive. This registry is not Object metadata, so it cannot be serialized or
## copied with a Resource. Borrowed frame and producer RIDs must be excluded.
func _replace_owned_rid_snapshot(p_rids: Array[RID]) -> void:
	var snapshot: Array[RID] = []
	var seen: Dictionary = {}
	for rid in p_rids:
		if rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			snapshot.append(rid)
	_replace_owned_rid_snapshot_for_id(get_instance_id(), snapshot)

static func _replace_owned_rid_snapshot_for_id(p_instance_id: int,
		p_snapshot: Array[RID]) -> void:
	_owned_rid_snapshots_mutex.lock()
	if p_snapshot.is_empty():
		_owned_rid_snapshots.erase(p_instance_id)
	else:
		_owned_rid_snapshots[p_instance_id] = p_snapshot
	_owned_rid_snapshots_mutex.unlock()

static func _take_owned_rid_snapshot(p_instance_id: int,
		p_primary: Array[RID]) -> Array[RID]:
	var snapshot: Array[RID] = []
	_owned_rid_snapshots_mutex.lock()
	var stored: Variant = _owned_rid_snapshots.get(p_instance_id, [])
	_owned_rid_snapshots.erase(p_instance_id)
	_owned_rid_snapshots_mutex.unlock()
	if stored is Array:
		for value in stored:
			if value is RID and value.is_valid():
				snapshot.append(value)
	var result: Array[RID] = []
	var seen: Dictionary = {}
	for rid in p_primary:
		if rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			result.append(rid)
	for rid in snapshot:
		if rid.is_valid() and not seen.has(rid):
			seen[rid] = true
			result.append(rid)
	return result

func _cleanup(rd: RenderingDevice) -> void:
	var instance_id := get_instance_id()
	var rids := _take_owned_rids()
	_free_rids(rd, _take_owned_rid_snapshot(instance_id, rids))

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
	_ensure_parameter_layout()
	for key in _parameter_exports:
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

## Optional diffuse-indirect provider classification. The plan resolver uses this
## authored identity to select one owner before any pass callback runs.
func get_indirect_gi_kind() -> StringName:
	return &""

## Native entries this custom pass must stay before. Pipeline validators use these
## semantic bounds to reject schedules that would composite after a later transform.
func get_required_before_native_ids() -> PackedInt32Array:
	return PackedInt32Array()

## Opt into sharing this pass's execution resource across camera views.
##
## Return true only when the pass and every pass it carries can run without retaining
## mutable state that belongs to one view. Per-view parameters, textures and render
## data must be read from the FRPPassContext passed to _frp_execute(ctx); do not keep
## them in the shared pass resource. The default is conservative isolation, so a
## subclass must explicitly override this method. A top-level BuiltinPass opt-in also
## accepts responsibility for its complete carried implementation/overlay graph.
func can_share_view_execution() -> bool:
	return false

## Reuses export types/ranges for the Volume UI; dictionary-only settings work too.
func get_volume_parameter_list() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var names := get_volume_parameter_names()
	if names.is_empty():
		return result
	var defaults := get_frp_parameters()
	_ensure_parameter_layout()
	for key in names:
		if not defaults.has(key):
			continue
		var info: Dictionary = _parameter_properties.get(key, {"name": key, "type": typeof(defaults[key])}).duplicate()
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
		elif declaration.source == TextureInput.Source.MOTION_VECTORS:
			needs_motion_vectors = true
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
	if what != NOTIFICATION_PREDELETE:
		return
	# Capture the native ObjectID before any script dispatch. Derived state may no
	# longer be available at RefCounted zero, so merge its last live snapshot using
	# only the base registry and native Object identity.
	var instance_id := int(super.call("get_instance_id"))
	var rids: Array[RID] = super.call("_take_owned_rids")
	_free_on_render_thread(_take_owned_rid_snapshot(instance_id, rids))

static func _free_rids(rd: RenderingDevice, rids: Array[RID]) -> void:
	if rd == null:
		return
	for rid in rids:
		if rid.is_valid():
			rd.free_rid(rid)

## Only detached values cross the thread boundary: the dying pass no longer
## exists when a deferred render-thread callback runs.
static func _free_on_render_thread(rids: Array[RID]) -> void:
	if rids.is_empty():
		return
	var owned := rids.duplicate()
	RenderingServer.call_on_render_thread(func():
		_free_rids(RenderingServer.get_rendering_device(), owned)
	)
