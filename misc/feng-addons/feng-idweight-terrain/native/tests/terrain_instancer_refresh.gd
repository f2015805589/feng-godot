# Run with a graphical rendering driver; see README.md in this directory.
#
# `update_mmis()` with no arguments means "every mesh in every region, without destroying first". It
# queues the `(V2I_MAX, -1)` sentinel, and `Terrain3DInstancer::initialize()` is its caller, so this is
# also what materialises instances after a scene loads.
#
# A pass of this repository removed the arm that recognises that pair and the guard that skips it in the
# pair loop, judging both unreachable. They are not: with them gone the pair fell through to the
# "all mesh ids for this region" expansion, where `V2I_MAX` is not a region - so the refresh built
# nothing and every mesh id logged `Errant null region found at: (2147483647, 2147483647)`.
#
# The observable is the instance count, because it is derived from the resident multimeshes
# (`_recount_master_lods()`). The fixture edits a region's stored transforms directly, which is the state
# a restored or hand-edited region is in, and then asks for the refresh the instancer contract requires.
extends SceneTree

var terrain: Terrain3D
var scene: Node3D
var failed := false


func _initialize() -> void:
	call_deferred("run")


func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true


func settle(frames: int = 4) -> void:
	for i in frames:
		await process_frame


func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_vt_enabled = false
	terrain.surface_svt_enabled = false
	terrain.surface_svt_auto_bake = false
	scene.add_child(terrain)
	root.add_child(scene)
	await process_frame
	terrain.set_physics_process(false)

	var asset := Terrain3DMeshAsset.new()
	asset.generated_type = Terrain3DMeshAsset.TYPE_TEXTURE_CARD
	asset.generated_size = Vector2(2, 4)
	asset.generated_faces = 2
	asset.set_lod_range(0, 1000.0)
	asset.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_OFF
	terrain.assets.set_mesh_asset(0, asset)

	var region := terrain.data.add_region_blank(Vector2i.ZERO)
	var transforms: Array[Transform3D] = []
	var colors := PackedColorArray()
	for i in 4:
		transforms.append(Transform3D(Basis.IDENTITY, Vector3(4 + i * 4, 0, 4)))
		colors.append(Color.WHITE)
	terrain.instancer.add_transforms(0, transforms, colors)
	await settle()
	require(asset.get_instance_count() == 4, "the fixture places four instances")
	print("INSTANCER: count is ", asset.get_instance_count(), " after placing four instances")

	# Edit the stored payload behind the instancer's back: the MMI table is stale until a refresh runs.
	var cells: Dictionary = region.get_instances()[0]
	var cell: Vector2i = cells.keys()[0]
	var triple: Array = cells[cell]
	for i in 4:
		triple[0].append(transforms[i])
		triple[1].append(colors[i])
	triple[2] = true
	require(triple[0].size() == 8, "the fixture doubles the stored transforms")

	terrain.instancer.update_mmis()
	await settle()
	print("INSTANCER: count is ", asset.get_instance_count(), " after update_mmis() with no arguments")
	require(asset.get_instance_count() == 8, "update_mmis() with no arguments refreshes every region")

	scene.queue_free()
	await process_frame
	if not failed:
		print("PASS update_mmis() with no arguments refreshes every region")
	quit(1 if failed else 0)
