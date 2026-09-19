@tool
extends "native_pass.gd"
## Sky: Draws the background sky and resolves it into the frame.
##
## The default implementation runs the engine's own pass through ctx.run_pass(), so
## replacing the entry with this script renders the same frame. Override
## _frp_execute() to take the pass over with the granular Core primitives.

func _init() -> void:
	native_id = 4
	resource_name = "Sky"
