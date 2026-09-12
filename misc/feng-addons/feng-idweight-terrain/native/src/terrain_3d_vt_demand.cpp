// Camera-visible SVT demand. Legacy raw-ID diagnostics retain their original scan.
#include "terrain_3d.h"
#include "terrain_3d_material.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_3d_vt_visibility.h"
#include <map>
#include <tuple>

// Far-field demand. Two rules share this pass and they do not interfere:
//
//  1. Detail. A page's level comes from one rule,
//     Terrain3D::get_surface_svt_mip_for_distance(), applied to the distance from the
//     camera the shader reports. A page is produced at exactly the level the shader
//     samples, so the level a point renders at is a pure function of its distance and
//     cannot follow page residency. The nearest pages keep their own level.
//
//  2. Coverage. A visible chunk must always resolve to something, so when the detail set
//     does not fit the pool the remainder is coarsened *together*, by whole levels, to the
//     finest level that fits the slots held back for it. Coarsening only moves a page to a
//     coarser level (the shader walks coarse-ward, so a coarser ancestor still serves its
//     texels), it is derived from the visible set rather than from pool pressure, and it
//     never rewrites the level of a page that did fit.
//
// The previous selection had neither property: it derived every level from a screen-space
// density ratio and then coarsened the whole set until it fit, so a page's level changed
// whenever the visible set or the pool pressure changed while the pages it had published
// at the old level stayed resident, and the sampled mip flapped between them.
int Terrain3D::_update_visible_svt(int p_max_pages) {
	Camera3D *camera = get_camera();
	if (!camera || !camera->is_inside_tree()) { return 0; }
	TerrainVT::VisibleView view(camera);
	struct Region { Rect2 rect; Vector2 heights; float distance; float farthest; };
	struct Page { Vector2i address; int mip; float distance; };
	std::vector<Region> regions;
	const float region_world = _region_size * _vertex_spacing;
	const float page_world = MAX(1.f, _surface_svt_page_world);
	// A region never walks more than 16x16 pages per level. A page far smaller than the
	// region caps how fine the far field can go there instead of turning one region into
	// thousands of requests per frame.
	int region_min_mip = 0;
	while (region_min_mip < 30 && region_world / (page_world * float(1 << region_min_mip)) > 16.f) {
		++region_min_mip;
	}
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		// AVT owns its selected regions. SVT should not spend the scarce detail
		// budget duplicating material pages that this view will never sample.
		if (_surface_vt_enabled && _vt_registered_sectors.has(location)) { continue; }
		Rect2 rect(Vector2(location) * region_world, Vector2(region_world, region_world));
		TerrainVT::VisiblePatch visible;
		if (!view.sample(rect, region->get_height_range(), visible)) { continue; }
		regions.push_back({ rect, region->get_height_range(), visible.distance, visible.farthest });
	}
	std::sort(regions.begin(), regions.end(), [](const Region &a, const Region &b) { return a.distance < b.distance; });
	float farthest_distance = 0.f;
	for (const Region &region : regions) { farthest_distance = MAX(farthest_distance, region.farthest); }

	// The centered indirection keeps the four world quadrants apart at its coarsest level,
	// and a page has to stay inside the table it is published in. That is the absolute
	// level limit for this frame; the effective limit is raised below to whatever the
	// detail and coverage sets actually use.
	const int configured_mip = _surface_svt->get_world_max_mip();
	const int coverage_limit = MAX(0, TerrainVT::log2_power_of_two(_surface_svt->get_indirection_size()) - 1);
	// Levels are planned against the absolute limit, not against the currently published
	// one, so a raise never has to be recomputed: the plan states the levels this frame
	// wants and the raise below publishes exactly those.
	const int plan_limit = coverage_limit;

	std::map<std::tuple<int, int, int>, Page> unique;
	if (!regions.empty()) {
		// Levels outside the span of the visible footprint cannot hold a needed page, so
		// the walk is bounded by the levels of the nearest and the farthest visible point.
		const int near_level = get_surface_svt_mip_for_distance(regions.front().distance, plan_limit);
		const int far_level = get_surface_svt_mip_for_distance(farthest_distance, plan_limit);
		for (int mip = near_level; mip <= far_level; ++mip) {
			if (mip < region_min_mip) { continue; }
			const float span = page_world * float(1 << mip);
			for (const Region &region : regions) {
				const Vector2 end = region.rect.get_end();
				const int x0 = int(Math::floor(region.rect.position.x / span));
				const int y0 = int(Math::floor(region.rect.position.y / span));
				const int x1 = int(Math::ceil(end.x / span));
				const int y1 = int(Math::ceil(end.y / span));
				for (int y = y0; y < y1; ++y) {
					for (int x = x0; x < x1; ++x) {
						const Rect2 footprint(Vector2(x * span, y * span), Vector2(span, span));
						TerrainVT::VisiblePatch visible;
						if (!view.sample(footprint.intersection(region.rect), region.heights, visible)) { continue; }
						// The visible part of a page spans levels [level(near),
						// level(farthest)]. A fragment anywhere inside it resolves to a
						// level in that span, so the page has to exist at every level in
						// it: publishing only the extreme would leave the shader's walk
						// without the level it was told to sample.
						if (mip < get_surface_svt_mip_for_distance(visible.distance, plan_limit) ||
								mip > get_surface_svt_mip_for_distance(MAX(visible.farthest, visible.distance), plan_limit)) {
							continue;
						}
						// Page coordinates are mip 0 pages of the world grid, aligned down
						// to this level; the producer and the shader both expect that.
						const Vector2i address(x * (1 << mip), y * (1 << mip));
						const auto key = std::make_tuple(mip, address.x, address.y);
						auto found = unique.find(key);
						if (found == unique.end() || visible.distance < found->second.distance) {
							unique[key] = { address, mip, visible.distance };
						}
					}
				}
			}
		}
	}
	std::vector<Page> pages;
	pages.reserve(unique.size());
	for (const auto &entry : unique) { pages.push_back(entry.second); }
	std::sort(pages.begin(), pages.end(), [](const Page &a, const Page &b) {
		if (a.distance != b.distance) { return a.distance < b.distance; }
		return std::make_tuple(a.mip, a.address.y, a.address.x) < std::make_tuple(b.mip, b.address.y, b.address.x);
	});

	// The physical pool is shared with the near field, so the far field only claims what
	// the near field is not holding.
	const int physical_page_count = MAX(1, _surface_svt->get_page_count());
	const int capacity = MAX(1, physical_page_count - (_surface_vt_enabled ? physical_page_count / 2 : 0));
	// Over-subscription policy: raise a *floor* on coarseness until the visible set fits
	// the pool, and keep every page that is already coarser than that floor exactly where
	// the distance rule put it. Only the pages finer than the floor coarsen, so the far
	// field never becomes coarser than the rule asks for, every visible chunk still
	// resolves, and the floor is a function of the visible set and the pool size alone:
	// the search always starts at the finest level and walks up, so a settled view selects
	// the same floor, the same levels and the same pages on every frame.
	int floor_mip = 0;
	std::map<std::tuple<int, int, int>, Page> selected;
	for (;;) {
		selected.clear();
		for (const Page &page : pages) {
			const int mip = MAX(page.mip, floor_mip);
			const int shift = mip - page.mip;
			const Vector2i address((page.address.x >> shift) << shift, (page.address.y >> shift) << shift);
			const auto key = std::make_tuple(mip, address.x, address.y);
			auto found = selected.find(key);
			if (found == selected.end() || page.distance < found->second.distance) {
				selected[key] = { address, mip, page.distance };
			}
		}
		if (int(selected.size()) <= capacity || floor_mip >= plan_limit) { break; }
		floor_mip++;
	}
	std::vector<Page> chosen;
	chosen.reserve(selected.size());
	for (const auto &entry : selected) { chosen.push_back(entry.second); }
	std::sort(chosen.begin(), chosen.end(), [](const Page &a, const Page &b) {
		if (a.distance != b.distance) { return a.distance < b.distance; }
		return std::make_tuple(a.mip, a.address.y, a.address.x) < std::make_tuple(b.mip, b.address.y, b.address.x);
	});
	if (floor_mip > 0) {
		WARN_PRINT_ONCE(vformat("Terrain3D: the far field needs %d pages for its current level bands but only %d of the pool are available to it; levels finer than %d are coarsened to level %d so every visible chunk still resolves. Raise the surface page count to keep the distance bands.",
				int(pages.size()), capacity, floor_mip, floor_mip));
	}
	if (int(chosen.size()) > capacity) {
		WARN_PRINT_ONCE(vformat("Terrain3D: the far field cannot cover its visible footprint: %d pages are needed even at level %d but only %d are available to it. Raise the surface page count, coarsen surface_svt_page_world, or set surface_svt_mip_distances so distant terrain uses coarser levels.",
				int(chosen.size()), plan_limit, capacity));
	}

	// Publish the level this frame uses. A saved maximum detail level is only ever raised,
	// never lowered, so a view that already extended the hierarchy keeps it.
	int used_mip = configured_mip;
	for (const Page &page : chosen) { used_mip = MAX(used_mip, page.mip); }
	if (!regions.empty() && _surface_svt_mip_distances.is_empty()) {
		// With the automatic rule a saved cap must not hide terrain the view can see, so
		// the hierarchy extends to the level the farthest visible point selects. The
		// raise is a function of the visible set rather than of pool pressure, and it
		// only ever grows, so it cannot make a level move back and forth.
		used_mip = MAX(used_mip, get_surface_svt_mip_for_distance(farthest_distance, plan_limit));
	}
	const int maximum_mip = MIN(used_mip, plan_limit);
	if (maximum_mip != configured_mip) {
		_surface_svt->set_world_max_mip(maximum_mip);
		for (const Vector2i &location : _data->get_region_locations()) { _vt_svt_dirty_regions[location] = true; }
		_vt_svt_edit_time = 0;
		if (_material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
	}

	int produced = 0;
	int visited = 0;
	for (const Page &request : chosen) {
		if (visited >= capacity) { break; }
		visited++;
		bool miss = false;
		const int slot = _surface_svt->request_world_page_internal(request.address.x, request.address.y, request.mip, &miss);
		if (slot < 0) { continue; }
		if (!miss) { continue; }
		_invalidate_vt_slot(slot);
		Ref<Image> payload;
		if (_data->produce_sparse_surface_page(request.address.x, request.address.y, request.mip, _surface_svt_page_world,
					_vt_page_size, _vt_page_border, payload) < 0 || !_surface_svt->write_page(slot, payload)) {
			_surface_svt->release_world_page(request.address.x, request.address.y, request.mip);
			continue;
		}
		const float span = _surface_svt_page_world * float(1 << request.mip);
		_queue_vt_material_page(slot, payload, Rect2(Vector2(request.address) * _surface_svt_page_world, Vector2(span, span)),
				true, request.mip, request.address);
		produced++;
		// The allocator enforces the production budget. Keep visiting the rest of the
		// working set so resident pages remain protected this frame.
	}
	_surface_svt->commit();
	if (_surface_vt && _surface_vt->is_initialized()) { _surface_vt->commit(); }
	_surface_svt->set_allocation_budget(-1);
	return produced;
}
