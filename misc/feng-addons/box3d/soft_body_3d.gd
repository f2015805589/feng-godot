@tool
class_name FengBox3DSoftBody3D
extends SoftBody3D
## Box3D's additional solver controls. Ordinary SoftBody3D remains supported.

@export_group("Box3D Sleeping")
@export var can_sleep := true:
	set(value):
		can_sleep = value
		_queue_options()
@export_group("Box3D Contacts")
@export var self_collision := true:
	set(value):
		self_collision = value
		_queue_options()
@export var soft_body_collision := true:
	set(value):
		soft_body_collision = value
		_queue_options()
@export_range(0.001, 0.5, 0.001, "suffix:m") var collision_radius := 0.025:
	set(value):
		collision_radius = value
		_queue_options()
@export_group("Box3D Tearing")
@export var tearing_enabled := false:
	set(value):
		tearing_enabled = value
		_queue_options()
@export_range(1.05, 10.0, 0.05) var tear_stretch_ratio := 1.8:
	set(value):
		tear_stretch_ratio = value
		_queue_options()
@export_range(1, 128, 1) var max_tears_per_substep := 8:
	set(value):
		max_tears_per_substep = value
		_queue_options()
var _options_queued := false

func _ready() -> void:
	apply_solver_options()

func _queue_options() -> void:
	if is_inside_tree() and is_node_ready() and not _options_queued:
		_options_queued = true
		call_deferred("apply_solver_options")

func apply_solver_options() -> void:
	_options_queued = false
	if Engine.is_editor_hint():
		return
	if not PhysicsServer3D.has_method("soft_body_configure"):
		push_error("FengBox3DSoftBody3D 需要更新后的 Box3D Physics 插件并重启。")
		return
	# A new mesh may be assigned after startup. Decide from its topology instead
	# of a one-time flag; Godot also replaces this resource with an owned copy.
	if tearing_enabled and mesh and mesh.get_surface_count() > 0 and not mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].is_empty():
		var source: Mesh = mesh
		var old_pins: Array = get("pinned_points")
		var attachments: Dictionary = {}
		for i in old_pins.size():
			attachments[int(old_pins[i])] = get("attachments/%d/spatial_attachment_path" % i)
		var indices: PackedInt32Array = source.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
		var expanded := make_tearable_mesh(source)
		if expanded == null:
			return
		set("pinned_points", [])
		mesh = expanded
		for i in expanded.surface_get_array_len(0):
			var original := indices[i] if not indices.is_empty() else i
			if original in old_pins:
				set_point_pinned(i, true, attachments.get(original, NodePath()))
	PhysicsServer3D.call("soft_body_configure", get_physics_rid(), {
		"can_sleep": can_sleep,
		"self_collision": self_collision, "soft_collision": soft_body_collision,
		"collision_radius": collision_radius, "tearing": tearing_enabled,
		"tear_ratio": tear_stretch_ratio, "max_tears_per_step": max_tears_per_substep})

func cut_segment(from_world: Vector3, to_world: Vector3, radius := 0.04) -> int:
	if not PhysicsServer3D.has_method("soft_body_cut"):
		return 0
	return int(PhysicsServer3D.call("soft_body_cut", get_physics_rid(), from_world, to_world, radius))

func get_solver_statistics() -> Dictionary:
	if PhysicsServer3D.has_method("soft_body_get_statistics"):
		return PhysicsServer3D.call("soft_body_get_statistics", get_physics_rid())
	return {}

static func make_tearable_mesh(source: Mesh) -> ArrayMesh:
	if source.get_surface_count() != 1:
		push_error("撕裂网格需要一个三角形 surface。")
		return null
	var surface: Dictionary = RenderingServer.mesh_get_surface(source.get_rid(), 0)
	if int(surface.get("primitive", -1)) != Mesh.PRIMITIVE_TRIANGLES:
		push_error("撕裂网格需要三角形拓扑。")
		return null
	var arrays := source.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if vertices.is_empty():
		return null
	if indices.is_empty():
		indices.resize(vertices.size())
		for i in indices.size(): indices[i] = i
	var expanded := arrays.duplicate()
	# Expand every attribute, preserving UVs, tangents, colors and skin data.
	for channel in Mesh.ARRAY_INDEX:
		if arrays[channel] == null or arrays[channel].is_empty():
			continue
		var stride: int = arrays[channel].size() / vertices.size()
		var data = arrays[channel].duplicate()
		data.resize(indices.size() * stride)
		for i in indices.size():
			for component in stride:
				data[i*stride+component] = arrays[channel][indices[i]*stride+component]
		expanded[channel] = data
	expanded[Mesh.ARRAY_INDEX] = null
	var result := ArrayMesh.new()
	var flags: int = int(surface.format) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
	for shift in [Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT]:
		flags |= int(surface.format) & (Mesh.ARRAY_FORMAT_CUSTOM_MASK << shift)
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, expanded, [], {}, flags | Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
	result.surface_set_material(0, source.surface_get_material(0))
	return result
