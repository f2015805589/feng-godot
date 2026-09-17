// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Surface virtual texture service: view setup and teardown, the settings the editor
// and scripts write, and the near/far demand passes. Split out of terrain_3d.cpp;
// the addressing itself lives in terrain_3d_virtual_texture.cpp.

#include "terrain_3d.h"

#include "logger.h"
#include "terrain_3d_util.h"
#include "terrain_3d_vt_visibility.h"

#include <godot_cpp/classes/compositor.hpp>
#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/classes/surface_tool.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/world3d.hpp>

///////////////////////////
// Surface virtual texture
///////////////////////////

void Terrain3D::_setup_surface_vt() {
	if (_vt.surface_vt || !_data) {
		return;
	}
	LOG(DEBUG, "Creating surface virtual texture");
	_vt.surface_vt = memnew(Terrain3DVirtualTexture);
	_configure_surface_view(_vt.surface_vt, false);
	_vt.surface_vt->initialize();
}

void Terrain3D::_destroy_surface_vt() {
	LOG(INFO, "Destroying surface virtual texture");
	memdelete_safely(_vt.surface_vt);
	_vt.surface_vt_enabled = false;
}

void Terrain3D::_setup_surface_svt() {
	if (_vt.surface_svt || !_data) {
		return;
	}
	LOG(DEBUG, "Creating far-field surface virtual texture");
	_vt.surface_svt = memnew(Terrain3DVirtualTexture);
	_configure_surface_view(_vt.surface_svt, true);
	_vt.surface_svt->initialize();
}

// One view's configuration, apart from the physical pool it is attached to. Both
// the initial setup and a shared-pool rebuild go through here, so neither path
// depends on settings that a previous configuration happened to leave on the
// object -- notably the resolved world mip cap and the minimal block size.
void Terrain3D::_configure_surface_view(Terrain3DVirtualTexture *p_view, const bool p_world_space) {
	p_view->set_world_space(p_world_space);
	p_view->set_format(Image::Format(39));
	if (p_world_space) {
		p_view->set_page_size(_vt.surface_svt_page_size);
		p_view->set_page_border(_vt.surface_svt_page_border);
		p_view->set_page_count(_vt.surface_svt_page_count);
		// A world grid needs no allocator, so the indirection is sized directly: enough
		// pages to hold the reach, with headroom for the LRU. -1 re-resolves the cap on
		// initialize(); a stale resolved cap must not survive a resize.
		p_view->set_indirection_size(MAX(64, _vt.surface_svt_page_count * 4));
		p_view->set_world_max_mip(_vt.surface_svt_max_mip);
		return;
	}
	p_view->set_page_size(_vt.surface_vt_page_size);
	p_view->set_page_border(_vt.surface_vt_page_border);
	p_view->set_page_count(_vt.surface_vt_page_count);
	// One page per axis per sector is legal (a 1x1 virtual image), which is what a
	// region whose surface map is already page-sized wants.
	p_view->set_minimal_block(1);
	p_view->set_indirection_size(is_sector_avt() ? 2048 : MAX(64, _vt.surface_vt_page_count * 4));
}

void Terrain3D::_destroy_surface_svt() {
	LOG(INFO, "Destroying far-field surface virtual texture");
	memdelete_safely(_vt.surface_svt);
	_vt.surface_svt_enabled = false;
}

void Terrain3D::set_surface_svt_enabled(const bool p_enabled) {
	_vt.surface_svt_enabled = p_enabled;
	if (p_enabled) { _vt.svt_startup_ready = false; }
	if (p_enabled && _initialized) { set_physics_process(true); }
	LOG(INFO, "Far-field surface virtual texture ", p_enabled ? "enabled" : "disabled");
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

void Terrain3D::set_surface_svt_page_world(const real_t p_size) {
	_vt.surface_svt_page_world = CLAMP(p_size, 0.001f, 65536.f);
	if (!_vt.vt_debug_direct_material) {
		_reset_vt_configuration();
		return;
	}
	if (_vt.surface_svt) {
		// Page contents are world aligned, so a different page size invalidates every
		// page; a fresh atlas is cheaper than tracking that.
		_vt.surface_svt->clear();
		_vt.surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_page_size(const int p_size) {
	if (!_vt.vt_debug_direct_material) { set_vt_page_size(p_size); _vt.surface_vt_page_size = _vt.surface_svt_page_size = _vt.vt_page_size; return; }
	_vt.surface_svt_page_size = CLAMP(p_size, 1, 4096);
	if (_vt.surface_svt) {
		_vt.surface_svt->set_page_size(_vt.surface_svt_page_size);
		_vt.surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_page_border(const int p_border) {
	if (!_vt.vt_debug_direct_material) { set_vt_page_border(p_border); _vt.surface_vt_page_border = _vt.surface_svt_page_border = _vt.vt_page_border; return; }
	_vt.surface_svt_page_border = CLAMP(p_border, 0, 64);
	if (_vt.surface_svt) {
		_vt.surface_svt->set_page_border(_vt.surface_svt_page_border);
		_vt.surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_page_count(const int p_count) {
	if (!_vt.vt_debug_direct_material) { set_vt_page_count(p_count); _vt.surface_vt_page_count = _vt.surface_svt_page_count = _vt.vt_page_count; return; }
	_vt.surface_svt_page_count = CLAMP(p_count, 1, 1024);
	if (_vt.surface_svt) {
		_vt.surface_svt->set_page_count(_vt.surface_svt_page_count);
		_vt.surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_max_mip(const int p_mip) {
	_vt.surface_svt_max_mip = p_mip;
	if (!_vt.vt_debug_direct_material) {
		if (_vt.surface_svt) { _vt.surface_svt->set_world_max_mip(p_mip); }
		_reset_vt_configuration();
		return;
	}
	if (_vt.surface_svt) {
		_vt.surface_svt->set_world_max_mip(p_mip);
		_vt.surface_svt->initialize();
	}
}

void Terrain3D::set_surface_svt_distance(const real_t p_distance) {
	_vt.surface_svt_distance = MAX(0.f, p_distance);
}

void Terrain3D::set_surface_svt_root_mips(const int p_mips) {
	int mips = CLAMP(p_mips, 0, 16);
	if (_vt.surface_svt_root_mips == mips) { return; }
	_vt.surface_svt_root_mips = mips;
	if (!_vt.vt_debug_direct_material) { _reset_vt_configuration(); }
}

// Explicit far-field level bands. Entry m is the largest camera distance (metres) at
// which world mip m is sampled; the last entry is the furthest distance the far field
// keeps detail for, and everything beyond it uses that last level (the protected roots
// still serve as the coarser fallback). No entry is ever required: an empty table keeps
// the automatic page-size rule, so this is purely additive.
void Terrain3D::set_surface_svt_mip_distances(const PackedFloat32Array &p_distances) {
	PackedFloat32Array distances;
	distances.resize(p_distances.size());
	for (int i = 0; i < int(p_distances.size()); i++) {
		// Strictly increasing with at least a metre per band. A table that is not
		// monotonic has no meaning (level m would never be selected), and a zero-width
		// band would make the level ambiguous.
		const real_t previous = i > 0 ? distances[i - 1] : 0.f;
		distances[i] = MAX(real_t(p_distances[i]), previous + 1.f);
	}
	if (_vt.surface_svt_mip_distances == distances) { return; }
	_vt.surface_svt_mip_distances = distances;
	// Pages are world aligned, so a page produced for a level stays valid whatever the
	// table says; only the level the shader samples changes. That is a uniform update,
	// not a rebake, so editing the table never throws away produced pages.
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::UNIFORMS_ONLY);
	}
}

void Terrain3D::set_surface_array_enabled(const bool p_enabled) {
	_vt.surface_array_enabled = p_enabled;
	LOG(INFO, "Surface region texture array ", p_enabled ? "enabled" : "disabled");
	if (!p_enabled && !_vt.surface_vt_enabled && !_vt.surface_svt_enabled) {
		LOG(WARN, "Both surface virtual textures are off, so the region texture array keeps "
				  "carrying the surface channel until one of them is enabled.");
	}
	if (_data) {
		// Re-upload (or blank) every surface layer so the change takes effect now.
		_data->update_maps(TYPE_MAX, true, false);
	}
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

// Both virtual textures cache a region's surface, so an edit has to drop the pages that
// carry it. Without this, an array-free configuration would keep rendering the material
// the page was produced with until the LRU happened to evict it.
void Terrain3D::invalidate_surface_pages(const Vector2i &p_region_loc, bool p_force) {
	if (!p_force && is_vt_editor_preview_active()) {
		_vt.vt_editor_dirty_regions[p_region_loc] = true;
		_vt.vt_svt_dirty_regions[p_region_loc] = true;
		return;
	}
	_invalidate_vt_region(p_region_loc);
	const real_t vertex_spacing = MAX(0.0001f, _vertex_spacing);
	const real_t region_world = real_t(_region_size) * vertex_spacing;
	// Near field: the sector is the region, so every page of every level is stale.
	if (!is_sector_avt() && _vt.surface_vt && _vt.surface_vt->is_initialized() && _vt.surface_vt->has_sector(p_region_loc)) {
		const int block = _vt.surface_vt->get_sector_block_size(p_region_loc);
		const int max_mip = block > 0 ? TerrainVT::log2_power_of_two(block) : 0;
		for (int mip = 0; mip <= max_mip; mip++) {
			const int pages = MAX(1, block >> mip);
			for (int py = 0; py < pages; py++) {
				for (int px = 0; px < pages; px++) {
					_vt.surface_vt->release_page(p_region_loc, mip, px, py);
				}
			}
		}
	}
	// Far field: every page of every level that overlaps the region, plus one page of
	// margin because a page's border texels are filled from its neighbours.
	if (_vt.surface_svt && _vt.surface_svt->is_initialized()) {
		const real_t page_world = MAX(0.001f, _vt.surface_svt_page_world);
		const real_t x0 = real_t(p_region_loc.x) * region_world;
		const real_t z0 = real_t(p_region_loc.y) * region_world;
		const int max_mip = _vt.surface_svt->get_world_max_mip();
		for (int mip = 0; mip <= max_mip; mip++) {
			const real_t mip_world = page_world * real_t(1 << mip);
			const int px0 = int(Math::floor(x0 / mip_world)) - 1;
			const int px1 = int(Math::floor((x0 + region_world) / mip_world)) + 1;
			const int pz0 = int(Math::floor(z0 / mip_world)) - 1;
			const int pz1 = int(Math::floor((z0 + region_world) / mip_world)) + 1;
			for (int pz = pz0; pz <= pz1; pz++) {
				for (int px = px0; px <= px1; px++) {
					// release_world_page takes a mip 0 page coordinate, so shift the
					// level's page back up; any mip 0 page inside it maps to the same
					// indirection texel.
					_vt.surface_svt->release_world_page(px << mip, pz << mip, mip);
				}
			}
		}
	}
}

// The far field's one distance -> level rule. Every consumer resolves a level through
// this function: the demand pass (which level to produce), the legacy grid scan and the
// shader uniform (which level to sample). An explicit table states the bands directly;
// without one, a mip m page covers `page_world * 2^m` metres, so level m is the right
// choice out to twice that distance and the bands follow the page size automatically.
// `p_max_mip` -1 means the level the far field currently publishes; the demand pass
// passes the indirection's absolute limit while it plans a frame, so a plan never depends
// on the level cap it is about to change.
int Terrain3D::get_surface_svt_mip_for_distance(const real_t p_distance, const int p_max_mip) const {
	const int max_mip = p_max_mip >= 0
			? p_max_mip
			: (_vt.surface_svt ? MAX(0, _vt.surface_svt->get_world_max_mip()) : MAX(0, _vt.surface_svt_max_mip));
	if (_vt.surface_svt_mip_distances.is_empty()) {
		int mip = 0;
		real_t threshold = MAX(1.f, _vt.surface_svt_page_world * 2.f);
		while (mip < max_mip && p_distance > threshold) {
			threshold *= 2.f;
			mip++;
		}
		return mip;
	}
	const int last = int(_vt.surface_svt_mip_distances.size()) - 1;
	int mip = 0;
	while (mip < last && p_distance > _vt.surface_svt_mip_distances[mip]) {
		mip++;
	}
	return MIN(mip, max_mip);
}

// Furthest distance an explicit table still serves with a produced page; 0 means the
// automatic rule, which coarsens without a limit of its own.
real_t Terrain3D::get_surface_svt_mip_reach() const {
	if (_vt.surface_svt_mip_distances.is_empty()) {
		return 0.f;
	}
	const int max_mip = _vt.surface_svt ? MAX(0, _vt.surface_svt->get_world_max_mip()) : MAX(0, _vt.surface_svt_max_mip);
	return _vt.surface_svt_mip_distances[MIN(int(_vt.surface_svt_mip_distances.size()) - 1, max_mip)];
}

// A page the raw-ID diagnostic mode allocates carries the packed id/weight payload the
// shader reads, cropped from the resident region maps at the page's own world rect. The
// crop is world aligned, so a page that spans several regions (or covers none) resolves
// every texel through its owning region, and the border ring reads the neighbours.
bool Terrain3D::_write_diagnostic_sparse_page(int p_slot, int p_page_x, int p_page_y, int p_local_mip,
		real_t p_page_world) {
	if (!_vt.vt_debug_direct_material || !_data || !_vt.surface_svt || p_slot < 0) {
		return false;
	}
	Ref<Image> page = _data->make_sparse_surface_page(p_page_x, p_page_y, p_local_mip, p_page_world,
			_vt.surface_svt->get_page_size(), _vt.surface_svt->get_page_border());
	return page.is_valid() && _vt.surface_svt->write_page(p_slot, page);
}

// One far-field demand pass. Pages are world aligned, so the set is a plain grid walk
// around the clipmap target; the mip comes from the page's distance, and only the pages
// this pass actually allocated are produced.
int Terrain3D::update_surface_svt(int p_max_pages) {
	// The workers this pass submits to are woken when it is over, not in the middle of it: see
	// Terrain3DPagePipeline::flush_wakes(). The guard covers every return below.
	struct FlushWakes { Terrain3D *terrain; ~FlushWakes() { terrain->_flush_source_wakes_unless_ticking(); } } flush_wakes{ this };
	if (is_vt_editor_preview_active()) { return 0; }
	if (!_vt.vt_shared_ready || _vt.vt_materials_dirty) { _update_vt_service(); }
	_ensure_vt_views_ready();
	if (!_vt.surface_svt || !_data) {
		return 0;
	}
	if (!_vt.surface_svt->is_initialized()) {
		_vt.surface_svt->initialize();
		if (!_vt.surface_svt->is_initialized()) {
			return 0;
		}
	}
	_vt.surface_svt->set_allocation_budget(p_max_pages > 0 ? p_max_pages : -1);
	if (!_vt.vt_debug_direct_material) {
		const uint64_t svt_started = Time::get_singleton()->get_ticks_usec();
		const int produced = _update_visible_svt(p_max_pages);
		_vt.svt_cpu_ms = double(Time::get_singleton()->get_ticks_usec() - svt_started) / 1000.0;
		return produced;
	}
	const real_t page_world = MAX(0.001f, _vt.surface_svt_page_world);
	const real_t reach = MAX(page_world, _vt.surface_svt_distance);
	const Vector3 target = get_clipmap_target_position();
	// The level rule measures from the camera the shader renders with, so the diagnostic
	// scan has to measure from the same point: otherwise it publishes pages at levels the
	// shader does not start at, and the far field renders from whatever ancestor the walk
	// finds instead of from the page that was produced. Without a camera (CPU
	// diagnostics) the clipmap target stays the reference.
	Camera3D *reference_camera = get_camera();
	const Vector3 reference = (reference_camera && reference_camera->is_inside_tree())
			? reference_camera->get_global_position()
			: target;
	// Keep the public world-page API's int coordinates in a range where adding the
	// indirection half and multiplying by a mip scale cannot overflow. The old nested
	// loops converted an arbitrary distance directly to int, so a large editor distance
	// could wrap before the allocator had a chance to enforce its page budget.
	const int64_t coordinate_limit = int64_t(INT32_MAX) / 2;
	auto clamp_page_coordinate = [coordinate_limit](const double p_value) -> int64_t {
		if (p_value <= -double(coordinate_limit)) {
			return -coordinate_limit;
		}
		if (p_value >= double(coordinate_limit)) {
			return coordinate_limit;
		}
		return int64_t(p_value);
	};

	int64_t first_x = clamp_page_coordinate(Math::floor((double(reference.x) - double(reach)) / double(page_world)));
	int64_t last_x = clamp_page_coordinate(Math::floor((double(reference.x) + double(reach)) / double(page_world)));
	int64_t first_y = clamp_page_coordinate(Math::floor((double(reference.z) - double(reach)) / double(page_world)));
	int64_t last_y = clamp_page_coordinate(Math::floor((double(reference.z) + double(reach)) / double(page_world)));


	// A target/configuration key invalidates both cursors. Include the effective detail
	// bounds and loaded-region count so adding/removing streamed regions starts a fresh
	// pass without storing another lifetime-sensitive observer in Terrain3D.
	auto mix_hash = [](const uint32_t p_hash, const uint32_t p_value) -> uint32_t {
		return p_hash ^ (p_value + 0x9e3779b9u + (p_hash << 6) + (p_hash >> 2));
	};
	auto mix_i64 = [&mix_hash](uint32_t p_hash, const int64_t p_value) -> uint32_t {
		const uint64_t bits = uint64_t(p_value);
		p_hash = mix_hash(p_hash, uint32_t(bits));
		return mix_hash(p_hash, uint32_t(bits >> 32));
	};
	uint32_t scan_hash = 2166136261u;
	scan_hash = mix_i64(scan_hash, _vt.surface_svt->get_indirection_size());
	scan_hash = mix_i64(scan_hash, _vt.surface_svt->get_world_max_mip());
	scan_hash = mix_i64(scan_hash, _vt.surface_svt_root_mips);
	scan_hash = mix_i64(scan_hash, _vt.surface_svt->get_page_count());
	scan_hash = mix_i64(scan_hash, int64_t(Math::floor(double(page_world))));
	scan_hash = mix_i64(scan_hash, int64_t(Math::floor(double(reach))));
	scan_hash = mix_i64(scan_hash, _data->get_region_locations().size());
	scan_hash = mix_i64(scan_hash, first_x);
	scan_hash = mix_i64(scan_hash, last_x);
	scan_hash = mix_i64(scan_hash, first_y);
	scan_hash = mix_i64(scan_hash, last_y);
	scan_hash = mix_i64(scan_hash, 1);
	const Vector3i scan_key(int(clamp_page_coordinate(Math::floor(double(target.x) / double(page_world)))),
			int(clamp_page_coordinate(Math::floor(double(target.z) / double(page_world)))),
			int(scan_hash & 0x7fffffffu));
	if (_vt.surface_svt_scan_key != scan_key) {
		_vt.surface_svt_scan_key = scan_key;
		_vt.surface_svt_root_cursor = 0;
		_vt.surface_svt_detail_cursor = 0;
	}

	int produced = 0;
	int allocations = 0;
	const int physical_page_count = MAX(1, _vt.surface_svt->get_page_count());
	const Dictionary residency = _vt.surface_svt->get_stats();
	int protected_count = MAX(0, int(residency.get("protected_count", 0)));
	const int protected_limit = physical_page_count / 2;
	int root_protection_budget = MAX(0, protected_limit - protected_count);

	const int root_max_mip = MAX(0, _vt.surface_svt->get_world_max_mip());
	const int root_mip_count = CLAMP(_vt.surface_svt_root_mips, 0, root_max_mip + 1);
	const int first_root = root_mip_count > 0 ? root_max_mip - root_mip_count + 1 : root_max_mip + 1;
	int64_t root_total = 0;
	for (int mip = root_max_mip; mip >= first_root; mip--) {
		const int64_t level_size = MAX(1, _vt.surface_svt->get_indirection_size() >> mip);
		root_total += level_size * level_size;
	}

	// A finite CPU budget is separate from the allocation budget. It bounds an extreme
	// root_mips=16/full-grid or distance=huge frame even when most candidates are hits.
	const int scan_budget = MAX(256, MIN(4096, physical_page_count * 4));

	// A completed cursor is normally left at the end while the pool is full. If an
	// invalidation removes a protected root, the reduced protected count opens budget
	// again; restart then so the missing root can be found without scanning every frame
	// while the cache is settled. Small legacy root sets retain their historical repeat
	// walk, which also lets an invalidated page be repaired on the next update.
	if (root_total > 0 && _vt.surface_svt_root_cursor >= root_total && root_protection_budget > 0) {
		_vt.surface_svt_root_cursor = 0;
	}

	int root_scanned = 0;
	while (_vt.surface_svt_root_cursor < root_total && root_scanned < scan_budget &&
			root_protection_budget > 0 && (p_max_pages <= 0 || allocations < p_max_pages)) {
		const int64_t root_index = _vt.surface_svt_root_cursor++;
		root_scanned++;
		int mip = first_root;
		int virtual_x = 0;
		int virtual_y = 0;
		int64_t level_index = root_index;
		for (mip = root_max_mip; mip >= first_root; mip--) {
			const int level_size = MAX(1, _vt.surface_svt->get_indirection_size() >> mip);
			const int64_t level_cells = int64_t(level_size) * level_size;
			if (level_index < level_cells) {
				virtual_x = int(level_index % level_size);
				virtual_y = int(level_index / level_size);
				break;
			}
			level_index -= level_cells;
		}
		const int level_size = MAX(1, _vt.surface_svt->get_indirection_size() >> mip);
		if (virtual_x < 0 || virtual_y < 0 || virtual_x >= level_size || virtual_y >= level_size) {
			continue;
		}
		bool was_miss = false;
		const int slot = _vt.surface_svt->request_virtual_page_internal(virtual_x, virtual_y, mip, &was_miss);
		if (slot < 0) {
			// A full protected pool cannot make progress in this pass. Leave the cursor
			// at the next candidate so a later unprotection can retry without rescanning
			// the whole level.
			break;
		}
		if (!was_miss) {
			if (!_vt.surface_svt->is_page_protected(slot) && root_protection_budget > 0) {
				_vt.surface_svt->protect_page(slot, true);
				protected_count++;
				root_protection_budget--;
			}
			continue;
		}
		allocations++;
		// A newly acquired physical slot may have an output from an evicted AVT/SVT
		// page. Invalidate that material result before the new page can be sampled.
		_invalidate_vt_slot(slot);
		const int half_at_mip = (_vt.surface_svt->get_indirection_size() >> 1) >> mip;
		const Vector2i address((virtual_x - half_at_mip) << mip, (virtual_y - half_at_mip) << mip);
		Ref<Image> page;
		const float span = page_world * float(1 << mip);
		if (_vt.vt_debug_direct_material &&
				!_write_diagnostic_sparse_page(slot, address.x, address.y, mip, page_world)) {
			// The diagnostic mode has no material pipeline to fall back on, so a page
			// without content must not be published and pinned as if it were a root.
			_vt.surface_svt->release_world_page(address.x, address.y, mip);
			continue;
		}
		_queue_vt_material_page(slot, page, Rect2(Vector2(address) * page_world, Vector2(span, span)), true, mip, address);
		// A root page is the fallback of last resort. Protecting it leaves at least
		// half of the shared pool available to AVT, detail SVT, and offline baking.
		_vt.surface_svt->protect_page(slot, true);
		protected_count++;
		root_protection_budget--;
		produced++;
	}
	if (root_protection_budget <= 0) {
		// No further root can be made resident under the shared-pool cap. Avoid
		// repeatedly walking a potentially million-cell full-grid root on every tick.
		_vt.surface_svt_root_cursor = root_total;
	}

	int64_t detail_width = 0;
	int64_t detail_height = 0;
	int64_t detail_total = 0;
	if (first_x <= last_x && first_y <= last_y) {
		detail_width = last_x - first_x + 1;
		detail_height = last_y - first_y + 1;
		if (detail_width > 0 && detail_height > 0 && detail_width <= INT64_MAX / detail_height) {
			detail_total = detail_width * detail_height;
		}
	}
	int detail_scanned = 0;
	while (_vt.surface_svt_detail_cursor < detail_total && detail_scanned < scan_budget &&
			(p_max_pages <= 0 || allocations < p_max_pages)) {
		const int64_t detail_index = _vt.surface_svt_detail_cursor++;
		detail_scanned++;
		const int64_t page_x64 = first_x + detail_index % detail_width;
		const int64_t page_y64 = first_y + detail_index / detail_width;
		if (page_x64 < -coordinate_limit || page_x64 > coordinate_limit ||
				page_y64 < -coordinate_limit || page_y64 > coordinate_limit) {
			continue;
		}
		const int page_x = int(page_x64);
		const int page_y = int(page_y64);
		const real_t center_x = (real_t(page_x) + 0.5f) * page_world;
		const real_t center_z = (real_t(page_y) + 0.5f) * page_world;
		// Same measurement the shader makes for a fragment: the distance from the camera
		// to the page, with the page sampled on the ground plane.
		const real_t distance = Vector3(center_x, 0.f, center_z).distance_to(reference);
		if (distance > reach) {
			continue;
		}
		// Same distance -> level table the shader and the camera-visible pass use. This
		// diagnostic grid measures from the clipmap target rather than the camera, so
		// it stays usable without a rendering camera; production goes through
		// _update_visible_svt(), which measures from the camera the shader reports.
		const int mip = get_surface_svt_mip_for_distance(distance);
		bool was_miss = false;
		const int slot = _vt.surface_svt->request_world_page_internal(page_x, page_y, mip, &was_miss);
		if (slot < 0) {
			break;
		}
		if (!was_miss) {
			continue;
		}
		allocations++;
		_invalidate_vt_slot(slot);
		Ref<Image> page;

		const float span = page_world * float(1 << mip);
		const Vector2i address((page_x >> mip) << mip, (page_y >> mip) << mip);
		if (_vt.vt_debug_direct_material &&
				!_write_diagnostic_sparse_page(slot, page_x, page_y, mip, page_world)) {
			// Nothing else can fill this slot in the diagnostic mode, so drop it again
			// instead of serving an unwritten layer until the next LRU pass recycles it.
			_vt.surface_svt->release_world_page(page_x, page_y, mip);
			continue;
		}
		_queue_vt_material_page(slot, page, Rect2(Vector2(address) * page_world, Vector2(span, span)), true, mip, address);
		produced++;
	}
	if (detail_total > 0 && _vt.surface_svt_detail_cursor >= detail_total) {
		_vt.surface_svt_detail_cursor = 0;
	}

	_vt.surface_svt->commit();
	// Both views may share the physical pool. An SVT allocation can evict an AVT
	// owner and dirty its indirection, so publish both tables before the next draw.
	if (_vt.surface_vt && _vt.surface_vt->is_initialized()) {
		_vt.surface_vt->commit();
	}
	_vt.surface_svt->set_allocation_budget(-1);
	return produced;
}

void Terrain3D::set_surface_vt_enabled(const bool p_enabled) {
	_vt.surface_vt_enabled = p_enabled;
	if (p_enabled && _initialized) { set_physics_process(true); }
	LOG(INFO, "Surface virtual texture ", p_enabled ? "enabled" : "disabled");
	if (_initialized && _material.is_valid()) {
		// The shader's `_vt.surface_vt_enabled` uniform and its block table have to follow
		// the toggle, otherwise the material keeps sampling the atlas after it is off.
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

void Terrain3D::set_surface_vt_page_count(const int p_count) {
	if (!_vt.vt_debug_direct_material) { set_vt_page_count(p_count); _vt.surface_vt_page_count = _vt.surface_svt_page_count = _vt.vt_page_count; return; }
	_vt.surface_vt_page_count = CLAMP(p_count, 1, 1024);
	if (_vt.surface_vt) {
		_vt.surface_vt->set_page_count(_vt.surface_vt_page_count);
		_vt.surface_vt->initialize();
	}
}

void Terrain3D::set_surface_vt_page_size(const int p_size) {
	if (!_vt.vt_debug_direct_material) { set_vt_page_size(p_size); _vt.surface_vt_page_size = _vt.surface_svt_page_size = _vt.vt_page_size; return; }
	_vt.surface_vt_page_size = CLAMP(p_size, 1, 4096);
	if (_vt.surface_vt) {
		_vt.surface_vt->set_page_size(_vt.surface_vt_page_size);
		_vt.surface_vt->initialize();
	}
}

void Terrain3D::set_surface_vt_page_border(const int p_border) {
	if (!_vt.vt_debug_direct_material) { set_vt_page_border(p_border); _vt.surface_vt_page_border = _vt.surface_svt_page_border = _vt.vt_page_border; return; }
	_vt.surface_vt_page_border = CLAMP(p_border, 0, 64);
	if (_vt.surface_vt) {
		_vt.surface_vt->set_page_border(_vt.surface_vt_page_border);
		_vt.surface_vt->initialize();
	}
}

void Terrain3D::set_surface_vt_pages_per_axis(const int p_pages) {
	// Power of two: the page grid halves per mip.
	int pages = 1;
	while (pages * 2 <= CLAMP(p_pages, 1, 64)) {
		pages *= 2;
	}
	_vt.surface_vt_pages_per_axis = pages;
}

void Terrain3D::set_surface_vt_distance(const real_t p_distance) {
	_vt.surface_vt_distance = MAX(0.f, p_distance);
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
}

static bool terrain_region_in_frustum(Terrain3DData *p_data, const Vector2i &p_location,
		float p_region_world, const TypedArray<Plane> &p_planes) {
	Ref<Terrain3DRegion> region = p_data->get_region(p_location);
	if (region.is_null() || region->is_deleted()) { return false; }
	const Vector2 heights = region->get_height_range();
	const Vector3 lo(p_location.x * p_region_world, heights.x - 1.f, p_location.y * p_region_world);
	const Vector3 hi(lo.x + p_region_world, heights.y + 1.f, lo.z + p_region_world);
	for (int i = 0; i < p_planes.size(); ++i) {
		const Plane plane = p_planes[i];
		const Vector3 closest(plane.normal.x > 0.f ? lo.x : hi.x,
				plane.normal.y > 0.f ? lo.y : hi.y, plane.normal.z > 0.f ? lo.z : hi.z);
		if (plane.is_point_over(closest)) { return false; }
	}
	return true;
}

Rect2i Terrain3D::get_surface_vt_region_rect() const {
	// Inspector property reads can occur while the edited scene is being removed.
	if (!is_inside_tree() || !_is_inside_world) { return Rect2i(); }
	const float region_world = MAX(0.0001f, float(_region_size) * _vertex_spacing);
	Vector3 target = get_clipmap_target_position();
	Node3D *anchor = _clipmap_target.is_valid() ? cast_to<Node3D>(_clipmap_target.ptr()) : get_camera();
	Camera3D *camera = get_camera();
	if (_vt.surface_vt_selection_mode == 0 && camera && _data) {
		const TypedArray<Plane> planes = camera->get_frustum();
		const TerrainVT::VisibleView view(camera);
		float best_score = 1e30f;
		float previous_score = 1e30f;
		Vector2i best;
		for (const Vector2i &location : _data->get_region_locations()) {
			if (!terrain_region_in_frustum(_data, location, region_world, planes)) { continue; }
			TerrainVT::VisiblePatch visible;
			if (!view.sample(Rect2(Vector2(location) * region_world, Vector2(region_world, region_world)),
					_data->get_region(location)->get_height_range(), visible)) { continue; }
			const float score = visible.distance;
			if (score < best_score) { best_score = score; best = location; }
			if (_vt.vt_view_focus_valid && location == _vt.vt_view_focus) { previous_score = score; }
		}
		if (best_score == 1e30f) { _vt.vt_view_focus_valid = false; return Rect2i(); }
		// Small distance hysteresis stabilizes adjoining visible region edges.
		if (_vt.vt_view_focus_valid && previous_score <= best_score * 1.03f + 0.01f) { best = _vt.vt_view_focus; }
		_vt.vt_view_focus = best;
		_vt.vt_view_focus_valid = true;
		target.x = (best.x + 0.5f) * region_world;
		target.z = (best.y + 0.5f) * region_world;
		anchor = camera;
	}
	if (anchor && !Math::is_zero_approx(_vt.surface_vt_forward_regions)) {
		Vector3 forward = -anchor->get_global_basis().get_column(2);
		forward.y = 0.f;
		if (forward.length_squared() > 0.0001f) { target += forward.normalized() * (_vt.surface_vt_forward_regions * region_world); }
	}
	const Vector2i center(int(Math::floor(target.x / region_world)), int(Math::floor(target.z / region_world)));
	return Rect2i(center + _vt.surface_vt_region_offset - _vt.surface_vt_region_grid / 2, _vt.surface_vt_region_grid);
}

void Terrain3D::set_surface_vt_force_mip(const bool p_enabled, const int p_mip) {
	_vt.surface_vt_force_mip = p_enabled;
	_vt.surface_vt_mip = CLAMP(p_mip, 0, 16);
}

void Terrain3D::set_surface_vt_feedback_enabled(const bool p_enabled) {
	_vt.surface_vt_feedback_enabled = p_enabled;
	// Feedback is optional legacy/debug mip refinement. Toggling it must not leave a stale
	// result, nor be required to wake the CPU visibility demand that owns normal AVT/SVT.
	_vt.surface_vt_feedback_tick = 0;
	if (!p_enabled && _vt.surface_vt_feedback) {
		memdelete_safely(_vt.surface_vt_feedback);
	}
	if (_initialized && (_vt.surface_vt_enabled || _vt.surface_svt_enabled)) {
		set_physics_process(true);
	}
	LOG(INFO, "Surface virtual texture GPU feedback ", p_enabled ? "enabled" : "disabled");
}

void Terrain3D::set_surface_vt_feedback_interval(const int p_updates) {
	_vt.surface_vt_feedback_interval = CLAMP(p_updates, 1, 120);
}

void Terrain3D::set_surface_vt_feedback_grid_chunks(const int p_chunks) {
	_vt.surface_vt_feedback_grid_chunks = CLAMP(p_chunks, 1, 64);
	if (_vt.surface_vt_feedback) {
		// The grid size is baked into the texture and the pipeline.
		memdelete_safely(_vt.surface_vt_feedback);
	}
}

void Terrain3D::set_surface_vt_feedback_min_extent(const real_t p_extent) {
	_vt.surface_vt_feedback_min_extent = CLAMP(p_extent, 0.f, 1024.f);
}

// Runs the demand pass and makes its result available. The readback of a local device is
// delivered by sync(), so this is a stall; the interval exists to amortise it, and the
// demand pass keeps using the last result in between.
bool Terrain3D::_update_surface_vt_feedback(const Vector3 &p_target) {
	if (!_vt.surface_vt_feedback_enabled) {
		return false;
	}
	Camera3D *camera = get_camera();
	if (!camera) {
		return false;
	}
	if (_vt.surface_vt_feedback_tick++ % _vt.surface_vt_feedback_interval != 0) {
		return _vt.surface_vt_feedback != nullptr && _vt.surface_vt_feedback->has_result();
	}
	const int pages_per_axis = _vt.surface_vt_pages_per_axis;
	const int grid = _vt.surface_vt_feedback_grid_chunks * pages_per_axis;
	if (!_vt.surface_vt_feedback) {
		_vt.surface_vt_feedback = memnew(Terrain3DVTFeedback);
		if (_vt.surface_vt_feedback->initialize(grid, grid) != OK) {
			memdelete_safely(_vt.surface_vt_feedback);
			_vt.surface_vt_feedback_enabled = false;
			return false;
		}
	} else if (_vt.surface_vt_feedback->get_grid_width() != grid) {
		_vt.surface_vt_feedback->initialize(grid, grid);
	}
	if (!_vt.surface_vt_feedback->is_initialized()) {
		return false;
	}

	// The grid is a window of chunks centred on the camera's chunk.
	const Vector2i camera_chunk = _data->get_region_location(p_target);
	_vt.surface_vt_feedback_origin = camera_chunk - Vector2i(_vt.surface_vt_feedback_grid_chunks / 2,
													_vt.surface_vt_feedback_grid_chunks / 2);
	const Projection view_projection = camera->get_camera_projection() *
			Projection(camera->get_global_transform().affine_inverse());
	const real_t page_world_size = real_t(_region_size) * _vertex_spacing / real_t(pages_per_axis);
	Viewport *viewport = camera->get_viewport();
	const Vector2i viewport_size = viewport ? viewport->get_visible_rect().size : Vector2i(1920, 1080);

	if (_vt.surface_vt_feedback->dispatch(view_projection, pages_per_axis, real_t(_region_size),
				page_world_size, _vt.surface_vt->get_page_size(),
				TerrainVT::log2_power_of_two(pages_per_axis), _vt.surface_vt_feedback_origin,
				viewport_size, _vt.surface_vt_feedback_min_extent) != OK) {
		return false;
	}
	_vt.surface_vt_feedback->request_readback();
	// dispatch + request + sync is the only order that works: the copy is a draw graph
	// node, so the submit has to come after the request.
	_vt.surface_vt_feedback->sync();
	return _vt.surface_vt_feedback->has_result();
}

int Terrain3D::_surface_vt_mip_for_page(const Vector2i &p_region_loc, const int p_page_x0,
		const int p_page_y0, const real_t p_distance, const real_t p_page_world_size,
		const int p_max_local_mip) {
	if (_vt.surface_vt_force_mip) {
		return MIN(_vt.surface_vt_mip, p_max_local_mip);
	}
	if (!_vt.vt_debug_direct_material) { return 0; }
	if (_vt.surface_vt_feedback_enabled && _vt.surface_vt_feedback &&
			_vt.surface_vt_feedback->has_result()) {
		const int mip = _vt.surface_vt_feedback->get_mip_for_page(p_region_loc, _vt.surface_vt_pages_per_axis,
				p_page_x0, p_page_y0, _vt.surface_vt_feedback_origin);
		// -1 means the pass culled this page: off screen, behind the camera or too
		// small to be worth a page. That is the point of using it over the distance
		// rule, so it is honoured rather than treated as a failure.
		return mip;
	}
	// Distance fallback. A mip 0 page covers region_size / pages_per_axis metres, and
	// each doubling of that threshold steps one mip.
	int mip = 0;
	const real_t threshold = MAX(1.f, p_page_world_size * 2.f);
	while (mip < p_max_local_mip && p_distance > threshold * real_t(1 << mip)) {
		mip++;
	}
	return mip;
}

// Both views are bound to the material by RID, so a view that was cleared by hand (the
// public clear() is bound) leaves the service claiming to be configured while the view has
// no page table, no allocator and no published texture. The near-field sector planner
// cannot work without them: it retries a failed sector registration for every visible
// sector on every tick, which costs hundreds of milliseconds per frame. Rebuild the shared
// service instead, which re-initializes both views and republishes the material.
void Terrain3D::_ensure_vt_views_ready() {
	if (!_vt.vt_shared_ready || _vt.vt_debug_direct_material) {
		return;
	}
	if ((_vt.surface_vt && !_vt.surface_vt->is_initialized()) ||
			(_vt.surface_svt && !_vt.surface_svt->is_initialized())) {
		_reset_vt_configuration();
		_update_vt_service();
	}
}

// One demand pass. The page contract is the same whichever rule picks the mips:
// The near-field AVT is the one VT path that owns its own planner; the far-field
// update is a straight sequence: request -> produce -> write -> commit.
int Terrain3D::update_surface_vt(int p_max_pages) {
	// As above: the source workers are woken once this pass is over.
	struct FlushWakes { Terrain3D *terrain; ~FlushWakes() { terrain->_flush_source_wakes_unless_ticking(); } } flush_wakes{ this };
	const uint64_t entered = Time::get_singleton()->get_ticks_usec();
	if (is_vt_editor_preview_active()) { return 0; }
	// Explicit sector updates must also bind textures first created by the
	// preceding render-thread bake, even when normal physics updates are paused.
	if (is_sector_avt() || !_vt.vt_shared_ready || _vt.vt_materials_dirty) { _update_vt_service(); }
	_ensure_vt_views_ready();
	if (is_sector_avt()) {
		// What this wrapper costs around the sector planner, which reports its own total as
		// `cpu_update_ms`. The difference between the phase a profiler shows and that figure had no
		// attribution at all.
		_vt.avt_sector_stats["wrapper_ms"] = double(Time::get_singleton()->get_ticks_usec() - entered) / 1000.0;
		return _update_sector_avt(p_max_pages);
	}
	if (!_vt.surface_vt || !_data) {
		return 0;
	}
	if (!_vt.surface_vt->is_initialized()) {
		_vt.surface_vt->initialize();
		if (!_vt.surface_vt->is_initialized()) {
			return 0;
		}
	}
	const int max_pages_per_axis = _vt.surface_vt_pages_per_axis;
	_vt.surface_vt->set_allocation_budget(p_max_pages > 0 ? p_max_pages : -1);
	PackedVector2Array next_blocks;
	PackedFloat32Array next_sizes;
	_prepare_vt_block_tables(next_blocks, next_sizes);
	const Vector3 target = get_clipmap_target_position();
	if (_vt.vt_debug_direct_material) { _update_surface_vt_feedback(target); }
	const real_t reach_squared = _vt.surface_vt_distance * _vt.surface_vt_distance;
	int produced = 0;
	const Dictionary eligible_regions = _collect_eligible_vt_regions();
	const Dictionary adaptive_sizes = _compute_adaptive_sector_sizes(eligible_regions, max_pages_per_axis);
	_retire_stale_vt_sectors(eligible_regions);

	for (const Vector2i &region_loc : _data->get_region_locations()) {
		const Vector3 center((real_t(region_loc.x) + 0.5f) * _region_size * _vertex_spacing, 0.f,
				(real_t(region_loc.y) + 0.5f) * _region_size * _vertex_spacing);
		const Vector2 flat(center.x - target.x, center.z - target.z);
		const real_t distance_squared = flat.length_squared();
		if (_vt.vt_debug_direct_material ? distance_squared > reach_squared : !eligible_regions.has(region_loc)) {
			continue;
		}
		int pages_per_axis = adaptive_sizes.get(region_loc, max_pages_per_axis);
		const float region_world = _region_size * _vertex_spacing;
		if (!_prepare_vt_sector(region_loc, pages_per_axis)) {
			continue;
		}
		pages_per_axis = _vt.surface_vt->get_sector_block_size(region_loc);
		const int max_local_mip = TerrainVT::log2_power_of_two(pages_per_axis);
		const real_t page_world_size = region_world / real_t(pages_per_axis);
		// Publish the block so the shader can resolve this chunk's pages.
		const int slot = _data->get_region_id(region_loc);
		if (slot >= 0 && slot < next_blocks.size()) {
			next_blocks[slot] = Vector2(real_t(_vt.surface_vt->get_sector_block_origin_x(region_loc)),
					real_t(_vt.surface_vt->get_sector_block_origin_y(region_loc)));
			next_sizes[slot] = float(pages_per_axis);
		}
		const real_t distance = Math::sqrt(distance_squared);
		const std::vector<Vector3i> requests = _vt_page_requests_for_sector(region_loc, pages_per_axis,
				distance, page_world_size, max_local_mip);
		// Only produce the pages this pass actually allocated. A hit already holds
		// content, and re-producing it every tick would swamp the atlas uploads.
		//
		// A hit is only a hit while the producer still has the page's content, though: an
		// encode that failed or a production dropped by a bundle rebuild leaves the table
		// naming a slot nothing ever filled, and treating that as resident kept sampling an
		// empty layer for the rest of the session. The retry only applies to a page the demand
		// path produced, which is what its demand record says: a page written straight into
		// the atlas - an explicit capture, or the direct-material diagnostic - is the caller's
		// content, and producing over it would erase what that caller just wrote.
		std::vector<Vector3i> missing;
		for (const Vector3i &request : requests) {
			bool was_miss = false;
			const int request_slot = _vt.surface_vt->request_page_internal(region_loc, request.z, request.x,
					request.y, &was_miss);
			if (request_slot < 0) {
				continue;
			}
			const bool tracked = _vt.vt_page_records.has(request_slot);
			if (was_miss || (tracked && _vt_page_production_stale(request_slot))) {
				_invalidate_vt_slot(request_slot);
				missing.push_back(request);
			}
		}
		if (missing.empty()) {
			continue;
		}
		produced += _produce_missing_vt_pages(region_loc, pages_per_axis, region_world, missing);
	}
	_publish_vt_block_tables(next_blocks, next_sizes);
	_vt.surface_vt->commit();
	if (_vt.surface_svt && _vt.surface_svt->is_initialized()) { _vt.surface_svt->commit(); }
	_vt.surface_vt->set_allocation_budget(-1);
	return produced;
}

// Rebuilds the layer -> block origin table the shader indexes. Sectors are never
// unregistered (the virtual atlas is large and the entries are only read for
// resident chunks), so this is a fresh map of the current resident set.
void Terrain3D::_prepare_vt_block_tables(PackedVector2Array &r_blocks, PackedFloat32Array &r_sizes) {
	const int capacity = _data->get_map_capacity();
	if (capacity > 0 && _vt.surface_vt_blocks.size() != capacity) {
		_vt.surface_vt_blocks.resize(capacity);
		_vt.surface_vt_blocks_dirty = true;
	}
	r_blocks.resize(_vt.surface_vt_blocks.size());
	r_blocks.fill(Vector2(-1.f, -1.f));
	r_sizes.resize(_vt.surface_vt_blocks.size());
	r_sizes.fill(1.f);
}

// Regions the far field may publish this pass: inside the explicit Target Grid and,
// in view-selection mode, inside the camera frustum.
Dictionary Terrain3D::_collect_eligible_vt_regions() {
	Dictionary eligible_regions;
	if (_vt.vt_debug_direct_material) {
		return eligible_regions;
	}
	Camera3D *camera = get_camera();
	const bool view_selection = _vt.surface_vt_selection_mode == 0 && camera;
	const TypedArray<Plane> planes = view_selection ? camera->get_frustum() : TypedArray<Plane>();
	const Rect2i avt_regions = get_surface_vt_region_rect();
	for (const Vector2i &location : _data->get_region_locations()) {
		if (avt_regions.has_point(location) && (!view_selection ||
				terrain_region_in_frustum(_data, location, _region_size * _vertex_spacing, planes))) {
			eligible_regions[location] = true;
		}
	}
	return eligible_regions;
}

// How many pages each eligible sector may use. Sectors the camera sees closely keep
// more of them; the whole mip hierarchy is reserved before detail is reduced, so a
// shrink never discards a sector.
Dictionary Terrain3D::_compute_adaptive_sector_sizes(const Dictionary &p_eligible, int p_max_pages_per_axis) {
	Dictionary adaptive_sizes;
	if (!_vt.vt_adaptive_enabled || _vt.vt_debug_direct_material || _vt.surface_vt_force_mip || !get_camera()) {
		return adaptive_sizes;
	}
	TerrainVT::VisibleView view(get_camera());
	struct SectorDemand { Vector2i location; int size; float distance; };
	std::vector<SectorDemand> demands;
	const float world = _region_size * _vertex_spacing;
	const int capacity = _vt.surface_svt_enabled ? MAX(1, _vt.surface_vt->get_page_count() / 2) : _vt.surface_vt->get_page_count();
	auto cost = [](int size) { return (4 * size * size - 1) / 3; };
	int total = 0;
	for (const Variant &key : p_eligible.keys()) {
		Vector2i location = key;
		TerrainVT::VisiblePatch visible;
		if (!view.sample(Rect2(Vector2(location) * world, Vector2(world, world)), _data->get_region(location)->get_height_range(), visible)) {
			// Explicit Target Grid can include off-screen sectors; retain a base page.
			visible.density = 0.f;
		}
		const float wanted = world * visible.density * _vt.surface_vt_texels_per_pixel / _vt.surface_vt->get_page_size();
		int size = 1;
		while (size < p_max_pages_per_axis && size < wanted) { size <<= 1; }
		// Separate grow/shrink thresholds avoid toggling at projection boundaries.
		if (_vt.surface_vt->has_sector(location)) {
			int previous = _vt.surface_vt->get_sector_block_size(location);
			if (wanted >= previous * 0.4f && wanted <= previous * 1.1f) { size = MIN(previous, p_max_pages_per_axis); }
		}
		demands.push_back({ location, size, visible.distance });
		total += cost(size);
	}
	// Reserve the complete mip hierarchy, including coverage while finer pages
	// are produced. Reduce the least visible detail first, never discard sectors.
	while (total > capacity) {
		int reduce = -1;
		for (int i = 0; i < int(demands.size()); ++i) {
			if (demands[i].size > 1 && (reduce < 0 || demands[i].distance > demands[reduce].distance)) { reduce = i; }
		}
		if (reduce < 0) { break; }
		total -= cost(demands[reduce].size);
		demands[reduce].size >>= 1;
		total += cost(demands[reduce].size);
	}
	for (const SectorDemand &demand : demands) { adaptive_sizes[demand.location] = demand.size; }
	return adaptive_sizes;
}

// Returns virtual address blocks when terrain streams out or leaves AVT coverage;
// otherwise a long traversal eventually exhausts the atlas.
void Terrain3D::_retire_stale_vt_sectors(const Dictionary &p_eligible) {
	if (_vt.vt_debug_direct_material) {
		return;
	}
	for (const Variant &key : _vt.vt_registered_sectors.keys()) {
		Vector2i location = key;
		if (_data->get_region_id(location) < 0 || !p_eligible.has(location)) {
			_vt.surface_vt->unregister_sector(location);
			_vt.vt_registered_sectors.erase(key);
		}
	}
}

// Gives this region a virtual block of the requested size. False means the block
// could not be allocated, so the region has to be skipped this pass.
bool Terrain3D::_prepare_vt_sector(const Vector2i &p_region_loc, int p_pages_per_axis) {
	if (!_vt.surface_vt->has_sector(p_region_loc)) {
		if (!_vt.surface_vt->register_sector(p_region_loc, p_pages_per_axis)) {
			return false;
		}
		_vt.surface_vt_blocks_dirty = true;
	} else if (_vt.surface_vt->get_sector_block_size(p_region_loc) != p_pages_per_axis) {
		_vt.surface_vt->resize_sector(p_region_loc, p_pages_per_axis);
		// Resizing keeps world footprints while changing their mip addresses.
		// Keep the inspector's records consistent with the remapped page table.
		for (const Variant &key : _vt.vt_page_records.keys()) {
			for (const Dictionary &owner : _vt.surface_vt->get_slot_owner_metadata(int(key))) {
				if (bool(owner["world_space"]) || Vector2i(owner["sector"]) != p_region_loc) { continue; }
				const int mip = owner["mip"];
				Dictionary record = _vt.vt_page_records[key];
				record["mip"] = mip;
				record["address"] = Vector2i(owner["virtual"]) - Vector2i(
						_vt.surface_vt->get_sector_block_origin_x(p_region_loc) >> mip,
						_vt.surface_vt->get_sector_block_origin_y(p_region_loc) >> mip);
			}
		}
	}
	if (!_vt.vt_debug_direct_material) { _vt.vt_registered_sectors[p_region_loc] = true; }
	return true;
}

// The pages this sector needs: per-page mips resolve the detail the feedback asks
// for at each distance, and the near field keeps its whole mip chain resident.
std::vector<Vector3i> Terrain3D::_vt_page_requests_for_sector(const Vector2i &p_region_loc, int p_pages_per_axis,
		real_t p_distance, real_t p_page_world_size, int p_max_local_mip) {
	// Per-page mips: the feedback varies within a sector, which is the whole point
	// of it over a per-sector distance rule. Resolve every mip 0 page first, then
	// collect the pages actually needed at each level.
	std::vector<int> mip0(size_t(p_pages_per_axis) * p_pages_per_axis, -1);
	for (int page_y0 = 0; page_y0 < p_pages_per_axis; page_y0++) {
		for (int page_x0 = 0; page_x0 < p_pages_per_axis; page_x0++) {
			mip0[size_t(page_y0) * p_pages_per_axis + page_x0] = _surface_vt_mip_for_page(
					p_region_loc, page_x0, page_y0, p_distance, p_page_world_size, p_max_local_mip);
		}
	}
	std::vector<Vector3i> requests;
	for (int mip = 0; mip <= p_max_local_mip; mip++) {
		const int at = MAX(1, p_pages_per_axis >> mip);
		std::vector<uint8_t> need(size_t(at) * at, 0);
		for (int page_y0 = 0; page_y0 < p_pages_per_axis; page_y0++) {
			for (int page_x0 = 0; page_x0 < p_pages_per_axis; page_x0++) {
				const int page_mip = mip0[size_t(page_y0) * p_pages_per_axis + page_x0];
				// Exactly one level per mip 0 page: the shader walks mips fine to
				// coarse, so a page resolved to level L is served by the level L
				// page and needs no ancestor. -1 is culled, which leaves the
				// indirection entry alone and lets the array path serve the texel.
				if (page_mip != mip) {
					continue;
				}
				need[size_t(page_y0 >> mip) * at + (page_x0 >> mip)] = 1;
			}
		}
		for (int page_y = 0; page_y < at; page_y++) {
			for (int page_x = 0; page_x < at; page_x++) {
				if (need[size_t(page_y) * at + page_x]) {
					requests.push_back(Vector3i(page_x, page_y, mip));
				}
			}
		}
	}
	if (!_vt.vt_debug_direct_material && _vt.vt_adaptive_enabled && !_vt.surface_vt_force_mip) {
		// Keep an AVT mip chain resident. Growth remaps existing pages to their
		// new mip addresses; the shader keeps sampling them during refinement.
		requests.clear();
		for (int mip = p_max_local_mip; mip >= 0; --mip) {
			int at = MAX(1, p_pages_per_axis >> mip);
			for (int y = 0; y < at; ++y) {
				for (int x = 0; x < at; ++x) { requests.push_back(Vector3i(x, y, mip)); }
			}
		}
	}
	return requests;
}

// Produces and publishes the pages this pass allocated. A page that cannot be
// written is released again so a later pass can retry it.
int Terrain3D::_produce_missing_vt_pages(const Vector2i &p_region_loc, int p_pages_per_axis, real_t p_region_world,
		const std::vector<Vector3i> &p_missing) {
	std::vector<Ref<Image>> pages;
	if (_data->produce_surface_page_set(p_region_loc, p_pages_per_axis, _vt.surface_vt->get_page_size(),
				_vt.surface_vt->get_page_border(), p_missing, pages) < 0) {
		for (const Vector3i &request : p_missing) { _vt.surface_vt->release_page(p_region_loc, request.z, request.x, request.y); }
		return 0;
	}
	int produced = 0;
	for (int i = 0; i < int(p_missing.size()) && i < int(pages.size()); i++) {
		const int slot = _vt.surface_vt->lookup_page(p_region_loc, p_missing[i].z, p_missing[i].x, p_missing[i].y);
		if (slot >= 0 && _vt.surface_vt->write_page(slot, pages[i])) {
			float span = p_region_world / float(MAX(1, p_pages_per_axis >> p_missing[i].z));
			Rect2 rect(Vector2(p_region_loc) * p_region_world + Vector2(p_missing[i].x, p_missing[i].y) * span, Vector2(span, span));
			_queue_vt_material_page(slot, pages[i], rect, false, p_missing[i].z, Vector2i(p_missing[i].x, p_missing[i].y));
			produced++;
		} else {
			_vt.surface_vt->release_page(p_region_loc, p_missing[i].z, p_missing[i].x, p_missing[i].y);
		}
	}
	return produced;
}

// Publishes block origins/sizes in the same update as the remapped page table.
// Direct callers must not expose a new table with yesterday's shader block.
void Terrain3D::_publish_vt_block_tables(const PackedVector2Array &p_blocks, const PackedFloat32Array &p_sizes) {
	if (_vt.surface_vt_blocks != p_blocks) {
		_vt.surface_vt_blocks = p_blocks;
		_vt.surface_vt_blocks_dirty = true;
	}
	if (_vt.surface_vt_block_sizes != p_sizes) {
		_vt.surface_vt_block_sizes = p_sizes;
		_vt.surface_vt_blocks_dirty = true;
	}
	if (_vt.surface_vt_blocks_dirty && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
		_vt.surface_vt_blocks_dirty = false;
	}
}
