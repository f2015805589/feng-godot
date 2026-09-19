@tool
extends "native_pass.gd"
## Shadow Precompute: drawing the shadow maps for every shadow-casting light.
##
## This is the one preparation step that depends on nothing else in the frame: it
## renders from each light's point of view, so it reads no scene depth, no G-buffer
## and no material page. That is why it is the pipeline's first pass, before virtual
## texture updates and the G-buffer.
##
## The light and cluster buffers are *not* here: they are consumed by the Lighting
## pass, so they are prepared there.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

func _native_pass_id() -> int:
	return NativeSpec.PASS_SHADOW_PRECOMPUTE
