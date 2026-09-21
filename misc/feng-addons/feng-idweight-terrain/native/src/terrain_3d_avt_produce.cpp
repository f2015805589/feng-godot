// Terrain3D's near field, part 5 of 5: the production pass.

// One of five files that own the near field. This is the one production pass per tick, split out
// of terrain_3d_sector_avt.cpp: classify the standing plan, retain the source queue, prime the
// workers, publish what fits the budget, commit, and report what it cost. The planning chain that
// produced the plan, the sector scan and the address directory are in terrain_3d_sector_avt.cpp.
//
// The other four: `terrain_3d_sector_avt.cpp` (the driver and its configuration),
// `terrain_3d_sector_avt_motion.cpp` (the lead and the plan key), `terrain_3d_sector_avt_hierarchy.cpp`
// (the scan, the hierarchy and the address directory) and `terrain_3d_avt_plan.cpp` (the worker
// whose plan this pass consumes).
#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_vt_visibility.h"
#include "terrain_vt_request_priority.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <queue>
#include <tuple>
#include <unordered_set>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/time.hpp>

namespace {
// The source queue's window is 32 entries. A prime leaves the queue alone while this many are still
// claimable, because those are requests the workers have not reached yet: adding to a half-full
// queue re-scans it and inserts nothing, at the cost of the queue mutex, behind the workers that
// are holding it. `_avt_retain_visible()` has already dropped everything the current plan does not
// name, so a queue this deep is current-plan work either way.
constexpr int SOURCE_QUEUE_REFILL_ABOVE = 16;
// FNV-1a over one page address. The demand-age map is keyed by this, so a collision
// would only mis-age a diagnostic counter, never a page.
uint64_t avt_page_age_key(const Terrain3DAVTPageRequest &p_page) {
	uint64_t key = 1469598103934665603ull;
	for (const uint32_t word : { uint32_t(p_page.owner.x), uint32_t(p_page.owner.y),
			uint32_t(p_page.mip), uint32_t(p_page.x), uint32_t(p_page.y) }) {
		key = (key ^ word) * 1099511628211ull;
	}
	return key;
}
}

// The near field's one production pass per tick: verify the standing plan, classify it into
// resident and missing pages, retain the source queue, prime the workers, publish what fits
// the budget, and commit. The tick calls it exactly once, so every stage above is paid once
// per tick rather than once per caller.
int Terrain3D::_produce_sector_avt_pages(int p_max_pages) {
	if (p_max_pages == 0) { return 0; }
	p_max_pages = p_max_pages < 0 ? 16 : MIN(p_max_pages, 16);
	const auto pool = _vt.surface_vt->get_page_pool();
	// A repeated plan with nothing left to upload still has to re-mark its resident
	// pages as demanded, or the pool evicts them while the camera is stationary.
	//
	// The cached state is only idle while every page it holds still has content. A page
	// whose production was lost after this state was reached - an encode that failed, a job
	// dropped by the bundle rebuild that changed the producer's generation - keeps its
	// indirection entry and its demand record, so the shader samples an empty layer and no
	// other part of the pipeline would ever look at it again: the plan is reused and the
	// pool's residency did not move, which is exactly the condition this shortcut tests.
	// When the cached state is a candidate for the settled shortcut, readiness is verified here
	// and not assumed. The cost is one lookup per resident slot, on the loop that already touches
	// every one of them.
	const Terrain3DSurfaceBaker *idle_producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	const bool idle_candidate = _vt.avt_settled.can_run(pool->residency_revision);
	int idle_lost = 0;
	if (idle_candidate && idle_producer) {
		// One lock for the whole resident set: the per-slot query is the same read, and this
		// loop is the one a settled view runs on every tick.
		idle_lost = idle_producer->count_unready_pages(_vt.avt_settled.slots);
	}
	if (idle_candidate && idle_lost == 0) {
		for (int slot : _vt.avt_settled.slots) { pool->mark_demanded(slot); }
		// Only the first tick of an idle run publishes: every value below is a constant of
		// the settled state, and rewriting the same numbers into a String-keyed dictionary
		// every frame is the largest cost a settled view has left.
		if (!_vt.avt_settled.stats_current) {
			_vt.avt_settled.stats_current = true;
			_vt.avt_sector_stats["produced"] = 0;
			_vt.avt_sector_stats["prefetched"] = 0;
			// An idle pass is only reached once the previous one produced nothing, the residency
			// did not change, and every page above was verified to still have its content.
			_vt.avt_sector_stats["visible_plan_pages"] = _vt.avt_plan.sampled;
			_vt.avt_sector_stats["visible_missing_pages"] = 0;
			_vt.avt_sector_stats["visible_pending_pages"] = 0;
			_vt.avt_sector_stats["visible_late_pages"] = 0;
			_vt.avt_sector_stats["idle_ready_lost"] = 0;
		}
		_vt.avt_late_pages = 0;
		_vt.avt_missing_pages = 0;
		_vt.avt_pending_pages = 0;
		_vt.avt_demand_age.clear();
		return 0;
	}
	// A page the cached state would have called resident is not ready, so this pass runs the
	// real classification and reports what it finds instead of claiming a complete plan. The
	// reading is what tells a lost page under a still camera from a settled view.
	// A moving/non-candidate pass did not perform the idle readiness check, so it reports no
	// lost idle pages rather than carrying a result from an earlier settled pass.
	_vt.avt_sector_stats["idle_ready_lost"] = idle_candidate ? idle_lost : 0;
	// The shortcut's verdict goes with the statistics it published: this pass is about to rebuild
	// the resident set, so the next one has to verify its own.
	_vt.avt_settled.fall_through();
	_vt.surface_vt->set_allocation_budget(p_max_pages > 0 ? p_max_pages : -1);
	if (!_vt.vt_page_pipeline) { _vt.vt_page_pipeline = std::make_unique<Terrain3DPagePipeline>(_vt.vt_page_workers); }
	if (!_vt.vt_source_snapshot) { _vt.vt_source_snapshot = Terrain3DPagePipeline::snapshot(_data, _region_size, _vertex_spacing, _surface_density); }

	Terrain3DAVTProducePass pass;
	// One place to record a stage's cost, so the pass reads as the stages it runs instead of as a
	// sequence of timestamp reassignments. Each stage is named by the key its cost lands under,
	// and summed into the member its mean is read from.
	uint64_t stage_started = Time::get_singleton()->get_ticks_usec();
	auto mark = [this, &stage_started](const char *p_key, double &r_sum) {
		const uint64_t now = Time::get_singleton()->get_ticks_usec();
		const double elapsed_ms = double(now - stage_started) / 1000.0;
		_vt.avt_sector_stats[p_key] = elapsed_ms;
		r_sum += elapsed_ms;
		stage_started = now;
	};
	_avt_classify_plan(pass);
	mark("classify_ms", _vt.avt_classify_sum_ms);
	_avt_retain_visible(pass);
	mark("retain_ms", _vt.avt_retain_sum_ms);
	if (_vt.vt_page_pipeline) {
		// The retention is the largest stage of a pass that installed a plan, and it is two
		// unrelated costs: waiting for the queue's mutex against producing workers, and comparing
		// its entries. Which half it is decides whether the fix is fewer queue acquisitions or a
		// better index, so the split is published instead of being argued about.
		int64_t retain_lock_us = 0;
		int64_t retain_index_us = 0;
		_vt.vt_page_pipeline->get_retain_stats(retain_lock_us, retain_index_us);
		_vt.avt_sector_stats["retain_lock_ms"] = double(retain_lock_us) / 1000.0;
		_vt.avt_sector_stats["retain_index_ms"] = double(retain_index_us) / 1000.0;
	}
	_avt_prime_sources(pass, SOURCE_QUEUE_REFILL_ABOVE);
	mark("prime_ms", _vt.avt_prime_sum_ms);
	_avt_produce_visible(pass, p_max_pages);
	mark("upload_ms", _vt.avt_upload_sum_ms);
	// Refill after consuming ready results even when the render budget is spent, so the workers
	// are not left idle between ticks - but only when the queue is actually running low. A queue
	// that is still half full is work the workers have not reached yet, and re-scanning and
	// re-inserting into it buys nothing.
	_avt_prime_sources(pass, SOURCE_QUEUE_REFILL_ABOVE, true);
	mark("refill_ms", _vt.avt_refill_sum_ms);
	_avt_produce_prefetch(pass, p_max_pages);
	_avt_finish_produce(pass);
	mark("finish_ms", _vt.avt_finish_sum_ms);
	// The stage sums and the count they are summed over, so `report()` can difference two readings
	// and state the mean of one sweep. The live keys above describe the last pass only.
	_vt.avt_pass_count++;
	_vt.avt_sector_stats["passes"] = int64_t(_vt.avt_pass_count);
	_vt.avt_sector_stats["classify_sum_ms"] = _vt.avt_classify_sum_ms;
	_vt.avt_sector_stats["retain_sum_ms"] = _vt.avt_retain_sum_ms;
	_vt.avt_sector_stats["prime_sum_ms"] = _vt.avt_prime_sum_ms;
	_vt.avt_sector_stats["upload_sum_ms"] = _vt.avt_upload_sum_ms;
	_vt.avt_sector_stats["refill_sum_ms"] = _vt.avt_refill_sum_ms;
	_vt.avt_sector_stats["finish_sum_ms"] = _vt.avt_finish_sum_ms;
	return pass.produced;
}

// Sorts the published plan into pages that already have a physical slot - which are
// pinned and marked demanded - and pages that still have to be produced.
void Terrain3D::_avt_classify_plan(Terrain3DAVTProducePass &r_pass) {
	const auto pool = _vt.surface_vt->get_page_pool();
	r_pass.protected_slots.reserve(_vt.avt_plan.pages.size() + 16);
	r_pass.missing.reserve(_vt.avt_plan.pages.size());
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	const int sampled = MIN(_vt.avt_plan.sampled, int(_vt.avt_plan.pages.size()));
	const uint64_t now_us = Time::get_singleton()->get_ticks_usec();
	const uint64_t lead_us = uint64_t(double(MAX(0.f, float(_vt.vt_motion_lead_ms))) * 1000.0);
	// Resolve every page's slot first, then ask the producer about the whole set under one lock.
	// Readiness lives behind the producer's mutex and the walk used to ask it once per page for
	// the sampled answer and again inside the staleness check, so a 250 page plan against a view
	// that is mostly missing took ~500 queue locks to read one array - the stage measured
	// 0.045-0.08 ms and was almost entirely lock traffic. The batched read is the same read of
	// the same array, and `_vt_page_production_stale()` already takes a pre-read answer.
	_vt.avt_verify_slots.clear();
	for (const Terrain3DAVTPageRequest &page : _vt.avt_plan.pages) {
		_vt.avt_verify_slots.push_back(_vt.surface_vt->lookup_page_exact(page.owner, page.mip, page.x, page.y));
	}
	if (producer) {
		producer->query_page_readiness(_vt.avt_verify_slots, _vt.avt_verify_ready);
	} else {
		// Without a producer every resident page counts as ready, which is what the per-page
		// form answered too: it skipped the query entirely.
		_vt.avt_verify_ready.assign(_vt.avt_verify_slots.size(), 1);
	}
	int index = 0;
	size_t plan_index = 0;
	for (const Terrain3DAVTPageRequest &page : _vt.avt_plan.pages) {
		const int slot = plan_index < _vt.avt_verify_slots.size() ? _vt.avt_verify_slots[plan_index] : -1;
		const int slot_ready = plan_index < _vt.avt_verify_ready.size() ? int(_vt.avt_verify_ready[plan_index]) : 0;
		++plan_index;
		if (slot >= 0 && !_vt.surface_vt->is_page_protected(slot)) { _vt.surface_vt->protect_page(slot, true); r_pass.protected_slots.push_back(slot); }
		const bool sampled_ready = slot >= 0 && slot_ready != 0;
		const bool stale = slot >= 0 && !sampled_ready && _vt_page_production_stale(slot, slot_ready);
		if (index++ < sampled) {
			// A page the image samples without content is shaded as the missing-page
			// material; one whose production is still inside its retry window is a
			// pending miss that the next frames resolve.
			r_pass.sampled_plan++;
			if (slot < 0) { r_pass.sampled_missing++; } else if (!sampled_ready) { stale ? r_pass.sampled_missing++ : r_pass.sampled_pending++; }
			// Age the miss from the frame the page was first demanded without content.
			// A page younger than one lead is not late: the plan is ahead of the camera,
			// so the frames it holds in flight are its production window, not a stall.
			const uint64_t age_key = avt_page_age_key(page);
			if (sampled_ready) {
				_vt.avt_demand_age.erase(age_key);
			} else {
				auto found = _vt.avt_demand_age.find(age_key);
				const uint64_t since = found == _vt.avt_demand_age.end() ? now_us : found->second;
				if (found == _vt.avt_demand_age.end()) { _vt.avt_demand_age.emplace(age_key, since); }
				const uint64_t age = now_us - since;
				r_pass.late_worst_us = MAX(r_pass.late_worst_us, int(MIN(age, uint64_t(INT32_MAX))));
				if (age >= lead_us) { r_pass.sampled_late++; }
			}
		}
		if (slot < 0 || stale) { r_pass.missing.push_back(&page); }
		if (slot >= 0) { pool->mark_demanded(slot); _vt.avt_settled.slots.push_back(slot); }
	}
	// A page that left the plan is never checked again, so the map is bounded by a clear
	// whenever the view settles, and by a hard cap if a pathological plan keeps churning.
	if (r_pass.sampled_missing == 0 && r_pass.sampled_pending == 0) { _vt.avt_demand_age.clear(); }
	else if (_vt.avt_demand_age.size() > 8192) { _vt.avt_demand_age.clear(); }
	// Roots must establish coverage first, then the current sampled prefix is ordered by
	// distance bands. This lets a nearby fine page beat a distant coarse page while keeping
	// the parent before its child inside one band; the optional apron and retained requests
	// are last. The plan and the source queue use this same typed order, so a 16-page pass
	// cannot spend its whole budget on speculative coarse work ahead of the rendered view.
	std::stable_sort(r_pass.missing.begin(), r_pass.missing.end(),
			[](const Terrain3DAVTPageRequest *p_left, const Terrain3DAVTPageRequest *p_right) {
				return TerrainVT::page_request_priority_before(p_left->priority, p_right->priority);
			});
}

// Queued idle work must not occupy every source-worker slot while visible requests
// wait for a free entry. Retain only source jobs needed by visible misses until they settle.
void Terrain3D::_avt_retain_visible(const Terrain3DAVTProducePass &p_pass) {
	// A source payload is needed only for a page with no slot, or for a stale slot whose
	// replacement can be polled this pass. Ready resident pages are consumed by the GPU and
	// never polled here; an in-flight, non-stale slot explicitly discards its source result in
	// _avt_produce_page(). Keeping either kind in the queue only occupies one of its 32 entries
	// and makes prime scan more work. Once the visible set has no missing page, retain the warm
	// prefetch set instead. This set only changes when a plan is installed or the prefetch switch
	// flips, so the operation remains off the per-tick hot path after it has been applied.
	const bool with_prefetch = p_pass.missing.empty();
	if (_vt.avt_plan.retained(with_prefetch)) { return; }
	std::vector<Terrain3DPagePipeline::Request> wanted;
	if (with_prefetch) {
		wanted.reserve(_vt.avt_plan.prefetch.size());
		for (const auto &page : _vt.avt_plan.prefetch) { wanted.push_back(_avt_page_request(page)); }
	} else {
		wanted.reserve(p_pass.missing.size());
		for (const Terrain3DAVTPageRequest *page : p_pass.missing) { wanted.push_back(_avt_page_request(*page)); }
	}
	_vt.vt_page_pipeline->retain(wanted);
	_vt.avt_plan.mark_retained(with_prefetch);
}

Terrain3DPagePipeline::Request Terrain3D::_avt_page_request(const Terrain3DAVTPageRequest &p_page) const {
	return Terrain3DPagePipeline::Request{{ p_page.owner.x, p_page.owner.y, p_page.mip, p_page.x, p_page.y }, p_page.rect, _vt.vt_page_size, _vt.vt_page_border };
}

// Gives the source workers the first pages of the missing list that the pass has not attempted, so
// results are ready when the next stage polls them. `p_refill_above` is the point at which the
// queue is already deep enough that there is nothing to do: the second call of a tick passes it, so
// a queue the workers are still working through is not re-scanned and re-inserted into - which
// measured as ~0.15 ms of a peak tick, almost all of it waiting for the queue's mutex.
void Terrain3D::_avt_prime_sources(const Terrain3DAVTProducePass &p_pass, const int p_refill_above, const bool p_refill) {
	if (p_refill_above > 0 && _vt.vt_page_pipeline->claimable_count() >= p_refill_above) { return; }
	std::vector<Terrain3DPagePipeline::Request> requests;
	requests.reserve(32);
	// The readiness snapshot may skip unfinished pages before reaching the end.
	// Refill those holes too; successfully consumed requests are cleared below.
	for (size_t i = p_refill ? 0 : p_pass.missing_next; i < p_pass.missing.size(); ++i) {
		if (!p_pass.missing[i]) { continue; }
		requests.push_back(_avt_page_request(*p_pass.missing[i]));
		if (requests.size() == 32) { break; }
	}
	if (requests.empty()) { return; }
	_vt.vt_page_pipeline->prime(requests, _vt.vt_source_snapshot);
	int64_t insert_us = 0;
	int64_t wake_us = 0;
	int inserted = 0;
	int wakes = 0;
	_vt.vt_page_pipeline->get_prime_stats(insert_us, wake_us);
	_vt.vt_page_pipeline->get_prime_counts(inserted, wakes);
	_vt.avt_sector_stats[p_refill ? "refill_insert_ms" : "prime_insert_ms"] = double(insert_us) / 1000.0;
	_vt.avt_sector_stats[p_refill ? "refill_wake_ms" : "prime_wake_ms"] = double(wake_us) / 1000.0;
	_vt.avt_sector_stats[p_refill ? "refill_inserted" : "prime_inserted"] = inserted;
	_vt.avt_sector_stats[p_refill ? "refill_wakes" : "prime_wakes"] = wakes;
}

// Publishes one prepared page: allocates the slot, writes the payload, queues the
// material copy and pins the slot for the rest of the pass. Returns whether a page
// was produced.
bool Terrain3D::_avt_produce_page(Terrain3DAVTProducePass &r_pass, const Terrain3DAVTPageRequest &p_page, bool p_prefetch) {
	int slot = _vt.surface_vt->lookup_page_exact(p_page.owner, p_page.mip, p_page.x, p_page.y);
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	if (slot >= 0 && (!producer || producer->is_page_ready(slot))) { return false; }
	// A recent exact entry is production already in flight. Re-queueing it would advance the
	// slot sequence every frame and make every async encode completion stale before arrival.
	// Its prepared source is not going to be consumed, though - the producer is filling the
	// slot from the GPU - so the entry is dropped here. Leaving it in the queue is what
	// starved the pages behind it: 32 slots filled with results nobody would ever poll.
	if (slot >= 0 && !_vt_page_production_stale(slot)) {
		_vt.vt_page_pipeline->discard(_avt_page_request(p_page).key);
		return false;
	}
	if (p_prefetch) { r_pass.prefetch_pending = true; }
	Terrain3DPagePipeline::Result prepared;
	if (!_vt.vt_page_pipeline->poll(_avt_page_request(p_page), _vt.vt_source_snapshot, prepared)) {
		r_pass.source_wait++;
		return false;
	}
	const uint64_t allocation_start = Time::get_singleton()->get_ticks_usec();
	if (slot < 0) {
		bool miss = false;
		slot = _vt.surface_vt->request_page_internal(p_page.owner, p_page.mip, p_page.x, p_page.y, &miss);
		if (slot < 0 || !miss) {
			r_pass.slot_wait++;
			return false;
		}
	}
	const uint64_t request_done = Time::get_singleton()->get_ticks_usec();
	_invalidate_vt_slot(slot);
	const uint64_t payload_start = Time::get_singleton()->get_ticks_usec();
	r_pass.allocation_us += payload_start - allocation_start;
	r_pass.request_us += request_done - allocation_start;
	r_pass.invalidate_us += payload_start - request_done;
	Ref<Image> payload = prepared.payload;
	if (payload.is_null() || !_vt.surface_vt->write_page(slot, payload)) {
		_vt.surface_vt->release_page(p_page.owner, p_page.mip, p_page.x, p_page.y);
		return false;
	}
	const uint64_t queue_start = Time::get_singleton()->get_ticks_usec();
	r_pass.payload_us += queue_start - payload_start;
	_queue_vt_material_page(slot, payload, p_page.rect, false, p_page.mip, Vector2i(p_page.x, p_page.y), &prepared);
	r_pass.queue_us += Time::get_singleton()->get_ticks_usec() - queue_start;
	_vt.surface_vt->protect_page(slot, true);
	r_pass.protected_slots.push_back(slot);
	return true;
}

void Terrain3D::_avt_produce_visible(Terrain3DAVTProducePass &r_pass, int p_max_pages) {
	if (r_pass.missing_next >= r_pass.missing.size()) { return; }
	// One bounded readiness snapshot replaces a lock and empty poll for every
	// unprepared page. Preserve the plan's priority; later completions stay queued
	// for the next tick, and prime/refill still feed the asynchronous workers.
	const auto ready = _vt.vt_page_pipeline->ready_keys();
	if (ready.count == 0) { return; }
	// The tick deadline bounds what this pass adds, but a pass that produces nothing because
	// the planning already spent the budget stalls the pipeline for the whole session: pages
	// whose demand was recorded are never produced, and a settled view keeps showing the
	// missing-page material. One page of progress per pass is the floor that keeps every view
	// converging while a strict budget still decides the rate above it - and it stays below the
	// residency a pooled view is allowed to hold, so sharing pressure still evicts down to the
	// last page.
	const int floor = MIN(1, p_max_pages);
	// The walk resumes where the last one stopped rather than restarting: a page already
	// attempted is already in the source queue or already resident, so re-attempting it only
	// re-polls the answer it gave, and the pages behind it are the ones still owed.
	for (; r_pass.missing_next < r_pass.missing.size(); ++r_pass.missing_next) {
		// Throughput is bounded by the real page budget, not a CPU timer that can
		// collapse this pipeline to one page per frame while the camera is moving.
		if (r_pass.produced >= p_max_pages) { break; }
		// ... but an automatic tick also stops on its own deadline once it has made progress:
		// the remaining pages are produced by the ticks that follow, and the view they are
		// missing from is shaded from the source in the meantime.
		if (r_pass.produced >= floor && _vt_tick_expired()) { break; }
		const auto &page = *r_pass.missing[r_pass.missing_next];
		if (!ready.contains({ page.owner.x, page.owner.y, page.mip, page.x, page.y })) {
			// The page's source payload is not ready yet, which is the definition of
			// `source_wait` - and it used to be the one case that did not count itself. The walk
			// advances past the page either way, so a pass that produced eight pages out of a
			// hundred-miss working set reported no wait at all and looked like a pass with
			// nothing left to do. The number is what decides whether the fix is worker
			// throughput or demand: `produced` is bounded by how many payloads the source
			// pipeline delivers per tick, not by this pass's budget.
			++r_pass.source_wait;
			continue;
		}
		if (_avt_produce_page(r_pass, page)) {
			++r_pass.produced;
			r_pass.missing[r_pass.missing_next] = nullptr;
		}
	}
}

// Fills the pool with off-screen pages, but only once the visible plan is complete,
// and never twice over the same page in one cycle.
void Terrain3D::_avt_produce_prefetch(Terrain3DAVTProducePass &r_pass, int p_max_pages) {
	if (!r_pass.missing.empty() || _vt.avt_plan.prefetch.empty()) { return; }
	const auto pool = _vt.surface_vt->get_page_pool();
	bool complete = pool->free_slots.empty();
	for (size_t checked = 0; checked < _vt.avt_plan.prefetch.size() && !complete; ++checked) {
		if (r_pass.prefetched >= p_max_pages || _vt_tick_expired()) { break; }
		r_pass.prefetch_pending = false;
		r_pass.prefetched += _avt_produce_page(r_pass, _vt.avt_plan.prefetch[_vt.avt_prefetch_cursor], true) ? 1 : 0;
		_vt.avt_prefetch_cycle_pending |= r_pass.prefetch_pending;
		if (++_vt.avt_prefetch_cursor == _vt.avt_plan.prefetch.size()) {
			_vt.avt_prefetch_cursor = 0;
			complete = !_vt.avt_prefetch_cycle_pending;
			_vt.avt_prefetch_cycle_pending = false;
			break;
		}
		complete = pool->free_slots.empty();
	}
	r_pass.prefetch_pending = !complete;
}

// Releases the pins and publishes the pass to the render thread in one commit, then
// reports what it cost. A pass that produced nothing and owes no prefetch is idle,
// so the next plan with the same residency can be reused.
void Terrain3D::_avt_finish_produce(Terrain3DAVTProducePass &r_pass) {
	const auto pool = _vt.surface_vt->get_page_pool();
	const uint64_t finish_start = Time::get_singleton()->get_ticks_usec();
	_vt.avt_sector_stats["prefetched"] = r_pass.prefetched;
	// Visible-miss diagnostics: pages the current image samples, of which how many are
	// waiting on production and how many have already been retried past their window.
	_vt.avt_sector_stats["visible_plan_pages"] = r_pass.sampled_plan;
	_vt.avt_sector_stats["visible_missing_pages"] = r_pass.sampled_missing;
	_vt.avt_sector_stats["visible_pending_pages"] = r_pass.sampled_pending;
	_vt.avt_sector_stats["visible_late_pages"] = r_pass.sampled_late;
	_vt.avt_sector_stats["visible_late_worst_ms"] = double(r_pass.late_worst_us) / 1000.0;
	_vt.avt_sector_stats["demand_age_entries"] = int(_vt.avt_demand_age.size());
	_vt.avt_late_pages = r_pass.sampled_late;
	_vt.avt_late_worst_us = r_pass.late_worst_us;
	_vt.avt_missing_pages = r_pass.sampled_missing;
	_vt.avt_pending_pages = r_pass.sampled_pending;
	_vt.avt_sector_stats["sampled_pages"] = _vt.avt_plan.sampled;
	_vt.avt_sector_stats["produce_source_wait"] = r_pass.source_wait;
	_vt.avt_sector_stats["produce_slot_wait"] = r_pass.slot_wait;
	// This function is the largest stage of a peak pass, and it is all bookkeeping. The three
	// timings below are what tells which half of it - the String-keyed writes of the statistics,
	// the producer queries under their lock, or releasing the pass's pins.
	auto since = [](const uint64_t p_from) { return double(Time::get_singleton()->get_ticks_usec() - p_from) / 1000.0; };
	_vt.avt_sector_stats["stats_ms"] = since(finish_start);
	const uint64_t worker_start = Time::get_singleton()->get_ticks_usec();
	{
		// Worker throughput: pages the source threads assembled and the worker time they
		// spent, which is what separates "the workers cannot keep up" from "the pool will
		// not hand out a slot for the pages they did assemble".
		int pages = 0, queued = 0;
		int64_t usec = 0;
		if (_vt.vt_page_pipeline) {
			_vt.vt_page_pipeline->get_production_stats(pages, usec, queued);
			int hits = 0, mismatch = 0, evicted = 0, discarded = 0;
			_vt.vt_page_pipeline->get_outcome_stats(hits, mismatch, evicted, discarded);
			_vt.avt_sector_stats["worker_hits"] = hits;
			_vt.avt_sector_stats["worker_rect_mismatch"] = mismatch;
			_vt.avt_sector_stats["worker_evicted"] = evicted;
			_vt.avt_sector_stats["worker_discarded"] = discarded;
			_vt.vt_page_pipeline->reset_production_stats();
		}
		_vt.avt_sector_stats["worker_pages"] = pages;
		_vt.avt_sector_stats["worker_ms"] = double(usec) / 1000.0;
		_vt.avt_sector_stats["worker_queue"] = queued;
	}
	_vt.avt_sector_stats["worker_stats_ms"] = since(worker_start);
	r_pass.produced += r_pass.prefetched;
	const uint64_t protect_start = Time::get_singleton()->get_ticks_usec();
	for (int slot : r_pass.protected_slots) { _vt.surface_vt->protect_page(slot, false); }
	_vt.avt_sector_stats["protect_ms"] = since(protect_start);
	_vt.avt_sector_stats["pins_released"] = int(r_pass.protected_slots.size());
	const uint64_t commit_start = Time::get_singleton()->get_ticks_usec();
	_vt.surface_vt->commit();
	_vt.avt_sector_stats["commit_ms"] = since(commit_start);
	_vt.avt_sector_stats["allocation_ms"] = double(r_pass.allocation_us) / 1000.;
	_vt.avt_sector_stats["request_ms"] = double(r_pass.request_us) / 1000.;
	_vt.avt_sector_stats["invalidate_ms"] = double(r_pass.invalidate_us) / 1000.;
	_vt.avt_sector_stats["payload_ms"] = double(r_pass.payload_us) / 1000.;
	_vt.avt_sector_stats["queue_ms"] = double(r_pass.queue_us) / 1000.;
	_vt.surface_vt->set_allocation_budget(-1);
	_vt.avt_sector_stats["produced"] = r_pass.produced;
	if (r_pass.missing.empty() && r_pass.produced == 0 && !r_pass.prefetch_pending) { _vt.avt_settled.verified(pool->residency_revision); }
}
