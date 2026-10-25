@tool
extends Node
## Scene-scoped service used by the Environment Light Mixer window.
##
## The service discovers only the authored FRP lighting actors described below.
## It does not inspect the project pipeline or render volumes. Property editing is
## delegated to EditorInspector so component resources keep their normal Godot
## serialization and UndoRedo behavior.

signal snapshot_changed(snapshot: Dictionary)
signal components_created(nodes: Array)

const COMPONENTS: Array[Dictionary] = [
	{
		"id": &"atmosphere_sun",
		"label": "Atmosphere Sun",
		"short_label": "太阳",
		"native_class": "DirectionalLight3D",
		"node_name": "AtmosphereSun",
	},
	{
		"id": &"sky_light",
		"label": "SkyLight",
		"short_label": "SkyLight",
		"script_path": "res://addons/feng-sky/feng_sky_light.gd",
		"global_class": "FengSkyLight",
		"node_name": "SkyLight",
	},
	{
		"id": &"sky_atmosphere",
		"label": "Sky Atmosphere",
		"short_label": "天空大气",
		"script_path": "res://addons/feng-sky/feng_sky_atmosphere.gd",
		"global_class": "FengSkyAtmosphere",
		"node_name": "SkyAtmosphere",
	},
	{
		"id": &"volumetric_cloud",
		"label": "Volumetric Cloud",
		"short_label": "体积云",
		"script_path": "res://addons/feng-cloud/feng_volumetric_cloud.gd",
		"global_class": "FengVolumetricCloud",
		"node_name": "VolumetricCloud",
	},
	{
		"id": &"height_fog",
		"label": "Height Fog",
		"short_label": "高度雾",
		"script_path": "res://addons/feng-fog/feng_height_fog.gd",
		"global_class": "FengHeightFog",
		"node_name": "HeightFog",
	},
]

var _editor_plugin_ref: WeakRef
var _scene_root_ref: WeakRef
var _watched_nodes: Dictionary = {}
var _undo_redo_manager: EditorUndoRedoManager
var _snapshot_cache: Dictionary = {}
var _refresh_queued := false
var _atmospheric_only := true


func start(p_editor_plugin: EditorPlugin) -> void:
	stop()
	if p_editor_plugin == null or not is_instance_valid(p_editor_plugin):
		return
	_editor_plugin_ref = weakref(p_editor_plugin)
	if not p_editor_plugin.scene_changed.is_connected(_on_editor_scene_changed):
		p_editor_plugin.scene_changed.connect(_on_editor_scene_changed)
	if not p_editor_plugin.scene_closed.is_connected(_on_editor_scene_closed):
		p_editor_plugin.scene_closed.connect(_on_editor_scene_closed)
	_undo_redo_manager = p_editor_plugin.get_undo_redo()
	if _undo_redo_manager != null:
		_undo_redo_manager.history_changed.connect(_on_undo_redo_changed)
		_undo_redo_manager.version_changed.connect(_on_undo_redo_changed)
	var tree := get_tree() if is_inside_tree() else null
	if tree != null:
		if not tree.node_added.is_connected(_on_tree_node_added):
			tree.node_added.connect(_on_tree_node_added)
		if not tree.node_removed.is_connected(_on_tree_node_removed):
			tree.node_removed.connect(_on_tree_node_removed)
	refresh()


func stop() -> void:
	var plugin := _editor_plugin()
	if plugin != null:
		if plugin.scene_changed.is_connected(_on_editor_scene_changed):
			plugin.scene_changed.disconnect(_on_editor_scene_changed)
		if plugin.scene_closed.is_connected(_on_editor_scene_closed):
			plugin.scene_closed.disconnect(_on_editor_scene_closed)
	if is_instance_valid(_undo_redo_manager):
		_undo_redo_manager.history_changed.disconnect(_on_undo_redo_changed)
		_undo_redo_manager.version_changed.disconnect(_on_undo_redo_changed)
	_undo_redo_manager = null
	var tree := get_tree() if is_inside_tree() else null
	if tree != null:
		if tree.node_added.is_connected(_on_tree_node_added):
			tree.node_added.disconnect(_on_tree_node_added)
		if tree.node_removed.is_connected(_on_tree_node_removed):
			tree.node_removed.disconnect(_on_tree_node_removed)
	_unwatch_scene_nodes()
	_scene_root_ref = null
	_snapshot_cache.clear()
	_editor_plugin_ref = null


func _exit_tree() -> void:
	stop()


func _editor_plugin() -> EditorPlugin:
	var plugin: Variant = _editor_plugin_ref.get_ref() if _editor_plugin_ref != null else null
	if not is_instance_valid(plugin) or not (plugin is EditorPlugin):
		return null
	return plugin as EditorPlugin


func get_scene_root() -> Node:
	var root: Variant = _scene_root_ref.get_ref() if _scene_root_ref != null else null
	if is_instance_valid(root) and root is Node:
		return root as Node
	return null


func get_component_definitions() -> Array[Dictionary]:
	return COMPONENTS.duplicate(true)


func set_atmospheric_only(p_enabled: bool) -> void:
	if _atmospheric_only == p_enabled:
		return
	_atmospheric_only = p_enabled
	refresh()


func get_snapshot() -> Dictionary:
	var root := _current_edited_scene_root()
	if _snapshot_cache_needs_refresh(root):
		refresh()
	return _snapshot_cache.duplicate(true)


func _snapshot_cache_needs_refresh(p_current_root: Node) -> bool:
	if _snapshot_cache.is_empty() or p_current_root != get_scene_root():
		return true
	var cached_root: Variant = _snapshot_cache.scene_root
	if bool(_snapshot_cache.has_scene) != is_instance_valid(cached_root):
		return true
	if is_instance_valid(cached_root) and cached_root != p_current_root:
		return true
	for rows in _snapshot_cache.components.values():
		for row in rows:
			if not is_instance_valid(row.node):
				return true
	return false


func refresh() -> void:
	var root := _current_edited_scene_root()
	var previous := get_scene_root()
	if previous != root:
		_unwatch_scene_nodes()
		_scene_root_ref = weakref(root) if root != null else null
	var scan := _scan_scene(root)
	_snapshot_cache = scan["snapshot"]
	_sync_rename_watches(scan["watch_nodes"])
	snapshot_changed.emit(_snapshot_cache.duplicate(true))


func create_missing_component(p_component_id: StringName) -> Array[Node]:
	return create_missing_components([p_component_id])


func create_environment_scene() -> Array[Node]:
	if _current_edited_scene_root() == null:
		var root := Node3D.new()
		root.name = "EnvironmentScene"
		EditorInterface.add_root_node(root)
		_schedule_refresh()
	var ids: Array[StringName] = []
	for definition in COMPONENTS:
		ids.append(definition["id"])
	return create_missing_components(ids)


func create_missing_components(p_component_ids: Array) -> Array[Node]:
	var root := _current_edited_scene_root()
	if root == null or not root.is_inside_tree():
		return []
	var requested: Dictionary = {}
	for component_id in p_component_ids:
		requested[StringName(component_id)] = true
	var existing_by_id := _existing_nodes_by_id(root)
	var created_by_id: Dictionary = {}
	var created: Array[Node] = []
	for definition in COMPONENTS:
		var component_id: StringName = definition["id"]
		if not requested.has(component_id) or not existing_by_id.get(component_id, []).is_empty():
			continue
		var node := _instantiate_component(definition, root)
		if node == null:
			for partial in created:
				partial.free()
			return []
		created.append(node)
		created_by_id[component_id] = node

	if created.is_empty():
		return []
	_configure_new_components(created_by_id, existing_by_id)
	if not _commit_create_action(root, created):
		for partial in created:
			if is_instance_valid(partial) and partial.get_parent() == null:
				partial.free()
		return []
	EditorInterface.mark_scene_as_unsaved()
	components_created.emit(created)
	refresh.call_deferred()
	return created


func _commit_create_action(p_root: Node, p_nodes: Array[Node]) -> bool:
	var plugin := _editor_plugin()
	if plugin == null:
		return false
	var undo_redo = plugin.get_undo_redo()
	if undo_redo == null:
		return false
	var labels: PackedStringArray = []
	for node in p_nodes:
		labels.append(String(node.name))
	undo_redo.create_action("Create Environment Components: %s" % ", ".join(labels),
			UndoRedo.MERGE_DISABLE, p_root)
	for node in p_nodes:
		undo_redo.add_do_method(p_root, "add_child", node, true)
		undo_redo.add_do_method(node, "set_owner", p_root)
		undo_redo.add_do_reference(node)
		undo_redo.add_undo_method(p_root, "remove_child", node)
	undo_redo.commit_action()
	return true


func _instantiate_component(p_definition: Dictionary, p_scene_root: Node) -> Node:
	var node: Node
	var instance: Object
	var native_class := String(p_definition.get("native_class", ""))
	if not native_class.is_empty():
		instance = ClassDB.instantiate(native_class)
		node = instance as Node
	else:
		var script_path := String(p_definition.get("script_path", ""))
		var script: Script = load(script_path) as Script if not script_path.is_empty() else null
		if script != null:
			instance = script.new()
			node = instance as Node
	if node == null:
		push_error("Environment Mixer could not instantiate %s." % p_definition.get("label", "component"))
		return null
	node.name = StringName(p_definition.get("node_name", "EnvironmentComponent"))
	_apply_creation_defaults(node, StringName(p_definition["id"]), p_scene_root)
	return node


func _apply_creation_defaults(p_node: Node, p_component_id: StringName, p_scene_root: Node) -> void:
	if p_component_id == &"atmosphere_sun":
		# Godot's DirectionalLight3D default is 100,000 lux; make the new-scene
		# preset explicit while leaving global physical-unit settings untouched.
		p_node.set("light_intensity_lux", 100000.0)
		p_node.set("shadow_enabled", true)
		p_node.set("rotation_degrees", Vector3(-45.0, 0.0, 0.0))
	elif p_component_id == &"sky_atmosphere" and p_node is WorldEnvironment:
		if not _scene_has_camera_attribute_override(p_scene_root):
			var camera_attributes := CameraAttributesPhysical.new()
			camera_attributes.resource_local_to_scene = true
			camera_attributes.exposure_aperture = 16.0
			camera_attributes.exposure_shutter_speed = 100.0
			camera_attributes.exposure_sensitivity = 100.0
			p_node.camera_attributes = camera_attributes


func _scene_has_camera_attribute_override(p_scene_root: Node) -> bool:
	if p_scene_root == null:
		return false
	var pending: Array[Node] = [p_scene_root]
	var cursor := 0
	while cursor < pending.size():
		var node := pending[cursor]
		cursor += 1
		if node is Camera3D and node.attributes != null:
			return true
		if node is WorldEnvironment and node.camera_attributes != null:
			return true
		pending.append_array(node.get_children(false))
	return false


func _configure_new_components(p_created: Dictionary, p_existing: Dictionary) -> void:
	var sun: Node = p_created.get(&"atmosphere_sun", _first_valid(p_existing.get(&"atmosphere_sun", [])))
	var atmosphere: Node = p_created.get(&"sky_atmosphere", _first_valid(p_existing.get(&"sky_atmosphere", [])))
	var created_atmosphere: Node = p_created.get(&"sky_atmosphere")
	if created_atmosphere != null and sun != null:
		created_atmosphere.set("sun_light", sun)
	var cloud: Node = p_created.get(&"volumetric_cloud")
	if cloud != null:
		if atmosphere != null:
			cloud.set("planet_source", atmosphere)
		if sun != null:
			cloud.set("primary_sun", sun)


func _first_valid(p_nodes: Array) -> Node:
	for node in p_nodes:
		if is_instance_valid(node):
			return node as Node
	return null


func _missing_component_ids(p_rows_by_id: Dictionary) -> Array[StringName]:
	var result: Array[StringName] = []
	for definition in COMPONENTS:
		var component_id: StringName = definition["id"]
		if p_rows_by_id.get(component_id, []).is_empty():
			result.append(component_id)
	return result


func _existing_nodes_by_id(p_root: Node) -> Dictionary:
	return _scan_scene(p_root)["nodes_by_id"]


func _find_component_nodes(p_root: Node, p_definition: Dictionary) -> Array[Node]:
	if p_root == null:
		return []
	var nodes_by_id: Dictionary = _scan_scene(p_root)["nodes_by_id"]
	var result: Array[Node] = []
	for node in nodes_by_id.get(p_definition.get("id"), []):
		result.append(node)
	return result


func _scan_scene(p_root: Node) -> Dictionary:
	var nodes_by_id: Dictionary = {}
	for definition in COMPONENTS:
		nodes_by_id[definition["id"]] = []
	var watch_nodes: Dictionary = {}
	var primary_sun_ids: Dictionary = {}
	var secondary_sun_ids: Dictionary = {}
	if p_root != null:
		var pending: Array[Node] = [p_root]
		var cursor := 0
		while cursor < pending.size():
			var node := pending[cursor]
			cursor += 1
			var definition := component_definition(node)
			if not definition.is_empty():
				nodes_by_id[definition.id].append(node)
			pending.append_array(node.get_children(false))

		for atmosphere in nodes_by_id[&"sky_atmosphere"]:
			var linked_sun: Variant = atmosphere.get("sun_light")
			var linked_secondary: Variant = atmosphere.get("secondary_sun_light")
			if linked_sun is DirectionalLight3D:
				primary_sun_ids[linked_sun.get_instance_id()] = true
			if linked_secondary is DirectionalLight3D:
				secondary_sun_ids[linked_secondary.get_instance_id()] = true

		var selected_suns: Array[Node] = []
		var other_suns: Array[Node] = []
		for sun in nodes_by_id[&"atmosphere_sun"]:
			if secondary_sun_ids.has(sun.get_instance_id()):
				continue
			if _atmospheric_only and sun.sky_mode == DirectionalLight3D.SKY_MODE_LIGHT_ONLY:
				continue
			if primary_sun_ids.has(sun.get_instance_id()):
				selected_suns.append(sun)
			else:
				other_suns.append(sun)
		nodes_by_id[&"atmosphere_sun"] = selected_suns + other_suns

		for definition in COMPONENTS:
			for component in nodes_by_id[definition["id"]]:
				var ancestor: Node = component
				while ancestor != null:
					watch_nodes[ancestor.get_instance_id()] = ancestor
					if ancestor == p_root:
						break
					ancestor = ancestor.get_parent()

	var rows_by_id: Dictionary = {}
	for definition in COMPONENTS:
		var component_id: StringName = definition["id"]
		var rows: Array[Dictionary] = []
		for node in nodes_by_id[component_id]:
			rows.append({
				"id": component_id,
				"node": node,
				"name": String(node.name),
				"path": p_root.get_path_to(node),
			})
		rows_by_id[component_id] = rows
	var can_create := p_root != null and p_root.is_inside_tree()
	var snapshot := {
		"scene_root": p_root,
		"has_scene": p_root != null,
		"components": rows_by_id,
		"can_create": can_create,
		"missing_ids": _missing_component_ids(rows_by_id) if can_create else [],
	}
	return {
		"nodes_by_id": nodes_by_id,
		"watch_nodes": watch_nodes.values(),
		"snapshot": snapshot,
	}


static func component_definition(p_object: Object) -> Dictionary:
	for definition in COMPONENTS:
		if definition.has("native_class") and p_object.is_class(definition.native_class):
			return definition
	var script := p_object.get_script() as Script
	while script != null:
		for definition in COMPONENTS:
			if definition.has("script_path") and (script.resource_path == definition.script_path \
					or script.get_global_name() == definition.global_class):
				return definition
		script = script.get_base_script()
	return {}


func _current_edited_scene_root() -> Node:
	var root := EditorInterface.get_edited_scene_root()
	return root if root != null and is_instance_valid(root) else null


func _sync_rename_watches(p_watch_nodes: Array) -> void:
	var next_nodes: Dictionary = {}
	for node in p_watch_nodes:
		if not is_instance_valid(node):
			continue
		next_nodes[node.get_instance_id()] = weakref(node)
		if not node.renamed.is_connected(_on_scene_node_renamed):
			node.renamed.connect(_on_scene_node_renamed)
	for instance_id in _watched_nodes:
		if next_nodes.has(instance_id):
			continue
		var node_ref: WeakRef = _watched_nodes[instance_id]
		var node: Object = node_ref.get_ref()
		if is_instance_valid(node) and node is Node and node.renamed.is_connected(_on_scene_node_renamed):
			node.renamed.disconnect(_on_scene_node_renamed)
	_watched_nodes = next_nodes


func _unwatch_scene_nodes() -> void:
	for node_ref in _watched_nodes.values():
		var node: Object = node_ref.get_ref()
		if is_instance_valid(node) and node is Node and node.renamed.is_connected(_on_scene_node_renamed):
			node.renamed.disconnect(_on_scene_node_renamed)
	_watched_nodes.clear()


func _on_editor_scene_changed(_scene_root: Node) -> void:
	_schedule_refresh()


func _on_editor_scene_closed(_filepath: String) -> void:
	_schedule_refresh()


func _on_tree_node_added(p_node: Node) -> void:
	if _belongs_to_current_scene(p_node) and _subtree_has_component(p_node):
		_schedule_refresh()


func _on_tree_node_removed(p_node: Node) -> void:
	if p_node == get_scene_root() or _watched_nodes.has(p_node.get_instance_id()):
		_schedule_refresh()


func _on_scene_node_renamed() -> void:
	_schedule_refresh()


func _on_undo_redo_changed() -> void:
	_schedule_refresh()


func _subtree_has_component(p_node: Node) -> bool:
	var pending: Array[Node] = [p_node]
	var cursor := 0
	while cursor < pending.size():
		var node := pending[cursor]
		cursor += 1
		if not component_definition(node).is_empty():
			return true
		pending.append_array(node.get_children(false))
	return false


func _belongs_to_current_scene(p_node: Node) -> bool:
	var root := _current_edited_scene_root()
	return root != null and (p_node == root or root.is_ancestor_of(p_node))


func _schedule_refresh() -> void:
	if not is_inside_tree() or _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_flush_queued_refresh")


func _flush_queued_refresh() -> void:
	_refresh_queued = false
	if is_inside_tree() and _editor_plugin() != null:
		refresh()
