extends SceneTree
## P0 probe for `docs/vt_hdrp_avt_alignment.md` section 7.
##
## Section 7 suspects that a change of the far field's world mip cap is treated as a content
## change - every region is marked for re-bake and the material's region arrays are rebuilt -
## and that the cap keeps moving while the view moves. This script decides that with numbers
## instead of by reading the code: it drives a far-field view through a full turn and a
## lateral displacement and reports, at every step, each counter that could explain a visible
## far-field page-update trace.
##
## It asserts nothing about the result except that the scene ran. The point is the log.
##
## `PAGE_WORLD` is 32 m rather than the 256 m default so a 1.9 km view exercises the same
## level range a 6 km view does at the default, without a 32 x 32 region grid. The rule under
## test is scale free: level m owns `PAGE_WORLD * 2^(m+1)` metres.

const REGION_SIZE := 256
const REGION_GRID := 5
const PAGE_WORLD := 32.0
const PAGE_COUNT := 256
# The indirection's "no page here" marker, as `terrain_vt.h` defines it.
const INVALID_SLOT := 65535
## Frames driven per camera step, and the frames allowed for the view to settle first.
const STEP_FRAMES := 3
const SETTLE_FRAMES := 60
## Phase C's motion: a cruise leg's speed in metres per second and its length in frames. At 60
## frames per second this is about 3.3 m per frame, in the range the motion lead is tuned for
## (`vt_motion_lead_ms` defaults to 250 ms, which at this speed leads by about 50 m).
const CRUISE_SPEED := 200.0
const CRUISE_FRAMES := 100
## Fixed world points inside the region grid. The level the rule selects for each of them is
## sampled at every report, so `total_moves` counts resolution changes that happened at a
## fixed place while the camera moved. A point whose level moves when the camera *turns* is a
## resolution change at distance, which is the artifact this probe exists for - and the number
## H1's footprint rule is expected to remove, so it is H1's acceptance metric.
const PROBE_POINTS := [Vector2(384.0, 384.0), Vector2(1152.0, 384.0), Vector2(384.0, 1152.0), Vector2(1152.0, 1152.0)]

var terrain: Terrain3D
var scene: Node3D
var camera: Camera3D
var previous := {}
var previous_served := PackedInt32Array()
var served_changes := 0
# The last plan generation the full-tuple line was printed for; see `report()`.
var previous_plan_generation := -1
# The near field's reach the probe drives, from `VT_PROBE_AVT_DISTANCE`; 384 is the setting's
# default. Phases A, E and F run at it, so one script measures what the reach costs the plan and
# the settle by environment alone.
var avt_reach := 384.0
# The producer snapshot `ring_line()` measures its interval against, and the one `run()` opened
# with, so the summary can report the session's own production rate.
var ring_previous := {}
var ring_opening := {}

func _initialize() -> void:
	call_deferred("run")

func frame_barrier() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

# The engine's own tick: the same notification a physics frame delivers, which is the path
# that runs both demand passes. `set_physics_process(false)` only stops the automatic call.
func tick() -> void:
	await frame_barrier()
	terrain.notification(Node.NOTIFICATION_PHYSICS_PROCESS)

func settings() -> Dictionary:
	return terrain.get_vt_settings()

# The producer's own rate limiters. The tick's page budget is the *demand* side: a page is shaded
# into a ring position that stays held until its encode readbacks land, so the ring's admitted
# depth is the real pages-per-frame ceiling, `pending` is what a frame had to defer for want of a
# position, and `baked+cached+migrated` over the frames the producer ran is what it actually
# produced per frame. `alloc` is the depth the bundle allocated; `_refresh_encode_ring_capacity()`
# never admits more than that, and the allocation is decided when the bundle is built, so a
# `vt_pages_per_update` raised at runtime cannot deepen the ring. Section 7.7.11 has the reading.
func producer_stats() -> Dictionary:
	return settings().get("producer", {})

func produced_pages(p_stats: Dictionary) -> int:
	return int(p_stats.get("baked_pages", 0)) + int(p_stats.get("cached_uploads", 0)) \
			+ int(p_stats.get("migrated_pages", 0))

# The same snapshot the report line is built from, so the interval deltas and the session totals
# cannot disagree with it.
func ring_watch() -> Dictionary:
	var stats := producer_stats()
	return {
		"cap": int(stats.get("encode_ring_capacity", -1)),
		"alloc": int(stats.get("encode_ring_allocated", -1)),
		"pages": int(stats.get("encode_ring_pages", 0)),
		"pending": int(stats.get("pending", 0)),
		"enc_pending": int(stats.get("encode_pending", 0)),
		"ready": int(stats.get("ready_pages", 0)),
		"staging": int(stats.get("staging_layers", 0)),
		"dispatch": int(stats.get("dispatch_count", 0)),
		"produced": produced_pages(stats),
		"enc_req": int(stats.get("encode_requests", 0)),
		"enc_back": int(stats.get("encode_readbacks", 0)),
		"lat": float(stats.get("ready_latency_frames_mean", 0.0)),
		"lat_max": float(stats.get("ready_latency_frames_max", 0)),
	}

# Printed on every report rather than folded into the changed-only line: these counters move in
# every step that produces anything, so putting them in `watch()` would replace every `(settled)`
# with noise and hide the one signal that line exists for.
func ring_line(p_label: String) -> void:
	var now := ring_watch()
	var produced := int(now["produced"]) - int(ring_previous.get("produced", int(now["produced"])))
	var frames := int(now["dispatch"]) - int(ring_previous.get("dispatch", int(now["dispatch"])))
	print("VTCAPRING %-14s cap=%d alloc=%d pages=%d pending=%d enc_pending=%d ready=%d staging=%d | frames=%d produced=%d per_frame=%.2f enc=%d/%d lat=%.2f/%.0f" % [
			p_label, int(now["cap"]), int(now["alloc"]), int(now["pages"]), int(now["pending"]),
			int(now["enc_pending"]), int(now["ready"]), int(now["staging"]), frames, produced,
			float(produced) / float(maxi(frames, 1)),
			int(now["enc_req"]) - int(ring_previous.get("enc_req", int(now["enc_req"]))),
			int(now["enc_back"]) - int(ring_previous.get("enc_back", int(now["enc_back"]))),
			float(now["lat"]), float(now["lat_max"])])
	ring_previous = now

# Everything that could move when the view moves, in one snapshot. `cap_*` is the suspect of
# section 7; the rest is what actually explains a far-field update if the suspect is still.
# `fade_starts` is the direct signal for a visible trace: a page that arrives starts a fade,
# so the fade start count is how many pages changed underneath the view during these frames.
func watch() -> Dictionary:
	var s := settings()
	var pool := {}
	if terrain.get_surface_svt() != null:
		pool = terrain.get_surface_svt().get_stats()
	# The near field's own addressing outcomes. `alloc`/`evict`/`free` above are the *shared
	# pool's* counters, so only a per-view miss count can say which view is asking for the
	# pages that the pool is churning through.
	var near := {}
	if terrain.get_surface_vt() != null:
		near = terrain.get_surface_vt().get_stats()
	# The near field's own account of what it planned and what it produced this pass. These are
	# the keys section 7.4 of the alignment document names as the way to tell "new pages are
	# entering the view" from "the few pages of the working set are being re-requested".
	var avt: Dictionary = s.get("avt_sector_stats", {})
	return {
		"max_mip": int(s.get("svt_effective_max_mip", -1)),
		"cap_changes": int(s.get("svt_cap_changes", 0)),
		# The region re-bakes a cap change caused. Since H3 step 1 it is a property rather than a
		# measurement: a cap change publishes a bound and marks nothing, so a non-zero value here is
		# the whole-world re-bake coming back.
		"cap_regions": int(s.get("svt_cap_dirty_regions", 0)),
		"cap_ms": float(s.get("svt_cap_change_ms", 0.0)),
		"cap_worst_ms": float(s.get("svt_cap_change_worst_ms", 0.0)),
		"cap_last": "%d>%d" % [int(s.get("svt_cap_last_from", -1)), int(s.get("svt_cap_last_to", -1))],
		"root_cap_raises": int(s.get("svt_root_cap_raises", 0)),
		"root_pages": int(s.get("svt_root_pages", 0)),
		# Which set answers a non-resident far-field fragment, and how wide one of its pages is. The
		# pair is the measurement H2 is adopted or rejected on: the wider the fallback page, the
		# larger the rectangle a fallback arrival changes.
		"fallback_policy": int(s.get("svt_fallback_policy", -1)),
		"root_page_world": float(s.get("svt_root_page_world", 0.0)),
		"root_passes": int(s.get("svt_root_passes", 0)),
		"root_skips": int(s.get("svt_root_skips", 0)),
		# What the far field's cell sources cost: cells the persisted-bake probe examined, and
		# pages it refused to examine because they cover more cells than a cell source can serve.
		# A rebuilt root pyramid asks the disk about pages the disk cannot assemble unless the
		# second counter moves - see `svt_page_cell_cover()` and section 7.7.13.
		"probe_cells": int(s.get("svt_persist_probe_cells", 0)),
		"probe_skips": int(s.get("svt_persist_probe_skips", 0)),
		"visible_pages": int(s.get("svt_visible_pages", 0)),
		"floor": int(s.get("svt_floor_level", 0)),
		"requeues": int(s.get("svt_requeues", 0)),
		"fade_starts": int(s.get("vt_page_fade_starts", 0)),
		"fade_active": int(s.get("vt_page_fade_active_slots", 0)),
		"fade_held": int(s.get("vt_page_fade_held_slots", 0)),
		"alloc": int(pool.get("alloc_count", 0)),
		"evict": int(pool.get("evict_count", 0)),
		# This view's own addressing outcomes. A miss is what gets produced, so a miss count
		# that keeps growing while `visible_pages` stays flat means the same pages are being
		# invalidated and re-requested rather than new pages entering the view.
		"hit": int(pool.get("hit_count", 0)),
		"miss": int(pool.get("miss_count", 0)),
		"writes": int(pool.get("page_write_count", 0)),
		"free": int(pool.get("free_count", 0)),
		"prot": int(pool.get("protected_count", 0)),
		"n_hit": int(near.get("hit_count", 0)),
		"n_miss": int(near.get("miss_count", 0)),
		# Near-field demand shape: how big the plan is, how much of it the image samples, how
		# much of that is missing, whether the plan was reused, whether the address directory
		# was rebuilt, and whether the address budget biased the sizes.
		"avt_pages": int(avt.get("requested_physical_pages", 0)),
		"avt_prefetch": int(avt.get("prefetch_requests", 0)),
		"avt_sampled": int(avt.get("sampled_pages", 0)),
		"avt_missing": int(avt.get("visible_missing_pages", 0)),
		"avt_pending": int(avt.get("visible_pending_pages", 0)),
		"avt_produced": int(avt.get("produced", 0)),
		"avt_prefetched": int(avt.get("prefetched", 0)),
		"avt_reused": bool(avt.get("plan_reused", false)),
		"avt_key_same": bool(avt.get("plan_key_unchanged", false)),
		"avt_key_dirty": int(avt.get("plan_key_dirty_component", -2)),
		"avt_chain": int(avt.get("chain_ticks", 0)),
		"avt_dir_rebuilt": bool(avt.get("directory_rebuilt", false)),
		"avt_retained_addr": int(avt.get("retained_sector_addresses", 0)),
		"avt_bias": int(avt.get("virtual_budget_bias", 0)),
		"avt_sectors": int(avt.get("visible_sectors", 0)),
		"avt_radius": float(avt.get("coverage_radius", -1.0)),
		# The plan's budget. A plan larger than its budget would be a different problem from a
		# plan that fills it: the first is a sizing bug, the second is demand meeting capacity.
		"avt_pool": int(avt.get("pool_pages", 0)),
		"avt_budget": int(avt.get("plan_budget", 0)),
		# Why a planned page was not produced this pass: no slot (the pool is full, so the
		# optional pages are crowding out the sampled ones) or no source (the workers are
		# behind). The two have different fixes, so the split is the reading that matters.
		"avt_slot_wait": int(avt.get("produce_slot_wait", 0)),
		"avt_source_wait": int(avt.get("produce_source_wait", 0)),
		"avt_roots": int(avt.get("visible_root_pages", 0)),
		"avt_denied": int(avt.get("refinement_requests_denied", 0)),
		"avt_mip_bias": int(avt.get("capacity_mip_bias", 0)),
		"avt_retained_reqs": int(avt.get("retained_requests", 0)),
		# The plan's rate term (section 7.7). The term is what the plan may hold beyond the pages
		# the image samples; the apron and the retention share are how it was spent. A plan whose
		# tail sits at the term is one sized to the production rate; the residency bound beside it
		# (`avt_budget`) is the number that let it be sized to the pool instead.
		"avt_tail_cap": int(avt.get("plan_tail_cap", 0)),
		"avt_retain_share": int(avt.get("plan_retain_share", 0)),
		"avt_apron": int(avt.get("plan_apron_pages", 0)),
		# P0e: how one plan generation differs from the one before it. `carried` is the share that
		# needed no new slot at all. Of what is left: `overlapped` is a rect a previous page of the
		# same owner intersects, `rescaled` is a span the owner did not have (its block size stepped,
		# or the walk reached a new mip), `reselected` is a new page at an owner and span the previous
		# plan both had (the boundary decisions moved), and `new_sector` is an owner no page covered.
		# `dropped` is the other direction: what the retention window has to hold.
		#
		# Read `overlapped` for what it is: a page the walk just *refined into* necessarily intersects
		# its parent, and the parent is always in the previous plan, so this counter measures the
		# refinement frontier's movement and cannot distinguish gaining a level from re-deriving one.
		# Section 7.7.3 read it as "the same ground at another level"; the `avt_depth_*` pair below is
		# the version of that question which can answer, and section 7.7.7 has the correction.
		"avt_sel": int(avt.get("plan_selected", 0)),
		"avt_carried": int(avt.get("plan_carried", 0)),
		"avt_overlapped": int(avt.get("plan_overlapped", 0)),
		"avt_reselected": int(avt.get("plan_reselected", 0)),
		"avt_rescaled": int(avt.get("plan_rescaled", 0)),
		"avt_new_sector": int(avt.get("plan_new_sector", 0)),
		"avt_new_area": int(avt.get("plan_new_area", 0)),
		"avt_dropped": int(avt.get("plan_dropped", 0)),
		# Which way the refinement *depth* moved, per owner both plans held: the finest world span
		# each plan offers for that owner. `deepened` is a level gained, `receded` a level given up.
		# The first attempt at this question asked the overlap test whether the previous rect over
		# the same ground was finer or coarser, and every bucket was structurally single-valued - a
		# refined child always intersects its parent, so "the previous rect was larger" is what being
		# a child means. Depth per owner is the version of the question that can take three values.
		"avt_depth_up": int(avt.get("plan_depth_deepened", 0)),
		"avt_depth_down": int(avt.get("plan_depth_receded", 0)),
		"avt_depth_same": int(avt.get("plan_depth_same", 0)),
		# How many sectors had their virtual block size raised during the generation the churn
		# counters above describe. The pair says whether `avt_rescaled` is a block-size step or the
		# refinement walk reaching a new mip by itself.
		"avt_size_grows": int(avt.get("sector_size_grows", 0)),
		"avt_late": int(avt.get("visible_late_pages", 0)),
		"avt_idle_lost": int(avt.get("idle_ready_lost", 0)),
		"avt_pins": int(avt.get("pins_released", 0)),
		# The near field's own pass cost, against the 3 ms soft deadline the architecture review
		# documents. A pass that produces 8 pages with a budget of 16 and no slot or source wait
		# stopped on this deadline, so the split says which half of the work filled it.
		"avt_cpu_ms": float(avt.get("cpu_update_ms", 0.0)),
		"avt_alloc_ms": float(avt.get("allocation_ms", 0.0)),
		"avt_payload_ms": float(avt.get("payload_ms", 0.0)),
		"avt_queue_ms": float(avt.get("queue_ms", 0.0)),
		"avt_classify_ms": float(avt.get("classify_ms", 0.0)),
		"avt_retain_ms": float(avt.get("retain_ms", 0.0)),
		"avt_finish_ms": float(avt.get("finish_ms", 0.0)),
		"pending_regions": int(s.get("auto_pending_regions", 0)),
		"eff_pool": int(s.get("effective_page_count", 0)),
		"pool_gen": int(s.get("pool_generation", 0)),
		"per_update": int(s.get("pages_per_update", 0)),
		"avt_allowance": int(s.get("avt_allowance", 0)),
		# H4's probe, answered on the running binary: whether the main RenderingDevice can store a
		# page on the GPU directly, and whether it can read data back without a stall. The missing
		# capability is the one that is not a boolean here - see section 7.7.5.
		"rd_store": int(s.get("rd_direct_store", 0)),
		"rd_async_buf": int(s.get("rd_async_buffer_readback", 0)),
		"rd_async_tex": int(s.get("rd_async_texture_readback", 0)),
		"svt_cpu_ms": float(s.get("svt_cpu_ms", 0.0)),
		"svt_worst_ms": float(s.get("svt_worst_ms", 0.0)),
	}

# The level the far field's rule selects for each fixed probe point, measured the way the
# shader measures it: the distance from the camera to the ground point.
func probe_levels() -> PackedInt32Array:
	var levels := PackedInt32Array()
	for point in PROBE_POINTS:
		levels.append(terrain.get_surface_svt_mip_for_distance(
				Vector3(point.x, 0.0, point.y).distance_to(camera.global_position)))
	return levels

# The level a fragment at this world point actually gets: the shader starts at the level the
# rule selects and walks coarser until it finds a published page, so this is the first
# resident level at or above the selected one. It is the resolution the image is made of, and
# unlike the selected level it *can* move while the camera only turns - which is what a trace
# at distance looks like from the frame's side.
func served_level(p_world: Vector2, p_selected: int) -> int:
	var max_mip := int(terrain.get_vt_settings().get("svt_effective_max_mip", 0))
	var page := Vector2i(int(floor(p_world.x / PAGE_WORLD)), int(floor(p_world.y / PAGE_WORLD)))
	for mip in range(clampi(p_selected, 0, max_mip), max_mip + 1):
		var virtual: Vector2i = terrain.get_surface_svt().get_world_page_virtual(page.x, page.y, mip)
		if terrain.get_surface_svt().get_indirection_slot(virtual.x, virtual.y, mip) != INVALID_SLOT:
			return mip
	return -1

func served_levels(p_selected: PackedInt32Array) -> PackedInt32Array:
	var levels := PackedInt32Array()
	for index in PROBE_POINTS.size():
		levels.append(served_level(PROBE_POINTS[index], p_selected[index]))
	return levels

func levels_text(p_selected: PackedInt32Array, p_served: PackedInt32Array) -> String:
	var parts: PackedStringArray = []
	for index in p_selected.size():
		parts.append("%d>%d" % [p_selected[index], p_served[index]])
	return ",".join(parts)

# Prints only what changed since the previous report, so a settled step is visibly settled.
func report(p_label: String) -> void:
	var now := watch()
	if ring_opening.is_empty():
		ring_opening = ring_watch()
	var changed: PackedStringArray = []
	for key in now:
		if previous.get(key, null) != now[key]:
			changed.append("%s=%s" % [key, str(now[key])])
	previous = now
	var selected := probe_levels()
	var served := served_levels(selected)
	var moved := 0
	if previous_served.size() == served.size():
		for index in served.size():
			if previous_served[index] != served[index]:
				moved += 1
	served_changes += moved
	previous_served = served
	var detail := " ".join(changed) if changed.size() > 0 else "(settled)"
	print("VTCAP %-16s %s | served %s moved=%d changes=%d" % [
			p_label, detail, levels_text(selected, served), moved, served_changes])
	# The plan-generation tuple in full, whenever a new generation's counters appear. The line above
	# prints only what *changed* since the last report, which is what makes a settled step visibly
	# settled - but it cannot be read as a record: a counter that stayed at its previous value does
	# not print, so a row reconstructed from it is a guess. P0e's table in section 7.7.3 and P2's in
	# section 7.7.7 are both read out of this line instead. `avt_sel` is the generation marker: the
	# installer writes all of these together, so a change in any of them implies it.
	var plan_generation := int(now.get("avt_sel", 0))
	if plan_generation != previous_plan_generation:
		previous_plan_generation = plan_generation
		print("VTCAPPLAN %-14s sel=%d carried=%d overlapped=%d rescaled=%d reselected=%d new_sector=%d new_area=%d dropped=%d missing=%d depth_up=%d depth_down=%d depth_same=%d size_grows=%d" % [
				p_label, plan_generation, int(now.get("avt_carried", 0)), int(now.get("avt_overlapped", 0)),
				int(now.get("avt_rescaled", 0)), int(now.get("avt_reselected", 0)), int(now.get("avt_new_sector", 0)),
				int(now.get("avt_new_area", 0)), int(now.get("avt_dropped", 0)), int(now.get("avt_missing", 0)),
				int(now.get("avt_depth_up", 0)), int(now.get("avt_depth_down", 0)), int(now.get("avt_depth_same", 0)),
				int(now.get("avt_size_grows", 0))])
	ring_line(p_label)

func add_flat_regions() -> void:
	terrain.region_size = REGION_SIZE
	for z in REGION_GRID:
		for x in REGION_GRID:
			terrain.data.add_region_blank(Vector2i(x, z))
	terrain.data.update_maps()

func make_texture(p_color: Color) -> ImageTexture:
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(p_color)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func add_materials() -> void:
	terrain.assets = Terrain3DAssets.new()
	for id in 2:
		var asset := Terrain3DTextureAsset.new()
		asset.albedo_texture = make_texture(Color(0.16, 0.42, 0.2) if id == 0 else Color(0.55, 0.42, 0.2))
		asset.normal_texture = make_texture(Color(0.5, 0.5, 1.0))
		terrain.assets.set_texture_asset(id, asset)

func build_scene() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://vt_cap_probe_data"))
	scene = Node3D.new()
	terrain = Terrain3D.new()
	terrain.vt_page_count = PAGE_COUNT
	# An A/B knob for the one feng extension HDRP does not have: growing the physical pool at runtime
	# (`vt_auto_capacity`). Growth cannot preserve a page - the atlas is one Texture2DArray and
	# `ensure_layers()` recreates it blank when its layer count changes, so `Terrain3DVTPagePool::grow()`
	# evicts every used slot - and the generation is deliberately not bumped for it, so the wipe is
	# silent. Section 7.7.10 measures the trade. Set `VT_PROBE_AUTO_CAPACITY=0` in the environment to
	# run the same script with growth off; the runner passes the environment through.
	var auto_capacity := OS.get_environment("VT_PROBE_AUTO_CAPACITY")
	if auto_capacity != "":
		terrain.vt_auto_capacity = auto_capacity != "0"
	# The page budget the two tiers share. Raised to 32 as an opt-in (section 7.7.1's supply experiment
	# argues against expecting much, but it had a confound this does not), so the probe can A/B it.
	var per_update := OS.get_environment("VT_PROBE_PAGES_PER_UPDATE")
	if per_update != "":
		terrain.vt_pages_per_update = int(per_update)
	# The near field's radius, which is its working set: every sector inside it is planned, so the
	# plan's page count - and therefore the work a move has to fill - is a function of this number.
	# The tier boundary the far field uses is `0.75 * this` (`_update_visible_svt()`'s
	# `avt_interior`), so shrinking it hands the ground between the two numbers to the far field.
	var avt_distance := OS.get_environment("VT_PROBE_AVT_DISTANCE")
	if avt_distance != "":
		avt_reach = float(avt_distance)
	terrain.surface_vt_distance = avt_reach
	print("VTCAP knob             auto_capacity=%s pages_per_update=%d page_count=%d avt_distance=%.0f" % [
			str(terrain.vt_auto_capacity), int(terrain.vt_pages_per_update), PAGE_COUNT,
			float(terrain.surface_vt_distance)])
	terrain.surface_svt_page_world = PAGE_WORLD
	# The automatic distance rule, which is the configuration section 7 is about.
	terrain.surface_svt_mip_distances = PackedFloat32Array()
	terrain.surface_svt_auto_bake = false
	terrain.vt_editor_preview = false
	terrain.free_editor_textures = false
	terrain.data_directory = "user://vt_cap_probe_data"
	add_materials()
	camera = Camera3D.new()
	camera.far = 8192.0
	camera.position = Vector3(128.0, 300.0, -200.0)
	root.add_child(camera)
	camera.look_at(Vector3(640.0, 0.0, 640.0), Vector3.UP)
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, -20.0, 0.0)
	scene.add_child(light)
	scene.add_child(terrain)
	root.add_child(scene)
	terrain.set_camera(camera)
	terrain.set_clipmap_target(terrain)
	terrain.set_physics_process(false)
	add_flat_regions()

# One scripted camera sweep: a full turn in 15 degree steps, then a lateral walk across the
# region grid, reporting every fourth step.
func sweep(p_phase: String) -> void:
	for step in range(1, 25):
		camera.rotation.y = deg_to_rad(15.0 * float(step))
		for _i in STEP_FRAMES:
			await tick()
		if step % 4 == 0:
			report("%s turn %d" % [p_phase, 15 * step])
	for step in range(1, 5):
		camera.position += Vector3(REGION_SIZE, 0.0, REGION_SIZE)
		for _i in STEP_FRAMES:
			await tick()
		report("%s move %d" % [p_phase, REGION_SIZE * step])

# One frame, as the GPU drew it.
func capture() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

# The worst per-channel difference between two frames over the distant half of the picture -
# below the horizon line, where the far field is what is drawn. A settled view must reach
# zero: any value above 1/255 is the image still changing at distance.
func far_band_delta(p_before: Image, p_after: Image) -> float:
	var width := p_before.get_width()
	var height := p_before.get_height()
	var worst := 0.0
	for y in range(int(height * 0.30), int(height * 0.62), 4):
		for x in range(0, width, 8):
			worst = maxf(worst, absf(p_before.get_pixel(x, y).r - p_after.get_pixel(x, y).r))
	return worst

# How long the picture keeps changing after the camera stops. This is what "a page-update
# trace" is from the frame's side: the number of frames the far field is still visibly doing
# something, and the size of the largest step it took while doing it.
func settle_trace(p_label: String, p_max_frames: int = 40) -> void:
	var before: Image = await capture()
	var frames := 0
	var worst := 0.0
	for _i in p_max_frames:
		await tick()
		var after: Image = await capture()
		var delta := far_band_delta(before, after)
		worst = maxf(worst, delta)
		before = after
		frames += 1
		if delta <= 1.0 / 255.0:
			break
	print("VTCAP %-16s settle frames=%d worst_delta=%.4f" % [p_label, frames, worst])

# Continuous motion at a realistic speed. The walk above moves 256 m in three frames - about
# 85 m/frame, which is a teleport and which no motion lead can cover - so anything measured
# there is a teleport profile, not what a moving camera sees. This drives the camera forward
# at `p_speed` for `p_frames`, which is the profile the far field is actually tuned for.
func cruise(p_label: String, p_speed: float, p_frames: int) -> void:
	var forward := -camera.global_transform.basis.z
	var per_frame := p_speed / 60.0
	for frame in p_frames:
		camera.position += forward * per_frame
		await tick()
		if frame % 25 == 24:
			report("%s f%d" % [p_label, frame + 1])
func run() -> void:
	build_scene()
	await frame_barrier()
	print("VTCAP setup            regions=%d page_world=%.1f pool=%d bands=%s" % [
			terrain.data.get_region_locations().size(), PAGE_WORLD, PAGE_COUNT,
			"auto" if terrain.get_surface_svt_mip_distances().is_empty() else "table"])
	report("start")

	# Phase A: the shipped configuration. The near field covers its 512 m radius, so the far
	# field carries only what is beyond it.
	for _i in SETTLE_FRAMES:
		await tick()
	report("A settled")
	await sweep("A")

	# Phase B: the far field carries the view. Shrinking the near field's reach is what makes
	# a far-field page arrival the dominant visible event, which is the configuration the
	# reported trace is about.
	terrain.surface_vt_distance = 64.0
	camera.position = Vector3(128.0, 300.0, -200.0)
	camera.look_at(Vector3(640.0, 0.0, 640.0), Vector3.UP)
	for _i in SETTLE_FRAMES:
		await tick()
	report("B settled")
	await sweep("B")

	# Phase C: realistic motion. Cruise, then stop and measure how long the picture keeps
	# changing at distance. A trace that survives the cruise profile is a real one; the
	# teleport walk above cannot tell the two apart.
	camera.position = Vector3(128.0, 300.0, -200.0)
	camera.look_at(Vector3(640.0, 0.0, 640.0), Vector3.UP)
	for _i in SETTLE_FRAMES:
		await tick()
	await settle_trace("C settled")
	for leg in range(1, 4):
		await cruise("C cruise %d" % leg, CRUISE_SPEED, CRUISE_FRAMES)
		await settle_trace("C stop %d" % leg)

	# Phase D: the same cruise with the near field off, which isolates how much of the shared
	# pool's churn belongs to it. The far field gets the whole pool here, so its own demand is
	# also larger; the allocation *rate* per cruise leg is the number to compare with phase C.
	terrain.surface_vt_enabled = false
	camera.position = Vector3(128.0, 300.0, -200.0)
	camera.look_at(Vector3(640.0, 0.0, 640.0), Vector3.UP)
	for _i in SETTLE_FRAMES:
		await tick()
	report("D settled")
	await cruise("D cruise", CRUISE_SPEED, CRUISE_FRAMES)
	await settle_trace("D stop")

	# Phase E: back to the near-field reach the probe was started with, and cruise. Phase A only
	# settled and teleported; this is the configuration a project actually ships, driven the way a
	# camera actually moves, so it is the comparison that says whether the deficit phases B-D show is
	# a property of the small reach or of the near field itself. `avt_reach` is the knob, so the same
	# script measures a different reach by environment alone; 512 is the setting's default.
	terrain.surface_vt_enabled = true
	terrain.set_physics_process(false)
	terrain.surface_vt_distance = avt_reach
	camera.position = Vector3(128.0, 300.0, -200.0)
	camera.look_at(Vector3(640.0, 0.0, 640.0), Vector3.UP)
	for _i in SETTLE_FRAMES:
		await tick()
	report("E settled")
	for leg in range(1, 5):
		await cruise("E cruise %d" % leg, CRUISE_SPEED, CRUISE_FRAMES)
		await settle_trace("E stop %d" % leg)

	# Phase F: H2's per-unit guarantee as the fallback policy, on the same start pose and the same
	# cruise as phase E, so the two are comparable line for line. What the policy changes is *which*
	# pages are pinned - the coarsest level of each visible unit, instead of one complete level window
	# over the whole addressable domain - so `root_pages`, `root_page_world` and `free`/`alloc` are
	# the readings, and `served` says whether the fallback a fragment actually lands on moved.
	camera.position = Vector3(128.0, 300.0, -200.0)
	camera.look_at(Vector3(640.0, 0.0, 640.0), Vector3.UP)
	terrain.surface_svt_fallback_policy = 1
	for _i in SETTLE_FRAMES:
		await tick()
	report("F settled")
	for leg in range(1, 3):
		await cruise("F cruise %d" % leg, CRUISE_SPEED, CRUISE_FRAMES)
		await settle_trace("F stop %d" % leg)

	# Phase G: the configured mip cap changed at runtime, on the settled view F left behind. This is
	# P4's *setting* side, and the readings are the ones that tell "published a bound" from "rebuilt
	# the world": `pool_gen` must not move (a rebuilt pool releases every resident page and drops
	# every pin), `bake_generation` must not move (the catalogue is indexed by cell and level, not by
	# this cap), and the resident count must survive. `served` says whether the view still resolves.
	var cap_settings_before: Dictionary = terrain.get_vt_settings()
	var cap_watch_before := watch()
	var cap_resident_before := terrain.get_vt_pages().size()
	# The setting and the published cap are two different numbers: the pass raises the live cap above
	# the setting whenever the visible field needs more, so a line that printed only one of them could
	# not say which moved. `setting` is what this phase changes; `effective` is what the view publishes.
	var cap_setting_before := int(terrain.surface_svt_max_mip)
	var cap_effective_before := int(cap_settings_before.get("svt_effective_max_mip", -1))
	terrain.surface_svt_max_mip = cap_setting_before + 1
	for _i in SETTLE_FRAMES:
		await tick()
	var cap_settings_after: Dictionary = terrain.get_vt_settings()
	var cap_watch_after := watch()
	print("VTCAP G capsetting     setting %d->%d effective %d->%d resident %d->%d pool_gen %d->%d bake_generation %d->%d cap_changes %d->%d alloc %d->%d" % [
			cap_setting_before, int(terrain.surface_svt_max_mip),
			cap_effective_before, int(cap_settings_after.get("svt_effective_max_mip", -1)),
			cap_resident_before, terrain.get_vt_pages().size(),
			int(cap_settings_before.get("pool_generation", -1)), int(cap_settings_after.get("pool_generation", -1)),
			int(cap_settings_before.get("bake_generation", -1)), int(cap_settings_after.get("bake_generation", -1)),
			int(cap_watch_before.get("cap_changes", 0)), int(cap_watch_after.get("cap_changes", 0)),
			int(cap_watch_before.get("alloc", 0)), int(cap_watch_after.get("alloc", 0))])
	await settle_trace("G capsetting")

	# Phase H: the capacity change - the setting H3 step 2 is about. `surface_svt_page_count` reaches
	# `set_vt_page_count()`, which marks the shared setup stale, so the next tick builds a new pool:
	# every resident page is released, the far field's root plan is invalidated by the pool
	# generation, and the near field's plan and address directory are forgotten. It is the one
	# level-space change that is *reachable* at runtime, and unlike a cap change it moves the
	# indirection grid, so a remap is what would preserve the content. Nothing here asserts: the
	# numbers are the baseline that remap has to beat. `settle` afterwards is how long the view takes
	# to stop changing.
	var count_settings_before: Dictionary = terrain.get_vt_settings()
	var count_watch_before := watch()
	var count_resident_before := terrain.get_vt_pages().size()
	var page_count_before := int(terrain.surface_svt_page_count)
	terrain.surface_svt_page_count = page_count_before * 2
	for _i in SETTLE_FRAMES:
		await tick()
	var count_settings_after: Dictionary = terrain.get_vt_settings()
	var count_watch_after := watch()
	print("VTCAP H pagecount      pages %d->%d resident %d->%d pool_gen %d->%d bake_generation %d->%d alloc %d->%d evict %d->%d free %d->%d" % [
			page_count_before, int(terrain.surface_svt_page_count),
			count_resident_before, terrain.get_vt_pages().size(),
			int(count_settings_before.get("pool_generation", -1)), int(count_settings_after.get("pool_generation", -1)),
			int(count_settings_before.get("bake_generation", -1)), int(count_settings_after.get("bake_generation", -1)),
			int(count_watch_before.get("alloc", 0)), int(count_watch_after.get("alloc", 0)),
			int(count_watch_before.get("evict", 0)), int(count_watch_after.get("evict", 0)),
			int(count_watch_before.get("free", 0)), int(count_watch_after.get("free", 0))])
	await settle_trace("H pagecount")
	report("H pagecount")

	# Phase I: the same setting raised at runtime, which is what the dock's spin box does. The
	# ring's allocation is made for the whole ceiling when the bundle is built, so the admitted
	# depth has to follow the setting without a rebuild. Before that was true, a session that
	# raised 16 to 64 kept the ring the build-time budget derived and produced the rate of a
	# 16-page budget (section 7.7.12); the reading that says so is `cap` on the line below.
	var late_before := ring_watch()
	var late_setting := int(terrain.vt_pages_per_update)
	terrain.vt_pages_per_update = late_setting * 4
	for _i in SETTLE_FRAMES:
		await tick()
	report("I latebudget")
	var late_after := ring_watch()
	print("VTCAP I latebudget    setting %d->%d ring cap %d->%d alloc %d->%d staging %d" % [
			late_setting, int(terrain.vt_pages_per_update), int(late_before["cap"]), int(late_after["cap"]),
			int(late_before["alloc"]), int(late_after["alloc"]), int(late_after["staging"])])
	terrain.vt_pages_per_update = late_setting
	for _i in 2:
		await tick()

	var final := watch()
	var parts: PackedStringArray = []
	for key in final:
		parts.append("%s=%s" % [key, str(final[key])])
	parts.append("served_level_changes=%d" % served_changes)
	print("VTCAP summary          " + " ".join(parts))
	# The whole session's production rate, which is the reading "how fast does it load" asks for:
	# pages produced over the frames the producer ran, and the ring depth they were produced
	# through. `ring_line()` above gives the same reading for one interval at a time.
	var session := ring_watch()
	var session_frames := int(session["dispatch"]) - int(ring_opening.get("dispatch", int(session["dispatch"])))
	var session_produced := int(session["produced"]) - int(ring_opening.get("produced", int(session["produced"])))
	print("VTCAPRING session      cap=%d alloc=%d pages=%d pending=%d enc_pending=%d ready=%d staging=%d | frames=%d produced=%d per_frame=%.2f enc=%d/%d lat=%.2f/%.0f" % [
			int(session["cap"]), int(session["alloc"]), int(session["pages"]), int(session["pending"]),
			int(session["enc_pending"]), int(session["ready"]), int(session["staging"]), session_frames,
			session_produced, float(session_produced) / float(maxi(session_frames, 1)),
			int(session["enc_req"]), int(session["enc_back"]),
			float(session["lat"]), float(session["lat_max"])])
	# P6: the worst far-field pass's own breakdown, which is the one that cannot be read from the
	# live dictionary - `svt_stats` describes the worst pass, and `svt_worst_ms` says which total it
	# belongs to, so the pair is the record the phase needs. The ~200 ms first pass shows up here as
	# one stage dominating, and the four `*_ms` keys name which.
	var worst: Dictionary = terrain.get_vt_settings().get("svt_stats", {})
	var worst_parts: PackedStringArray = []
	for key in worst:
		worst_parts.append("%s=%s" % [key, str(worst[key])])
	print("VTCAP worstpass        svt_worst_ms=%s svt_worst_frames_ago=%s %s" % [
			str(terrain.get_vt_settings().get("svt_worst_ms", 0.0)),
			str(terrain.get_vt_settings().get("svt_worst_frames_ago", 0.0)),
			" ".join(worst_parts)])
	scene.queue_free()
	camera.queue_free()
	await frame_barrier()
	quit(0)
