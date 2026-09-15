// Camera-visible SVT demand. Legacy raw-ID diagnostics retain their original scan.
#include "terrain_3d.h"
#include "terrain_3d_material.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_3d_vt_visibility.h"
#include <godot_cpp/classes/engine.hpp>
#include <map>
#include <tuple>
#include <functional>

// How long a published far-field page may stay without content before demand produces it
// again. Long enough that a bake, a cell copy and an asynchronous page read all complete
// first, short enough that a production that was dropped, refused, or that failed leaves
// the far field missing for a fraction of a second.
static const uint64_t SVT_PAGE_RETRY_FRAMES = 30;

// A page is only a hit when its content is actually there. The virtual texture's
// indirection entry survives an invalidation - `_invalidate_vt_slot()` clears the material
// slot, not the table - so a page whose production was dropped, refused for lack of a
// source, or lost to a failed cell copy stays named by the table while the shader samples
// an empty layer. `request_world_page_internal()` then reports it as a hit, so nothing ever
// retried it: that is the far field that loads on one run and not on the next. Demand asks
// the producer, and only a page with content or with a recent production in flight is a hit.
bool Terrain3D::_vt_page_production_stale(int p_slot) {
	if (p_slot < 0) {
		return true;
	}
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	if (producer && producer->is_page_ready(p_slot)) {
		return false;
	}
	if (_vt.vt_page_records.has(p_slot)) {
		const Dictionary record = _vt.vt_page_records[p_slot];
		const uint64_t queued = uint64_t(int64_t(record.get("queued_frame", 0)));
		const uint64_t now = Engine::get_singleton()->get_process_frames();
		return now > queued + SVT_PAGE_RETRY_FRAMES;
	}
	return true;
}

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

	// Far-field roots: the coarsest levels covering the whole SVT domain stay resident and
	// protected, so any world position a fragment can address resolves to real coarse data
	// instead of the diagnostic material. The candidate set is the domain and not the visible
	// part of it, because the fallback has to answer wherever the shader walks - a root pinned
	// only while visible is unpinned exactly when the camera turns away. At the level the view
	// selects that set is thousands of pages, and the protection budget used to truncate it in
	// row-major order, which left every pinned root in one corner of the map. Coverage is the
	// requirement, so the window slides coarser until the whole domain fits the budget: the
	// level is what gives way, never the coverage. The coarsest level the window reaches is
	// published as the world mip cap, which is what lets the shader's walk reach it.
	const int protected_limit = MAX(1, physical_page_count / 2);
	const int root_levels = CLAMP(_vt.surface_svt_root_mips, 0, maximum_mip + 1);
	const int indirection_size = _vt.surface_svt->get_indirection_size();
	auto level_cells = [indirection_size](int p_mip) {
		const int64_t size = MAX(1, indirection_size >> p_mip);
		return size * size;
	};
	int root_top = maximum_mip;
	if (root_levels > 0) {
		auto window_cells = [&](int p_top) {
			int64_t total = 0;
			for (int mip = p_top; mip > p_top - root_levels && mip >= 0; --mip) {
				total += level_cells(mip);
			}
			return total;
		};
		while (window_cells(root_top) > int64_t(protected_limit) && root_top < coverage_limit) {
			++root_top;
		}
		if (root_top > maximum_mip) {
			// Levels coarser than the one the distance rule selects are only ever reached by
			// the fallback walk, so publishing a coarser cap does not change which level a
			// visible fragment samples.
			_vt.surface_svt->set_world_max_mip(root_top);
			if (_material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
		}
	}
	const int root_first = MAX(0, root_top - root_levels + 1);
	// The pyramid is baked static content, and its pages are pinned, so a pass over the same
	// identity would re-derive exactly the same set and re-request pages that are already
	// resident and protected. Hash everything the set is a function of - the domain it
	// covers, the level window, the pool the pins live in, that pool's generation (a rebuilt
	// pool drops every pin) and the surface revision (an edit re-produces roots) - and reuse
	// the plan while the hash matches and the last walk pinned every root it planned. That is
	// what keeps a baked far field at zero main-thread cost while the view is still.
	uint64_t root_key = 1469598103934665603ull;
	auto root_mix = [&root_key](uint64_t p_value) {
		root_key ^= p_value;
		root_key *= 1099511628211ull;
	};
	root_mix(uint64_t(int64_t(domain.position.x * 1000.0)));
	root_mix(uint64_t(int64_t(domain.position.y * 1000.0)));
	root_mix(uint64_t(int64_t(domain.get_end().x * 1000.0)));
	root_mix(uint64_t(int64_t(domain.get_end().y * 1000.0)));
	root_mix(uint64_t(uint32_t(maximum_mip)));
	root_mix(uint64_t(uint32_t(root_top)));
	root_mix(uint64_t(uint32_t(root_levels)));
	root_mix(uint64_t(uint32_t(protected_limit)));
	root_mix(uint64_t(uint32_t(physical_page_count)));
	root_mix(uint64_t(uint32_t(_vt.vt_pool_generation)));
	root_mix(uint64_t(_vt.vt_source_revision));

	int produced = 0;
	// A cached plan is only reusable while every root it pinned is still published and still
	// has content: a caller can clear() the view directly, which empties the indirection
	// without touching the pool generation, and a production that never landed leaves the
	// entry published over an empty layer. Verifying that costs one read-only lookup per
	// root, which is less than the allocator bookkeeping the walk below would spend on the
	// same roots.
	bool roots_cached = _vt.svt_roots_settled && _vt.svt_root_key == root_key;
	if (roots_cached) {
		for (const Vector3i &root : _vt.svt_root_pages) {
			int virtual_x = 0;
			int virtual_y = 0;
			_vt.surface_svt->world_page_to_virtual(root.x, root.y, root.z, virtual_x, virtual_y);
			const int slot = _vt.surface_svt->get_indirection_slot(virtual_x, virtual_y, root.z);
			if (slot == int(Terrain3DVirtualTexture::INVALID_SLOT) || _vt_page_production_stale(slot)) {
				roots_cached = false;
				break;
			}
		}
	}
	if (roots_cached) {
		_vt.svt_root_skips++;
	} else {
		_vt.svt_root_passes++;
		std::vector<Vector3i> next_roots;
		if (root_levels > 0) {
			// Every texel of every level in the window, which is what makes the fallback
			// answer any world position rather than the ones that happen to be resident. The
			// walk is in level coordinates so it cannot address a texel the level does not
			// have, which a domain rect in world units does at its upper edge.
			const int half_pages = indirection_size >> 1;
			for (int mip = root_top; mip >= root_first && int(next_roots.size()) < protected_limit; --mip) {
				const int level_size = MAX(1, indirection_size >> mip);
				const int first_index = -(half_pages >> mip);
				for (int iy = 0; iy < level_size && int(next_roots.size()) < protected_limit; ++iy) {
					for (int ix = 0; ix < level_size && int(next_roots.size()) < protected_limit; ++ix) {
						// Page requests and releases take a mip 0 page coordinate.
						next_roots.push_back(Vector3i((first_index + ix) << mip, (first_index + iy) << mip, mip));
					}
				}
			}
		}
		// A root outside the domain loses its pin, so a re-configured extent does not keep half
		// the pool reserved for the rest of the session. Leaving the visible bounds is no longer
		// a reason to unpin: that is what left the coarser level missing when it was needed.
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

		// A root the allocator could not hand out this pass has to be retried, so the plan
		// is only reusable once every root was pinned.
		bool settled = true;
		for (const Vector3i &root : next_roots) {
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
			if (!miss && !_vt_page_production_stale(slot)) { continue; }
			_vt.svt_requeues++;
			_invalidate_vt_slot(slot);
			Ref<Image> payload;
			const float span = _vt.surface_svt_page_world * float(1 << root.z);
			_queue_vt_material_page(slot, payload, Rect2(Vector2(root.x, root.y) * _vt.surface_svt_page_world, Vector2(span, span)),
					true, root.z, Vector2i(root.x, root.y));
			produced++;
		}
		// What the pinned set covers, which is what the fallback can answer with.
		_vt.svt_root_coverage = Rect2();
		_vt.svt_root_level_min = -1;
		_vt.svt_root_level_max = -1;
		for (const Vector3i &root : next_roots) {
			const float span = _vt.surface_svt_page_world * float(1 << root.z);
			const Rect2 footprint(Vector2(root.x, root.y) * _vt.surface_svt_page_world, Vector2(span, span));
			_vt.svt_root_coverage = _vt.svt_root_coverage.size.x <= 0.f ? footprint : _vt.svt_root_coverage.merge(footprint);
			_vt.svt_root_level_min = _vt.svt_root_level_min < 0 ? root.z : MIN(_vt.svt_root_level_min, root.z);
			_vt.svt_root_level_max = MAX(_vt.svt_root_level_max, root.z);
		}
		_vt.svt_root_key = root_key;
		_vt.svt_roots_settled = settled;
	}

	// Over-subscription raises a shared coarseness floor instead of dropping the far end of
	// the working set: a page finer than the floor is published at the floor, while a page
	// already coarser than it keeps the level the distance rule gave it. Every visible
	// footprint therefore still resolves through a page of some real level, and the floor is
	// the smallest one that fits - a function of the visible set and the remaining capacity
	// alone - so a settled view selects the same floor, levels and pages on every pass.
	const int detail_capacity = MAX(1, capacity - int(_vt.svt_root_pages.size()));
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
		// The table says this address is published; the producer says whether anything is
		// there. A detail page that never landed is produced again here instead of being
		// sampled as an empty layer for the rest of the session.
		if (!miss && !_vt_page_production_stale(slot)) { continue; }
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
	return produced;
}
