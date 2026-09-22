// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// The two surface views, part 1 of 4: the view objects and the settings that size them.

// One of four files that define the two views and their demand passes. The two views' setup and
// teardown
// (`_setup_surface_vt()`, `_setup_surface_svt()`, `_configure_surface_view()` and their destroy
// counterparts), the delivery matrix that decides which of them exist at all
// (`set_vt_delivery()` / `_resolve_vt_delivery()`) with the rule that decides which cells it accepts
// (`is_vt_delivery_supported()`), the clipmap ring's one owner and the mechanism's own entry
// (`_setup_vt_clipmap()` / `debug_update_vt_clipmap()`), and every setting the dock, the inspector
// and scripts write: both fields' page size, border, count and distances, the level bands, the array
// toggle, the feedback controls and `invalidate_surface_pages()`.
//
// The two legacy enables (`surface_vt_enabled`, `surface_svt_enabled`) are now *views of a cell*
// of that matrix rather than independent state: writing one writes the near or far material cell,
// and reading one asks whether that cell selected the method. Nothing else reads them, so a
// configuration cannot be described twice and drift.
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
#include "terrain_3d_clipmap_source_height.h"

#include <godot_cpp/classes/time.hpp>

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
	// The shared service is a function of which views exist: it is the pool and the producer both
	// sample, so a view arriving or leaving invalidates the configuration the last one proved and
	// the next tick reconfigures it. Without this a view created after a shared configuration had
	// been proven would keep its own private pool and never be given the shared one.
	_vt.vt_shared_ready = false;
}

void Terrain3D::_destroy_surface_vt() {
	LOG(INFO, "Destroying surface virtual texture");
	// A near field that is going away must not reserve physical capacity from a far field that
	// stays: the coarse owner's pages are protected, and a protection held by a destroyed view is a
	// slot the far field can never evict.
	_release_avt_coarse_protections();
	memdelete_safely(_vt.surface_vt);
	_vt.avt_settled.unverify();
	// The surviving view is the one the next tick must hand the shared pool to; see the note in
	// `_setup_surface_vt()`.
	_vt.vt_shared_ready = false;
}

void Terrain3D::_setup_surface_svt() {
	if (_vt.surface_svt || !_data) {
		return;
	}
	LOG(DEBUG, "Creating far-field surface virtual texture");
	_vt.surface_svt = memnew(Terrain3DVirtualTexture);
	_configure_surface_view(_vt.surface_svt, true);
	_vt.surface_svt->initialize();
	// A view that has just been created has proven nothing, so the shader renders from the live
	// source material until the root pyramid is verified. Reopening the gate here as well as in
	// the enable path is what makes creation and re-enable the same state.
	_vt.svt_startup_ready = false;
	// See `_setup_surface_vt()`: the shared configuration is a function of the view set.
	_vt.vt_shared_ready = false;
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
	// The far field's root plan and its startup gate describe a view that no longer exists; a
	// re-created one plans and proves itself from scratch.
	_vt.svt_roots = Terrain3DSVTRootPlan();
	_vt.svt_startup_ready = false;
	_vt.vt_shared_ready = false;
}

void Terrain3D::set_surface_svt_enabled(const bool p_enabled) {
	// A view of the far field's material cell; the assembly rule is `set_vt_delivery()`'s.
	set_vt_delivery(int(TerrainVT::Tier::Far), int(TerrainVT::ChannelGroup::Material),
			int(p_enabled ? TerrainVT::Delivery::SVT : TerrainVT::Delivery::Direct));
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
	if (!p_enabled && !group_has_vt_delivery(TerrainVT::ChannelGroup::Material)) {
		LOG(WARN, "No cell delivers the diffuse/normal group, so the region texture array keeps "
				  "carrying the surface channel until one does.");
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
	// A view of the near field's material cell. The assembly rule - what a service creation or
	// destruction costs, and when the material is rebound - lives in `set_vt_delivery()`.
	set_vt_delivery(int(TerrainVT::Tier::Near), int(TerrainVT::ChannelGroup::Material),
			int(p_enabled ? TerrainVT::Delivery::AVT : TerrainVT::Delivery::Direct));
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
	if (_initialized && has_vt_delivery()) {
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

///////////////////////////
// Delivery assembly
///////////////////////////

// Which method carries which channel group in which band. `TerrainVT::DeliveryMatrix` holds the
// four values; everything below is the assembly that follows from them, and it is deliberately the
// only place a service is created or destroyed outside teardown. See
// docs/vt_delivery_assembly.md for the channel inventory and the rule.

int Terrain3D::get_vt_delivery(const int p_tier, const int p_group) const {
	if (p_tier < 0 || p_tier >= TerrainVT::TIER_COUNT || p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return int(TerrainVT::Delivery::Direct);
	}
	return int(_vt.delivery.get(TerrainVT::Tier(p_tier), TerrainVT::ChannelGroup(p_group)));
}

// Which (channel group, method) pairs this build can deliver, and the sentence that says why not.
// This is the one place the matrix's *acceptance* is decided, so a cell can only ever name a method
// that reaches a fragment here, and the matrix is deliberately **asymmetric**: the two channel groups
// do not have the same choices.
//
//   * The **material** group (diffuse + normal, and the control payload they are baked from) is the
//     paged one: AVT and SVT are its two arms and are what this build ships. Clipmap needs a
//     material-channel source, which is M4.
//   * The **height** group (displacement, normals, holes) has exactly two choices, by design:
//     `Direct`, the region array, and the clipmap ring - which the shader arm `height_at_uv()`
//     samples, so the cell is deliverable and selecting it is what compiles the arm in. AVT and SVT
//     page the material group and are not height's methods: a height cell naming one of them is not
//     a method waiting for an arm, because there is no height arm of that kind to write.
//
// `Direct` is always deliverable: the region arrays are the fallback and the only method that is
// always correct (see the enum's comment). The tier does not enter, because the two bands select
// reach rather than capability - and that matters most for the height group, where a ring is one
// object per *group*: the near and the far height cell name the same ring, so either one of them
// selecting Clipmap is the whole of the choice, and the band they name is where the ring serves.
bool Terrain3D::is_vt_delivery_supported(const int p_group, const int p_method) const {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT || !TerrainVT::is_valid_delivery(p_method)) {
		return false;
	}
	const TerrainVT::Delivery method = TerrainVT::Delivery(p_method);
	if (method == TerrainVT::Delivery::Direct) {
		return true;
	}
	if (p_group == int(TerrainVT::ChannelGroup::Height)) {
		return method == TerrainVT::Delivery::Clipmap;
	}
	return method == TerrainVT::Delivery::AVT || method == TerrainVT::Delivery::SVT;
}

String Terrain3D::get_vt_delivery_unsupported_reason(const int p_group, const int p_method) const {
	if (is_vt_delivery_supported(p_group, p_method)) {
		return String();
	}
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT || !TerrainVT::is_valid_delivery(p_method)) {
		return "the cell is out of range";
	}
	if (p_group == int(TerrainVT::ChannelGroup::Height)) {
		return "the height channel is delivered directly or by the clipmap ring; AVT and SVT page the diffuse+normal group";
	}
	return TerrainVT::Delivery(p_method) == TerrainVT::Delivery::Clipmap
			? "no clipmap source carries the diffuse+normal channel in this build (M4)"
			: "the diffuse+normal channel has no arm for this method";
}

void Terrain3D::set_vt_delivery(const int p_tier, const int p_group, const int p_delivery) {
	if (p_tier < 0 || p_tier >= TerrainVT::TIER_COUNT || p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		LOG(WARN, "Delivery cell (tier ", p_tier, ", group ", p_group, ") is out of range; keeping the current methods.");
		return;
	}
	if (!TerrainVT::is_valid_delivery(p_delivery)) {
		LOG(WARN, "Delivery method ", p_delivery, " is not one of Direct/AVT/Clipmap/SVT; keeping the current method.");
		return;
	}
	const TerrainVT::Tier tier = TerrainVT::Tier(p_tier);
	const TerrainVT::ChannelGroup group = TerrainVT::ChannelGroup(p_group);
	const TerrainVT::Delivery previous = _vt.delivery.get(tier, group);
	// A method this build cannot deliver is refused here, at the one door every write goes through
	// (the panel, the four properties, the two legacy booleans and a script). The alternative - take
	// the cell and render from the region arrays anyway - is a cell that reads as working while the
	// picture is the fallback, which is exactly the state this refusal exists to make impossible.
	if (!is_vt_delivery_supported(p_group, p_delivery)) {
		LOG(WARN, "Delivery ", p_tier == int(TerrainVT::Tier::Near) ? "near" : "far", "/",
				p_group == int(TerrainVT::ChannelGroup::Material) ? "diffuse+normal" : "height", ": ",
				TerrainVT::delivery_name(TerrainVT::Delivery(p_delivery)), " is unavailable: ",
				get_vt_delivery_unsupported_reason(p_group, p_delivery), "; it stays ",
				TerrainVT::delivery_name(previous), ".");
		return;
	}
	const bool changed = _vt.delivery.set(tier, group, TerrainVT::Delivery(p_delivery));
	if (changed) {
		LOG(INFO, "Delivery ", p_tier == int(TerrainVT::Tier::Near) ? "near" : "far", "/",
				p_group == int(TerrainVT::ChannelGroup::Material) ? "diffuse+normal" : "height", ": ",
				TerrainVT::delivery_name(previous), " -> ", TerrainVT::delivery_name(TerrainVT::Delivery(p_delivery)));
	}
	_resolve_vt_delivery(changed);
}

void Terrain3D::set_vt_delivery_near_material(const int p_delivery) {
	set_vt_delivery(int(TerrainVT::Tier::Near), int(TerrainVT::ChannelGroup::Material), p_delivery);
}

void Terrain3D::set_vt_delivery_near_height(const int p_delivery) {
	set_vt_delivery(int(TerrainVT::Tier::Near), int(TerrainVT::ChannelGroup::Height), p_delivery);
}

void Terrain3D::set_vt_delivery_far_material(const int p_delivery) {
	set_vt_delivery(int(TerrainVT::Tier::Far), int(TerrainVT::ChannelGroup::Material), p_delivery);
}

void Terrain3D::set_vt_delivery_far_height(const int p_delivery) {
	set_vt_delivery(int(TerrainVT::Tier::Far), int(TerrainVT::ChannelGroup::Height), p_delivery);
}

// The assembly rule, in one place. Every write to the matrix - the four properties, the generic
// setter and the two legacy views - reaches the services through here, so a method's object has one
// owner and a new method adds one arm rather than a setter that has to remember to rebuild.
//
// **Creation is selection-driven; freeing is at teardown.** A method no cell ever selected is never
// built, which is the whole point: an all-`Direct` configuration owns no view, no page pool, no
// material arrays, no VT uniform, no shader arm and no pass - measured in `vt_delivery`. What a
// *deselection* does is stop the service: its pass stops, its uniform gate closes, its arms leave
// the generated shader, its protected pages are released and its capacity is no longer reserved.
// The object itself stays, deliberately, for three reasons that are one decision:
//
//   * it is a residency cache as well as a renderer. Freeing it releases every page it holds, so a
//     toggle would cost a full re-stream - and the lifetime design (`docs/vt_lifetime_review.md`)
//     treats a toggle as a rendering choice, not a residency reset. Four recorded scenarios toggle
//     and then measure continuity across it.
//   * the pool and the producer are **shared** between the two views (rule 6 of the assembly doc).
//     They are not per-cell state, so "this cell is direct now" cannot decide their lifetime, and
//     freeing one view while the other samples the pool is exactly the coupling that produced the
//     five-suite failure recorded in section 9 there.
//   * it removes a whole class of failure by construction: with no view ever freed at runtime,
//     `_vt.surface_vt` cannot become null under a code path written when it never could. Five
//     suites crashed or failed on the unguarded dereferences the first attempt exposed.
//
// The tick side effect is applied even when the write did not move the cell: a harness that
// switched processing off before re-applying a setting has to get it back, which is the contract at
// the top of this file and the reason this is not an early return.
void Terrain3D::_resolve_vt_delivery(const bool p_changed) {
	// The clipmap is the one method whose service is per channel *group* rather than per tier: a ring
	// carries one group's channel, so a cell selecting Clipmap asks for exactly one ring, and the
	// group that selected it is the ring's identity. Every ring that exists is reconfigured here as
	// well, so a size or level write lands on the same call as the cell that selected the method.
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		const TerrainVT::ChannelGroup channel = TerrainVT::ChannelGroup(group);
		if (_vt.clipmap[group] != nullptr || _vt.delivery.group_uses(channel, TerrainVT::Delivery::Clipmap)) {
			_setup_vt_clipmap(channel);
		}
	}
	if (has_avt_delivery() && _vt.surface_vt == nullptr) {
		_setup_surface_vt();
	}
	if (has_svt_delivery() && _vt.surface_svt == nullptr) {
		_setup_surface_svt();
	}
	if (p_changed) {
		if (!has_avt_delivery() && _vt.surface_vt != nullptr) {
			// A field that was turned off must give back what it held from the *shared* pool: the
			// coarse owner's pages are protected, and a protection held by a field nobody samples is
			// a slot the surviving field can never evict. It must also forget what it proved - a
			// settled verdict describes a residency that is no longer maintained. Both used to live
			// in the enable setter; they belong here now, because the cell is what turns the field
			// off.
			_release_avt_coarse_protections();
			_vt.avt_settled.unverify();
		}
		if (_initialized && _material.is_valid()) {
			// The shader's variant is built from the service set, and its uniform gate from the
			// material group's own cell: one rebuild covers both, and the flag the material compares
			// (`_shader_uses_vt` against `_needs_vt_shader()`) is what decides whether the code is
			// regenerated or only the uniforms are rebound.
			_material->update(Terrain3DMaterial::REGION_ARRAYS);
		}
	}
	if (has_vt_delivery() && _initialized) { set_physics_process(true); }
}

// Releases the near field's coarse owner from the shared pool's protection. Called when the field
// stops being selected and when it is destroyed: the two moments it stops being sampled, and
// therefore the two moments its reservation is not a reservation for anything.
void Terrain3D::_release_avt_coarse_protections() {
	if (_vt.surface_vt == nullptr) {
		return;
	}
	for (const auto &page : _vt.avt_coarse.pages) {
		const int slot = _vt.surface_vt->lookup_page_exact(page.owner, page.mip, page.x, page.y);
		if (slot >= 0 && _vt.surface_vt->is_page_protected(slot)) { _vt.surface_vt->protect_page(slot, false); }
	}
}

///////////////////////////
// Clipmap ring
///////////////////////////

// The ring's one owner, called by the assembly rule. Which *source* carries a group is the whole of
// the difference between the rings: the addressing, the levels, the strips and the budget are one
// object for either group, so a second channel is a source and a line here rather than a second
// clipmap implementation.
//
// A ring is a residency cache as well as a renderer, so a deselection stops its pass and keeps its
// content - the rule the two views follow (`_resolve_vt_delivery()`), and a selection that comes
// back finds the ring it left instead of a blank one. The return value is whether a ring exists after
// the call, which is what `debug_update_vt_clipmap()` reports as -1 rather than as "produced nothing".
bool Terrain3D::_setup_vt_clipmap(const TerrainVT::ChannelGroup p_group) {
	if (_data == nullptr) {
		return false;
	}
	const int index = int(p_group);
	if (_vt.clipmap[index] == nullptr) {
		if (p_group != TerrainVT::ChannelGroup::Height) {
			// The matrix refuses a method this build cannot deliver (`is_vt_delivery_supported()`),
			// so this branch is reached by `debug_update_vt_clipmap()` asking for a channel no source
			// carries: the material group's, which is M4. It says so per call rather than handing
			// back a ring nothing could produce.
			LOG(WARN, "Clipmap has no source for the ",
					p_group == TerrainVT::ChannelGroup::Material ? "diffuse+normal" : "height",
					" channel in this build; it stays direct.");
			return false;
		}
		LOG(DEBUG, "Creating height clipmap ring");
		_vt.clipmap[index] = std::make_unique<Terrain3DClipmap>(
				std::make_unique<Terrain3DClipmapSourceHeight>(_data));
	}
	Terrain3DClipmap::Config config;
	config.size = _vt.clipmap_size;
	config.levels = _vt.clipmap_levels;
	config.base_world = _vt.clipmap_base_world;
	// One value a texel, in the height map's own format: the ring's layer is what the height arm
	// samples in place of the region array, so the two carry the same numbers in the same format.
	config.channels = 1;
	config.format = Image::FORMAT_RF;
	_vt.clipmap[index]->configure(config);
	return true;
}

// Whether any ring object exists. Read by the ring's debug view, its native preview and the report:
// the gate is "is there a ring to draw", not "does a cell name the method", because a build that
// cannot deliver Clipmap still has the mechanism - built by `debug_update_vt_clipmap()` - and a ring
// that exists is what a picture of a ring is a picture of.
bool Terrain3D::has_vt_clipmap_ring() const {
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		if (_vt.clipmap[group] != nullptr) {
			return true;
		}
	}
	return false;
}

void Terrain3D::set_vt_clipmap_size(const int p_size) {
	// 0 is refused rather than clamped: a ring with no texels an axis is not a small clipmap, it is
	// not a clipmap, and the setter should not accept a shape the mechanism cannot build.
	if (p_size <= 0 || p_size == _vt.clipmap_size) {
		return;
	}
	_vt.clipmap_size = p_size;
	_resolve_vt_delivery(false);
}

void Terrain3D::set_vt_clipmap_levels(const int p_levels) {
	if (p_levels <= 0 || p_levels == _vt.clipmap_levels) {
		return;
	}
	_vt.clipmap_levels = p_levels;
	_resolve_vt_delivery(false);
}

void Terrain3D::set_vt_clipmap_base_world(const real_t p_metres) {
	if (p_metres <= 0.f || Math::is_equal_approx(p_metres, _vt.clipmap_base_world)) {
		return;
	}
	_vt.clipmap_base_world = p_metres;
	_resolve_vt_delivery(false);
}

void Terrain3D::set_vt_clipmap_budget_texels(const int p_texels) {
	// The budget is not a shape: a ring keeps its content when it changes, and 0 is a legal "produce
	// nothing this tick" that a test uses to hold the ring still.
	_vt.clipmap_budget_texels = MAX(0, p_texels);
}

real_t Terrain3D::sample_vt_clipmap(const int p_group, const Vector2 &p_world_xz, const int p_channel) const {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return NAN;
	}
	const Terrain3DClipmap *ring = _vt.clipmap[p_group].get();
	return ring != nullptr ? ring->sample(p_world_xz, p_channel) : NAN;
}

// The height arm's binding, and the reason it is one dictionary rather than five accessors: the
// shader's copy of the ring's addressing has to be the *same* numbers the CPU's is, and the two are
// one publish. `centers` and `rings` are the per-level state the shader indexes with, `valid` is the
// gate that keeps a level which is not current out of a fragment, and the shape is the level rule
// (`base_world * 2^l` metres in `size` texels).
//
// Padded to `Terrain3DClipmap::MAX_LEVELS`, which is the shader's declared array size: Godot's
// uniform arrays are read at their declared length, so a shorter binding leaves the tail undefined,
// and `levels` is what tells a reader how many entries are meaningful. Not published in
// `get_vt_settings()`: the dock and the tests read it from here, and the settings dictionary already
// carries the same state per level (`clipmap[group].level_reports[]`).
Dictionary Terrain3D::get_vt_clipmap_arm(const int p_group) const {
	Dictionary arm;
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return arm;
	}
	const Terrain3DClipmap *ring = _vt.clipmap[p_group].get();
	if (ring == nullptr || !ring->is_configured()) {
		return arm;
	}
	const int levels = ring->get_level_count();
	PackedVector2Array centers;
	PackedVector2Array rings;
	PackedFloat32Array valid;
	centers.resize(Terrain3DClipmap::MAX_LEVELS);
	rings.resize(Terrain3DClipmap::MAX_LEVELS);
	valid.resize(Terrain3DClipmap::MAX_LEVELS);
	for (int level = 0; level < levels; level++) {
		const Terrain3DClipmap::Level &entry = ring->get_level(level);
		centers[level] = entry.center;
		rings[level] = Vector2(real_t(entry.ring.x), real_t(entry.ring.y));
		valid[level] = entry.valid ? 1.f : 0.f;
	}
	arm["configured"] = true;
	arm["texture"] = ring->get_texture_rid();
	arm["size"] = ring->get_size();
	arm["levels"] = levels;
	arm["base_world"] = ring->get_base_world();
	arm["channels"] = ring->get_channel_count();
	arm["centers"] = centers;
	arm["rings"] = rings;
	arm["valid"] = valid;
	return arm;
}

// An edit reached the source. Every ring that carries a channel the edit can change re-produces the
// texels the area covers and stops serving the levels that touch it until they have, so a fragment
// reads the region array for those few ticks instead of a height from before the stroke. Only a ring
// that exists is told: a group with no ring has nothing that could be stale.
int Terrain3D::invalidate_vt_clipmap_area(const AABB &p_area) {
	const Vector2 origin(p_area.position.x, p_area.position.z);
	const Rect2 rect(origin, Vector2(p_area.size.x, p_area.size.z));
	int queued = 0;
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		Terrain3DClipmap *ring = _vt.clipmap[group].get();
		if (ring == nullptr) {
			continue;
		}
		queued += ring->invalidate_rect(rect);
	}
	// The levels that stopped being current are the shader's gate, and the gate is a uniform: without
	// this the ring would keep serving the height it held before the stroke.
	_update_vt_clipmap_arm();
	return queued;
}

// Whether any ring's addressing moved since the shader was bound with it, and the rebind that
// follows. Both halves are the ring's own state rather than a copy kept here, so a ring that was
// freed and rebuilt is a change like any other.
bool Terrain3D::_vt_clipmap_state_changed() {
	bool changed = false;
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		const Terrain3DClipmap *ring = _vt.clipmap[group].get();
		const uint64_t stamp = ring != nullptr ? ring->get_state_stamp() : 0;
		if (stamp != _vt.clipmap_state[group]) {
			_vt.clipmap_state[group] = stamp;
			changed = true;
		}
	}
	return changed;
}

void Terrain3D::_update_vt_clipmap_arm() {
	if (!_vt_clipmap_state_changed()) {
		return;
	}
	if (_initialized && _material.is_valid()) {
		_material->update_vt_clipmap_uniforms();
	}
}

// The mechanism's own entry, beside the read above, and the reason it exists: the matrix refuses
// `Clipmap` for every group in this build (`is_vt_delivery_supported()` - the height channel's arm is
// M2b and the material channel's source is M4), so no cell can name the method and the tick never
// enters its phase. The ring's addressing, strips, budget and content still have to be measurable -
// `native/tests/vt_clipmap` is nothing but those readings - so this runs exactly what that phase
// runs: the same `Terrain3DClipmap::update()`, with the same focus (`get_clipmap_target_position()`)
// and the same `vt_clipmap_budget_texels`, over the rings the caller names rather than the rings a
// cell selected. It publishes the same two numbers the phase publishes, so a panel or a test reads
// the mechanism through the one report either way.
//
// A reading taken here is the mechanism's and not a render's: nothing samples the ring yet.
int Terrain3D::debug_update_vt_clipmap(const int p_group) {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return -1;
	}
	if (!_setup_vt_clipmap(TerrainVT::ChannelGroup(p_group))) {
		_vt.clipmap_produced_texels = 0;
		return -1;
	}
	Terrain3DClipmap *ring = _vt.clipmap[p_group].get();
	if (ring == nullptr) {
		_vt.clipmap_produced_texels = 0;
		return -1;
	}
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	const Vector2 focus = v3v2(get_clipmap_target_position());
	_vt.clipmap_produced_texels = ring->update(focus, _vt.clipmap_budget_texels);
	_vt.vt_clipmap_ms = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	// The same rebind the tick's phase does, so a ring a test or the dock drove with this entry is
	// the ring the shader reads.
	_update_vt_clipmap_arm();
	return _vt.clipmap_produced_texels;
}
