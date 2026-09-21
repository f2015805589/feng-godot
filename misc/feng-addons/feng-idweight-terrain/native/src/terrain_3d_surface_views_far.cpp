// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The two surface views, part 2 of 4: the far field's demand pass and its level rule.

// One of four files that define the two views and their demand passes. `update_surface_svt()` is one
// world-page grid walk around the reference the shader's level rule uses, in two modes: with the
// material pipeline on it hands the pages it allocates to `_update_visible_svt()` (in
// `terrain_3d_surface_views_far_walk.cpp`), and in `vt_debug_direct_material` it is the scan that fills each page
// itself through `_write_diagnostic_sparse_page()`. The level rule it walks -
// `get_surface_svt_mip_for_distance()` and `get_surface_svt_mip_reach()` - is here with it.
//
// The other halves: `terrain_3d_surface_views.cpp` (the views and the settings),
// `terrain_3d_surface_views_far_walk.cpp` (the root pyramid plan, the visible walk and the pass
// that spends the budget) and `terrain_3d_surface_views_near.cpp` (the near field's pass, its
// feedback pass and the sector machinery).

#include "terrain_3d.h"
#include "terrain_3d_surface_views_internal.h"

#include "logger.h"

#include <godot_cpp/classes/time.hpp>

///////////////////////////
// Surface virtual texture
///////////////////////////

// The far field's one distance -> level rule. Every consumer resolves a level through
// this function: the demand pass (which level to produce), the legacy grid scan and the
// shader uniform (which level to sample). An explicit table states the bands directly;
// without one, a mip m page covers `page_world * 2^m` metres, so level m is the right
// choice out to twice that distance and the bands follow the page size automatically.
// `p_max_mip` -1 means the level the far field currently publishes; the demand pass
// passes the indirection's absolute limit while it plans a frame, so a plan never depends
// on the level cap it is about to change.
//
// The rule itself is `TerrainVT::MipRule` in terrain_vt.h, beside the addressing contract it belongs
// to and where the engine-free contract test can pin it. This file owns only the two things that need
// the live settings: building the rule, and resolving the cap when the caller did not name one.
TerrainVT::MipRule Terrain3D::_svt_mip_rule() const {
	const PackedFloat32Array &bands = _vt.surface_svt_mip_distances;
	return TerrainVT::select_mip_rule(_vt.surface_svt_page_world,
			bands.is_empty() ? nullptr : bands.ptr(), int(bands.size()));
}

// The published level cap when `p_max_mip` does not name one.
int Terrain3D::_svt_mip_rule_cap(const int p_max_mip) const {
	return p_max_mip >= 0
			? p_max_mip
			: (_vt.surface_svt ? MAX(0, _vt.surface_svt->get_world_max_mip()) : MAX(0, _vt.surface_svt_max_mip));
}

int Terrain3D::get_surface_svt_mip_for_distance(const real_t p_distance, const int p_max_mip) const {
	return _svt_mip_rule().mip_for_distance(float(p_distance), _svt_mip_rule_cap(p_max_mip));
}

// Furthest distance an explicit table still serves with a produced page; 0 means the
// automatic rule, which coarsens without a limit of its own.
real_t Terrain3D::get_surface_svt_mip_reach() const {
	return _svt_mip_rule().reach(_svt_mip_rule_cap(-1));
}

// A page the raw-ID diagnostic mode allocates carries the packed id/weight payload the
// shader reads, cropped from the resident region maps at the page's own world rect. The
// crop is world aligned, so a page that spans several regions (or covers none) resolves
// every texel through its owning region, and the border ring reads the neighbours.
bool Terrain3D::_write_diagnostic_sparse_page(int p_slot, int p_page_x, int p_page_y, int p_local_mip,
		real_t p_page_world) {
	if (!_vt.vt_debug_direct_material || !_data || !_vt.surface_svt || p_slot < 0) {
		return false;
	}
	Ref<Image> page = _data->make_sparse_surface_page(p_page_x, p_page_y, p_local_mip, p_page_world,
			_vt.surface_svt->get_page_size(), _vt.surface_svt->get_page_border());
	return page.is_valid() && _vt.surface_svt->write_page(p_slot, page);
}

// One far-field demand pass. Pages are world aligned, so the set is a plain grid walk
// around the clipmap target; the mip comes from the page's distance, and only the pages
// this pass actually allocated are produced.
int Terrain3D::update_surface_svt(int p_max_pages) {
	// The workers this pass submits to are woken when it is over, not in the middle of it: the
	// file-scope SourceWakeFlush above says why, and its destructor covers every return below.
	SourceWakeFlush flush_wakes{ this };
	if (is_vt_editor_preview_active()) { return 0; }
	if (!_vt.vt_shared_ready || _vt.vt_materials_dirty) { _update_vt_service(); }
	_ensure_vt_views_ready();
	if (!_vt.surface_svt || !_data) {
		return 0;
	}
	if (!_vt.surface_svt->is_initialized()) {
		_vt.surface_svt->initialize();
		if (!_vt.surface_svt->is_initialized()) {
			return 0;
		}
	}
	_vt.surface_svt->set_allocation_budget(p_max_pages > 0 ? p_max_pages : -1);
	if (!_vt.vt_debug_direct_material) {
		const uint64_t svt_started = Time::get_singleton()->get_ticks_usec();
		const int produced = _update_visible_svt(p_max_pages);
		_vt.svt_cpu_ms = double(Time::get_singleton()->get_ticks_usec() - svt_started) / 1000.0;
		return produced;
	}
	const real_t page_world = MAX(0.001f, _vt.surface_svt_page_world);
	const real_t reach = MAX(page_world, _vt.surface_svt_distance);
	const Vector3 target = get_clipmap_target_position();
	// The level rule measures from the camera the shader renders with, so the diagnostic
	// scan has to measure from the same point: otherwise it publishes pages at levels the
	// shader does not start at, and the far field renders from whatever ancestor the walk
	// finds instead of from the page that was produced. Without a camera (CPU
	// diagnostics) the clipmap target stays the reference.
	Camera3D *reference_camera = get_camera();
	const Vector3 reference = (reference_camera && reference_camera->is_inside_tree())
			? reference_camera->get_global_position()
			: target;
	// Keep the public world-page API's int coordinates in a range where adding the
	// indirection half and multiplying by a mip scale cannot overflow. The old nested
	// loops converted an arbitrary distance directly to int, so a large editor distance
	// could wrap before the allocator had a chance to enforce its page budget.
	const int64_t coordinate_limit = int64_t(INT32_MAX) / 2;
	auto clamp_page_coordinate = [coordinate_limit](const double p_value) -> int64_t {
		if (p_value <= -double(coordinate_limit)) {
			return -coordinate_limit;
		}
		if (p_value >= double(coordinate_limit)) {
			return coordinate_limit;
		}
		return int64_t(p_value);
	};

	int64_t first_x = clamp_page_coordinate(Math::floor((double(reference.x) - double(reach)) / double(page_world)));
	int64_t last_x = clamp_page_coordinate(Math::floor((double(reference.x) + double(reach)) / double(page_world)));
	int64_t first_y = clamp_page_coordinate(Math::floor((double(reference.z) - double(reach)) / double(page_world)));
	int64_t last_y = clamp_page_coordinate(Math::floor((double(reference.z) + double(reach)) / double(page_world)));

	// A target/configuration key invalidates both cursors. Include the effective detail
	// bounds and loaded-region count so adding/removing streamed regions starts a fresh
	// pass without storing another lifetime-sensitive observer in Terrain3D.
	auto mix_hash = [](const uint32_t p_hash, const uint32_t p_value) -> uint32_t {
		return p_hash ^ (p_value + 0x9e3779b9u + (p_hash << 6) + (p_hash >> 2));
	};
	auto mix_i64 = [&mix_hash](uint32_t p_hash, const int64_t p_value) -> uint32_t {
		const uint64_t bits = uint64_t(p_value);
		p_hash = mix_hash(p_hash, uint32_t(bits));
		return mix_hash(p_hash, uint32_t(bits >> 32));
	};
	uint32_t scan_hash = 2166136261u;
	scan_hash = mix_i64(scan_hash, _vt.surface_svt->get_indirection_size());
	scan_hash = mix_i64(scan_hash, _vt.surface_svt->get_world_max_mip());
	scan_hash = mix_i64(scan_hash, _vt.surface_svt_root_mips);
	// The fallback policy decides which pages are pinned, so a changed policy is a changed scan.
	scan_hash = mix_i64(scan_hash, _vt.surface_svt_fallback_policy);
	scan_hash = mix_i64(scan_hash, _vt.surface_svt->get_page_count());
	scan_hash = mix_i64(scan_hash, int64_t(Math::floor(double(page_world))));
	scan_hash = mix_i64(scan_hash, int64_t(Math::floor(double(reach))));
	scan_hash = mix_i64(scan_hash, _data->get_region_locations().size());
	scan_hash = mix_i64(scan_hash, first_x);
	scan_hash = mix_i64(scan_hash, last_x);
	scan_hash = mix_i64(scan_hash, first_y);
	scan_hash = mix_i64(scan_hash, last_y);
	scan_hash = mix_i64(scan_hash, 1);
	const Vector3i scan_key(int(clamp_page_coordinate(Math::floor(double(target.x) / double(page_world)))),
			int(clamp_page_coordinate(Math::floor(double(target.z) / double(page_world)))),
			int(scan_hash & 0x7fffffffu));
	if (_vt.surface_svt_scan_key != scan_key) {
		_vt.surface_svt_scan_key = scan_key;
		_vt.surface_svt_root_cursor = 0;
		_vt.surface_svt_detail_cursor = 0;
	}

	int produced = 0;
	int allocations = 0;
	const int physical_page_count = MAX(1, _vt.surface_svt->get_page_count());
	const Dictionary residency = _vt.surface_svt->get_stats();
	int protected_count = MAX(0, int(residency.get("protected_count", 0)));
	const int protected_limit = physical_page_count / 2;
	int root_protection_budget = MAX(0, protected_limit - protected_count);

	const int root_max_mip = MAX(0, _vt.surface_svt->get_world_max_mip());
	const int root_mip_count = CLAMP(_vt.surface_svt_root_mips, 0, root_max_mip + 1);
	const int first_root = root_mip_count > 0 ? root_max_mip - root_mip_count + 1 : root_max_mip + 1;
	int64_t root_total = 0;
	for (int mip = root_max_mip; mip >= first_root; mip--) {
		const int64_t level_size = MAX(1, _vt.surface_svt->get_indirection_size() >> mip);
		root_total += level_size * level_size;
	}

	// A finite CPU budget is separate from the allocation budget. It bounds an extreme
	// root_mips=16/full-grid or distance=huge frame even when most candidates are hits.
	const int scan_budget = MAX(256, MIN(4096, physical_page_count * 4));

	// A completed cursor is normally left at the end while the pool is full. If an
	// invalidation removes a protected root, the reduced protected count opens budget
	// again; restart then so the missing root can be found without scanning every frame
	// while the cache is settled. Small legacy root sets retain their historical repeat
	// walk, which also lets an invalidated page be repaired on the next update.
	if (root_total > 0 && _vt.surface_svt_root_cursor >= root_total && root_protection_budget > 0) {
		_vt.surface_svt_root_cursor = 0;
	}

	int root_scanned = 0;
	while (_vt.surface_svt_root_cursor < root_total && root_scanned < scan_budget &&
			root_protection_budget > 0 && (p_max_pages <= 0 || allocations < p_max_pages)) {
		const int64_t root_index = _vt.surface_svt_root_cursor++;
		root_scanned++;
		int mip = first_root;
		int virtual_x = 0;
		int virtual_y = 0;
		int64_t level_index = root_index;
		for (mip = root_max_mip; mip >= first_root; mip--) {
			const int level_size = MAX(1, _vt.surface_svt->get_indirection_size() >> mip);
			const int64_t level_cells = int64_t(level_size) * level_size;
			if (level_index < level_cells) {
				virtual_x = int(level_index % level_size);
				virtual_y = int(level_index / level_size);
				break;
			}
			level_index -= level_cells;
		}
		const int level_size = MAX(1, _vt.surface_svt->get_indirection_size() >> mip);
		if (virtual_x < 0 || virtual_y < 0 || virtual_x >= level_size || virtual_y >= level_size) {
			continue;
		}
		bool was_miss = false;
		const int slot = _vt.surface_svt->request_virtual_page_internal(virtual_x, virtual_y, mip, &was_miss);
		if (slot < 0) {
			// A full protected pool cannot make progress in this pass. Leave the cursor
			// at the next candidate so a later unprotection can retry without rescanning
			// the whole level.
			break;
		}
		if (!was_miss) {
			if (!_vt.surface_svt->is_page_protected(slot) && root_protection_budget > 0) {
				_vt.surface_svt->protect_page(slot, true);
				protected_count++;
				root_protection_budget--;
			}
			continue;
		}
		allocations++;
		// A newly acquired physical slot may have an output from an evicted AVT/SVT
		// page. Invalidate that material result before the new page can be sampled.
		_invalidate_vt_slot(slot);
		const int half_at_mip = (_vt.surface_svt->get_indirection_size() >> 1) >> mip;
		const Vector2i address((virtual_x - half_at_mip) << mip, (virtual_y - half_at_mip) << mip);
		if (!_write_diagnostic_sparse_page(slot, address.x, address.y, mip, page_world)) {
			// The diagnostic mode has no material pipeline to fall back on, so a page
			// without content must not be published and pinned as if it were a root.
			_vt.surface_svt->release_world_page(address.x, address.y, mip);
			continue;
		}
		// A root page is the fallback of last resort. Protecting it leaves at least
		// half of the shared pool available to AVT, detail SVT, and offline baking.
		_vt.surface_svt->protect_page(slot, true);
		protected_count++;
		root_protection_budget--;
		produced++;
	}
	if (root_protection_budget <= 0) {
		// No further root can be made resident under the shared-pool cap. Avoid
		// repeatedly walking a potentially million-cell full-grid root on every tick.
		_vt.surface_svt_root_cursor = root_total;
	}

	int64_t detail_width = 0;
	int64_t detail_height = 0;
	int64_t detail_total = 0;
	if (first_x <= last_x && first_y <= last_y) {
		detail_width = last_x - first_x + 1;
		detail_height = last_y - first_y + 1;
		if (detail_width > 0 && detail_height > 0 && detail_width <= INT64_MAX / detail_height) {
			detail_total = detail_width * detail_height;
		}
	}
	int detail_scanned = 0;
	while (_vt.surface_svt_detail_cursor < detail_total && detail_scanned < scan_budget &&
			(p_max_pages <= 0 || allocations < p_max_pages)) {
		const int64_t detail_index = _vt.surface_svt_detail_cursor++;
		detail_scanned++;
		const int64_t page_x64 = first_x + detail_index % detail_width;
		const int64_t page_y64 = first_y + detail_index / detail_width;
		if (page_x64 < -coordinate_limit || page_x64 > coordinate_limit ||
				page_y64 < -coordinate_limit || page_y64 > coordinate_limit) {
			continue;
		}
		const int page_x = int(page_x64);
		const int page_y = int(page_y64);
		const real_t center_x = (real_t(page_x) + 0.5f) * page_world;
		const real_t center_z = (real_t(page_y) + 0.5f) * page_world;
		// Same measurement the shader makes for a fragment: the distance from the camera
		// to the page, with the page sampled on the ground plane.
		const real_t distance = Vector3(center_x, 0.f, center_z).distance_to(reference);
		if (distance > reach) {
			continue;
		}
		// Same distance -> level table the shader and the camera-visible pass use. The
		// grid measures from the same reference the level rule does - the camera the
		// shader renders with, or the clipmap target when there is none (see above) -
		// which is what keeps a diagnostic run and a rendered frame at the same levels.
		const int mip = get_surface_svt_mip_for_distance(distance);
		bool was_miss = false;
		const int slot = _vt.surface_svt->request_world_page_internal(page_x, page_y, mip, &was_miss);
		if (slot < 0) {
			break;
		}
		if (!was_miss) {
			continue;
		}
		allocations++;
		_invalidate_vt_slot(slot);

		if (!_write_diagnostic_sparse_page(slot, page_x, page_y, mip, page_world)) {
			// Nothing else can fill this slot in the diagnostic mode, so drop it again
			// instead of serving an unwritten layer until the next LRU pass recycles it.
			_vt.surface_svt->release_world_page(page_x, page_y, mip);
			continue;
		}
		produced++;
	}
	if (detail_total > 0 && _vt.surface_svt_detail_cursor >= detail_total) {
		_vt.surface_svt_detail_cursor = 0;
	}

	_vt.surface_svt->commit();
	// Both views may share the physical pool. An SVT allocation can evict an AVT
	// owner and dirty its indirection, so publish both tables before the next draw.
	if (_vt.surface_vt && _vt.surface_vt->is_initialized()) {
		_vt.surface_vt->commit();
	}
	_vt.surface_svt->set_allocation_budget(-1);
	return produced;
}
