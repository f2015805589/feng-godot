// Copyright 漏 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

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
#include "terrain_3d_clipmap_source_material.h"
#include "terrain_3d_surface_baker.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport.hpp>

#include <cmath>

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
//   * `Direct` is always deliverable: the region arrays are the fallback and the only method that is
//     always correct (see the enum's comment).
//   * `Clipmap` is deliverable for exactly the groups that have a *source* - `has_clipmap_source()`,
//     which is the source factory's own answer. The ring's mechanism, its settings, its reporting and
//     its arm's uniforms are channel-agnostic, so this is not a capability list: registering a source
//     is what makes the method selectable for that group, in the dock, in both previews, in the
//     report and at the setter, with nothing else edited.
//   * `AVT` and `SVT` are the **material** group's, and that is a channel rule rather than a
//     capability that could arrive: they page a baked diffuse+normal+AO/roughness payload, while the
//     height channel's two choices are the region array and the ring. A height cell naming one of
//     them is not a method waiting for an arm, because there is no height arm of that kind to write.
//
// The tier does not enter, because the two bands select reach rather than capability - and that
// matters most for the height group, where a ring is one object per *group*: the near and the far
// height cell name the same ring, so either one of them selecting Clipmap is the whole of the choice,
// and the band they name is where the ring serves.
bool Terrain3D::is_vt_delivery_supported(const int p_group, const int p_method) const {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT || !TerrainVT::is_valid_delivery(p_method)) {
		return false;
	}
	const TerrainVT::Delivery method = TerrainVT::Delivery(p_method);
	if (method == TerrainVT::Delivery::Direct) {
		return true;
	}
	if (method == TerrainVT::Delivery::Clipmap) {
		return has_clipmap_source(p_group);
	}
	return p_group == int(TerrainVT::ChannelGroup::Material) &&
			(method == TerrainVT::Delivery::AVT || method == TerrainVT::Delivery::SVT);
}

String Terrain3D::get_vt_delivery_unsupported_reason(const int p_group, const int p_method) const {
	if (is_vt_delivery_supported(p_group, p_method)) {
		return String();
	}
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT || !TerrainVT::is_valid_delivery(p_method)) {
		return "the cell is out of range";
	}
	const TerrainVT::ChannelGroup group = TerrainVT::ChannelGroup(p_group);
	if (TerrainVT::Delivery(p_method) == TerrainVT::Delivery::Clipmap) {
		return String("no clipmap source carries the ") + TerrainVT::group_channel_name(group) +
				" channel in this build";
	}
	if (group == TerrainVT::ChannelGroup::Height) {
		return "the height channel is delivered directly or by the clipmap layer; AVT and SVT page the diffuse+normal group";
	}
	return "the diffuse+normal channel has no arm for this method";
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
				TerrainVT::group_channel_name(group), ": ",
				TerrainVT::delivery_name(TerrainVT::Delivery(p_delivery)), " is unavailable: ",
				get_vt_delivery_unsupported_reason(p_group, p_delivery), "; it stays ",
				TerrainVT::delivery_name(previous), ".");
		return;
	}
	const bool changed = _vt.delivery.set(tier, group, TerrainVT::Delivery(p_delivery));
	if (changed) {
		LOG(INFO, "Delivery ", p_tier == int(TerrainVT::Tier::Near) ? "near" : "far", "/",
				TerrainVT::group_channel_name(group), ": ",
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
	// The clipmap is the one method whose service is per channel *group* rather than per tier: a layer
	// carries one group's channel, so a cell selecting Clipmap asks for exactly one layer, and the
	// group that selected it is the layer's identity. Every layer that exists is reconfigured here as
	// well, so a size, level, implementation or budget write lands on the same call as the cell that
	// selected the method - and a switch of implementation replaces the storage in that one call.
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		const TerrainVT::ChannelGroup channel = TerrainVT::ChannelGroup(group);
		if (_vt.clipmap_layer[group] != nullptr ||
				_vt.delivery.group_uses(channel, TerrainVT::Delivery::Clipmap)) {
			_setup_vt_clipmap(channel);
		}
	}
	// And the material group's detail layer, which is a second object over the same group: a finer,
	// sparse layer whose lifetime follows the material cell exactly like the ring's does. It is
	// rebuilt here rather than by the ring because it is not a ring - its own settings size it and
	// its own budget turns it off.
	_setup_vt_material_detail();
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

// The one place a channel group is bound to a channel, and therefore the whole of what adding a
// channel to the ring costs on this side: a `Terrain3DClipmapSource` subclass and a case below (plus
// the class's own `get_channel_count()` / `get_format()`, which is where its *shape* is declared). The
// mechanism is the levels, the addressing, the strips, the budget and the upload
// (`terrain_3d_clipmap.h`), so nothing here or above has to know what the values mean.
//
// A group whose channel is `None` has no ring rather than a ring nothing could produce - the shape a
// channel with no scalar payload at all would take. The two channels that exist are the height map's
// `R32F` texel and the material group's packed `R16` surface payload; the material group's *baked*
// arrays are a publish path (the baker's) rather than a source, which is why the ring carries the
// payload those arrays are baked from and the arm evaluates from it.
Terrain3D::ClipmapChannel Terrain3D::_clipmap_channel(const TerrainVT::ChannelGroup p_group) const {
	switch (p_group) {
		case TerrainVT::ChannelGroup::Height:
			return ClipmapChannel::Height;
		case TerrainVT::ChannelGroup::Material:
			return ClipmapChannel::Material;
		default:
			return ClipmapChannel::None;
	}
}

std::unique_ptr<Terrain3DClipmapSource> Terrain3D::_make_clipmap_source(const TerrainVT::ChannelGroup p_group) const {
	if (_data == nullptr) {
		return nullptr;
	}
	switch (_clipmap_channel(p_group)) {
		case ClipmapChannel::Height:
			return std::make_unique<Terrain3DClipmapSourceHeight>(_data);
		case ClipmapChannel::Material:
			return std::make_unique<Terrain3DClipmapSourceMaterial>(_data);
		default:
			return nullptr;
	}
}

// The matrix's acceptance question, and deliberately not `_make_clipmap_source() != nullptr`: the
// factory needs the data resource (a height source reads it), while the capability is a property of the
// build. Reading the factory here would refuse a cell on a terrain whose data is assigned later - and a
// cell refused is a cell a scene loses, which is exactly the failure the refusal exists to prevent.
bool Terrain3D::has_clipmap_source(const int p_group) const {
	return p_group >= 0 && p_group < TerrainVT::GROUP_COUNT &&
			_clipmap_channel(TerrainVT::ChannelGroup(p_group)) != ClipmapChannel::None;
}

// The layer's one owner, called by the assembly rule. Which *source* carries a group is the whole of
// the difference between two groups: the addressing ladder, the units, the budget and the bake queue
// are one object for either group, so a second channel is a source and the line above rather than a
// second clipmap. Which *implementation* answers them is a setting of that one object
// (`vt_clipmap_implementation`), and the facade owns the selected one - so a switch replaces the
// storage instead of standing a second mechanism beside the first.
//
// A layer is a residency cache as well as a renderer, so a deselection stops its pass and keeps its
// content - the rule the two views follow (`_resolve_vt_delivery()`), and a selection that comes back
// finds the layer it left instead of a blank one. The return value is whether a layer exists after the
// call, which is what `debug_update_vt_clipmap()` reports as -1 rather than as "produced nothing".
Terrain3DClipmapLayer::Settings Terrain3D::_clipmap_settings(const TerrainVT::ChannelGroup p_group) const {
	Terrain3DClipmapLayer::Settings settings;
	settings.implementation = _vt.clipmap_implementation;
	// A legacy tuple that differs from its historical default is an explicit compatibility fallback for
	// both groups. With the tuple untouched, each group starts from its own recommended shape: material
	// keeps the complete 1024 -> 1 ladder, while height trades some fine density and storage for the same
	// one-texel/metre outer endpoint. Per-group fields then override only the values they specify.
	const TerrainClipmap::Shape legacy_default;
	const bool has_legacy_override = _vt.clipmap_size != legacy_default.size ||
			_vt.clipmap_units != legacy_default.units ||
			!Math::is_equal_approx(_vt.clipmap_base_world, legacy_default.base_world);
	if (has_legacy_override) {
		settings.shape.size = _vt.clipmap_size;
		settings.shape.units = _vt.clipmap_units;
		settings.shape.base_world = _vt.clipmap_base_world;
	} else if (p_group == TerrainVT::ChannelGroup::Height) {
		// 128 texels over 2 m is 64 texels/m; seven units halve this to 1 texel/m at 128 m reach.
		settings.shape.size = 128;
		settings.shape.units = 7;
		settings.shape.base_world = 2.f;
	} // Material keeps TerrainClipmap::Shape's shipped (256, 11, 0.25 m) defaults.
	const int index = int(p_group);
	if (index >= 0 && index < TerrainVT::GROUP_COUNT) {
		if (_vt.clipmap_group_size[index] > 0) {
			settings.shape.size = _vt.clipmap_group_size[index];
		}
		if (_vt.clipmap_group_units[index] > 0) {
			settings.shape.units = _vt.clipmap_group_units[index];
		}
		if (_vt.clipmap_group_base_world[index] > 0.f) {
			settings.shape.base_world = _vt.clipmap_group_base_world[index];
		}
	}
	settings.shape.global_texels = _vt.clipmap_atlas_global_texels;
	settings.shape.blocks_per_frame = _vt.clipmap_atlas_blocks_per_frame;
	return settings;
}

bool Terrain3D::_setup_vt_clipmap(const TerrainVT::ChannelGroup p_group) {
	if (_data == nullptr) {
		return false;
	}
	const int index = int(p_group);
	if (_vt.clipmap_layer[index] == nullptr) {
		// The facade is handed the channel's *factory*, not one source: it asks for a source each time
		// it builds an implementation, which is what lets the implementation be replaced without
		// moving ownership back out of the one being replaced.
		_vt.clipmap_layer[index] = std::make_unique<Terrain3DClipmapLayer>(
				[this, p_group]() { return _make_clipmap_source(p_group); });
	}
	Terrain3DClipmapLayer::Settings settings = _clipmap_settings(p_group);
	// The channel's shape is the channel's: a source declares how many scalars a texel holds, what one
	// value's format is, and what a producer bakes out of those texels. Asking for it *before* the
	// build is what makes the shape travel with the channel rather than being written here - and it is
	// the same question whichever implementation ends up answering.
	const int existing = _vt.clipmap_layer[index]->get_source_channel_count();
	const Image::Format existing_format = _vt.clipmap_layer[index]->get_source_format();
	const int existing_baked = _vt.clipmap_layer[index]->get_source_baked_channel_count();
	const Image::Format existing_baked_format = _vt.clipmap_layer[index]->get_source_baked_format();
	settings.shape.channels = existing;
	settings.shape.format = existing_format;
	settings.shape.baked_channels = existing_baked;
	settings.shape.baked_format = existing_baked_format;
	if (!_vt.clipmap_layer[index]->configure(settings)) {
		// The matrix refuses a method this build cannot deliver (`is_vt_delivery_supported()`), so this
		// branch is reached by `debug_update_vt_clipmap()` asking for a channel no source carries, or by
		// an implementation the shape cannot build. It says so per call and per group rather than
		// handing back a layer nothing could produce.
		LOG(WARN, "Clipmap has no source for the ", TerrainVT::group_channel_name(p_group),
				" channel in this build; it stays direct.");
		return false;
	}
	// The producer bakes out of the layer's texels, so the bake needs the surface *material list* -
	// which the page path publishes and a configuration whose material group takes no page never does.
	// The same one-time publication the ring made, for the same reason: this runs on every write to
	// the matrix, and asking for the list again is not free (the service answers a publish by telling
	// every layer its baked content is stale).
	if (settings.shape.baked_channels > 0 && !_vt.vt_materials_published) {
		_vt.vt_materials_dirty = true;
		_vt.vt_materials_published = true;
	}
	return true;
}

// Whether any layer object exists. Read by the layer's debug view, its native preview and the report:
// the gate is "is there a layer to draw", not "does a cell name the method", because a build that
// cannot deliver Clipmap still has the mechanism - built by `debug_update_vt_clipmap()` - and a layer
// that exists is what a picture of one is a picture of.
bool Terrain3D::has_vt_clipmap_layer() const {
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		if (_vt.clipmap_layer[group] != nullptr) {
			return true;
		}
	}
	return false;
}

void Terrain3D::set_vt_clipmap_size(const int p_size) {
	// 0 is refused rather than clamped: a layer with no texels an axis is not a small clipmap, it is
	// not a clipmap, and the setter should not accept a shape the mechanism cannot build.
	if (p_size <= 0 || p_size == _vt.clipmap_size) {
		return;
	}
	_vt.clipmap_size = p_size;
	_resolve_vt_delivery(false);
}

void Terrain3D::set_vt_clipmap_levels(const int p_levels) {
	if (p_levels <= 0 || p_levels == _vt.clipmap_units) {
		return;
	}
	_vt.clipmap_units = p_levels;
	_resolve_vt_delivery(false);
}

void Terrain3D::set_vt_clipmap_base_world(const real_t p_metres) {
	if (p_metres <= 0.f || Math::is_equal_approx(p_metres, _vt.clipmap_base_world)) {
		return;
	}
	_vt.clipmap_base_world = p_metres;
	_resolve_vt_delivery(false);
}

void Terrain3D::set_vt_clipmap_group_size(const int p_group, const int p_size) {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT || p_size < 0 ||
			p_size == _vt.clipmap_group_size[p_group]) {
		return;
	}
	_vt.clipmap_group_size[p_group] = p_size;
	_resolve_vt_delivery(false);
}

int Terrain3D::get_vt_clipmap_group_size(const int p_group) const {
	return p_group >= 0 && p_group < TerrainVT::GROUP_COUNT ? _vt.clipmap_group_size[p_group] : 0;
}

void Terrain3D::set_vt_clipmap_group_levels(const int p_group, const int p_levels) {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT || p_levels < 0 ||
			p_levels == _vt.clipmap_group_units[p_group]) {
		return;
	}
	_vt.clipmap_group_units[p_group] = p_levels;
	_resolve_vt_delivery(false);
}

int Terrain3D::get_vt_clipmap_group_levels(const int p_group) const {
	return p_group >= 0 && p_group < TerrainVT::GROUP_COUNT ? _vt.clipmap_group_units[p_group] : 0;
}

void Terrain3D::set_vt_clipmap_group_base_world(const int p_group, const real_t p_metres) {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT || !std::isfinite(p_metres) || p_metres < 0.f ||
			Math::is_equal_approx(p_metres, _vt.clipmap_group_base_world[p_group])) {
		return;
	}
	_vt.clipmap_group_base_world[p_group] = p_metres;
	_resolve_vt_delivery(false);
}

real_t Terrain3D::get_vt_clipmap_group_base_world(const int p_group) const {
	return p_group >= 0 && p_group < TerrainVT::GROUP_COUNT ? _vt.clipmap_group_base_world[p_group] : 0.f;
}

void Terrain3D::reset_vt_clipmap_group_shape(const int p_group) {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT ||
			(_vt.clipmap_group_size[p_group] == 0 && _vt.clipmap_group_units[p_group] == 0 &&
					_vt.clipmap_group_base_world[p_group] == 0.f)) {
		return;
	}
	_vt.clipmap_group_size[p_group] = 0;
	_vt.clipmap_group_units[p_group] = 0;
	_vt.clipmap_group_base_world[p_group] = 0.f;
	_resolve_vt_delivery(false);
}

bool Terrain3D::is_vt_clipmap_group_shape_overridden(const int p_group) const {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return false;
	}
	return _vt.clipmap_group_size[p_group] > 0 || _vt.clipmap_group_units[p_group] > 0 ||
			_vt.clipmap_group_base_world[p_group] > 0.f;
}

Dictionary Terrain3D::get_vt_clipmap_group_shape(const int p_group) const {
	Dictionary result;
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return result;
	}
	const Terrain3DClipmapLayer::Settings settings = _clipmap_settings(TerrainVT::ChannelGroup(p_group));
	const TerrainClipmap::Shape &shape = settings.shape;
	result["size"] = shape.size;
	result["levels"] = shape.units;
	result["base_world"] = shape.base_world;
	result["finest_density"] = real_t(shape.size) / MAX(real_t(0.001), shape.base_world);
	result["coarsest_density"] = TerrainClipmap::ladder_of(shape).density_at_unit_count(shape.units);
	result["overridden"] = is_vt_clipmap_group_shape_overridden(p_group);
	return result;
}

// The implementation switch. It goes through the assembly rule like every other shape write, so the
// storage is replaced - the old implementation is freed and the new one configured in the same call -
// and the shader's arm and the material's uniforms are rebuilt because the addressing changed shape.
void Terrain3D::set_vt_clipmap_implementation(const int p_implementation) {
	if (!TerrainClipmap::is_valid_implementation(p_implementation)) {
		LOG(WARN, "Clipmap implementation ", p_implementation, " is not one of ", TerrainClipmap::implementation_hint(),
				"; it stays ", TerrainClipmap::implementation_name(_vt.clipmap_implementation), ".");
		return;
	}
	const TerrainClipmap::Implementation wanted = TerrainClipmap::implementation_from_int(p_implementation);
	if (wanted == _vt.clipmap_implementation) {
		return;
	}
	LOG(INFO, "Clipmap implementation ", TerrainClipmap::implementation_name(_vt.clipmap_implementation), " -> ",
			TerrainClipmap::implementation_name(wanted));
	_vt.clipmap_implementation = wanted;
	_resolve_vt_delivery(true);
}

void Terrain3D::set_vt_clipmap_budget_texels(const int p_texels) {
	// The budget is not a shape: a layer keeps its content when it changes, and 0 is a legal "produce
	// nothing this tick" that a test uses to hold the layer still.
	_vt.clipmap_budget_texels = MAX(0, p_texels);
}

// The Atlas implementation's two settings. Neither is a delivery: they are fields of the layer's shape
// and the next resolve picks them up, exactly as `size` and `base_world` are.
void Terrain3D::set_vt_clipmap_global_texels(const int p_texels) {
	if (p_texels <= 0) {
		return;
	}
	_vt.clipmap_atlas_global_texels = p_texels;
}

void Terrain3D::set_vt_clipmap_blocks_per_frame(const int p_blocks) {
	// 0 is refused rather than clamped: a per-frame bound of zero is a mechanism that never loads.
	if (p_blocks <= 0) {
		return;
	}
	_vt.clipmap_atlas_blocks_per_frame = p_blocks;
}

// The layer's stored value at a world position, through the layer's own addressing - the same ladder
// and the same offset the shader arm samples with, whichever implementation is selected.
real_t Terrain3D::sample_vt_clipmap(const int p_group, const Vector2 &p_world_xz, const int p_channel) const {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return NAN;
	}
	const Terrain3DClipmapLayer *layer = _vt.clipmap_layer[p_group].get();
	return layer != nullptr ? layer->sample(p_world_xz, p_channel) : NAN;
}

// The density a fragment is served at a world point, in texels a metre. It is the *shared ladder's*
// reciprocal and the layer answers it for either implementation, which is what makes the acceptance's
// "density - distance" curve a reading of the delivery rather than of a storage layout.
real_t Terrain3D::sample_vt_clipmap_density(const int p_group, const Vector2 &p_world_xz) const {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return 0.f;
	}
	const Terrain3DClipmapLayer *layer = _vt.clipmap_layer[p_group].get();
	return layer != nullptr ? layer->get_density_at(p_world_xz) : 0.f;
}

// The material's arm binding, and the reason it is one dictionary rather than five accessors: the
// shader's copy of the layer's addressing has to be the *same* numbers the CPU's is, and the two are
// one publish. The selected implementation fills the dictionary in its own uniform names and stamps
// `implementation`, so this is a forward and the binding above it is one path.
Dictionary Terrain3D::get_vt_clipmap_arm(const int p_group) const {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return Dictionary();
	}
	const Terrain3DClipmapLayer *layer = _vt.clipmap_layer[p_group].get();
	return layer != nullptr ? layer->get_arm() : Dictionary();
}

// An edit reached the source. Every layer that carries a channel the edit can change re-produces the
// texels the area covers and stops serving the units that touch it until they have, so a fragment
// reads the region array for those few ticks instead of a height from before the stroke. Only a layer
// that exists is told: a group with none has nothing that could be stale.
int Terrain3D::invalidate_vt_clipmap_area(const AABB &p_area) {
	const Vector2 origin(p_area.position.x, p_area.position.z);
	const Rect2 rect(origin, Vector2(p_area.size.x, p_area.size.z));
	int queued = 0;
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		Terrain3DClipmapLayer *layer = _vt.clipmap_layer[group].get();
		if (layer != nullptr) {
			queued += layer->invalidate_rect(rect);
		}
	}
	// The units that stopped being current are the shader's gate, and the gate is a uniform: without
	// this the layer would keep serving the height it held before the stroke.
	_update_vt_clipmap_arm();
	return queued;
}

// Whether any layer's addressing moved since the shader was bound with it, and the rebind that
// follows. The stamp is the layer's own state rather than a copy kept here, so a layer that was freed
// and rebuilt is a change like any other - and a switch of implementation is one by construction.
bool Terrain3D::_vt_clipmap_state_changed() {
	bool changed = false;
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		const Terrain3DClipmapLayer *layer = _vt.clipmap_layer[group].get();
		const uint64_t stamp = layer != nullptr ? layer->get_state_stamp() : 0;
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

// The mechanism's own entry, beside the read above, and the reason it exists: a group with no source
// this build cannot deliver has no matrix door (`is_vt_delivery_supported()` reads
// `has_clipmap_source()`), so no cell can name the method and the tick never enters its phase for it.
// The layer's addressing, units, budget and content still have to be measurable -
// `native/tests/vt_clipmap` and `native/tests/vt_clipmap_atlas` are nothing but those readings - so
// this runs exactly what that phase runs: the same `update()`, with the same focus
// (`get_clipmap_target_position()`) and the same `vt_clipmap_budget_texels`, over the layers the
// caller names rather than the layers a cell selected. **It drives whichever implementation is
// selected**, which is how the two are measured side by side by one script on one build.
//
// A reading taken here is the mechanism's and not a render's.
int Terrain3D::debug_update_vt_clipmap(const int p_group) {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return -1;
	}
	if (!_setup_vt_clipmap(TerrainVT::ChannelGroup(p_group))) {
		_vt.clipmap_produced_texels = 0;
		return -1;
	}
	Terrain3DClipmapLayer *layer = _vt.clipmap_layer[p_group].get();
	if (layer == nullptr) {
		_vt.clipmap_produced_texels = 0;
		return -1;
	}
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	const Vector2 focus = v3v2(get_clipmap_target_position());
	_vt.clipmap_produced_texels = layer->update(focus, _vt.clipmap_budget_texels);
	// The tests drive the layer through this entry, so the bake is offered here too: a layer whose
	// rects are never offered to a producer reports `baked` false for the rest of the session, which is
	// a state only a caller that forgot the offer can produce.
	if (Terrain3DSurfaceBaker *baker = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr())) {
		baker->queue_clipmap_layer(layer, _vt.clipmap_budget_texels);
	}
	_vt.vt_clipmap_ms = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	// The same rebind the tick's phase does, so a layer a test or the dock drove with this entry is
	// the layer the shader reads.
	_update_vt_clipmap_arm();
	return _vt.clipmap_produced_texels;
}
bool Terrain3D::_setup_vt_material_detail() {
	// On exactly while the material group is delivered by the ring *and* the switch is on. The ring
	// must exist too, because it is the layer's fallback: a detail tile that cannot be baked is
	// served by the ring's coarse level, and without the ring the fragment would have nothing
	// between the tile and the region array.
	const bool wanted = _vt.detail_enabled && _data != nullptr &&
			_vt.delivery.group_uses(TerrainVT::ChannelGroup::Material, TerrainVT::Delivery::Clipmap);
	if (!wanted) {
		if (_vt.material_detail != nullptr) {
			// The producer holds a descriptor set that names this layer's textures and this bundle's
			// job buffer, and jobs that name its slots. It has to forget them while the layer still
			// exists: the arrays are freed just below, and the producer's set would outlive them.
			if (Terrain3DSurfaceBaker *surface_baker = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr())) {
				surface_baker->drop_detail_bake();
			}
			_vt.material_detail->clear();
			_vt.material_detail.reset();
			_vt.material_detail_state = 0;
			_vt.detail_requested_tiles = 0;
			_vt.detail_starved_tiles = 0;
			// The arm's names are still declared by the material clipmap block, so the uniforms are
			// rebound to an empty arm rather than left naming the arrays just freed.
			if (_initialized && _material.is_valid()) {
				_material->update_vt_clipmap_uniforms();
			}
		}
		return false;
	}
	if (_vt.material_detail == nullptr) {
		_vt.material_detail = std::make_unique<Terrain3DMaterialClipmapDetail>();
	}
	Terrain3DMaterialClipmapDetail::Config config;
	config.tile_size = _vt.detail_tile_size;
	// The gutter is shared with the ring and the pages: one setting for "how far a filtering
	// footprint may reach past the texels a tile owns", which is why it is not a detail setting.
	config.border = _vt.vt_page_border;
	config.density = _vt.detail_density;
	config.directory_size = _vt.detail_directory_size;
	config.budget_bytes = _vt.detail_budget_bytes;
	config.demand_radius = _vt.detail_demand_radius;
	config.texels_per_pixel = _vt.detail_texels_per_pixel;
	// The layer's source workers are the shared setting: the pipeline is a page pipeline, and its
	// cost profile is the same question whoever it feeds.
	config.source_workers = _vt.vt_page_workers;
	// Levels: the finest is the requested density and the coarsest is the first that would fall
	// below `detail_min_density`. That is what makes the fringe a density step rather than the
	// finest level stretched over metres, and it is why a level count is not a user setting.
	int levels = 1;
	real_t density = config.density;
	while (levels < Terrain3DMaterialClipmapDetail::MAX_LEVELS && density * 0.5f >= _vt.detail_min_density) {
		density *= 0.5f;
		levels++;
	}
	config.levels = levels;
	_vt.material_detail->configure(config);
	_vt.material_detail_state = _vt.material_detail->get_state_stamp();
	const bool enabled = _vt.material_detail->is_enabled();
	if (!enabled) {
		// The budget could not afford a slot table. The message is the manager's; this is the
		// node-level statement that the coarse ring is what serves instead.
		LOG(WARN, "Detail material layer is off; the coarse ring serves the near field.");
	}
	return enabled;
}

void Terrain3D::_update_vt_material_detail() {
	_vt.detail_requested_tiles = 0;
	_vt.detail_starved_tiles = 0;
	_vt.vt_detail_ms = 0.0;
	Terrain3DMaterialClipmapDetail *detail = _vt.material_detail.get();
	if (detail == nullptr || !detail->is_enabled()) {
		return;
	}
	// The source snapshot is the pages' and the layer's one source of truth; the pages build it in
	// `_configure_vt_service()`, which returns early when no view exists - and "no view, material on
	// the ring" is exactly the configuration this layer is for. Filling it here is what lets the
	// layer prepare sources in that case; every edit resets it, so a stale snapshot is not a hazard.
	if (!_vt.vt_source_snapshot && _data != nullptr) {
		_vt.vt_source_snapshot = Terrain3DPagePipeline::snapshot(_data, _region_size, _vertex_spacing,
				_surface_density);
	}
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	Terrain3DMaterialClipmapDetail::DemandView view;
	const Vector3 target = get_clipmap_target_position();
	view.focus = v3v2(target);
	view.viewport_height = 1080;
	view.texels_per_pixel = _vt.detail_texels_per_pixel;
	if (Camera3D *camera = get_camera()) {
		// The fragment-side camera: it is the position and direction the band rule in the shader
		// measures with (`v_camera_pos`), so the demand walk and the fragment's own footprint agree.
		const Vector3 position = camera->get_global_position();
		view.focus = Vector2(position.x, position.z);
		const Vector3 forward = -camera->get_global_transform().basis.get_column(2);
		const Vector2 flat(forward.x, forward.z);
		if (flat.length_squared() > 1e-8f) {
			view.forward = flat.normalized();
		}
		view.fov_y = Math::deg_to_rad(camera->get_fov());
		if (Viewport *viewport = camera->get_viewport()) {
			const Vector2 size = viewport->get_visible_rect().size;
			if (size.y >= 1.f) {
				view.viewport_height = int(size.y);
			}
		}
	}
	_vt.detail_requested_tiles = detail->update(view, _vt.vt_source_snapshot, _vt.clipmap_budget_texels);
	_vt.detail_starved_tiles = detail->get_starved_tiles();
	if (Terrain3DSurfaceBaker *surface_baker = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr())) {
		// The offers are charged in *stored texels* a tile (`stored_size^2`, one channel), while the
		// budget below is the ring's channel-texel budget: the two are different units. Measured, the
		// `* 4` admits **three tiles a tick**, not the "one ring tick's worth" the comment above
		// claims (4 * 65,536 = 262,144 and a tile costs 70,756 stored texels: 3 * 70,756 = 212,268,
		// the fourth does not fit). 238 demanded tiles / 3 a tick = ~79 ticks, which is the ~211
		// frames the load probe reports for the near material's detail half - the largest single item
		// in that load, and a *throughput* bound rather than a cost bound (0.29 ms of CPU a tick).
		// Sixteen times the ring's budget admits 14 tiles a tick (14 * 70,756 = 990,584 <= 1,048,576)
		// and fills the same demand in ~23 frames: the same tiles, density, slot table and thresholds,
		// with no fallback and no quality change. The layer is still bounded by its own slot table,
		// and the offer remains a soft floor of one tile a tick.
		surface_baker->queue_detail_tiles(detail, _vt.clipmap_budget_texels * 16);
	}
	_vt.vt_detail_ms = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	_update_vt_detail_arm();
}

bool Terrain3D::_vt_detail_state_changed() {
	const Terrain3DMaterialClipmapDetail *detail = _vt.material_detail.get();
	const uint64_t stamp = detail != nullptr ? detail->get_state_stamp() : 0;
	if (stamp == _vt.material_detail_state) {
		return false;
	}
	_vt.material_detail_state = stamp;
	return true;
}

void Terrain3D::_update_vt_detail_arm() {
	if (!_vt_detail_state_changed()) {
		return;
	}
	if (_initialized && _material.is_valid()) {
		_material->update_vt_clipmap_uniforms();
	}
}

Dictionary Terrain3D::get_vt_detail_arm() const {
	const Terrain3DMaterialClipmapDetail *detail = _vt.material_detail.get();
	return detail != nullptr ? detail->get_arm() : Dictionary();
}

int Terrain3D::sample_vt_detail_level(const Vector2 &p_world_xz) const {
	const Terrain3DMaterialClipmapDetail *detail = _vt.material_detail.get();
	return detail != nullptr ? detail->level_at(p_world_xz) : -1;
}

real_t Terrain3D::sample_vt_detail(const Vector2 &p_world_xz) const {
	const Terrain3DMaterialClipmapDetail *detail = _vt.material_detail.get();
	return detail != nullptr ? detail->density_at(p_world_xz) : 0.f;
}

int Terrain3D::invalidate_vt_detail_area(const AABB &p_area) {
	Terrain3DMaterialClipmapDetail *detail = _vt.material_detail.get();
	if (detail == nullptr || !detail->is_enabled()) {
		return 0;
	}
	const Vector2 origin(p_area.position.x, p_area.position.z);
	const Rect2 rect(origin, Vector2(p_area.size.x, p_area.size.z));
	const int touched = detail->invalidate_rect(rect);
	if (touched > 0) {
		_update_vt_detail_arm();
	}
	return touched;
}

Dictionary Terrain3D::get_vt_detail_settings() const {
	Dictionary result;
	result["enabled_setting"] = _vt.detail_enabled;
	result["density"] = _vt.detail_density;
	result["min_density"] = _vt.detail_min_density;
	result["tile_size"] = _vt.detail_tile_size;
	result["directory_size"] = _vt.detail_directory_size;
	result["budget_bytes_setting"] = int64_t(_vt.detail_budget_bytes);
	result["demand_radius"] = _vt.detail_demand_radius;
	result["texels_per_pixel"] = _vt.detail_texels_per_pixel;
	result["exists"] = _vt.material_detail != nullptr;
	// The acceptance reading of the layer, under the names the 1024 density test takes (a `detail`
	// dictionary inside the material ring's entry): `enabled` is whether the layer is on *and* usable,
	// `requested_density` is the level-0 density that was asked for, and `delivered_density` is the
	// density the directory actually answers at the focus of the last demand walk - a reading of
	// resident, generation-matched, baked content rather than of a setting. `missing_tiles` counts the
	// demanded tiles no fragment can read yet, `fallback_tiles` the ones the coarse ring serves because
	// the budget could not hold them, and `cache_bytes` what the arrays occupy. They are written here
	// as well as beside the layer's own keys so one dictionary satisfies both the panel and the test.
	result["enabled"] = false;
	result["requested_density"] = _vt.detail_density;
	result["delivered_density"] = 0.0;
	result["delivered_density_focus"] = _vt.material_detail != nullptr ? _vt.material_detail->get_last_focus()
																	 : Vector2();
	result["missing_tiles"] = 0;
	result["fallback_tiles"] = 0;
	result["cache_bytes"] = int64_t(0);
	const Terrain3DMaterialClipmapDetail *detail = _vt.material_detail.get();
	if (detail == nullptr) {
		result["active"] = false;
		result["requested_tiles"] = 0;
		result["starved_tiles"] = 0;
		result["vt_detail_ms"] = 0.0;
		return result;
	}
	result["active"] = detail->is_enabled();
	result["enabled"] = detail->is_enabled();
	// The density a fragment at the focus would be served, through the same directory lookup the
	// shader does. A layer whose tiles are still baking reads 0 or a coarser level here, which is the
	// whole point of reporting a delivered number instead of the requested one.
	result["delivered_density"] = detail->density_at(detail->get_last_focus());
	result["missing_tiles"] = detail->get_pending_count() + detail->get_starved_tiles();
	result["fallback_tiles"] = detail->get_starved_tiles();
	result["cache_bytes"] = detail->get_used_bytes();
	result["levels"] = detail->get_level_count();
	result["tile_size"] = detail->get_tile_size();
	result["border"] = detail->get_border();
	result["stored_size"] = detail->get_stored_size();
	result["directory_bytes"] = int64_t(detail->get_directory_bytes());
	result["bytes_per_slot"] = int64_t(detail->bytes_per_slot());
	result["slot_count"] = detail->get_slot_count();
	result["used_bytes"] = int64_t(detail->get_used_bytes());
	result["budget_bytes"] = int64_t(detail->get_budget_bytes());
	result["resident_tiles"] = detail->get_used_slots();
	result["valid_tiles"] = detail->get_valid_count();
	result["pending_tiles"] = detail->get_pending_count();
	result["starved_tiles"] = detail->get_starved_tiles();
	result["requested_tiles"] = _vt.detail_requested_tiles;
	result["vt_detail_ms"] = _vt.vt_detail_ms;
	result["hit_tiles"] = int64_t(detail->get_hit_count());
	result["miss_tiles"] = int64_t(detail->get_miss_count());
	result["evictions"] = int64_t(detail->get_evictions());
	result["source_uploads"] = int64_t(detail->get_source_uploads());
	result["bake_offers"] = int64_t(detail->get_bake_offers());
	result["bake_acks"] = int64_t(detail->get_bake_acks());
	result["bake_rejects"] = int64_t(detail->get_bake_rejects());
	result["invalidation_calls"] = int64_t(detail->get_invalidation_calls());
	result["invalidated_tiles"] = int64_t(detail->get_invalidated_tiles());
	result["directory_publishes"] = int64_t(detail->get_directory_publishes());
	result["budget_report"] = detail->get_budget_report();
	// The per-level density the level rule resolves to, so a reader can see the 1024 target beside
	// what each level actually is without re-deriving it.
	PackedFloat32Array level_density;
	PackedFloat32Array level_tile_world;
	for (int level = 0; level < detail->get_level_count(); level++) {
		level_density.push_back(detail->get_level_texels_per_meter(level));
		level_tile_world.push_back(detail->get_level_tile_world(level));
	}
	result["level_density"] = level_density;
	result["level_tile_world"] = level_tile_world;
	if (Terrain3DSurfaceBaker *surface_baker = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr())) {
		result["bake"] = surface_baker->get_detail_bake_stats();
	}
	return result;
}

void Terrain3D::set_vt_detail_enabled(const bool p_enabled) {
	if (p_enabled == _vt.detail_enabled) {
		return;
	}
	_vt.detail_enabled = p_enabled;
	_setup_vt_material_detail();
	if (_initialized && _material.is_valid()) {
		_material->update_vt_clipmap_uniforms();
	}
	if (p_enabled && has_vt_delivery() && _initialized) {
		set_physics_process(true);
	}
}

void Terrain3D::set_vt_detail_density(const real_t p_texels_per_meter) {
	// A density is a positive number of texels per metre. Zero or negative is refused rather than
	// clamped: a level with no texels is not a coarser layer, it is not a layer.
	if (p_texels_per_meter <= 0.f || Math::is_equal_approx(p_texels_per_meter, _vt.detail_density)) {
		return;
	}
	_vt.detail_density = p_texels_per_meter;
	if (_vt.detail_min_density > p_texels_per_meter) {
		_vt.detail_min_density = p_texels_per_meter;
	}
	_setup_vt_material_detail();
}

void Terrain3D::set_vt_detail_min_density(const real_t p_texels_per_meter) {
	if (p_texels_per_meter <= 0.f || Math::is_equal_approx(p_texels_per_meter, _vt.detail_min_density)) {
		return;
	}
	// The floor cannot be above the target: a layer whose coarsest level is finer than its finest
	// has no level rule at all, so the request is clamped to the target instead.
	_vt.detail_min_density = MIN(p_texels_per_meter, _vt.detail_density);
	_setup_vt_material_detail();
}

void Terrain3D::set_vt_detail_tile_size(const int p_texels) {
	if (p_texels <= 0 || p_texels == _vt.detail_tile_size) {
		return;
	}
	_vt.detail_tile_size = p_texels;
	_setup_vt_material_detail();
}

void Terrain3D::set_vt_detail_directory_size(const int p_texels) {
	if (p_texels <= 0 || p_texels == _vt.detail_directory_size) {
		return;
	}
	_vt.detail_directory_size = p_texels;
	_setup_vt_material_detail();
}

void Terrain3D::set_vt_detail_budget_bytes(const int p_bytes) {
	// Not a shape: the layer keeps its content when the budget changes in the policy sense, but a
	// derived slot table cannot be resized in place, so the manager rebuilds. Zero is a legal
	// "spend nothing", which turns the layer off with a report rather than allocating a slot table
	// it cannot afford.
	_vt.detail_budget_bytes = MAX(0, p_bytes);
	_setup_vt_material_detail();
}

void Terrain3D::set_vt_detail_demand_radius(const real_t p_metres) {
	// Policy, not shape: the manager's `configure()` takes the fast path for it (nothing resident
	// moves), so this reaches the next demand walk without evicting a tile.
	_vt.detail_demand_radius = CLAMP(p_metres, real_t(0.25), real_t(4096));
	_setup_vt_material_detail();
}

void Terrain3D::set_vt_detail_texels_per_pixel(const real_t p_texels) {
	// Policy as well: the screen-footprint target the level rule is derived from.
	_vt.detail_texels_per_pixel = CLAMP(p_texels, real_t(0.25), real_t(64));
	_setup_vt_material_detail();
}
