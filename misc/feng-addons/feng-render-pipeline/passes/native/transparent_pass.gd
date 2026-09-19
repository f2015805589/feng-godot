@tool
extends "native_pass.gd"
## Transparent: The forward queue: the opaque forward fallback, the screen and depth copy the transparent shaders read, and then the transparent geometry.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

func _native_pass_id() -> int:
	return NativeSpec.PASS_TRANSPARENT
