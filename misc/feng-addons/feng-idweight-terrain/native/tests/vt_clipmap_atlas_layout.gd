# Public native layout regression: rectangles must represent disjoint physical storage.
# The general atlas test checks counts/area but previously did not check intersections.
extends "res://vt_scene_base.gd"

const HEIGHT := 1
const BLOCK_SIZE := 64

func _initialize() -> void:
	call_deferred("run")

func check_layout(rings: int, global_size: int) -> void:
	terrain.vt_clipmap_levels = rings
	terrain.vt_clipmap_global_texels = global_size
	require(terrain.debug_update_vt_clipmap(HEIGHT) >= 0, "native atlas builds")
	var group: Dictionary = terrain.get_vt_settings().get("clipmap", {}).get("height", {})
	var layout: Dictionary = group.get("layout", {}).get("layout", {})
	var rects: Array = layout.get("rects", [])
	var bounds := Rect2(0, 0, int(layout.get("width", 0)), int(layout.get("height", 0)))
	require(str(layout.get("chosen", "")) == "quadtree", "native layout selected quadtree")
	require(rects.size() == rings * 10 + 1, "one rect per block, spare and global slot")
	var area := 0.0
	var globals := 0
	var spares := 0
	var ring_blocks: Array[int] = []
	ring_blocks.resize(rings)
	ring_blocks.fill(0)
	for i in rects.size():
		var item: Dictionary = rects[i]
		var rect: Rect2 = item.get("rect", Rect2())
		require(rect.size.x > 0 and rect.size.y > 0 and bounds.encloses(rect),
				"every native packed rect has positive size and lies inside the atlas")
		area += rect.get_area()
		if bool(item.get("global", false)):
			globals += 1
			require(rect.size == Vector2(global_size, global_size), "global rect retains its own dimensions")
		else:
			require(rect.size == Vector2(BLOCK_SIZE, BLOCK_SIZE), "ring/spare rect retains its own dimensions")
			if bool(item.get("spare", false)):
				spares += 1
			else:
				ring_blocks[int(item.get("ring", -1))] += 1
		for j in i:
			var earlier: Rect2 = (rects[j] as Dictionary).get("rect", Rect2())
			require(not rect.intersects(earlier),
					"native layout overlap rings=%d global=%d slots=%d/%d rects=%s/%s" %
					[rings, global_size, i, j, str(rect), str(earlier)])
	require(globals == 1 and spares == rings, "native layout retains global and spare identities")
	for count in ring_blocks:
		require(count == 9, "every ring retains all nine block rectangles")
	require(area == float(rings * 10 * BLOCK_SIZE * BLOCK_SIZE + global_size * global_size),
			"rectangles cover exactly the requested block, spare and global texels")
	require(area == float(layout.get("packed_texels", 0)), "reported packed area matches actual rectangles")
	print("VT_ATLAS_LAYOUT rings=%d global=%d rects=%d bounds=%s area=%d" %
			[rings, global_size, rects.size(), str(bounds.size), int(area)])

func run() -> void:
	camera = Camera3D.new()
	camera.position = Vector3(0, 20, 20)
	camera.current = true
	root.add_child(camera)
	terrain = Terrain3D.new()
	terrain.region_size = 64
	terrain.vt_delivery_near_material = 0
	terrain.vt_delivery_far_material = 0
	terrain.vt_delivery_near_height = 0
	terrain.vt_delivery_far_height = 0
	terrain.vt_clipmap_size = BLOCK_SIZE
	terrain.vt_clipmap_base_world = 64.0
	terrain.vt_clipmap_blocks_per_frame = 1
	terrain.vt_clipmap_implementation = 1
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	root.add_child(terrain)
	terrain.set_process(false)
	terrain.set_physics_process(false)
	terrain.data.add_region_blank(Vector2i.ZERO, false)
	terrain.data.update_maps()
	await process_frame
	for rings in [1, 2, 3, 4, 8, 11]:
		for global_size in [1, 16, 64]:
			check_layout(rings, global_size)
	terrain.set_editor(null)
	terrain.queue_free()
	camera.queue_free()
	await process_frame
	if failed:
		print("REGRESSION: clipmap atlas layout")
		quit(1)
		return
	print("PASS clipmap atlas layout")
	quit(0)
