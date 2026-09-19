@tool
class_name FengWorldCompositor
extends RefCounted
## The compositor a viewport renders with, resolved the way the engine resolves it.
##
## The engine keeps the WorldEnvironments that carry a compositor in a group named after
## the scenario and lets the first member of that group provide the world's compositor
## (see WorldEnvironment::_update_current_compositor); World3D's own compositor is not
## exposed to scripts. The group name is therefore engine-internal knowledge, and it is
## written down here once, for the two systems that need it: the project pipeline, which
## has to step aside for a compositor a scene authored, and the volume system, which has
## to find the compositor it pushes its overrides to.

static func _group_nodes(p_viewport: Viewport, p_world: World3D) -> Array:
	if p_world == null:
		return []
	var tree := p_viewport.get_tree() if p_viewport != null else null
	if tree == null:
		return []
	return tree.get_nodes_in_group("_world_compositor_" + str(p_world.get_scenario().get_id()))

## The compositor the world provides: the first WorldEnvironment that carries one. Null
## when nothing in the world has a compositor.
static func world_compositor(p_viewport: Viewport) -> Compositor:
	var world := p_viewport.find_world_3d() if p_viewport != null else null
	for node in _group_nodes(p_viewport, world):
		if node is WorldEnvironment and node.compositor != null:
			return node.compositor
	return null

## The compositor a node other than `p_exclude` provides for the world. This is the
## question the project pipeline asks before installing its own: a compositor a scene
## authored wins.
static func other_world_compositor(p_viewport: Viewport, p_exclude: Node) -> Compositor:
	var world := p_viewport.find_world_3d() if p_viewport != null else null
	for node in _group_nodes(p_viewport, world):
		if node != p_exclude and node is WorldEnvironment and node.compositor != null:
			return node.compositor
	return null

## The compositor a camera renders with: its own, else the world's.
static func active_compositor(p_viewport: Viewport, p_camera: Camera3D) -> Compositor:
	if p_camera != null and p_camera.compositor != null:
		return p_camera.compositor
	return world_compositor(p_viewport)
