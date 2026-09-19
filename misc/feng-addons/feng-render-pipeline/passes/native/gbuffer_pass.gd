@tool
extends "native_pass.gd"
## GBuffer: The single opaque geometry pass. It writes normal/roughness, albedo, ORM, emission and voxel-GI targets and the motion vectors in the same draw.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

func _init() -> void:
	native_id = 2
	resource_name = "GBuffer"
