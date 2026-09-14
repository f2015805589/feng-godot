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
	// Preserve the shader's selected level. Coarsening only the CPU request
	// produces a permanently missing page when strict residency is enabled.
	const std::vector<Page> &chosen = pages;

	// Publish the level this frame uses. A saved maximum detail level is only ever raised,
	// never lowered, so a view that already extended the hierarchy keeps it.
	int used_mip = configured_mip;
	for (const Page &page : chosen) { used_mip = MAX(used_mip, page.mip); }
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

	int produced = 0;
	int visited = 0;
	for (const Page &request : chosen) {
		if (visited >= capacity) { break; }
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
