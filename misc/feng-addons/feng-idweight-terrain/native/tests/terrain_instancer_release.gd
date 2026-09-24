# Run with a graphical rendering driver; see README.md in this directory.
#
# A region that leaves the data releases its instances. Terrain3DInstancer keeps its MMIs keyed by
# region location, and its teardown paths iterated the regions the *data* currently holds. A region
# that has been removed (the region tool's SUBTRACT, a deletion in the editor) or unloaded (the
# streamer, outside the active range) is gone from the data by then, so its MMI and multimesh RIDs
# were never freed, and the mesh asset's instance count - adjusted only where an MMI is freed - stayed
# inflated for a region that no longer exists.
#
# The count is the observable: it is raised when a multimesh is created and lowered in
# `_destroy_mmi_by_cell()`, so it reaches zero exactly when every MMI was reached. A leaked MMI also
# keeps its RID alive in the RenderingServer, which this test cannot count directly.
#
# Both removal paths are driven, because they reach the instancer differently: `remove_region()` marks
# the region deleted and then updates, while `unload_region()` drops it from memory and then updates.
extends "res://vt_scene_base.gd"

const REMOVED := Vector2i.ZERO
const UNLOADED := Vector2i(1, 0)

var scene: Node3D
# One region's width in metres, read from the terrain rather than assumed: `add_transforms()` groups a
# global batch by the region each transform lands in, and a batch placed over a region that is not
# there adds nothing at all.
var region_span := 0.0


func _initialize() -> void:
	call_deferred("run")


# The instancer queues its work and processes it on the RenderingServer's frame_pre_draw, so the MMIs
# and the count appear a frame or two after the call that asked for them.
func _settle() -> void:
	for i in 4:
		await process_frame


# The transforms are placed inside the region each scenario uses, one region width in.
func _transforms(p_region_x: float) -> Array[Transform3D]:
	var transforms: Array[Transform3D] = []
	for i in 4:
		transforms.append(Transform3D(Basis.IDENTITY,
				Vector3(p_region_x * region_span + 4 + i * 4, 0, 4)))
	return transforms


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
	region_span = float(terrain.region_size) * terrain.vertex_spacing

	var asset := Terrain3DMeshAsset.new()
	asset.generated_type = Terrain3DMeshAsset.TYPE_TEXTURE_CARD
	asset.generated_size = Vector2(2, 4)
	asset.generated_faces = 2
	asset.set_lod_range(0, 1000.0)
	asset.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_OFF
	terrain.assets.set_mesh_asset(0, asset)

	# 1) remove_region(region, true)
	var removed := terrain.data.add_region_blank(REMOVED)
	terrain.instancer.add_transforms(0, _transforms(0.0), PackedColorArray())
	await _settle()
	print("INSTANCER: before remove_region the count is ", asset.get_instance_count())
	require(asset.get_instance_count() == 4, "instances are counted before the region is removed")
	terrain.data.remove_region(removed, true)
	await _settle()
	print("INSTANCER: after remove_region the count is ", asset.get_instance_count())
	require(asset.get_instance_count() == 0, "removing a region releases its instances")

	# 2) unload_region(location, true)
	var unloaded := terrain.data.add_region_blank(UNLOADED)
	require(unloaded != null, "the second region exists before it is used")
	require(terrain.data.get_region_location(Vector3(UNLOADED.x * region_span + 4, 0, 4)) == UNLOADED,
			"the fixture places the second batch inside the second region")
	terrain.instancer.add_transforms(0, _transforms(1.0), PackedColorArray())
	await _settle()
	print("INSTANCER: before unload_region the count is ", asset.get_instance_count())
	require(asset.get_instance_count() == 4, "instances are counted before the region is unloaded")
	terrain.data.unload_region(UNLOADED, true)
	await _settle()
	print("INSTANCER: after unload_region the count is ", asset.get_instance_count())
	require(asset.get_instance_count() == 0, "unloading a region releases its instances")

	scene.queue_free()
	await process_frame
	if not failed:
		print("PASS unloaded or removed regions release their instances")
	quit(1 if failed else 0)
