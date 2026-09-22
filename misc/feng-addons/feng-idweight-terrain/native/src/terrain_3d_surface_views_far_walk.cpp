// The two surface views, part 3 of 4: the far field's visible walk and its demand pass.

// One of four files that define the two views and their demand passes. This one is what
// `update_surface_svt()` - the pass in terrain_3d_surface_views_far.cpp - delegates to while the
// material pipeline is on: `_svt_plan_roots()` pins the coarse root pyramid the fallback resolves
// through, `_svt_walk_visible_pages()` resolves the visible regions' footprints into pages nearest
// first, and `_update_visible_svt()` spends the tick's page budget on them. The legacy raw-ID
// diagnostic scan is the pass's other mode, and it stays with the pass.
//
// The other halves: terrain_3d_surface_views.cpp (the views and the settings that size them),
// terrain_3d_surface_views_far.cpp (the pass itself and the one distance -> level rule it walks)
// and terrain_3d_surface_views_near.cpp (the near field's pass, its feedback pass and the sector
// machinery). The one question both views ask of a resident page - has its content actually
// arrived - is `_vt_page_production_stale()`, which is page plumbing and lives with it in
// terrain_3d_vt_service_pages.cpp.
#include "terrain_3d_svt.h"
#include "terrain_3d.h"
#include "terrain_3d_material.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_3d_vt_visibility.h"
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/time.hpp>
#include <map>
#include <tuple>
#include <functional>

// Pins the far field's root pyramid over `p_domain`.
//
// The coarsest levels covering the whole SVT domain stay resident and protected, so any world
// position a fragment can address resolves to real coarse data instead of the diagnostic material.
// The candidate set is the domain and not the visible part of it, because the fallback has to answer
// wherever the shader walks - a root pinned only while visible is unpinned exactly when the camera
// turns away. At the level the view selects that set is thousands of pages, and the protection
// budget used to truncate it in row-major order, which left every pinned root in one corner of the
// map. Coverage is the requirement, so the window slides coarser until the whole domain fits the
// budget: the level is what gives way, never the coverage. The coarsest level the window reaches is
// published as the world mip cap, which is what lets the shader's walk reach it.
//
// The pyramid is baked static content and its pages are pinned, so a pass over the same identity
// would re-derive exactly the same set and re-request pages that are already resident and protected.
// The set's identity is hashed, and the plan is reused while the hash matches and the last walk
// pinned every root it planned. That is what keeps a baked far field at zero cost on the main thread
// while the view is still.
//
// Returns the four stages it spent its time in, in `Terrain3D::_update_visible_svt()`'s
// `ST_ROOTLIST`..`ST_ROOTCOV` order: the root list, releasing the previous plan's pins, requesting
// and pinning the new roots (queueing the ones with no content), and recording what the pinned set
// covers. A reused plan does none of the first three, so it reports only the fourth.
// The two fallback policies H2 of the alignment document names, as the one place that decides which
// pages answer a fragment whose selected page is not resident. Both return candidates as mip-0 page
// coordinates plus the level they are requested at, which is what `_svt_plan_roots()` publishes,
// pins and protects; everything downstream - the pin budget, the plan key, the reuse and verify
// path, coverage accounting - is the same for either, which is why the decision is a strategy and
// not a second code path in the pass.
//
// `Terrain3DSVTGlobalRootPyramid`: one complete level window over the *whole* addressable domain.
// Every world position a fragment can address resolves, at a granularity of kilometres per page -
// `indirection_size * page_world / 2^mip` metres - so a fallback page that lands or leaves changes a
// continent's worth of shading.
//
// `Terrain3DSVTPerUnitCoarsest`: the reference's `DeduplicateJob` guarantee - for every virtual image that is
// *resident* (here: every page the visible set selected), the coarsest level the world grid can
// express that contains it, requested unconditionally. The fallback's granularity becomes the unit
// the fragment is looking at rather than the domain, and the coarsest ancestor of a page is a
// function of the page, so the set moves with the detail set instead of with the world.
std::vector<Vector3i> Terrain3D::_svt_global_root_pyramid(const int p_indirection_size,
		const int p_protected_limit, const int p_root_top, const int p_root_first) {
	std::vector<Vector3i> roots;
	const int half_pages = p_indirection_size >> 1;
	for (int mip = p_root_top; mip >= p_root_first && int(roots.size()) < p_protected_limit; --mip) {
		const int level_size = MAX(1, p_indirection_size >> mip);
		const int first_index = -(half_pages >> mip);
		for (int iy = 0; iy < level_size && int(roots.size()) < p_protected_limit; ++iy) {
			for (int ix = 0; ix < level_size && int(roots.size()) < p_protected_limit; ++ix) {
				// Page requests and releases take a mip 0 page coordinate.
				roots.push_back(Vector3i((first_index + ix) << mip, (first_index + iy) << mip, mip));
			}
		}
	}
	return roots;
}

std::vector<Vector3i> Terrain3D::_svt_per_unit_coarsest(const std::vector<Terrain3DSVTPage> &p_visible,
		const int p_coarsest_mip, const int p_protected_limit) {
	std::vector<Vector3i> roots;
	if (p_coarsest_mip <= 0) { return roots; }
	auto floor_div = [](int value, int scale) { return int(std::floor(double(value) / double(scale))); };
	const int shift = p_coarsest_mip;
	for (const Terrain3DSVTPage &page : p_visible) {
		if (int(roots.size()) >= p_protected_limit) { break; }
		// The coarsest ancestor, in mip-0 page coordinates. `floor_div` and not `>>`: a page
		// coordinate is signed (the indirection is centred on the origin), and an arithmetic shift
		// rounds toward negative infinity only by implementation coincidence.
		const Vector3i root(floor_div(page.address.x, 1 << shift), floor_div(page.address.y, 1 << shift), shift);
		bool known = false;
		for (const Vector3i &existing : roots) {
			if (existing == root) { known = true; break; }
		}
		if (!known) { roots.push_back(root); }
	}
	return roots;
}

// Wrapper so `_svt_plan_roots()` reads as the policy it applies. The two strategies are alternatives,
// never layers: the caller publishes exactly one of them into `svt_roots.pages`.
std::vector<Vector3i> Terrain3D::_svt_fallback_pages(const int p_policy, const int p_maximum_mip,
		const int p_indirection_size, const int p_protected_limit, const int p_root_top, const int p_root_first,
		const std::vector<Terrain3DSVTPage> &p_visible) {
	if (p_policy == 1) { return _svt_per_unit_coarsest(p_visible, p_maximum_mip, p_protected_limit); }
	return _svt_global_root_pyramid(p_indirection_size, p_protected_limit, p_root_top, p_root_first);
}

std::array<double, 4> Terrain3D::_svt_plan_roots(const Rect2 &p_domain, const int p_maximum_mip,
		const int p_coverage_limit, const int p_physical_page_count, const int p_pass_budget,
		const std::vector<Terrain3DSVTPage> &p_visible, int &r_produced, bool &r_cached) {
	std::array<double, 4> stages{};
	uint64_t mark = Time::get_singleton()->get_ticks_usec();
	auto stamp_root = [&stages, &mark](const int p_index) {
		const uint64_t now = Time::get_singleton()->get_ticks_usec();
		stages[p_index] = double(now - mark) / 1000.0;
		mark = now;
	};
	// Near and far detail share this pool. Reserve only a quarter for permanent
	// far roots while the AVT service is live; keep the complete root window by sliding it
	// coarser, never by clipping its world coverage. Visible SVT LOD is unchanged. The
	// question is the *service*'s, not a group's: a cell that puts the height channel on
	// AVT holds pages from this pool exactly as the material channel does.
	const int protected_limit = MAX(4, p_physical_page_count / (has_avt_delivery() ? 4 : 2));
	const int root_levels = CLAMP(_vt.surface_svt_root_mips, 0, p_maximum_mip + 1);
	const int indirection_size = _vt.surface_svt->get_indirection_size();
	auto level_cells = [indirection_size](const int p_mip) {
		const int64_t size = MAX(1, indirection_size >> p_mip);
		return size * size;
	};
	int root_top = p_maximum_mip;
	if (root_levels > 0) {
		auto window_cells = [&](const int p_top) {
			int64_t total = 0;
			for (int mip = p_top; mip > p_top - root_levels && mip >= 0; --mip) {
				total += level_cells(mip);
			}
			return total;
		};
		while (window_cells(root_top) > int64_t(protected_limit) && root_top < p_coverage_limit) {
			++root_top;
		}
		if (root_top > p_maximum_mip) {
			// Levels coarser than the one the distance rule selects are only ever reached by
			// the fallback walk, so publishing a coarser cap does not change which level a
			// visible fragment samples.
			_vt.surface_svt->set_world_max_mip(root_top);
			if (_material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
			++_vt.svt_root_cap_raises;
		}
	}
	const int root_first = MAX(0, root_top - root_levels + 1);

	// Hash everything the set is a function of - the domain it covers, the level window, the
	// pool the pins live in, that pool's generation (a rebuilt pool drops every pin) and the
	// surface revision (an edit re-produces roots) - so the plan can be reused while it matches.
	uint64_t root_key = 1469598103934665603ull;
	auto root_mix = [&root_key](const uint64_t p_value) {
		root_key ^= p_value;
		root_key *= 1099511628211ull;
	};
	root_mix(uint64_t(int64_t(p_domain.position.x * 1000.0)));
	root_mix(uint64_t(int64_t(p_domain.position.y * 1000.0)));
	root_mix(uint64_t(int64_t(p_domain.get_end().x * 1000.0)));
	root_mix(uint64_t(int64_t(p_domain.get_end().y * 1000.0)));
	root_mix(uint64_t(uint32_t(p_maximum_mip)));
	root_mix(uint64_t(uint32_t(root_top)));
	root_mix(uint64_t(uint32_t(root_levels)));
	// The fallback policy is part of the set's identity: it decides which pages are pinned, so a
	// changed policy has to re-plan even when the domain, the window and the pool are unchanged.
	root_mix(uint64_t(uint32_t(_vt.surface_svt_fallback_policy)));
	root_mix(uint64_t(uint32_t(protected_limit)));
	root_mix(uint64_t(uint32_t(p_physical_page_count)));
	root_mix(uint64_t(uint32_t(_vt.pool.generation)));
	root_mix(uint64_t(_vt.vt_source_revision));

	// A cached plan is only reusable while every root it pinned is still published and still
	// has content: a caller can clear() the view directly, which empties the indirection
	// without touching the pool generation, and a production that never landed leaves the
	// entry published over an empty layer. Verifying that costs one read-only lookup per
	// root, which is less than the allocator bookkeeping the walk below would spend on the
	// same roots.
	bool cached = _vt.svt_roots.matches(root_key);
	if (cached) {
		// The roots are resolved first and verified in one batch: this loop runs on every
		// settled tick, and asking the producer about each root individually is a lock per
		// root.
		std::vector<int> &slots = _vt.svt_verify_slots;
		slots.clear();
		for (const Vector3i &root : _vt.svt_roots.pages) {
			int virtual_x = 0;
			int virtual_y = 0;
			_vt.surface_svt->world_page_to_virtual(root.x, root.y, root.z, virtual_x, virtual_y);
			const int slot = _vt.surface_svt->get_indirection_slot(virtual_x, virtual_y, root.z);
			if (slot == int(Terrain3DVirtualTexture::INVALID_SLOT)) {
				cached = false;
				break;
			}
			slots.push_back(slot);
		}
		if (cached) {
			Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
			if (producer) {
				producer->query_page_readiness(slots, _vt.svt_verify_ready);
			} else {
				_vt.svt_verify_ready.assign(slots.size(), uint8_t(0));
			}
			for (size_t i = 0; i < slots.size(); ++i) {
				if (_vt_page_production_stale(slots[i], _vt.svt_verify_ready[i] != 0 ? 1 : 0)) {
					cached = false;
					break;
				}
			}
		}
	}
	if (cached) {
		_vt.svt_root_skips++;
		if (!_vt.svt_startup_ready) {
			_vt.svt_startup_ready = true;
			if (_material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
		}
	} else {
		_vt.svt_root_passes++;
		// The guaranteed page set, from the policy that owns that decision. See the two strategies
		// above for what each guarantees.
		std::vector<Vector3i> next_roots = _svt_fallback_pages(_vt.surface_svt_fallback_policy,
				p_maximum_mip, indirection_size, protected_limit, root_top, root_first, p_visible);
		stamp_root(0);
		// A root outside the domain loses its pin, so a re-configured extent does not keep half
		// the pool reserved for the rest of the session. Leaving the visible bounds is no longer
		// a reason to unpin: that is what left the coarser level missing when it was needed.
		for (const Vector3i &previous : _vt.svt_roots.pages) {
			bool retained = false;
			for (const Vector3i &next : next_roots) {
				if (next == previous) { retained = true; break; }
			}
			if (retained) { continue; }
			// Drop the pin only. Releasing the page would also remove the owner entry that a
			// detail page may share with this root - publish_owner() dedups by virtual
			// coordinate and level - and an unpinned page is reclaimed by the LRU anyway.
			int virtual_x = 0;
			int virtual_y = 0;
			_vt.surface_svt->world_page_to_virtual(previous.x, previous.y, previous.z, virtual_x, virtual_y);
			const int slot = _vt.surface_svt->get_indirection_slot(virtual_x, virtual_y, previous.z);
			if (slot != int(Terrain3DVirtualTexture::INVALID_SLOT)) { _vt.surface_svt->protect_page(slot, false); }
		}
		_vt.svt_roots.pages = next_roots;
		stamp_root(1);

		// A root the allocator could not hand out this pass has to be retried, so the plan
		// is only reusable once every root was pinned.
		bool settled = true;
		for (const Vector3i &root : next_roots) {
			// Deliberately not cut on the deadline. An unfinished plan leaves `settled` false,
			// which throws the whole root plan away and rebuilds it next tick - and a rebuild
			// that is again cut short never settles, so the far field churns through its root
			// list on every tick instead of settling once. The root set is bounded by the pin
			// budget and its identity only changes on a reconfiguration, so it is left to
			// finish; the walk and the detail loop above and below are what the deadline cuts.
			bool miss = false;
			const int slot = _vt.surface_svt->request_world_page_internal(root.x, root.y, root.z, &miss);
			if (slot < 0) { settled = false; continue; }
			// A root that gets evicted leaves a miss with nothing coarser to show, which is
			// the whole reason the pyramid exists. The pin is reference counted and this walk
			// runs again on every camera move, so it is taken once: re-pinning a root that is
			// already protected made the count outlive the plan and kept half the pool
			// reserved for roots that no longer cover anything.
			if (!_vt.surface_svt->is_page_protected(slot)) { _vt.surface_svt->protect_page(slot, true); }
			// A published root without content is produced again; only the allocator failing
			// to hand out a slot leaves the plan unsettled.
			const bool root_stale = _vt_page_production_stale(slot);
			if (!miss && !root_stale) { continue; }
			// Queueing is what costs. A root page with no cell source crops its payload from the
			// density-scaled region data on this thread, so a rebuilt pyramid used to put the
			// whole set into one tick - measured at 213.9 ms for twenty roots in section 7.7.8,
			// and every one of those passes was paid again whenever the set was rebuilt.
			//
			// Pinning is free and is what the fallback needs, so the pin above stays
			// unconditional and only the queue is gated, by two bounds and a floor of one page:
			// the pass's own page budget - a root is a page like any other, and the pass already
			// knows how many it may produce - and the optional tick deadline beyond it. The floor
			// keeps a pass whose budget is already spent making progress. A root that is skipped
			// keeps no content, so the readiness check at the top of this pass reopens the plan
			// next tick and the pyramid arrives as a ramp over the passes the budget allows
			// instead of as one hitch. `continue` and not `break`: the rest of the roots still
			// have to be pinned.
			if (r_produced > 0 && (r_produced >= MAX(1, p_pass_budget) || _vt_tick_expired())) { continue; }
			_vt.svt_requeues++;
			_invalidate_vt_slot(slot);
			Ref<Image> payload;
			const float span = _vt.surface_svt_page_world * float(1 << root.z);
			_queue_vt_material_page(slot, payload, Rect2(Vector2(root.x, root.y) * _vt.surface_svt_page_world, Vector2(span, span)),
					true, root.z, Vector2i(root.x, root.y));
			r_produced++;
		}
		stamp_root(2);
		// What the pinned set covers, which is what the fallback can answer with.
		_vt.svt_roots.coverage = Rect2();
		_vt.svt_roots.level_min = -1;
		_vt.svt_roots.level_max = -1;
		for (const Vector3i &root : next_roots) {
			const float span = _vt.surface_svt_page_world * float(1 << root.z);
			const Rect2 footprint(Vector2(root.x, root.y) * _vt.surface_svt_page_world, Vector2(span, span));
			_vt.svt_roots.coverage = _vt.svt_roots.coverage.size.x <= 0.f ? footprint : _vt.svt_roots.coverage.merge(footprint);
			_vt.svt_roots.level_min = _vt.svt_roots.level_min < 0 ? root.z : MIN(_vt.svt_roots.level_min, root.z);
			_vt.svt_roots.level_max = MAX(_vt.svt_roots.level_max, root.z);
		}
		_vt.svt_roots.key = root_key;
		_vt.svt_roots.settled = settled;
		// `settled` means every address was allocated. Content readiness is verified by the
		// cached pass above on the next tick; do not expose strict SVT before that verification.
	}
	// Stamped on both paths, which is what the pass's own stamping did: a reused plan does none of
	// the work above, so everything it did spend lands in this stage.
	stamp_root(3);
	r_cached = cached;
	return stages;
}

// Select exactly the shader distance bands. Shared capacity limits residency,
// never changes the requested mip or substitutes an ancestor.
// The pages the visible regions' footprints resolve to, nearest first, plus how many footprints the
// walk visited. A recursive descent from the plan's coarsest level, bounded by a footprint count
// rather than by replacing requested levels with their ancestors.
//
// Deliberately not cut on the tick deadline. The walk feeds `maximum_mip`, which is part of the root
// plan's identity: a walk that stops in a different place on every tick makes the selected level -
// and so the root key - oscillate, which throws the root pyramid away and rebuilds it every tick. It
// is also cheap, so there is nothing to gain by cutting it.
std::vector<Terrain3DSVTPage> Terrain3D::_svt_walk_visible_pages(
		const std::vector<Terrain3DSVTRegion> &p_regions, const TerrainVT::VisibleView &p_view,
		const std::function<bool(const Rect2 &)> &p_avt_interior, const Rect2 &p_domain,
		const float p_page_world,
		const int p_plan_limit, int &r_visited) {
	std::map<std::tuple<int, int, int>, Terrain3DSVTPage> unique;
	// Traverse visible footprints, not every mip-0 cell of an entire region.
	// A high SVT texel density must not be silently capped to 16 pages/region.
	// Bound pathological traversal without replacing requested levels with ancestors.
	const int visit_limit = MAX(4096, _vt.surface_svt->get_page_count() * 128);
	for (const Terrain3DSVTRegion &region : p_regions) {
		if (!region.rect.intersects(p_domain)) { continue; }
		const Rect2 resident = region.rect.intersection(p_domain);
		std::function<void(int, int, int)> visit = [&](int x, int y, int mip) {
			// Deliberately not cut on the deadline. The walk feeds `maximum_mip`, which is
			// part of the root plan's identity: a walk that stops in a different place on
			// every tick makes the selected level - and so the root key - oscillate, which
			// throws the root pyramid away and rebuilds it every tick. It is also cheap
			// (0.02 ms for the visible set below), so there is nothing to gain by cutting it.
			const float span = p_page_world * float(1 << mip);
			const Rect2 footprint(Vector2(x, y) * span, Vector2(span, span));
			if (!footprint.intersects(resident)) { return; }
			const Rect2 clipped = footprint.intersection(resident);
			if (p_avt_interior(clipped)) { return; }
			TerrainVT::VisiblePatch visible;
			// Coarse ancestors commonly clip to the same complete region. Reuse
			// its exact query, including grazing-p_view density and distance bounds.
			if (clipped == region.rect) { visible = region.visible; }
			else if (!p_view.sample(clipped, region.heights, visible)) { return; }
			++r_visited;
			const int near_mip = get_surface_svt_mip_for_distance(MAX(0.f, visible.distance - MAX(2.f, visible.distance * 0.03f)), p_plan_limit);
			const int far_mip = get_surface_svt_mip_for_distance(MAX(visible.distance, visible.farthest) * 1.03f + 2.f, p_plan_limit);
			if (mip < near_mip) { return; }
			if (mip <= far_mip) {
				const Vector2i address(x * (1 << mip), y * (1 << mip));
				const auto key = std::make_tuple(mip, address.x, address.y);
				auto found = unique.find(key);
				if (found == unique.end() || visible.distance < found->second.distance) { unique[key] = { address, mip, visible.distance }; }
			}
			if (mip > near_mip && r_visited < visit_limit) {
				for (int dy = 0; dy < 2; ++dy) { for (int dx = 0; dx < 2; ++dx) { visit(x * 2 + dx, y * 2 + dy, mip - 1); } }
			}
		};
		const float root_span = p_page_world * float(1 << p_plan_limit);
		for (int y = int(Math::floor(resident.position.y / root_span)); y < int(Math::ceil(resident.get_end().y / root_span)); ++y) {
			for (int x = int(Math::floor(resident.position.x / root_span)); x < int(Math::ceil(resident.get_end().x / root_span)); ++x) { visit(x, y, p_plan_limit); }
		}
	}
	std::vector<Terrain3DSVTPage> pages;
	pages.reserve(unique.size());
	for (const auto &entry : unique) { pages.push_back(entry.second); }
	std::sort(pages.begin(), pages.end(), [](const Terrain3DSVTPage &a, const Terrain3DSVTPage &b) {
		if (a.distance != b.distance) { return a.distance < b.distance; }
		return std::make_tuple(a.mip, a.address.y, a.address.x) < std::make_tuple(b.mip, b.address.y, b.address.x);
	});
	return pages;
}

int Terrain3D::_update_visible_svt(int p_max_pages) {
	Camera3D *camera = get_camera();
	if (!camera || !camera->is_inside_tree()) { return 0; }
	// Where this pass spends its time, published as `svt_stats` when it becomes the worst
	// pass. The stages are collected in locals rather than written into the dictionary as
	// they finish: the far field's peak is what needs attributing, and a dictionary write
	// per stage would put the instrumentation on the hot path it is measuring.
	enum Stage { ST_REGIONS, ST_WALK, ST_CAPACITY, ST_MIP, ST_ROOTLIST, ST_ROOTUNPIN, ST_ROOTREQ, ST_ROOTCOV, ST_DETAIL, ST_COUNT };
	std::array<double, ST_COUNT> stage{};
	int stage_at = 0;
	const uint64_t pass_started = Time::get_singleton()->get_ticks_usec();
	uint64_t mark = pass_started;
	auto stamp = [&](int p_stage) {
		const uint64_t now = Time::get_singleton()->get_ticks_usec();
		for (int i = stage_at; i <= p_stage; ++i) { stage[i] = 0.0; }
		stage[p_stage] = double(now - mark) / 1000.0;
		stage_at = p_stage + 1;
		mark = now;
	};
	// The far field plans for the predicted camera as well: its pages are assembled from
	// cells, so a page demanded the moment its footprint enters the frustum is late by a
	// bake plus a read as well.
	const Transform3D lead_transform = _vt_lead_camera_transform(camera->get_camera_transform());
	const float viewport_height = camera->get_viewport() ? camera->get_viewport()->get_visible_rect().size.y : 720.f;
	TerrainVT::VisibleView view(lead_transform, camera->get_camera_projection(), viewport_height,
			camera->get_projection() == Camera3D::PROJECTION_ORTHOGONAL, 48.f);
	std::vector<Terrain3DSVTRegion> regions;
	const Vector3 camera_position = lead_transform.origin;
	const Vector2 focus(camera_position.x, camera_position.z);
	auto avt_interior = [&](const Rect2 &rect) {
		Vector2 farthest(MAX(Math::abs(rect.position.x - focus.x), Math::abs(rect.get_end().x - focus.x)),
				MAX(Math::abs(rect.position.y - focus.y), Math::abs(rect.get_end().y - focus.y)));
		return has_avt_delivery() && is_sector_avt() && farthest.length() < MAX(64.f, float(_vt.surface_vt_distance)) * 0.75f;
	};
	const float region_world = _region_size * _vertex_spacing;
	const float page_world = MAX(0.001f, _vt.surface_svt_page_world);
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		// Legacy region AVT owns whole regions; sector AVT excludes only the
		// metric near interior during footprint traversal below.
		if (has_avt_delivery() && !is_sector_avt() && _vt.vt_registered_sectors.has(location)) { continue; }
		Rect2 rect(Vector2(location) * region_world, Vector2(region_world, region_world));
		TerrainVT::VisiblePatch visible;
		if (!view.sample(rect, region->get_height_range(), visible)) { continue; }
		regions.push_back({ rect, region->get_height_range(), visible.distance, visible.farthest, visible });
	}
	std::sort(regions.begin(), regions.end(), [](const Terrain3DSVTRegion &a, const Terrain3DSVTRegion &b) { return a.distance < b.distance; });
	float farthest_distance = 0.f;
	for (const Terrain3DSVTRegion &region : regions) { farthest_distance = MAX(farthest_distance, region.farthest); }
	const int region_count = int(regions.size());
	stamp(ST_REGIONS);

	// The centered indirection keeps the four world quadrants apart at its coarsest level,
	// and a page has to stay inside the table it is published in. That is the absolute
	// level limit for this frame; the effective limit is raised below to whatever the
	// detail and coverage sets actually use.
	const int configured_mip = _vt.surface_svt->get_world_max_mip();
	const int coverage_limit = MAX(0, TerrainVT::log2_power_of_two(_vt.surface_svt->get_indirection_size()) - 1);
	// Levels are planned against the absolute limit, not against the currently published
	// one, so a raise never has to be recomputed: the plan states the levels this frame
	// wants and the raise below publishes exactly those.
	const int plan_limit = coverage_limit;
	// The addressable domain, from the indirection size. Both the walk and the root plan below are
	// bounded by it, so it is computed here rather than inside either of them.
	const float half_world = _vt.surface_svt->get_indirection_size() * page_world * 0.5f;
	const Rect2 domain(Vector2(-half_world, -half_world), Vector2(half_world * 2.f, half_world * 2.f));

	int walk_visited = 0;
	std::vector<Terrain3DSVTPage> pages = _svt_walk_visible_pages(regions, view, avt_interior,
			domain, page_world, plan_limit, walk_visited);
	const int visible_page_count = int(pages.size());
	stamp(ST_WALK);
	// The near field's share of the request is its *sampled* pages: the apron is sized by the
	// leftover budget, so counting it would make the capacity follow the budget that the
	// capacity itself allows. No floor of one either - a request of zero pages must not ask for
	// a minimum block of slots on every empty plan.
	if (_ensure_vt_capacity(int(pages.size()) + (has_avt_delivery() ? int(_vt.avt_plan.pages.size()) : 0))) { return 0; }
	stamp(ST_CAPACITY);

	// The physical pool is shared with the near field, so the far field only claims what
	// the near field is not holding.
	const int physical_page_count = MAX(1, _vt.surface_svt->get_page_count());
	_vt.vt_svt_visible_pages = int(pages.size());
	const int near_reserve = has_avt_delivery() ? MIN(physical_page_count / 2, int(_vt.avt_plan.pages.size())) : 0;
	const int capacity = MAX(1, physical_page_count - near_reserve);

	// Publish the level this frame uses. A saved maximum detail level is only ever raised,
	// never lowered, so a view that already extended the hierarchy keeps it.
	int used_mip = configured_mip;
	for (const Terrain3DSVTPage &page : pages) { used_mip = MAX(used_mip, page.mip); }
	// The rule as a value, once for the pass: the cap raise below is the automatic rule's business
	// only, and it asks the rule rather than the settings which one is active.
	const TerrainVT::MipRule mip_rule = _svt_mip_rule();
	if (!regions.empty() && mip_rule.kind == TerrainVT::MipRuleKind::AutomaticBands) {
		// With the automatic rule a saved cap must not hide terrain the view can see, so
		// the hierarchy extends to the level the farthest visible point selects. The
		// raise is a function of the visible set rather than of pool pressure, and it
		// only ever grows, so it cannot make a level move back and forth.
		used_mip = MAX(used_mip, mip_rule.mip_for_distance(farthest_distance, plan_limit));
	}
	const int maximum_mip = MIN(used_mip, plan_limit);
	if (maximum_mip != configured_mip) {
		// H3 step 1: a cap change is not a content change. A resident indirection entry stays valid
		// across it - `virtual = (page + half) >> mip` is level-invariant - so raising the cap enables
		// coarser *requests* and moves nothing that is already published. What it does have to do is
		// publish the cap, because `_surface_svt_max_mip` is what the shader's coarser walk clamps
		// against, and a stale uniform would leave the new level unreachable.
		//
		// This used to mark every region in the world bake-dirty and rebuild the material's region
		// arrays, which is a whole-world re-bake for a bound on which mips `request_world_page()`
		// accepts. Nothing was waiting on that sweep: the level's pages are requested by the walk
		// below like any other page and the producer serves them from the persisted catalogue, which
		// already holds the cell's mip chain. The landing measurement (the turned phase of
		// `vt_svt_coverage`) produced and served a page at the new level with no region marked, and
		// `docs/vt_reference_avt_alignment.md` section 7.7.6 records it. It is exactly the heavy hammer
		// section 4/H3 was written about.
		const int region_marks_before = int(_vt.bake.dirty_regions.size());
		const uint64_t cap_mark = Time::get_singleton()->get_ticks_usec();
		_vt.surface_svt->set_world_max_mip(maximum_mip);
		if (_material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
		const double cap_ms = double(Time::get_singleton()->get_ticks_usec() - cap_mark) / 1000.0;
		++_vt.svt_cap_changes;
		// The regions this change itself marked for re-bake - the increase across it, not the size
		// afterwards - because that is what H3 step 1 claims is zero and what `vt_svt_coverage`
		// asserts. Reading the size would report whatever an unrelated edit had already queued. A
		// regression that reintroduces the sweep shows up here.
		const int region_marks_after = int(_vt.bake.dirty_regions.size());
		_vt.svt_cap_dirty_regions = uint64_t(MAX(0, region_marks_after - region_marks_before));
		_vt.svt_cap_change_ms += cap_ms;
		_vt.svt_cap_change_worst_ms = MAX(_vt.svt_cap_change_worst_ms, cap_ms);
		_vt.svt_cap_last_from = configured_mip;
		_vt.svt_cap_last_to = maximum_mip;
	}

	// The root pyramid is its own unit - pinning it, reusing or verifying the previous plan, and
	// recording what it covers - so it lives in `_svt_plan_roots()`. Its doc comment says what the
	// pyramid is for.
	stamp(ST_MIP);
	int produced = 0;
	bool roots_cached = false;
	std::array<double, 4> root_stages = _svt_plan_roots(domain, maximum_mip, coverage_limit,
			physical_page_count, p_max_pages, pages, produced, roots_cached);
	for (int i = 0; i < 4; ++i) { stage[ST_ROOTLIST + i] = root_stages[i]; }
	stage_at = ST_ROOTCOV + 1;
	mark = Time::get_singleton()->get_ticks_usec();
	const int root_count = int(_vt.svt_roots.pages.size());

	// Over-subscription raises a shared coarseness floor instead of dropping the far end of
	// the working set: a page finer than the floor is published at the floor, while a page
	// already coarser than it keeps the level the distance rule gave it. Every visible
	// footprint therefore still resolves through a page of some real level, and the floor is
	// the smallest one that fits - a function of the visible set and the remaining capacity
	// alone - so a settled view selects the same floor, levels and pages on every pass.
	const int detail_capacity = MAX(1, capacity - int(_vt.svt_roots.pages.size()));
	// Published beside the floor below: the two are one decision, and a reader that only sees the
	// floor cannot tell whether the pool had room.
	_vt.svt_detail_capacity = detail_capacity;
	std::vector<Terrain3DSVTPage> chosen;
	_vt.svt_floor_level = 0;
	if (int(pages.size()) <= detail_capacity) {
		chosen = pages;
	} else {
		for (int candidate = 0; candidate <= maximum_mip && chosen.empty(); ++candidate) {
			std::map<std::tuple<int, int, int>, float> merged;
			for (const Terrain3DSVTPage &page : pages) {
				const int level = MAX(page.mip, candidate);
				const auto key = std::make_tuple(level, page.address.x, page.address.y);
				const auto found = merged.find(key);
				if (found == merged.end() || page.distance < found->second) { merged[key] = page.distance; }
			}
			if (int(merged.size()) > detail_capacity) { continue; }
			_vt.svt_floor_level = candidate;
			chosen.reserve(merged.size());
			for (const auto &entry : merged) {
				Terrain3DSVTPage page;
				page.mip = std::get<0>(entry.first);
				page.address = Vector2i(std::get<1>(entry.first), std::get<2>(entry.first));
				page.distance = entry.second;
				chosen.push_back(page);
			}
		}
		if (chosen.empty()) {
			// Even the coarsest floor does not fit. Keep the nearest pages and let the
			// shader's coarse walk and the root pyramid cover the rest.
			_vt.svt_floor_level = maximum_mip;
			chosen.assign(pages.begin(), pages.begin() + MIN(int(pages.size()), detail_capacity));
		}
		std::sort(chosen.begin(), chosen.end(), [](const Terrain3DSVTPage &a, const Terrain3DSVTPage &b) {
			if (a.distance != b.distance) { return a.distance < b.distance; }
			return std::make_tuple(a.mip, a.address.y, a.address.x) < std::make_tuple(b.mip, b.address.y, b.address.x);
		});
	}

	const int chosen_count = int(chosen.size());
	// Each page is requested and acted on before the next one is: `request_world_page_internal`
	// can hand out the slot an earlier request just evicted, so a slot collected for a later
	// batch would no longer be the page it was collected for.
	int visited = 0;
	for (const Terrain3DSVTPage &request : chosen) {
		if (visited >= detail_capacity) { break; }
		// Deliberately not cut on the deadline. Visiting a page is what re-marks it as
		// demanded; a page this loop skips keeps its slot but loses the mark, so the pool
		// evicts it and the next tick has to request, invalidate and re-queue it - and the
		// queue is the expensive half, since a page with no baked cell assembles its source
		// on this thread. The deadline could not bound that anyway: the floor below always
		// allows the first page, which is the expensive one. The set is bounded by the
		// physical pool, so the loop is bounded too.
		visited++;
		bool miss = false;
		const int slot = _vt.surface_svt->request_world_page_internal(request.address.x, request.address.y, request.mip, &miss);
		if (slot < 0) { continue; }
		// The table says this address is published; the producer says whether anything is
		// there. A detail page that never landed is produced again here instead of being
		// sampled as an empty layer for the rest of the session.
		const bool detail_stale = _vt_page_production_stale(slot);
		if (!miss && !detail_stale) { continue; }
		_vt.svt_requeues++;
		_invalidate_vt_slot(slot);
		// Both disk reads and source-ID construction belong to the source worker.
		Ref<Image> payload;
		const float span = _vt.surface_svt_page_world * float(1 << request.mip);
		_queue_vt_material_page(slot, payload, Rect2(Vector2(request.address) * _vt.surface_svt_page_world, Vector2(span, span)),
				true, request.mip, request.address);
		produced++;
		// The allocator enforces the production budget. Keep visiting the rest of the
		// working set so resident pages remain protected this frame.
	}
	_vt.surface_svt->commit();
	if (_vt.surface_vt && _vt.surface_vt->is_initialized()) { _vt.surface_vt->commit(); }
	_vt.surface_svt->set_allocation_budget(-1);
	stamp(ST_DETAIL);
	const double pass_ms = double(Time::get_singleton()->get_ticks_usec() - pass_started) / 1000.0;
	// Only the pass that becomes the new worst publishes its breakdown. The dictionary is
	// String keyed, and a running view's typical pass is a tenth of its worst one, so
	// writing every stage on every tick would put the instrumentation on the hot path.
	if (pass_ms >= _vt.svt_worst_ms) {
		_vt.svt_worst_ms = pass_ms;
		_vt.svt_worst_frame = Engine::get_singleton()->get_process_frames();
		Dictionary &stats = _vt.svt_stats;
		stats["pass_ms"] = pass_ms;
		stats["regions"] = region_count;
		stats["regions_ms"] = stage[ST_REGIONS];
		stats["walk_visited"] = walk_visited;
		stats["visible_pages"] = visible_page_count;
		stats["walk_ms"] = stage[ST_WALK];
		stats["capacity_ms"] = stage[ST_CAPACITY];
		stats["mip_ms"] = stage[ST_MIP];
		stats["roots"] = root_count;
		stats["roots_skipped"] = roots_cached;
		stats["rootlist_ms"] = stage[ST_ROOTLIST];
		stats["rootunpin_ms"] = stage[ST_ROOTUNPIN];
		stats["rootreq_ms"] = stage[ST_ROOTREQ];
		stats["rootcov_ms"] = stage[ST_ROOTCOV];
		stats["chosen"] = chosen_count;
		stats["detail_capacity"] = detail_capacity;
		stats["visited"] = visited;
		stats["produced"] = produced;
		stats["requeues"] = int(_vt.svt_requeues);
		stats["detail_ms"] = stage[ST_DETAIL];
	}
	return produced;
}

// The far field's half of `get_vt_settings()`: the level rule's density and world window, the root
// pyramid the last walk pinned, and the counters that say a baked far field costs nothing per
// frame. It is written here rather than in the report file because every key below reads a field
// this family owns.
void Terrain3D::_report_svt(Dictionary &r_result) const {
	Dictionary &result = r_result;
	result["svt_texels_per_meter"] = get_surface_svt_texels_per_meter();
	result["svt_world_extent"] = (_vt.surface_svt ? _vt.surface_svt->get_indirection_size() : MAX(64, _vt.surface_svt_page_count * 4)) * _vt.surface_svt_page_world;
	result["svt_effective_max_mip"] = _vt.surface_svt ? _vt.surface_svt->get_world_max_mip() : _vt.surface_svt_max_mip;
	result["svt_feedback"] = _vt.svt_feedback;
	// Far-field residency diagnostics: the root pyramid the last pass pinned, and the
	// coarseness floor it raised its detail pages to (0 when the set fit).
	result["svt_root_pages"] = int(_vt.svt_roots.pages.size());
	// What the pinned set covers and which levels it used. The fallback can only answer
	// inside this rect, so it is the property a test checks.
	result["svt_root_coverage"] = _vt.svt_roots.coverage;
	result["svt_root_level_min"] = _vt.svt_roots.level_min;
	result["svt_root_level_max"] = _vt.svt_roots.level_max;
	// Which set answers a non-resident fragment, and how many pages it is pinned as. The pair is
	// what a measurement of the two policies reports: the granularity is `root_page_world` wide, so
	// the policy with the larger count has the finer - and therefore smaller - update trace.
	result["svt_fallback_policy"] = _vt.surface_svt_fallback_policy;
	result["svt_root_page_world"] = _vt.svt_roots.level_max >= 0
			? double(_vt.surface_svt_page_world * float(1 << _vt.svt_roots.level_max))
			: 0.0;
	// Pages demand produced again because the table named them and the producer had no
	// content. A settled view must stop growing this.
	result["svt_requeues"] = int64_t(_vt.svt_requeues);
	// Root walks that ran and passes that reused the plan. A baked far field settles after
	// one walk, so the skip count is what proves the fallback costs nothing per frame.
	result["svt_root_passes"] = int64_t(_vt.svt_root_passes);
	result["svt_root_skips"] = int64_t(_vt.svt_root_skips);
	// The cell sources' own cost: cells the persisted-bake probe examined, and pages it refused
	// to examine because they cover more cells than a cell source can serve. A pass that spends
	// its time on the first without the second is a pass asking the disk about a page the disk
	// cannot assemble; section 7.7.13 has the reading.
	result["svt_persist_probe_cells"] = int64_t(_vt.svt_persist_probe_cells);
	result["svt_persist_probe_skips"] = int64_t(_vt.svt_persist_probe_skips);
	result["svt_floor_level"] = _vt.svt_floor_level;
	result["svt_detail_capacity"] = _vt.svt_detail_capacity;
	// P0/H3: the world mip cap's change history. `svt_cap_changes` counts the level changes,
	// `svt_cap_dirty_regions` how many region re-bakes they caused - zero since H3 step 1, and the
	// property `vt_svt_coverage` asserts - the two `*_ms` keys what they cost, and the two `last_*`
	// keys the most recent transition. A view that keeps moving the cap is a view whose far field
	// keeps re-baking itself, which is the trace section 7.3 chased.
	result["svt_cap_changes"] = int64_t(_vt.svt_cap_changes);
	result["svt_cap_dirty_regions"] = int64_t(_vt.svt_cap_dirty_regions);
	result["svt_cap_change_ms"] = _vt.svt_cap_change_ms;
	result["svt_cap_change_worst_ms"] = _vt.svt_cap_change_worst_ms;
	result["svt_cap_last_from"] = _vt.svt_cap_last_from;
	result["svt_cap_last_to"] = _vt.svt_cap_last_to;
	result["svt_root_cap_raises"] = int64_t(_vt.svt_root_cap_raises);
	result["svt_visible_pages"] = _vt.vt_svt_visible_pages;
	result["svt_stats"] = _vt.svt_stats;
	result["svt_worst_ms"] = _vt.svt_worst_ms;
	result["svt_worst_frames_ago"] = double(Engine::get_singleton()->get_process_frames() - _vt.svt_worst_frame);
	result["svt_cpu_ms"] = _vt.svt_cpu_ms;
}
