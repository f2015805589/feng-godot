// Camera-visible SVT demand. Legacy raw-ID diagnostics retain their original scan.
#include "terrain_3d.h"
#include "terrain_3d_material.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_3d_vt_visibility.h"
#include <map>
#include <tuple>
#include <functional>

// Select distance-based detail over visible terrain. If it exceeds the shared
// pool allowance, raise a common minimum mip until the canonical page set fits.
// Pages already coarser than that floor keep their distance-selected level.
// The shader can resolve missing detail through these coarser ancestors.
int Terrain3D::_update_visible_svt(int p_max_pages) {
	Camera3D *camera = get_camera();
	if (!camera || !camera->is_inside_tree()) { return 0; }
	TerrainVT::VisibleView view(camera);
	struct Region { Rect2 rect; Vector2 heights; float distance; float farthest; };
	struct Page { Vector2i address; int mip; float distance; };
	std::vector<Region> regions;
	const Vector3 camera_position = camera->get_global_position();
	const Vector2 focus(camera_position.x, camera_position.z);
	auto avt_interior = [&](const Rect2 &rect) {
		Vector2 farthest(MAX(Math::abs(rect.position.x - focus.x), Math::abs(rect.get_end().x - focus.x)),
				MAX(Math::abs(rect.position.y - focus.y), Math::abs(rect.get_end().y - focus.y)));
		return _surface_vt_enabled && is_sector_avt() && farthest.length() < MAX(64.f, float(_surface_vt_distance)) * 0.75f;
	};
	const float region_world = _region_size * _vertex_spacing;
	const float page_world = MAX(0.001f, _surface_svt_page_world);
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		// Legacy region AVT owns whole regions; sector AVT excludes only the
		// metric near interior during footprint traversal below.
		if (_surface_vt_enabled && !is_sector_avt() && _vt_registered_sectors.has(location)) { continue; }
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
	// Traverse visible footprints, not every mip-0 cell of an entire region.
	// A high SVT texel density must not be silently capped to 16 pages/region.
	// Bound pathological over-demand and retain a coarse ancestor when the CPU
	// walk budget is exhausted; normal sparse close-ups can reach mip 0.
	int walk_visited = 0;
	const int visit_limit = MAX(4096, _surface_svt->get_page_count() * 128);
	const float half_world = _surface_svt->get_indirection_size() * page_world * 0.5f;
	const Rect2 domain(Vector2(-half_world, -half_world), Vector2(half_world * 2.f, half_world * 2.f));
	for (const Region &region : regions) {
		if (!region.rect.intersects(domain)) { continue; }
		const Rect2 resident = region.rect.intersection(domain);
		std::function<void(int, int, int)> visit = [&](int x, int y, int mip) {
			const float span = page_world * float(1 << mip);
			const Rect2 footprint(Vector2(x, y) * span, Vector2(span, span));
			if (!footprint.intersects(resident) || avt_interior(footprint.intersection(resident))) { return; }
			TerrainVT::VisiblePatch visible;
			if (!view.sample(footprint.intersection(resident), region.heights, visible)) { return; }
			++walk_visited;
			const int near_mip = get_surface_svt_mip_for_distance(visible.distance, plan_limit);
			const int far_mip = get_surface_svt_mip_for_distance(MAX(visible.distance, visible.farthest), plan_limit);
			if (mip < near_mip) { return; }
			if (mip <= far_mip || walk_visited >= visit_limit) {
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

	// The physical pool is shared with the near field, so the far field only claims what
	// the near field is not holding.
	const int physical_page_count = MAX(1, _surface_svt->get_page_count());
	const int capacity = MAX(1, physical_page_count - (_surface_vt_enabled ? physical_page_count / 2 : 0));
	// Over-subscription policy: raise a *floor* on coarseness until the visible set fits
	// the pool, and keep every page that is already coarser than that floor exactly where
	// the distance rule put it. Only the pages finer than the floor coarsen, so the far
	// field above that floor stays unchanged, every visible chunk still
	// resolves, and the floor is a function of the visible set and the pool size alone:
	// the search always starts at the finest level and walks up, so a settled view selects
	// the same floor, the same levels and the same pages on every frame.
	int floor_mip = 0;
	std::map<std::tuple<int, int, int>, Page> selected;
	for (;;) {
		selected.clear();
		for (const Page &page : pages) {
			const int mip = MAX(page.mip, floor_mip);
			const Vector2i address(TerrainVT::world_page_origin(page.address.x, mip),
					TerrainVT::world_page_origin(page.address.y, mip));
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
