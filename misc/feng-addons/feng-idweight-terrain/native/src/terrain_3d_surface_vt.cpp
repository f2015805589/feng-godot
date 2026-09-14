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
bool Terrain3D::_ensure_vt_capacity(int p_required) {
	Terrain3DSurfaceBaker *producer = _vt.vt_baker.is_valid() ? baker(_vt.vt_baker) : nullptr;
	if (_vt.vt_shared_ready && producer && !_vt.vt_debug_direct_material) {
		const int ready_capacity = producer->get_capacity();
		if (ready_capacity > _vt.vt_page_count) {
			// Publish higher slot IDs only after the GPU cache was copied. Keep
			// addresses, owners and source jobs, including an already completed plan.
			if (!_vt.surface_vt->grow_capacity(ready_capacity) || !_vt.surface_svt->grow_capacity(ready_capacity)) { return false; }
			_vt.vt_page_count = _vt.surface_vt_page_count = _vt.surface_svt_page_count = ready_capacity;
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

void Terrain3D::_reset_vt_configuration() {
	// Old world addresses and channel dimensions cannot survive reconfiguration.
	_cancel_svt_bake("VT configuration changed; run Bake SVT again.");
	_vt.vt_shared_ready = false;
	invalidate_vt_materials();
}
void Terrain3D::set_surface_vt_coarse_mip_fallback(bool p_enabled) {
	if (_vt.surface_vt_coarse_mip_fallback == p_enabled) { return; }
	_vt.surface_vt_coarse_mip_fallback = p_enabled;
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
	_vt.vt_source_snapshot.reset();
	_vt.avt_refinement.reset();
	_vt.avt_plan_key.clear();
	if (_vt.vt_page_pipeline) { _vt.vt_page_pipeline->reset(); }
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->reset(); }
	// Detach both views before replacing their common pool. Clearing one view must
	// never destroy a pool that another view is still sampling.
	auto pool = Terrain3DVirtualTexture::create_page_pool();
	// Both views adopt the shared dimensions before they are configured, so the one
	// configuration helper describes the view that is actually built.
	_vt.surface_vt_page_size = _vt.surface_svt_page_size = _vt.vt_page_size;
	_vt.surface_vt_page_border = _vt.surface_svt_page_border = _vt.vt_page_border;
	_vt.surface_vt_page_count = _vt.surface_svt_page_count = _vt.vt_page_count;
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
	baker(_vt.vt_baker)->configure(_vt.vt_page_size, _vt.vt_page_border, _vt.vt_page_count);
	_vt.vt_bound_albedo = RID();
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
	_vt.vt_materials_dirty = true;
	_vt.vt_shared_ready = true;
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
	}
	if (_vt.vt_materials_dirty) {
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
	if (albedo != _vt.vt_bound_albedo && _material.is_valid()) {
		_vt.vt_bound_albedo = albedo;
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
		producer->acknowledge_output(albedo);
	}

	_process_async_svt_pages();
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
			if (result.payload.is_valid() && _vt.surface_svt->write_page(slot, result.payload)) {
				record["source"] = result.payload->get_data();
			}
			if (result.missing.empty() && !result.sources.is_empty()) {
				record["state"] = "Pending cell copy";
				baker(_vt.vt_baker)->queue_cell_page(slot, result.sources, it->second.rect);
			} else {
				record["state"] = "Missing/stale cell bake";
				if (_vt.svt_auto_bake && !_data_directory.is_empty()) {
					for (const Vector2i &cell : result.missing) {
						if (_vt.vt_svt_dirty_regions.is_empty()) { _vt.vt_svt_edit_time = 0; }
						_vt.vt_svt_dirty_regions[cell] = true;
					}
				}
			}
		}
		it = _vt.svt_pending_pages.erase(it);
		if (++submitted >= _vt.vt_pages_per_update) { break; }
	}
}

void Terrain3D::_destroy_vt_service() {
	if (_vt.surface_vt) { _vt.surface_vt->set_material_cache_mode(false); }
	if (_vt.surface_svt) { _vt.surface_svt->set_material_cache_mode(false); }
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
	record["state"] = p_svt ? "Pending cell read" : "Pending bake";
	record["world_rect"] = p_rect;
	record["mip"] = p_mip;
	record["address"] = p_address;
	record["revision"] = int64_t(_vt.vt_source_revision);
	record["source"] = p_payload.is_valid() ? p_payload->get_data() : PackedByteArray();
	_vt.vt_page_records[p_slot] = record;
	if (p_svt) {
		if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->cancel({p_slot, 0, 0, 0, 0}); }
		Terrain3DPagePipeline::Request request{{p_slot, 0, 0, 0, 0}, p_rect, _vt.vt_page_size, _vt.vt_page_border};
		request.svt = true; request.directory = _data_directory;
		request.materials = _vt.vt_material_signature; request.density = get_surface_svt_texels_per_meter();
		_vt.svt_pending_pages[p_slot] = std::move(request);
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
	result["albedo_height"] = baker(_vt.vt_baker)->get_albedo_rid();
	result["normal_roughness"] = baker(_vt.vt_baker)->get_normal_rid();
	result["params"] = baker(_vt.vt_baker)->get_params_rid();
	return result;
}
Dictionary Terrain3D::get_vt_settings() const {
	Dictionary result;
	result["page_size"] = _vt.vt_page_size;
	result["border"] = _vt.vt_page_border;
	result["page_count"] = _vt.vt_page_count;
	result["auto_capacity"] = _vt.vt_auto_capacity;
	// Three RGBA16F outputs, R16 IDs, and R16+R32F bake staging per slot.
	result["physical_cache_bytes"] = int64_t(_vt.vt_page_size + 2 * _vt.vt_page_border) * (_vt.vt_page_size + 2 * _vt.vt_page_border) * _vt.vt_page_count * 32;
	result["pages_per_update"] = _vt.vt_pages_per_update;
	result["shared_pool"] = _vt.vt_shared_ready;
	result["adaptive"] = _vt.vt_adaptive_enabled;
	result["avt_coarse_mip_fallback"] = _vt.surface_vt_coarse_mip_fallback;
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
	if (!_vt.vt_svt_catalog_loaded && !_data_directory.is_empty()) {
		_vt.vt_svt_catalog_loaded = true;
		for (const Vector2i &cell : _data->get_region_locations()) {
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
			!_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty() ||
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
			if (valid) {
				_vt.vt_svt_bake_done++;
				_vt.svt_cells_baked++;
				_vt.vt_svt_catalog_loaded = false;
				_vt.vt_svt_tiles.clear();
				// Requeue resident runtime pages from the newly persisted source.
				const Rect2 cell_rect = _vt.svt_cell_job["world_rect"];
				for (const Variant &key : _vt.vt_page_records.keys()) {
					Dictionary record = _vt.vt_page_records[key];
					Rect2 rect = record["world_rect"];
					if (record.get("kind", String()) != Variant("SVT") || !rect.grow(rect.size.x * _vt.vt_page_border / _vt.vt_page_size).intersects(cell_rect)) {
						continue;
					}
					Ref<Image> payload;
					_queue_vt_material_page(int(key), payload, rect, true, int(record["mip"]), record["address"]);
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
#undef VT_BIND_SETTING
	ClassDB::bind_method(D_METHOD("set_surface_vt_coarse_mip_fallback", "enabled"), &Terrain3D::set_surface_vt_coarse_mip_fallback);
	ClassDB::bind_method(D_METHOD("get_surface_vt_coarse_mip_fallback"), &Terrain3D::get_surface_vt_coarse_mip_fallback);
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
