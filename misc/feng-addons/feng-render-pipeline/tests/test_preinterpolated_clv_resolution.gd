extends SceneTree
## CPU coverage/layout/debug regression for configurable prepared CLV windows.
## Run headless. GPU integration is separately exercised on the native pass.

const Cache = preload("../passes/magic_gi_preinterpolated_volume_cache.gd")
const LegacyCache = preload("../passes/magic_gi_dynamic_volume_cache.gd")
const Clipmap = preload("../../feng-magic-gi/feng_magic_gi_volume_clipmap.gd")
const Chunk = preload("../../feng-magic-gi/feng_magic_gi_volume_source_chunk.gd")
const Broker = preload("../passes/magic_gi_clv_editor_snapshot.gd")
const MagicPass = preload("../passes/magic_gi_pass.gd")

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
	check(RenderingServer.get_rendering_device() == null, "CPU test has no GPU device")
	var pass_resource := MagicPass.new()
	check(pass_resource.prepared_clv_resolution == 16,
		"prepared default preserves the existing 16-cubed-per-level budget")
	var legacy := LegacyCache.new()
	check(legacy._clipmap_anchor_resolution() == 16, "legacy anchor remains fixed at 16")
	var source := Chunk.new()
	source.domain_bounds_world = AABB(Vector3(-4, -2, -4), Vector3(8, 4, 8))
	source.origin_world = source.domain_bounds_world.position + Vector3.ONE * 0.125
	source.directional_source_signature = "prepared-resolution-regression"
	check(source.allocate(Vector3i(32, 16, 32), PackedStringArray()), "source lattice allocated")
	source.validity.fill(1)
	var camera := Vector3(0, 0, 12)
	var directions := [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.UP]
	var previous_capacity := 0
	for resolution in [16, 24, 32]:
		pass_resource.prepared_clv_resolution = resolution
		check(pass_resource._effective_prepared_clv_resolution() == resolution,
			"pass preserves supported prepared resolution")
		var cache := Cache.new()
		cache.resolution = resolution
		check(cache._clipmap_anchor_resolution() == resolution,
			"finest-window fit uses actual resolution")
		var anchor: Dictionary = cache._clipmap_anchor_from_view(source, camera, Vector3.FORWARD)
		check(anchor.get("valid", false), "camera-position anchor is valid")
		var layout := Clipmap.build_prepared_layout(source, anchor.anchor_world, resolution)
		check(layout.get("valid", false) and layout.lods.size() == 4,
			"prepared layout admits four actual cascades")
		if not layout.get("valid", false):
			continue
		var cells_per_lod: int = resolution * resolution * resolution
		var capacity: int = cells_per_lod * 4
		check(capacity > previous_capacity, "increasing resolution expands resident capacity")
		previous_capacity = capacity
		var origins := PackedVector3Array()
		var spacings := PackedFloat32Array()
		var indices := PackedInt32Array()
		indices.resize(capacity)
		indices.fill(-1)
		for lod in 4:
			var entry: Dictionary = layout.lods[lod]
			var spacing := 0.25 * (1 << lod)
			check(entry.spacing_m == spacing, "source spacing is unchanged at each level")
			check(entry.clip_bounds_world.size == Vector3.ONE * resolution * spacing,
				"world coverage follows resolution times spacing")
			check(entry.dirty_cell_count == cells_per_lod,
				"first residency initializes the full chosen level")
			check(entry.cells_to_update.size() == cells_per_lod,
				"all logical cells are addressed without a 4096-cell cap")
			check(entry.cells_to_update[0] == 0 and entry.cells_to_update[-1] == cells_per_lod - 1,
				"dirty traversal reaches each level's last cell")
			origins.append(entry.origin_world)
			spacings.append(spacing)
			# Put a distinct source at the final cell of each level: a fixed 4096
			# decoder stride would mislabel these as another level or out-of-range.
			indices[(lod + 1) * cells_per_lod - 1] = lod + 100
		var snapshot := Broker.decode_snapshot(PackedByteArray(), {
			"dimensions": Vector3i(resolution, resolution, resolution * 4),
			"resident_indices": indices, "lod_origins": origins, "lod_spacings": spacings,
			"include_sh": false, "layout_key": "resolution-%d" % resolution})
		check(snapshot.get("current_available", false), "topology debug supports chosen resolution")
		check(snapshot.resident_capacity == capacity and snapshot.clipmap_resolution == resolution,
			"debug reports actual resident capacity")
		check(snapshot.lods == PackedInt32Array([0, 1, 2, 3]),
			"debug correctly separates four levels at the chosen cell stride")
		for lod in 4:
			check(snapshot.positions[lod] == origins[lod] + Vector3.ONE * (resolution - 1) * spacings[lod],
				"debug reaches actual last cell in each cascade")
			check(snapshot.clv_levels[lod].bounds.size == Vector3.ONE * (resolution - 1) * spacings[lod],
				"debug bounds describe real sample-center extent")
		for direction in directions:
			var turned: Dictionary = cache._clipmap_anchor_from_view(source, camera, direction)
			check(turned == anchor, "camera rotation does not cull or move residency")
			var unchanged := Clipmap.build_prepared_layout(source, turned.anchor_world,
				resolution, layout.state)
			check(unchanged.state == layout.state, "rotation preserves complete cascade state")
			for lod in unchanged.lods:
				check(lod.dirty_cell_count == 0, "rotation requires no entering cells")
		# Move to the next exact cell center, avoiding the intentional half-cell
		# hysteresis which keeps a tie on the previously selected side.
		var next_anchor: Vector3 = anchor.anchor_world
		next_anchor.x = source.origin_world.x + (layout.lods[0].center_source_index.x + 1) * 0.25
		var translated := Clipmap.build_prepared_layout(source, next_anchor, resolution, layout.state)
		check(translated.lods[0].dirty_cell_count == resolution * resolution,
			"one fine-cell translation enters exactly one full slab")
		check(not Clipmap.build_layout(source, anchor.anchor_world, resolution, 4).valid if resolution != 16
			else Clipmap.build_layout(source, anchor.anchor_world, 16, 4).valid,
			"legacy layout contract is unaffected")
	for invalid in [0, 15, 17, 23, 25, 31, 33, 64]:
		check(not Clipmap.build_prepared_layout(source, Vector3.ZERO, invalid).valid,
			"unsupported prepared window rejected")
	print("PREPARED_CLV_RESOLUTION checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
