extends SceneTree

const ClipmapCache = preload("../passes/magic_gi_clv_cache.gd")
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
	var cache: RefCounted = ClipmapCache.new()
	cache.resolution = TEST_RESOLUTION
	return cache

func _all_in_window(cache: RefCounted, cells: Array) -> bool:
	for cell: Vector4i in cells:
		if cell.w < 0 or cell.w >= ClipmapCache.LEVELS:
			return false
		var origin: Vector3i = cache._origins[cell.w]
		if not ClipmapCache._contains(origin, Vector3i(cell.x, cell.y, cell.z), TEST_RESOLUTION):
			return false
	return true

func run() -> void:
	check(RenderingServer.get_rendering_device() == null,
		"cold queue scheduler fixture must run without a RenderingDevice")
	var total_cells := TEST_RESOLUTION * TEST_RESOLUTION \
			* TEST_RESOLUTION * ClipmapCache.LEVELS

	# A fresh cache schedules one full window. A content refresh against the
	# already-pending window must not duplicate any cell.
	var reset_cache: RefCounted = _new_cache()
	reset_cache.queue_updates(Vector3.ZERO, 0.25, 7)
	check(reset_cache.queue_content_refresh(12) == 0,
		"content refresh is deduped against the pending full window")
	var reset_jobs: Array[Vector4i] = reset_cache.take_jobs(total_cells + 1)
	check(reset_jobs.size() == total_cells and _all_in_window(reset_cache, reset_jobs),
		"initial reset schedules every current cell exactly once")
	check(reset_cache._content_revision == 12,
		"the initial full sweep records the content revision it covered")
	check(reset_cache._pending.is_empty() and reset_cache._pending_set.is_empty() \
			and reset_cache._cursor == 0,
		"draining the full window clears the pending queue, dedupe set and cursor")

	# A later content revision schedules a fresh full window; repeating the same
	# revision is a no-op.
	var refresh_enqueued: int = reset_cache.queue_content_refresh(13)
	var refresh_jobs: Array[Vector4i] = reset_cache.take_jobs(total_cells + 1)
	check(refresh_enqueued == total_cells and refresh_jobs.size() == total_cells \
			and _all_in_window(reset_cache, refresh_jobs),
		"a new content revision schedules exactly one full replacement window")
	check(reset_cache.queue_content_refresh(13) == 0,
		"the current content revision is consumed exactly once")

	# A one-cell finest-level scroll must enqueue only the entering X slab.
	var scrolling: RefCounted = _new_cache()
	scrolling.queue_updates(Vector3.ZERO, 0.25, 7)
	var initial_jobs: Array[Vector4i] = scrolling.take_jobs(total_cells + 1)
	check(initial_jobs.size() == total_cells,
		"scroll fixture starts from a fully consumed window")
	scrolling.queue_updates(Vector3(0.25, 0.0, 0.0), 0.25, 7)
	var entering_jobs: Array[Vector4i] = scrolling.take_jobs(total_cells + 1)
	var expected_entering := TEST_RESOLUTION * TEST_RESOLUTION
	var entering_matches := entering_jobs.size() == expected_entering
	for cell: Vector4i in entering_jobs:
		if cell.w != 0 or cell.x != scrolling._origins[0].x + TEST_RESOLUTION - 1:
			entering_matches = false
	check(entering_matches,
		"a one-cell finest-level scroll enqueues exactly the entering recycled slab")

	# A full-resolution X wrap must enqueue every old-window cell that is no
	# longer inside the new window, and nothing outside it.
	var wrapping: RefCounted = _new_cache()
	wrapping.queue_updates(Vector3.ZERO, 0.25, 22)
	var old_window: Array[Vector4i] = wrapping.take_jobs(total_cells + 1)
	check(old_window.size() == total_cells,
		"wrap fixture starts from a fully consumed window")
	var old_origins: Array[Vector3i] = wrapping._origins.duplicate()
	wrapping.queue_updates(Vector3(float(TEST_RESOLUTION) * 0.25, 0.0, 0.0), 0.25, 22)
	var new_origins: Array[Vector3i] = wrapping._origins
	var expected_wrap_entering := 0
	for level in ClipmapCache.LEVELS:
		for x in TEST_RESOLUTION:
			for y in TEST_RESOLUTION:
				for z in TEST_RESOLUTION:
					var cell := Vector3i(old_origins[level].x + x,
							old_origins[level].y + y, old_origins[level].z + z)
					if not ClipmapCache._contains(new_origins[level], cell, TEST_RESOLUTION):
						expected_wrap_entering += 1
	var wrapped_jobs: Array[Vector4i] = wrapping.take_jobs(total_cells + 1)
	check(wrapped_jobs.size() == expected_wrap_entering \
			and _all_in_window(wrapping, wrapped_jobs),
		"logical full-wrap schedules every entering slab at every level")

	# Epoch invalidation clears the pending queue and schedules a fresh window.
	var epoch_cache: RefCounted = _new_cache()
	epoch_cache.queue_updates(Vector3.ZERO, 0.25, 7)
	epoch_cache.take_jobs(total_cells + 1)
	epoch_cache.queue_updates(Vector3.ZERO, 0.25, 8)
	var epoch_jobs: Array[Vector4i] = epoch_cache.take_jobs(total_cells + 1)
	check(epoch_jobs.size() == total_cells and epoch_cache._geometry_epoch == 8 \
			and _all_in_window(epoch_cache, epoch_jobs),
		"geometry epoch invalidation schedules every current cell without stale work")
	check(epoch_cache.queue_content_refresh(14) == total_cells,
		"the first content revision after an epoch reset schedules one full sweep")
	epoch_cache.take_jobs(total_cells + 1)
	check(epoch_cache.queue_content_refresh(14) == 0,
		"the post-reset content revision is consumed exactly once")

	# Fast travel can grow stale entering-slab jobs past the periodic compaction
	# threshold. The compactor must retain exactly the current pending window,
	# rebuild the dedupe set, and reset its cursor before future dispatches.
	var compacting: RefCounted = _new_cache()
	compacting.queue_updates(Vector3.ZERO, 0.25, 21)
	var initially_submitted: Array[Vector4i] = compacting.take_jobs(6000)
	check(initially_submitted.size() == 6000,
		"compaction fixture starts from a partially consumed window")
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
		if cell.w < 0 or cell.w >= ClipmapCache.LEVELS \
				or not ClipmapCache._contains(compacting._origins[cell.w],
					Vector3i(cell.x, cell.y, cell.z), TEST_RESOLUTION):
			compact_all_in_window = false
	var compact_queue_matches_set: bool = compact_pending_set.size() == compacting._pending_set.size()
	for cell in compact_pending_set:
		if not compacting._pending_set.has(cell):
			compact_queue_matches_set = false
	var compact_jobs: Array[Vector4i] = compacting.take_jobs(total_cells + 1)
	var compact_job_set: Dictionary = {}
	for cell in compact_jobs:
		compact_job_set[cell] = true
	# After draining, take_jobs() must have erased every pending cell from both the
	# queue and its dedupe set. Because all pre-drain pending cells were in-window
	# and deduped, a unique drained count of total_cells implies compact_job_set is
	# exactly the current window; a separate window-set comparison is redundant.
	check(compaction_seen and compact_scroll_steps > TEST_RESOLUTION \
			and compacting._cursor == 0 and compact_queue_matches_set \
			and compact_all_in_window and compact_job_set.size() == total_cells \
			and compacting._pending.is_empty() and compacting._pending_set.is_empty(),
		"periodic compaction preserves every current pending cell, dedupe entry, and queue cursor")

	print("MAGIC_GI_CLV_COLD_QUEUE checks=%d failures=%d cells=%d compaction_steps=%d wrap_entering=%d" % [
		checks, failures, total_cells, compact_scroll_steps, expected_wrap_entering])
	quit(1 if failures > 0 else 0)
