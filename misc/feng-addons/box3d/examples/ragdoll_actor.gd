@tool
class_name FengBox3DRagdollActor
extends CharacterBody3D
## Godot's PhysicalBoneSimulator3D, using Box3D's supported pin/hinge joints.
## Set player_controlled for arrow-key movement; call set_ragdoll() on impact.

signal rigid_body_contact(body: RigidBody3D)

@export var player_controlled := false
@export var move_speed := 3.0
var skeleton: Skeleton3D
var simulator: PhysicalBoneSimulator3D
var physical_bones: Array[PhysicalBone3D] = []
var ragdoll_active := false
var capsule: CollisionShape3D
var _spawn := Transform3D.IDENTITY

func _ready() -> void:
	_spawn = transform
	_build()

func _build() -> void:
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	add_child(skeleton)
	simulator = PhysicalBoneSimulator3D.new()
	simulator.name = "PhysicalBoneSimulator3D"
	# name, parent, world rest centre, radius, capsule height, orientation, joint
	var parts := [
		["hips", -1, Vector3(0, 1.0, 0), 0.18, 0.40, 0.0, 0],
		["chest", 0, Vector3(0, 1.42, 0), 0.22, 0.48, 0.0, 1],
		["head", 1, Vector3(0, 1.86, 0), 0.17, 0.34, 0.0, 1],
		["upper_arm_l", 1, Vector3(-0.42, 1.48, 0), 0.09, 0.36, PI/2, 1],
		["forearm_l", 3, Vector3(-0.76, 1.48, 0), 0.075, 0.34, PI/2, 3],
		["upper_arm_r", 1, Vector3(0.42, 1.48, 0), 0.09, 0.36, PI/2, 1],
		["forearm_r", 5, Vector3(0.76, 1.48, 0), 0.075, 0.34, PI/2, 3],
		["thigh_l", 0, Vector3(-0.16, 0.65, 0), 0.115, 0.43, 0.0, 1],
		["shin_l", 7, Vector3(-0.16, 0.22, 0), 0.09, 0.43, 0.0, 3],
		["thigh_r", 0, Vector3(0.16, 0.65, 0), 0.115, 0.43, 0.0, 1],
		["shin_r", 9, Vector3(0.16, 0.22, 0), 0.09, 0.43, 0.0, 3],
	]
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("e98142")
	material.roughness = 0.6
	# Finalize the skeleton before the simulator builds its bone lookup table.
	for i in parts.size():
		var part: Array = parts[i]
		skeleton.add_bone(part[0])
		var centre: Vector3 = part[2]
		var local := centre
		if part[1] >= 0:
			skeleton.set_bone_parent(i, part[1])
			local -= parts[part[1]][2]
		skeleton.set_bone_rest(i, Transform3D(Basis.IDENTITY, local))
		skeleton.set_bone_pose_position(i, local)
	skeleton.force_update_all_bone_transforms()
	skeleton.add_child(simulator)
	for i in parts.size():
		var part: Array = parts[i]
		var centre: Vector3 = part[2]
		var bone := PhysicalBone3D.new()
		bone.name = "Physical_" + part[0]
		bone.bone_name = part[0]
		bone.collision_layer = 0
		bone.collision_mask = 0
		bone.mass = 6.0 if i < 2 else 1.5
		bone.joint_type = part[6]
		# Adjacent bodies meet midway between their centres.
		bone.joint_offset = Transform3D(Basis(Vector3.UP, PI/2) if i in [8,10] else Basis.IDENTITY,
			(parts[part[1]][2] - centre)*0.5 if part[1] >= 0 else Vector3.ZERO)
		if part[6] == PhysicalBone3D.JOINT_TYPE_HINGE:
			bone.set("joint_constraints/angular_limit_enabled", true)
			bone.set("joint_constraints/angular_limit_lower", -10.0)
			bone.set("joint_constraints/angular_limit_upper", 100.0)
		var shape := CapsuleShape3D.new()
		shape.radius = part[3]
		shape.height = part[4]
		var collision := CollisionShape3D.new()
		collision.shape = shape
		collision.rotation.z = part[5]
		bone.add_child(collision)
		simulator.add_child(bone)
		physical_bones.append(bone)
		add_collision_exception_with(bone)
		bone.add_collision_exception_with(self)
		var attachment := BoneAttachment3D.new()
		attachment.bone_name = part[0]
		skeleton.add_child(attachment)
		var visual := MeshInstance3D.new()
		var mesh := CapsuleMesh.new()
		mesh.radius = part[3]
		mesh.height = part[4]
		mesh.radial_segments = 12
		mesh.rings = 4
		visual.mesh = mesh
		visual.material_override = material
		visual.rotation.z = part[5]
		attachment.add_child(visual)
	# Character capsule drives the standing actor; individual bone collisions only
	# become active when the simulator takes over.
	capsule = CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 2.0
	capsule.shape = shape
	capsule.position.y = 1.0
	add_child(capsule)
	simulator.physical_bones_stop_simulation()

func set_ragdoll(enabled: bool, impulse := Vector3.ZERO) -> void:
	if Engine.is_editor_hint() or simulator == null or enabled == ragdoll_active:
		return
	ragdoll_active = enabled
	# Native rigid bodies advance the ragdoll; no per-frame character callback
	# is needed while it is simulated (or later sleeping).
	set_physics_process(not enabled)
	capsule.disabled = enabled
	for bone in physical_bones:
		bone.collision_layer = 1 if enabled else 0
		bone.collision_mask = 1 if enabled else 0
	if enabled:
		simulator.physical_bones_start_simulation()
		# Preserve the moving actor's momentum and discard residual velocities
		# from a previous ragdoll/reset cycle.
		for bone in physical_bones:
			bone.linear_velocity = velocity
			bone.angular_velocity = Vector3.ZERO
		physical_bones[1].apply_central_impulse(impulse)
	else:
		simulator.physical_bones_stop_simulation()
		for bone in physical_bones:
			bone.linear_velocity = Vector3.ZERO
			bone.angular_velocity = Vector3.ZERO
		skeleton.reset_bone_poses()
		velocity = Vector3.ZERO

func reset_actor() -> void:
	set_ragdoll(false)
	transform = _spawn
	reset_physics_interpolation()

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or ragdoll_active:
		return
	velocity.y -= 9.8 * delta
	var direction := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down") if player_controlled else Vector2.ZERO
	velocity.x = direction.x * move_speed
	velocity.z = direction.y * move_speed
	move_and_slide()
	# Kinematic recovery can resolve an impact before the rigid body's contact
	# monitor sees a manifold. Expose those contacts to gameplay as well.
	for i in get_slide_collision_count():
		var collider := get_slide_collision(i).get_collider()
		if collider is RigidBody3D:
			rigid_body_contact.emit(collider)
