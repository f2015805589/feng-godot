@tool
class_name FengSkyLightRegistry
extends RefCounted
## One event-maintained set of directional lights per SceneTree. Atmosphere
## providers share the seed scan and resolve against live world/order state.

static var _registries_by_tree: Dictionary = {} # tree instance id -> registry

var _tree_ref: WeakRef
var _tree_id := 0
var _lights: Dictionary = {} # instance id -> WeakRef
var _owners: Dictionary = {} # provider id -> WeakRef
var seed_scan_count := 0


static func attach(tree: SceneTree, owner: Object):
	if tree == null or not is_instance_valid(tree) or owner == null or not is_instance_valid(owner):
		return null
	var tree_id := tree.get_instance_id()
	var registry = _registries_by_tree.get(tree_id)
	if registry != null:
		var registered_tree := registry._tree_ref.get_ref() as SceneTree if registry._tree_ref != null else null
		if registered_tree != tree:
			registry._dispose()
			registry = null
		else:
			registry._prune_owners()
			if registry._owners.is_empty():
				registry._dispose()
				registry = null
	if registry == null:
		registry = load("res://addons/feng-sky/feng_sky_light_registry.gd").new()
		registry._connect_tree(tree)
		_registries_by_tree[tree_id] = registry
	registry._owners[owner.get_instance_id()] = weakref(owner)
	return registry


func detach(owner: Object) -> void:
	if owner != null and is_instance_valid(owner):
		_owners.erase(owner.get_instance_id())
	_prune_owners()
	if _owners.is_empty():
		_dispose()


func resolve(world: World3D, excluded: DirectionalLight3D = null) -> DirectionalLight3D:
	if world == null or not is_instance_valid(world):
		return null
	var selected: DirectionalLight3D
	for instance_id in _lights.keys():
		var reference: WeakRef = _lights[instance_id]
		var light := reference.get_ref() as DirectionalLight3D if reference != null else null
		if light == null or not is_instance_valid(light):
			_lights.erase(instance_id)
			continue
		if light == excluded or not compatible(light, world):
			continue
		# Keep find_children's former depth-first tree-order winner while allowing
		# move_child/reparent/visibility changes to take effect in this same frame.
		if selected == null or selected.is_greater_than(light):
			selected = light
	return selected


static func compatible(light: DirectionalLight3D, world: World3D) -> bool:
	return (
		light != null
		and is_instance_valid(light)
		and light.is_inside_tree()
		and light.is_visible_in_tree()
		and light.get_world_3d() == world
		and light.sky_mode != DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	)


func _connect_tree(tree: SceneTree) -> void:
	_tree_ref = weakref(tree)
	_tree_id = tree.get_instance_id()
	tree.node_added.connect(_on_node_added)
	tree.node_removed.connect(_on_node_removed)
	seed_scan_count += 1
	if tree.root == null:
		return
	for node in tree.root.find_children("*", "DirectionalLight3D", true, false):
		_add_light(node)


func _on_node_added(node: Node) -> void:
	_add_light(node)


func _on_node_removed(node: Node) -> void:
	if node is DirectionalLight3D:
		_lights.erase(node.get_instance_id())


func _add_light(node: Node) -> void:
	if node is DirectionalLight3D:
		_lights[node.get_instance_id()] = weakref(node)


func _prune_owners() -> void:
	for owner_id in _owners.keys():
		var reference: WeakRef = _owners[owner_id]
		if reference == null or reference.get_ref() == null:
			_owners.erase(owner_id)


func _dispose() -> void:
	var tree := _tree_ref.get_ref() as SceneTree if _tree_ref != null else null
	if tree != null and is_instance_valid(tree):
		if tree.node_added.is_connected(_on_node_added):
			tree.node_added.disconnect(_on_node_added)
		if tree.node_removed.is_connected(_on_node_removed):
			tree.node_removed.disconnect(_on_node_removed)
	_lights.clear()
	_owners.clear()
	if _registries_by_tree.get(_tree_id) == self:
		_registries_by_tree.erase(_tree_id)
	_tree_ref = null
	_tree_id = 0
