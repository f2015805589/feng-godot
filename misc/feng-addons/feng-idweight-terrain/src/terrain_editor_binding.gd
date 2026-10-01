extends RefCounted
## Terrain3D stores raw native editor/plugin links. Release them while their
## owners are still alive, without removing a replacement owner's bindings.


## Variant parameters allow an already-freed selection to reach the validity
## guard; typed Object arguments reject it before the function can run.
static func release(p_terrain: Variant, p_editor: Variant, p_plugin: Variant) -> void:
	if not is_instance_valid(p_terrain):
		return
	if is_instance_valid(p_editor) and p_terrain.get_editor() == p_editor:
		p_terrain.set_editor(null)
	if is_instance_valid(p_plugin) and p_terrain.get_plugin() == p_plugin:
		p_terrain.set_plugin(null)
