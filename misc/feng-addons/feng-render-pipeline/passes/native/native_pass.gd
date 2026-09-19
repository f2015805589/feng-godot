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
## A concrete subclass sets native_id and its display name in _init(). The renderer
## attaches it to the matching schedule entry (FengBuiltinPass.implementation); the
## entry is then driven by this script and reports the pass as provided to the engine
## (see FengPass.provides_native_ids), while an entry without one still emits the
## engine's own token.

const NativeSpec = preload("../native_spec.gd")
const PassBase = preload("../pass_base.gd")

@export_storage var native_id: int = -1
## An extra pass that runs right after this pass's engine work, in the same pipeline
## slot. It is how a pass carries its own shader: put a FengShaderPass here (its
## shader_file and parameters are then shown on this pass in the pipeline resource,
## the URP way) and its work runs as part of this entry instead of as a separate
## entry that has to be kept in the right place.
@export var overlay: PassBase

func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	ctx.run_pass(native_id)
	if overlay != null:
		overlay._frp_execute(ctx)

## The overlay is what reads and writes textures, so it owns the resource contract of
## this pass (inputs, outputs, attachment flags) when one is set.
func get_contract_source() -> PassBase:
	return overlay if overlay != null else self

func get_configuration_warnings() -> PackedStringArray:
	var warnings := super.get_configuration_warnings()
	if not NativeSpec.is_valid_id(native_id):
		warnings.append("Native FRP pass id %d is not part of this engine's FRP pass set." % native_id)
	return warnings
