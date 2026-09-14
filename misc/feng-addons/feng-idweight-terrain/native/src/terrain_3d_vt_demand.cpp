// Camera-visible SVT demand. Legacy raw-ID diagnostics retain their original scan.
#include "terrain_3d.h"
#include "terrain_3d_material.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_3d_vt_visibility.h"
#include <map>
#include <tuple>
#include <functional>

// Select exactly the shader distance bands. Shared capacity limits residency,
// never changes the requested mip or substitutes an ancestor.
int Terrain3D::_update_visible_svt(int p_max_pages) {
	Camera3D *camera = get_camera();
	if (!camera || !camera->is_inside_tree()) { return 0; }
	TerrainVT::VisibleView view(camera, 48.f);
	struct Region { Rect2 rect; Vector2 heights; float distance; float farthest; TerrainVT::VisiblePatch visible; };
	struct Page { Vector2i address; int mip; float distance; };
	std::vector<Region> regions;
	// Union of the visible region rects. The far field's root pyramid has to cover what
	// this pass can render, not just the detail pages it manages to produce.
	Rect2 visible_bounds;
	bool has_visible_bounds = false;
	const Vector3 camera_position = camera->get_global_position();
	const Vector2 focus(camera_position.x, camera_position.z);
	auto avt_interior = [&](const Rect2 &rect) {
		Vector2 farthest(MAX(Math::abs(rect.position.x - focus.x), Math::abs(rect.get_end().x - focus.x)),
				MAX(Math::abs(rect.position.y - focus.y), Math::abs(rect.get_end().y - focus.y)));
		return _vt.surface_vt_enabled && is_sector_avt() && farthest.length() < MAX(64.f, float(_vt.surface_vt_distance)) * 0.75f;
	};
	const float region_world = _region_size * _vertex_spacing;
	const float page_world = MAX(0.001f, _vt.surface_svt_page_world);
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		// Legacy region AVT owns whole regions; sector AVT excludes only the
		// metric near interior during footprint traversal below.
		if (_vt.surface_vt_enabled && !is_sector_avt() && _vt.vt_registered_sectors.has(location)) { continue; }
		Rect2 rect(Vector2(location) * region_world, Vector2(region_world, region_world));
		TerrainVT::VisiblePatch visible;
		if (!view.sample(rect, region->get_height_range(), visible)) { continue; }
		regions.push_back({ rect, region->get_height_range(), visible.distance, visible.farthest, visible });
		visible_bounds = has_visible_bounds ? visible_bounds.merge(rect) : rect;
		has_visible_bounds = true;
	}
	std::sort(regions.begin(), regions.end(), [](const Region &a, const Region &b) { return a.distance < b.distance; });
	float farthest_distance = 0.f;
	for (const Region &region : regions) { farthest_distance = MAX(farthest_distance, region.farthest); }

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

	std::map<std::tuple<int, int, int>, Page> unique;
	// Traverse visible footprints, not every mip-0 cell of an entire region.
	// A high SVT texel density must not be silently capped to 16 pages/region.
	// Bound pathological traversal without replacing requested levels with ancestors.
	int walk_visited = 0;
	const int visit_limit = MAX(4096, _vt.surface_svt->get_page_count() * 128);
	const float half_world = _vt.surface_svt->get_indirection_size() * page_world * 0.5f;
	const Rect2 domain(Vector2(-half_world, -half_world), Vector2(half_world * 2.f, half_world * 2.f));
	for (const Region &region : regions) {
		if (!region.rect.intersects(domain)) { continue; }
		const Rect2 resident = region.rect.intersection(domain);
		std::function<void(int, int, int)> visit = [&](int x, int y, int mip) {
			const float span = page_world * float(1 << mip);
			const Rect2 footprint(Vector2(x, y) * span, Vector2(span, span));
			if (!footprint.intersects(resident)) { return; }
			const Rect2 clipped = footprint.intersection(resident);
			if (avt_interior(clipped)) { return; }
			TerrainVT::VisiblePatch visible;
			// Coarse ancestors commonly clip to the same complete region. Reuse
			// its exact query, including grazing-view density and distance bounds.
			if (clipped == region.rect) { visible = region.visible; }
			else if (!view.sample(clipped, region.heights, visible)) { return; }
			++walk_visited;
			const int near_mip = get_surface_svt_mip_for_distance(MAX(0.f, visible.distance - MAX(2.f, visible.distance * 0.03f)), plan_limit);
			const int far_mip = get_surface_svt_mip_for_distance(MAX(visible.distance, visible.farthest) * 1.03f + 2.f, plan_limit);
			if (mip < near_mip) { return; }
			if (mip <= far_mip) {
				const Vector2i address(x * (1 << mip), y * (1 << mip));
				const auto key = std::make_tuple(mip, address.x, address.y);
				auto found = unique.find(key);
				if (found == unique.end() || visible.distance < found->second.distance) { unique[key] = { address, mip, visible.distance }; }
			}
			if (mip > near_mip && walk_visited < visit_limit) {
				for (int dy = 0; dy < 2; ++dy) { for (int dx = 0; dx < 2; ++dx) { visit(x * 2 + dx, y * 2 + dy, mip - 1); } }
			}
		};
		const float root_span = page_world * float(1 << plan_limit);
		for (int y = int(Math::floor(resident.position.y / root_span)); y < int(Math::ceil(resident.get_end().y / root_span)); ++y) {
			for (int x = int(Math::floor(resident.position.x / root_span)); x < int(Math::ceil(resident.get_end().x / root_span)); ++x) { visit(x, y, plan_limit); }
		}
	}
	std::vector<Page> pages;
	pages.reserve(unique.size());
	for (const auto &entry : unique) { pages.push_back(entry.second); }
	std::sort(pages.begin(), pages.end(), [](const Page &a, const Page &b) {
		if (a.distance != b.distance) { return a.distance < b.distance; }
		return std::make_tuple(a.mip, a.address.y, a.address.x) < std::make_tuple(b.mip, b.address.y, b.address.x);
	});

	if (_ensure_vt_capacity(int(pages.size()) + (_vt.surface_vt_enabled ? int(_vt.avt_page_plan.size()) : 0))) { return 0; }

	// The physical pool is shared with the near field, so the far field only claims what
	// the near field is not holding.
	const int physical_page_count = MAX(1, _vt.surface_svt->get_page_count());
	_vt.vt_svt_visible_pages = int(pages.size());
	const int near_reserve = _vt.surface_vt_enabled ? MIN(physical_page_count / 2, int(_vt.avt_page_plan.size())) : 0;
	const int capacity = MAX(1, physical_page_count - near_reserve);

	// Publish the level this frame uses. A saved maximum detail level is only ever raised,
	// never lowered, so a view that already extended the hierarchy keeps it.
	int used_mip = configured_mip;
	for (const Page &page : pages) { used_mip = MAX(used_mip, page.mip); }
	if (!regions.empty() && _vt.surface_svt_mip_distances.is_empty()) {
		// With the automatic rule a saved cap must not hide terrain the view can see, so
		// the hierarchy extends to the level the farthest visible point selects. The
		// raise is a function of the visible set rather than of pool pressure, and it
		// only ever grows, so it cannot make a level move back and forth.
		used_mip = MAX(used_mip, get_surface_svt_mip_for_distance(farthest_distance, plan_limit));
	}
	const int maximum_mip = MIN(used_mip, plan_limit);
	if (maximum_mip != configured_mip) {
		_vt.surface_svt->set_world_max_mip(maximum_mip);
		for (const Vector2i &location : _data->get_region_locations()) { _vt.vt_svt_dirty_regions[location] = true; }
		_vt.vt_svt_edit_time = 0;
		if (_material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
	}

	// Far-field roots: the coarsest levels covering the visible world stay resident and
	// protected, so a miss on a detail page resolves to real coarse data instead of the
	// diagnostic material. They are acquired before the detail set because under pressure
	// the detail pass drops the far end of the working set, which is exactly where the
	// coarse levels live. Capped at half the pool, so the near field and the detail pages
	// keep room to work in.
	const int protected_limit = MAX(1, physical_page_count / 2);
	const int root_levels = CLAMP(_vt.surface_svt_root_mips, 0, maximum_mip + 1);
	std::vector<Vector3i> next_roots;
	if (root_levels > 0 && has_visible_bounds) {
		const Rect2 covered = visible_bounds.intersection(domain);
		for (int mip = maximum_mip; mip > maximum_mip - root_levels && int(next_roots.size()) < protected_limit; --mip) {
			const float span = page_world * float(1 << mip);
			const int x0 = int(Math::floor(covered.position.x / span));
			const int x1 = int(Math::floor(covered.get_end().x / span));
			const int y0 = int(Math::floor(covered.position.y / span));
			const int y1 = int(Math::floor(covered.get_end().y / span));
			for (int y = y0; y <= y1 && int(next_roots.size()) < protected_limit; ++y) {
				for (int x = x0; x <= x1 && int(next_roots.size()) < protected_limit; ++x) {
					// Page requests and releases take a mip 0 page coordinate.
					next_roots.push_back(Vector3i(x << mip, y << mip, mip));
				}
			}
		}
	}
	// A root that left the visible set loses its pin, so a world that scrolls away does not
	// keep half the pool reserved for the rest of the session.
	for (const Vector3i &previous : _vt.svt_root_pages) {
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
	_vt.svt_root_pages = next_roots;

	int produced = 0;
	for (const Vector3i &root : next_roots) {
		bool miss = false;
		const int slot = _vt.surface_svt->request_world_page_internal(root.x, root.y, root.z, &miss);
		if (slot < 0) { continue; }
		// A root that gets evicted leaves a miss with nothing coarser to show, which is
		// the whole reason the pyramid exists.
		_vt.surface_svt->protect_page(slot, true);
		if (!miss) { continue; }
		_invalidate_vt_slot(slot);
		Ref<Image> payload;
		const float span = _vt.surface_svt_page_world * float(1 << root.z);
		_queue_vt_material_page(slot, payload, Rect2(Vector2(root.x, root.y) * _vt.surface_svt_page_world, Vector2(span, span)),
				true, root.z, Vector2i(root.x, root.y));
		produced++;
	}

	// Over-subscription raises a shared coarseness floor instead of dropping the far end of
	// the working set: a page finer than the floor is published at the floor, while a page
	// already coarser than it keeps the level the distance rule gave it. Every visible
	// footprint therefore still resolves through a page of some real level, and the floor is
	// the smallest one that fits - a function of the visible set and the remaining capacity
	// alone - so a settled view selects the same floor, levels and pages on every pass.
	const int detail_capacity = MAX(1, capacity - int(next_roots.size()));
	std::vector<Page> chosen;
	_vt.svt_floor_level = 0;
	if (int(pages.size()) <= detail_capacity) {
		chosen = pages;
	} else {
		for (int candidate = 0; candidate <= maximum_mip && chosen.empty(); ++candidate) {
			std::map<std::tuple<int, int, int>, float> merged;
			for (const Page &page : pages) {
				const int level = MAX(page.mip, candidate);
				const auto key = std::make_tuple(level, page.address.x, page.address.y);
				const auto found = merged.find(key);
				if (found == merged.end() || page.distance < found->second) { merged[key] = page.distance; }
			}
			if (int(merged.size()) > detail_capacity) { continue; }
			_vt.svt_floor_level = candidate;
			chosen.reserve(merged.size());
			for (const auto &entry : merged) {
				Page page;
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
		std::sort(chosen.begin(), chosen.end(), [](const Page &a, const Page &b) {
			if (a.distance != b.distance) { return a.distance < b.distance; }
			return std::make_tuple(a.mip, a.address.y, a.address.x) < std::make_tuple(b.mip, b.address.y, b.address.x);
		});
	}

	int visited = 0;
	for (const Page &request : chosen) {
		if (visited >= detail_capacity) { break; }
		visited++;
		bool miss = false;
		const int slot = _vt.surface_svt->request_world_page_internal(request.address.x, request.address.y, request.mip, &miss);
		if (slot < 0) { continue; }
		if (!miss) { continue; }
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
	return produced;
}
