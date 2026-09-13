// World-aligned procedural AVT. Geometry regions are deliberately not sectors.
#include "terrain_3d.h"
#include "terrain_3d_vt_visibility.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <tuple>
#include <unordered_set>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/time.hpp>

namespace {
constexpr float SECTOR_WORLD = 64.f;
using SectorKey = std::pair<int, int>;
struct Sector {
	Vector2i location;
	Vector2i owner;
	int level = 0;
	int wanted = 1;
	int size = 1;
	bool produce = true;
	float distance = 0.f;
	Vector2 heights;
};

uint32_t sector_hash(int x, int y, int level) {
	return uint32_t(x) * 73856093u ^ uint32_t(y) * 19349663u ^ uint32_t(level) * 83492791u;
}
int floor_div(int value, int scale) { return int(std::floor(double(value) / scale)); }
}

void Terrain3D::set_surface_vt_texels_per_meter(real_t p_value) {
	if (!std::isfinite(p_value)) { return; }
	p_value = CLAMP(p_value, 1.f, 8192.f);
	if (_surface_vt_texels_per_meter == p_value) { return; }
	_surface_vt_texels_per_meter = p_value;
	_reset_vt_configuration(); // A changed density changes every page footprint.
}
void Terrain3D::set_surface_svt_texels_per_meter(real_t p_value) {
	if (!std::isfinite(p_value)) { return; }
	set_surface_svt_page_world(_vt_page_size / CLAMP(p_value, 0.01f, 8192.f));
}
int Terrain3D::get_avt_base_block_size() const {
	int size = 1;
	while (size < 64.f * _surface_vt_texels_per_meter / _vt_page_size) { size <<= 1; }
	return size;
}
// Compatibility with saved experimental distance controls; automatic LOD is authoritative.
void Terrain3D::set_surface_vt_distance_mips(bool p_enabled) { _surface_vt_distance_mips = false; }
void Terrain3D::set_surface_vt_mip_ranges(const Vector3 &p_ranges) { }
float Terrain3D::get_surface_vt_distance_lod(float p_distance) const { return 0.f; }

void Terrain3D::set_surface_vt_mip_distances(const PackedFloat32Array &p_distances) {
	PackedFloat32Array normalized;
	for (int i = 0; i < MIN(16, int(p_distances.size())); ++i) {
		const float previous = i ? normalized[i - 1] : 0.f;
		normalized.push_back(std::isfinite(p_distances[i]) ? MAX(previous + 0.01f, p_distances[i]) : previous + 1.f);
	}
	_surface_vt_mip_distances = normalized;
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
}
int Terrain3D::get_surface_vt_mip_for_distance(real_t p_distance) const {
	const int top = TerrainVT::log2_power_of_two(is_sector_avt() ? get_avt_base_block_size() : _surface_vt_pages_per_axis);
	int mip = 0;
	float edge = 8.f;
	while (mip < top) {
		if (mip < _surface_vt_mip_distances.size()) { edge = _surface_vt_mip_distances[mip]; }
		if (p_distance <= edge) { break; }
		++mip; edge *= 2.f;
	}
	return mip;
}

void Terrain3D::set_surface_vt_selection_mode(int p_mode) {
	p_mode = CLAMP(p_mode, 0, 2);
	if (_surface_vt_selection_mode == p_mode) { return; }
	_surface_vt_selection_mode = p_mode;
	_vt_view_focus_valid = false;
	// A legacy region coordinate and a 64 m sector coordinate describe different
	// footprints. They cannot share cached address ownership across a mode switch.
	_reset_vt_configuration();
	notify_property_list_changed();
}

int Terrain3D::_update_sector_avt(int p_max_pages) {
	if (!_surface_vt || !_data || !_vt_shared_ready || !get_camera()) { return 0; }
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	// Only planning is cached. Page requests still touch residency and repair
	// invalidated/evicted pages on every demand epoch, within the normal budget.
	const Vector3 camera_position = get_camera()->get_global_position();
	const Vector2 focus(camera_position.x, camera_position.z);
	const float reach = MAX(64.f, float(_surface_vt_distance));
	auto in_reach = [&](const Rect2 &rect) {
		Vector2 nearest(CLAMP(focus.x, rect.position.x, rect.get_end().x), CLAMP(focus.y, rect.position.y, rect.get_end().y));
		return nearest.distance_squared_to(focus) <= (reach + SECTOR_WORLD) * (reach + SECTOR_WORLD);
	};
	Array state;
	state.push_back(get_camera()->get_global_transform());
	state.push_back(get_camera()->get_camera_projection());
	state.push_back(get_camera()->get_viewport()->get_visible_rect());
	state.push_back(_region_size); state.push_back(_vertex_spacing);
	state.push_back(_surface_vt_texels_per_meter); state.push_back(_surface_vt_texels_per_pixel);
	state.push_back(_surface_vt_mip_distances); state.push_back(_vt_adaptive_enabled);
	state.push_back(_surface_svt_enabled); state.push_back(_surface_vt_distance);
	state.push_back(!_vt_svt_bake_queue.is_empty() || !_vt_svt_bake_waiting.is_empty());
	state.push_back(_vt_page_count); state.push_back(_vt_page_size);
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		state.push_back(location); state.push_back(region->get_height_range());
	}
	const PackedByteArray plan_key = UtilityFunctions::var_to_bytes(state);
	if (!_avt_plan_key.is_empty() && plan_key == _avt_plan_key) {
		_avt_sector_stats["plan_reused"] = true;
		_avt_sector_stats["directory_rebuilt"] = false;
		int produced = _produce_sector_avt_pages(p_max_pages);
		_avt_sector_stats["cpu_update_ms"] = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
		return produced;
	}
	_avt_sector_stats["plan_reused"] = false;
	_avt_sector_stats["coverage_center"] = focus;
	_avt_sector_stats["coverage_radius"] = _surface_svt_enabled ? reach : -1.f;
	TerrainVT::VisibleView view(get_camera());
	auto surrounding_sample = [&](const Rect2 &rect, const Vector2 &heights, TerrainVT::VisiblePatch &patch) {
		if (!in_reach(rect)) { return false; }
		patch.nearest = Vector3(CLAMP(camera_position.x, rect.position.x, rect.get_end().x),
				CLAMP(camera_position.y, heights.x, heights.y), CLAMP(camera_position.z, rect.position.y, rect.get_end().y));
		patch.distance = patch.nearest.distance_to(camera_position);
		// Conservative demand for a future camera yaw. This only spends idle/free
		// capacity and never changes the visible view's resolution or page budget.
		patch.density = view.orthographic ? view.focal : view.focal * 2.f / MAX(0.01f, patch.distance);
		return true;
	};
	std::vector<Sector> visible;
	visible.reserve(_data->get_region_locations().size() * 64);
	std::map<SectorKey, size_t> overlapping;

	const float region_world = _region_size * _vertex_spacing;
	const bool aligned_regions = region_world >= SECTOR_WORLD && Math::is_equal_approx(region_world / SECTOR_WORLD, Math::round(region_world / SECTOR_WORLD));
	int world_x0 = 0, world_y0 = 0, world_x1 = 0, world_y1 = 0;
	bool has_world = false;
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		Rect2 rect(Vector2(location) * region_world, Vector2(region_world, region_world));
		if (_surface_svt_enabled && !in_reach(rect)) { continue; }
		int x0 = int(std::floor(rect.position.x / SECTOR_WORLD));
		int y0 = int(std::floor(rect.position.y / SECTOR_WORLD));
		int x1 = int(std::ceil(rect.get_end().x / SECTOR_WORLD)) - 1;
		int y1 = int(std::ceil(rect.get_end().y / SECTOR_WORLD)) - 1;
		if (!has_world) { world_x0 = x0; world_y0 = y0; world_x1 = x1; world_y1 = y1; has_world = true; }
		world_x0 = MIN(world_x0, x0); world_y0 = MIN(world_y0, y0);
		world_x1 = MAX(world_x1, x1); world_y1 = MAX(world_y1, y1);
		TerrainVT::VisiblePatch patch;
		if (!view.sample(rect, region->get_height_range(), patch) && !in_reach(rect)) { continue; }
		for (int y = y0; y <= y1; ++y) {
			for (int x = x0; x <= x1; ++x) {
				Rect2 sector_rect(Vector2(x, y) * SECTOR_WORLD, Vector2(SECTOR_WORLD, SECTOR_WORLD));
				if (_surface_svt_enabled && !in_reach(sector_rect)) { continue; }
				// Clip against actual resident data, including regions smaller than a
				// sector and non-unit vertex spacing. Deduplicate overlapping regions.
				const bool on_screen = view.sample(sector_rect.intersection(rect), region->get_height_range(), patch);
				if (!on_screen && !surrounding_sample(sector_rect.intersection(rect), region->get_height_range(), patch)) { continue; }
				const int base = get_avt_base_block_size();
				// Screen density predicts the derivative-selected mip used by the shader.
				const float required_density = MAX(0.001f, patch.density * _surface_vt_texels_per_pixel);
				const int screen_mip = MAX(0, int(std::floor(std::log2(MAX(1.f, float(_surface_vt_texels_per_meter) / required_density)))));
				int wanted = MAX(1, base >> MIN(15, screen_mip));
				if (!_vt_adaptive_enabled) { wanted = base; }
				wanted = MIN(2048, wanted);
				Vector2i key(x, y);
				Sector sector = { key, key, 0, wanted, 1, on_screen, patch.distance, region->get_height_range() };
				if (aligned_regions) { visible.push_back(sector); }
				else {
					auto found = overlapping.find({x, y});
					if (found == overlapping.end()) { overlapping[{x, y}] = visible.size(); visible.push_back(sector); }
					else {
						Sector &previous = visible[found->second];
						previous.produce |= on_screen; previous.wanted = MAX(previous.wanted, wanted); previous.distance = MIN(previous.distance, patch.distance);
						previous.heights.x = MIN(previous.heights.x, sector.heights.x); previous.heights.y = MAX(previous.heights.y, sector.heights.y);
					}
				}

			}
		}
	}
	// Stable coarse procedural coverage is independent of camera distance and
	// remains resident during sector refinement. Coarse pages can serve many
	// logical sectors, so visibility is never capped by the physical slot count.
	const int pool_size = _surface_vt->get_page_count();
	const bool offline_bake = !_vt_svt_bake_queue.is_empty() || !_vt_svt_bake_waiting.is_empty();
	const int budget = (offline_bake || _surface_svt_enabled) ? MAX(4, pool_size / 2) : pool_size;
	const int root_budget = MAX(4, budget / 4);
	int root_level = 1;
	while (root_level < 24) {
		int scale = 1 << root_level;
		int64_t count = int64_t(floor_div(world_x1, scale) - floor_div(world_x0, scale) + 1) *
				(floor_div(world_y1, scale) - floor_div(world_y0, scale) + 1);
		if (count <= root_budget) { break; }
		++root_level;
	}
	std::map<SectorKey, Sector> roots;
	std::vector<Sector> sectors;
	for (const auto &item : visible) {
		sectors.push_back(item);
		int x = floor_div(item.location.x, 1 << root_level);
		int y = floor_div(item.location.y, 1 << root_level);
		// Reserved CPU owner namespace; the GPU hashes the unmodified world key.
		Vector2i owner(x, y + 0x40000000 + root_level * 0x100000);
		roots[{ x, y }] = { Vector2i(x, y), owner, root_level, 1, 1, true, 0.f };
	}
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
	_avt_sector_stats["virtual_budget_bias"] = virtual_bias;
	// Keep a world hierarchy between the coarse roots and the 64 m sectors.
	// This prevents a sector without fine pages from jumping straight to a huge root.
	using NodeKey = std::tuple<int, int, int>;
	std::map<NodeKey, Sector> coarse;
	auto add_parent = [&](const Sector &sector) {
		const int level = sector.level + 1;
		Vector2i key(floor_div(sector.location.x, 2), floor_div(sector.location.y, 2));
		NodeKey node(level, key.x, key.y);
		auto found = coarse.find(node);
		if (found == coarse.end()) {
			coarse[node] = {key, Vector2i(key.x, key.y + 0x40000000 + level * 0x100000), level, 1, 1, sector.produce, sector.distance, sector.heights};
		} else {
			found->second.produce |= sector.produce;
			found->second.heights.x = MIN(found->second.heights.x, sector.heights.x);
			found->second.heights.y = MAX(found->second.heights.y, sector.heights.y);
		}
	};
	for (const Sector &sector : sectors) { add_parent(sector); }
	// Build each parent once from the previous level, rather than revisiting
	// the entire ancestor chain for every leaf in a large visible world.
	for (int level = 1; level < root_level; ++level) {
		auto item = coarse.lower_bound({level, INT32_MIN, INT32_MIN});
		while (item != coarse.end() && std::get<0>(item->first) == level) { add_parent((item++)->second); }
	}
	std::vector<Sector> working;
	for (auto item = coarse.rbegin(); item != coarse.rend(); ++item) { working.push_back(item->second); }
	working.insert(working.end(), sectors.begin(), sectors.end());
	std::stable_sort(working.begin(), working.end(), [](const Sector &a, const Sector &b) { return a.produce > b.produce; });
	auto owner_key = [](Vector2i key) { return (uint64_t(uint32_t(key.x)) << 32) | uint32_t(key.y); };
	std::unordered_map<uint64_t, const Sector *> nodes;
	nodes.reserve(working.size());
	for (const Sector &sector : working) { nodes[owner_key(sector.owner)] = &sector; }
	std::unordered_set<uint64_t> owners;
	owners.reserve(working.size());
	for (const Sector &sector : working) { if (sector.produce) { owners.insert(owner_key(sector.owner)); } }
	bool directory_dirty = _avt_directory_bytes.is_empty();
	bool remapped = false;
	auto release_address = [&](const AVTCachedAddress &address) {
		_surface_vt->unregister_sector(address.owner);
		_vt_registered_sectors.erase(address.owner);
		_avt_allocated_sizes.erase(owner_key(address.owner));
		directory_dirty = true;
	};
	// Looking away does not invalidate material content. Keep addresses and cached
	// pages near the camera; physical pages remain evictable under actual demand.
	for (auto item = _avt_cached_addresses.begin(); item != _avt_cached_addresses.end();) {
		const AVTCachedAddress &address = item->second;
		const float span = SECTOR_WORLD * float(1 << address.level);
		Rect2 rect(Vector2(address.location) * span, Vector2(span, span));
		if (!owners.count(item->first) && _surface_svt_enabled && !in_reach(rect)) {
			release_address(address);
			item = _avt_cached_addresses.erase(item);
		} else { ++item; }
	}
	auto reclaim_addresses = [&]() {
		// Visible demand wins. Old views never force a lower virtual resolution.
		for (auto item = _avt_cached_addresses.begin(); item != _avt_cached_addresses.end();) {
			if (!owners.count(item->first)) { release_address(item->second); item = _avt_cached_addresses.erase(item); }
			else { ++item; }
		}
		for (const Sector &sector : working) {
			auto allocated = _avt_allocated_sizes.find(owner_key(sector.owner));
			if (allocated != _avt_allocated_sizes.end() && allocated->second > sector.size && _surface_vt->resize_sector(sector.owner, sector.size)) {
				allocated->second = sector.size; remapped = true; directory_dirty = true;
			}
		}
	};
	for (const Sector &sector : working) {
		auto allocated = _avt_allocated_sizes.find(owner_key(sector.owner));
		int previous_size = allocated != _avt_allocated_sizes.end() ? allocated->second : 0;
		if (previous_size == 0) {
			bool registered = _surface_vt->register_sector(sector.owner, sector.size);
			if (!registered && sector.produce) { reclaim_addresses(); registered = _surface_vt->register_sector(sector.owner, sector.size); }
			if (registered) {
				_vt_registered_sectors[sector.owner] = true; _avt_allocated_sizes[owner_key(sector.owner)] = sector.size; directory_dirty = true;
			}
		} else if (previous_size < sector.size) {
			bool resized = _surface_vt->resize_sector(sector.owner, sector.size);
			if (!resized && sector.produce) { reclaim_addresses(); resized = _surface_vt->resize_sector(sector.owner, sector.size); }
			remapped |= resized; directory_dirty |= resized;
			if (resized) { _avt_allocated_sizes[owner_key(sector.owner)] = sector.size; }
		}
		if (_surface_vt->has_sector(sector.owner)) { _avt_cached_addresses[owner_key(sector.owner)] = {sector.location, sector.owner, sector.level}; }
	}
	_avt_registered_owners.clear();
	for (const auto &entry : _avt_cached_addresses) { _avt_registered_owners.push_back(entry.second.owner); }
	_avt_sector_stats["retained_sector_addresses"] = int(_avt_cached_addresses.size());
	if (remapped) {
		for (const Variant &key : _vt_page_records.keys()) {
			for (const Dictionary &owner : _surface_vt->get_slot_owner_metadata(int(key))) {
				if (bool(owner["world_space"])) { continue; }
				Vector2i sector = owner["sector"];
				int mip = owner["mip"];
				Dictionary record = _vt_page_records[key];
				record["mip"] = mip;
				record["address"] = Vector2i(owner["virtual"]) - Vector2i(
						_surface_vt->get_sector_block_origin_x(sector) >> mip,
						_surface_vt->get_sector_block_origin_y(sector) >> mip);
			}
		}
	}

	// Refine only visible page footprints. The refinement walk never enumerates a
	// virtual image's full mip pyramid (256 squared entries need zero resident
	// pages until requested). Coarse roots cover delayed and over-budget demand.
	struct Page { const Sector *sector; int mip, x, y; Rect2 rect; float priority; };
	std::vector<Page> chosen;
	const float logical_ratio = SECTOR_WORLD * _surface_vt_texels_per_meter / (_vt_page_size * get_avt_base_block_size());
	auto make_page = [&](const Sector &sector, int mip, int x, int y, Page &page, bool prefetch = false) {
		const int size = _surface_vt->get_sector_block_size(sector.owner);
		const float logical = sector.level ? 1.f : size * logical_ratio;
		const float span = SECTOR_WORLD * float(1 << sector.level) * float(1 << mip) / logical;
		const Rect2 sector_rect(Vector2(sector.location) * (SECTOR_WORLD * float(1 << sector.level)), Vector2(1, 1) * (SECTOR_WORLD * float(1 << sector.level)));
		const Rect2 rect(sector_rect.position + Vector2(x, y) * span, Vector2(span, span));
		TerrainVT::VisiblePatch patch;
		if (!rect.intersects(sector_rect)) { return false; }
		if (prefetch ? !surrounding_sample(rect.intersection(sector_rect), sector.heights, patch) : !view.sample(rect.intersection(sector_rect), sector.heights, patch)) { return false; }
		const float density = patch.density * _surface_vt_texels_per_pixel;
		const float projected = span * density / _vt_page_size;
		page = { &sector, mip, x, y, rect, (mip > 0 || sector.level > 0) && projected > 1.f ? MAX(1.f, projected) : 0.f };
		return true;
	};
	for (const Sector &sector : working) {
		if (sector.level != root_level || !_surface_vt->has_sector(sector.owner)) { continue; }
		Page page;
		if (make_page(sector, 0, 0, 0, page)) { chosen.push_back(page); }
	}
	const int root_count = int(chosen.size());
	// Visible and idle plans share the same parent-preserving refinement rule.
	auto refine_pages = [&](std::vector<Page> &pages, int page_budget, bool prefetch) {
		for (;;) {
			int best = -1;
			for (int i = 0; i < int(pages.size()); ++i) {
				if (pages[i].priority > 0.f && (best < 0 || pages[i].priority > pages[best].priority)) { best = i; }
			}
			if (best < 0) { break; }
			Page parent = pages[best];
			pages[best].priority = 0.f;
			std::vector<Page> children;
			for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) {
				Page child;
				if (parent.sector->level > 0) {
					int level = parent.sector->level - 1;
					Vector2i child_owner(parent.sector->location.x * 2 + x, parent.sector->location.y * 2 + y + (level ? 0x40000000 + level * 0x100000 : 0));
					auto node = nodes.find(owner_key(child_owner));
					if (node == nodes.end() || !_surface_vt->has_sector(node->second->owner)) { continue; }
					int mip = level ? 0 : TerrainVT::log2_power_of_two(_surface_vt->get_sector_block_size(node->second->owner));
					if (make_page(*node->second, mip, 0, 0, child, prefetch)) { children.push_back(child); }
				} else if (parent.mip > 0 && make_page(*parent.sector, parent.mip - 1, parent.x * 2 + x, parent.y * 2 + y, child, prefetch)) {
					children.push_back(child);
				}
			}
			if (pages.size() + children.size() <= size_t(page_budget)) { pages.insert(pages.end(), children.begin(), children.end()); }
		}
	};
	refine_pages(chosen, budget, false);
	_avt_page_plan.clear();
	float finest_requested_texel = FLT_MAX;
	for (const Page &page : chosen) {
		_avt_page_plan.push_back({ page.sector->owner, page.mip, page.x, page.y, page.rect });
		finest_requested_texel = MIN(finest_requested_texel, page.rect.size.x / _vt_page_size);
	}
	_avt_sector_stats["finest_requested_texel_world"] = chosen.empty() ? 0.f : finest_requested_texel;
	// Prepare surrounding detail after the visible plan is fixed. A separate idle
	// queue may use free slots, but never evicts a resident page or steals demand.
	std::vector<Page> warm;
	for (const Sector &sector : working) {
		if (sector.level != root_level || !_surface_vt->has_sector(sector.owner)) { continue; }
		Page page;
		if (make_page(sector, 0, 0, 0, page, true)) { warm.push_back(page); }
	}
	refine_pages(warm, pool_size, true);
	_avt_prefetch_plan.clear();
	for (const Page &page : warm) { _avt_prefetch_plan.push_back({page.sector->owner, page.mip, page.x, page.y, page.rect}); }
	_avt_sector_stats["prefetch_requests"] = int(warm.size());
	_avt_sector_stats["requested_physical_pages"] = int(chosen.size());
	_avt_sector_stats["retained_hierarchy"] = true;
	_avt_sector_stats["visible_root_pages"] = root_count;
	_avt_sector_stats["base_virtual_resolution"] = SECTOR_WORLD * _surface_vt_texels_per_meter;
	_avt_sector_stats["base_page_entries"] = SECTOR_WORLD * _surface_vt_texels_per_meter / _vt_page_size;
	_avt_sector_stats["indirection_size"] = 2048;
	_avt_sector_stats["directory_rebuilt"] = directory_dirty || root_level != _avt_root_level;
	bool directory_changed = false;
	if (directory_dirty || root_level != _avt_root_level) {
		// A sparse hash directory decouples GPU sector lookup from region layer IDs.
		// Two RGBA32F texels hold an exact world key/level and block origin/size.
		int entries = 1;
		while (entries < int(_avt_cached_addresses.size()) * 2) { entries <<= 1; }
		int width = MIN(1024, entries * 2);
		int height = MAX(1, entries * 2 / width);
		PackedByteArray bytes;
		bytes.resize(int64_t(width) * height * 4 * sizeof(float));
		bytes.fill(0);
		uint8_t *output = bytes.ptrw();
		std::vector<bool> occupied(entries, false);
		int detailed = 0, max_size = 0;
		for (const auto &cached : _avt_cached_addresses) {
			const AVTCachedAddress &sector = cached.second;
			if (!_surface_vt->has_sector(sector.owner)) { continue; }
			uint32_t index = sector_hash(sector.location.x, sector.location.y, sector.level) & (entries - 1);
			while (occupied[index]) { index = (index + 1) & (entries - 1); }
			occupied[index] = true;
			int size = _surface_vt->get_sector_block_size(sector.owner);
			float entry[8] = { float(sector.location.x), float(sector.location.y), float(sector.level), 1.f,
					float(_surface_vt->get_sector_block_origin_x(sector.owner)), float(_surface_vt->get_sector_block_origin_y(sector.owner)), float(size), sector.level ? 1.f : float(size) * logical_ratio };
			std::memcpy(output + int64_t(index) * sizeof(entry), entry, sizeof(entry));
			if (sector.level == 0 && owners.count(cached.first)) { ++detailed; max_size = MAX(max_size, size); }
		}
		directory_changed = bytes != _avt_directory_bytes || root_level != _avt_root_level;
		if (directory_changed) {
			Ref<Image> image = Image::create_from_data(width, height, false, Image::FORMAT_RGBAF, bytes);
			if (_avt_sector_directory.is_valid() && _avt_sector_directory->get_width() == width && _avt_sector_directory->get_height() == height) { _avt_sector_directory->update(image); }
			else { _avt_sector_directory = ImageTexture::create_from_image(image); }
			_avt_directory_bytes = bytes;
			_avt_directory_mask = entries - 1;
			_avt_root_level = root_level;
		}
		_avt_sector_stats["independent_sectors"] = detailed;
		_avt_sector_stats["max_allocated_resolution"] = max_size * _vt_page_size;
	}
	_avt_sector_stats["visible_sectors"] = int(std::count_if(sectors.begin(), sectors.end(), [](const Sector &sector) { return sector.produce; }));
	_avt_sector_stats["coarse_pages"] = int(roots.size());
	_avt_sector_stats["coarse_world_size"] = SECTOR_WORLD * float(1 << root_level);
	if (directory_changed && _material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
	_avt_plan_key = plan_key;
	int produced = _produce_sector_avt_pages(p_max_pages);
	_avt_sector_stats["cpu_update_ms"] = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	return produced;
}

int Terrain3D::_produce_sector_avt_pages(int p_max_pages) {
	if (p_max_pages == 0) { return 0; }
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	_surface_vt->set_allocation_budget(p_max_pages > 0 ? p_max_pages : -1);
	int produced = 0;
	std::vector<int> protected_slots;
	auto produce_page = [&](const AVTPageRequest &page) {
		bool miss = false;
		int slot = _surface_vt->request_page_internal(page.owner, page.mip, page.x, page.y, &miss);
		if (slot < 0 || !miss) { return false; }
		_invalidate_vt_slot(slot);
		Ref<Image> payload;
		if (_data->produce_surface_rect_page(page.rect, _vt_page_size, _vt_page_border, payload) < 0 || !_surface_vt->write_page(slot, payload)) {
			_surface_vt->release_page(page.owner, page.mip, page.x, page.y);
			return false;
		}
		_queue_vt_material_page(slot, payload, page.rect, false, page.mip, Vector2i(page.x, page.y));
		_surface_vt->protect_page(slot, true);
		protected_slots.push_back(slot);
		return true;
	};
	for (const AVTPageRequest &page : _avt_page_plan) {
		int slot = _surface_vt->lookup_virtual((_surface_vt->get_sector_block_origin_x(page.owner) >> page.mip) + page.x, (_surface_vt->get_sector_block_origin_y(page.owner) >> page.mip) + page.y, page.mip, page.mip);
		if (slot >= 0 && !_surface_vt->is_page_protected(slot)) { _surface_vt->protect_page(slot, true); protected_slots.push_back(slot); }
	}
	for (const AVTPageRequest &page : _avt_page_plan) {
		// Bound CPU payload generation as well as page count. A single page is indivisible.
		if (produced > 0 && Time::get_singleton()->get_ticks_usec() - started >= 3000) { _surface_vt->set_allocation_budget(0); }
		produced += produce_page(page) ? 1 : 0;
	}
	int prefetched = 0;
	if (produced == 0) {
		const auto pool = _surface_vt->get_page_pool();
		for (const AVTPageRequest &page : _avt_prefetch_plan) {
			if (Time::get_singleton()->get_ticks_usec() - started >= 3000 ||
					std::find(pool->slot_used.begin(), pool->slot_used.end(), uint8_t(0)) == pool->slot_used.end()) { break; }
			prefetched += produce_page(page) ? 1 : 0;
		}
	}
	_avt_sector_stats["prefetched"] = prefetched;
	produced += prefetched;
	for (int slot : protected_slots) { _surface_vt->protect_page(slot, false); }
	_surface_vt->commit();
	_surface_vt->set_allocation_budget(-1);
	_avt_sector_stats["produced"] = produced;
	return produced;
}
