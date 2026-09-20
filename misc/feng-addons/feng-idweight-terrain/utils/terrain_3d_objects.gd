# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Objects parent for Terrain3D
# Children nodes get transform updates on sculpting
#
# Add this node above the props you want glued to the terrain: every Node3D child
# gets a hidden `TransformChangedSignaller`, and moving one re-derives its offset
# from the terrain height so an edit that raises the ground carries the child with
# it (through an undo action). `_offsets` is that state: node instance id ->
# Vector3(X, height above the terrain, Z).
#
# Editor only. `editor_setup()` hands the plugin's undo/redo manager in, and
# `get_terrain()` finds the edited scene's first Terrain3D when the cached one has
# gone away - both assume the editor has an edited scene root.
@tool
extends Node3D
class_name Terrain3DObjects

const TransformChangedNotifier: Script = preload("res://addons/feng-idweight-terrain/utils/transform_changed_notifier.gd")

const CHILD_HELPER_NAME: StringName = &"TransformChangedSignaller"
const CHILD_HELPER_PATH: NodePath = ^"TransformChangedSignaller"

var _undo_redo = null
var _terrain_id: int
var _observed_terrain_data = null
var _offsets: Dictionary # Object ID -> Vector3(X, Y offset relative to terrain height, Z)
var _child_transform_callbacks: Dictionary = {}
var _ignore_transform_change: bool = false


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		return
	
	for child in get_children():
		_on_child_entered_tree(child)
	
	child_entered_tree.connect(_on_child_entered_tree)
	child_exiting_tree.connect(_on_child_exiting_tree)


func _exit_tree() -> void:
	if not Engine.is_editor_hint():
		return
	
	_disconnect_terrain_data()
	child_entered_tree.disconnect(_on_child_entered_tree)
	child_exiting_tree.disconnect(_on_child_exiting_tree)
	
	for child in get_children():
		_on_child_exiting_tree(child)
	_child_transform_callbacks.clear()


# Called by the plugin once, with itself: transform tracking registers its changes
# as undo actions, so without it `_on_child_transform_changed()` cannot run.
func editor_setup(p_plugin) -> void:
	_undo_redo = p_plugin.get_undo_redo()


# The terrain this parent follows: the cached one if it is still valid and in the
# tree, otherwise the first Terrain3D in the edited scene, which is then cached.
func get_terrain() -> Terrain3D:
	var terrain := instance_from_id(_terrain_id) as Terrain3D
	if not terrain or terrain.is_queued_for_deletion() or not terrain.is_inside_tree():
		var terrains: Array[Node] = Engine.get_singleton(&"EditorInterface").get_edited_scene_root().find_children("", "Terrain3D")
		if terrains.size() > 0:
			terrain = terrains[0]
		_terrain_id = terrain.get_instance_id() if terrain else 0
	
	_bind_terrain_data(terrain.data if terrain and terrain.data else null)
	
	return terrain


func _bind_terrain_data(p_data) -> void:
	if p_data == _observed_terrain_data:
		if p_data != null and is_instance_valid(p_data) and not p_data.maps_edited.is_connected(_on_maps_edited):
			p_data.maps_edited.connect(_on_maps_edited)
		return
	_disconnect_terrain_data()
	if p_data == null or not is_instance_valid(p_data):
		return
	if not p_data.maps_edited.is_connected(_on_maps_edited):
		p_data.maps_edited.connect(_on_maps_edited)
	_observed_terrain_data = p_data


func _disconnect_terrain_data() -> void:
	var data = _observed_terrain_data
	_observed_terrain_data = null
	if data != null and is_instance_valid(data) and data.maps_edited.is_connected(_on_maps_edited):
		data.maps_edited.disconnect(_on_maps_edited)


func _get_terrain_height(p_global_position: Vector3) -> float:
	var terrain: Terrain3D = get_terrain()
	if not terrain or not terrain.data:
		return 0.0
	var height: float = terrain.data.get_surface_height(p_global_position)
	if is_nan(height):
		return 0.0
	return height


func _on_child_entered_tree(p_node: Node) -> void:
	if not (p_node is Node3D):
		return
	
	assert(p_node.get_parent() == self)
	
	var helper: TransformChangedNotifier = p_node.get_node_or_null(CHILD_HELPER_PATH)
	if not helper:
		helper = TransformChangedNotifier.new()
		helper.name = CHILD_HELPER_NAME
		p_node.add_child(helper, true, INTERNAL_MODE_BACK)
	assert(p_node.has_node(CHILD_HELPER_PATH))
	
	# When reparenting a Node3D, Godot changes its transform _after_ reparenting it. So here,
	# we must use call_deferred, to avoid receiving transform_changed as a result of reparenting.
	_setup_child_signal.call_deferred(p_node, helper)


func _setup_child_signal(p_node: Node, helper: TransformChangedNotifier) -> void:
	if not is_instance_valid(p_node) or not p_node.is_inside_tree():
		return
	var child_id := p_node.get_instance_id()
	var callback: Callable = _child_transform_callbacks.get(child_id, Callable())
	if not callback.is_valid():
		callback = _on_child_transform_changed.bind(p_node)
		_child_transform_callbacks[child_id] = callback
	if not helper.transform_changed.is_connected(callback):
		helper.transform_changed.connect(callback)
	_update_child_offset(p_node)


func _on_child_exiting_tree(p_node: Node) -> void:
	if not p_node is Node3D:
		return
	var child_id := p_node.get_instance_id()
	
	var helper: TransformChangedNotifier = p_node.get_node_or_null(CHILD_HELPER_PATH)
	if helper:
		var callback: Callable = _child_transform_callbacks.get(child_id, _on_child_transform_changed.bind(p_node))
		if helper.transform_changed.is_connected(callback):
			helper.transform_changed.disconnect(callback)
		p_node.remove_child(helper)
		helper.queue_free()
	
	_child_transform_callbacks.erase(child_id)
	_offsets.erase(p_node.get_instance_id())


func _is_node_selected(p_node: Node) -> bool:
	var editor_sel = Engine.get_singleton(&"EditorInterface").get_selection()
	return editor_sel.get_transformable_selected_nodes().has(p_node)


func _on_child_transform_changed(p_node: Node3D) -> void:
	if _ignore_transform_change:
		return
	
	var lmb_down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if lmb_down and (_is_node_selected(p_node) or _is_node_selected(self)):
		# The user may be moving the node using gizmos.
		# We should wait until they're done before updating otherwise gizmos + this node conflict.
		return
	
	if not _offsets.has(p_node.get_instance_id()):
		return
	
	var old_offset: Vector3 = _offsets[p_node.get_instance_id()]
	var old_h: float = _get_terrain_height(old_offset)
	var old_position: Vector3 = old_offset + Vector3(0, old_h, 0)
	var new_position: Vector3 = p_node.global_position
	if old_position.is_equal_approx(new_position):
		return
	var new_h: float = _get_terrain_height(new_position)
	var new_offset: Vector3 = new_position - Vector3(0, new_h, 0)
	
	var translate_without_reposition: bool = Input.is_key_pressed(KEY_SHIFT)
	var y_changed: bool = not is_equal_approx(old_position.y, p_node.global_position.y)
	if not y_changed and not translate_without_reposition:
		new_offset.y = old_offset.y
		new_position = new_offset + Vector3(0, new_h, 0)
	
	# Make sure that when the user undo's the translation, the offset change gets undone too!
	_undo_redo.create_action("Translate", UndoRedo.MERGE_ALL)
	_undo_redo.add_do_method(self, &"_set_offset_and_position", p_node.get_instance_id(), new_offset, new_position)
	_undo_redo.add_undo_method(self, &"_set_offset_and_position", p_node.get_instance_id(), old_offset, old_position)
	_undo_redo.commit_action()


func _set_offset_and_position(p_id: int, p_offset: Vector3, p_position: Vector3) -> void:
	var node := instance_from_id(p_id) as Node
	if not is_instance_valid(node):
		return
	
	_ignore_transform_change = true
	node.global_position = p_position
	_offsets[p_id] = p_offset
	_ignore_transform_change = false


# Overwrite current offset stored for node with its current Y position relative to the terrain
func _update_child_offset(p_node: Node3D) -> void:
	var position: Vector3 = global_transform * p_node.position
	var h: float = _get_terrain_height(position)
	var offset: Vector3 = position - Vector3(0, h, 0)
	_offsets[p_node.get_instance_id()] = offset


# Overwrite node's current position with terrain height + stored offset for this node
func _update_child_position(p_node: Node3D) -> void:
	if not _offsets.has(p_node.get_instance_id()):
		return
	
	var position: Vector3 = global_transform * p_node.position
	var h: float = _get_terrain_height(position)
	var offset: Vector3 = _offsets[p_node.get_instance_id()]
	var new_position: Vector3 = global_transform.inverse() * (offset + Vector3(0, h, 0))
	if not p_node.position.is_equal_approx(new_position):
		p_node.position = new_position


func _on_maps_edited(p_edited_aabb: AABB) -> void:
	var edited_area: AABB = p_edited_aabb.grow(1)
	edited_area.position.y = -INF
	edited_area.end.y = INF
	
	for child in get_children():
		var node := child as Node3D
		if node && edited_area.has_point(node.global_position):
			_update_child_position(node)
