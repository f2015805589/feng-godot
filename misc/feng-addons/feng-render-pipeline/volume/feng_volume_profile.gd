@tool
class_name FengVolumeProfile
extends Resource
## FRP pass parameters a FengVolume applies while a camera is inside it.
##
## URP drives its render passes from a Volume system. FRP defines its own here, on
## the addon side, because these parameters belong to FRP passes rather than to the
## engine's Environment: a project can therefore turn a pass's settings up or down
## per area (or per camera) without an engine change and without touching the pass
## resources themselves.
##
## The values are keyed by native FRP pass id, exactly like the parameters a pass
## script exposes (see FengPass.get_frp_parameters()):
##
##     pass_parameters = {
##         6: {"jitter_phases": 1},          # Temporal AA
##     }
##
## Numeric values are blended in by the volume's weight; other values are taken from
## the volume once its weight is at least half. This is the first cut: per-parameter
## blend modes (like URP's min/max/add) and pass enable/disable overrides come later.
@export var pass_parameters: Dictionary = {}

## Passes this volume switches on, and passes it switches off, by native pass id.
##
## This is how an effect is turned on for one area without editing the pass
## resources: the entry keeps its authored state, the volume overrides it while the
## camera is inside, and the schedule (and the engine's provided pass set) follows, so
## a pass that is off by default can run inside the volume and a pass that is on can be
## skipped there.
##
## A pass state cannot be interpolated: a volume applies it once its influence is at
## least half, and `enabled_passes` wins over `disabled_passes` at the same priority.
## A mandatory pass (see the pipeline spec) cannot be switched off this way; the
## renderer reports the incomplete schedule instead.
@export var enabled_passes: Array[int] = []
@export var disabled_passes: Array[int] = []
