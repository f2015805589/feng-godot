// Copyright © 2026 Terrain3D contributors.

// The virtual texture service, part 1 of 4: the settings and the service's lifetime.
//
// Everything a dock, a script or the editor inspector writes to size the shared service - the
// page size, border and count, the source workers, the motion lead, the resolution preset, both
// tiers' storage format, the feedback toggles and the editor preview - and what creates the
// service (`_configure_vt_service()`), what keeps it honest once per tick
// (`_vt_has_pending_upload()`, `_vt_has_streaming_work()`, `_update_vt_service()`) and what tears
// it down (`_destroy_vt_service()`). A demand pass never runs without a page table because this
// is what guarantees it.
//
// The other halves: terrain_3d_vt_service_pages.cpp (page plumbing and the cell store),
// terrain_3d_vt_service_report.cpp (the diagnostics) and terrain_3d_vt_service_bake.cpp (the far
// field's bake and its cell files).

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_vt_service_internal.h"
#include "terrain_3d_virtual_texture.h"

#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/engine.hpp>

#include <cmath>

// The two helpers the four halves share; see terrain_3d_vt_service_internal.h for what it holds
// and why it is a header.
using namespace terrain_surface_vt;

void Terrain3D::set_surface_vt_resolution(int p_resolution) {
	ERR_FAIL_COND(p_resolution != 512 && p_resolution != 1024 && p_resolution != 2048 && p_resolution != 4096);
	// A block has a power-of-two page count (at most 64). Normalize legacy
	// non-power-of-two page sizes so the displayed virtual resolution is exact.
	int page_size = MAX(16, p_resolution / 64);
	while (page_size * 2 <= MIN(_vt.vt_page_size, p_resolution)) {
		page_size *= 2;
	}
	set_vt_page_size(page_size);
	set_surface_vt_pages_per_axis(p_resolution / page_size);
	// With unchanged physical dimensions, demand resizes the virtual block and
	// retains ready ancestors; selecting a resolution must not flush the cache.
	notify_property_list_changed();
}

void Terrain3D::set_vt_page_size(int p_size) {
	p_size = CLAMP(p_size, 16, 1024);
	if (_vt.vt_page_size == p_size) {
		return;
	}
	const real_t svt_density = get_surface_svt_texels_per_meter();
	_vt.vt_page_size = p_size;
	_vt.surface_svt_page_world = _vt.vt_page_size / svt_density;
	_reset_vt_configuration();
}
void Terrain3D::set_vt_page_border(int p_border) {
	p_border = CLAMP(p_border, 1, 16);
	if (_vt.vt_page_border == p_border) {
		return;
	}
	_vt.vt_page_border = p_border;
	_reset_vt_configuration();
}

bool Terrain3D::_ensure_vt_capacity(int p_required) {
	Terrain3DSurfaceBaker *producer = _vt.vt_baker.is_valid() ? baker(_vt.vt_baker) : nullptr;
	if (_vt.vt_shared_ready && producer && !_vt.vt_debug_direct_material) {
		const int ready_capacity = producer->get_capacity();
		if (ready_capacity > _vt.vt_page_count) {
			// Publish higher slot IDs only after the GPU cache was copied. Keep
			// addresses, owners and source jobs, including an already completed plan.
			if (!_vt.surface_vt->grow_capacity(ready_capacity) || !_vt.surface_svt->grow_capacity(ready_capacity)) { return false; }
			_vt.vt_page_count = _vt.surface_vt_page_count = _vt.surface_svt_page_count = ready_capacity;
			_vt.pool.grow(ready_capacity);
			if (_material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
			notify_property_list_changed();
			return true;
		}
	}
	const int transition_capacity = p_required + MAX(8, p_required / 2);
	if (!_vt.vt_auto_capacity || transition_capacity <= _vt.vt_page_count || _vt.vt_page_count >= 1024 ||
		_vt.bake.busy()) { return false; }
	int capacity = 8;
	// Leave room for old/new view overlap; capacity never oscillates or shrinks.
	while (capacity < transition_capacity && capacity < 1024) { capacity *= 2; }
	if (_vt.vt_shared_ready && producer && !_vt.vt_debug_direct_material) {
		producer->request_capacity(capacity);
		// Wait, briefly, for the producer to publish the larger arrays: the pool follows them
		// on the next frame or two, and a page produced against the old count is released by
		// that growth. The wait is bounded, so a state that cannot grow the arrays - no
		// material arrays to build, a failed allocation - never stops page production.
		const uint64_t frame = Engine::get_singleton()->get_process_frames();
		if (_vt.pool.waiting_for_capacity(frame, producer->has_pending_capacity())) {
			return true;
		}
		return false;
	}
	set_vt_page_count(capacity);
	notify_property_list_changed();
	return true;
}

void Terrain3D::set_vt_page_count(int p_count) {
	p_count = CLAMP(p_count, 8, 1024);
	if (_vt.vt_page_count == p_count) {
		return;
	}
	_vt.vt_page_count = p_count;
	// An explicit capacity is a request, not a floor: it replaces the auto-grown value.
	_vt.pool.request(p_count);
	_reset_vt_configuration();
}
void Terrain3D::set_vt_pages_per_update(int p_pages) {
	_vt.vt_pages_per_update = CLAMP(p_pages, 1, 16);
}
// A pipeline owns its threads, so a changed worker count is applied by dropping the
// pipelines: every entry in them is in flight work the demand pass re-requests anyway,
// and the alternative - resizing a pool of threads under a running page job - is worse.
void Terrain3D::set_vt_page_workers(int p_workers) {
	p_workers = CLAMP(p_workers, 0, 16);
	if (_vt.vt_page_workers == p_workers) {
		return;
	}
	_vt.vt_page_workers = p_workers;
	_vt.vt_page_pipeline.reset();
	_vt.svt_page_pipeline.reset();
	_vt.svt_pending_pages.clear();
	invalidate_avt_plan_key(_vt.avt_plan.key);
	_vt.avt_refinement.reset();
}
void Terrain3D::set_vt_motion_lead_ms(real_t p_lead) {
	if (!std::isfinite(p_lead)) {
		return;
	}
	_vt.vt_motion_lead_ms = CLAMP(real_t(p_lead), real_t(0), real_t(1000));
	if (_vt.vt_motion_lead_ms <= 0.f) {
		_vt.avt_motion_velocity = Vector2();
		_vt.avt_motion_lead = Vector2();
		_vt.avt_motion_turn = Vector3();
		_vt.avt_motion_turn_lead = Vector3();
	}
	// A lead is part of the plan key, so a change has to be planned again.
	invalidate_avt_plan_key(_vt.avt_plan.key);
}

// Both tiers store the same shared pool, so both settings take the same path: the producer
// rebuilds the arrays in place and bumps its own generation, which makes its next render
// pass replace the bundle in the new format. Reconfiguring the service instead would detach
// both views, release every resident page and grow the pool back to a capacity it had
// already published, which is why a storage decision must not go through it.
void Terrain3D::_apply_vt_tier_compression(const int p_tier, const int p_mode) {
	if (_vt.vt_baker.is_valid()) {
		baker(_vt.vt_baker)->set_tier_compression(p_tier, p_mode);
		// The rebuilt arrays start blank, so the pages produced in the previous format have
		// to be produced again. This is forced: a plain edit is deferred while the editor
		// preview is active, but a format change leaves nothing to fall back on.
		if (_data) {
			for (const Vector2i &region_location : _data->get_region_locations()) {
				invalidate_surface_pages(region_location, true);
			}
		}
		_vt.vt_materials_dirty = true;
		return;
	}
	_reset_vt_configuration();
}

// Page storage, written in the page codec list the inspector offers: the two RGBA block codecs
// the GPU encoder implements, plus the uncompressed staging arrays. That list is shorter than the
// shared texture-array enum, so a value is translated rather than reinterpreted by position:
//
//   * 1 is BC7 in both lists.
//   * 2 is BC3 here and BC1 RGB in the array list, and 3 is BC3 in the array list. Both mean
//     BC3: the page list is the vocabulary this setting is offered in, and a scene that asked
//     for BC1 - which a page cannot be stored in, because BC1 keeps no alpha - lands on a codec
//     that does keep alpha rather than on the uncompressed pages it was given before.
//   * everything else is uncompressed, which is what every other array-list entry resolved to
//     while the page settings still listed it: BC4, BC5 and BC6H keep no alpha, and ETC1, ETC2,
//     EAC and ASTC have no shader encoder.
static int page_codec_from_request(const int p_requested) {
	switch (p_requested) {
		case SURFACE_PAGE_BC7:
			return SURFACE_PAGE_BC7;
		case SURFACE_PAGE_BC3:
		case Terrain3DAssets::ARRAY_BC3:
			return SURFACE_PAGE_BC3;
		default:
			return SURFACE_PAGE_UNCOMPRESSED;
	}
}

void Terrain3D::set_surface_vt_compression(const int p_compression) {
	const int mode = page_codec_from_request(p_compression);
	if (_vt.surface_vt_compression == mode) {
		return;
	}
	if (p_compression != SURFACE_PAGE_UNCOMPRESSED && mode == SURFACE_PAGE_UNCOMPRESSED) {
		LOG(INFO, "Page compression request ", p_compression,
				" has no page codec in this build; pages stay uncompressed");
	}
	_vt.surface_vt_compression = mode;
	_apply_vt_tier_compression(Terrain3DSurfaceBaker::TIER_AVT, mode);
}
int Terrain3D::get_surface_vt_compression() const {
	return _vt.surface_vt_compression;
}

// The far field's sibling. Same contract, and the tier where a codec is worth the most: a
// far-field page is assembled once from a baked cell and never rewritten, so its compressed
// copy is final.
void Terrain3D::set_surface_svt_compression(const int p_compression) {
	const int mode = page_codec_from_request(p_compression);
	if (_vt.surface_svt_compression == mode) {
		return;
	}
	if (p_compression != SURFACE_PAGE_UNCOMPRESSED && mode == SURFACE_PAGE_UNCOMPRESSED) {
		LOG(INFO, "Page compression request ", p_compression,
				" has no page codec in this build; pages stay uncompressed");
	}
	_vt.surface_svt_compression = mode;
	_apply_vt_tier_compression(Terrain3DSurfaceBaker::TIER_SVT, mode);
}
int Terrain3D::get_surface_svt_compression() const {
	return _vt.surface_svt_compression;
}

// Legacy normal overrides no longer select a separate format. Loading them keeps
// the tier codec authoritative, regardless of serialized property order.
void Terrain3D::set_surface_vt_normal_compression(int p_mode) {
	(void)p_mode; // Compatibility input only; the unified tier setting owns storage.
}
int Terrain3D::get_surface_vt_normal_compression() const { return SURFACE_NORMAL_AUTO; }
void Terrain3D::set_surface_svt_normal_compression(int p_mode) {
	(void)p_mode;
}
int Terrain3D::get_surface_svt_normal_compression() const { return SURFACE_NORMAL_AUTO; }

// The near field's setting under its pre-split name.
void Terrain3D::set_vt_atlas_compression(const int p_compression) {
	set_surface_vt_compression(p_compression);
}
int Terrain3D::get_vt_atlas_compression() const {
	return get_surface_vt_compression();
}

void Terrain3D::_reset_vt_configuration() {
	// Old world addresses and channel dimensions cannot survive reconfiguration.
	_cancel_svt_bake("VT configuration changed; run Bake SVT again.");
	_vt.vt_shared_ready = false;
	_vt.svt_startup_ready = false;
	invalidate_vt_materials();
}
void Terrain3D::set_avt_feedback(bool p_enabled) {
	if (_vt.avt_feedback == p_enabled) { return; }
	_vt.avt_feedback = p_enabled;
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
}

// The far field's sibling of the switch above. It only changes what the shader does with
// a miss; residency, demand and production are untouched, so no pool or page has to be
// rebuilt - a uniform update is the whole effect.
void Terrain3D::set_svt_feedback(bool p_enabled) {
	if (_vt.svt_feedback == p_enabled) { return; }
	_vt.svt_feedback = p_enabled;
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
}

void Terrain3D::set_vt_adaptive_enabled(bool p_enabled) {
	_vt.vt_adaptive_enabled = p_enabled;
}
bool Terrain3D::is_vt_editor_preview_active() const {
	return IS_EDITOR && _vt.vt_editor_preview;
}

void Terrain3D::set_vt_editor_preview(bool p_enabled) {
	if (_vt.vt_editor_preview == p_enabled) { return; }
	_vt.vt_editor_preview = p_enabled;
	if (!is_vt_editor_preview_active()) {
		Dictionary dirty = _vt.vt_editor_dirty_regions.duplicate();
		_vt.vt_editor_dirty_regions.clear();
		for (const Variant &location : dirty.keys()) { invalidate_surface_pages(location); }
	}
	if (_data && _initialized) { _data->update_maps(TYPE_MAX, true, false); }
	if (_material.is_valid() && _initialized) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
}

void Terrain3D::set_vt_debug_direct_material(bool p_enabled) {
	if (_vt.vt_debug_direct_material == p_enabled) {
		return;
	}
	_vt.vt_debug_direct_material = p_enabled;
	_destroy_vt_service();
	// Raw-ID diagnostics and material-cache rendering have different residency
	// contracts. Rebuild addresses rather than reusing unuploaded diagnostic IDs.
	if (_vt.surface_vt) { _vt.surface_vt->clear(); }
	if (_vt.surface_svt) { _vt.surface_svt->clear(); }
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

void Terrain3D::_configure_vt_service() {
	if (_vt.vt_debug_direct_material || !_vt.surface_vt || !_vt.surface_svt) {
		return;
	}
	if (_vt.vt_shared_ready) {
		return;
	}
	_vt.svt_startup_ready = false;
	_vt.vt_source_snapshot.reset();
	_vt.avt_refinement.reset();
	invalidate_avt_plan_key(_vt.avt_plan.key);
	if (_vt.vt_page_pipeline) { _vt.vt_page_pipeline->reset(); }
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->reset(); }
	// Detach both views before replacing their common pool. Clearing one view must
	// never destroy a pool that another view is still sampling.
	_reset_vt_page_fade();
	auto pool = Terrain3DVirtualTexture::create_page_pool();
	// Both views adopt the shared dimensions before they are configured, so the one
	// configuration helper describes the view that is actually built. A reconfiguration
	// keeps the capacity that is already published: auto capacity only ever grows, and
	// starting again from the setting would make the demand pass re-grow the pool - which
	// releases every page it had just rebuilt - for no reason.
	const int capacity = CLAMP(MAX(_vt.vt_page_count, _vt.pool.capacity), 8, 1024);
	_vt.vt_page_count = capacity;
	_vt.surface_vt_page_size = _vt.surface_svt_page_size = _vt.vt_page_size;
	_vt.surface_vt_page_border = _vt.surface_svt_page_border = _vt.vt_page_border;
	_vt.surface_vt_page_count = _vt.surface_svt_page_count = capacity;
	for (Terrain3DVirtualTexture *view : { _vt.surface_vt, _vt.surface_svt }) {
		view->clear();
		view->set_page_pool(pool);
		view->set_material_cache_mode(!_vt.vt_debug_direct_material);
		_configure_surface_view(view, view == _vt.surface_svt);
		view->initialize();
	}
	_vt.surface_vt_blocks.clear();
	_vt.surface_vt_block_sizes.clear();
	_vt.surface_vt_blocks_dirty = true;
	_vt.vt_page_records.clear();
	_vt.svt_pending_pages.clear();
	_vt.vt_registered_sectors.clear();
	_vt.avt_directory_bytes.clear();
	// The addresses every page of the standing plan resolved to no longer exist.
	_vt.avt_plan.forget();
	_vt.avt_density_scale = float(_vt.surface_vt_texels_per_pixel);
	_vt.avt_registered_owners.clear();
	_vt.avt_allocated_sizes.clear();
	_vt.avt_cached_addresses.clear();
	_vt.avt_sector_directory.unref();
	_vt.avt_directory_mask = 0;
	_vt.avt_sector_stats.clear();
	if (_vt.vt_baker.is_null()) {
		Ref<Terrain3DSurfaceBaker> instance;
		instance.instantiate();
		_vt.vt_baker = instance;
	}
	baker(_vt.vt_baker)->set_tier_compression(Terrain3DSurfaceBaker::TIER_AVT, _vt.surface_vt_compression);
	baker(_vt.vt_baker)->set_tier_compression(Terrain3DSurfaceBaker::TIER_SVT, _vt.surface_svt_compression);
	baker(_vt.vt_baker)->configure(_vt.vt_page_size, _vt.vt_page_border, capacity);
	_configure_svt_cell_store();
	_vt.bound.clear();
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
	_vt.vt_materials_dirty = true;
	_vt.vt_shared_ready = true;
	// A new pool has no resident page: everything has to be produced again. Callers that
	// only change how a page is stored must not reach this point.
	_vt.pool.rebuilt();
}

bool Terrain3D::_vt_has_pending_upload() const {
	// Either view can own the shared pool, and a commit on one of them is what puts
	// render-thread work in flight.
	return (_vt.surface_vt && _vt.surface_vt->has_pending_indirection()) ||
			(_vt.surface_svt && _vt.surface_svt->has_pending_indirection());
}

// A frame is what runs page production: the producers are called from the render pass, and the
// editor only renders when something has changed. Render work queued in the baker marks that
// change by itself, but a demand that is waiting on a source job, on a free slot, or on the
// page budget has nothing to show for itself - so the editor used to sleep with the miss still
// on screen and only wake for camera input, which is exactly the report that pages do not fill
// in again until the view is moved. Any page a view still owes keeps the editor drawing.
bool Terrain3D::_vt_has_streaming_work() const {
	if (_vt_has_pending_upload()) {
		return true;
	}
	if (_vt.vt_baker.is_valid()) {
		const Terrain3DSurfaceBaker *producer = baker(_vt.vt_baker);
		if (producer && (producer->has_render_work() || producer->materials_stale())) {
			return true;
		}
	}
	if (!_vt.avt_plan.pages.empty() && (_vt.avt_missing_pages > 0 || _vt.avt_pending_pages > 0)) {
		return true;
	}
	if (!_vt.svt_pending_pages.empty() || _vt.bake.busy()) {
		return true;
	}
	if (_vt.vt_page_pipeline) {
		int pages = 0, queued = 0;
		int64_t usec = 0;
		_vt.vt_page_pipeline->get_production_stats(pages, usec, queued);
		if (queued > 0) {
			return true;
		}
	}
	return false;
}

void Terrain3D::_update_vt_service() {
	if (!_vt.surface_svt_enabled) {
		_cancel_svt_bake("SVT was disabled; the offline bake was cancelled.");
	}
	if (!_vt.surface_vt_enabled && !_vt.surface_svt_enabled) {
		if (_vt.vt_callback_registered && RS->has_method("virtual_texture_remove_update_callback")) {
			RS->call("virtual_texture_remove_update_callback", int64_t(get_instance_id()));
			_vt.vt_callback_registered = false;
		}
		return;
	}
	if (_vt.vt_debug_direct_material || !_data || _assets.is_null()) {
		return;
	}
	const uint64_t frame = Engine::get_singleton()->get_process_frames();
	if (_vt.vt_shared_ready && !_vt.vt_materials_dirty && _vt.vt_service_frame == frame) { return; }
	_vt.vt_service_frame = frame;
	_configure_vt_service();
	Terrain3DSurfaceBaker *producer = baker(_vt.vt_baker);
	if (!producer) {
		return;
	}
	if (!_vt.vt_callback_registered && RS->has_method("virtual_texture_set_update_callback")) {
		RS->call("virtual_texture_set_update_callback", int64_t(get_instance_id()),
				Callable(producer, "render_pending").bind(_vt.vt_baker));
		_vt.vt_callback_registered = true;
	} else if (!_vt.vt_callback_registered && !_vt.vt_callback_missing_warned) {
		// Without this API the engine never invokes the material page producer, so no page
		// is ever baked and the near and far fields render from the region texture array.
		// Say so once, instead of leaving page-dependent tests failing for no visible reason.
		_vt.vt_callback_missing_warned = true;
		WARN_PRINT("This engine build has no virtual_texture_set_update_callback; surface material pages cannot be produced. Rebuild the engine from this source tree.");
	}
	producer->set_page_budget(_vt.vt_pages_per_update);
	if (_vt.vt_materials_dirty || producer->materials_stale()) {
		// Also re-publish when the producer reports its snapshot unbound: the arrays it named
		// were freed by a newer asset edit, and publishing the current pair is what recovers,
		// instead of retrying a dead pair every frame.
		producer->set_materials(_assets->get_albedo_array_rid(), _assets->get_normal_array_rid(),
				_assets->get_texture_colors(), _assets->get_texture_normal_depths(),
				_assets->get_texture_ao_strengths(), _assets->get_texture_ao_light_affects(),
				_assets->get_texture_roughness_mods(), _assets->get_texture_uv_scales(),
				_assets->get_texture_detiles(), _assets->get_texture_slope_params());
		Dictionary signature;
		signature["colors"] = _assets->get_texture_colors();
		signature["depths"] = _assets->get_texture_normal_depths();
		signature["ao"] = _assets->get_texture_ao_strengths();
		signature["affect"] = _assets->get_texture_ao_light_affects();
		signature["roughness"] = _assets->get_texture_roughness_mods();
		signature["uv"] = _assets->get_texture_uv_scales();
		signature["detile"] = _assets->get_texture_detiles();
		signature["slope"] = _assets->get_texture_slope_params();
		// Cache identity describes texture content and baking settings, never
		// resource instance IDs or paths. The asset system retains these existing
		// content hashes even after free_editor_textures releases its source list.
		signature["textures"] = _assets->get_texture_cache_identity();
		_vt.vt_material_signature = signature.hash();
		_vt.vt_materials_dirty = false;
		// Re-request old addresses using the current materials; stale pages remain
		// hidden until their producer has completed again.
		for (const Vector2i &location : _data->get_region_locations()) {
			invalidate_surface_pages(location);
		}
	}
	// Rebind on the bundle generation, not on the near field's albedo: the two tiers' arrays
	// are replaced together, so a change that only rebuilt the far field's set - a far-field
	// codec, or a pool resize on a far-field-only scene - must republish as well, or the
	// material keeps sampling arrays the retire below has already released.
	const uint64_t published_generation = producer->get_published_generation();
	RID albedo = producer->get_albedo_rid();
	if (!_vt.bound.matches(published_generation, albedo)) {
		_vt.bound.adopt(published_generation, albedo);
		if (_material.is_valid()) {
			_material->update(Terrain3DMaterial::REGION_ARRAYS);
		}
		// Acknowledged even without a material: the producer releases the arrays it
		// replaced, and none of them is referenced once nothing binds them.
		producer->acknowledge_output(albedo);
	}

	_process_async_svt_pages();
	// The explicit job is done once nothing of it is left, including the cell it was baking; only
	// then may an automatic job take over the progress counters.
	if (_vt.bake.explicit_job && _vt.bake.drained()) {
		_vt.bake.explicit_job = false;
	}
	_process_svt_auto_bake();
	// RD writes and worker completion do not mark RenderingServer as changed.
	// In the editor's low-processor mode that otherwise leaves queued GPU pages
	// waiting forever for camera input. Request a normal (non-blocking) redraw
	// only while work is actually outstanding; never force_draw here.
	if (IS_EDITOR && _vt_has_streaming_work()) {
		Control *editor = EditorInterface::get_singleton()->get_base_control();
		if (editor) { editor->queue_redraw(); }
	}
}

void Terrain3D::_destroy_vt_service() {
	_reset_vt_page_fade();
	if (_vt.surface_vt) { _vt.surface_vt->set_material_cache_mode(false); }
	if (_vt.surface_svt) { _vt.surface_svt->set_material_cache_mode(false); }
	if (_vt.vt_baker.is_valid()) { baker(_vt.vt_baker)->set_cell_store(Ref<Terrain3DCellStore>()); }
	if (_vt.svt_cells.is_valid()) { _vt.svt_cells->clear(); }
	_vt.svt_cell_file_probe.clear();
	_vt.vt_page_pipeline.reset();
	_vt.svt_page_pipeline.reset();
	_vt.svt_pending_pages.clear();
	_vt.vt_source_snapshot.reset();
	_vt.avt_refinement.reset();
	invalidate_avt_plan_key(_vt.avt_plan.key);
	_vt.bake.cell_baker.unref();
	if (_vt.vt_callback_registered && RS && RS->has_method("virtual_texture_remove_update_callback")) {
		RS->call("virtual_texture_remove_update_callback", int64_t(get_instance_id()));
	}
	_vt.vt_callback_registered = false;
	_vt.vt_baker.unref();
	_vt.bound.clear();
	_vt.vt_shared_ready = false;
	_vt.vt_page_records.clear();
	_vt.svt_pending_pages.clear();
	_vt.vt_registered_sectors.clear();
	_vt.bake.queue.clear();
	_vt.bake.waiting.clear();
}

void Terrain3D::_bind_vt_methods() {
#define VT_BIND_SETTING(name) \
	ClassDB::bind_method(D_METHOD("set_" #name, "value"), &Terrain3D::set_##name); \
	ClassDB::bind_method(D_METHOD("get_" #name), &Terrain3D::get_##name)
	VT_BIND_SETTING(vt_page_size);
	VT_BIND_SETTING(vt_page_border);
	VT_BIND_SETTING(vt_page_count);
	VT_BIND_SETTING(vt_auto_capacity);
	VT_BIND_SETTING(vt_pages_per_update);
	VT_BIND_SETTING(vt_frame_budget_ms);
	VT_BIND_SETTING(vt_page_workers);
	VT_BIND_SETTING(vt_motion_lead_ms);
	VT_BIND_SETTING(svt_feedback);
#undef VT_BIND_SETTING
	ClassDB::bind_method(D_METHOD("set_avt_feedback", "enabled"), &Terrain3D::set_avt_feedback);
	ClassDB::bind_method(D_METHOD("get_avt_feedback"), &Terrain3D::get_avt_feedback);
	ClassDB::bind_method(D_METHOD("set_vt_adaptive_enabled", "enabled"), &Terrain3D::set_vt_adaptive_enabled);
	ClassDB::bind_method(D_METHOD("is_vt_adaptive_enabled"), &Terrain3D::is_vt_adaptive_enabled);
	ClassDB::bind_method(D_METHOD("set_vt_editor_preview", "enabled"), &Terrain3D::set_vt_editor_preview);
	ClassDB::bind_method(D_METHOD("is_vt_editor_preview"), &Terrain3D::is_vt_editor_preview);
	ClassDB::bind_method(D_METHOD("is_vt_editor_preview_active"), &Terrain3D::is_vt_editor_preview_active);
	ClassDB::bind_method(D_METHOD("set_vt_debug_direct_material", "enabled"), &Terrain3D::set_vt_debug_direct_material);
	ClassDB::bind_method(D_METHOD("is_vt_debug_direct_material"), &Terrain3D::is_vt_debug_direct_material);
	ClassDB::bind_method(D_METHOD("get_vt_settings"), &Terrain3D::get_vt_settings);
	ClassDB::bind_method(D_METHOD("prepare_vt_capture"), &Terrain3D::prepare_vt_capture);
	ClassDB::bind_method(D_METHOD("get_vt_pages"), &Terrain3D::get_vt_pages);
	ClassDB::bind_method(D_METHOD("debug_lose_vt_page_readiness", "slot"), &Terrain3D::debug_lose_vt_page_readiness);
	ClassDB::bind_method(D_METHOD("debug_invalidate_vt_page", "slot"), &Terrain3D::debug_invalidate_vt_page);
	ClassDB::bind_method(D_METHOD("get_vt_material_textures"), &Terrain3D::get_vt_material_textures);
	ClassDB::bind_method(D_METHOD("get_vt_page_preview", "slot"), &Terrain3D::get_vt_page_preview);
	ClassDB::bind_method(D_METHOD("get_svt_baked_pages"), &Terrain3D::get_svt_baked_pages);
	ClassDB::bind_method(D_METHOD("get_surface_vt_block_sizes"), &Terrain3D::get_surface_vt_block_sizes);
	ClassDB::bind_method(D_METHOD("invalidate_vt_materials"), &Terrain3D::invalidate_vt_materials);
	ClassDB::bind_method(D_METHOD("set_svt_auto_bake", "enabled"), &Terrain3D::set_svt_auto_bake);
	ClassDB::bind_method(D_METHOD("is_svt_auto_bake"), &Terrain3D::is_svt_auto_bake);
	ClassDB::bind_method(D_METHOD("bake_svt"), &Terrain3D::bake_svt);
}
