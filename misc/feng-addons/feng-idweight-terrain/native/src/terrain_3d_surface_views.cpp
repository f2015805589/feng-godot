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
#include "terrain_3d_clipmap_source_material.h"
#include "terrain_3d_surface_baker.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport.hpp>

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
		return "the height channel is delivered directly or by the clipmap ring; AVT and SVT page the diffuse+normal group";
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

// The ring's one owner, called by the assembly rule. Which *source* carries a group is the whole of
// the difference between the rings: the addressing, the levels, the strips and the budget are one
// object for either group, so a second channel is a source and the line above rather than a second
// clipmap implementation - and the shape it is configured with is the source's own declaration, not
// a number written here.
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
		std::unique_ptr<Terrain3DClipmapSource> source = _make_clipmap_source(p_group);
		if (source == nullptr) {
			// The matrix refuses a method this build cannot deliver (`is_vt_delivery_supported()`),
			// so this branch is reached by `debug_update_vt_clipmap()` asking for a channel no source
			// carries. It says so per call and per group rather than handing back a ring nothing
			// could produce.
			LOG(WARN, "Clipmap has no source for the ", TerrainVT::group_channel_name(p_group),
					" channel in this build; it stays direct.");
			return false;
		}
		LOG(DEBUG, "Creating ", source->get_source_name(), " clipmap ring");
		_vt.clipmap[index] = std::make_unique<Terrain3DClipmap>(std::move(source));
	}
	Terrain3DClipmap::Config config;
	config.size = _vt.clipmap_size;
	config.levels = _vt.clipmap_levels;
	config.base_world = _vt.clipmap_base_world;
	// The channel's shape is the channel's: the ring is told how many scalars a texel holds and what
	// one value's format is, and no line here knows whether they are heights or anything else.
	config.channels = _vt.clipmap[index]->get_source_channel_count();
	config.format = _vt.clipmap[index]->get_source_format();
	// And what a producer bakes out of those texels, if the channel has one: the ring allocates the
	// layers here and the bake itself belongs to the owner (`Terrain3D::_bake_clipmap_rings()`), so a
	// channel with no bake declares zero and its ring is only what its source fills.
	config.baked_channels = _vt.clipmap[index]->get_source_baked_channel_count();
	config.baked_format = _vt.clipmap[index]->get_source_baked_format();
	_vt.clipmap[index]->configure(config);
	if (config.baked_channels > 0 && !_vt.vt_materials_published) {
		// The bake reads the surface *material list*, which the page path publishes to the producer
		// whenever the assets change. A ring that declares baked layers is a consumer of that list
		// exactly like a page is, and without this the list is never published in a configuration whose
		// material group takes no page at all - which is the configuration a ring is selected for.
		//
		// *Once*, though: this runs on every write to the matrix, and asking for the list again is not
		// free - the service answers a publish by telling every ring its baked layers are stale, which
		// queues a whole level per ring. A ring that needs the list because the list was never there is
		// the case this covers; a ring that already has it is re-baked only when the assets change,
		// which is the service's own trigger.
		_vt.vt_materials_dirty = true;
		_vt.vt_materials_published = true;
	}
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

///////////////////////////
// The clipmap atlas
///////////////////////////
//
// The same rings as `Terrain3DClipmap`, organised as discrete blocks packed into one texture per
// channel (`terrain_3d_clipmap_atlas.h`), and built by the same assembly rule for the same reason:
// which *source* carries a group is the whole of the difference, so a second channel is a source and
// a line here rather than a second atlas.
//
// **It is a mechanism before it is a delivery, exactly as the ring was.** The atlas's own entry is
// `debug_update_vt_clipmap_atlas()`, beside `debug_update_vt_clipmap()` and for the same reason: the
// addressing, the block layout, the rolling counters, the per-frame timeline and the texture still
// have to be *measurable* - `native/tests/vt_clipmap_atlas` and `native/tests/vt_clipmap_load` are
// nothing but those readings - and a cell has no arm for it yet, so no cell may name it. What it
// already answers is the load question: a ring publishes a whole `size x size` layer per movement, an
// atlas publishes the block rects that changed, and the two are measured side by side by one script.
bool Terrain3D::has_vt_clipmap_atlas() const {
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		if (_vt.clipmap_atlas[group] != nullptr) {
			return true;
		}
	}
	return false;
}

bool Terrain3D::_setup_vt_clipmap_atlas(const TerrainVT::ChannelGroup p_group) {
	if (_data == nullptr) {
		return false;
	}
	const int index = int(p_group);
	if (_vt.clipmap_atlas[index] == nullptr) {
		std::unique_ptr<Terrain3DClipmapSource> source = _make_clipmap_source(p_group);
		if (source == nullptr) {
			return false;
		}
		LOG(DEBUG, "Creating ", source->get_source_name(), " clipmap atlas");
		_vt.clipmap_atlas[index] = std::make_unique<Terrain3DClipmapAtlas>(std::move(source));
	}
	Terrain3DClipmapAtlas::Config config;
	// The block is `clipmap_size` texels of `clipmap_base_world` metres, so ring `r`'s block is
	// `clipmap_size >> r` texels of the *same* world size: the density ladder the ring's levels have,
	// with the shells nested instead of laid over each other. The settings that shape a ring shape an
	// atlas the same way, so a user who tuned one has tuned the other.
	config.block_size = _vt.clipmap_size;
	config.rings = CLAMP(_vt.clipmap_atlas_rings, 1, Terrain3DClipmapAtlas::MAX_RINGS);
	config.base_world = _vt.clipmap_base_world;
	config.channels = _vt.clipmap_atlas[index]->get_source_channel_count();
	config.format = _vt.clipmap_atlas[index]->get_source_format();
	config.global_texels = _vt.clipmap_atlas_global_texels;
	config.blocks_per_frame = _vt.clipmap_atlas_blocks_per_frame;
	_vt.clipmap_atlas[index]->configure(config);
	return true;
}

// The atlas's own arm: the rect array, the per-cell current-frame index, the per-ring start point and
// phase, and the grid's shape. The shader's copy of the block addressing has to be the *same* numbers
// the CPU's is, so the two are one publish - the same rule the ring's arm follows.
Dictionary Terrain3D::get_vt_clipmap_atlas_arm(const int p_group) const {
	Dictionary arm;
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return arm;
	}
	const Terrain3DClipmapAtlas *atlas = _vt.clipmap_atlas[p_group].get();
	if (atlas == nullptr || !atlas->is_configured()) {
		return arm;
	}
	const int rings = atlas->get_rings();
	const int cells = atlas->get_cell_count();
	const int slots = atlas->get_slot_count();
	PackedVector2Array starts;
	PackedVector4Array rects;
	PackedInt32Array cell_slots;
	PackedVector2Array cell_offsets;
	PackedFloat32Array cell_current;
	starts.resize(rings);
	rects.resize(slots);
	cell_slots.resize(cells);
	cell_offsets.resize(cells);
	cell_current.resize(cells);
	for (int ring = 0; ring < rings; ring++) {
		starts[ring] = atlas->get_grid_origin(ring);
	}
	for (int slot = 0; slot < slots; slot++) {
		const Rect2i rect = atlas->get_slot_rect(slot);
		rects[slot] = Vector4(real_t(rect.position.x), real_t(rect.position.y),
				real_t(rect.size.x), real_t(rect.size.y));
	}
	for (int cell = 0; cell < cells; cell++) {
		cell_slots[cell] = atlas->get_cell_slot(cell);
		const Vector2i offset = atlas->get_cell_offset(cell);
		cell_offsets[cell] = Vector2(real_t(offset.x), real_t(offset.y));
		cell_current[cell] = atlas->is_cell_current(cell) ? 1.f : 0.f;
	}
	arm["configured"] = true;
	arm["texture"] = atlas->get_texture_rid();
	arm["block_size"] = atlas->get_config().block_size;
	arm["block_world"] = atlas->get_config().base_world;
	arm["rings"] = rings;
	arm["grid_side"] = atlas->get_config().rings * 2 + 1;
	arm["cells"] = cells;
	arm["slots"] = slots;
	arm["channels"] = atlas->get_channel_count();
	arm["width"] = atlas->get_atlas_width();
	arm["height"] = atlas->get_atlas_height();
	arm["starts"] = starts;
	arm["rects"] = rects;
	arm["cell_slots"] = cell_slots;
	arm["cell_offsets"] = cell_offsets;
	arm["cell_current"] = cell_current;
	return arm;
}

// The mechanism's own entry, beside `debug_update_vt_clipmap()` and the same shape: the same focus
// (`get_clipmap_target_position()`), the same `vt_clipmap_budget_texels`, and the same two published
// numbers, so a panel or a test reads the atlas through the one report either way.
int Terrain3D::debug_update_vt_clipmap_atlas(const int p_group) {
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return -1;
	}
	if (!_setup_vt_clipmap_atlas(TerrainVT::ChannelGroup(p_group))) {
		_vt.clipmap_atlas_produced_texels = 0;
		return -1;
	}
	Terrain3DClipmapAtlas *atlas = _vt.clipmap_atlas[p_group].get();
	if (atlas == nullptr) {
		_vt.clipmap_atlas_produced_texels = 0;
		return -1;
	}
	const Vector2 focus = v3v2(get_clipmap_target_position());
	_vt.clipmap_atlas_produced_texels = atlas->update(focus, _vt.clipmap_budget_texels);
	// The rolling evidence, read straight off the mechanism: how many blocks a scroll loaded and how
	// many cells kept their content. It is published rather than kept local because "only the edge
	// reloads" is a claim the acceptance asks to see as a number.
	_vt.clipmap_atlas_block_uploads = int64_t(atlas->get_block_uploads());
	_vt.clipmap_atlas_scroll_events = int64_t(atlas->get_scroll_events());
	_vt.clipmap_atlas_blocks_loaded = int64_t(atlas->get_edge_blocks_loaded());
	_vt.clipmap_atlas_blocks_retained = int64_t(atlas->get_interior_blocks_retained());
	return _vt.clipmap_atlas_produced_texels;
}

// Whether any atlas exists, for the debug view's gate: the same rule the ring's gate follows, so a
// picture of an atlas is a picture of an object that exists rather than of a selection.
bool Terrain3D::clipmap_atlas_available() const {
	return has_vt_clipmap_atlas();
}

// The debug view's payload for the atlas: the layout the packer chose, the ring/block counts, every
// rect, and every cell's current-frame index - the user's "the debug should show the atlas's region".
Dictionary Terrain3D::get_clipmap_atlas_layout(const int p_group) const {
	Dictionary result;
	_vt.clipmap_atlas_preview_calls++;
	if (p_group < 0 || p_group >= TerrainVT::GROUP_COUNT) {
		return result;
	}
	const Terrain3DClipmapAtlas *atlas = _vt.clipmap_atlas[p_group].get();
	if (atlas == nullptr || !atlas->is_configured()) {
		return result;
	}
	_vt.clipmap_atlas_preview_computed++;
	result["group"] = String(TerrainVT::group_name(TerrainVT::ChannelGroup(p_group)));
	result["source"] = atlas->get_source_name();
	result["focus"] = atlas->get_focus();
	result["produced_texels"] = int64_t(atlas->get_produced_texels());
	result["upload_bytes"] = int64_t(atlas->get_upload_bytes());
	result["block_uploads"] = int64_t(atlas->get_block_uploads());
	result["pending_jobs"] = atlas->get_pending_jobs();
	result["rings"] = atlas->get_ring_reports();
	result["layout"] = atlas->get_layout_report();
	result["timeline"] = atlas->get_load_timeline();
	result["scroll_events"] = int64_t(atlas->get_scroll_events());
	result["blocks_loaded"] = int64_t(atlas->get_edge_blocks_loaded());
	result["blocks_retained"] = int64_t(atlas->get_interior_blocks_retained());
	result["last_scroll_loaded"] = int64_t(atlas->get_last_scroll_loaded());
	result["last_scroll_retained"] = int64_t(atlas->get_last_scroll_retained());
	result["state_stamp"] = int64_t(atlas->get_state_stamp());
	return result;
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

// The three atlas settings. None of them is a delivery: the atlas is built and driven through
// `debug_update_vt_clipmap_atlas()`, so a write here is a *shape* write and the next reading picks it
// up. `rings` and `global_texels` are clamped by `configure()`, so a value outside the structure the
// header states is refused there with a log rather than accepted and mis-laid-out.
void Terrain3D::set_vt_clipmap_atlas_rings(const int p_rings) {
	if (p_rings <= 0) {
		return;
	}
	_vt.clipmap_atlas_rings = p_rings;
}

void Terrain3D::set_vt_clipmap_atlas_global_texels(const int p_texels) {
	if (p_texels <= 0) {
		return;
	}
	_vt.clipmap_atlas_global_texels = p_texels;
}

void Terrain3D::set_vt_clipmap_atlas_blocks_per_frame(const int p_blocks) {
	// 0 is refused rather than clamped: a per-frame bound of zero is a mechanism that never loads.
	if (p_blocks <= 0) {
		return;
	}
	_vt.clipmap_atlas_blocks_per_frame = p_blocks;
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
	PackedVector4Array outstanding;
	PackedInt32Array outstanding_counts;
	centers.resize(Terrain3DClipmap::MAX_LEVELS);
	rings.resize(Terrain3DClipmap::MAX_LEVELS);
	valid.resize(Terrain3DClipmap::MAX_LEVELS);
	outstanding_counts.resize(Terrain3DClipmap::MAX_LEVELS);
	// One entry per level per rect, in the shape the shader's table has, so the arm's per-tap gate is a
	// lookup rather than a search: the rects of *stored* texels a reader must not serve from the baked
	// layers right now (un-baked, or still being produced). A level with nothing outstanding publishes
	// zeroes and a count of zero, and an unused entry stays zero as well.
	outstanding.resize(Terrain3DClipmap::MAX_LEVELS * Terrain3DClipmap::MAX_OUTSTANDING_RECTS);
	for (int level = 0; level < levels; level++) {
		const Terrain3DClipmap::Level &entry = ring->get_level(level);
		centers[level] = entry.center;
		rings[level] = Vector2(real_t(entry.ring.x), real_t(entry.ring.y));
		valid[level] = entry.valid ? 1.f : 0.f;
		Terrain3DClipmap::BakeRect rects[Terrain3DClipmap::MAX_OUTSTANDING_RECTS];
		const int count = ring->get_outstanding_rects(level, rects,
				Terrain3DClipmap::MAX_OUTSTANDING_RECTS);
		outstanding_counts[level] = count;
		for (int index = 0; index < count; index++) {
			outstanding[level * Terrain3DClipmap::MAX_OUTSTANDING_RECTS + index] = Vector4(
					real_t(rects[index].x0), real_t(rects[index].y0), real_t(rects[index].x1),
					real_t(rects[index].y1));
		}
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
	arm["outstanding"] = outstanding;
	arm["outstanding_counts"] = outstanding_counts;
	// The arrays a producer bakes out of the ring's own texels, when the channel declares them: what
	// the material arm samples where a level is baked, one layer per level. A ring whose channel
	// declares none publishes none, and the arm's names are bound to the dummy array instead - the
	// rule the atlas above follows.
	if (ring->get_baked_channel_count() >= 3) {
		arm["baked_albedo"] = ring->get_baked_texture_rid(0);
		arm["baked_normal"] = ring->get_baked_texture_rid(1);
		arm["baked_params"] = ring->get_baked_texture_rid(2);
	}
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

// The mechanism's own entry, beside the read above, and the reason it exists: a group with no source
// this build cannot deliver has no matrix door (`is_vt_delivery_supported()` reads
// `has_clipmap_source()`), so no cell can name the method and the tick never enters its phase for it.
// The ring's addressing, strips, budget and content still have to be measurable - `native/tests/vt_clipmap`
// is nothing but those readings - so this runs exactly what that phase runs: the same
// `Terrain3DClipmap::update()`, with the same focus (`get_clipmap_target_position()`) and the same
// `vt_clipmap_budget_texels`, over the rings the caller names rather than the rings a cell selected.
// It publishes the same two numbers the phase publishes, so a panel or a test reads the mechanism
// through the one report either way, and it is also how a ring is built for a group a cell *may* name
// but does not (the mechanism's own tests drive every cell `Direct`).
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
	Terrain3DClipmap *ring = _vt.clipmap[p_group].get();
	if (ring == nullptr) {
		_vt.clipmap_produced_texels = 0;
		return -1;
	}
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	const Vector2 focus = v3v2(get_clipmap_target_position());
	_vt.clipmap_produced_texels = ring->update(focus, _vt.clipmap_budget_texels);
	// The tests drive the ring through this entry, so the bake is offered here too: a ring whose rects
	// are never offered to a producer reports `baked` false for the rest of the session, which is a
	// state only a caller that forgot the offer can produce.
	if (Terrain3DSurfaceBaker *baker = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr())) {
		baker->queue_clipmap_ring(ring, _vt.clipmap_budget_texels);
	}
	_vt.vt_clipmap_ms = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	// The same rebind the tick's phase does, so a ring a test or the dock drove with this entry is
	// the ring the shader reads.
	_update_vt_clipmap_arm();
	return _vt.clipmap_produced_texels;
}

///////////////////////////
// The material group's detail layer
///////////////////////////
//
// A sparse, demand-resident layer of fine tiles over the coarse ring, and the only path to the 1024
// texels/m the near material field is measured at. The mechanism is
// `Terrain3DMaterialClipmapDetail`; this is its one owner on the node: the lifetime, the settings,
// the demand view built from the camera, the tick hook, and the arm the material binds.
//
// **Why it is a layer and not a denser ring.** The ring is one dense level per octave, so its finest
// level covers `base_world` metres: making that 1024 texels/m with a 256-texel axis would cover
// 0.25 m, and the 1.6 m probe would fall several levels up - the ring's low density is a *shape*
// property, not a setting that is merely set too coarse. The detail layer spends its bytes where the
// screen footprint asks for them, keeps the ring's complete coverage and fallback underneath, and
// owns nothing when the material group does not select Clipmap.
//
// **Selection.** `_setup_vt_material_detail()` is the one owner of the layer's lifetime and is called
// from the assembly rule (so a cell write creates or frees it with the ring) and from every setting
// setter. `_update_vt_material_detail()` is the tick, called from `terrain_3d.cpp`'s clipmap phase -
// the one production pass every tick a cell selects `Clipmap` runs - where the ring's production and
// its bake offer already live; it builds the screen-footprint demand view from the live camera, runs
// the layer's update, and offers the layers' landed tiles to the producer. Its outstanding work is
// counted by `_vt_has_streaming_work()` so a still-baking tile keeps the editor drawing.

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
		view.height = MAX(real_t(0.1), position.y - target.y);
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
		// The ring's texel budget is a tick's worth of *ring* work, and one detail tile is a whole
		// small array at the same cost, so that budget admits exactly one tile a tick: the near field
		// took seconds to fill after a move, which is a second kind of blur. The offers are spent in
		// tile units and the layer is bounded by its own slot table, so asking for a multiple of the
		// ring's budget fills the near field in a few frames without changing what one ring tick
		// produces.
		surface_baker->queue_detail_tiles(detail, _vt.clipmap_budget_texels * 4);
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
