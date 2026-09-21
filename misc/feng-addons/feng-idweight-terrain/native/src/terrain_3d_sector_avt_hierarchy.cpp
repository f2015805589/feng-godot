// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3D's near field, part 3 of 5: the sector scan, the hierarchy and the address directory.

// One of five files that own the near field. `_avt_scan_sectors()` walks the visible
// view and produces the working set, `_avt_build_hierarchy()` folds it into a coarse hierarchy
// with its owners, `_avt_sync_address_directory()` registers, resizes and releases the blocks the
// directory points at, and `_publish_avt_directory()` / `_avt_publish_directory()` write the
// directory texture the shader reads. Nothing here talks to a worker: this is the main thread's
// model of the near field, and the selection that runs beside it is
// `terrain_3d_avt_plan.cpp`.
//
// The other four: `terrain_3d_sector_avt.cpp` (the entry point and its configuration),
// `terrain_3d_sector_avt_motion.cpp` (the lead and the plan key), `terrain_3d_avt_plan.cpp` (the
// plan worker this file's model is handed to) and `terrain_3d_avt_produce.cpp` (the production
// pass that spends the tick's budget on the installed plan).

#include "terrain_3d_sector_avt_internal.h"

#include "terrain_3d.h"

#include <godot_cpp/classes/time.hpp>

#include <algorithm>
#include <cmath>
#include <map>

using namespace TerrainAVT;

namespace {
// Demand leads footprint changes so asynchronous production completes before
// a normal mip transition. This does not alter the shader's mip selection.
constexpr float DEMAND_DENSITY_MARGIN = AVT_DEMAND_DENSITY_MARGIN;
using SectorKey = std::pair<int, int>;
uint32_t sector_hash(int x, int y, int level) {
	return uint32_t(x) * 73856093u ^ uint32_t(y) * 19349663u ^ uint32_t(level) * 83492791u;
}
int floor_div(int value, int scale) { return int(std::floor(double(value) / scale)); }
}

// Publishes the address directory of a finished hierarchy. The material is republished
// only when a uniform it reads changed: the directory texture is updated in place, so its
// new content is already visible to the shader, and republishing every uniform costs more
// than the whole tick budget.
void Terrain3D::_publish_avt_directory(const Terrain3DAVTHierarchy &p_hierarchy) {
	_vt.avt_sector_stats["directory_rebuilt"] = p_hierarchy.directory_dirty || p_hierarchy.root_level != _vt.avt_root_level;
	const bool rebind = _avt_publish_directory(p_hierarchy, p_hierarchy.directory_dirty);
	_vt.avt_sector_stats["visible_sectors"] = int(std::count_if(p_hierarchy.leaves.begin(), p_hierarchy.leaves.end(), [](const Sector &sector) { return sector.produce; }));
	_vt.avt_sector_stats["coarse_pages"] = p_hierarchy.coarse_roots;
	_vt.avt_sector_stats["coarse_world_size"] = SECTOR_WORLD * float(1 << p_hierarchy.root_level);
	_vt.avt_sector_stats["material_ms"] = 0.0;
	if (rebind && _material.is_valid()) {
		const uint64_t material_start = Time::get_singleton()->get_ticks_usec();
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
		_vt.avt_sector_stats["material_ms"] = double(Time::get_singleton()->get_ticks_usec() - material_start) / 1000.0;
	}
}

// Enumerates the resident regions into 64 m demand cells, each sized to the mip
// its on-screen footprint needs.
Terrain3DAVTSectorScan Terrain3D::_avt_scan_sectors(const TerrainVT::VisibleView &p_view,
		const Vector3 &p_camera_position, const bool p_bounds_ready,
		const Vector2 &p_focus, const float p_reach) const {
	Terrain3DAVTSectorScan scan;
	// The conservative reach test, and the sample a cell gets from it. The plan worker applies the
	// same two steps in terrain_3d_avt_plan.cpp (`surrounding_sample`), and the two have to agree:
	// this one decides which cells exist at all, that one decides which of their pages are in reach,
	// so any difference between them is a page the plan asks for that no scan ever enumerated. They
	// are the same arithmetic because the camera position and the focus passed here are the same
	// point in XZ - the lead camera's - and they have to stay the same point for that to hold.
	auto in_reach = [&](const Rect2 &rect) {
		const Vector2 nearest(CLAMP(p_focus.x, rect.position.x, rect.get_end().x), CLAMP(p_focus.y, rect.position.y, rect.get_end().y));
		return nearest.distance_squared_to(p_focus) <= (p_reach + SECTOR_WORLD) * (p_reach + SECTOR_WORLD);
	};
	auto surrounding_sample = [&](const Rect2 &rect, const Vector2 &heights, TerrainVT::VisiblePatch &patch) {
		if (!in_reach(rect)) { return false; }
		patch.nearest = Vector3(CLAMP(p_camera_position.x, rect.position.x, rect.get_end().x),
				CLAMP(p_camera_position.y, heights.x, heights.y), CLAMP(p_camera_position.z, rect.position.y, rect.get_end().y));
		patch.distance = patch.nearest.distance_to(p_camera_position);
		// Conservative demand for a future camera yaw. This only spends idle/free
		// capacity and never changes the visible view's resolution or page budget.
		patch.density = p_view.orthographic ? p_view.focal : p_view.focal * 2.f / MAX(0.01f, patch.distance);
		return true;
	};
	scan.visible.reserve(_data->get_region_locations().size() * 64);
	std::map<SectorKey, size_t> overlapping;

	const float region_world = _region_size * _vertex_spacing;
	const bool aligned_regions = region_world >= SECTOR_WORLD && Math::is_equal_approx(region_world / SECTOR_WORLD, Math::round(region_world / SECTOR_WORLD));
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		Rect2 rect(Vector2(location) * region_world, Vector2(region_world, region_world));
		if (_vt.surface_svt_enabled && !in_reach(rect)) { continue; }
		int x0 = int(std::floor(rect.position.x / SECTOR_WORLD));
		int y0 = int(std::floor(rect.position.y / SECTOR_WORLD));
		int x1 = int(std::ceil(rect.get_end().x / SECTOR_WORLD)) - 1;
		int y1 = int(std::ceil(rect.get_end().y / SECTOR_WORLD)) - 1;
		if (!scan.has_world) { scan.world_x0 = x0; scan.world_y0 = y0; scan.world_x1 = x1; scan.world_y1 = y1; scan.has_world = true; }
		scan.world_x0 = MIN(scan.world_x0, x0); scan.world_y0 = MIN(scan.world_y0, y0);
		scan.world_x1 = MAX(scan.world_x1, x1); scan.world_y1 = MAX(scan.world_y1, y1);
		TerrainVT::VisiblePatch patch;
		if (!p_view.sample(rect, region->get_height_range(), patch) && !in_reach(rect)) { continue; }
		for (int y = y0; y <= y1; ++y) {
			for (int x = x0; x <= x1; ++x) {
				Rect2 sector_rect(Vector2(x, y) * SECTOR_WORLD, Vector2(SECTOR_WORLD, SECTOR_WORLD));
				if (_vt.surface_svt_enabled && !in_reach(sector_rect)) { continue; }
				// Clip against actual resident data, including regions smaller than a
				// sector and non-unit vertex spacing. Deduplicate overlapping regions.
				const Vector2 sector_heights = p_bounds_ready ? _vt.vt_source_snapshot->bounds(sector_rect.intersection(rect), region->get_height_range()) : region->get_height_range();
				const bool on_screen = p_view.sample(sector_rect.intersection(rect), sector_heights, patch);
				if (!on_screen && !surrounding_sample(sector_rect.intersection(rect), sector_heights, patch)) { continue; }
				const int base = get_avt_base_block_size();
				// Screen density predicts the derivative-selected mip used by the shader.
				const float required_density = MAX(0.001f, patch.density * _vt.surface_vt_texels_per_pixel * DEMAND_DENSITY_MARGIN);
				const int screen_mip = MAX(0, int(std::floor(std::log2(MAX(1.f, float(_vt.surface_vt_texels_per_meter) / required_density)))));
				int wanted = MAX(1, base >> MIN(15, screen_mip));
				if (!_vt.vt_adaptive_enabled) { wanted = base; }
				wanted = MIN(2048, wanted);
				Vector2i key(x, y);
				Sector sector = { key, key, 0, wanted, 1, on_screen, patch.distance, sector_heights };
				if (aligned_regions) { scan.visible.push_back(sector); }
				else {
					auto found = overlapping.find({ x, y });
					if (found == overlapping.end()) { overlapping[{ x, y }] = scan.visible.size(); scan.visible.push_back(sector); }
					else {
						Sector &previous = scan.visible[found->second];
						previous.produce |= on_screen; previous.wanted = MAX(previous.wanted, wanted); previous.distance = MIN(previous.distance, patch.distance);
						previous.heights.x = MIN(previous.heights.x, sector.heights.x); previous.heights.y = MAX(previous.heights.y, sector.heights.y);
					}
				}
			}
		}
	}
	return scan;
}

// Turns the scan into the working set: the 64 m cells sorted near to far, the
// hierarchy of coarse nodes above them, and the address budget they have to fit.
Terrain3DAVTHierarchy Terrain3D::_avt_build_hierarchy(const Terrain3DAVTSectorScan &p_scan) {
	Terrain3DAVTHierarchy hierarchy;
	hierarchy.directory_dirty = _vt.avt_directory_bytes.is_empty();
	// The world hierarchy supplies the footprint-selected coarse mips. Its
	// addresses remain stable during local refinement; residency is determined
	// below by the actual visible mip range, not by reserving every ancestor.
	const int pool_size = _vt.surface_vt->get_page_count();
	const bool offline_bake = _vt.bake.busy();
	// How much of the pool the near field's plan may name. `reserved` is what the plan may not
	// reach: at least what the far field needs, and at least a quarter of the pool.
	//
	// The quarter is the headroom the plan cannot do without. Production is asynchronous - a page
	// is allocated, assembled by a worker over several frames, and written when it arrives - so a
	// plan that reaches the pool's last slot makes every production evict the page it is about to
	// replace. Measured with the plan allowed to fill the pool: the planning chain ran five times
	// as often, the phase mean went from 0.13 to 0.7-1.0 ms, and the view still never converged.
	// The far field's own share is the other half of the same number, so the larger of the two is
	// what is held back.
	// The far field's visible-page count is only its detail set. Its protected root
	// pyramid lives in the same physical pool, so reserving `vt_svt_visible_pages`
	// alone lets the near plan name roots' slots as well. That is the oversubscription
	// seen at a high-resolution view: the plan fits its 768-page budget, while the
	// far field already owns 320 roots plus its detail pages. Use the last published
	// far set as the near budget's floor; the demand passes run near first, so an empty
	// initial far set needs a conservative half-pool hold until that set is known.
	const int svt_root_pages = CLAMP(int(_vt.svt_roots.pages.size()), 0, pool_size);
	const int svt_detail_pages = CLAMP(_vt.vt_svt_visible_pages, 0, pool_size);
	const int svt_reserved = svt_root_pages > 0 || _vt.svt_roots.settled
			? MIN(pool_size, svt_root_pages + svt_detail_pages)
			: pool_size / 2;
	const int reserved = offline_bake ? pool_size / 2
			: (_vt.surface_svt_enabled ? MAX(pool_size / 4, svt_reserved) : 0);
	const int budget = MAX(4, pool_size - reserved);
	const int root_budget = MAX(4, budget / 4);
	int root_level = 1;
	while (root_level < 24) {
		int scale = 1 << root_level;
		int64_t count = int64_t(floor_div(p_scan.world_x1, scale) - floor_div(p_scan.world_x0, scale) + 1) *
				(floor_div(p_scan.world_y1, scale) - floor_div(p_scan.world_y0, scale) + 1);
		if (count <= root_budget) { break; }
		++root_level;
	}
	// More physical capacity must not remove the old coarsest virtual level.
	// That would change the shader's terminal mip and orphan ready root pages.
	root_level = MAX(root_level, _vt.avt_root_level);
	// The root level set is a flat vector searched in place rather than a `std::map`: it is a few
	// dozen entries, and a node-based container pays an allocation and a tree walk per insert for a
	// lookup a linear scan of that size beats. The same reasoning the page pipeline's queue records.
	std::vector<Sector> roots;
	for (const Sector &item : p_scan.visible) {
		hierarchy.leaves.push_back(item);
		int x = floor_div(item.location.x, 1 << root_level);
		int y = floor_div(item.location.y, 1 << root_level);
		// Reserved CPU owner namespace; the GPU hashes the unmodified world key.
		Vector2i owner(x, y + 0x40000000 + root_level * 0x100000);
		bool known = false;
		for (const Sector &root : roots) {
			if (root.location.x == x && root.location.y == y) { known = true; break; }
		}
		if (!known) { roots.push_back({ Vector2i(x, y), owner, root_level, 1, 1, true, 0.f }); }
	}
	std::vector<Sector> &sectors = hierarchy.leaves;
	std::sort(sectors.begin(), sectors.end(), [](const Sector &a, const Sector &b) {
		if (a.distance != b.distance) { return a.distance < b.distance; }
		return a.location.y == b.location.y ? a.location.x < b.location.x : a.location.y < b.location.y;
	});
	// Address-space budgeting is independent of physical residency. Leave atlas
	// headroom for coarse roots and for buddy allocator fragmentation.
	const int64_t virtual_budget = int64_t(2048) * 2048 * 3 / 4 - roots.size() - sectors.size();
	int virtual_bias = 0;
	for (;;) {
		int64_t area = 0;
		for (const Sector &sector : sectors) { if (!sector.produce) { continue; } int size = MAX(1, sector.wanted >> virtual_bias); area += int64_t(size) * size; }
		if (area <= virtual_budget || virtual_bias >= 11) { break; }
		++virtual_bias;
	}
	for (Sector &sector : sectors) { sector.size = MAX(1, sector.wanted >> virtual_bias); }
	// Keep a world hierarchy between the coarse roots and the 64 m sectors.
	// This prevents a sector without fine pages from jumping straight to a huge root.
	std::vector<Sector> coarse;
	// Takes the sector by value: it appends to `coarse` while the caller may be holding a
	// reference into it.
	auto add_parent = [&coarse](const Sector p_sector) {
		const int level = p_sector.level + 1;
		Vector2i key(floor_div(p_sector.location.x, 2), floor_div(p_sector.location.y, 2));
		for (Sector &node : coarse) {
			if (node.level != level || node.location.x != key.x || node.location.y != key.y) { continue; }
			node.produce |= p_sector.produce;
			node.heights.x = MIN(node.heights.x, p_sector.heights.x);
			node.heights.y = MAX(node.heights.y, p_sector.heights.y);
			return;
		}
		coarse.push_back({ key, Vector2i(key.x, key.y + 0x40000000 + level * 0x100000), level, 1, 1, p_sector.produce, p_sector.distance, p_sector.heights });
	};
	for (const Sector &sector : sectors) { add_parent(sector); }
	// Build each parent once from the previous level, rather than revisiting
	// the entire ancestor chain for every leaf in a large visible world. The entries of the level
	// being read are the ones already there, so the loop reads through a snapshot of the size:
	// everything `add_parent` appends belongs to the next level.
	for (int level = 1; level < root_level; ++level) {
		const size_t end = coarse.size();
		for (size_t i = 0; i < end; ++i) {
			if (coarse[i].level == level) { add_parent(coarse[i]); }
		}
	}
	// Ordered as the keyed set it replaces was, so the working set keeps the order it had: the
	// level first, then x, then y, read backwards.
	std::sort(coarse.begin(), coarse.end(), [](const Sector &a, const Sector &b) {
		if (a.level != b.level) { return a.level < b.level; }
		return a.location.x == b.location.x ? a.location.y < b.location.y : a.location.x < b.location.x;
	});
	for (auto item = coarse.rbegin(); item != coarse.rend(); ++item) { hierarchy.working.push_back(*item); }
	_vt.avt_sector_stats["virtual_budget_bias"] = virtual_bias;
	// The three numbers the plan is a function of, published together: the plan is bounded by the
	// budget, the budget by the pool, and a plan at the pool's size is the state that cannot
	// converge. Reading them from one report is what tells the two apart.
	_vt.avt_sector_stats["pool_pages"] = pool_size;
	_vt.avt_sector_stats["plan_budget"] = budget;
	hierarchy.working.insert(hierarchy.working.end(), sectors.begin(), sectors.end());
	std::stable_sort(hierarchy.working.begin(), hierarchy.working.end(), [](const Sector &a, const Sector &b) { return a.produce > b.produce; });
	hierarchy.owners.reserve(hierarchy.working.size());
	for (const Sector &sector : hierarchy.working) { if (sector.produce) { hierarchy.owners.insert(avt_owner_key(sector.owner)); } }
	hierarchy.root_level = root_level;
	hierarchy.coarse_roots = int(roots.size());
	hierarchy.budget = budget;
	return hierarchy;
}

// Keeps the virtual block directory in step with the working set: releases the
// addresses of views the camera has left, allocates or resizes the rest, and
// reclaims address space when a visible block cannot be allocated otherwise.
void Terrain3D::_avt_sync_address_directory(Terrain3DAVTHierarchy &r_hierarchy, const Vector2 &p_focus, const float p_reach) {
	auto in_reach = [&](const Rect2 &rect) {
		const Vector2 nearest(CLAMP(p_focus.x, rect.position.x, rect.get_end().x), CLAMP(p_focus.y, rect.position.y, rect.get_end().y));
		return nearest.distance_squared_to(p_focus) <= (p_reach + SECTOR_WORLD) * (p_reach + SECTOR_WORLD);
	};
	bool &directory_dirty = r_hierarchy.directory_dirty;
	auto release_address = [&](const Terrain3DAVTCachedAddress &address) {
		_vt.surface_vt->unregister_sector(address.owner);
		_vt.vt_registered_sectors.erase(address.owner);
		_vt.avt_allocated_sizes.erase(avt_owner_key(address.owner));
		directory_dirty = true;
	};
	// Looking away does not invalidate material content. Keep addresses and cached
	// pages near the camera; physical pages remain evictable under actual demand.
	for (auto item = _vt.avt_cached_addresses.begin(); item != _vt.avt_cached_addresses.end();) {
		const Terrain3DAVTCachedAddress &address = item->second;
		const float span = SECTOR_WORLD * float(1 << address.level);
		Rect2 rect(Vector2(address.location) * span, Vector2(span, span));
		if (!r_hierarchy.owners.count(item->first) && _vt.surface_svt_enabled && !in_reach(rect)) {
			release_address(address);
			item = _vt.avt_cached_addresses.erase(item);
		} else { ++item; }
	}
	auto reclaim_addresses = [&]() {
		// Visible demand wins. Old views never force a lower virtual resolution.
		for (auto item = _vt.avt_cached_addresses.begin(); item != _vt.avt_cached_addresses.end();) {
			if (!r_hierarchy.owners.count(item->first)) { release_address(item->second); item = _vt.avt_cached_addresses.erase(item); }
			else { ++item; }
		}
		for (const Sector &sector : r_hierarchy.working) {
			auto allocated = _vt.avt_allocated_sizes.find(avt_owner_key(sector.owner));
			if (allocated != _vt.avt_allocated_sizes.end() && allocated->second > sector.size && _vt.surface_vt->resize_sector(sector.owner, sector.size)) {
				allocated->second = sector.size; directory_dirty = true;
			}
		}
	};
	for (const Sector &sector : r_hierarchy.working) {
		auto allocated = _vt.avt_allocated_sizes.find(avt_owner_key(sector.owner));
		int previous_size = allocated != _vt.avt_allocated_sizes.end() ? allocated->second : 0;
		if (previous_size == 0) {
			bool registered = _vt.surface_vt->register_sector(sector.owner, sector.size);
			if (!registered && sector.produce) { reclaim_addresses(); registered = _vt.surface_vt->register_sector(sector.owner, sector.size); }
			if (registered) {
				_vt.vt_registered_sectors[sector.owner] = true; _vt.avt_allocated_sizes[avt_owner_key(sector.owner)] = sector.size; directory_dirty = true;
				++r_hierarchy.size_grows;
			}
		} else if (previous_size < sector.size) {
			bool resized = _vt.surface_vt->resize_sector(sector.owner, sector.size);
			if (!resized && sector.produce) { reclaim_addresses(); resized = _vt.surface_vt->resize_sector(sector.owner, sector.size); }
			directory_dirty |= resized;
			if (resized) { _vt.avt_allocated_sizes[avt_owner_key(sector.owner)] = sector.size; ++r_hierarchy.size_grows; }
		}
		if (_vt.surface_vt->has_sector(sector.owner)) { _vt.avt_cached_addresses[avt_owner_key(sector.owner)] = { sector.location, sector.owner, sector.level }; }
	}
	_vt.avt_registered_owners.clear();
	for (const auto &entry : _vt.avt_cached_addresses) { _vt.avt_registered_owners.push_back(entry.second.owner); }
	_vt.avt_sector_stats["retained_sector_addresses"] = int(_vt.avt_cached_addresses.size());
	// The one event in this pass that re-addresses a whole sector at once. Read beside P0e's
	// `plan_rescaled` to tell a block-size growth from the refinement walk picking a new mip.
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
	// The block size the shader reads is this ratio, and the planner only records it in the
	// plan it submits after publishing, so derive the live value instead of reading
	// `_vt.avt_plan_logical_ratio`: on the first publish of a configuration that member is
	// still its default of zero, and a zero block size collapses every fragment of the
	// sector onto the block's first page.
	const float logical_ratio = _avt_logical_ratio();
	for (const auto &cached : _vt.avt_cached_addresses) {
		const Terrain3DAVTCachedAddress &sector = cached.second;
		if (!_vt.surface_vt->has_sector(sector.owner)) { continue; }
		uint32_t index = sector_hash(sector.location.x, sector.location.y, sector.level) & (entries - 1);
		while (occupied[index]) { index = (index + 1) & (entries - 1); }
		occupied[index] = true;
		int size = _vt.surface_vt->get_sector_block_size(sector.owner);
		float entry[8] = { float(sector.location.x), float(sector.location.y), float(sector.level), 1.f,
				float(_vt.surface_vt->get_sector_block_origin_x(sector.owner)), float(_vt.surface_vt->get_sector_block_origin_y(sector.owner)), float(size), sector.level ? 1.f : float(size) * logical_ratio };
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
