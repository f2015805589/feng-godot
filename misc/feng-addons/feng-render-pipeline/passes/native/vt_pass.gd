@tool
extends "native_pass.gd"
## VT Pass: Virtual texture page updates and feedback, before any geometry is drawn.
##
## Runs second, after the shadow maps: the shadow pass draws geometry, but it never
## samples a material page, so it cannot depend on a page this pass produces.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

func _native_pass_id() -> int:
	return NativeSpec.PASS_VIRTUAL_TEXTURE
