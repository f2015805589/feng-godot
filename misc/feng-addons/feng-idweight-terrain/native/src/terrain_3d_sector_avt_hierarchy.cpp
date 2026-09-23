// AVT addressing: independent dense baseline and sparse high-resolution local mip chains.
#include "terrain_3d_sector_avt_internal.h"
#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include <godot_cpp/classes/time.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>

using namespace TerrainAVT;
namespace {
uint32_t sector_hash(int x, int y, int level) {
	return uint32_t(x) * 73856093u ^ uint32_t(y) * 19349663u ^ uint32_t(level) * 83492791u;
}
int coarse_page_count(int size, int levels) {
	int count = 0;
	for (int mip = 1; mip < levels && size > 0; ++mip, size >>= 1) { count += size * size; }
	return count;
}
}

void Terrain3D::_publish_avt_directory(const Terrain3DAVTHierarchy &p_hierarchy) {
	const bool rebind = _avt_publish_directory(p_hierarchy, p_hierarchy.directory_dirty);
	_vt.avt_sector_stats["directory_rebuilt"] = p_hierarchy.directory_dirty;
	_vt.avt_sector_stats["visible_sectors"] = int(p_hierarchy.leaves.size());
	_vt.avt_sector_stats["coarse_pages"] = int(_vt.avt_coarse.pages.size());
	_vt.avt_sector_stats["coarse_world_size"] = _vt.avt_coarse.page_world;
	_vt.avt_sector_stats["material_ms"] = 0.0;
	if ((rebind || p_hierarchy.directory_dirty) && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

Terrain3DAVTSectorScan Terrain3D::_avt_scan_sectors(const TerrainVT::VisibleView &p_view,
		const Vector3 &p_camera_position, const bool p_bounds_ready,
		const Vector2 &p_focus, const float p_reach) const {
	Terrain3DAVTSectorScan scan;
	// Source bounds only reject empty fine cells; AVT itself is bounded by reach.
	Rect2 bounds;
	Vector2 world_heights;
	const float region_world = _region_size * _vertex_spacing;
	for (const Vector2i &location : _data->get_region_locations()) {
		const Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		const Rect2 rect(Vector2(location) * region_world, Vector2(region_world, region_world));
		const Vector2 heights = region->get_height_range();
		world_heights = scan.has_world ? Vector2(MIN(world_heights.x, heights.x), MAX(world_heights.y, heights.y)) : heights;
		bounds = scan.has_world ? bounds.merge(rect) : rect;
		scan.has_world = true;
	}
	if (!scan.has_world) { return scan; }
	const int pool = _vt.vt_page_count;
	// The near plan's share of the pool: everything except the far field's floor. This is a residency
	// budget, fixed rather than derived from last frame's visible count, because turning the camera
	// must not change the dense grid's world footprint or its resident addresses.
	//
	// It used to be exactly half the pool whenever the far field was enabled, which is not a share but
	// a ceiling: measured on the near-field probe, the near plan held 116 of its 128 entries while the
	// far field held 27 pages and 101 slots sat free, and the plan could afford a second level for only
	// 15 of the 36 cells it covers - every other cell kept its whole-cell page at 0.25 m per texel,
	// which is the per-cell blur. A quarter of the pool is more than the far field's own demand (its
	// root pyramid is 20 pages and its visible set tens), so the near field takes the rest. The
	// per-tick *production* split stays where it is: it is a separate decision with its own
	// measurements (`_avt_tick_allowance()`).
	const int far_floor = MAX(4, pool / 4);
	scan.budget = MAX(1, has_svt_delivery() ? pool - far_floor : pool);
	// A 2x2 ring is the minimum that can cover both sides of world zero.
	// Tiny pools reserve four pages; normal pools reserve at most one quarter.
	const int resident_budget = MIN(scan.budget, MAX(4, scan.budget / 4));
	auto &coarse = scan.coarse;
	coarse.size = 2;
	coarse.levels = 2;
	for (int side = 4; side <= 512; side <<= 1) {
		const int levels = TerrainVT::log2_power_of_two(side) + 1;
		if (coarse_page_count(side, levels) > resident_budget) { break; }
		coarse.size = side;
		coarse.levels = levels;
	}
	coarse.page_world = 2.f * _vt.vt_page_size / float(_vt.surface_vt_texels_per_meter);
	const int top = coarse.levels - 1;
	const int top_side = coarse.size >> (top - 1);
	// Every level has enough wrap-free interior for the entire near circle.
	// The extra row handles arbitrary (including negative) camera alignment.
	const float coverage_span = 2.f * p_reach / (float(1 << (top - 1)) * (top_side - 1));
	coarse.page_world = std::exp2(std::ceil(std::log2(MAX(coarse.page_world, coverage_span))));
	coarse.center = p_focus;
	coarse.origin = ((p_focus / coarse.page_world + Vector2(0.5f, 0.5f)).floor() - Vector2(coarse.size / 2, coarse.size / 2)) * coarse.page_world;
	for (int mip = coarse.levels - 1; mip >= 1; --mip) {
		const int side = coarse.size >> (mip - 1);
		const float span = coarse.page_world * float(1 << (mip - 1));
		const Vector2i first = Vector2i((p_focus / span + Vector2(0.5f, 0.5f)).floor()) - Vector2i(side / 2, side / 2);
		for (int y = 0; y < side; ++y) for (int x = 0; x < side; ++x) {
			const Vector2i world = first + Vector2i(x, y);
			coarse.pages.push_back({ avt_coarse_owner(), mip, world.x & (side - 1), world.y & (side - 1),
					Rect2(Vector2(world) * span, Vector2(span, span)),
					TerrainVT::make_page_request_priority(TerrainVT::PageRequestKind::ROOT, 0.f, span) });
		}
	}
	// The upgrade grid has its own virtual resolution. Coarse residency must
	// never change the world footprint of a fine texel.
	if (_vt.surface_vt_texels_per_meter <= _vt.vt_page_size / coarse.page_world || scan.budget <= int(coarse.pages.size())) { return scan; }
	const float maximum_pages = SECTOR_WORLD * _vt.surface_vt_texels_per_meter / _vt.vt_page_size;
	const float section_world = get_avt_local_section_world();
	const Vector2i first = Vector2i(((p_focus - Vector2(p_reach, p_reach)) / section_world).floor());
	const Vector2i last = Vector2i(((p_focus + Vector2(p_reach, p_reach)) / section_world).floor());
	for (int y = first.y; y <= last.y; ++y) for (int x = first.x; x <= last.x; ++x) {
		const Vector2i key(x, y);
		const Rect2 rect(Vector2(key) * section_world, Vector2(section_world, section_world));
		if (!rect.intersects(bounds)) { continue; }
		const Vector2 nearest(CLAMP(p_focus.x, rect.position.x, rect.get_end().x), CLAMP(p_focus.y, rect.position.y, rect.get_end().y));
		if (nearest.distance_squared_to(p_focus) > p_reach * p_reach) { continue; }
		const Vector2 heights = p_bounds_ready ? _vt.vt_source_snapshot->bounds(rect, world_heights) : world_heights;
		TerrainVT::VisiblePatch patch;
		const bool visible = p_view.sample(rect, heights, patch);
		const float distance = Vector3(nearest.x, CLAMP(p_camera_position.y, heights.x, heights.y), nearest.y).distance_to(p_camera_position);
		// Screen density naturally decreases with perspective distance. The
		// configured count limits sector image resolutions, not its mip chain.
		const float density = visible ? patch.density * _vt.surface_vt_texels_per_pixel * AVT_DEMAND_DENSITY_MARGIN :
				p_view.focal * _vt.surface_vt_texels_per_pixel / MAX(0.01f, distance);
		int tier = CLAMP(int(std::floor(std::log2(MAX(1.f, _vt.surface_vt_texels_per_meter / MAX(0.00001f, density))))), 0, _vt.surface_vt_mip_levels - 1);
		// The distance table is a *perspective* control. An orthographic camera's footprint does not
		// shrink with distance - `terrain_3d_vt_visibility.h` answers `density = focal` for it, flat
		// in depth - so letting the table replace the footprint's own tier discards detail the view
		// still asks for. Measured in `vt_region_ownership`: over unchanged ground the block fell
		// 16 -> 8 -> 4 as the camera rose 5 -> 15 -> 30 m, while the orthographic footprint was
		// identical at all three heights.
		if (!_vt.surface_vt_mip_distances.is_empty() && !p_view.orthographic) {
			tier = MIN(_vt.surface_vt_mip_levels - 1, get_surface_vt_mip_for_distance(distance));
		}
		const auto cached = _vt.avt_cached_addresses.find(avt_owner_key(key));
		// Turning away is not a request to discard fine addresses. Preserve the
		// previous resolution until distance demand or address pressure replaces it.
		if (!visible && cached != _vt.avt_cached_addresses.end()) { tier = MIN(tier, cached->second.resolution_level); }
		const float logical = maximum_pages * std::exp2(-float(tier));
		int size = 1;
		while (size < logical) { size <<= 1; }
		scan.visible.push_back({ key, key, 0, size, visible, distance, heights, tier, logical });
	}
	std::stable_sort(scan.visible.begin(), scan.visible.end(), [](const auto &a, const auto &b) { return a.distance < b.distance; });
	// Every cell the near field can reach is kept, on screen or not.
	//
	// This is the reference implementation's *additional feedback*: its feedback pass adds one
	// entry per resident virtual image every frame - each image's coarsest page - so no image the
	// camera has an address for can be dropped from demand while the camera is not looking at it,
	// and a turn finds the ground it turns onto already addressable rather than planned from
	// nothing. The readme's badcase is exactly that turn. The old rule kept only
	// `MIN(8, budget / 16)` cells behind the camera, so a 180-degree cut named ground the previous
	// plan had never held and had to build every page of it - roots included - from a source read.
	// A cell outside the frustum still never competes for refinement: `produce` is false for it, and
	// the walk's own comparators put a producing cell first inside every level. What it does keep is
	// its whole-cell root page, which is resident, reserved and demanded across the turn.
	std::stable_sort(scan.visible.begin(), scan.visible.end(), [](const auto &a, const auto &b) {
		if (a.produce != b.produce) { return a.produce; }
		return a.distance < b.distance;
	});

	return scan;
}

Terrain3DAVTHierarchy Terrain3D::_avt_build_hierarchy(const Terrain3DAVTSectorScan &p_scan) {
	Terrain3DAVTHierarchy hierarchy;
	hierarchy.budget = p_scan.budget;
	hierarchy.root_level = MAX(1, p_scan.coarse.levels - 1);
	hierarchy.leaves = p_scan.visible;
	hierarchy.working = p_scan.visible;
	for (const auto &cell : p_scan.visible) { hierarchy.owners.insert(avt_owner_key(cell.owner)); }
	auto &coarse = _vt.avt_coarse;
	const auto &next = p_scan.coarse;
	const bool changed = coarse.size != next.size || coarse.levels != next.levels ||
			coarse.page_world != next.page_world ||
			(next.size > 0 && !_vt.surface_vt->has_sector(avt_coarse_owner()));
	hierarchy.directory_dirty = changed || _vt.avt_directory_bytes.is_empty();
	if (changed) {
		// Source/layout changes invalidate the old world's requests as well as its
		// addresses. Ordinary camera motion never enters this branch.
		for (const auto &entry : _vt.avt_cached_addresses) { _vt.surface_vt->unregister_sector(entry.second.owner); }
		_vt.avt_cached_addresses.clear();
		_vt.avt_allocated_sizes.clear();
		_vt.vt_registered_sectors.clear();
		_vt.surface_vt->unregister_sector(avt_coarse_owner());
		_vt.avt_plan.forget();
		_vt.avt_settled.unverify();
		coarse = next;
		if (coarse.size > 0 && _vt.surface_vt->register_sector(avt_coarse_owner(), coarse.size * 2)) {
			coarse.block = Vector2i(_vt.surface_vt->get_sector_block_origin_x(avt_coarse_owner()),
					_vt.surface_vt->get_sector_block_origin_y(avt_coarse_owner()));
			_vt.avt_plan.install(std::vector<Terrain3DAVTPageRequest>(coarse.pages), int(coarse.pages.size()));
			_avt_publish_plan_coverage();
		} else { coarse.size = 0; coarse.levels = 0; }
	}
	if (!changed && coarse.size > 0) {
		bool scrolled = false;
		// Toroidal page-table coordinates preserve every overlapping world's page.
		// Only rows that leave the near window are invalidated and recycled.
		for (const auto &page : next.pages) {
			const auto old = std::find_if(coarse.pages.begin(), coarse.pages.end(), [&](const Terrain3DAVTPageRequest &entry) {
				return entry.mip == page.mip && entry.x == page.x && entry.y == page.y;
			});
			if (old != coarse.pages.end() && old->rect == page.rect) { continue; }
			_vt.surface_vt->release_page(page.owner, page.mip, page.x, page.y);
			scrolled = true;
		}
		coarse.origin = next.origin;
		coarse.pages = next.pages;
		if (scrolled) {
			coarse.center = next.center;
			hierarchy.directory_dirty = true;
			std::vector<Terrain3DAVTPageRequest> pages = coarse.pages;
			for (const auto &page : _vt.avt_plan.pages) { if (page.owner != avt_coarse_owner()) { pages.push_back(page); } }
			const int sampled = int(pages.size());
			_vt.avt_plan.install(std::move(pages), sampled);
			_avt_publish_plan_coverage();
			_vt.avt_settled.unverify();
		}
	}
	_vt.avt_sector_stats["pool_pages"] = _vt.surface_vt->get_page_count();
	_vt.avt_sector_stats["plan_budget"] = hierarchy.budget;
	_vt.avt_sector_stats["virtual_budget_bias"] = 0;
	return hierarchy;
}

void Terrain3D::_avt_sync_address_directory(Terrain3DAVTHierarchy &r_hierarchy, const Vector2 &p_focus, const float p_reach) {
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	auto coarse_ready = [&](const Terrain3DAVTCachedAddress &address) {
		const Vector2 origin = Vector2(address.location) * get_avt_local_section_world();
		const Vector2 end = origin + Vector2(get_avt_local_section_world(), get_avt_local_section_world());
		const Vector2 nearest(CLAMP(p_focus.x, origin.x, end.x), CLAMP(p_focus.y, origin.y, end.y));
		// Outside the current AVT circle the shader uses SVT, so old upgrades can
		// be discarded without mistaking a wrapped coarse slot for their world.
		if (nearest.distance_squared_to(p_focus) > p_reach * p_reach) { return true; }
		for (int mip = 1; mip < _vt.avt_coarse.levels; ++mip) {
			const int side = _vt.avt_coarse.size >> (mip - 1);
			const float span = _vt.avt_coarse.page_world * float(1 << (mip - 1));
			const Vector2i cell = Vector2i((origin / span).floor());
			const Vector2i first = Vector2i((_vt.avt_coarse.center / span + Vector2(0.5f, 0.5f)).floor()) - Vector2i(side / 2, side / 2);
			if (cell.x < first.x || cell.y < first.y || cell.x >= first.x + side || cell.y >= first.y + side) { continue; }
			const int slot = _vt.surface_vt->lookup_page_exact(avt_coarse_owner(), mip,
					cell.x & (side - 1), cell.y & (side - 1));
			if (slot >= 0 && (!producer || producer->is_page_ready(slot))) { return true; }
		}
		return false;
	};
	auto release = [&](uint64_t key) {
		const auto found = _vt.avt_cached_addresses.find(key);
		if (found == _vt.avt_cached_addresses.end()) { return; }
		const Vector2i owner = found->second.owner;
		_vt.avt_plan.pages.erase(std::remove_if(_vt.avt_plan.pages.begin(), _vt.avt_plan.pages.end(),
				[&](const auto &page) { return page.owner == owner; }), _vt.avt_plan.pages.end());
		_avt_publish_plan_coverage();
		_vt.surface_vt->unregister_sector(owner);
		_vt.vt_registered_sectors.erase(found->second.owner);
		_vt.avt_allocated_sizes.erase(key);
		_vt.avt_cached_addresses.erase(found);
		r_hierarchy.directory_dirty = true;
	};
	// Release upgrades only when the independent fallback is ready.
	for (auto item = _vt.avt_cached_addresses.begin(); item != _vt.avt_cached_addresses.end();) {
		const uint64_t key = item->first;
		const bool remove = !r_hierarchy.owners.count(key) && coarse_ready(item->second);
		++item;
		if (remove) { release(key); }
	}
	std::unordered_set<uint64_t> considered;
	for (const auto &cell : r_hierarchy.working) {
		const uint64_t key = avt_owner_key(cell.owner);
		considered.insert(key);
		int old_size = _vt.surface_vt->has_sector(cell.owner) ? _vt.surface_vt->get_sector_block_size(cell.owner) : 0;
		const auto old = _vt.avt_cached_addresses.find(key);
		if (old_size > 0 && old != _vt.avt_cached_addresses.end()) {
			if (old_size == cell.size && old->second.logical_pages == cell.logical_pages) { continue; }
			// Below one page per image, changing the tier changes its footprint
			// without changing the 1x1 block. It cannot use the mip-shift remap.
			if (!Math::is_equal_approx(old->second.logical_pages / old_size, cell.logical_pages / cell.size)) {
				if (!coarse_ready(old->second)) { continue; }
				release(key); old_size = 0;
			}
		}
		auto allocate = [&]() { return old_size > 0 ? _vt.surface_vt->resize_sector(cell.owner, cell.size) : _vt.surface_vt->register_sector(cell.owner, cell.size); };
		bool allocated = allocate();
		if (!allocated) {
			// Working cells are nearest first. An old, still-visible far block
			// must not occupy the last address space forever while new near cells
			// fail to register. Reclaim a farther block after its fallback is ready.
			for (auto far = r_hierarchy.working.rbegin(); far != r_hierarchy.working.rend(); ++far) {
				const uint64_t far_key = avt_owner_key(far->owner);
				if (considered.count(far_key)) { continue; }
				const auto cached = _vt.avt_cached_addresses.find(far_key);
				if (cached == _vt.avt_cached_addresses.end() || !coarse_ready(cached->second)) { continue; }
				release(far_key);
				allocated = allocate();
				if (allocated) { break; }
			}
		}
		if (!allocated) { continue; }
		if (old_size > 0) {
			// The same mip-shift the reference implementation's `RemapVirtualImage` applies: a page
			// stands for a fixed world footprint, so doubling the image moves the same payload from
			// local mip L to L + shift and halving it moves L to L - shift. A page whose new mip
			// falls outside the block is the one case the shift cannot express, and only those are
			// dropped.
			const int shift = TerrainVT::log2_power_of_two(cell.size) - TerrainVT::log2_power_of_two(old_size);
			for (auto &page : _vt.avt_plan.pages) { if (page.owner == cell.owner) { page.mip += shift; } }
			_vt.avt_plan.pages.erase(std::remove_if(_vt.avt_plan.pages.begin(), _vt.avt_plan.pages.end(),
					[&](const auto &page) { return page.owner == cell.owner && page.mip < 0; }), _vt.avt_plan.pages.end());
			_avt_publish_plan_coverage();
		}
		_vt.avt_cached_addresses[key] = { cell.location, cell.owner, 0, cell.resolution_level, cell.logical_pages };
		_vt.avt_allocated_sizes[key] = cell.size;
		_vt.vt_registered_sectors[cell.owner] = true;
		r_hierarchy.directory_dirty = true;
		++r_hierarchy.size_grows;
	}
	_vt.avt_registered_owners.clear();
	for (const auto &entry : _vt.avt_cached_addresses) { _vt.avt_registered_owners.push_back(entry.second.owner); }
	_vt.avt_sector_stats["retained_sector_addresses"] = int(_vt.avt_cached_addresses.size());
	_vt.avt_sector_stats["sector_size_grows"] = r_hierarchy.size_grows;
}

// Publishes the sector directory the shader reads. A sparse hash directory
// decouples GPU sector lookup from region layer IDs: two RGBA32F texels hold an
// exact world key/level and block origin/size. Returns whether it changed.
bool Terrain3D::_avt_publish_directory(const Terrain3DAVTHierarchy &p_hierarchy, const bool p_directory_dirty) {
	bool directory_changed = false;
	if (!p_directory_dirty && p_hierarchy.root_level == _vt.avt_root_level) { return false; }
	int entries = 1;
	while (entries < int(_vt.avt_cached_addresses.size()) * 2) { entries <<= 1; }
	int width = MIN(1024, entries * 2);
	int height = MAX(1, entries * 2 / width);
	PackedByteArray bytes;
	bytes.resize(int64_t(width) * height * 4 * sizeof(float));
	bytes.fill(0);
	uint8_t *output = bytes.ptrw();
	std::vector<bool> occupied(entries, false);
	int detailed = 0, max_size = 0;
	// The block size the shader reads is this ratio, derived from the live configuration rather
	// than carried by the plan: the chain that re-configures a view publishes its directory
	// before it submits the plan, so a value the plan carried would still be the previous
	// configuration's on the first publish - and a zero block size collapses every fragment
	// of the sector onto the block's first page.
	for (const auto &cached : _vt.avt_cached_addresses) {
		const Terrain3DAVTCachedAddress &sector = cached.second;
		if (!_vt.surface_vt->has_sector(sector.owner)) { continue; }
		uint32_t index = sector_hash(sector.location.x, sector.location.y, sector.level) & (entries - 1);
		while (occupied[index]) { index = (index + 1) & (entries - 1); }
		occupied[index] = true;
		int size = _vt.surface_vt->get_sector_block_size(sector.owner);
		float entry[8] = { float(sector.location.x), float(sector.location.y), float(sector.level), 1.f,
				float(_vt.surface_vt->get_sector_block_origin_x(sector.owner)), float(_vt.surface_vt->get_sector_block_origin_y(sector.owner)), float(size), sector.logical_pages };
		std::memcpy(output + int64_t(index) * sizeof(entry), entry, sizeof(entry));
		if (sector.level == 0 && p_hierarchy.owners.count(cached.first)) { ++detailed; max_size = MAX(max_size, size); }
	}
	directory_changed = bytes != _vt.avt_directory_bytes || p_hierarchy.root_level != _vt.avt_root_level;
	bool uniform_changed = false;
	if (directory_changed) {
		const bool recreated = !(_vt.avt_sector_directory.is_valid() &&
				_vt.avt_sector_directory->get_width() == width && _vt.avt_sector_directory->get_height() == height);
		Ref<Image> image = Image::create_from_data(width, height, false, Image::FORMAT_RGBAF, bytes);
		if (_vt.avt_sector_directory.is_valid() && _vt.avt_sector_directory->get_width() == width && _vt.avt_sector_directory->get_height() == height) { _vt.avt_sector_directory->update(image); }
		else { _vt.avt_sector_directory = ImageTexture::create_from_image(image); }
		// Only a uniform the shader reads needs a material republish: the texture update
		// in place is already visible to it, and the republish is not free.
		uniform_changed = recreated || (entries - 1) != _vt.avt_directory_mask || p_hierarchy.root_level != _vt.avt_root_level;
		_vt.avt_directory_bytes = bytes;
		_vt.avt_directory_mask = entries - 1;
		_vt.avt_root_level = p_hierarchy.root_level;
	}
	_vt.avt_sector_stats["independent_sectors"] = detailed;
	_vt.avt_sector_stats["max_allocated_resolution"] = max_size * _vt.vt_page_size;
	return uniform_changed;
}

// Read-only inspector data. It uses the same grid and demand rules as runtime,
// including when the editor's live-material preview pauses VT production.
//
// **A preview of a service nobody selected is refused, not drawn empty.** The scan below walks the
// visible grid and builds one dictionary per sector, so running it for a configuration whose
// material group is on `Direct` or `SVT` would be work whose only result is a picture of a service
// that was never built. The delivery matrix is asked first instead, and the two counters in
// `get_vt_settings()` (`avt_preview_calls` / `avt_preview_computed`) record which of the asks went
// on to scan, so "the preview costs nothing when AVT is unused" is a reading and not a claim.
Dictionary Terrain3D::get_avt_layout_preview(Camera3D *p_camera) const {
	Dictionary result;
	_vt.avt_preview_calls++;
	if (!has_avt_delivery()) { return result; }
	if (!_data || !p_camera) { return result; }
	_vt.avt_preview_computed++;
	TerrainVT::VisibleView view(p_camera);
	view.anisotropy = get_avt_anisotropy(p_camera);
	const Vector3 eye = p_camera->get_camera_transform().origin;
	const bool bounds_ready = _vt.vt_source_snapshot && _vt.vt_source_snapshot->bounds_ready.load(std::memory_order_acquire);
	const auto scan = _avt_scan_sectors(view, eye, bounds_ready, Vector2(eye.x, eye.z), MAX(64.f, float(_vt.surface_vt_distance)));
	const auto &coarse = scan.coarse;
	if (!scan.has_world || coarse.size == 0) { return result; }
	result["bounds"] = Rect2(coarse.origin, Vector2(1, 1) * coarse.page_world * coarse.size);
	result["camera"] = Vector2(eye.x, eye.z);
	const Vector3 forward = -p_camera->get_camera_transform().basis.get_column(2);
	result["camera_forward"] = Vector2(forward.x, forward.z);
	result["radius"] = MAX(64.f, float(_vt.surface_vt_distance));
	result["page_world"] = coarse.page_world;
	result["size"] = coarse.size;
	result["levels"] = _vt.surface_vt_mip_levels;
	result["coarse_levels"] = coarse.levels - 1;
	result["requested_levels"] = _vt.surface_vt_mip_levels;
	result["resident_pages"] = coarse_page_count(coarse.size, coarse.levels);
	result["effective_texels_per_meter"] = _vt.surface_vt_texels_per_meter;
	result["coarse_texels_per_meter"] = _vt.vt_page_size / coarse.page_world;
	result["fine_page_world"] = _vt.vt_page_size / float(_vt.surface_vt_texels_per_meter);
	result["fine_block_size"] = get_avt_local_block_size();
	result["fine_section_world"] = get_avt_local_section_world();
	result["fine_mip_levels"] = get_avt_mip_level_cap() + 1;
	Array resolution_levels;
	for (int level = 0; level < _vt.surface_vt_mip_levels; ++level) {
		const float density = _vt.surface_vt_texels_per_meter * std::exp2(-float(level));
		int block_size = 1;
		while (block_size < SECTOR_WORLD * density / _vt.vt_page_size) { block_size <<= 1; }
		Dictionary entry;
		entry["level"] = level; entry["resolution"] = SECTOR_WORLD * density;
		entry["texels_per_meter"] = density; entry["block_size"] = block_size;
		resolution_levels.push_back(entry);
	}
	result["resolution_levels"] = resolution_levels;
	Array sectors;
	for (const auto &cell : scan.visible) {
		Dictionary entry;
		entry["rect"] = Rect2(Vector2(cell.location) * SECTOR_WORLD, Vector2(SECTOR_WORLD, SECTOR_WORLD));
		entry["level"] = cell.resolution_level; entry["resolution"] = cell.logical_pages * _vt.vt_page_size;
		entry["block_size"] = cell.size; entry["logical_pages"] = cell.logical_pages; entry["visible"] = cell.produce;
		const bool allocated = _vt.surface_vt && _vt.surface_vt->has_sector(cell.owner);
		entry["allocated"] = allocated;
		if (allocated) {
			const int size = _vt.surface_vt->get_sector_block_size(cell.owner);
			entry["allocation_rect"] = Rect2(_vt.surface_vt->get_sector_block_origin_x(cell.owner), _vt.surface_vt->get_sector_block_origin_y(cell.owner), size, size);
		}
		sectors.push_back(entry);
	}
	result["sectors"] = sectors;
	Array fine;
	for (const auto &cell : scan.visible) {
		fine.push_back(Rect2(Vector2(cell.location) * get_avt_local_section_world(),
				Vector2(1, 1) * get_avt_local_section_world()));
	}
	result["fine_cells"] = fine;
	Array low_pages;
	for (const auto &page : coarse.pages) {
		Dictionary entry;
		entry["rect"] = page.rect;
		entry["mip"] = page.mip;
		low_pages.push_back(entry);
	}
	result["coarse_pages"] = low_pages;
	return result;
}
