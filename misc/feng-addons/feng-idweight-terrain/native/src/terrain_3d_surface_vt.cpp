// Copyright © 2026 Terrain3D contributors.
#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_vt_cell.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <cstring>

namespace {
Terrain3DSurfaceBaker *baker(const Ref<RefCounted> &p_ref) {
	return Object::cast_to<Terrain3DSurfaceBaker>(p_ref.ptr());
}
// Preserve source corner IDs instead of nearest-resampling them onto output pixels.
Vector3 bake_source_grid(Terrain3DData *data, const Rect2 &rect, int size, int border,
		float source_step, Ref<Image> &ids, Ref<Image> &height) {
	const float pixel = rect.size.x / size;
	if (pixel > source_step) { return Vector3(); } // Existing minified source path.
	const int stored = size + 2 * border;
	const Vector2 origin = ((rect.position - Vector2(pixel, pixel) * border) / source_step).floor() * source_step;
	const Vector2 end = rect.get_end() + Vector2(pixel, pixel) * border;
	const int extent = MIN(stored, int(Math::ceil(MAX(end.x - origin.x, end.y - origin.y) / source_step)) + 2);
	const Rect2 source_rect(origin - Vector2(source_step, source_step) * .5f, Vector2(extent, extent) * source_step);
	Ref<Image> corners;
	if (data->produce_surface_rect_page(source_rect, extent, 0, corners) < 0) { return Vector3(); }
	Ref<Image> heights = data->make_vt_height_page(source_rect, extent, 0);
	if (heights.is_null()) { return Vector3(); }
	ids = Image::create_empty(stored, stored, false, corners->get_format());
	height = Image::create_empty(stored, stored, false, heights->get_format());
	ids->blit_rect(corners, Rect2i(0, 0, extent, extent), Vector2i());
	height->blit_rect(heights, Rect2i(0, 0, extent, extent), Vector2i());
	return Vector3(origin.x, origin.y, source_step);
}
String tile_key(const Vector2i &p_address, int p_mip) {
	return String::num_int64(p_address.x) + "_" + String::num_int64(p_address.y) + "_" + String::num_int64(p_mip);
}
Ref<Image> cell_mip(const Ref<Image> &image, int level) {
	int width = MAX(1, image->get_width() >> level), height = MAX(1, image->get_height() >> level);
	PackedByteArray bytes = image->get_data();
	int64_t begin = image->get_mipmap_offset(level);
	int64_t end = level < image->get_mipmap_count() ? image->get_mipmap_offset(level + 1) : bytes.size();
	return Image::create_from_data(width, height, false, image->get_format(), bytes.slice(begin, end));
}

} //namespace

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
// How long the demand pass may skip production while the producer rebuilds its arrays for a
// larger capacity. Long enough for the producer's render pass and the pool's own growth (two
// or three frames), short enough that a device which cannot grow the arrays loses only a
// fraction of one page budget.
static const uint64_t MAX_CAPACITY_WAIT_FRAMES = 8;

bool Terrain3D::_ensure_vt_capacity(int p_required) {
	Terrain3DSurfaceBaker *producer = _vt.vt_baker.is_valid() ? baker(_vt.vt_baker) : nullptr;
	if (_vt.vt_shared_ready && producer && !_vt.vt_debug_direct_material) {
		const int ready_capacity = producer->get_capacity();
		if (ready_capacity > _vt.vt_page_count) {
			// Publish higher slot IDs only after the GPU cache was copied. Keep
			// addresses, owners and source jobs, including an already completed plan.
			if (!_vt.surface_vt->grow_capacity(ready_capacity) || !_vt.surface_svt->grow_capacity(ready_capacity)) { return false; }
			_vt.vt_page_count = _vt.vt_effective_page_count = _vt.surface_vt_page_count = _vt.surface_svt_page_count = ready_capacity;
			_vt.vt_capacity_wait_start = UINT64_MAX;
			if (_material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
			notify_property_list_changed();
			return true;
		}
	}
	const int transition_capacity = p_required + MAX(8, p_required / 2);
	if (!_vt.vt_auto_capacity || transition_capacity <= _vt.vt_page_count || _vt.vt_page_count >= 1024 ||
		!_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty()) { return false; }
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
		if (producer->has_pending_capacity()) {
			if (_vt.vt_capacity_wait_start == UINT64_MAX) {
				_vt.vt_capacity_wait_start = frame;
			}
			if (frame < _vt.vt_capacity_wait_start + MAX_CAPACITY_WAIT_FRAMES) {
				return true;
			}
		}
		_vt.vt_capacity_wait_start = UINT64_MAX;
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
	_vt.vt_effective_page_count = p_count;
	_reset_vt_configuration();
}
void Terrain3D::set_vt_pages_per_update(int p_pages) {
	_vt.vt_pages_per_update = CLAMP(p_pages, 1, 16);
}

void Terrain3D::_cancel_svt_bake(const String &p_reason) {
	_vt.svt_cell_job.clear();
	_vt.svt_cell_baker.unref();
	if (!_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty()) {
		_vt.vt_svt_bake_failed += _vt.vt_svt_bake_queue.size() + _vt.vt_svt_bake_waiting.size();
		_vt.vt_svt_bake_error = p_reason;
	}
	if (_vt.surface_svt && _vt.surface_svt->is_initialized()) {
		for (const Variant &slot : _vt.vt_svt_bake_waiting.keys()) {
			if (int(slot) >= 0) {
				_vt.surface_svt->protect_page(int(slot), false);
			}
		}
	}
	_vt.vt_svt_bake_queue.clear();
	_vt.vt_svt_bake_waiting.clear();
}

// Compresses and decodes one image through the atlas codec, so a test can verify the codec
// path where page production has nothing to bake from.
Dictionary Terrain3D::probe_vt_atlas_compression(const Ref<Image> &p_image) const {
	if (!_vt.vt_baker.is_valid()) {
		return Dictionary();
	}
	return baker(_vt.vt_baker)->probe_atlas_compression(p_image);
}

void Terrain3D::set_vt_atlas_compression(const int p_compression) {
	const int mode = CLAMP(p_compression, 0, Terrain3DAssets::ARRAY_COMPRESSION_MAX - 1);
	if (_vt.vt_atlas_compression == mode) {
		return;
	}
	_vt.vt_atlas_compression = mode;
	// Only the three material page arrays carry the format. The pool, the world addresses,
	// the owners and the demand plan are format independent, and the producer rebuilds the
	// arrays in place - it bumps its own generation, which makes its next render pass
	// replace the bundle in the new format. Reconfiguring the service here instead would
	// detach both views, release every resident page and grow the pool back to the
	// capacity it had already published.
	if (_vt.vt_baker.is_valid()) {
		baker(_vt.vt_baker)->set_atlas_compression(mode);
		// The rebuilt arrays start blank, so the pages that were produced in the previous
		// format have to be produced again. This is forced: a plain edit is deferred while
		// the editor preview is active, but a format change leaves nothing to fall back on.
		if (_data) {
			for (const Vector2i &location : _data->get_region_locations()) {
				invalidate_surface_pages(location, true);
			}
		}
		_vt.vt_materials_dirty = true;
		return;
	}
	_reset_vt_configuration();
}
int Terrain3D::get_vt_atlas_compression() const {
	return _vt.vt_atlas_compression;
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
	_vt.avt_plan_key.clear();
	if (_vt.vt_page_pipeline) { _vt.vt_page_pipeline->reset(); }
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->reset(); }
	// Detach both views before replacing their common pool. Clearing one view must
	// never destroy a pool that another view is still sampling.
	auto pool = Terrain3DVirtualTexture::create_page_pool();
	// Both views adopt the shared dimensions before they are configured, so the one
	// configuration helper describes the view that is actually built. A reconfiguration
	// keeps the capacity that is already published: auto capacity only ever grows, and
	// starting again from the setting would make the demand pass re-grow the pool - which
	// releases every page it had just rebuilt - for no reason.
	const int capacity = CLAMP(MAX(_vt.vt_page_count, _vt.vt_effective_page_count), 8, 1024);
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
	_vt.avt_plan_key.clear();
	_vt.avt_page_plan.clear();
	_vt.avt_prefetch_plan.clear();
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
	baker(_vt.vt_baker)->set_atlas_compression(_vt.vt_atlas_compression);
	baker(_vt.vt_baker)->configure(_vt.vt_page_size, _vt.vt_page_border, capacity);
	_configure_svt_cell_store();
	_vt.vt_bound_albedo = RID();
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
	_vt.vt_materials_dirty = true;
	_vt.vt_shared_ready = true;
	// A new pool has no resident page: everything has to be produced again. Callers that
	// only change how a page is stored must not reach this point.
	_vt.vt_pool_generation++;
}

bool Terrain3D::_vt_has_pending_upload() const {
	// Either view can own the shared pool, and a commit on one of them is what puts
	// render-thread work in flight.
	return (_vt.surface_vt && _vt.surface_vt->has_pending_indirection()) ||
			(_vt.surface_svt && _vt.surface_svt->has_pending_indirection());
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
	RID albedo = producer->get_albedo_rid();
	if (albedo != _vt.vt_bound_albedo) {
		_vt.vt_bound_albedo = albedo;
		if (_material.is_valid()) {
			_material->update(Terrain3DMaterial::REGION_ARRAYS);
		}
		// Acknowledged even without a material: the producer releases the arrays it
		// replaced, and none of them is referenced once nothing binds them.
		producer->acknowledge_output(albedo);
	}

	_process_async_svt_pages();
	// The explicit job is done once its queue, its waiting set and the cell it was baking are
	// all empty; only then may an automatic job take over the progress counters.
	if (_vt.vt_svt_explicit_bake && _vt.vt_svt_bake_queue.is_empty() &&
			_vt.vt_svt_bake_waiting.is_empty() && _vt.svt_cell_job.is_empty()) {
		_vt.vt_svt_explicit_bake = false;
	}
	_process_svt_auto_bake();
	// RD writes and worker completion do not mark RenderingServer as changed.
	// In the editor's low-processor mode that otherwise leaves queued GPU pages
	// waiting forever for camera input. Request a normal (non-blocking) redraw
	// only while work is actually outstanding; never force_draw here.
	if (IS_EDITOR && (producer->has_render_work() || _vt_has_pending_upload())) {
		Control *editor = EditorInterface::get_singleton()->get_base_control();
		if (editor) { editor->queue_redraw(); }
	}
}

void Terrain3D::_process_async_svt_pages() {
	if (_vt.svt_pending_pages.empty() || !_data || _vt.vt_baker.is_null()) { return; }
	if (!_vt.svt_page_pipeline) { _vt.svt_page_pipeline = std::make_unique<Terrain3DPagePipeline>(); }
	if (!_vt.vt_source_snapshot) { _vt.vt_source_snapshot = Terrain3DPagePipeline::snapshot(_data, _region_size, _vertex_spacing, _surface_density); }
	int submitted = 0;
	for (auto it = _vt.svt_pending_pages.begin(); it != _vt.svt_pending_pages.end();) {
		const int slot = it->first;
		Terrain3DPagePipeline::Result result;
		if (!_vt.svt_page_pipeline->poll(it->second, _vt.vt_source_snapshot, result)) {
			++it; continue;
		}
		if (_vt.vt_page_records.has(slot)) {
			Dictionary record = _vt.vt_page_records[slot];
			const bool written = result.payload.is_valid() &&
					_vt.surface_svt->write_page(slot, result.payload);
			if (written) {
				record["source"] = result.payload->get_data();
			}
			bool cell_copy_queued = false;
			if (result.missing.empty() && !result.sources.is_empty()) {
				record["state"] = "Pending cell copy";
				baker(_vt.vt_baker)->queue_cell_page(slot, result.sources, it->second.rect);
				cell_copy_queued = true;
			} else {
				// A partially available persisted page must not strand the published slot with
				// raw IDs but no material params. Fall back to the resident terrain payload for
				// this page immediately; disk cells remain an accelerator, not a requirement.
				Ref<Image> ids;
				Ref<Image> height;
				if (_data->produce_surface_rect_page(it->second.rect, _vt.vt_page_size,
						_vt.vt_page_border, ids) >= 0) {
					const Vector3 source_grid = bake_source_grid(_data, it->second.rect,
							_vt.vt_page_size, _vt.vt_page_border,
							_vertex_spacing / _surface_density, ids, height);
					if (height.is_null()) {
						height = _data->make_vt_height_page(it->second.rect,
								_vt.vt_page_size, _vt.vt_page_border);
					}
					if (ids.is_valid() && height.is_valid()) {
						record["state"] = "Pending resident fallback";
						baker(_vt.vt_baker)->queue_page(slot, ids, height,
								it->second.rect, 1.f, source_grid);
						cell_copy_queued = true;
					}
				}
				if (!cell_copy_queued) {
					record["state"] = "Missing/stale cell bake";
				}
				// A running explicit job already covers these cells: a full bake covers every
				// region. Arming the automatic job here makes it start the frame the explicit
				// job drains and replace its job-scoped progress counters.
				const bool explicit_job = _vt.vt_svt_explicit_bake ||
						!_vt.vt_svt_bake_queue.is_empty() ||
						!_vt.vt_svt_bake_waiting.is_empty();
				if (_vt.svt_auto_bake && !_data_directory.is_empty() && !explicit_job) {
					for (const Vector2i &cell : result.missing) {
						if (_vt.vt_svt_dirty_regions.is_empty()) { _vt.vt_svt_edit_time = 0; }
						_vt.vt_svt_dirty_regions[cell] = true;
					}
				}
			}
			if (!written && !cell_copy_queued) {
				// The slot is allocated and published, but neither the raw-ID payload nor
				// a GPU cell copy will ever fill it. Release both so a later demand pass
				// requests the page again instead of sampling an unwritten layer for the
				// rest of the session.
				WARN_PRINT("Releasing SVT slot " + String::num_int64(slot) + " after failed page production");
				const Vector2i address = record.get("address", Vector2i());
				const int mip = record.get("mip", 0);
				// Advance the iterator first: _invalidate_vt_slot() erases this entry by key.
				it = _vt.svt_pending_pages.erase(it);
				_invalidate_vt_slot(slot);
				_vt.surface_svt->release_world_page(address.x, address.y, mip);
				continue;
			}
		}
		it = _vt.svt_pending_pages.erase(it);
		if (++submitted >= _vt.vt_pages_per_update) { break; }
	}
}

// Physical memory the resident far-field cells may occupy, across all three channels.
// Cells are an accelerator: one that does not fit is evicted and the pages it served are
// rebuilt from the resident payloads, which is why this is a budget and not a requirement.
static const int64_t SVT_CELL_STORE_BUDGET_BYTES = 192 * 1024 * 1024;

void Terrain3D::_configure_svt_cell_store() {
	if (_vt.vt_baker.is_null()) {
		return;
	}
	if (_vt.svt_cells.is_null()) {
		Ref<Terrain3DCellStore> store;
		store.instantiate();
		_vt.svt_cells = store;
	}
	const int resolution = MAX(1, int(Math::ceil(double(_region_size) * double(_vertex_spacing) *
			MAX(0.001, get_surface_svt_texels_per_meter()))));
	int64_t level_bytes = 0;
	for (int size = resolution; size > 0; size >>= 1) {
		level_bytes += int64_t(MAX(1, size)) * MAX(1, size) * 8;
	}
	const int64_t per_layer = MAX(1, level_bytes) * 3;
	const int capacity = int(CLAMP(SVT_CELL_STORE_BUDGET_BYTES / per_layer, 1, 64));
	_vt.svt_cells->initialize(RS->get_rendering_device(), capacity, resolution);
	_vt.svt_cell_file_probe.clear();
	baker(_vt.vt_baker)->set_cell_store(_vt.svt_cells);
}

void Terrain3D::_destroy_vt_service() {
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
	_vt.avt_plan_key.clear();
	_vt.svt_cell_baker.unref();
	if (_vt.vt_callback_registered && RS && RS->has_method("virtual_texture_remove_update_callback")) {
		RS->call("virtual_texture_remove_update_callback", int64_t(get_instance_id()));
	}
	_vt.vt_callback_registered = false;
	_vt.vt_baker.unref();
	_vt.vt_bound_albedo = RID();
	_vt.vt_shared_ready = false;
	_vt.vt_page_records.clear();
	_vt.svt_pending_pages.clear();
	_vt.vt_registered_sectors.clear();
	_vt.vt_svt_bake_queue.clear();
	_vt.vt_svt_bake_waiting.clear();
}

void Terrain3D::invalidate_vt_materials() {
	_vt.vt_materials_dirty = true;
	_vt.vt_source_revision++;
}

void Terrain3D::_invalidate_vt_slot(int p_slot) {
	_vt.svt_pending_pages.erase(p_slot);
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->cancel({p_slot, 0, 0, 0, 0}); }
	if (_vt.vt_baker.is_valid() && p_slot >= 0) {
		baker(_vt.vt_baker)->invalidate_slot(p_slot);
	}
	_vt.vt_page_records.erase(p_slot);
}

String Terrain3D::_svt_page_path(const Vector2i &p_address, int p_mip) const {
	if (_data_directory.is_empty()) {
		return String();
	}
	return TerrainVTCell::path(_data_directory, p_address, 0);
}

int Terrain3D::prepare_vt_capture() {
	Terrain3DSurfaceBaker *producer = baker(_vt.vt_baker);
	if (!producer || _vt.vt_debug_direct_material || !_data) {
		return 0;
	}
	// Reissue resident production into the same slots for a diagnostic capture.
	// This does not evict pages, edit terrain, or run a persistent full bake.
	const Array records = _vt.vt_page_records.values();
	const int stored_size = _vt.vt_page_size + 2 * _vt.vt_page_border;
	int queued = 0;
	for (const Dictionary &record : records) {
		const int slot = record.get("slot", -1);
		if (!producer->is_page_ready(slot)) {
			continue;
		}
		PackedByteArray bytes = record.get("source", PackedByteArray());
		if (bytes.size() != int64_t(stored_size) * stored_size * 2) {
			continue;
		}
		Ref<Image> payload = Image::create_from_data(stored_size, stored_size, false,
				Image::Format(39), bytes);
		_queue_vt_material_page(slot, payload, record.get("world_rect", Rect2()),
				record.get("kind", String()) == Variant("SVT"), record.get("mip", 0),
				record.get("address", Vector2i()));
		++queued;
	}
	return queued;
}

// A resident cell is reused while this key matches the one it was published with. It is
// deliberately cheap - the material signature, the far-field density and a per-cell edit
// stamp - because it is evaluated for every cell of every page; the exact content
// signature stays on the bake path, which is the only place a mismatch must be proven.
uint64_t Terrain3D::_svt_cell_state_key(const Vector2i &p_cell) const {
	uint64_t key = uint64_t(_vt.vt_material_signature) * 1099511628211ull;
	key ^= uint64_t(int64_t(Math::round(double(get_surface_svt_texels_per_meter()) * 1000.0))) * 1315423911ull;
	const int64_t cell_id = (int64_t(p_cell.x) << 32) ^ uint32_t(p_cell.y);
	const auto found = _vt.svt_cell_edit_stamp.find(cell_id);
	key ^= (found != _vt.svt_cell_edit_stamp.end() ? found->second : uint64_t(0)) * 2654435761ull;
	return key;
}

// The cells a page samples, resolved against the resident store. The geometry is the same
// world crop the file-backed path builds: every cell the page and its border ring touch
// contributes one piece, weighted by how much of the page pixel it covers, and the border
// reads the neighbouring cells. A piece names the store layer and the level whose texel is
// closest to one page pixel, so the copy shader samples the whole cell level and the
// accumulate pass is what crops it.
bool Terrain3D::_resolve_svt_cell_pieces(const Rect2 &p_rect, Array &r_pieces,
		std::vector<Vector2i> &r_missing) {
	if (!_data || !_vt.svt_cells.is_valid() || !_vt.svt_cells->is_initialized() ||
			_vt.vt_page_size <= 0 || p_rect.size.x <= 0.f) {
		return false;
	}
	const float world = float(_region_size) * _vertex_spacing;
	if (world <= 0.f) {
		return false;
	}
	const float pixel = p_rect.size.x / float(_vt.vt_page_size);
	const Rect2 footprint = p_rect.grow(pixel * _vt.vt_page_border);
	// The store bakes at the far field's density, so the level is the one whose texel is
	// nearest a page pixel; the same choice the file-backed reader makes.
	const int resolution = _vt.svt_cells->get_resolution();
	const int level = CLAMP(int(Math::floor(Math::log(MAX(1.f, pixel * float(get_surface_svt_texels_per_meter()))) /
											Math::log(2.f))),
			0, MAX(0, _vt.svt_cells->get_level_count() - 1));
	const int level_size = MAX(1, resolution >> level);
	const Vector2i first(int(Math::floor(footprint.position.x / world)), int(Math::floor(footprint.position.y / world)));
	const Vector2i last(int(Math::floor(footprint.get_end().x / world)), int(Math::floor(footprint.get_end().y / world)));
	// A root page can span a continent. Above this many cells the store cannot serve the
	// page usefully anyway (it holds a handful), and the caller falls back to cropping the
	// resident payloads, which costs one pass over the regions instead of one per cell.
	const int64_t span_x = int64_t(last.x) - int64_t(first.x) + 1;
	const int64_t span_z = int64_t(last.y) - int64_t(first.y) + 1;
	if (span_x <= 0 || span_z <= 0 || span_x * span_z > 4096) {
		return false;
	}
	for (int z = first.y; z <= last.y; ++z) {
		for (int x = first.x; x <= last.x; ++x) {
			const Vector2i cell(x, z);
			const Rect2 cell_rect(Vector2(cell) * world, Vector2(world, world));
			const Terrain3DCellStore::Cell *entry = _vt.svt_cells->find_cell(cell, _svt_cell_state_key(cell));
			if (!entry) {
				r_missing.push_back(cell);
				continue;
			}
			_vt.svt_cells->touch_cell(cell);
			float left = 0.f, right = 0.f, top = 0.f, bottom = 0.f;
			// A page that reaches past the resident world needs edge texels in its border
			// too, and only there: a cell that exists but has no bake still blocks the page.
			const float padding = pixel * (_vt.vt_page_border + 1);
			bool open_x = true, open_z = true;
			for (int dz = -1; dz <= 1 && open_x; ++dz) {
				for (int dx = -1; dx <= 1; ++dx) {
					if (_data->has_region(cell + Vector2i(dx, dz))) { open_x = false; break; }
				}
			}
			for (int dx = -1; dx <= 1 && open_z; ++dx) {
				for (int dz = -1; dz <= 1; ++dz) {
					if (_data->has_region(cell + Vector2i(dx, dz))) { open_z = false; break; }
				}
			}
			if (open_x) { left = x == first.x ? padding : 0.f; right = x == last.x ? padding : 0.f; }
			if (open_z) { top = z == first.y ? padding : 0.f; bottom = z == last.y ? padding : 0.f; }
			Dictionary piece;
			piece["layer"] = entry->layer;
			piece["level"] = level;
			piece["cell_rect"] = cell_rect;
			piece["coverage_rect"] = Rect2(cell_rect.position - Vector2(left, top),
					cell_rect.size + Vector2(left + right, top + bottom));
			// The store view covers the whole cell level, so the source rect is the cell.
			piece["source_rect"] = cell_rect;
			piece["level_size"] = level_size;
			r_pieces.push_back(piece);
		}
	}
	return true;
}

// Whether any cell this page touches has a persisted bake. The answer is remembered per
// cell, so the render path never stats the same file twice.
bool Terrain3D::_svt_cells_have_persisted_bake(const Rect2 &p_rect) {
	if (_data_directory.is_empty() || !_data) {
		return false;
	}
	const float world = float(_region_size) * _vertex_spacing;
	if (world <= 0.f) {
		return false;
	}
	const float pixel = p_rect.size.x / float(MAX(1, _vt.vt_page_size));
	const Rect2 footprint = p_rect.grow(pixel * _vt.vt_page_border);
	const Vector2i first(int(Math::floor(footprint.position.x / world)), int(Math::floor(footprint.position.y / world)));
	const Vector2i last(int(Math::floor(footprint.get_end().x / world)), int(Math::floor(footprint.get_end().y / world)));
	const int resolution = MAX(1, int(Math::ceil(double(world) * MAX(0.001, get_surface_svt_texels_per_meter()))));
	const int64_t span_x = int64_t(last.x) - int64_t(first.x) + 1;
	const int64_t span_z = int64_t(last.y) - int64_t(first.y) + 1;
	if (span_x <= 0 || span_z <= 0 || span_x * span_z > 4096) {
		return false;
	}
	for (int z = first.y; z <= last.y; ++z) {
		for (int x = first.x; x <= last.x; ++x) {
			const Vector2i cell(x, z);
			const int64_t key = (int64_t(x) << 32) ^ uint32_t(z);
			auto probe = _vt.svt_cell_file_probe.find(key);
			if (probe == _vt.svt_cell_file_probe.end()) {
				probe = _vt.svt_cell_file_probe.emplace(key, uint8_t(2)).first;
				const Dictionary saved = _load_svt_cell(cell);
				// A bake at another resolution would have to be resampled into the store's
				// shape, so only a matching one counts as usable here.
				if (!saved.is_empty() && int(saved.get("resolution", 0)) == resolution) {
					probe->second = 1;
				}
			}
			if (probe->second == 1) {
				return true;
			}
		}
	}
	return false;
}

void Terrain3D::_queue_vt_material_page(int p_slot, const Ref<Image> &p_payload, const Rect2 &p_rect,
		bool p_svt, int p_mip, const Vector2i &p_address, const Terrain3DPagePipeline::Result *p_prepared) {
	Terrain3DSurfaceBaker *producer = baker(_vt.vt_baker);
	if (_vt.vt_debug_direct_material || !producer || p_slot < 0 || (!p_svt && p_payload.is_null())) {
		return;
	}
	Ref<Image> height;
	Dictionary record;
	record["slot"] = p_slot;
	record["kind"] = p_svt ? "SVT" : "AVT";
	record["state"] = "Pending bake";
	record["world_rect"] = p_rect;
	record["mip"] = p_mip;
	record["address"] = p_address;
	record["revision"] = int64_t(_vt.vt_source_revision);
	// When this production was queued. Demand retries a page whose content never arrived
	// once this stamp is older than SVT_PAGE_RETRY_FRAMES, which is what recovers from a
	// production that was dropped, refused, or lost to a failed cell copy.
	record["queued_frame"] = int64_t(Engine::get_singleton()->get_process_frames());
	record["source"] = p_payload.is_valid() ? p_payload->get_data() : PackedByteArray();
	_vt.vt_page_records[p_slot] = record;
	if (p_svt) {
		// The far field has three sources, in this order of preference:
		//   1. a resident baked cell (this store) - a GPU copy, no CPU work and no file;
		//   2. a persisted bake on disk - assembled by the source worker, one read per page;
		//   3. the resident region payloads - cropped and baked here, so a page is produced
		//      whether or not any bake exists.
		// Only the first is free, but none of them makes rendering depend on a file.
		if (_vt.svt_cells.is_valid() && _vt.svt_cells->is_initialized()) {
			Array pieces;
			std::vector<Vector2i> missing;
			if (_resolve_svt_cell_pieces(p_rect, pieces, missing) && missing.empty() && !pieces.is_empty()) {
				record["state"] = "Pending cell copy";
				record["cells"] = pieces.size();
				_vt.vt_page_records[p_slot] = record;
				producer->queue_cell_page(p_slot, pieces, p_rect);
				return;
			}
		}
		if (_svt_cells_have_persisted_bake(p_rect)) {
			if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->cancel({p_slot, 0, 0, 0, 0}); }
			Terrain3DPagePipeline::Request request{{p_slot, 0, 0, 0, 0}, p_rect, _vt.vt_page_size, _vt.vt_page_border};
			request.svt = true; request.directory = _data_directory;
			request.materials = _vt.vt_material_signature; request.density = get_surface_svt_texels_per_meter();
			record["state"] = "Missing bake";
			_vt.vt_page_records[p_slot] = record;
			_vt.svt_pending_pages[p_slot] = std::move(request);
			return;
		}
		// The raw ID/weight and height source is cropped from the resident region payloads
		// and the GPU bake turns it into material channels, exactly like the near field.
		Ref<Image> ids;
		if (_data->produce_surface_rect_page(p_rect, _vt.vt_page_size, _vt.vt_page_border, ids) < 0) {
			record["state"] = "No resident payload";
			_vt.vt_page_records[p_slot] = record;
			return;
		}
		const Vector3 source_grid = bake_source_grid(_data, p_rect, _vt.vt_page_size, _vt.vt_page_border,
				_vertex_spacing / _surface_density, ids, height);
		if (height.is_null()) { height = _data->make_vt_height_page(p_rect, _vt.vt_page_size, _vt.vt_page_border); }
		producer->queue_page(p_slot, ids, height, p_rect, 1.f, source_grid);
		return;
	}
	if (p_prepared) {
		producer->queue_page(p_slot, p_prepared->ids, p_prepared->height, p_rect, 1.f, p_prepared->grid);
		return;
	}
	Ref<Image> ids = p_payload;
	const Vector3 source_grid = bake_source_grid(_data, p_rect, _vt.vt_page_size, _vt.vt_page_border,
			_vertex_spacing / _surface_density, ids, height);
	if (height.is_null()) { height = _data->make_vt_height_page(p_rect, _vt.vt_page_size, _vt.vt_page_border); }
	producer->queue_page(p_slot, ids, height, p_rect, 1.f, source_grid);
}

void Terrain3D::_invalidate_vt_region(const Vector2i &p_region) {
	_vt.vt_source_snapshot.reset();
	_vt.avt_refinement.reset();
	_vt.avt_plan_key.clear();
	if (_vt.vt_page_pipeline) { _vt.vt_page_pipeline->reset(); }
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->reset(); }
	// A resident far-field cell is stale from the moment a region in it - or beside it, since
	// a page border reads the neighbours - is edited, and the persisted bake with it.
	for (int dz = -1; dz <= 1; ++dz) {
		for (int dx = -1; dx <= 1; ++dx) {
			const Vector2i cell = p_region + Vector2i(dx, dz);
			_vt.svt_cell_edit_stamp[(int64_t(cell.x) << 32) ^ uint32_t(cell.y)] = ++_vt.svt_edit_counter;
			_vt.svt_cell_file_probe.erase((int64_t(cell.x) << 32) ^ uint32_t(cell.y));
		}
	}
	_vt.vt_svt_dirty_regions[p_region] = true;
	_vt.vt_svt_edit_time = Time::get_singleton()->get_ticks_msec();
	if (_vt.vt_baker.is_null()) {
		return;
	}
	float world = float(_region_size) * _vertex_spacing;
	Rect2 affected(Vector2(p_region) * world, Vector2(world, world));
	Array keys = _vt.vt_page_records.keys();
	for (int i = 0; i < keys.size(); i++) {
		Dictionary record = _vt.vt_page_records[keys[i]];
		Rect2 rect = record["world_rect"];
		if (rect.grow(MAX(_vertex_spacing, rect.size.x * float(_vt.vt_page_border + 1) / _vt.vt_page_size)).intersects(affected)) {
			if (_vt.vt_svt_bake_waiting.has(keys[i])) {
				Vector2i address = record["address"];
				_vt.vt_svt_bake_queue.push_back(Vector3i(address.x, address.y, int(record["mip"])));
				_vt.vt_svt_bake_waiting.erase(keys[i]);
			}
			baker(_vt.vt_baker)->invalidate_slot(int(keys[i]));
			// Border edits can affect a neighbour's page. Remove its address too,
			// otherwise the scheduler would keep treating an invalid payload as a hit.
			for (const Dictionary &owner : _vt.surface_vt->get_slot_owner_metadata(int(keys[i]))) {
				int mip = owner["mip"];
				Vector2i address = owner["virtual"];
				if (bool(owner["world_space"])) {
					int half = _vt.surface_svt->get_indirection_size() >> 1;
					_vt.surface_svt->release_world_page((address.x << mip) - half, (address.y << mip) - half, mip);
				} else {
					Vector2i sector = owner["sector"];
					int x = address.x - (_vt.surface_vt->get_sector_block_origin_x(sector) >> mip);
					int y = address.y - (_vt.surface_vt->get_sector_block_origin_y(sector) >> mip);
					_vt.surface_vt->release_page(sector, mip, x, y);
				}
			}
			const int slot = keys[i];
			_vt.svt_pending_pages.erase(slot);
			if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->cancel({slot, 0, 0, 0, 0}); }
			_vt.vt_page_records.erase(keys[i]);
		}
	}
}

Dictionary Terrain3D::get_vt_material_textures() const {
	Dictionary result;
	if (_vt.vt_debug_direct_material || _vt.vt_baker.is_null()) {
		return result;
	}
	// One locked read of the whole bundle: three separate getters can straddle a rebuild and
	// hand back arrays from two generations, which the material then binds as one set.
	return baker(_vt.vt_baker)->get_published_arrays();
}
Dictionary Terrain3D::get_vt_settings() const {
	Dictionary result;
	result["page_size"] = _vt.vt_page_size;
	result["border"] = _vt.vt_page_border;
	result["page_count"] = _vt.vt_page_count;
	result["effective_page_count"] = _vt.vt_effective_page_count;
	// How many times the service built a page pool. Building one releases every resident
	// page, because the atlas cannot be resized in place.
	result["pool_generation"] = _vt.vt_pool_generation;
	result["auto_capacity"] = _vt.vt_auto_capacity;
	// Three RGBA16F outputs, R16 IDs, and R16+R32F bake staging per slot.
	result["physical_cache_bytes"] = int64_t(_vt.vt_page_size + 2 * _vt.vt_page_border) * (_vt.vt_page_size + 2 * _vt.vt_page_border) * _vt.vt_page_count * 32;
	result["pages_per_update"] = _vt.vt_pages_per_update;
	result["shared_pool"] = _vt.vt_shared_ready;
	result["adaptive"] = _vt.vt_adaptive_enabled;
	result["avt_feedback"] = _vt.avt_feedback;
	result["svt_feedback"] = _vt.svt_feedback;
	result["avt_texels_per_pixel"] = _vt.surface_vt_texels_per_pixel;
	result["avt_resolution"] = get_surface_vt_resolution(); // Legacy API only.
	result["avt_distance_mips"] = _vt.surface_vt_distance_mips;
	result["avt_mip_ranges"] = _vt.surface_vt_mip_ranges;
	result["avt_distance"] = _vt.surface_vt_distance;
	result["avt_texels_per_meter"] = get_surface_vt_texels_per_meter();
	result["svt_texels_per_meter"] = get_surface_svt_texels_per_meter();
	result["svt_world_extent"] = (_vt.surface_svt ? _vt.surface_svt->get_indirection_size() : MAX(64, _vt.surface_svt_page_count * 4)) * _vt.surface_svt_page_world;
	result["avt_virtual_resolution"] = 64.f * get_surface_vt_texels_per_meter();
	result["avt_base_block_size"] = get_avt_base_block_size();
	result["avt_sector_world"] = is_sector_avt() ? 64.0 : double(_region_size * _vertex_spacing);
	result["avt_sector_stats"] = _vt.avt_sector_stats;
	result["svt_effective_max_mip"] = _vt.surface_svt ? _vt.surface_svt->get_world_max_mip() : _vt.surface_svt_max_mip;
	// Far-field residency diagnostics: the root pyramid the last pass pinned, and the
	// coarseness floor it raised its detail pages to (0 when the set fit).
	result["svt_root_pages"] = int(_vt.svt_root_pages.size());
	// What the pinned set covers and which levels it used. The fallback can only answer
	// inside this rect, so it is the property a test checks.
	result["svt_root_coverage"] = _vt.svt_root_coverage;
	result["svt_root_level_min"] = _vt.svt_root_level_min;
	result["svt_root_level_max"] = _vt.svt_root_level_max;
	// Pages demand produced again because the table named them and the producer had no
	// content. A settled view must stop growing this.
	result["svt_requeues"] = int64_t(_vt.svt_requeues);
	// Root walks that ran and passes that reused the plan. A baked far field settles after
	// one walk, so the skip count is what proves the fallback costs nothing per frame.
	result["svt_root_passes"] = int64_t(_vt.svt_root_passes);
	result["svt_root_skips"] = int64_t(_vt.svt_root_skips);
	result["svt_floor_level"] = _vt.svt_floor_level;
	result["svt_visible_pages"] = _vt.vt_svt_visible_pages;
	// Main-thread cost of the VT section of the last physics tick, its worst frame so
	// far, and the far-field demand pass inside it.
	result["vt_cpu_ms"] = _vt.vt_cpu_ms;
	result["vt_cpu_peak_ms"] = _vt.vt_cpu_peak_ms;
	result["svt_cpu_ms"] = _vt.svt_cpu_ms;
	Dictionary phases;
	phases["service"] = _vt.vt_service_ms;
	phases["avt"] = _vt.vt_avt_ms;
	phases["svt"] = _vt.vt_svt_ms;
	phases["avt_peak"] = _vt.vt_avt_peak_ms;
	phases["svt_peak"] = _vt.vt_svt_peak_ms;
	phases["topup"] = _vt.vt_topup_ms;
	phases["bake"] = _vt.vt_bake_ms;
	result["vt_phases"] = phases;
	// Resident far-field cell sources: what the runtime copies pages from without touching
	// a file or re-baking, and how close that cache is to its memory budget.
	if (_vt.svt_cells.is_valid()) {
		result["svt_cells"] = _vt.svt_cells->get_stats();
	}
	// Atlas compression: the request, what the baker resolved it to, and the reason a
	// request was refused (unsupported codec, no compressor, or an unloadable format).
	result["vt_atlas_compression"] = _vt.vt_atlas_compression;
	if (_vt.vt_baker.is_valid()) {
		const Dictionary compression = baker(_vt.vt_baker)->get_atlas_compression_info();
		result["vt_atlas_compression_available"] = compression.get("available", 0);
		result["vt_atlas_compression_applied"] = compression.get("applied", 0);
		result["vt_atlas_compression_name"] = compression.get("name", String());
		result["vt_atlas_compression_reason"] = compression.get("reason", String());
	}
	result["avt_selection_mode"] = _vt.surface_vt_selection_mode;
	result["editor_preview"] = _vt.vt_editor_preview;
	result["editor_preview_active"] = is_vt_editor_preview_active();
	result["avt_region_grid"] = _vt.surface_vt_region_grid;
	result["avt_region_offset"] = _vt.surface_vt_region_offset;
	result["avt_forward_regions"] = _vt.surface_vt_forward_regions;
	result["avt_region_rect"] = get_surface_vt_region_rect();
	result["callback_registered"] = _vt.vt_callback_registered;
	result["material_signature"] = int64_t(_vt.vt_material_signature);
	result["auto_bake"] = _vt.svt_auto_bake;
	result["auto_pending_regions"] = _vt.vt_svt_dirty_regions.size();
	result["bake_generation"] = int64_t(_vt.vt_svt_bake_generation);
	result["bake_incremental"] = _vt.vt_svt_bake_incremental;
	result["bake_total"] = _vt.vt_svt_bake_total;
	result["cells_baked"] = int64_t(_vt.svt_cells_baked);
	result["bake_done"] = _vt.vt_svt_bake_done;
	result["svt_source_pending"] = int64_t(_vt.svt_pending_pages.size());
	result["bake_pending"] = _vt.vt_svt_bake_queue.size() + _vt.vt_svt_bake_waiting.size();
	result["bake_failed"] = _vt.vt_svt_bake_failed;
	result["bake_error"] = _vt.vt_svt_bake_error;
	if (_vt.vt_baker.is_valid()) {
		result["producer"] = baker(_vt.vt_baker)->get_stats();
	}
	if (_vt.surface_vt) {
		result["residency"] = _vt.surface_vt->get_stats();
	}
	return result;
}
Array Terrain3D::get_vt_pages() const {
	Array result;
	for (const Variant &key : _vt.vt_page_records.keys()) {
		if (!_vt.surface_vt || _vt.surface_vt->get_slot_owner_count(int(key)) == 0) {
			continue;
		}
		Dictionary record = Dictionary(_vt.vt_page_records[key]).duplicate();
		record.erase("source");
		record["ready"] = _vt.vt_baker.is_valid() && baker(_vt.vt_baker)->is_page_ready(int(key));
		if (bool(record["ready"])) {
			record["state"] = "Ready";
		}
		const Array owners = _vt.surface_vt ? _vt.surface_vt->get_slot_owner_metadata(int(key)) : Array();
		record["owners"] = owners;
		for (const Dictionary &owner : owners) {
			if (bool(owner["world_space"])) { continue; }
			const Vector2i sector = owner["sector"];
			const int mip = owner["mip"];
			record["mip"] = mip;
			record["address"] = Vector2i(owner["virtual"]) - Vector2i(_vt.surface_vt->get_sector_block_origin_x(sector) >> mip, _vt.surface_vt->get_sector_block_origin_y(sector) >> mip);
		}
		result.push_back(record);
	}
	return result;
}
Ref<Image> Terrain3D::get_vt_page_preview(int p_slot) {
	return _vt.vt_baker.is_valid() ? baker(_vt.vt_baker)->get_page_preview(p_slot) : Ref<Image>();
}
uint32_t Terrain3D::_svt_cell_signature(const Vector2i &p_cell) const {
	// The signature shape lives in terrain_vt_cell.h because the runtime reader has
	// to reproduce it exactly.
	return TerrainVTCell::signature(int64_t(_vt.vt_material_signature), get_surface_svt_texels_per_meter(),
			_vertex_spacing, int(_region_size), [&](int p_x, int p_y) {
				Ref<Terrain3DRegion> region = _data->get_region(p_cell + Vector2i(p_x, p_y));
				if (region.is_null() || region->is_deleted()) {
					return Array();
				}
				Array hashes;
				hashes.push_back(region->get_control_map().is_valid() ? Variant(region->get_control_map()->get_data()).hash() : 0);
				hashes.push_back(region->get_surface_map().is_valid() ? Variant(region->get_surface_map()->get_data()).hash() : 0);
				hashes.push_back(region->get_height_map().is_valid() ? Variant(region->get_height_map()->get_data()).hash() : 0);
				return hashes;
			});
}

Dictionary Terrain3D::_load_svt_cell(const Vector2i &p_cell) {
	// Explicit/incremental bake validation only. Runtime reads use the worker.
	String path = _svt_page_path(p_cell, 0);
	if (path.is_empty() || !FileAccess::file_exists(path)) { return Dictionary(); }
	Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
	Variant value = file.is_valid() ? file->get_var(false) : Variant();
	if (value.get_type() != Variant::DICTIONARY) { return Dictionary(); }
	Dictionary saved = value;
	if (int(saved.get("version", 0)) != TerrainVTCell::FORMAT_VERSION || uint32_t(int64_t(saved.get("signature", 0))) != _svt_cell_signature(p_cell)) { return Dictionary(); }
	return saved;
}

Array Terrain3D::get_svt_baked_pages() {
	// Two kinds of source can serve a far page: a persisted bake on disk, which the runtime
	// will read once, and a cell that is already resident on the GPU (baked in this session,
	// or imported). The browser lists both. A persisted bake keeps its tile - it is the
	// artifact a caller tracks by path - and a resident cell only adds a tile when no bake
	// file describes that address.
	if (!_vt.vt_svt_catalog_loaded && !_data_directory.is_empty()) {
		_vt.vt_svt_catalog_loaded = true;
		for (const Vector2i &cell : _data->get_region_locations()) {
			if (_vt.vt_svt_tiles.has(tile_key(cell, 0))) {
				continue;
			}
			String path = _svt_page_path(cell, 0);
			if (!FileAccess::file_exists(path)) {
				continue;
			}
			Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
			Variant value = file.is_valid() ? file->get_var(false) : Variant();
			if (value.get_type() != Variant::DICTIONARY) {
				continue;
			}
			Dictionary source = value;
			if (int(source.get("version", 0)) != TerrainVTCell::FORMAT_VERSION) {
				continue;
			}
			Dictionary tile;
			tile["world_rect"] = source["world_rect"];
			Vector2i size = source["preview_size"];
			tile["preview"] = Image::create_from_data(size.x, size.y, false, Image::FORMAT_RGBAH, source["preview"]);
			tile["path"] = path;
			tile["address"] = cell;
			tile["mip"] = 0;
			tile["kind"] = "SVT";
			tile["slot"] = -1;
			tile["border"] = 0;
			tile["resolution"] = source["resolution"];
			tile["storage"] = "Baked cell mip chain";
			_vt.vt_svt_tiles[tile_key(cell, 0)] = tile;
		}
	}
	// Resident cells whose address no bake file describes: listed with an empty path, since
	// what the runtime serves them from is device memory and not a file.
	if (_vt.svt_cells.is_valid() && _vt.svt_cells->is_initialized()) {
		for (const Variant &entry : _vt.svt_cells->get_catalog()) {
			Dictionary tile = entry;
			const Vector2i address = tile.get("address", Vector2i());
			if (_vt.vt_svt_tiles.has(tile_key(address, 0))) {
				continue;
			}
			_vt.vt_svt_tiles[tile_key(address, 0)] = tile;
		}
	}
	return _vt.vt_svt_tiles.values();
}

int Terrain3D::bake_svt() {
	_vt.svt_cell_baker.unref();
	_vt.svt_cell_job.clear();
	if (!_data || _vt.vt_debug_direct_material) {
		return 0;
	}
	set_surface_svt_enabled(true);
	_update_vt_service();
	_vt.vt_svt_bake_queue.clear();
	for (const Variant &slot : _vt.vt_svt_bake_waiting.keys()) {
		if (int(slot) >= 0) {
			_vt.surface_svt->protect_page(int(slot), false);
		}
	}
	_vt.vt_svt_bake_waiting.clear();
	_vt.vt_svt_dirty_regions.clear();
	// The explicit job owns the progress counters until it has fully drained, including the
	// cell it happens to be baking when its queue empties.
	_vt.vt_svt_explicit_bake = true;
	return _queue_svt_bake(Dictionary());
}

void Terrain3D::set_svt_auto_bake(bool p_enabled) {
	_vt.svt_auto_bake = p_enabled;
	if (p_enabled && _data) {
		for (const Vector2i &location : _data->get_region_locations()) {
			_vt.vt_svt_dirty_regions[location] = true;
		}
		_vt.vt_svt_edit_time = Time::get_singleton()->get_ticks_msec();
	}
}

void Terrain3D::_process_svt_auto_bake() {
	if (is_vt_editor_preview_active() || !_vt.svt_auto_bake || !_vt.surface_svt_enabled || _data_directory.is_empty() || _vt.vt_svt_dirty_regions.is_empty() ||
			!_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty() || _vt.vt_svt_explicit_bake ||
			Time::get_singleton()->get_ticks_msec() - _vt.vt_svt_edit_time < 500) {
		return;
	}
	Dictionary dirty = _vt.vt_svt_dirty_regions.duplicate();
	_vt.vt_svt_dirty_regions.clear();
	_queue_svt_bake(dirty);
}

int Terrain3D::_queue_svt_bake(const Dictionary &p_dirty_regions) {
	_vt.vt_svt_bake_generation++;
	_vt.vt_svt_bake_incremental = !p_dirty_regions.is_empty();
	for (const Vector2i &cell : _data->get_region_locations()) {
		bool affected = p_dirty_regions.is_empty();
		for (const Variant &key : p_dirty_regions.keys()) {
			Vector2i delta = Vector2i(key) - cell;
			if (ABS(delta.x) <= 1 && ABS(delta.y) <= 1) {
				affected = true;
				break;
			}
		}
		if (affected) {
			_vt.vt_svt_bake_queue.push_back(Vector3i(cell.x, cell.y, 0));
		}
	}
	_vt.vt_svt_bake_total = _vt.vt_svt_bake_queue.size();
	_vt.vt_svt_bake_done = 0;
	_vt.vt_svt_bake_failed = 0;
	_vt.vt_svt_bake_error = String();
	return _vt.vt_svt_bake_total;
}

void Terrain3D::_process_svt_bake(int p_page_budget) {
	if (!_data || _data_directory.is_empty()) {
		return;
	}
	if (!_vt.svt_cell_job.is_empty()) {
		Terrain3DSurfaceBaker *producer = baker(_vt.svt_cell_baker);
		if (!producer) {
			return;
		}
		if (!producer->is_page_ready(0)) {
			int ticks = int(_vt.svt_cell_job.get("ticks", 0)) + 1;
			_vt.svt_cell_job["ticks"] = ticks;
			if (ticks < 600) {
				return;
			}
			_vt.vt_svt_bake_failed++;
			_vt.vt_svt_bake_error = "Cell bake timed out.";
		} else {
			Dictionary channels = producer->export_page(0);
			Vector2i cell = _vt.svt_cell_job["cell"];
			bool valid = bool(channels.get("valid", false)) && uint32_t(int64_t(_vt.svt_cell_job["signature"])) == _svt_cell_signature(cell);
			Dictionary images;
			int resolution = _vt.svt_cell_job["resolution"];
			if (valid) {
				for (const String &name : { String("albedo_height"), String("normal_roughness"), String("params") }) {
					Ref<Image> image = channels[name];
					image = image->get_region(Rect2i(1, 1, resolution, resolution));
					valid = image->generate_mipmaps() == OK && valid;
					images[name] = image;
				}
			}
			String path = _svt_page_path(cell, 0);
			// The resident copy is published first and independently of the file: it is what
			// the runtime reads, and a read-only or full disk must not stop the far field
			// from being served from device memory.
			Vector2i evicted(INT32_MAX, INT32_MAX);
			bool resident = false;
			if (valid && _vt.svt_cells.is_valid() && _vt.svt_cells->is_initialized()) {
				const Ref<Image> cell_channels[3] = { images["albedo_height"], images["normal_roughness"], images["params"] };
				resident = _vt.svt_cells->publish_cell(cell, _svt_cell_state_key(cell),
						_vt.svt_cell_job["world_rect"], cell_channels, resolution, &evicted);
				if (resident) { _vt.svt_cell_file_probe[(int64_t(cell.x) << 32) ^ uint32_t(cell.y)] = 1; }
			}
			if (valid) {
				Dictionary saved;
				saved["version"] = TerrainVTCell::FORMAT_VERSION;
				saved["signature"] = _vt.svt_cell_job["signature"];
				saved["world_rect"] = _vt.svt_cell_job["world_rect"];
				saved["density"] = get_surface_svt_texels_per_meter();
				Ref<Image> albedo = images["albedo_height"];
				Ref<Image> preview = cell_mip(albedo, MAX(0, albedo->get_mipmap_count() - 7));
				saved["preview"] = preview->get_data();
				saved["preview_size"] = preview->get_size();
				saved["resolution"] = resolution;
				DirAccess::make_dir_recursive_absolute(path.get_base_dir());
				String temporary = path + ".tmp";
				Ref<FileAccess> file = FileAccess::open(temporary, FileAccess::WRITE);
				valid = file.is_valid();
				if (valid) {
					const int levels = albedo->get_mipmap_count() + 1;
					PackedInt64Array index;
					index.resize(levels * 6);
					saved["levels"] = levels;
					saved["index"] = index;
					file->store_var(saved, false);
					const uint64_t header_end = file->get_position();
					const String names[] = { "albedo_height", "normal_roughness", "params" };
					for (int mip = 0; mip < levels; ++mip) {
						for (int channel = 0; channel < 3; ++channel) {
							Ref<Image> image = images[names[channel]];
							PackedByteArray compressed = cell_mip(image, mip)->get_data().compress(FileAccess::COMPRESSION_ZSTD);
							index.set(mip * 6 + channel * 2, file->get_position());
							index.set(mip * 6 + channel * 2 + 1, compressed.size());
							file->store_buffer(compressed);
						}
					}
					valid = file->get_error() == OK;
					saved["index"] = index;
					file->seek(0);
					file->store_var(saved, false);
					valid = valid && file->get_error() == OK && file->get_position() == header_end;
					file->close();
				}
				if (valid) {
					valid = DirAccess::rename_absolute(temporary, path) == OK;
				}
			}
			if (valid || resident) {
				_vt.vt_svt_bake_done++;
				_vt.svt_cells_baked++;
				_vt.vt_svt_catalog_loaded = false;
				_vt.vt_svt_tiles.clear();
				// Requeue the pages that sample this cell, so they are assembled from the
				// bake that just landed instead of the payloads they were baked from. A cell
				// that was evicted to make room has to be requeued the same way: its pages
				// now name a layer that holds another cell.
				const Rect2 requeue_rects[] = { Rect2(_vt.svt_cell_job["world_rect"]),
					evicted.x == INT32_MAX ? Rect2() : Rect2(Vector2(evicted) * float(_region_size) * _vertex_spacing,
															Vector2(float(_region_size) * _vertex_spacing, float(_region_size) * _vertex_spacing)) };
				for (const Rect2 &cell_rect : requeue_rects) {
					if (cell_rect.size.x <= 0.f) {
						continue;
					}
					for (const Variant &key : _vt.vt_page_records.keys()) {
						Dictionary record = _vt.vt_page_records[key];
						Rect2 rect = record["world_rect"];
						if (record.get("kind", String()) != Variant("SVT") || !rect.grow(rect.size.x * _vt.vt_page_border / _vt.vt_page_size).intersects(cell_rect)) {
							continue;
						}
						Ref<Image> payload;
						_queue_vt_material_page(int(key), payload, rect, true, int(record["mip"]), record["address"]);
					}
				}
			} else {
				_vt.vt_svt_bake_failed++;
				_vt.vt_svt_bake_error = "Cell changed during baking or could not be saved: " + path;
			}
		}
		_vt.svt_cell_job.clear();
		_vt.vt_svt_bake_waiting.clear();
		_vt.svt_cell_baker.unref();
		return;
	}
	if (_vt.vt_svt_bake_queue.is_empty() || p_page_budget == 0) {
		return;
	}
	Vector3i request = _vt.vt_svt_bake_queue[0];
	_vt.vt_svt_bake_queue.remove_at(0);
	Vector2i cell(request.x, request.y);
	if (_vt.vt_svt_bake_incremental && !_load_svt_cell(cell).is_empty()) {
		_vt.vt_svt_bake_done++;
		return;
	}
	float world = _region_size * _vertex_spacing;
	int resolution = int(Math::ceil(world * get_surface_svt_texels_per_meter()));
	if (resolution < 1 || resolution > 8192) {
		_vt.vt_svt_bake_failed++;
		_vt.vt_svt_bake_error = "Cell source resolution exceeds the supported 8192 texels; lower SVT density.";
		return;
	}
	Rect2 rect(Vector2(cell) * world, Vector2(world, world));
	Ref<Image> ids;
	if (_data->produce_surface_rect_page(rect, resolution, 1, ids) < 0) {
		_vt.vt_svt_bake_failed++;
		return;
	}
	Ref<Image> height;
	Ref<Terrain3DSurfaceBaker> producer;
	producer.instantiate();
	producer->configure(resolution, 1, 2);
	producer->set_materials(_assets->get_albedo_array_rid(), _assets->get_normal_array_rid(),
			_assets->get_texture_colors(), _assets->get_texture_normal_depths(), _assets->get_texture_ao_strengths(),
			_assets->get_texture_ao_light_affects(), _assets->get_texture_roughness_mods(), _assets->get_texture_uv_scales(),
			_assets->get_texture_detiles(), _assets->get_texture_slope_params());
	_vt.svt_cell_baker = producer;
	_vt.svt_cell_job["cell"] = cell;
	_vt.svt_cell_job["world_rect"] = rect;
	_vt.svt_cell_job["resolution"] = resolution;
	_vt.svt_cell_job["signature"] = int64_t(_svt_cell_signature(cell));
	_vt.vt_svt_bake_waiting[-1] = 0;
	const Vector3 source_grid = bake_source_grid(_data, rect, resolution, 1,
			_vertex_spacing / _surface_density, ids, height);
	if (height.is_null()) { height = _data->make_vt_height_page(rect, resolution, 1); }
	producer->queue_page(0, ids, height, rect, 1.f, source_grid);
	RS->call_on_render_thread(Callable(producer.ptr(), "render_pending").bind(_vt.svt_cell_baker));
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
	ClassDB::bind_method(D_METHOD("get_vt_material_textures"), &Terrain3D::get_vt_material_textures);
	ClassDB::bind_method(D_METHOD("get_vt_page_preview", "slot"), &Terrain3D::get_vt_page_preview);
	ClassDB::bind_method(D_METHOD("get_svt_baked_pages"), &Terrain3D::get_svt_baked_pages);
	ClassDB::bind_method(D_METHOD("get_surface_vt_block_sizes"), &Terrain3D::get_surface_vt_block_sizes);
	ClassDB::bind_method(D_METHOD("invalidate_vt_materials"), &Terrain3D::invalidate_vt_materials);
	ClassDB::bind_method(D_METHOD("set_svt_auto_bake", "enabled"), &Terrain3D::set_svt_auto_bake);
	ClassDB::bind_method(D_METHOD("is_svt_auto_bake"), &Terrain3D::is_svt_auto_bake);
	ClassDB::bind_method(D_METHOD("bake_svt"), &Terrain3D::bake_svt);
}
