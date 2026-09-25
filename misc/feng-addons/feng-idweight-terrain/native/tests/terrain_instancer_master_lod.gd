# Run with a graphical rendering driver; see README.md in this directory.
#
# The instance counter follows the master LOD. `_get_master_lod()` answers lod 0 for an ordinary asset
# and `shadow_impostor` for a shadows-only one, and `_update_mmi_by_region()` raises and lowers the
# counter only for the LOD that function names. So a setting that moves it - `cast_shadows` between ON
# and SHADOWS_ONLY - changes which multimesh the count describes, and the count has to follow it: the
# number of placed instances does not change when the LOD the count is read from does.
#
# The asset needs more than one LOD for that, which a generated mesh cannot express (it is one card), so
# the fixture packs a scene whose meshes are named `*LOD?` - the convention `set_scene_file()` looks for.
extends "res://vt_scene_base.gd"

const REMOVED_AFTER := 3

var scene: Node3D
var region_span := 0.0


func _initialize() -> void:
	call_deferred("run")


func _settle() -> void:
	for i in 4:
		await process_frame


# A three-LOD tree: `*LOD0`.. `*LOD2`, which is the naming `set_scene_file()` sorts by last digit.
func _lod_scene() -> PackedScene:
	var root := Node3D.new()
	root.name = "Tree"
	for lod in 3:
		var instance := MeshInstance3D.new()
		instance.name = "TreeLOD%d" % lod
		var box := BoxMesh.new()
		box.size = Vector3.ONE * (1.0 - lod * 0.25)
		instance.mesh = box
		root.add_child(instance)
		instance.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	# `pack()` serialises the node; the builder itself is this fixture's own and would leak with its
	# three meshes and their render instances if it were left to the tree teardown.
	root.free()
	return packed


func _transforms() -> Array[Transform3D]:
	var transforms: Array[Transform3D] = []
	for i in 4:
		transforms.append(Transform3D(Basis.IDENTITY, Vector3(4 + i * 4, 0, 4)))
	return transforms


func run() -> void:
	scene = Node3D.new()
	var test_camera := Camera3D.new()
	test_camera.position = Vector3(16.0, 32.0, 16.0)
	test_camera.current = true
	scene.add_child(test_camera)
	terrain = Terrain3D.new()
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	terrain.set_camera(test_camera)
	terrain.set_clipmap_target(test_camera)
	scene.add_child(terrain)
	root.add_child(scene)
	await process_frame
	terrain.set_physics_process(false)
	region_span = float(terrain.region_size) * terrain.vertex_spacing

	var asset := Terrain3DMeshAsset.new()
	asset.set_scene_file(_lod_scene())
	asset.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_ON
	asset.shadow_impostor = 1
	terrain.assets.set_mesh_asset(0, asset)
	require(asset.get_lod_count() == 3, "the scene file provides three LODs")
	require(asset.shadow_impostor == 1, "the scene fixture sets the shadow impostor to LOD1")

	terrain.data.add_region_blank(Vector2i.ZERO)
	terrain.instancer.add_transforms(0, _transforms(), PackedColorArray())
	await _settle()
	var placed := asset.get_instance_count()
	print("INSTANCER: count is ", placed, " with the master LOD at lod 0")
	require(placed == 4, "the placed instances are counted once")

	# Move the master LOD to the shadow impostor.
	asset.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	await _settle()
	print("INSTANCER: count is ", asset.get_instance_count(), " in shadows-only, master LOD is the impostor")
	require(asset.get_instance_count() == placed, "moving the master LOD keeps one LOD's worth of instances")

	# Move it back.
	asset.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_ON
	await _settle()
	print("INSTANCER: count is ", asset.get_instance_count(), " back with the master LOD at lod 0")
	require(asset.get_instance_count() == placed, "moving the master LOD back keeps one LOD's worth")

	# And to a different impostor.
	asset.shadow_impostor = 2
	asset.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	await _settle()
	print("INSTANCER: count is ", asset.get_instance_count(), " with the master LOD at lod 2")
	require(asset.get_instance_count() == placed, "moving the master LOD to another LOD keeps one LOD's worth")

	terrain.instancer.clear_by_mesh(0)
	await _settle()
	require(asset.get_instance_count() == 0, "clearing releases every instance again")

	scene.queue_free()
	await process_frame
	if not failed:
		print("PASS the instance count follows the master LOD")
	quit(1 if failed else 0)
