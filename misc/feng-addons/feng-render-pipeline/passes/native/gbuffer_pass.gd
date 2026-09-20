@tool
extends "native_pass.gd"
## GBuffer: The single opaque geometry pass. It writes normal, albedo, ORM (including the low-nibble shading-model ID), and emission; motion vectors are written in the same draw when requested.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

func _native_pass_id() -> int:
	return NativeSpec.PASS_GBUFFER
