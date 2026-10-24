extends SceneTree

const BakedCache = preload("../passes/magic_gi_baked_sh_clv_cache.gd")
const TEST_RESOLUTION := 32

var checks := 0
var failures := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func _new_cache() -> RefCounted:
	var cache: RefCounted = BakedCache.new()
	cache.resolution = TEST_RESOLUTION
	return cache

func run() -> void:
	check(RenderingServer.get_rendering_device() == null,
		"cold queue scheduler fixture must run without a RenderingDevice")
	var total_cells := TEST_RESOLUTION * TEST_RESOLUTION \
			* TEST_RESOLUTION * BakedCache.LEVELS

	# Compare the optimized first geometry reset to the previous three full-window
	# sweeps. _pending_set deduplicates insertion but the queue order must match.
	var old_reset_usec := Time.get_ticks_usec()
	var old_reset: RefCounted = _new_cache()
	old_reset.queue_updates(Vector3.ZERO, 0.25, 7)
	old_reset.queue_content_refresh(12)
	old_reset._boundary_tensor_refresh_pending = true
	old_reset._queue_boundary_tensor_refresh()
	var old_reset_cells: Array[Vector4i] = old_reset._current_cells()
	for cell in old_reset_cells:
		old_reset._slot_owners[old_reset._slot_key(cell)] = cell
	old_reset_usec = Time.get_ticks_usec() - old_reset_usec
	var old_reset_jobs: Array[Vector4i] = old_reset.take_jobs(total_cells + 1)
	var new_reset_usec := Time.get_ticks_usec()
	var new_reset: RefCounted = _new_cache()
	new_reset.queue_updates(Vector3.ZERO, 0.25, 7)
	new_reset._boundary_tensor_refresh_pending = true
	new_reset._record_full_reset_slot_owners()
	new_reset._queue_refreshes_after_origin_update(true, 12)
	new_reset_usec = Time.get_ticks_usec() - new_reset_usec
	var new_reset_jobs: Array[Vector4i] = new_reset.take_jobs(total_cells + 1)
	check(old_reset_jobs.size() == total_cells and old_reset_jobs == new_reset_jobs,
		"geometry reset keeps the same full-window job order while skipping duplicate refresh sweeps")
	check(new_reset._content_revision == 12 and not new_reset._boundary_tensor_refresh_pending,
		"the initial sweep records the content and boundary snapshot it already covers")

	# Later content and sidecar invalidations still enqueue the same work in the
	# same order when the geometry is stable.
	var old_refresh: RefCounted = _new_cache()
	old_refresh.queue_updates(Vector3.ZERO, 0.25, 7)
	old_refresh.take_jobs(total_cells + 1)
	old_refresh.queue_content_refresh(13)
	old_refresh._boundary_tensor_refresh_pending = true
	old_refresh._queue_boundary_tensor_refresh()
	var old_refresh_jobs: Array[Vector4i] = old_refresh.take_jobs(total_cells + 1)
	var new_refresh: RefCounted = _new_cache()
	new_refresh.queue_updates(Vector3.ZERO, 0.25, 7)
	new_refresh.take_jobs(total_cells + 1)
	new_refresh._boundary_tensor_refresh_pending = true
	new_refresh._queue_refreshes_after_origin_update(false, 13)
	var new_refresh_jobs: Array[Vector4i] = new_refresh.take_jobs(total_cells + 1)
	check(old_refresh_jobs.size() == total_cells and old_refresh_jobs == new_refresh_jobs,
		"later content and boundary invalidations retain the full-window refresh sequence")

	# A settled cache needs no recycled-slot scan. A one-cell L0 scroll produces
	# one entering slab; a failed dispatch leaves the dirty state retryable.
	var scrolling: RefCounted = _new_cache()
	scrolling.queue_updates(Vector3.ZERO, 0.25, 7)
	var initial_jobs: Array[Vector4i] = scrolling.take_jobs(total_cells + 1)
	for cell in initial_jobs:
		scrolling._slot_owners[scrolling._slot_key(cell)] = cell
	var stable_before: int = scrolling._recycled_slot_scan_count
	check(scrolling._collect_recycled_slots_for_update(false, false).is_empty()
			and scrolling._recycled_slot_scan_count == stable_before,
		"stable origins skip the pending-slot scan entirely")
	scrolling.queue_updates(Vector3(0.25, 0.0, 0.0), 0.25, 7)
	var entering: Array[Vector4i] = scrolling._collect_recycled_slots_for_update(true, false)
	var expected_entering := TEST_RESOLUTION * TEST_RESOLUTION
	check(entering.size() == expected_entering and entering.all(
		func(cell: Vector4i) -> bool:
			return cell.w == 0 and cell.x == scrolling._origins[0].x + TEST_RESOLUTION - 1),
		"a one-cell finest-level scroll clears exactly the entering recycled slab")
	var retry: Array[Vector4i] = scrolling._collect_recycled_slots_for_update(false, false)
	check(retry == entering,
		"a failed clear/fill dispatch keeps recycled-slot clears pending for retry")
	scrolling._commit_recycled_slot_scan()
	var stable_after: int = scrolling._recycled_slot_scan_count
	check(scrolling._collect_recycled_slots_for_update(false, false).is_empty()
			and scrolling._recycled_slot_scan_count == stable_after,
		"successful slot ownership publication clears the dirty scan state")

	# Epoch invalidation must queue a fresh window, assign current slot ownership,
	# and avoid recycled clears because the full field reset handles all slots.
	scrolling.queue_updates(Vector3.ZERO, 0.25, 8)
	scrolling._record_full_reset_slot_owners()
	var epoch_clears: Array[Vector4i] = scrolling._collect_recycled_slots_for_update(false, true)
	var epoch_jobs: Array[Vector4i] = scrolling.take_jobs(total_cells + 1)
	check(epoch_clears.is_empty() and epoch_jobs.size() == total_cells
			and scrolling._geometry_epoch == 8,
		"geometry epoch invalidation clears all fields and schedules every current cell without slot recycles")
	scrolling._queue_refreshes_after_origin_update(true, 14)
	check(scrolling.queue_content_refresh(14) == 0,
		"the post-reset full sweep consumes the current revision exactly once")

	# Fast travel can grow stale entering-slab jobs past the periodic compaction
	# threshold. The compactor must retain exactly the current pending window,
	# rebuild the dedupe set, and reset its cursor before future dispatches.
	var compacting: RefCounted = _new_cache()
	compacting.queue_updates(Vector3.ZERO, 0.25, 21)
	var initially_submitted: Array[Vector4i] = compacting.take_jobs(6000)
	for cell in initially_submitted:
		compacting._slot_owners[compacting._slot_key(cell)] = cell
	var compact_camera := Vector3.ZERO
	var prior_pending_size: int = compacting._pending.size()
	var compaction_seen := false
	var compact_scroll_steps := 0
	for scroll_step in 128:
		compact_camera.x += 0.25
		compacting.queue_updates(compact_camera, 0.25, 21)
		compact_scroll_steps = scroll_step + 1
		var current_pending_size: int = compacting._pending.size()
		if current_pending_size < prior_pending_size:
			compaction_seen = true
			break
		prior_pending_size = current_pending_size
	var compact_pending_set: Dictionary = {}
	var compact_all_in_window := true
	for cell in compacting._pending:
		compact_pending_set[cell] = true
		if cell.w < 0 or cell.w >= BakedCache.LEVELS \
				or not compacting._contains(compacting._origins[cell.w], Vector3i(cell.x, cell.y, cell.z), TEST_RESOLUTION):
			compact_all_in_window = false
	var compact_queue_matches_set: bool = compact_pending_set.size() == compacting._pending_set.size()
	for cell in compact_pending_set:
		if not compacting._pending_set.has(cell):
			compact_queue_matches_set = false
	var compact_jobs: Array[Vector4i] = compacting.take_jobs(total_cells + 1)
	var compact_job_set: Dictionary = {}
	for cell in compact_jobs:
		compact_job_set[cell] = true
	var current_window: Array[Vector4i] = compacting._current_cells()
	var compaction_job_set_matches: bool = compact_job_set.size() == current_window.size()
	for cell in current_window:
		if not compact_job_set.has(cell):
			compaction_job_set_matches = false
	check(compaction_seen and compact_scroll_steps > TEST_RESOLUTION \
			and compacting._cursor == 0 and compact_queue_matches_set \
			and compact_all_in_window and compact_job_set.size() == total_cells \
			and compaction_job_set_matches and compacting._pending.is_empty() \
			and compacting._pending_set.is_empty(),
		"periodic compaction preserves every current pending cell, dedupe entry, and queue cursor")

	# A full-resolution X wrap maps new logical cells onto prior physical slots.
	# All entering cells must request clears across the three per-level shifts.
	var wrapping: RefCounted = _new_cache()
	wrapping.queue_updates(Vector3.ZERO, 0.25, 22)
	var old_window: Array[Vector4i] = wrapping.take_jobs(total_cells + 1)
	for cell in old_window:
		wrapping._slot_owners[wrapping._slot_key(cell)] = cell
	wrapping.queue_updates(Vector3(float(TEST_RESOLUTION) * 0.25, 0.0, 0.0), 0.25, 22)
	var wrapped_clear: Array[Vector4i] = wrapping._collect_recycled_slots_for_update(true, false)
	var expected_wrap_clear: int = TEST_RESOLUTION * TEST_RESOLUTION * (TEST_RESOLUTION + TEST_RESOLUTION / 2 + TEST_RESOLUTION / 4)
	var wrap_owners_match := true
	for cell in wrapped_clear:
		var owner: Variant = wrapping._slot_owners.get(wrapping._slot_key(cell))
		if not owner is Vector4i or owner == cell:
			wrap_owners_match = false
	check(wrapped_clear.size() == expected_wrap_clear and wrap_owners_match,
		"logical full-wrap entering slabs clear their old physical slot owners at every level")
	wrapping._commit_recycled_slot_scan()
	var wrap_scan_count: int = wrapping._recycled_slot_scan_count
	check(wrapping._collect_recycled_slots_for_update(false, false).is_empty() \
			and wrapping._recycled_slot_scan_count == wrap_scan_count,
		"successful full-wrap ownership commit returns to the stable-origin fast path")

	print("MAGICDAWN_BAKED_CLV_COLD_QUEUE checks=%d failures=%d cells=%d old_reset_usec=%d new_reset_usec=%d compaction_steps=%d wrap_clear=%d" % [
		checks, failures, total_cells, old_reset_usec, new_reset_usec, compact_scroll_steps, wrapped_clear.size()])
	quit(1 if failures > 0 else 0)
