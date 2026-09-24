# Run with a graphical rendering driver; see README.md in this directory.
#
# The clipmap ring: the toroidal addressing, the strips a moving focus costs, the production budget,
# and the content.
#
# The requirement this test exists for is that the ring is a *mechanism*: it carries whatever channel
# its source produces, it writes nothing while the focus stands still, and a strip it streams must
# hold exactly what a full regeneration would. Those are four separate claims and each has its own
# reading here, all deterministic and all driven by one manual tick:
#
#   * **Shape.** The ring's level count, texel size and snapped centre are read out of the level
#     reports, so "level l covers `base_world * 2^l` metres in `size` texels" is a measurement.
#   * **Cost.** Production is charged per texel and counted, and the byte count of the layer uploads
#     is counted beside it. A one-texel move at level 0 is therefore *named* as `size` texels of CPU
#     production and one whole layer of transfer - the CPU side is incremental and the transfer is
#     not, and both numbers are published rather than assumed.
#   * **Content.** Every texel of the ring is read back through the ring's own addressing
#     (`sample_vt_clipmap`) and compared against the height map texel under the same world position
#     (`Terrain3DData.get_pixel`), at every texel centre of the level. That is a different code path
#     for the data and the same world positions, so it fails on a wrong ring, a wrong snap and a
#     wrong wrap - which is what the ring's addressing is.
#   * **Independence from a delivery claim.** Every cell is `Direct` in this suite: the ring is built
#     and driven by the mechanism's own entry (`Terrain3D::debug_update_vt_clipmap()`), which runs the
#     same `update()`, focus and budget the tick's phase runs whenever a cell names the method. That
#     keeps the readings the mechanism's rather than a render's - no AVT view, no SVT view, no page
#     pool and no shader arm take part in anything below - and it is what lets `vt_clipmap_render`
#     drive the arm side separately.
#
# Block 5b covers the other way content becomes wrong: an edit under the ring. The rect the changed
# area covers is re-produced rather than the ring, and the level stops being current until it has -
# which is what a reader of the ring falls back on. Block 6 covers the VT Page view's payload and the
# gate in front of it: the world square of every level, the rects still queued as the work that is
# left (their areas add up to the texels the budget has not produced), and the two counters that show
# a preview with no ring behind it is refused rather than answered with an empty drawing.
#
# Read `docs/vt_delivery_assembly.md` section 6 for the design; the group index is Material=0/Height=1
# and the delivery values are Direct=0/AVT=1/Clipmap=2/SVT=3, i.e. the native `TerrainVT` enum
# values, which are also the property values.
extends "res://vt_scene_base.gd"

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const AVT := 1
const CLIPMAP := 2

# A one-level ring of 16 texels an axis covering 16 m, i.e. exactly one texel a metre at the default
# vertex spacing. Small enough that a whole level is 256 texels and a test can afford to refill it,
# and exact in binary so a texel centre is a half metre and every arithmetic claim below is exact.
const SIZE := 16
const LEVELS := 1
const BASE_WORLD := 16.0
const TEXELS := SIZE * SIZE
const LAYER_BYTES := TEXELS * 4

var target: Node3D


func _initialize() -> void:
	call_deferred("run")


# ---- readings -----------------------------------------------------------------------------------

func settings() -> Dictionary:
	return terrain.get_vt_settings()


func ring() -> Dictionary:
	return settings().get("clipmap", {}).get("height", {})


# What only the selected implementation can say, nested under the layer's shared entry. The LOD
# implementation carries the per-level reports and the fill/bake/invalidation counters; the
# implementation selector is a setting of the one layer, so the shared keys above `layout` are the
# same either way.
func layout() -> Dictionary:
	return ring().get("layout", {})


func level_report() -> Dictionary:
	var reports: Array = layout().get("level_reports", [])
	return reports[0] if not reports.is_empty() else {}


# The toroidal offset of the finest level, which is the ring's own state: `physical = (logical + ring)
# mod size`, so this is the number every strip rect is derived from.
func level_ring() -> Vector2i:
	return level_report().get("ring", Vector2i.ZERO)


func produced() -> int:
	return int(ring().get("produced_texels", 0))


func uploads() -> int:
	return int(ring().get("upload_bytes", 0))


func fulls() -> int:
	return int(layout().get("full_level_productions", 0))


func pending() -> int:
	return int(ring().get("pending_jobs", 0))


func valid_levels() -> int:
	var count := 0
	for report: Dictionary in (ring().get("unit_reports", []) as Array):
		if bool(report.get("valid", false)):
			count += 1
	return count


func idle() -> int:
	return int(ring().get("idle_updates", 0))


func invalidations() -> int:
	return int(layout().get("invalidation_calls", -1))


func invalidated_texels() -> int:
	return int(layout().get("invalidated_texels", -1))


func updates() -> int:
	return int(ring().get("update_calls", 0))


# One line per step, so a counter that does not move as predicted can be read as "the tick ran once
# and produced something else" or as "the tick ran four times".
func diag(label: String) -> void:
	print("VT_CLIPMAP_DIAG %s updates=%d produced=%d idle=%d full=%d pending=%d upload=%d valid=%d physics=%s center=%s ring=%s" % [
		label, updates(), produced(), idle(), fulls(), pending(), uploads(), valid_levels(),
		str(terrain.is_physics_processing()), str(level_report().get("center", "?")), str(level_ring())])


# The height map texel under a world XZ, read through the data layer rather than through the ring:
# the independent side of every content assertion below.
func reference(world: Vector2) -> float:
	return terrain.data.get_pixel(Terrain3DRegion.TYPE_HEIGHT, Vector3(world.x, 0.0, world.y)).r


func sample(world: Vector2) -> float:
	return terrain.sample_vt_clipmap(HEIGHT, world)


func preview_layer(preview: Dictionary, group_name: String) -> Dictionary:
	for entry: Dictionary in preview.get("layers", []):
		if str(entry.get("group", "")) == group_name:
			return entry
	return {}


func run_clipmap_shape_serialization_block() -> void:
	# The exported native properties are the storage contract for old scene files as well as the new
	# group-specific overrides, so exercise a real PackedScene roundtrip rather than only method calls.
	var serialized := Terrain3D.new()
	serialized.vt_clipmap_size = 32
	serialized.vt_clipmap_levels = 5
	serialized.vt_clipmap_base_world = 8.0
	serialized.vt_clipmap_height_size = 64
	var packed := PackedScene.new()
	var pack_error := packed.pack(serialized)
	require(pack_error == OK, "a Terrain3D with legacy and per-group clipmap values packs into a scene")
	if pack_error != OK:
		serialized.free()
		return
	const path := "user://vt_clipmap_group_shape_roundtrip.tscn"
	var save_error := ResourceSaver.save(packed, path)
	require(save_error == OK, "clipmap shape properties serialize to a PackedScene")
	if save_error != OK:
		serialized.free()
		return
	var loaded_scene := ResourceLoader.load(path) as PackedScene
	require(loaded_scene != null, "the serialized clipmap scene can be loaded")
	if loaded_scene == null:
		serialized.free()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	var loaded_node := loaded_scene.instantiate()
	var loaded := loaded_node as Terrain3D
	require(loaded != null, "the loaded scene retains its Terrain3D root")
	if loaded != null:
		require(loaded.vt_clipmap_size == 32 and loaded.vt_clipmap_levels == 5 and
				is_equal_approx(loaded.vt_clipmap_base_world, 8.0),
				"legacy global clipmap values survive scene serialization")
		require(loaded.vt_clipmap_height_size == 64 and
				int(loaded.get_vt_clipmap_group_shape(HEIGHT).get("size", 0)) == 64 and
				int(loaded.get_vt_clipmap_group_shape(HEIGHT).get("levels", 0)) == 5,
				"a per-group override survives serialization and composes with inherited fields")
		loaded.free()
	serialized.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# The worst difference between the ring and the height map, over *every* texel centre of the finest
# level: the ring's own addressing decides where each stored value is read from, so a wrap, a snap or
# a strip rect that is off by anything shows up here.
func content_error() -> float:
	var report := level_report()
	var center: Vector2 = report.get("center", Vector2.ZERO)
	var half := float(report.get("world_size", 0.0)) * 0.5
	var texel := float(report.get("texel_world", 1.0))
	var worst := 0.0
	for y in SIZE:
		for x in SIZE:
			var world := center - Vector2(half, half) + Vector2((x + 0.5) * texel, (y + 0.5) * texel)
			worst = maxf(worst, absf(sample(world) - reference(world)))
	return worst


func describe() -> String:
	var report := level_report()
	return "configured=%s selected=%s source=%s size=%d levels=%d valid=%d pending=%d|produced=%d full=%d upload=%d layers=%d|center=%s ring=%s texel_world=%.3f world_size=%.1f" % [
		str(ring().get("configured", false)), str(ring().get("selected", false)), str(ring().get("source", "?")),
		int(ring().get("size", 0)), int(ring().get("units", 0)), valid_levels(), pending(),
		produced(), fulls(), uploads(), int(ring().get("texture_layers", 0)),
		str(report.get("center", "?")), str(report.get("ring", "?")),
		float(report.get("texel_world", 0.0)), float(report.get("world_size", 0.0))]


# ---- driving ------------------------------------------------------------------------------------

# The mechanism's own entry, which is how this suite drives the ring: no cell may name `Clipmap` in
# this build, so the tick enters no clipmap phase and the ring is built and stepped by
# `debug_update_vt_clipmap()` instead. It runs the same `ring->update(focus, budget)` that phase runs,
# with the same focus (`get_clipmap_target_position()`) and the same `vt_clipmap_budget_texels`, and
# publishes the same `clipmap_produced_texels` / `vt_clipmap_ms` - so the counters below are the
# mechanism's own, taken without a delivery claim nothing can render. One frame first, so a target
# that just moved is read at its new position, exactly as the tick's phase would read it.
func tick() -> void:
	await process_frame
	terrain.call("debug_update_vt_clipmap", HEIGHT)


func ticks(count: int) -> void:
	for _i in count:
		await tick()


func settle(frames: int) -> void:
	for _i in frames:
		await process_frame


func ticks_until_drained(limit: int = 128) -> int:
	var spent := 0
	while pending() > 0 and spent < limit:
		await tick()
		spent += 1
	return spent


func move_to(world_x: float, world_z: float) -> void:
	target.position = Vector3(world_x, 0.0, world_z)


# ---- scenarios ----------------------------------------------------------------------------------

# A configuration that never selects the method owns no ring: no levels, no texture, no jobs and no
# budget, which is the assembly rule measured on the mechanism itself rather than on a log line. The
# write that *is* refused here is a height cell naming `AVT` - the height channel's choices are the
# array and the ring, so that refusal is a channel rule - and the registry below answers for the two
# channels the ring *can* carry, which is what the matrix's acceptance is read from.
func run_never_selected_block() -> void:
	var plain := Terrain3D.new()
	plain.surface_svt_auto_bake = false
	plain.vt_delivery_near_material = DIRECT
	plain.vt_delivery_near_height = DIRECT
	plain.vt_delivery_far_material = DIRECT
	plain.vt_delivery_far_height = DIRECT
	plain.vt_clipmap_size = SIZE
	plain.vt_clipmap_levels = LEVELS
	plain.vt_clipmap_base_world = BASE_WORLD
	# A target before the node enters the tree: `__physics_process()` resolves one on entering, and a
	# terrain without a target logs an error that this test does not want to be reading past.
	plain.set_camera(camera)
	plain.set_clipmap_target(camera)
	var holder := Node3D.new()
	holder.add_child(plain)
	root.add_child(holder)
	# A group with no ring has nothing to tick, and this terrain owns no service, so the engine never
	# enters its VT section either: what the readings below assert is the absence itself - no ring
	# object, no levels, and a production counter that stays at zero because there is nothing to drive.
	plain.data.add_region_blank(Vector2i.ZERO)
	await settle(4)
	# The refused write, on a live terrain: the height channel has no `AVT` arm, so the cell keeps its
	# method and no ring is created by it.
	plain.vt_delivery_near_height = AVT
	await settle(2)
	var s := plain.get_vt_settings()
	var entry: Dictionary = s.get("clipmap", {}).get("height", {})
	var material_entry: Dictionary = s.get("clipmap", {}).get("material", {})
	require(plain.vt_delivery_near_height == DIRECT, "the height group refuses the AVT cell: that channel has no paged arm")
	require(not plain.is_vt_delivery_supported(HEIGHT, AVT), "and says so through the published capability")
	# The acceptance is the *registry's* answer rather than a table, which is what makes a channel a
	# source and a case: each group the ring can carry is deliverable for `Clipmap`, and one it cannot
	# is refused, in the same call the setter uses.
	require(plain.has_clipmap_source(HEIGHT) and plain.has_clipmap_source(MATERIAL),
			"the source factory answers which channels the ring can carry, and the matrix accepts exactly those")
	var refused: Dictionary = s.get("delivery_unsupported", {}).get("height", {})
	require(str(refused.get("AVT", "")).contains("clipmap layer"),
			"and the refusal names what that channel's choices are: %s" % str(refused.get("AVT", "")))
	require(not bool(entry.get("configured", true)) and not bool(material_entry.get("configured", true)),
			"so a terrain whose only Clipmap writes were refused owns no ring")
	require(entry.get("units", -1) == -1, "and therefore no levels, no texture and no jobs")
	require(not bool(s.get("clipmap_service", true)), "and reports no clipmap service")
	require(not bool(s.get("clipmap_layer", true)), "and no layer object")
	require(int(s.get("clipmap_produced_texels", -1)) == 0, "and produces nothing while it ticks")
	require(plain.sample_vt_clipmap(HEIGHT, Vector2(4.0, 4.0)) != plain.sample_vt_clipmap(HEIGHT, Vector2(4.0, 4.0)),
			"and answers a sample with NAN rather than with a value")
	require(not plain.is_vt_delivery_used(CLIPMAP), "and does not report Clipmap as used")
	require(plain.get_clipmap_layout_preview().is_empty(), "and has no layout to draw: the preview refuses it")
	var legacy_material: Dictionary = plain.get_vt_clipmap_group_shape(MATERIAL)
	var legacy_height: Dictionary = plain.get_vt_clipmap_group_shape(HEIGHT)
	require(int(legacy_material.get("size", 0)) == SIZE and int(legacy_material.get("levels", 0)) == LEVELS and
			is_equal_approx(float(legacy_material.get("base_world", 0.0)), BASE_WORLD) and
			int(legacy_height.get("size", 0)) == SIZE and int(legacy_height.get("levels", 0)) == LEVELS and
			is_equal_approx(float(legacy_height.get("base_world", 0.0)), BASE_WORLD),
			"a customized legacy tuple remains the fallback shape for both groups")
	require(plain.debug_update_vt_clipmap(HEIGHT) >= 0 and plain.debug_update_vt_clipmap(MATERIAL) >= 0,
			"and the mechanism's own entry builds either channel's ring, with no cell claiming the method")
	# A positive field overrides only that group; zero clears it back to the customized legacy tuple.
	plain.vt_clipmap_material_size = 32
	var material_override: Dictionary = plain.get_vt_clipmap_group_shape(MATERIAL)
	var unaffected_height: Dictionary = plain.get_vt_clipmap_group_shape(HEIGHT)
	require(int(material_override.get("size", 0)) == 32 and
			int(unaffected_height.get("size", 0)) == SIZE and plain.is_vt_clipmap_group_shape_overridden(MATERIAL),
			"the Material shape override is isolated from Height")
	plain.reset_vt_clipmap_group_shape(MATERIAL)
	require(int(plain.get_vt_clipmap_group_shape(MATERIAL).get("size", 0)) == SIZE and
			not plain.is_vt_clipmap_group_shape_overridden(MATERIAL),
			"reset clears group fields back to the legacy fallback")
	# With the old tuple at its unchanged defaults, both actual layers use the new per-group defaults.
	plain.vt_clipmap_size = 256
	plain.vt_clipmap_levels = 11
	plain.vt_clipmap_base_world = 0.25
	plain.vt_clipmap_budget_texels = 1
	plain.debug_update_vt_clipmap(HEIGHT)
	plain.debug_update_vt_clipmap(MATERIAL)
	var shape_preview := plain.get_clipmap_layout_preview()
	var material_layer := preview_layer(shape_preview, "material")
	var height_layer := preview_layer(shape_preview, "height")
	require(not material_layer.is_empty() and not height_layer.is_empty(),
			"the shared preview exposes the actual Material and Height layers")
	if not material_layer.is_empty() and not height_layer.is_empty():
		var material_densities: PackedFloat32Array = material_layer.get("unit_density", PackedFloat32Array())
		var height_densities: PackedFloat32Array = height_layer.get("unit_density", PackedFloat32Array())
		require(material_densities.size() == 11 and is_equal_approx(material_densities[0], 1024.0) and
				is_equal_approx(material_densities[10], 1.0),
			"the default Material clipmap keeps its full 1024 -> 1 density ladder")
		require(height_densities.size() == 7 and is_equal_approx(height_densities[0], 64.0) and
				is_equal_approx(height_densities[6], 1.0),
			"the default Height clipmap uses lower fine density and still reaches 1 texel/metre")
		require(is_equal_approx(plain.sample_vt_clipmap_density(MATERIAL, Vector2(8.5, 8.5)), 1024.0) and
				is_equal_approx(plain.sample_vt_clipmap_density(HEIGHT, Vector2(8.5, 8.5)), 64.0),
			"the density sampler probes both groups at the same focus with their own ladders")
	# A group-specific material shape can still choose 1024 -> 1 without changing Height's ladder.
	plain.vt_clipmap_material_size = 128
	plain.vt_clipmap_material_base_world = 0.125
	plain.debug_update_vt_clipmap(MATERIAL)
	var overridden_material: Dictionary = plain.get_vt_clipmap_group_shape(MATERIAL)
	require(int(overridden_material.get("size", 0)) == 128 and
			is_equal_approx(float(overridden_material.get("finest_density", 0.0)), 1024.0) and
			is_equal_approx(float(plain.get_vt_clipmap_group_shape(HEIGHT).get("finest_density", 0.0)), 64.0),
			"the material override preserves its density endpoints and leaves Height unchanged")
	plain.reset_vt_clipmap_group_shape(MATERIAL)
	plain.debug_update_vt_clipmap(MATERIAL)
	require(int(plain.get_vt_clipmap_group_shape(MATERIAL).get("size", 0)) == 256,
			"reset restores the Material default after an actual layer reconfiguration")
	run_clipmap_shape_serialization_block()
	print("VT_CLIPMAP_NEVER_SELECTED configured=%s levels=%s service=%s produced=%d" % [
		str(entry.get("configured", "?")), str(entry.get("units", "none")),
		str(s.get("clipmap_service", "?")), int(s.get("clipmap_produced_texels", -1))])
	holder.queue_free()
	await process_frame


func setup() -> void:
	# The camera comes from `run()`: both terrains need a demand target before they enter the tree,
	# and a terrain that reaches its first tick without one logs an error this test would otherwise
	# be reading past.
	target = Node3D.new()
	target.position = Vector3(8.5, 0.0, 8.5)
	root.add_child(target)

	terrain = Terrain3D.new()
	terrain.surface_svt_auto_bake = false
	# Every cell direct: no cell may name Clipmap in this build, so nothing selects a service and no
	# AVT view, SVT view, page pool or shader arm takes part in anything below. The ring is built by
	# the mechanism's entry, which is what `tick()` calls.
	terrain.vt_delivery_near_material = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_clipmap_size = SIZE
	terrain.vt_clipmap_levels = LEVELS
	terrain.vt_clipmap_base_world = BASE_WORLD
	terrain.vt_clipmap_budget_texels = TEXELS
	# The target and the camera are set before the node enters the tree, so the tick that follows has
	# a focus and no window of its own to spend resolving one.
	terrain.set_camera(camera)
	terrain.set_clipmap_target(target)
	root.add_child(terrain)
	terrain.data.add_region_blank(Vector2i.ZERO)
	# A ramp with an exact value at every vertex: one metre of error in the addressing reads a
	# different vertex, and the ramp makes that a different number rather than the same one.
	for z in 65:
		for x in 65:
			terrain.data.set_height(Vector3(x, 0.0, z), x * 0.25 + z * 0.5)
	await process_frame
	# After every setting, so the assembly rule's own `set_physics_process(true)` cannot undo it.
	terrain.set_physics_process(false)


func run() -> void:
	# The camera first: both terrains below are handed it before they enter the tree, so neither
	# spends a tick resolving a target it does not have.
	camera = Camera3D.new()
	camera.position = Vector3(8.5, 60.0, 8.5)
	camera.current = true
	root.add_child(camera)
	camera.look_at(Vector3(8.5, 0.0, 8.5))

	await run_never_selected_block()
	await setup()
	diag("setup")

	# 1. The first tick fills the level whole: 256 texels of CPU production and one whole layer of
	#    transfer, which is the ring's cost model in the two numbers it publishes.
	await tick()
	diag("first_fill")
	require(bool(ring().get("configured", false)), "the mechanism's entry builds the ring")
	require(not bool(ring().get("selected", false)), "while no delivery cell claims the method, which this build refuses")
	require(str(ring().get("source", "")) == "height", "the ring names the channel it carries")
	require(int(ring().get("size", 0)) == SIZE, "the ring takes the configured size")
	require(int(ring().get("units", 0)) == LEVELS, "the ring takes the configured level count")
	require(int(ring().get("texture_layers", 0)) == LEVELS, "one layer a level, one channel a texel")
	require(pending() == 0, "a budget of one whole level drains it in one tick")
	require(valid_levels() == 1, "the drained level is valid")
	require(produced() == TEXELS, "the first tick produces the whole level, %d texels" % TEXELS)
	require(fulls() == 1, "and it was a full production, not a strip")
	require(uploads() == LAYER_BYTES, "and it uploads one whole layer, %d bytes" % LAYER_BYTES)
	var report := level_report()
	require(absf(float(report.get("world_size", 0.0)) - BASE_WORLD) < 0.001, "level 0 covers base_world metres")
	require(absf(float(report.get("texel_world", 0.0)) - 1.0) < 0.001, "and its texel is one metre wide")
	require(report.get("center", Vector2.ZERO) == Vector2(8.0, 8.0), "the centre is snapped to the texel size")
	require(report.get("ring", Vector2i.ZERO) == Vector2i.ZERO, "and no wrap has happened yet")
	require(content_error() < 0.0001, "every texel of the ring holds the height map texel under it")
	print("VT_CLIPMAP_FIRST_FILL ", describe())

	# 2. A stationary focus writes nothing. This is the whole reason the ring stores rather than
	#    re-produces, and it is asserted as zero production, not as a small number.
	var before_produced := produced()
	var before_uploads := uploads()
	var before_idle := idle()
	await ticks(3)
	require(produced() == before_produced, "a stationary focus produces no texels")
	require(uploads() == before_uploads, "and uploads no layer")
	require(idle() == before_idle + 3, "and each tick is counted as idle")
	require(pending() == 0, "with nothing left pending")
	print("VT_CLIPMAP_IDLE produced=%d idle=%d pending=%d" % [produced(), idle(), pending()])
	diag("stationary")

	# 3. One texel of movement is one strip: a level that moved one texel lost one column and gained
	#    one, so the CPU side produces `size` texels and the transfer is one whole layer regardless -
	#    the second half of the cost model, and the reason it is published.
	before_produced = produced()
	var before_fulls := fulls()
	var before_uploads_move := uploads()
	move_to(9.5, 8.5)
	await tick()
	diag("move_x_plus")
	require(produced() - before_produced == SIZE, "a one-texel move produces one column of %d texels" % SIZE)
	require(fulls() == before_fulls, "and is a strip, not a full production")
	require(level_ring() == Vector2i(1, 0), "the ring turned by one texel")
	require(uploads() - before_uploads_move == LAYER_BYTES, "while the transfer is still one whole layer")
	require(content_error() < 0.0001, "and the wrapped content is still the height map under it")

	before_produced = produced()
	before_uploads_move = uploads()
	move_to(8.5, 8.5)
	await tick()
	diag("move_x_minus")
	require(produced() - before_produced == SIZE, "moving back is one column as well")
	require(level_ring() == Vector2i(0, 0), "and the ring comes back with it")
	require(content_error() < 0.0001, "both wraps hold the height map under them")

	# A diagonal move pays both bands, and the corner texel is written twice: the second band is full
	# width on purpose, because the alternative is a third rect for a texel the first band already
	# gave the same value.
	before_produced = produced()
	before_uploads_move = uploads()
	move_to(9.5, 9.5)
	await tick()
	diag("move_diagonal")
	require(produced() - before_produced == 2 * SIZE, "a diagonal one-texel move produces both bands")
	require(level_ring() == Vector2i(1, 1), "and both axes of the ring turn")
	require(uploads() - before_uploads_move == LAYER_BYTES, "as one whole-layer transfer, not two")
	require(content_error() < 0.0001, "with the corner still correct after the overlap")
	print("VT_CLIPMAP_STRIP produced=%d full=%d upload=%d ring=%s error=%.6f" % [
		produced(), fulls(), uploads(), str(level_ring()), content_error()])

	# 4. The budget: a focus that left the level's own coverage is rebuilt whole, and a ring that may
	#    only produce four texels a tick spends exactly four and keeps the job. The resume point is
	#    what makes the level's content the same either way, so it is asserted rather than implied.
	move_to(30.5, 9.5)
	terrain.vt_clipmap_budget_texels = 4
	before_produced = produced()
	before_uploads = uploads()
	before_fulls = fulls()
	await tick()
	diag("budget_first")
	require(produced() - before_produced == 4, "a four-texel budget produces exactly four texels")
	require(pending() == 1, "and leaves the job queued")
	require(valid_levels() == 0, "so the level is not valid yet")
	require(fulls() == before_fulls + 1, "a move past the coverage is a full production")
	require(uploads() == before_uploads, "and an invalid level is not uploaded")
	var spent := await ticks_until_drained()
	require(pending() == 0, "the queued job drains")
	require(produced() - before_produced == TEXELS, "to exactly one whole level, %d texels" % TEXELS)
	require(valid_levels() == 1, "which then becomes valid")
	require(uploads() - before_uploads == LAYER_BYTES, "and is uploaded once, not once a tick")
	require(content_error() < 0.0001, "and the resumed production holds the height map under it")
	print("VT_CLIPMAP_BUDGET budget=4 first=4 total=%d ticks=%d upload=%d error=%.6f" % [
		produced() - before_produced, spent, uploads() - before_uploads, content_error()])

	# 5. Incremental content equals a full regeneration. Eight one-texel moves build the level out of
	#    strips, and the samples are then compared against the same level rebuilt whole at the same
	#    focus: a strip that wrote the wrong rect or the wrong value cannot survive both readings.
	terrain.vt_clipmap_budget_texels = TEXELS
	var streams := 0
	for step in 8:
		move_to(target.position.x + 1.0, target.position.z + (1.0 if step % 2 == 0 else 0.0))
		await tick()
		streams += 1
		require(pending() == 0, "a one-texel move finishes inside one tick at this budget")
	var strip_error := content_error()
	var strip_samples := snapshots()
	require(strip_error < 0.0001, "eight strips leave every texel equal to the height map under it")
	move_to(80.5, 60.5)
	await tick()
	move_to(30.5 + 8.0, 9.5 + 4.0)
	# The move has to be ticked before the drain is waited on: a level with no jobs queued yet is
	# whole at the *old* focus, and `ticks_until_drained()` would return without producing anything.
	await tick()
	await ticks_until_drained()
	diag("full_regen")
	require(pending() == 0 and valid_levels() == 1, "the level is whole again after the full regeneration")
	var full_error := content_error()
	var full_samples := snapshots()
	require(full_error < 0.0001, "the full regeneration holds the height map under it too")
	var mismatch := 0
	for index in strip_samples.size():
		if absf(strip_samples[index] - full_samples[index]) > 0.0001:
			mismatch += 1
	require(mismatch == 0, "and the level built out of strips is the level built whole, texel for texel")
	print("VT_CLIPMAP_INCREMENTAL moves=%d strip_error=%.6f full_error=%.6f mismatch=%d size=%d" % [
		streams, strip_error, full_error, mismatch, TEXELS])

	# 5b. An edit under the ring. The rect the changed area covers is re-produced rather than the ring,
	#     and the level that covers it stops being current until it has - which is what a reader of the
	#     ring falls back on, so it is read here as state and not as a picture. Four numbers: the texels
	#     queued, the level going not-current, nothing produced until it may be, and then exactly the
	#     queued texels with the edited height in them and every other texel still the height map's.
	var before_invalidations := invalidations()
	var before_invalidated := invalidated_texels()
	var before_invalidation_produced := produced()
	var center: Vector2 = level_report().get("center", Vector2.ZERO)
	var area := AABB(Vector3(center.x - 2.0, 0.0, center.y - 2.0), Vector3(4.0, 1.0, 4.0))
	terrain.data.set_height(Vector3(center.x, 0.0, center.y), 99.0)
	# The production is stopped for the window, so "the rect waited" is observable: a whole-level budget
	# drains 16 texels in the first tick and the level would be current again before it could be read.
	var budget := terrain.vt_clipmap_budget_texels
	terrain.vt_clipmap_budget_texels = 0
	var queued_jobs := terrain.invalidate_vt_clipmap_area(area)
	await tick()
	diag("invalidate_queued")
	require(queued_jobs == 1, "one 16 m level covers a 4x4 m rect, and it queues one job")
	require(invalidations() == before_invalidations + 1, "which is one invalidation")
	require(invalidated_texels() - before_invalidated == 16, "of the rect's own texels, 4 on an axis")
	require(valid_levels() == 0, "the level that covers the rect is not current")
	require(pending() == 1, "and the rect is queued")
	require(produced() == before_invalidation_produced, "with nothing produced while the budget is zero")
	terrain.vt_clipmap_budget_texels = budget
	await ticks_until_drained()
	diag("invalidate_drained")
	require(valid_levels() == 1, "the rect drains and the level is current again")
	require(pending() == 0, "with nothing left queued")
	require(produced() - before_invalidation_produced == 16, "having produced exactly the queued texels")
	require(absf(sample(Vector2(center.x, center.y)) - 99.0) < 0.001, "and the ring holds the edited height")
	require(content_error() < 0.0001, "while every other texel is still the height map under it")
	print("VT_CLIPMAP_INVALIDATE rect=4x4 queued=%d texels=%d produced=%d error=%.6f" % [
		queued_jobs, invalidated_texels() - before_invalidated, produced() - before_invalidation_produced,
		content_error()])

	# 6. The debug payload the VT Page view draws, and the gate in front of it. The payload has to
	#    carry the world square of every level - a clipped *view* of a ring is exactly what makes a
	#    strip look right for a frame - and it has to state what is still queued, because the queued
	#    rects are the only part of a ring a picture can show changing.
	require(terrain.has_vt_clipmap_layer(), "the layer the entry built exists, and that is what the payload is gated on")
	require(not terrain.is_vt_delivery_used(CLIPMAP), "while no delivery cell claims the method, which this build refuses")
	var preview := terrain.get_clipmap_layout_preview()
	var layers: Array = preview.get("layers", [])
	require(layers.size() == 1, "the preview describes exactly the one layer that exists, not one a group")
	var entry: Dictionary = layers[0] if not layers.is_empty() else {}
	require(str(entry.get("group", "")) == "height", "and names the channel group it carries")
	var squares: Array = entry.get("unit_reports", [])
	require(squares.size() == LEVELS, "with one square a level")
	var square: Dictionary = squares[0] if not squares.is_empty() else {}
	require(absf(float(square.get("world_size", 0.0)) - BASE_WORLD) < 0.001, "each square is the world that level covers")
	require(absf(float(square.get("texel_world", 0.0)) - 1.0) < 0.001, "and states the texel size the snap uses")
	require(square.get("center", Vector2.ZERO) == level_report().get("center", Vector2.ZERO), "and the snapped centre the report carries")
	require(int(square.get("pending", 0)) == 0, "a drained level has nothing queued")
	require((square.get("pending_rects", []) as Array).is_empty(), "so it reports no pending rect")
	var focus: Vector2 = preview.get("focus", Vector2.ZERO)
	require(absf(focus.x - target.position.x) < 0.001 and absf(focus.y - target.position.z) < 0.001,
			"and the payload names the focus the levels were snapped to")

	# Sixteen texels of 256 produced: the reported rects are the *rest* of the job, so their world
	# areas have to add up to exactly what the budget has not produced yet. A rect that reported the
	# whole job, or a cursor read as the rect's origin, cannot pass this.
	move_to(90.5, 13.5)
	terrain.vt_clipmap_budget_texels = 4
	await tick()
	require(pending() == 1 and produced() > 0, "a four-texel budget leaves the job queued")
	var partial := preview_level(squares_of(terrain.get_clipmap_layout_preview()))
	# The shared per-unit schema publishes `pending` as the number of queued rects a unit owes (the
	# old per-group preview published the job count beside the rects). One job split in two is
	# therefore two, which the rect assertion below reads as its own statement.
	require(int(partial.get("pending", 0)) == 2, "the payload counts the queued rects")
	var rects: Array = partial.get("pending_rects", [])
	require(rects.size() == 2, "and splits what is left into the rest of the row and the rows below it")
	var remaining := 0.0
	for value: Variant in rects:
		remaining += (value as Rect2).size.x * (value as Rect2).size.y
	require(absf(remaining - float(TEXELS - 4)) < 0.001,
			"the rects are exactly the %d texels the budget has not produced" % (TEXELS - 4))
	require(not bool(partial.get("valid", true)), "and the level is not valid while that work is queued")
	print("VT_CLIPMAP_PREVIEW layers=%d levels=%d queued=%d rects=%d remaining=%.0f focus=%.1f,%.1f" % [
		layers.size(), squares.size(), int(partial.get("pending", 0)), rects.size(), remaining, focus.x, focus.y])

	# The gate: the payload is refused while no ring exists and answered once one does, and the ring is
	# the gate's whole subject - it does not ask the matrix, which could never say yes in this build.
	# The two counters are what make that a reading: the asks go up, and the work follows the object.
	var before_calls := int(settings().get("clipmap_preview_calls", 0))
	var before_computed := int(settings().get("clipmap_preview_computed", 0))
	terrain.vt_clipmap_budget_texels = TEXELS
	await ticks_until_drained()
	require(not terrain.is_vt_delivery_used(CLIPMAP),
			"Clipmap stays unselected: this build refuses the cell for the height group")
	require(terrain.has_vt_clipmap_layer(), "but the layer the entry built exists")
	require(not terrain.get_clipmap_layout_preview().is_empty(), "so the preview answers it")
	var answered := settings()
	require(int(answered.get("clipmap_preview_calls", 0)) - before_calls == 1, "the ask was counted")
	require(int(answered.get("clipmap_preview_computed", 0)) - before_computed == 1, "and it did the work, because a layer was there")
	print("VT_CLIPMAP_GATE calls=%d computed=%d layer=%s selected=%s" % [
		int(answered.get("clipmap_preview_calls", 0)) - before_calls,
		int(answered.get("clipmap_preview_computed", 0)) - before_computed,
		str(answered.get("clipmap_layer")), str(terrain.is_vt_delivery_used(CLIPMAP))])

	if failed:
		print("REGRESSION: clipmap ring")
		quit(1)
		return
	print("PASS clipmap ring")
	quit(0)


# Every texel of the finest level, read through the ring, for the incremental-versus-full comparison.
func snapshots() -> Array:
	var values := []
	var report := level_report()
	var center: Vector2 = report.get("center", Vector2.ZERO)
	var half := float(report.get("world_size", 0.0)) * 0.5
	var texel := float(report.get("texel_world", 1.0))
	for y in SIZE:
		for x in SIZE:
			values.append(sample(center - Vector2(half, half) + Vector2((x + 0.5) * texel, (y + 0.5) * texel)))
	return values


# The per-unit entries the preview reports for the first layer in its payload, which is the layer
# this scene builds: one entry a unit, in unit order, in the shared schema either implementation
# fills.
func squares_of(p_preview: Dictionary) -> Array:
	var layers: Array = p_preview.get("layers", [])
	if layers.is_empty():
		return []
	return (layers[0] as Dictionary).get("unit_reports", [])


# The finest level of a set of squares, which is the one a one-level ring has.
func preview_level(p_squares: Array) -> Dictionary:
	return p_squares[0] if not p_squares.is_empty() else {}
