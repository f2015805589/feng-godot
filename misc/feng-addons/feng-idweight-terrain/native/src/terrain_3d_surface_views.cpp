// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The two surface views, part 1 of 4: the view objects and the settings that size them.

// One of four files that define the two views and their demand passes. The two views' setup and
// teardown
// (`_setup_surface_vt()`, `_setup_surface_svt()`, `_configure_surface_view()` and their destroy
// counterparts) and every setting the dock, the inspector and scripts write: the two enables, both
// fields' page size, border, count and distances, the level bands, the array toggle, the feedback
// controls and `invalidate_surface_pages()`.
//
// A setter here owns its side effects rather than only storing a value, and the one to know about is
// the *toggle*: enabling either field puts a field that is about to be demanded into a world that
// may have switched this node's own tick off, so both enables turn `set_physics_process` on when the
// node is initialized. A caller that drives the section itself - an editor preview, a test harness
// that sends `NOTIFICATION_PHYSICS_PROCESS` by hand, a paused world - therefore has to disable
// processing again *after* the enable and not before it: measured, a test that disabled first ran
// every page-arrival ramp at twice the rate it asked for. Disabling a field does not stop the tick,
// because the other field may still be enabled. The setters that must rebuild rather than adjust
// call `_reset_vt_configuration()`, which cancels a bake in flight, marks the shared setup and the
// far field's startup gate as unproven and rebinds the material.
//
// The other halves: `terrain_3d_surface_views_far.cpp` (the far field's pass and the one
// distance -> level rule it walks), `terrain_3d_surface_views_far_walk.cpp` (the far field's root
// pyramid plan, its visible walk and the pass that spends the budget on them) and
// `terrain_3d_surface_views_near.cpp` (the near field's pass, its feedback pass and the sector machinery).

#include "terrain_3d.h"
#include "terrain_3d_surface_views_internal.h"

#include "logger.h"

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
	p_view->set_format(IDWEIGHT_IMAGE_FORMAT);
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
	p_view->set_indirection_size(is_sector_avt() ? MIN(4096, MAX(2048, get_avt_base_block_size() * 2)) : MAX(64, _vt.surface_vt_page_count * 4));
}

void Terrain3D::_destroy_surface_svt() {
	LOG(INFO, "Destroying far-field surface virtual texture");
	memdelete_safely(_vt.surface_svt);
	_vt.surface_svt_enabled = false;
}

void Terrain3D::set_surface_svt_enabled(const bool p_enabled) {
	_vt.surface_svt_enabled = p_enabled;
	// A far field that has just been switched on has to prove its root pyramid before the shader
	// may sample it strictly - it renders from the live source material until then - so the gate has
	// to be reopened here and not only in setup, which is the only reason a re-enable differs from
	// a first enable.
	if (p_enabled) { _vt.svt_startup_ready = false; }
	// The tick side effect both toggles have; see the contract at the top of this file.
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

// The far field's configured mip cap: the coarsest level the world grid may publish before demand
// raises it. H3 step 1 established that a cap is a bound on which mips a *request* may name, not a
// property of any page's content - a resident indirection entry survives it, because
// `virtual = (page + half) >> mip` does not depend on the cap, and the levels it enables are derived
// from the persisted cells on demand. Step 1 removed the whole-world re-bake from the *runtime* raise
// for that reason; this setter was the same heavy hammer one level up, and the two demand-side setters
// below (`set_surface_svt_root_mips()`, `set_surface_svt_fallback_policy()`) already show what the
// cheap version looks like. `_reset_vt_configuration()` here marked the shared setup stale, which on
// the next tick rebuilt both views' pool, released every resident page (including the near field's),
// bumped `pool.generation` so the far field re-planned from nothing, and cancelled a bake in flight
// whose catalogue is indexed by cell and level rather than by this cap.
//
// What does have to happen: publish the cap on the live view, because `_surface_svt_max_mip` is what
// the shader's coarser walk clamps against and the view is its source; reopen the strict-sampling
// gate, because the root window is planned inside the new cap and `_update_visible_svt()`'s root key
// mixes `maximum_mip` and `root_top` so the next pass re-pins by itself; and republish the material,
// which is where both reach the shader.
void Terrain3D::set_surface_svt_max_mip(const int p_mip) {
	_vt.surface_svt_max_mip = p_mip;
	if (!_vt.vt_debug_direct_material) {
		if (_vt.surface_svt) { _vt.surface_svt->set_world_max_mip(p_mip); }
		_vt.svt_startup_ready = false;
		if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
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
	// A demand-side setting: how many root mips the far field protects. It moves no address, no page
	// size and no atlas dimension, and `_update_visible_svt()` mixes the count into its plan hash, so a
	// changed count invalidates the plan by itself. The root pyramid does have to be proven again -
	// `is_svt_startup_ready()` reads this count and the material gates strict sampling on it - which is
	// the same one flag `set_surface_svt_enabled()` reopens. Resetting the whole VT configuration here
	// instead rebuilt the shared pool the near field samples and threw away its resident pages, and it
	// cancelled a bake in flight whose output is indexed by level, not by this count.
	if (!_vt.vt_debug_direct_material) { _vt.svt_startup_ready = false; }
}

// Which set answers a far-field fragment whose selected page is not resident. Like the root-mip
// count above this is a demand-side setting: it moves no address, no page size and no atlas
// dimension, and `_update_visible_svt()` mixes it into its plan hash, so a change invalidates the
// plan by itself. It does have to be proven again - `is_svt_startup_ready()` gates strict sampling on
// the protected set having content - which is the same one flag `set_surface_svt_enabled()` reopens.
// Resetting the whole VT configuration here would rebuild the shared pool the near field samples and
// throw away its resident pages for a setting that changes which pages are pinned.
void Terrain3D::set_surface_svt_fallback_policy(const int p_policy) {
	const int policy = CLAMP(p_policy, 0, 1);
	if (_vt.surface_svt_fallback_policy == policy) { return; }
	_vt.surface_svt_fallback_policy = policy;
	if (!_vt.vt_debug_direct_material) { _vt.svt_startup_ready = false; }
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
		_vt.bake.dirty_regions[p_region_loc] = true;
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

void Terrain3D::set_surface_vt_enabled(const bool p_enabled) {
	if (!p_enabled && _vt.surface_vt_enabled && _vt.surface_vt) {
		// A disabled near field must not reserve physical capacity from SVT.
		for (const auto &page : _vt.avt_coarse.pages) {
			const int slot = _vt.surface_vt->lookup_page_exact(page.owner, page.mip, page.x, page.y);
			if (slot >= 0 && _vt.surface_vt->is_page_protected(slot)) { _vt.surface_vt->protect_page(slot, false); }
		}
	}
	if (p_enabled != _vt.surface_vt_enabled) { _vt.avt_settled.unverify(); }
	_vt.surface_vt_enabled = p_enabled;
	// The tick side effect both toggles have; see the contract at the top of this file. It is what a
	// harness that drives the section itself has to undo *after* this setter, not before it.
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
