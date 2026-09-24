# Run with a graphical rendering driver; see README.md in this directory.
#
# The near-material Clipmap *load* evidence. The user's report is "near material on Clipmap has a
# very long load time", and this script is the measurement that turns it into numbers along the
# user's own path: the near material group on `Clipmap`, `vt_clipmap_size = 256`, four rings,
# `base_world = 256`, and the shipped budget, with nothing else changed.
#
# It records, per physics tick, the clipmap phase's own cost, the material detail layer's cost, the
# channel texels the ring produced, the bytes it published to the device, and the bake's outstanding
# rects - from the frame the terrain is added to the tree until the ring and its bakes have settled,
# and then again for a scroll. The three numbers the acceptance asks for are:
#
#   * `CLIPMAP_LOAD first`  - how many ticks and how many milliseconds the first fill takes, and how
#                             many of those bytes the ring published as whole layers;
#   * `CLIPMAP_LOAD detail` - how many further ticks the 1024 texels/m detail layer takes, because
#                             that is the half of the near material field the coarse ring is not;
#   * `CLIPMAP_LOAD scroll` - the same for a 3 m move of the view.
#
# It also drives the *same* readings through the atlas mechanism when the build has one
# (`has_vt_clipmap_atlas()`), so the before/after table is produced by one script on one build and
# the comparison is the mechanism's own counters rather than two runs of two programs.
extends "res://vt_probe_base.gd"

const MATERIAL := 0
const HEIGHT := 1
const DIRECT := 0
const CLIPMAP := 2
const CLIPMAP_ATLAS := 4

# The measurement window. A frame cap, not a settle criterion: the script reports what it saw even
# when something never settles, because "it never settled" is itself the answer the user gave.
const LOAD_CAP := 600

var painter: Terrain3DEditor
var brush: Image

var _rows: Array = []

func settle(frames: int) -> void:
	for _i in frames:
		await process_frame

func settings() -> Dictionary:
	return terrain.get_vt_settings()

func clip_entry() -> Dictionary:
	return (settings().get("clipmap", {}) as Dictionary).get("material", {})

func detail_entry() -> Dictionary:
	var entry := clip_entry()
	return entry.get("detail", settings().get("detail_material", {}))

func phases() -> Dictionary:
	return settings().get("vt_phases", {})

# The coarse ring is settled when every ring is current and no bake is outstanding. A group with no
# ring reports no `levels`, which is settled by construction.
func ring_settled() -> bool:
	var entry := clip_entry()
	if not bool(entry.get("configured", false)):
		return true
	if int(entry.get("levels", 0)) <= 0:
		return true
	return int(entry.get("valid_levels", 0)) >= int(entry.get("levels", 0)) \
			and int(entry.get("pending_jobs", 0)) == 0 \
			and int(entry.get("pending_bake_rects", 0)) == 0

# The detail layer fills a slot table over many ticks; its own report is the criterion.
func detail_settled() -> bool:
	var entry := detail_entry()
	return int(entry.get("missing_tiles", 1)) == 0 and int(entry.get("fallback_tiles", 1)) == 0

# One measurement window. It samples the counters *after* each `process_frame`, so row N is the cost
# and the state of tick N, and it stops as soon as `p_settled` holds (or at `p_cap`).
func window(label: String, p_settled: Callable, p_cap: int) -> Dictionary:
	var frames := 0
	var clipmap_ms := 0.0
	var detail_ms := 0.0
	var peak_ms := 0.0
	var produced := 0
	var upload_bytes := 0
	var bake_dispatches := 0
	var last_valid := 0
	var last_pending := 0
	var last_bake_pending := 0
	var rows: Array = []
	while frames < p_cap:
		await process_frame
		frames += 1
		var s := settings()
		var p := phases()
		var frame_clip := float(p.get("clipmap", 0.0))
		var frame_detail := float(p.get("detail", 0.0))
		clipmap_ms += frame_clip
		detail_ms += frame_detail
		peak_ms = maxf(peak_ms, frame_clip + frame_detail)
		produced += int(s.get("clipmap_produced_texels", 0))
		var entry := clip_entry()
		upload_bytes = int(entry.get("upload_bytes", 0))
		bake_dispatches = int(entry.get("bake_dispatches", 0))
		last_valid = int(entry.get("valid_levels", 0))
		last_pending = int(entry.get("pending_jobs", 0))
		last_bake_pending = int(entry.get("pending_bake_rects", 0))
		rows.append({
			"frame": frames,
			"clipmap_ms": frame_clip,
			"detail_ms": frame_detail,
			"produced": int(s.get("clipmap_produced_texels", 0)),
			"upload_bytes": upload_bytes,
			"valid_levels": last_valid,
			"pending_jobs": last_pending,
			"pending_bake_rects": last_bake_pending,
		})
		print("CLIPMAP_LOAD_ROW %s frame=%d clipmap_ms=%.3f detail_ms=%.3f produced=%d upload_bytes=%d valid=%d pending=%d bake_pending=%d" % [
			label, frames, frame_clip, frame_detail,
			int(s.get("clipmap_produced_texels", 0)), upload_bytes,
			last_valid, last_pending, last_bake_pending])
		if p_settled.call():
			break
	var result := {
		"label": label,
		"frames": frames,
		"clipmap_ms": clipmap_ms,
		"detail_ms": detail_ms,
		"peak_ms": peak_ms,
		"produced": produced,
		"upload_bytes": upload_bytes,
		"bake_dispatches": bake_dispatches,
		"valid_levels": last_valid,
		"pending_jobs": last_pending,
		"pending_bake_rects": last_bake_pending,
		"rows": rows,
	}
	print("CLIPMAP_LOAD %s frames=%d clipmap_ms=%.3f detail_ms=%.3f peak_ms=%.3f produced=%d upload_bytes=%d bakes=%d valid=%d pending=%d bake_pending=%d" % [
		label, frames, clipmap_ms, detail_ms, peak_ms, produced, upload_bytes,
		bake_dispatches, last_valid, last_pending, last_bake_pending])
	return result

# The atlas mechanism's own load window. It is driven the way the ring's mechanism tests drive the
# ring - through the mechanism's own entry, one call a simulated frame - because the atlas is a
# mechanism before it is a delivery and no cell has an arm for it yet. The near material ring is put
# on `Direct` for the window so the two mechanisms are not ticked at once and the cost measured here
# is the atlas's own.
func atlas_entry() -> Dictionary:
	return (settings().get("clipmap_atlas", {}) as Dictionary).get("material", {})

func atlas_settled() -> bool:
	var entry := atlas_entry()
	if entry.is_empty():
		return true
	return int(entry.get("pending_jobs", 0)) == 0 \
			and int(entry.get("current_cells", 0)) >= int(entry.get("cells", 0))

# The material group's delivery path is settled when the blocks are current *and* their baked rects
# have been acknowledged: that is the moment a fragment reads the atlas's material rather than the
# payload evaluation.
func material_atlas_settled() -> bool:
	var entry := atlas_entry()
	if entry.is_empty():
		return true
	return int(entry.get("pending_jobs", 0)) == 0 \
			and int(entry.get("current_cells", 0)) >= int(entry.get("cells", 0)) \
			and int(entry.get("pending_bake_rects", 0)) == 0 \
			and int(entry.get("baked_cells", 0)) >= int(entry.get("current_cells", 0))

# The near field is the finest ring's own cells: the blocks the ground under the camera reads. It is
# the moment the atlas is *usable*, and it is deliberately a separate reading from the whole grid
# being current, because the dependency order fills the finest ring first.
func atlas_near_settled() -> bool:
	var entry := atlas_entry()
	if entry.is_empty():
		return true
	var rings: Array = entry.get("ring_reports", [])
	if rings.is_empty():
		return false
	var finest: Dictionary = rings[0]
	return int(finest.get("current", 0)) >= int(finest.get("cells", 0))

func atlas_window(label: String, p_settled: Callable, p_cap: int) -> Dictionary:
	var frames := 0
	var ms := 0.0
	var peak_ms := 0.0
	var produced := 0
	var upload_bytes := 0
	var block_uploads := 0
	var current := 0
	var pending := 0
	var rows: Array = []
	while frames < p_cap:
		await process_frame
		frames += 1
		# The mechanism's own per-frame cost, which is the column the ring's `vt_clipmap_ms` phase is.
		var started := Time.get_ticks_usec()
		var made := terrain.debug_update_vt_clipmap_atlas(MATERIAL)
		var frame_ms := float(Time.get_ticks_usec() - started) / 1000.0
		ms += frame_ms
		peak_ms = maxf(peak_ms, frame_ms)
		produced += maxi(made, 0)
		var entry := atlas_entry()
		upload_bytes = int(entry.get("upload_bytes", 0))
		block_uploads = int(entry.get("block_uploads", 0))
		current = int(entry.get("current_cells", 0))
		pending = int(entry.get("pending_jobs", 0))
		rows.append({
			"frame": frames,
			"ms": frame_ms,
			"produced": maxi(made, 0),
			"upload_bytes": upload_bytes,
			"block_uploads": block_uploads,
			"current_cells": current,
			"pending_jobs": pending,
		})
		print("CLIPMAP_LOAD_ROW %s frame=%d atlas_ms=%.3f produced=%d upload_bytes=%d block_uploads=%d current=%d pending=%d" % [
			label, frames, frame_ms, maxi(made, 0), upload_bytes, block_uploads, current, pending])
		if p_settled.call():
			break
	var result := {
		"label": label,
		"frames": frames,
		"clipmap_ms": ms,
		"detail_ms": 0.0,
		"peak_ms": peak_ms,
		"produced": produced,
		"upload_bytes": upload_bytes,
		"block_uploads": block_uploads,
		"valid_levels": current,
		"pending_jobs": pending,
		"rows": rows,
	}
	print("CLIPMAP_LOAD %s frames=%d atlas_ms=%.3f peak_ms=%.3f produced=%d upload_bytes=%d block_uploads=%d current=%d pending=%d" % [
		label, frames, ms, peak_ms, produced, upload_bytes, block_uploads, current, pending])
	return result

# The **delivery path's** own window: a cell names `ClipmapAtlas`, so the tick's phase drives the
# atlas and this only *observes* - no `debug_update_vt_clipmap_atlas()` call in the loop. `clipmap_ms`
# is the tick's whole clipmap phase, which is the number a user's frame pays; the per-entry counters
# are the atlas's own.
func delivery_window(label: String, p_settled: Callable, p_cap: int) -> Dictionary:
	var frames := 0
	var ms := 0.0
	var peak_ms := 0.0
	var produced := 0
	var upload_bytes := 0
	var block_uploads := 0
	var current := 0
	var baked := 0
	var pending := 0
	while frames < p_cap:
		await process_frame
		frames += 1
		var frame_ms := float(phases().get("clipmap", 0.0))
		ms += frame_ms
		peak_ms = maxf(peak_ms, frame_ms)
		produced += int(settings().get("clipmap_atlas_produced_texels", 0))
		var entry := atlas_entry()
		upload_bytes = int(entry.get("upload_bytes", 0))
		block_uploads = int(entry.get("block_uploads", 0))
		current = int(entry.get("current_cells", 0))
		baked = int(entry.get("baked_cells", 0))
		pending = int(entry.get("pending_jobs", 0))
		print("CLIPMAP_LOAD_ROW %s frame=%d atlas_ms=%.3f produced=%d upload_bytes=%d block_uploads=%d current=%d baked=%d pending=%d" % [
			label, frames, frame_ms, int(settings().get("clipmap_atlas_produced_texels", 0)),
			upload_bytes, block_uploads, current, baked, pending])
		if p_settled.call():
			break
	var result := {
		"label": label,
		"frames": frames,
		"clipmap_ms": ms,
		"peak_ms": peak_ms,
		"produced": produced,
		"upload_bytes": upload_bytes,
		"block_uploads": block_uploads,
		"current": current,
		"baked": baked,
		"pending_jobs": pending,
	}
	print("CLIPMAP_LOAD %s frames=%d atlas_ms=%.3f peak_ms=%.3f produced=%d upload_bytes=%d block_uploads=%d current=%d baked=%d pending=%d" % [
		label, frames, ms, peak_ms, produced, upload_bytes, block_uploads, current, baked, pending])
	return result

# The rolling evidence, read off the mechanism after a scroll: how many blocks entered the grid and
# how many cells kept the content they had. "Only the edge reloads" is this pair of numbers.
func atlas_roll_report(label: String) -> Dictionary:
	var entry := atlas_entry()
	var report := {
		"label": label,
		"scroll_events": int(entry.get("scroll_events", 0)),
		"blocks_loaded": int(entry.get("blocks_loaded", 0)),
		"blocks_retained": int(entry.get("blocks_retained", 0)),
		"last_loaded": int(entry.get("last_scroll_loaded", 0)),
		"last_retained": int(entry.get("last_scroll_retained", 0)),
		"cells": int(entry.get("cells", 0)),
		"layout": entry.get("layout", {}),
	}
	print("CLIPMAP_LOAD_ROLL %s scroll_events=%d loaded=%d retained=%d last_loaded=%d last_retained=%d cells=%d" % [
		label, int(report["scroll_events"]), int(report["blocks_loaded"]),
		int(report["blocks_retained"]), int(report["last_loaded"]),
		int(report["last_retained"]), int(report["cells"])])
	return report

func setup() -> void:
	root.name = "ClipmapLoadProbe"
	scene = Node3D.new()
	scene.name = "Scene"
	root.add_child(scene)
	await process_frame

	camera = Camera3D.new()
	camera.position = Vector3(0.0, 12.0, 14.0)
	camera.rotation_degrees = Vector3(-40.0, 0.0, 0.0)
	camera.fov = 70.0
	camera.current = true
	root.add_child(camera)

	terrain = Terrain3D.new()
	terrain.region_size = 64
	terrain.free_editor_textures = false
	terrain.surface_svt_auto_bake = false
	terrain.vt_page_fade_frames = 0
	# The user's path: the near material group on Clipmap, and the shipped shape of the ring.
	terrain.vt_delivery_near_material = CLIPMAP
	terrain.vt_delivery_near_height = DIRECT
	terrain.vt_delivery_far_material = DIRECT
	terrain.vt_delivery_far_height = DIRECT
	terrain.vt_clipmap_size = 256
	terrain.vt_clipmap_levels = 4
	terrain.vt_clipmap_base_world = 256.0
	terrain.vt_clipmap_budget_texels = 256 * 256
	add_assets()
	terrain.set_camera(camera)
	terrain.set_clipmap_target(camera)
	scene.add_child(terrain)
	terrain.set_plugin(self)
	painter = Terrain3DEditor.new()
	painter.set_terrain(terrain)
	terrain.set_editor(painter)
	brush = Image.create(16, 16, false, Image.FORMAT_RF)
	brush.fill(Color.WHITE)
	for z in range(-1, 2):
		for x in range(-1, 2):
			terrain.data.add_region_blank(Vector2i(x, z), false)
	terrain.data.update_maps()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 1:
		output_dir = args[1]
	DirAccess.make_dir_recursive_absolute(output_dir)
	await setup()

	# The first fill, measured from the first tick the terrain exists on. The window stops when the
	# coarse ring and its bakes have settled, which is the "the near material is there" moment.
	var first: Dictionary = await window("first", Callable(self, "ring_settled"), LOAD_CAP)
	# And then the detail layer, which is the half of the near field the coarse ring is not.
	var detail: Dictionary = await window("detail", Callable(self, "detail_settled"), LOAD_CAP)
	await settle(10)

	# A scroll: 3 m forward. The ring loses and gains strips; the counters say what that cost.
	camera.position = Vector3(camera.position.x + 3.0, camera.position.y, camera.position.z - 2.0)
	var scroll: Dictionary = await window("scroll", Callable(self, "ring_settled"), LOAD_CAP)
	await window("scroll_detail", Callable(self, "detail_settled"), LOAD_CAP)
	await settle(10)

	print("CLIPMAP_LOAD_TABLE first_frames=%d first_clipmap_ms=%.3f first_upload_bytes=%d first_bakes=%d detail_frames=%d detail_ms=%.3f scroll_frames=%d scroll_clipmap_ms=%.3f scroll_upload_delta=%d" % [
		int(first["frames"]), float(first["clipmap_ms"]), int(first["upload_bytes"]),
		int(first["bake_dispatches"]), int(detail["frames"]), float(detail["detail_ms"]),
		int(scroll["frames"]), float(scroll["clipmap_ms"]),
		int(scroll["upload_bytes"]) - int(first["upload_bytes"])])

	# The atlas mechanism, when the build has one: the same two windows through its own counters. The
	# material ring is put on `Direct` first so the two mechanisms are not driven at once and the
	# number measured is the atlas's own.
	if terrain.has_method("debug_update_vt_clipmap_atlas"):
		var built: int = terrain.call("debug_update_vt_clipmap_atlas", MATERIAL)
		terrain.vt_delivery_near_material = DIRECT
		await settle(4)
		camera.position = Vector3(0.0, 12.0, 14.0)
		await settle(2)
		if built >= 0:
			# The near field first, then the whole grid: the two are different questions and the
			# dependency order is chosen for the first of them.
			var atlas_near: Dictionary = await atlas_window("atlas_near", Callable(self, "atlas_near_settled"), LOAD_CAP)
			var atlas_first: Dictionary = await atlas_window("atlas_first", Callable(self, "atlas_settled"), LOAD_CAP)
			await window("atlas_detail", Callable(self, "detail_settled"), LOAD_CAP)
			# A scroll inside a block first: a phase turn, which loads nothing at all. Then a scroll of
			# exactly one block: `base_world` metres, which is what relabels the grid. The two are the
			# whole rolling claim, and they are different numbers.
			var block_world := float(terrain.vt_clipmap_base_world)
			var texel_world := block_world / float(terrain.vt_clipmap_size)
			var before_phase := atlas_entry()
			camera.position = Vector3(camera.position.x + texel_world * 4.0, camera.position.y, camera.position.z)
			var phase_window: Dictionary = await atlas_window("atlas_scroll_phase", Callable(self, "atlas_settled"), 4)
			var after_phase := atlas_entry()
			print("CLIPMAP_LOAD_ATLAS_PHASE frames=%d produced=%d upload_delta=%d scrolls=%d" % [
				int(phase_window["frames"]), int(phase_window["produced"]),
				int(after_phase.get("upload_bytes", 0)) - int(before_phase.get("upload_bytes", 0)),
				int(after_phase.get("scroll_events", 0))])
			camera.position = Vector3(camera.position.x + block_world, camera.position.y, camera.position.z)
			var atlas_scroll: Dictionary = await atlas_window("atlas_scroll", Callable(self, "atlas_settled"), LOAD_CAP)
			var roll := atlas_roll_report("after_one_block_scroll")
			print("CLIPMAP_LOAD_ATLAS_TABLE near_frames=%d near_ms=%.3f first_frames=%d first_ms=%.3f first_upload_bytes=%d first_blocks=%d phase_produced=%d phase_upload_delta=%d scroll_frames=%d scroll_ms=%.3f scroll_upload_delta=%d scroll_loaded=%d scroll_retained=%d" % [
				int(atlas_near["frames"]), float(atlas_near["clipmap_ms"]),
				int(atlas_first["frames"]), float(atlas_first["clipmap_ms"]), int(atlas_first["upload_bytes"]),
				int(atlas_first["block_uploads"]), int(phase_window["produced"]),
				int(after_phase.get("upload_bytes", 0)) - int(before_phase.get("upload_bytes", 0)),
				int(atlas_scroll["frames"]), float(atlas_scroll["clipmap_ms"]),
				int(atlas_scroll["upload_bytes"]) - int(atlas_first["upload_bytes"]),
				int(roll["last_loaded"]), int(roll["last_retained"])])
			var layout: Dictionary = roll["layout"]
			print("CLIPMAP_LOAD_LAYOUT width=%d height=%d area=%d chosen=%s blocks=%d ring_blocks=%s packed=%d efficiency=%.4f lower_bound=%d schemes=%s" % [
				int(layout.get("width", 0)), int(layout.get("height", 0)), int(layout.get("area", 0)),
				str(layout.get("chosen", "?")), int(layout.get("blocks", 0)),
				str(layout.get("ring_blocks", [])), int(layout.get("packed_texels", 0)),
				float(layout.get("efficiency", 0.0)), int(layout.get("lower_bound_area", 0)),
				str(layout.get("schemes", [])).replace("\n", " ")])
		else:
			print("CLIPMAP_LOAD_ATLAS_SKIPPED no atlas source for the material group")

	# ---- D. The delivery path ---------------------------------------------------------------------
	# The measurement the user's report is about: a *cell* names `ClipmapAtlas`, the tick's own phase
	# drives it, and this only observes - no `debug_update_vt_clipmap_atlas()` call in the loop. The
	# near material's whole chain is here: the atlas's first fill (its cells current *and* their baked
	# rects acknowledged), the detail layer's own fill, and the two scrolls.
	terrain.vt_delivery_near_material = CLIPMAP_ATLAS
	await settle(6)
	camera.position = Vector3(0.0, 12.0, 14.0)
	await settle(2)
	# The atlas object is a residency cache and was filled by the mechanism section above, so the
	# delivery fill below is measured as a *delta*: the camera is moved back to the start, which
	# relabels the grid under the selected cell, and the window reports what the tick's own phase
	# produced for that move. The mechanism section's table is the object's true first fill.
	var before_delivery := atlas_entry()
	var d_near: Dictionary = await delivery_window("delivery_near", Callable(self, "atlas_near_settled"), LOAD_CAP)
	var d_first: Dictionary = await delivery_window("delivery_first", Callable(self, "material_atlas_settled"), LOAD_CAP)
	var d_detail: Dictionary = await window("delivery_detail", Callable(self, "detail_settled"), LOAD_CAP)
	print("CLIPMAP_LOAD_DELIVERY_TABLE near_frames=%d near_ms=%.3f first_frames=%d first_ms=%.3f first_peak_ms=%.3f first_delta_bytes=%d first_delta_blocks=%d detail_frames=%d detail_ms=%.3f chain_frames=%d" % [
		int(d_near["frames"]), float(d_near["clipmap_ms"]),
		int(d_first["frames"]), float(d_first["clipmap_ms"]), float(d_first["peak_ms"]),
		int(d_first["upload_bytes"]) - int(before_delivery.get("upload_bytes", 0)),
		int(d_first["block_uploads"]) - int(before_delivery.get("block_uploads", 0)),
		int(d_detail["frames"]), float(d_detail["detail_ms"]),
		int(d_first["frames"]) + int(d_detail["frames"])])
	# A scroll inside a block: the phase turns and the atlas produces nothing at all.
	var block_world := float(terrain.vt_clipmap_base_world)
	var texel_world := block_world / float(terrain.vt_clipmap_size)
	var before_phase := atlas_entry()
	camera.position = Vector3(camera.position.x + texel_world * 4.0, camera.position.y, camera.position.z)
	var d_phase: Dictionary = await delivery_window("delivery_scroll_phase", Callable(self, "atlas_settled"), 4)
	var after_phase := atlas_entry()
	# A whole-block scroll: only the blocks that entered are loaded, block by block, one a frame.
	camera.position = Vector3(camera.position.x + block_world, camera.position.y, camera.position.z)
	var d_scroll: Dictionary = await delivery_window("delivery_scroll", Callable(self, "material_atlas_settled"), LOAD_CAP)
	var d_roll := atlas_roll_report("delivery_after_one_block_scroll")
	var d_scroll_detail: Dictionary = await window("delivery_scroll_detail", Callable(self, "detail_settled"), LOAD_CAP)
	print("CLIPMAP_LOAD_DELIVERY_ROLL phase_frames=%d phase_produced=%d phase_upload_delta=%d scroll_frames=%d scroll_upload_delta=%d roll_loaded=%d roll_retained=%d scroll_detail_frames=%d" % [
		int(d_phase["frames"]), int(d_phase["produced"]),
		int(after_phase.get("upload_bytes", 0)) - int(before_phase.get("upload_bytes", 0)),
		int(d_scroll["frames"]), int(d_scroll["upload_bytes"]) - int(d_first["upload_bytes"]),
		int(d_roll["last_loaded"]), int(d_roll["last_retained"]), int(d_scroll_detail["frames"])])
	if terrain != null:
		terrain.set_process(false)
		terrain.set_physics_process(false)
		terrain.set_editor(null)
		terrain.set_plugin(null)
	if painter != null:
		painter.free()
	if scene != null:
		scene.queue_free()
	if camera != null:
		camera.queue_free()
	await process_frame
	await process_frame
	if failed:
		print("REGRESSION: clipmap load evidence")
		quit(1)
		return
	print("PASS clipmap load evidence")
	quit(0)
