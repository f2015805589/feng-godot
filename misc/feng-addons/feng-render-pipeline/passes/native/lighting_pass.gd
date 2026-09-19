@tool
extends "native_pass.gd"
## Lighting: Deferred lighting, the subsurface/specular merge and the opaque resolve: the frame's lit colour.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

func _init() -> void:
	native_id = 3
	resource_name = "Lighting"
