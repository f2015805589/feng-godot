# Run with a graphical rendering driver; see README.md in this directory.
#
# A far-field demand setting must not rebuild the physical pool.
#
# `surface_svt_root_mips` decides how many root mips the far field protects. It changes no address, no
# page size and no atlas dimension - `_update_visible_svt()` mixes it into the plan hash, so a changed
# count invalidates the plan by itself - yet its setter called `_reset_vt_configuration()`, which clears
# the shared-pool flag, cancels a bake in flight and invalidates the shader materials. Clearing that flag
# makes the next update rebuild the pool, and the near field's resident pages go with it.
#
# `get_vt_settings()["shared_pool"]` is the observable, read *immediately* after each setter so no frame
# can re-establish the pool in between. The test asserts both halves of the distinction - a demand-side
# setting leaves the flag alone, a page-footprint setting clears it - because a fix that simply stopped
# resetting would break the second half.
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


func shared_pool() -> bool:
	return bool(terrain.get_vt_settings().get("shared_pool", false))


func settle(frames: int = 8) -> void:
	for i in frames:
		await process_frame


func run() -> void:
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	scene.add_child(terrain)
	root.add_child(scene)
	# The service only configures its pool with a camera to demand for.
	var camera := Camera3D.new()
	camera.position = Vector3(32, 40, 64)
	camera.current = true
	root.add_child(camera)
	camera.look_at(Vector3(32, 0, 32))
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	await process_frame
	# Physics processing is left on: the physics tick is what drives `_update_vt_service()`, and that is
	# what configures the shared pool.
	terrain.data.add_region_blank(Vector2i.ZERO)
	await settle()

	require(shared_pool(), "the shared pool is up before any setting changes")
	print("INSTANCER: shared pool is up, page size ", terrain.vt_page_size)

	# A demand-side count: which pages the far field protects, not what a page is.
	terrain.surface_svt_root_mips = 4
	require(shared_pool(), "a demand-side setting leaves the shared pool alone")
	print("INSTANCER: after surface_svt_root_mips the shared pool is ", shared_pool())

	# The other half of the distinction: a different page footprint cannot survive a reconfiguration.
	var resized: int = 16 if int(terrain.vt_page_size) != 16 else 32
	terrain.vt_page_size = resized
	require(not shared_pool(), "a page-footprint setting resets the shared pool")
	print("INSTANCER: after vt_page_size=", resized, " the shared pool is ", shared_pool())
	await settle()
	require(shared_pool(), "the pool comes back after a real reconfiguration")

	scene.queue_free()
	await process_frame
	if not failed:
		print("PASS a demand-side setting leaves the shared pool alone")
	quit(1 if failed else 0)
