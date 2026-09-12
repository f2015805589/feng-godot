// Camera-visible SVT demand. Legacy raw-ID diagnostics retain their original scan.
#include "terrain_3d.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_3d_vt_visibility.h"
#include <map>
#include <tuple>

int Terrain3D::_update_visible_svt(int p_max_pages) {
	Camera3D *camera = get_camera();
	if (!camera || !camera->is_inside_tree()) { return 0; }
	TerrainVT::VisibleView view(camera);
	struct Region { Rect2 rect; Vector2 heights; float distance; float density; };
	struct Page { Vector2i address; int mip; float distance; };
	std::vector<Region> regions;
	const float region_world = _region_size * _vertex_spacing;
	float best_density = 0.f;
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		// AVT owns its selected regions. SVT should not spend the scarce detail
		// budget duplicating material pages that this view will never sample.
		if (_surface_vt_enabled && _vt_registered_sectors.has(location)) { continue; }
		Rect2 rect(Vector2(location) * region_world, Vector2(region_world, region_world));
		TerrainVT::VisiblePatch visible;
		if (!view.sample(rect, region->get_height_range(), visible)) { continue; }
		regions.push_back({ rect, region->get_height_range(), visible.distance, visible.density });
		best_density = MAX(best_density, visible.density);
	}
	std::sort(regions.begin(), regions.end(), [](const Region &a, const Region &b) { return a.distance < b.distance; });
	const int maximum_mip = _surface_svt->get_world_max_mip();
	const int capacity = MAX(1, _surface_svt->get_page_count() - (_surface_vt_enabled ? _surface_svt->get_page_count() / 2 : 0));
	std::vector<Page> pages;
	// Start at the finest visible footprint. Coarsen the selected set only when
	// its physical working set does not fit; never fill the cache by row order.
	for (int bias = 0; bias <= maximum_mip; ++bias) {
		std::map<std::tuple<int, int, int>, Page> unique;
		for (const Region &region : regions) {
			const float ratio = MAX(1.f, best_density / MAX(0.000001f, region.density));
			int mip =
					CLAMP(int(Math::floor(Math::log(ratio) / Math::log(2.f))) + bias, 0, maximum_mip);
			// Bound candidate work for unusually small world pages.
			while (mip < maximum_mip && region.rect.size.x / (_surface_svt_page_world * float(1 << mip)) > 16.f) { ++mip; }
			const float span = _surface_svt_page_world * float(1 << mip);
			const Vector2 end = region.rect.get_end();
			const int x0 = int(Math::floor(region.rect.position.x / span));
			const int y0 = int(Math::floor(region.rect.position.y / span));
			const int x1 = int(Math::ceil(end.x / span));
			const int y1 = int(Math::ceil(end.y / span));
			int scanned = 0;
			for (int y = y0; y < y1 && scanned < 1024; ++y) {
				for (int x = x0; x < x1 && scanned++ < 1024; ++x) {
					Rect2 footprint(Vector2(x * span, y * span), Vector2(span, span));
					TerrainVT::VisiblePatch visible;
					if (!view.sample(footprint.intersection(region.rect), region.heights, visible)) { continue; }
					const float page_ratio = MAX(1.f, best_density / MAX(0.000001f, visible.density));
					const int page_mip = MAX(mip,
							CLAMP(int(Math::floor(Math::log(page_ratio) / Math::log(2.f))) + bias, 0, maximum_mip));
					const int scale = 1 << (page_mip - mip);
					const Vector2i address(int(Math::floor(float(x) / scale)) * (1 << page_mip),
							int(Math::floor(float(y) / scale)) * (1 << page_mip));
					const auto key = std::make_tuple(page_mip, address.x, address.y);
					auto found = unique.find(key);
					if (found == unique.end() || visible.distance < found->second.distance) {
						unique[key] = { address, page_mip, visible.distance };
					}
				}
			}
		}
		pages.clear();
		for (const auto &entry : unique) { pages.push_back(entry.second); }
		if (int(pages.size()) <= capacity) { break; }
	}
	std::sort(pages.begin(), pages.end(), [](const Page &a, const Page &b) {
		if (a.distance != b.distance) { return a.distance < b.distance; }
		return std::make_tuple(a.mip, a.address.y, a.address.x) < std::make_tuple(b.mip, b.address.y, b.address.x);
	});
	int produced = 0;
	int visited = 0;
	for (const Page &request : pages) {
		if (visited++ >= capacity) { break; }
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
		++produced;
		if (p_max_pages > 0 && produced >= p_max_pages) { break; }
	}
	_surface_svt->commit();
	if (_surface_vt && _surface_vt->is_initialized()) { _surface_vt->commit(); }
	return produced;
}
