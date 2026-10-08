extends "res://vt_scene_base.gd"

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	terrain = Terrain3D.new()
	terrain.vt_delivery_near_material = 0
	terrain.vt_delivery_far_material = 0
	terrain.vt_debug_direct_material = true
	terrain.surface_svt_page_size = 16
	terrain.surface_svt_page_border = 1
	terrain.surface_svt_page_count = 8
	terrain.surface_svt_page_world = 0.03125
	root.add_child(terrain)
	terrain.collision_mode = 0
	terrain.region_size = 1024
	terrain.surface_svt_enabled = true
	terrain.set_physics_process(false)
	var vt := terrain.get_surface_svt()
	require(vt != null and vt.is_initialized(), "diagnostic SVT must initialize")
	# No PageRecord exists for these public requests. Fine and coarse margins
	# must still clear, while pages outside the one-page border stay resident.
	var requests := [Vector3i(0, 0, 0), Vector3i(-1, 0, 0), Vector3i(-2, 0, 0),
		Vector3i(-4, 0, 2), Vector3i(-8, 0, 2)]
	var slots: Array[int] = []
	for request in requests:
		var slot := vt.request_world_page(request.x, request.y, request.z)
		require(slot >= 0, "invalidation fixture slot allocation failed")
		slots.append(slot)
	var start := Time.get_ticks_usec()
	terrain.invalidate_surface_pages(Vector2i.ZERO)
	var elapsed := Time.get_ticks_usec() - start
	print("INVALIDATION_USEC ", elapsed)
	require(elapsed < 1000000, "region edit work grew with the virtual grid")
	for index in requests.size():
		var should_keep := index == 2 or index == 4
		require(vt.is_page_used(slots[index]) == should_keep, "wrong fine/coarse border invalidation at " + str(requests[index]))
	terrain.free()
	if not failed:
		print("PASS resident-bounded VT invalidation in ", elapsed, " usec")
	quit(1 if failed else 0)
