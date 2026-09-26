// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The two surface views, part 4 of 4: the near field's demand pass and its sectors.

// One of four files that define the two views and their demand passes. `update_surface_vt()` is the AVT pass:
// it reads the camera-visible regions through `terrain_region_in_frustum()`, a file-scope static,
// which is why that helper is here and not with the settings, and bounds them with
// `get_surface_vt_region_rect()`, which calls it. It gives each visible region a virtual block
// (`_prepare_vt_sector()`, `_compute_adaptive_sector_sizes()`), asks the block for its pages
// (`_vt_page_requests_for_sector()`, `_surface_vt_mip_for_page()`) and produces the ones that are
// missing (`_produce_missing_vt_pages()`). `_update_surface_vt_feedback()` is the GPU projection pass
// that tells it which pages the shader actually sampled, and `_publish_vt_block_tables()` is what the
// material binds afterwards.
//
// The other halves: `terrain_3d_surface_views.cpp` (the views and the settings),
// `terrain_3d_surface_views_far.cpp` (the far field's pass and its level rule) and
// `terrain_3d_surface_views_far_walk.cpp` (the far field's root plan, visible walk and demand pass).

#include "terrain_3d.h"
#include "terrain_3d_surface_views_internal.h"


#include <godot_cpp/classes/time.hpp>

///////////////////////////
// Surface virtual texture
///////////////////////////

static bool terrain_region_in_frustum(Terrain3DData *p_data, const Vector2i &p_location,
		float p_region_world, const TypedArray<Plane> &p_planes) {
	Ref<Terrain3DRegion> region = p_data->get_region(p_location);
	if (region.is_null() || region->is_deleted()) { return false; }
	const Vector2 heights = region->get_height_range();
	const Vector3 lo(p_location.x * p_region_world, heights.x - 1.f, p_location.y * p_region_world);
	const Vector3 hi(lo.x + p_region_world, heights.y + 1.f, lo.z + p_region_world);
	for (int i = 0; i < p_planes.size(); ++i) {
		const Plane plane = p_planes[i];
		const Vector3 closest(plane.normal.x > 0.f ? lo.x : hi.x,
				plane.normal.y > 0.f ? lo.y : hi.y, plane.normal.z > 0.f ? lo.z : hi.z);
		if (plane.is_point_over(closest)) { return false; }
	}
	return true;
}

Rect2i Terrain3D::get_surface_vt_region_rect() const {
	// Inspector property reads can occur while the edited scene is being removed.
	if (!is_inside_tree() || !_is_inside_world) { return Rect2i(); }
	const float region_world = MAX(0.0001f, float(_region_size) * _vertex_spacing);
	Vector3 target = get_clipmap_target_position();
	Node3D *anchor = _clipmap_target.is_valid() ? cast_to<Node3D>(_clipmap_target.ptr()) : get_camera();
	Camera3D *camera = get_camera();
	if (_vt.surface_vt_selection_mode == 0 && camera && _data) {
		const TypedArray<Plane> planes = camera->get_frustum();
		const TerrainVT::VisibleView view(camera);
		float best_score = 1e30f;
		float previous_score = 1e30f;
		Vector2i best;
		for (const Vector2i &location : _data->get_region_locations()) {
			if (!terrain_region_in_frustum(_data, location, region_world, planes)) { continue; }
			TerrainVT::VisiblePatch visible;
			if (!view.sample(Rect2(Vector2(location) * region_world, Vector2(region_world, region_world)),
					_data->get_region(location)->get_height_range(), visible)) { continue; }
			const float score = visible.distance;
			if (score < best_score) { best_score = score; best = location; }
			if (_vt.vt_view_focus_valid && location == _vt.vt_view_focus) { previous_score = score; }
		}
		if (best_score == 1e30f) { _vt.vt_view_focus_valid = false; return Rect2i(); }
		// Small distance hysteresis stabilizes adjoining visible region edges.
		if (_vt.vt_view_focus_valid && previous_score <= best_score * 1.03f + 0.01f) { best = _vt.vt_view_focus; }
		_vt.vt_view_focus = best;
		_vt.vt_view_focus_valid = true;
		target.x = (best.x + 0.5f) * region_world;
		target.z = (best.y + 0.5f) * region_world;
		anchor = camera;
	}
	if (anchor && !Math::is_zero_approx(_vt.surface_vt_forward_regions)) {
		Vector3 forward = -anchor->get_global_basis().get_column(2);
		forward.y = 0.f;
		if (forward.length_squared() > 0.0001f) { target += forward.normalized() * (_vt.surface_vt_forward_regions * region_world); }
	}
	const Vector2i center(int(Math::floor(target.x / region_world)), int(Math::floor(target.z / region_world)));
	return Rect2i(center + _vt.surface_vt_region_offset - _vt.surface_vt_region_grid / 2, _vt.surface_vt_region_grid);
}

// Which demand source answers this frame. The projection source answers only while it is enabled
// *and* it has a result: the first pass of a session has none, and the interval between passes keeps
// the standing result rather than dropping back to the distance rule for a frame. That distinction -
// the setting versus this frame - is the whole reason the source is a named value; see
// `TerrainVTPageDemandSource` in terrain_3d_vt_state.h.
TerrainVTPageDemandSource Terrain3D::_vt_demand_source() const {
	if (!_vt_projection_demand_enabled()) { return TerrainVTPageDemandSource::CPURule; }
	if (!_vt.surface_vt_feedback || !_vt.surface_vt_feedback->has_result()) { return TerrainVTPageDemandSource::CPURule; }
	return TerrainVTPageDemandSource::Projected;
}

// Runs the demand pass and makes its result available. The readback of a local device is
// delivered by sync(), so this is a stall; the interval exists to amortise it, and the
// demand pass keeps using the last result in between.
//
// This is the projection source's *producer*: it asks whether the source may run, not which source
// answers, because a result it produces this tick is what makes it answer on the next ones.
bool Terrain3D::_update_surface_vt_feedback(const Vector3 &p_target) {
	if (!_vt_projection_demand_enabled()) {
		return false;
	}
	Camera3D *camera = get_camera();
	if (!camera) {
		return false;
	}
	if (_vt.surface_vt_feedback_tick++ % _vt.surface_vt_feedback_interval != 0) {
		return _vt.surface_vt_feedback != nullptr && _vt.surface_vt_feedback->has_result();
	}
	const int pages_per_axis = _vt.surface_vt_pages_per_axis;
	const int grid = _vt.surface_vt_feedback_grid_chunks * pages_per_axis;
	if (!_vt.surface_vt_feedback) {
		_vt.surface_vt_feedback = memnew(Terrain3DVTFeedback);
		if (_vt.surface_vt_feedback->initialize(grid, grid) != OK) {
			memdelete_safely(_vt.surface_vt_feedback);
			_vt.surface_vt_feedback_enabled = false;
			return false;
		}
	} else if (_vt.surface_vt_feedback->get_grid_width() != grid) {
		_vt.surface_vt_feedback->initialize(grid, grid);
	}
	if (!_vt.surface_vt_feedback->is_initialized()) {
		return false;
	}

	// The grid is a window of chunks centred on the camera's chunk.
	const Vector2i camera_chunk = _data->get_region_location(p_target);
	_vt.surface_vt_feedback_origin = camera_chunk - Vector2i(_vt.surface_vt_feedback_grid_chunks / 2,
													_vt.surface_vt_feedback_grid_chunks / 2);
	const Projection view_projection = camera->get_camera_projection() *
			Projection(camera->get_global_transform().affine_inverse());
	const real_t page_world_size = real_t(_region_size) * _vertex_spacing / real_t(pages_per_axis);
	Viewport *viewport = camera->get_viewport();
	const Vector2i viewport_size = viewport ? Vector2i(viewport->get_visible_rect().size) : Vector2i(1920, 1080);

	if (_vt.surface_vt_feedback->dispatch(view_projection, pages_per_axis, real_t(_region_size),
				page_world_size, _vt.surface_vt->get_page_size(),
				TerrainVT::log2_power_of_two(pages_per_axis), _vt.surface_vt_feedback_origin,
				viewport_size, _vt.surface_vt_feedback_min_extent) != OK) {
		return false;
	}
	_vt.surface_vt_feedback->request_readback();
	// dispatch + request + sync is the only order that works: the copy is a draw graph
	// node, so the submit has to come after the request.
	_vt.surface_vt_feedback->sync();
	return _vt.surface_vt_feedback->has_result();
}

int Terrain3D::_surface_vt_mip_for_page(const Vector2i &p_region_loc, const int p_page_x0,
		const int p_page_y0, const real_t p_distance, const real_t p_page_world_size,
		const int p_max_local_mip) {
	if (_vt.surface_vt_force_mip) {
		return MIN(_vt.surface_vt_mip, p_max_local_mip);
	}
	if (!_vt.vt_debug_direct_material) { return 0; }
	if (_vt_demand_source() == TerrainVTPageDemandSource::Projected) {
		const int mip = _vt.surface_vt_feedback->get_mip_for_page(p_region_loc, _vt.surface_vt_pages_per_axis,
				p_page_x0, p_page_y0, _vt.surface_vt_feedback_origin);
		// -1 means the pass culled this page: off screen, behind the camera or too
		// small to be worth a page. That is the point of using it over the distance
		// rule, so it is honoured rather than treated as a failure.
		return mip;
	}
	// Distance fallback: the shared rule (terrain_vt.h), which is also what the far field and the
	// shader's mirror evaluate - a page requested at one level and sampled at another is the one
	// thing the rule's single definition exists to prevent.
	return TerrainVT::select_mip_rule(float(p_page_world_size), nullptr, 0).mip_for_distance(
			float(p_distance), p_max_local_mip);
}

// Both views are bound to the material by RID, so a view that was cleared by hand (the
// public clear() is bound) leaves the service claiming to be configured while the view has
// no page table, no allocator and no published texture. The near-field sector planner
// cannot work without them: it retries a failed sector registration for every visible
// sector on every tick, which costs hundreds of milliseconds per frame. Rebuild the shared
// service instead, which re-initializes both views and republishes the material.
void Terrain3D::_ensure_vt_views_ready() {
	if (!_vt.vt_shared_ready || _vt.vt_debug_direct_material) {
		return;
	}
	if ((_vt.surface_vt && !_vt.surface_vt->is_initialized()) ||
			(_vt.surface_svt && !_vt.surface_svt->is_initialized())) {
		_reset_vt_configuration();
		_update_vt_service();
	}
}

// One demand pass. The page contract is the same whichever rule picks the mips:
// The near-field AVT is the one VT path that owns its own planner; the far-field
// update is a straight sequence: request -> produce -> write -> commit.
int Terrain3D::update_surface_vt(int p_max_pages) {
	// As above: the source workers are woken once this pass is over.
	SourceWakeFlush flush_wakes{ this };
	const uint64_t entered = Time::get_singleton()->get_ticks_usec();
	if (is_vt_editor_preview_active()) { return 0; }
	// Explicit sector updates must also bind textures first created by the
	// preceding render-thread bake, even when normal physics updates are paused.
	//
	// The physics tick runs this as its own phase immediately before the near-field pass, so on
	// the tick path it would be the same check twice per tick - and the second one costs the same
	// as the first, inside the phase the budget is measured on. `vt_tick_active` is what tells the
	// two callers apart: an explicit `update_surface_vt()` call - a test driving the pass directly,
	// or an editor preview - has no such phase and still gets its own check.
	if (!_vt.vt_tick_active || !_vt.vt_shared_ready || _vt.vt_materials_dirty) { _update_vt_service(); }
	_ensure_vt_views_ready();
	if (is_sector_avt()) {
		// What this wrapper costs around the sector planner, which reports its own total as
		// `cpu_update_ms`. The difference between the phase a profiler shows and that figure had no
		// attribution at all.
		const double wrapper_ms = double(Time::get_singleton()->get_ticks_usec() - entered) / 1000.0;
		_vt.avt_sector_stats["wrapper_ms"] = wrapper_ms;
		_vt.avt_cost.wrapper_sum_ms += wrapper_ms;
		return _update_sector_avt(p_max_pages);
	}
	if (!_vt.surface_vt || !_data) {
		return 0;
	}
	if (!_vt.surface_vt->is_initialized()) {
		_vt.surface_vt->initialize();
		if (!_vt.surface_vt->is_initialized()) {
			return 0;
		}
	}
	const int max_pages_per_axis = _vt.surface_vt_pages_per_axis;
	_vt.surface_vt->set_allocation_budget(p_max_pages > 0 ? p_max_pages : -1);
	PackedVector2Array next_blocks;
	PackedFloat32Array next_sizes;
	_prepare_vt_block_tables(next_blocks, next_sizes);
	const Vector3 target = get_clipmap_target_position();
	if (_vt.vt_debug_direct_material) { _update_surface_vt_feedback(target); }
	const real_t reach_squared = _vt.surface_vt_distance * _vt.surface_vt_distance;
	int produced = 0;
	const Dictionary eligible_regions = _collect_eligible_vt_regions();
	const Dictionary adaptive_sizes = _compute_adaptive_sector_sizes(eligible_regions, max_pages_per_axis);
	_retire_stale_vt_sectors(eligible_regions);

	for (const Vector2i &region_loc : _data->get_region_locations()) {
		const Vector3 center((real_t(region_loc.x) + 0.5f) * _region_size * _vertex_spacing, 0.f,
				(real_t(region_loc.y) + 0.5f) * _region_size * _vertex_spacing);
		const Vector2 flat(center.x - target.x, center.z - target.z);
		const real_t distance_squared = flat.length_squared();
		if (_vt.vt_debug_direct_material ? distance_squared > reach_squared : !eligible_regions.has(region_loc)) {
			continue;
		}
		int pages_per_axis = adaptive_sizes.get(region_loc, max_pages_per_axis);
		const float region_world = _region_size * _vertex_spacing;
		if (!_prepare_vt_sector(region_loc, pages_per_axis)) {
			continue;
		}
		pages_per_axis = _vt.surface_vt->get_sector_block_size(region_loc);
		const int max_local_mip = TerrainVT::log2_power_of_two(pages_per_axis);
		const real_t page_world_size = region_world / real_t(pages_per_axis);
		// Publish the block so the shader can resolve this chunk's pages.
		const int slot = _data->get_region_id(region_loc);
		if (slot >= 0 && slot < next_blocks.size()) {
			next_blocks[slot] = Vector2(real_t(_vt.surface_vt->get_sector_block_origin_x(region_loc)),
					real_t(_vt.surface_vt->get_sector_block_origin_y(region_loc)));
			next_sizes[slot] = float(pages_per_axis);
		}
		const real_t distance = Math::sqrt(distance_squared);
		const std::vector<Vector3i> requests = _vt_page_requests_for_sector(region_loc, pages_per_axis,
				distance, page_world_size, max_local_mip);
		// Only produce the pages this pass actually allocated. A hit already holds
		// content, and re-producing it every tick would swamp the atlas uploads.
		//
		// A hit is only a hit while the producer still has the page's content, though: an
		// encode that failed or a production dropped by a bundle rebuild leaves the table
		// naming a slot nothing ever filled, and treating that as resident kept sampling an
		// empty layer for the rest of the session. The retry only applies to a page the demand
		// path produced, which is what its demand record says: a page written straight into
		// the atlas - an explicit capture, or the direct-material diagnostic - is the caller's
		// content, and producing over it would erase what that caller just wrote.
		std::vector<Vector3i> missing;
		for (const Vector3i &request : requests) {
			bool was_miss = false;
			const int request_slot = _vt.surface_vt->request_page_internal(region_loc, request.z, request.x,
					request.y, &was_miss);
			if (request_slot < 0) {
				continue;
			}
			const bool tracked = _vt.vt_page_records.count(request_slot) > 0;
			if (was_miss || (tracked && _vt_page_production_stale(request_slot))) {
				_invalidate_vt_slot(request_slot);
				missing.push_back(request);
			}
		}
		if (missing.empty()) {
			continue;
		}
		produced += _produce_missing_vt_pages(region_loc, pages_per_axis, region_world, missing);
	}
	_publish_vt_block_tables(next_blocks, next_sizes);
	_vt.surface_vt->commit();
	if (_vt.surface_svt && _vt.surface_svt->is_initialized()) { _vt.surface_svt->commit(); }
	_vt.surface_vt->set_allocation_budget(-1);
	return produced;
}

// Rebuilds the layer -> block origin table the shader indexes. Every entry starts at the
// no-block value, and the pass fills in the sectors that are resident; sectors that
// streamed out or left AVT coverage are unregistered by _retire_stale_vt_sectors().
void Terrain3D::_prepare_vt_block_tables(PackedVector2Array &r_blocks, PackedFloat32Array &r_sizes) {
	const int capacity = _data->get_map_capacity();
	if (capacity > 0 && _vt.surface_vt_blocks.size() != capacity) {
		_vt.surface_vt_blocks.resize(capacity);
		_vt.surface_vt_blocks_dirty = true;
	}
	r_blocks.resize(_vt.surface_vt_blocks.size());
	r_blocks.fill(Vector2(-1.f, -1.f));
	r_sizes.resize(_vt.surface_vt_blocks.size());
	r_sizes.fill(1.f);
}

// Regions the near field (AVT) may publish this pass: inside the explicit Target Grid
// and, in view-selection mode, inside the camera frustum.
Dictionary Terrain3D::_collect_eligible_vt_regions() {
	Dictionary eligible_regions;
	if (_vt.vt_debug_direct_material) {
		return eligible_regions;
	}
	Camera3D *camera = get_camera();
	const bool view_selection = _vt.surface_vt_selection_mode == 0 && camera;
	const TypedArray<Plane> planes = view_selection ? camera->get_frustum() : TypedArray<Plane>();
	const Rect2i avt_regions = get_surface_vt_region_rect();
	for (const Vector2i &location : _data->get_region_locations()) {
		if (avt_regions.has_point(location) && (!view_selection ||
				terrain_region_in_frustum(_data, location, _region_size * _vertex_spacing, planes))) {
			eligible_regions[location] = true;
		}
	}
	return eligible_regions;
}

// How many pages each eligible sector may use. Sectors the camera sees closely keep
// more of them; the whole mip hierarchy is reserved before detail is reduced, so a
// shrink never discards a sector.
Dictionary Terrain3D::_compute_adaptive_sector_sizes(const Dictionary &p_eligible, int p_max_pages_per_axis) {
	Dictionary adaptive_sizes;
	if (!_vt.vt_adaptive_enabled || _vt.vt_debug_direct_material || _vt.surface_vt_force_mip || !get_camera()) {
		return adaptive_sizes;
	}
	TerrainVT::VisibleView view(get_camera());
	struct SectorDemand { Vector2i location; int size; float distance; };
	std::vector<SectorDemand> demands;
	const float world = _region_size * _vertex_spacing;
	const int capacity = has_svt_delivery() ? MAX(1, _vt.surface_vt->get_page_count() / 2) : _vt.surface_vt->get_page_count();
	auto cost = [](int size) { return (4 * size * size - 1) / 3; };
	int total = 0;
	for (const Variant &key : p_eligible.keys()) {
		Vector2i location = key;
		TerrainVT::VisiblePatch visible;
		if (!view.sample(Rect2(Vector2(location) * world, Vector2(world, world)), _data->get_region(location)->get_height_range(), visible)) {
			// Explicit Target Grid can include off-screen sectors; retain a base page.
			visible.density = 0.f;
		}
		const float wanted = world * visible.density * _vt.surface_vt_texels_per_pixel / _vt.surface_vt->get_page_size();
		int size = 1;
		while (size < p_max_pages_per_axis && size < wanted) { size <<= 1; }
		// Separate grow/shrink thresholds avoid toggling at projection boundaries.
		if (_vt.surface_vt->has_sector(location)) {
			int previous = _vt.surface_vt->get_sector_block_size(location);
			if (wanted >= previous * 0.4f && wanted <= previous * 1.1f) { size = MIN(previous, p_max_pages_per_axis); }
		}
		demands.push_back({ location, size, visible.distance });
		total += cost(size);
	}
	// Reserve the complete mip hierarchy, including coverage while finer pages
	// are produced. Reduce the least visible detail first, never discard sectors.
	while (total > capacity) {
		int reduce = -1;
		for (int i = 0; i < int(demands.size()); ++i) {
			if (demands[i].size > 1 && (reduce < 0 || demands[i].distance > demands[reduce].distance)) { reduce = i; }
		}
		if (reduce < 0) { break; }
		total -= cost(demands[reduce].size);
		demands[reduce].size >>= 1;
		total += cost(demands[reduce].size);
	}
	for (const SectorDemand &demand : demands) { adaptive_sizes[demand.location] = demand.size; }
	return adaptive_sizes;
}

// Returns virtual address blocks when terrain streams out or leaves AVT coverage;
// otherwise a long traversal eventually exhausts the atlas.
void Terrain3D::_retire_stale_vt_sectors(const Dictionary &p_eligible) {
	if (_vt.vt_debug_direct_material) {
		return;
	}
	std::unordered_set<Vector2i, Vector2iHash> released;
	for (const Variant &key : _vt.vt_registered_sectors.keys()) {
		Vector2i location = key;
		if (_data->get_region_id(location) < 0 || !p_eligible.has(location)) {
			_vt.surface_vt->unregister_sector_block(location);
			released.insert(location);
			_vt.vt_registered_sectors.erase(key);
		}
	}
	// One owner-index scan clears every retired sector's indirection entries;
	// unregister_sector() per sector would rescan it once per sector.
	_vt.surface_vt->release_sectors_pages(released);
}

// Gives this region a virtual block of the requested size. False means the block
// could not be allocated, so the region has to be skipped this pass.
bool Terrain3D::_prepare_vt_sector(const Vector2i &p_region_loc, int p_pages_per_axis) {
	if (!_vt.surface_vt->has_sector(p_region_loc)) {
		if (!_vt.surface_vt->register_sector(p_region_loc, p_pages_per_axis)) {
			return false;
		}
		_vt.surface_vt_blocks_dirty = true;
	} else if (_vt.surface_vt->get_sector_block_size(p_region_loc) != p_pages_per_axis) {
		_vt.surface_vt->resize_sector(p_region_loc, p_pages_per_axis);
		// Resizing keeps world footprints while changing their mip addresses.
		// Keep the inspector's records consistent with the remapped page table.
		for (auto &entry : _vt.vt_page_records) {
			Terrain3DVTState::PageRecord &record = entry.second;
			for (const Dictionary &owner : _vt.surface_vt->get_slot_owner_metadata(entry.first)) {
				if (bool(owner["world_space"]) || Vector2i(owner["sector"]) != p_region_loc) { continue; }
				const int mip = owner["mip"];
				record.mip = mip;
				record.address = Vector2i(owner["virtual"]) - Vector2i(
						_vt.surface_vt->get_sector_block_origin_x(p_region_loc) >> mip,
						_vt.surface_vt->get_sector_block_origin_y(p_region_loc) >> mip);
			}
		}
	}
	if (!_vt.vt_debug_direct_material) { _vt.vt_registered_sectors[p_region_loc] = true; }
	return true;
}

// The pages this sector needs: per-page mips resolve the detail the feedback asks
// for at each distance, and the near field keeps its whole mip chain resident.
std::vector<Vector3i> Terrain3D::_vt_page_requests_for_sector(const Vector2i &p_region_loc, int p_pages_per_axis,
		real_t p_distance, real_t p_page_world_size, int p_max_local_mip) {
	// Per-page mips: the feedback varies within a sector, which is the whole point
	// of it over a per-sector distance rule. Resolve every mip 0 page first, then
	// collect the pages actually needed at each level.
	std::vector<int> mip0(size_t(p_pages_per_axis) * p_pages_per_axis, -1);
	for (int page_y0 = 0; page_y0 < p_pages_per_axis; page_y0++) {
		for (int page_x0 = 0; page_x0 < p_pages_per_axis; page_x0++) {
			mip0[size_t(page_y0) * p_pages_per_axis + page_x0] = _surface_vt_mip_for_page(
					p_region_loc, page_x0, page_y0, p_distance, p_page_world_size, p_max_local_mip);
		}
	}
	std::vector<Vector3i> requests;
	for (int mip = 0; mip <= p_max_local_mip; mip++) {
		const int at = MAX(1, p_pages_per_axis >> mip);
		std::vector<uint8_t> need(size_t(at) * at, 0);
		for (int page_y0 = 0; page_y0 < p_pages_per_axis; page_y0++) {
			for (int page_x0 = 0; page_x0 < p_pages_per_axis; page_x0++) {
				const int page_mip = mip0[size_t(page_y0) * p_pages_per_axis + page_x0];
				// Exactly one level per mip 0 page: the shader walks mips fine to
				// coarse, so a page resolved to level L is served by the level L
				// page and needs no ancestor. -1 is culled, which leaves the
				// indirection entry alone and lets the array path serve the texel.
				if (page_mip != mip) {
					continue;
				}
				need[size_t(page_y0 >> mip) * at + (page_x0 >> mip)] = 1;
			}
		}
		for (int page_y = 0; page_y < at; page_y++) {
			for (int page_x = 0; page_x < at; page_x++) {
				if (need[size_t(page_y) * at + page_x]) {
					requests.push_back(Vector3i(page_x, page_y, mip));
				}
			}
		}
	}
	if (!_vt.vt_debug_direct_material && _vt.vt_adaptive_enabled && !_vt.surface_vt_force_mip) {
		// Keep an AVT mip chain resident. Growth remaps existing pages to their
		// new mip addresses; the shader keeps sampling them during refinement.
		requests.clear();
		for (int mip = p_max_local_mip; mip >= 0; --mip) {
			int at = MAX(1, p_pages_per_axis >> mip);
			for (int y = 0; y < at; ++y) {
				for (int x = 0; x < at; ++x) { requests.push_back(Vector3i(x, y, mip)); }
			}
		}
	}
	return requests;
}

// Produces and publishes the pages this pass allocated. A page that cannot be
// written is released again so a later pass can retry it.
int Terrain3D::_produce_missing_vt_pages(const Vector2i &p_region_loc, int p_pages_per_axis, real_t p_region_world,
		const std::vector<Vector3i> &p_missing) {
	std::vector<Ref<Image>> pages;
	if (_data->produce_surface_page_set(p_region_loc, p_pages_per_axis, _vt.surface_vt->get_page_size(),
				_vt.surface_vt->get_page_border(), p_missing, pages) < 0) {
		for (const Vector3i &request : p_missing) { _vt.surface_vt->release_page(p_region_loc, request.z, request.x, request.y); }
		return 0;
	}
	int produced = 0;
	for (int i = 0; i < int(p_missing.size()) && i < int(pages.size()); i++) {
		const int slot = _vt.surface_vt->lookup_page(p_region_loc, p_missing[i].z, p_missing[i].x, p_missing[i].y);
		if (slot >= 0 && _vt.surface_vt->write_page(slot, pages[i])) {
			float span = p_region_world / float(MAX(1, p_pages_per_axis >> p_missing[i].z));
			Rect2 rect(Vector2(p_region_loc) * p_region_world + Vector2(p_missing[i].x, p_missing[i].y) * span, Vector2(span, span));
			_queue_vt_material_page(slot, pages[i], rect, false, p_missing[i].z, Vector2i(p_missing[i].x, p_missing[i].y));
			produced++;
		} else {
			_vt.surface_vt->release_page(p_region_loc, p_missing[i].z, p_missing[i].x, p_missing[i].y);
		}
	}
	return produced;
}

// Publishes block origins/sizes in the same update as the remapped page table.
// Direct callers must not expose a new table with yesterday's shader block.
void Terrain3D::_publish_vt_block_tables(const PackedVector2Array &p_blocks, const PackedFloat32Array &p_sizes) {
	if (_vt.surface_vt_blocks != p_blocks) {
		_vt.surface_vt_blocks = p_blocks;
		_vt.surface_vt_blocks_dirty = true;
	}
	if (_vt.surface_vt_block_sizes != p_sizes) {
		_vt.surface_vt_block_sizes = p_sizes;
		_vt.surface_vt_blocks_dirty = true;
	}
	if (_vt.surface_vt_blocks_dirty && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
		_vt.surface_vt_blocks_dirty = false;
	}
}
