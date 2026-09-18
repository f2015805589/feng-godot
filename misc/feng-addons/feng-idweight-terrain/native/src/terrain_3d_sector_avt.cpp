// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3D's near field, part 1 of 3: the demand entry point and its configuration.

// One of three files that own the near field's planning. `_update_sector_avt()` is the driver:
// it predicts the lead transform, derives the plan key, decides whether the previous plan can be
// reused, and otherwise runs the chain - scan, hierarchy, address directory, publish - and submits
// the result. The tier settings here are the ones the sector size is derived from
// (`get_avt_base_block_size()` and `_avt_logical_ratio()`), so they live beside the driver that
// reads them rather than in the properties file.
//
// The other two: `terrain_3d_sector_avt_motion.cpp` (the lead and the plan key) and
// `terrain_3d_sector_avt_hierarchy.cpp` (the scan, the hierarchy, the address directory and its
// publication). The prologue all three share is `terrain_3d_sector_avt_internal.h`.

#include "terrain_3d_sector_avt_internal.h"

#include "terrain_3d.h"
#include "terrain_3d_avt_plan.h"
#include "terrain_3d_vt_visibility.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/time.hpp>

using namespace TerrainAVT;

void Terrain3D::set_surface_vt_texels_per_meter(real_t p_value) {
	if (!std::isfinite(p_value)) { return; }
	p_value = CLAMP(p_value, 1.f, 8192.f);
	if (_vt.surface_vt_texels_per_meter == p_value) { return; }
	_vt.surface_vt_texels_per_meter = p_value;
	_reset_vt_configuration(); // A changed density changes every page footprint.
}

void Terrain3D::set_surface_svt_texels_per_meter(real_t p_value) {
	if (!std::isfinite(p_value)) { return; }
	set_surface_svt_page_world(_vt.vt_page_size / CLAMP(p_value, 0.01f, 8192.f));
}

int Terrain3D::get_avt_base_block_size() const {
	int size = 1;
	while (size < 64.f * _vt.surface_vt_texels_per_meter / _vt.vt_page_size) { size <<= 1; }
	return size;
}

// The number of texels a level 0 sector block carries per page, as a multiple of its page
// count: `size * logical_ratio` is the block's virtual resolution for `SECTOR_WORLD`
// metres. Derived here rather than read from the plan, because the chain that re-configures a
// view publishes its directory before it submits the plan: the first publish of a configuration
// would otherwise read the previous configuration's ratio.
float Terrain3D::_avt_logical_ratio() const {
	return SECTOR_WORLD * _vt.surface_vt_texels_per_meter / (_vt.vt_page_size * get_avt_base_block_size());
}

void Terrain3D::set_surface_vt_mip_distances(const PackedFloat32Array &p_distances) {
	PackedFloat32Array normalized;
	for (int i = 0; i < MIN(16, int(p_distances.size())); ++i) {
		const float previous = i ? normalized[i - 1] : 0.f;
		normalized.push_back(std::isfinite(p_distances[i]) ? MAX(previous + 0.01f, p_distances[i]) : previous + 1.f);
	}
	_vt.surface_vt_mip_distances = normalized;
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
}

int Terrain3D::get_surface_vt_mip_for_distance(real_t p_distance) const {
	const int top = TerrainVT::log2_power_of_two(is_sector_avt() ? get_avt_base_block_size() : _vt.surface_vt_pages_per_axis);
	int mip = 0;
	float edge = 8.f;
	while (mip < top) {
		if (mip < _vt.surface_vt_mip_distances.size()) { edge = _vt.surface_vt_mip_distances[mip]; }
		if (p_distance <= edge) { break; }
		++mip; edge *= 2.f;
	}
	return mip;
}

void Terrain3D::set_surface_vt_selection_mode(int p_mode) {
	p_mode = CLAMP(p_mode, 0, 2);
	if (_vt.surface_vt_selection_mode == p_mode) { return; }
	_vt.surface_vt_selection_mode = p_mode;
	_vt.vt_view_focus_valid = false;
	// A legacy region coordinate and a 64 m sector coordinate describe different
	// footprints. They cannot share cached address ownership across a mode switch.
	_reset_vt_configuration();
	notify_property_list_changed();
}

// One AVT demand pass per physics tick, in four phases: decide whether this tick
// plans at all, scan the resident regions into demand cells, turn that scan into
// a sorted working set with an address directory, and submit the page selection
// to a worker. Page production happens on every tick, planned or not.
int Terrain3D::_update_sector_avt(int p_max_pages) {
	if (!_vt.surface_vt || !_data || !_vt.vt_shared_ready || !get_camera()) { return 0; }
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	_vt.avt_sector_ticks++;
	// Demand is planned for the predicted camera, which is where the view will be when
	// the pages being produced now are needed. The transform is the only difference: the
	// shader still selects mips from the real frustum.
	const Transform3D camera_transform = get_camera()->get_camera_transform();
	const Transform3D lead_transform = _vt_lead_camera_transform(camera_transform);
	const Vector3 camera_position = lead_transform.origin;
	const Vector2 focus(camera_position.x, camera_position.z);
	const float reach = MAX(64.f, float(_vt.surface_vt_distance));
	// Published before the plan is installed or reused, so the readings describe this tick
	// and not the last one that ran the whole planning chain.
	_vt.avt_sector_stats["motion_lead_m"] = _vt.avt_motion_lead.length();
	_vt.avt_sector_stats["motion_speed"] = _vt.avt_motion_velocity.length();
	// The turn half of the reading: the estimated rate and the lead actually aimed with. A turn
	// whose lead is zero is a turn the plan is not ahead of, which is the one thing to look at
	// when a view streams while turning and not while running.
	_vt.avt_sector_stats["motion_turn_deg_s"] = Math::rad_to_deg(_vt.avt_motion_turn.length());
	_vt.avt_sector_stats["motion_turn_lead_deg"] = Math::rad_to_deg(_vt.avt_motion_turn_lead.length());
	_vt.avt_sector_stats["plan_origin"] = Vector2(lead_transform.origin.x, lead_transform.origin.z);
	_vt.avt_sector_stats["camera_origin"] = Vector2(camera_transform.origin.x, camera_transform.origin.z);
	if (!_vt.vt_source_snapshot) { _vt.vt_source_snapshot = Terrain3DPagePipeline::snapshot(_data, _region_size, _vertex_spacing, _surface_density); }
	const bool bounds_ready = _vt.vt_source_snapshot->bounds_ready.load(std::memory_order_acquire);

	const uint64_t plan_state_started = Time::get_singleton()->get_ticks_usec();
	const Terrain3DAVTPlanKey plan_key = _avt_plan_state(bounds_ready);
	_vt.avt_plan_state_sum_ms += double(Time::get_singleton()->get_ticks_usec() - plan_state_started) / 1000.0;
	// Diagnostic: a plan key that changes every frame re-plans the whole working set, so
	// which component moved is the question worth answering. Component indices follow
	// `_avt_plan_state` (9 basis, 3 origin, 16 projection, 4 viewport, then the scalars), which is
	// also the element index of the key; an invalidated key has no component to report.
	{
		int first = -1;
		if (is_valid_avt_plan_key(_vt.avt_plan_key)) {
			for (size_t i = 0; i < plan_key.size(); ++i) {
				if (plan_key[i] != _vt.avt_plan_key[i]) { first = int(i); break; }
			}
		}
		_vt.avt_sector_stats["plan_key_dirty_component"] = first;
		_vt.avt_sector_stats["plan_key_unchanged"] = first < 0;
	}
	_vt.avt_key_sum_ms += double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	const uint64_t install_started = Time::get_singleton()->get_ticks_usec();
	// A changed key does not have to mean a new plan: the plan is a look-ahead artifact, and the
	// chain that derives it is the most expensive thing in the tick. Inside the refresh interval a
	// changed key reuses the standing plan, which is what the production pass then works from.
	// `avt_plan_key` is deliberately left at the key the standing plan was planned for, so the
	// tick after the interval sees the change and plans.
	//
	// A key that was *invalidated* is not camera motion and does not wait: a region was added or
	// removed, a slot was swapped, the material or the pool was rebuilt, and the standing plan
	// describes a world that no longer exists. Only a key that changed because the view moved is
	// held for the interval, which is the whole of what the interval is for. Measured: without
	// this distinction a region whose slot had just been swapped rendered the missing-page
	// diagnostic until the interval expired.
	const uint64_t frame_now = Engine::get_singleton()->get_process_frames();
	const bool key_same = _vt.avt_plan_key == plan_key;
	const bool key_valid = is_valid_avt_plan_key(_vt.avt_plan_key);
	const bool refresh_due = !key_valid || _vt.avt_last_chain_frame == UINT64_MAX ||
			frame_now >= _vt.avt_last_chain_frame + _vt.avt_plan_refresh_frames;
	if (!key_same && !refresh_due) { _vt.avt_plan_refresh_skips++; }
	const int finished = _avt_install_or_reuse_plan(started, p_max_pages, key_same || !refresh_due);
	_vt.avt_install_sum_ms += double(Time::get_singleton()->get_ticks_usec() - install_started) / 1000.0;
	// Where a tick's cost goes, summed over the session: the plan key, the install or reuse
	// decision - which includes a production pass on every path, so it is not the tick's total -
	// and the planning chain a moving camera pays on the ticks where the key changed. The
	// per-pass sums are beside them, and `idle_ticks` is the count of ticks the production pass
	// answered as already settled.
	auto publish_tick_sums = [this]() {
		const uint64_t produce_calls = _vt.avt_reuse_ticks + _vt.avt_chain_ticks;
		_vt.avt_sector_stats["sector_ticks"] = int64_t(_vt.avt_sector_ticks);
		_vt.avt_sector_stats["reuse_ticks"] = int64_t(_vt.avt_reuse_ticks);
		_vt.avt_sector_stats["chain_ticks"] = int64_t(_vt.avt_chain_ticks);
		_vt.avt_sector_stats["capacity_skip_ticks"] = int64_t(_vt.avt_capacity_skip_ticks);
		_vt.avt_sector_stats["plan_refresh_skips"] = int64_t(_vt.avt_plan_refresh_skips);
		_vt.avt_sector_stats["plan_refresh_frames"] = int64_t(_vt.avt_plan_refresh_frames);
		_vt.avt_sector_stats["idle_ticks"] = int64_t(produce_calls - MIN(produce_calls, _vt.avt_pass_count));
		_vt.avt_sector_stats["key_sum_ms"] = _vt.avt_key_sum_ms;
		_vt.avt_sector_stats["plan_state_sum_ms"] = _vt.avt_plan_state_sum_ms;
		_vt.avt_sector_stats["install_sum_ms"] = _vt.avt_install_sum_ms;
		_vt.avt_sector_stats["chain_sum_ms"] = _vt.avt_chain_sum_ms;
		_vt.avt_sector_stats["produce_sum_ms"] = _vt.avt_produce_sum_ms;
		_vt.avt_sector_stats["update_sum_ms"] = _vt.avt_update_sum_ms;
		_vt.avt_sector_stats["wrapper_sum_ms"] = _vt.avt_wrapper_sum_ms;
	};
	auto leave = [this, &publish_tick_sums, started](const int p_result) {
		_vt.avt_update_sum_ms += double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
		publish_tick_sums();
		return p_result;
	};
	if (finished >= 0) {
		_vt.avt_reuse_ticks++;
		return leave(finished);
	}
	_vt.avt_chain_ticks++;
	_vt.avt_last_chain_frame = frame_now;

	_vt.avt_sector_stats["plan_reused"] = false;
	_vt.avt_sector_stats["coverage_center"] = focus;
	_vt.avt_sector_stats["coverage_radius"] = _vt.surface_svt_enabled ? reach : -1.f;
	// Phase timings for the uncached path, which is the one a moving camera takes on
	// every tick: the visible scan, the sector hierarchy, the address directory, the
	// hand-off to the refinement worker, the directory upload and the page production.
	// The predicted frustum, not the rendered one. `camera_transform` is the real one the
	// engine is using; only the plan moves ahead of it.
	TerrainVT::VisibleView view(lead_transform, get_camera()->get_camera_projection(),
			get_camera()->get_viewport() ? get_camera()->get_viewport()->get_visible_rect().size.y : 720.f,
			get_camera()->get_projection() == Camera3D::PROJECTION_ORTHOGONAL, 192.f);
	// The chain runs in one pass. Staging it across ticks was tried and reverted: the
	// install/reuse path above resets the stage cursor, so a chain that was interrupted
	// between phases could be discarded before it published, which left the directory
	// stale and the view rendering the missing-page diagnostic for whole sectors.
	//
	// The scratch members the phases hand each other are reused rather than rebuilt, so a
	// plan tick does not reallocate the scan and the hierarchy it is about to discard.
	uint64_t phase_start = Time::get_singleton()->get_ticks_usec();
	const uint64_t chain_started = phase_start;
	auto mark_phase = [this, &phase_start](const char *p_key) {
		const uint64_t now = Time::get_singleton()->get_ticks_usec();
		_vt.avt_sector_stats[p_key] = double(now - phase_start) / 1000.0;
		phase_start = now;
	};
	_vt.avt_pending_scan = _avt_scan_sectors(view, camera_position, bounds_ready, focus, reach);
	mark_phase("scan_ms");
	_vt.avt_pending_hierarchy = _avt_build_hierarchy(_vt.avt_pending_scan);
	_vt.avt_pending_scan = Terrain3DAVTSectorScan();
	mark_phase("hierarchy_ms");
	_avt_sync_address_directory(_vt.avt_pending_hierarchy, focus, reach);
	mark_phase("sync_ms");
	_publish_avt_directory(_vt.avt_pending_hierarchy);
	mark_phase("publish_ms");
	_avt_submit_plan(_vt.avt_pending_hierarchy, plan_key, view, camera_position, bounds_ready, focus, reach);
	mark_phase("submit_ms");
	_vt.avt_chain_sum_ms += double(Time::get_singleton()->get_ticks_usec() - chain_started) / 1000.0;
	_vt.avt_plan_key = plan_key;
	_vt.avt_pending_hierarchy = Terrain3DAVTHierarchy();

	_vt.avt_sector_stats["height_bounds_ready"] = bounds_ready;
	_vt.avt_sector_stats["retained_hierarchy"] = true;
	_vt.avt_sector_stats["planning_pending"] = true;
	_vt.avt_sector_stats["base_virtual_resolution"] = SECTOR_WORLD * _vt.surface_vt_texels_per_meter;
	_vt.avt_sector_stats["base_page_entries"] = SECTOR_WORLD * _vt.surface_vt_texels_per_meter / _vt.vt_page_size;
	_vt.avt_sector_stats["indirection_size"] = 2048;
	const uint64_t produce_started = Time::get_singleton()->get_ticks_usec();
	const int produced = _produce_sector_avt_pages(p_max_pages);
	_vt.avt_produce_sum_ms += double(Time::get_singleton()->get_ticks_usec() - produce_started) / 1000.0;
	mark_phase("produce_ms");
	_vt.avt_sector_stats["cpu_update_ms"] = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	return leave(produced);
}

// Fixed camera/configuration key: no per-frame Variant arrays or region scan.
// All source edits invalidate this key together with the source snapshot.
Terrain3DAVTPlanKey Terrain3D::_avt_plan_state(const bool p_bounds_ready) const {
	const Camera3D *camera = get_camera();
	// Filled in place and returned by value: this runs on every tick of a moving view, and the
	// byte array it used to be built into was a 512 byte allocation and a copy per tick.
	Terrain3DAVTPlanKey state = {};
	int component = 0;
	auto append = [&](double value) { state[component++] = value; };
	// The key describes what the plan is a function of, which is the predicted transform the
	// page set was derived from - not the rendered one, or a moving camera would re-plan every
	// frame while the predicted view had not changed at all.
	const Transform3D transform = _vt_plan_key_transform(camera->get_camera_transform());
	for (int row = 0; row < 3; ++row) for (int col = 0; col < 3; ++col) { append(transform.basis[row][col]); }
	for (int axis = 0; axis < 3; ++axis) { append(transform.origin[axis]); }
	const Projection projection = camera->get_camera_projection();
	for (int col = 0; col < 4; ++col) for (int row = 0; row < 4; ++row) { append(projection[col][row]); }
	const Rect2 viewport = camera->get_viewport()->get_visible_rect();
	append(viewport.position.x); append(viewport.position.y); append(viewport.size.x); append(viewport.size.y);
	append(p_bounds_ready); append(_region_size); append(_vertex_spacing);
	append(_vt.surface_vt_texels_per_meter); append(_vt.surface_vt_texels_per_pixel); append(_vt.vt_adaptive_enabled);
	// The far field's visible count is what reserves part of the pool, but it moves by a page
	// or two on every frame of a moving view. Bucketing it keeps the near field's plan
	// installable while its own footprint is unchanged; an exact count in the key re-planned
	// the whole working set whenever the far field gained or lost a single page.
	append((_vt.vt_svt_visible_pages / 16) * 16); append(_vt.surface_svt_enabled); append(_vt.surface_vt_distance);
	append(!_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty());
	append(_vt.vt_page_count); append(_vt.vt_page_size);
	return state;
}

// Only planning is cached. Page requests still touch residency and repair
// invalidated/evicted pages on every demand epoch, within the normal budget.
int Terrain3D::_avt_install_or_reuse_plan(const uint64_t p_started, const int p_max_pages, const bool p_same_plan) {
	bool installed = false;
	if (_vt.avt_refinement && _vt.avt_refinement->ready.load(std::memory_order_acquire)) {
		if (_vt.avt_refinement->key == _vt.avt_plan_key) {
			// Sizing the pool for the pages the image actually samples, not for everything the
			// plan names. The speculative apron is a function of the leftover budget, so
			// counting it here closes a loop - a larger pool allows a larger apron, which asks
			// for a larger pool - and the pair grows until the capacity cap: measured at 1024
			// slots holding 53 near-field pages. The apron and the retained tail live in the
			// slack of that capacity instead.
			//
			// The same loop runs one step wider through the retention window, which is appended
			// to the plan after this call: a request that counted it asked for capacity the plan
			// only holds for a few epochs, and the request is what the pool's growth is driven
			// by. `sampled` is the pages the image is shading, which is the number above.
			// No floor of one here: a request of zero pages must not grow the pool, which is what
			// a minimum of eight slots per request would do on every empty plan.
			if (_ensure_vt_capacity(_vt.avt_refinement->sampled + _vt.vt_svt_visible_pages)) {
				// The pool is waiting for a larger capacity, so this tick produced nothing and
				// did not classify either. Counted separately from the settled shortcut, which
				// reads the same way from the outside.
				_vt.avt_capacity_skip_ticks++;
				return 0;
			}
			// A grazing mip can disappear for one plan and reappear immediately.
			// Let recently requested jobs finish instead of repeatedly cancelling
			// their prepared source bytes. Current visibility always comes first.
			const uint64_t epoch = ++_vt.avt_plan_epoch;
			// The retained scan compares every address in the plan against every address
			// still requested. A tree node per address costs more than one tick's whole
			// budget, so the current set is a sorted array searched in place.
			std::vector<std::array<int, 5>> current;
			current.reserve(_vt.avt_refinement->pages.size());
			for (Terrain3DAVTPageRequest &page : _vt.avt_refinement->pages) {
				page.last_visible_plan = epoch;
				current.push_back({ page.owner.x, page.owner.y, page.mip, page.x, page.y });
			}
			std::sort(current.begin(), current.end());
			// The window is at least one lead wide: a page the plan moved ahead of is still
			// in the image being rendered, and dropping its request would let the pool evict
			// it out from under the view that has not caught up yet. The count is capped so a
			// look-ahead plan cannot reserve the whole pool with pages the camera has left -
			// and capped again by the room the completed plan left in its budget, so what this
			// installs is never larger than the residency it is served from. The planner
			// reserves that room; this is the same invariant, held where the append happens.
			const int retain_cap = MIN(128, MAX(0, _vt.avt_refinement->budget - int(_vt.avt_refinement->pages.size())));
			int retained = 0;
			for (const Terrain3DAVTPageRequest &page : _vt.avt_page_plan) {
				if (retained == retain_cap) { break; }
				if (page.last_visible_plan + uint64_t(_vt.avt_retain_epochs) < epoch ||
						std::binary_search(current.begin(), current.end(),
								std::array<int, 5>{ page.owner.x, page.owner.y, page.mip, page.x, page.y })) {
					continue;
				}
				_vt.avt_refinement->pages.push_back(page);
				++retained;
			}
			_vt.avt_retained_pages = retained;
			_vt.avt_sector_stats["retained_requests"] = retained;
			_vt.avt_sector_stats["retain_epochs"] = _vt.avt_retain_epochs;
			_vt.avt_page_plan = std::move(_vt.avt_refinement->pages);
			_vt.avt_sampled_pages = _vt.avt_refinement->sampled;
			_vt.avt_prefetch_plan = std::move(_vt.avt_refinement->warm);
			_vt.avt_prefetch_cursor = 0;
			_vt.avt_prefetch_cycle_pending = false;
			// A new plan is a new wanted set, so the source queue has to be retained again.
			_vt.avt_retain_applied = false;
			_vt.avt_sector_stats["refinement_requests_denied"] = _vt.avt_refinement->denied;
			_vt.avt_sector_stats["finest_requested_texel_world"] = _vt.avt_refinement->finest;
			_vt.avt_sector_stats["visible_root_pages"] = _vt.avt_refinement->roots;
			_vt.avt_sector_stats["requested_physical_pages"] = int(_vt.avt_page_plan.size());
			_vt.avt_sector_stats["prefetch_requests"] = int(_vt.avt_prefetch_plan.size());
			_vt.avt_sector_stats["planning_ms"] = double(_vt.avt_refinement->elapsed_us) / 1000.;
			_vt.avt_sector_stats["plan_age_ms"] = double(p_started - _vt.avt_refinement->submitted_us) / 1000.;
			installed = true;
		}
		_vt.avt_refinement.reset();
	}
	_vt.avt_sector_stats["planning_pending"] = bool(_vt.avt_refinement);
	// Finish an in-flight plan instead of replacing it on every camera tick.
	// Installing a completed plan must not insert an idle planning frame. Its
	// requests remain active while the next camera view is submitted below.
	if (p_same_plan || _vt.avt_refinement) {
		_vt.avt_plan_reused = !installed;
		_vt.avt_sector_stats["plan_reused"] = _vt.avt_plan_reused;
		_vt.avt_sector_stats["directory_rebuilt"] = false;
		const int produced = _produce_sector_avt_pages(p_max_pages);
		_vt.avt_sector_stats["cpu_update_ms"] = double(Time::get_singleton()->get_ticks_usec() - p_started) / 1000.0;
		return produced;
	}
	// A plan that is not being reused leaves the settled verdict false: the caller goes on to run
	// this tick's production pass, and it must not read the absence of an install as an idle plan
	// and skip the work the new view needs.
	_vt.avt_plan_reused = false;
	return -1;
}

// Submits this key's page selection to the plan pipeline. The selection is the
// expensive half (it walks the visible mip interval per cell), so it runs on the
// plan worker and arrives through _avt_install_or_reuse_plan on a later tick.
void Terrain3D::_avt_submit_plan(Terrain3DAVTHierarchy &r_hierarchy, const Terrain3DAVTPlanKey &p_plan_key,
		const TerrainVT::VisibleView &p_view,
		const Vector3 &p_camera_position, const bool p_bounds_ready, const Vector2 &p_focus, const float p_reach) {
	// Refine only visible page footprints. The refinement walk never enumerates a
	// virtual image's full mip pyramid (256 squared entries need zero resident
	// pages until requested). Budget exhaustion must remain visible in diagnostics.
	for (Sector &sector : r_hierarchy.working) { sector.size = _vt.surface_vt->has_sector(sector.owner) ? _vt.surface_vt->get_sector_block_size(sector.owner) : 0; }
	const float logical_ratio = _avt_logical_ratio();
	auto job = std::make_shared<Terrain3DAVTRefinement>();
	// The plan carries the key it was planned for, which is the key this tick
	// publishes at its end. The install step compares it against the member, so it
	// must be the new key and not the one being replaced.
	job->key = p_plan_key;
	job->submitted_us = Time::get_singleton()->get_ticks_usec();
	_vt.avt_refinement = job;
	// Keep producing the last completed view while its successor is being planned.
	// A virtual block can grow without changing a physical page's world footprint.
	auto remap_plan = [&](std::vector<Terrain3DAVTPageRequest> &plan) {
		for (auto it = plan.begin(); it != plan.end();) {
			auto address = _vt.avt_cached_addresses.find(avt_owner_key(it->owner));
			if (address == _vt.avt_cached_addresses.end() || !_vt.surface_vt->has_sector(it->owner)) { it = plan.erase(it); continue; }
			const auto &node = address->second;
			const int size = _vt.surface_vt->get_sector_block_size(it->owner);
			const float world = SECTOR_WORLD * float(1 << node.level);
			const float logical = node.level ? 1.f : size * logical_ratio;
			const int mip = int(std::round(std::log2(it->rect.size.x * logical / world)));
			if (mip < 0 || mip > TerrainVT::log2_power_of_two(size)) { it = plan.erase(it); continue; }
			it->mip = mip;
			++it;
		}
	};
	// Camera motion changes demand, not existing virtual addresses. Avoid
	// re-deriving every page mip when the address directory and scale agree.
	if (r_hierarchy.directory_dirty || logical_ratio != _vt.avt_plan_logical_ratio) {
		remap_plan(_vt.avt_page_plan);
		remap_plan(_vt.avt_prefetch_plan);
		_vt.avt_plan_logical_ratio = logical_ratio;
		// The addresses the source queue is retained against just changed.
		_vt.avt_retain_applied = false;
	}
	_vt.avt_prefetch_cursor = 0;
	_vt.avt_prefetch_cycle_pending = false;
	_vt.avt_idle_revision = 0;
	if (!_vt.vt_page_pipeline) { _vt.vt_page_pipeline = std::make_unique<Terrain3DPagePipeline>(_vt.vt_page_workers); }
	TerrainAVT::PlanInput input;
	input.working = r_hierarchy.working;
	input.source = _vt.vt_source_snapshot;
	input.view = p_view;
	input.bounds_ready = p_bounds_ready;
	input.camera_position = p_camera_position;
	input.focus = p_focus;
	input.reach = p_reach;
	input.exact_radius = float(_cdlod_enabled && _tessellation_level == 0 ? _cdlod_patch_size * _vertex_spacing * _cdlod_lod_scale * 0.7 / (1 << _tessellation_level) : 0);
	input.logical_ratio = logical_ratio;
	input.texels_per_pixel = _vt.surface_vt_texels_per_pixel;
	input.budget = r_hierarchy.budget;
	input.root_level = r_hierarchy.root_level;
	input.page_size = _vt.vt_page_size;
	_vt.vt_page_pipeline->submit_task([job, input]() mutable { TerrainAVT::plan_pages(*job, input); });
}
