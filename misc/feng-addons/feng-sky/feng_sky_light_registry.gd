@tool
extends RefCounted
## Scene membership is event-driven; selection visits lights, never all nodes.
## Live world/visibility/order checks preserve editor reparenting and toggles.

var _tree: SceneTree
var _lights: Dictionary = {}
var seed_scan_count := 0


func attach(tree: SceneTree) -> void:
	detach()
	_tree = tree
	if _tree == null:
		return
	_tree.node_added.connect(_added)
	_tree.node_removed.connect(_removed)
	seed_scan_count += 1
	for light in _tree.root.find_children("*", "DirectionalLight3D", true, false):
		_added(light)


func detach() -> void:
	if is_instance_valid(_tree):
		if _tree.node_added.is_connected(_added):
			_tree.node_added.disconnect(_added)
		if _tree.node_removed.is_connected(_removed):
			_tree.node_removed.disconnect(_removed)
	_tree = null
	_lights.clear()


func _added(node: Node) -> void:
	if node is DirectionalLight3D:
		_lights[node.get_instance_id()] = weakref(node)


func _removed(node: Node) -> void:
	if node is DirectionalLight3D:
		_lights.erase(node.get_instance_id())


static func compatible(light: DirectionalLight3D, world: World3D) -> bool:
	return is_instance_valid(light) and light.is_inside_tree() and light.is_visible_in_tree() \
		and light.get_world_3d() == world and light.sky_mode != DirectionalLight3D.SKY_MODE_LIGHT_ONLY


func resolve(world: World3D, excluded: DirectionalLight3D = null) -> DirectionalLight3D:
	var selected: DirectionalLight3D
	for reference: WeakRef in _lights.values():
		var light := reference.get_ref() as DirectionalLight3D
		if light == excluded or not compatible(light, world):
			continue
		if selected == null or selected.is_greater_than(light):
			selected = light
	return selected
