@tool
extends "native_pass.gd"
## Temporal AA: Temporal anti-aliasing and the 3D upscale. This entry is the TAA switch: the viewport jitter follows it.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

## How many jitter phases the viewport cycles through. One phase freezes the sampling
## pattern (Temporal AA still resolves, nothing moves), which is useful to keep a
## stable image or to compare frames; 16 is the engine's own value.
##
## The engine reads it from the schedule the pipeline hands over, so the setter
## notifies: an `@export` member does not emit on its own, and without that an edit in
## the inspector would keep the old phase count until the next unrelated change.
@export_range(1, 64, 1) var jitter_phases: int = 16:
	set(value):
		var next := clampi(value, 1, 64)
		if jitter_phases == next:
			return
		jitter_phases = next
		emit_changed()

func _native_pass_id() -> int:
	return NativeSpec.PASS_TEMPORAL_AA

func get_frp_parameters() -> Dictionary:
	# This pass chooses what it exposes: one typed field, shown in the pipeline
	# resource next to the entry, and read by the engine for the viewport jitter.
	return {"enabled": enabled, "jitter_phases": jitter_phases}

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray(["enabled", "jitter_phases"])
