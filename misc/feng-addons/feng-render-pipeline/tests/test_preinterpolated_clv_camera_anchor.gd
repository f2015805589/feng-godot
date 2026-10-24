extends SceneTree
## CPU regression: rotating a camera must not change a prepared CLV receiver's LOD.

const Cache = preload("../passes/magic_gi_preinterpolated_volume_cache.gd")
const PreviousCache = preload("../passes/magic_gi_dynamic_volume_cache.gd")
const Clipmap = preload("../../feng-magic-gi/feng_magic_gi_volume_clipmap.gd")
const Chunk = preload("../../feng-magic-gi/feng_magic_gi_volume_source_chunk.gd")

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func run() -> void:
	check(RenderingServer.get_rendering_device() == null,
		"camera-anchor regression uses no GPU device")
	var source := Chunk.new()
	source.domain_bounds_world = AABB(Vector3(-2.4, -0.4, -2.7), Vector3(4.8, 3.8, 5.4))
	source.origin_world = source.domain_bounds_world.position + Vector3.ONE * 0.125
	source.directional_source_signature = "camera-anchor-regression"
	check(source.allocate(Vector3i(20, 16, 22), PackedStringArray()),
		"white-box source header and arrays are available")
	var cache: RefCounted = Cache.new()
	var old_cache: RefCounted = PreviousCache.new()
	var front_camera := Vector3(0.0, 1.58, 6.7)
	var cameras: Array[Vector3] = [front_camera, Vector3(0.6, 1.2, 0.8),
		Vector3(-5.0, 2.0, 0.5), source.domain_bounds_world.get_center()]
	var directions: Array[Vector3] = [Vector3.FORWARD,
		Vector3(0.17364818, 0.0, -0.98480775),
		Vector3(-0.17364818, 0.0, -0.98480775),
		Vector3(0.0, 0.5, -0.8660254), Vector3.BACK, Vector3.UP,
		Vector3.ZERO, Vector3(NAN, 0.0, 0.0)]
	for camera in cameras:
		var baseline: Dictionary = cache._clipmap_anchor_from_view(source, camera, Vector3.FORWARD)
		check(bool(baseline.get("valid", false)), "position anchor is valid: %s" % camera)
		if not bool(baseline.get("valid", false)):
			continue
		var baseline_layout := Clipmap.build_layout(source, baseline.anchor_world, 16, 4)
		check(bool(baseline_layout.get("valid", false)), "four-level source layout is valid")
		if not bool(baseline_layout.get("valid", false)):
			continue
		for direction in directions:
			var anchor: Dictionary = cache._clipmap_anchor_from_view(source, camera, direction)
			check(anchor == baseline, "orientation cannot move the anchor: %s / %s" % [camera, direction])
			var layout := Clipmap.build_layout(source, anchor.anchor_world, 16, 4, baseline_layout.state)
			check(layout.get("state") == baseline_layout.state,
				"orientation cannot change any cascade origin or resident layout")
			var dirty_cells := 0
			for lod: Dictionary in layout.get("lods", []):
				dirty_cells += int(lod.dirty_cell_count)
			check(dirty_cells == 0, "pure rotation schedules no entering cells or relight")
		check(baseline_layout.lods[0].spacing_m == 0.25
			and baseline_layout.lods.size() == 4 and baseline_layout.resolution == 16,
			"stable anchor keeps the .25m source and four 16-cubed resident levels")

	var front: Dictionary = cache._clipmap_anchor_from_view(source, front_camera, Vector3.FORWARD)
	var previous_front: Dictionary = old_cache._clipmap_anchor_from_view(source, front_camera, Vector3.FORWARD)
	var front_layout := Clipmap.build_layout(source, front.anchor_world, 16, 4)
	var previous_front_layout := Clipmap.build_layout(source, previous_front.anchor_world, 16, 4)
	check(front_layout.lods[0].logical_origin_source_index
		== previous_front_layout.lods[0].logical_origin_source_index,
		"the existing white-box front view keeps its finest resident window")
	var rear_receiver := Vector3(0.0, 1.58, -2.4)
	var fine_grid: Vector3 = (rear_receiver - front_layout.lods[0].origin_world) / 0.25
	check(fine_grid.x >= 0 and fine_grid.y >= 0 and fine_grid.z >= 0
		and fine_grid.x <= 15 and fine_grid.y <= 15 and fine_grid.z <= 15,
		"an outside camera still keeps the rear-wall center in the finest volume")
	var moved: Dictionary = cache._clipmap_anchor_from_view(source, front_camera + Vector3(2.0, 0.0, 0.0), Vector3.FORWARD)
	var moved_layout := Clipmap.build_layout(source, moved.anchor_world, 16, 4, front_layout.state)
	check(moved.anchor_world != front.anchor_world and moved_layout.state != front_layout.state,
		"translating the camera still scrolls the resident cascades")
	var old_turned: Dictionary = old_cache._clipmap_anchor_from_view(source, front_camera, directions[2])
	var old_turned_layout := Clipmap.build_layout(source, old_turned.anchor_world, 16, 4, previous_front_layout.state)
	check(old_turned_layout.state != previous_front_layout.state,
		"the fixture reproduces the original orientation-dependent layout change")

	check(not cache._clipmap_anchor_from_view(null, front_camera, Vector3.FORWARD).valid,
		"a missing source is rejected")
	check(not cache._clipmap_anchor_from_view(Resource.new(), front_camera, Vector3.FORWARD).valid,
		"a source without volume bounds is rejected")
	for invalid_camera in [Vector3(NAN, 0.0, 0.0), Vector3(INF, 0.0, 0.0)]:
		check(not cache._clipmap_anchor_from_view(source, invalid_camera, Vector3.FORWARD).valid,
			"a non-finite camera position is rejected")
	var saved_bounds: AABB = source.domain_bounds_world
	for bounds in [AABB(), AABB(Vector3(NAN, 0.0, 0.0), Vector3.ONE),
		AABB(Vector3.ZERO, Vector3(-1.0, 1.0, 1.0))]:
		source.domain_bounds_world = bounds
		check(not cache._clipmap_anchor_from_view(source, front_camera, Vector3.FORWARD).valid,
			"an invalid source domain is rejected")
	source.domain_bounds_world = saved_bounds
	for spacing in [0.0, -0.25, NAN]:
		source.spacing_m = spacing
		check(not cache._clipmap_anchor_from_view(source, front_camera, Vector3.FORWARD).valid,
			"an invalid source spacing is rejected")
	print("Prepared CLV camera anchor: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
