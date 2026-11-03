@tool
extends Node3D
## Hanging cloth and a pressurized closed mesh, both native SoftBody3D nodes.
const Soft = preload("res://addons/box3d/soft_body_3d.gd")
var cloth: SoftBody3D
var cushion: SoftBody3D
var second_cushion: SoftBody3D

func _ready() -> void:
	build_bodies()

func reset_bodies() -> void:
	if is_instance_valid(cloth):
		cloth.free()
	if is_instance_valid(cushion):
		cushion.free()
	if is_instance_valid(second_cushion):
		second_cushion.free()
	build_bodies()

func build_bodies() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("42c5c7")
	material.roughness = 0.75
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	cloth = Soft.new()
	cloth.tearing_enabled = true
	cloth.tear_stretch_ratio = 2.0
	cloth.name = "Cloth"
	var plane := PlaneMesh.new()
	plane.size = Vector2(3, 2)
	# PlaneMesh adds two end vertices per axis: 64 x 32 = 2048 particles.
	plane.subdivide_width = 62
	plane.subdivide_depth = 30
	# Keep the contact diameter below the minimum rest spacing.
	cloth.collision_radius = 0.004
	cloth.mesh = plane
	cloth.material_override = material
	cloth.position = Vector3(0, 3.4, 0)
	cloth.rotation.x = PI/2
	cloth.linear_stiffness = 0.85
	cloth.simulation_precision = 6
	cloth.total_mass = 1.0
	cloth.damping_coefficient = 0.3
	var vertices: PackedVector3Array = plane.get_mesh_arrays()[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		if vertices[i].z < -0.99 and absf(vertices[i].x)>1.49:
			cloth.set_point_pinned(i, true)
	add_child(cloth)
	cushion = Soft.new()
	cushion.name = "ElasticBall"
	var sphere := SphereMesh.new()
	sphere.radius = 0.7
	sphere.height = 1.4
	sphere.radial_segments = 16
	sphere.rings = 10
	cushion.mesh = sphere
	cushion.position = Vector3(3.5, 2.0, 0)
	cushion.pressure_coefficient = 1.0
	cushion.linear_stiffness = 0.6
	cushion.total_mass = 2.0
	cushion.damping_coefficient = 0.8
	cushion.simulation_precision = 6
	cushion.material_override = material
	add_child(cushion)
	second_cushion = Soft.new()
	second_cushion.name = "SecondElasticBall"
	second_cushion.mesh = sphere
	second_cushion.position = Vector3(3.55, 4.2, 0)
	second_cushion.pressure_coefficient = 1.0
	second_cushion.linear_stiffness = 0.6
	second_cushion.total_mass = 1.5
	second_cushion.damping_coefficient = 0.8
	second_cushion.simulation_precision = 6
	var second_material := material.duplicate()
	second_material.albedo_color = Color("db9062")
	second_cushion.material_override = second_material
	add_child(second_cushion)

func cut_cloth() -> void:
	if is_instance_valid(cloth):
		cloth.cut_segment(global_position + Vector3(-1.6,3.5,0), global_position + Vector3(1.6,3.5,0), 0.04)
