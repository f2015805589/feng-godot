@tool
class_name FengNativePass
extends "../pass_base.gd"
## Addon-side implementation of one of the engine's FRP passes.
##
## The engine keeps the primitives: the pass/operation table (FRPPipelineSpec), the
## Core surface a pass runs on (FRPPassContext) and the internal operations behind
## it. The pipeline itself lives here, as pass scripts that extend the same base
## class as a custom pass.
##
## The default implementation runs the pass's own operations through
## ctx.run_pass(native_id), which is exactly what the engine's built-in pass did, so
## a schedule of these scripts renders the same frame as the engine's default order.
## Override _frp_execute() to take the pass over: call the granular primitives in the
## order the effect needs, or skip work a project does not want.
##
## A concrete subclass answers _native_pass_id() with the engine pass it implements, and
## its display name is read back from the engine's spec, so the two cannot drift apart.
## The renderer attaches it to the matching schedule entry
## (FengBuiltinPass.implementation); the entry is then driven by this script and reports
## the pass as provided to the engine (see FengPass.provides_native_ids), while an entry
## without one still emits the engine's own token.

const NativeSpec = preload("../../pipeline/native_spec.gd")
const PassBase = preload("../pass_base.gd")

@export_storage var native_id: int = -1
## An extra pass that runs right after this pass's engine work, in the same pipeline
## slot. It is how a pass carries its own shader: put a FengShaderPass here (its
## shader_file and parameters are then shown on this pass in the pipeline resource,
## the URP way) and its work runs as part of this entry instead of as a separate
## entry that has to be kept in the right place.
##
## Setting or clearing it changes the pass's resource contract, so it notifies (an
## `@export` member does not do that on its own).
@export var overlay: PassBase:
	set(value):
		overlay = value
		emit_changed()

func _init() -> void:
	native_id = _native_pass_id()
	if native_id >= 0:
		# The engine's spec owns the display name, so it cannot drift from the pass this
		# script runs.
		resource_name = NativeSpec.pass_name(native_id)

## The engine pass this script implements. A concrete subclass returns its id; the
## default means "not one of the engine's passes", which is what a bare FengNativePass
## attached to an entry an author filled in by hand needs.
func _native_pass_id() -> int:
	return -1

func get_parameter_key() -> Variant:
	return native_id

func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	ctx.run_pass(native_id)
	run_overlay(ctx)

## The overlay this pass carries and runs, or null when it carries none or it is
## switched off. An overlay is the *extra* work of a pass - its own shader, parameters
## and textures - so switching it off stops that work and its declarations without
## stopping the pass. Which is why is_enabled() is not derived from it: an overlay is
## not a pass in the schedule, the pass script itself is (see FengBuiltinPass).
func active_overlay() -> PassBase:
	return overlay if overlay != null and overlay.enabled else null

## Runs this pass's overlay when it has one that is switched on. A pass script that
## overrides _frp_execute() and calls its overlay itself uses this, so "is the overlay
## on" is answered in one place.
func run_overlay(ctx: FRPPassContext) -> void:
	var active := active_overlay()
	if active != null:
		active._frp_execute(ctx)

## The overlay is what reads and writes textures, so it owns the resource contract of
## this pass (inputs, outputs, attachment flags) while it runs; a switched-off overlay
## declares nothing.
func get_contract_source() -> PassBase:
	return active_overlay() if active_overlay() != null else self

func carried_passes() -> Array[PassBase]:
	return [overlay] if overlay != null else []

func get_configuration_warnings() -> PackedStringArray:
	var warnings := super.get_configuration_warnings()
	if not NativeSpec.is_valid_id(native_id):
		warnings.append("Native FRP pass id %d is not part of this engine's FRP pass set." % native_id)
	return warnings
