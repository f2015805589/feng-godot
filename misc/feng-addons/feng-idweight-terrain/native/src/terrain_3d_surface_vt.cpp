// Copyright © 2026 Terrain3D contributors.
#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_virtual_texture.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <cstring>

namespace {
Terrain3DSurfaceBaker *baker(const Ref<RefCounted> &p_ref) {
	return Object::cast_to<Terrain3DSurfaceBaker>(p_ref.ptr());
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
Ref<Image> cell_mip_crop(const Ref<Image> &image, int level, const Rect2i &rect) {
	const int width = MAX(1, image->get_width() >> level);
	const int stride = image->get_format() == Image::FORMAT_RGBAH ? 8 : 16;
	PackedByteArray bytes = image->get_data(), cropped;
	cropped.resize(int64_t(rect.size.x) * rect.size.y * stride);
	const uint8_t *source = bytes.ptr() + image->get_mipmap_offset(level);
	uint8_t *target = cropped.ptrw();
	for (int y = 0; y < rect.size.y; ++y) {
		std::memcpy(target + int64_t(y) * rect.size.x * stride,
				source + (int64_t(rect.position.y + y) * width + rect.position.x) * stride, size_t(rect.size.x) * stride);
	}
	return Image::create_from_data(rect.size.x, rect.size.y, false, image->get_format(), cropped);
}

} //namespace

void Terrain3D::set_surface_vt_resolution(int p_resolution) {
	ERR_FAIL_COND(p_resolution != 512 && p_resolution != 1024 && p_resolution != 2048 && p_resolution != 4096);
	// A block has a power-of-two page count (at most 64). Normalize legacy
	// non-power-of-two page sizes so the displayed virtual resolution is exact.
	int page_size = MAX(16, p_resolution / 64);
	while (page_size * 2 <= MIN(_vt_page_size, p_resolution)) {
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
	if (_vt_page_size == p_size) {
		return;
	}
	const real_t svt_density = get_surface_svt_texels_per_meter();
	_vt_page_size = p_size;
	_surface_svt_page_world = _vt_page_size / svt_density;
	_reset_vt_configuration();
}
void Terrain3D::set_vt_page_border(int p_border) {
	p_border = CLAMP(p_border, 1, 16);
	if (_vt_page_border == p_border) {
		return;
	}
	_vt_page_border = p_border;
	_reset_vt_configuration();
}
void Terrain3D::set_vt_page_count(int p_count) {
	p_count = CLAMP(p_count, 8, 1024);
	if (_vt_page_count == p_count) {
		return;
	}
	_vt_page_count = p_count;
	_reset_vt_configuration();
}
void Terrain3D::set_vt_pages_per_update(int p_pages) {
	_vt_pages_per_update = CLAMP(p_pages, 1, 64);
}

void Terrain3D::_cancel_svt_bake(const String &p_reason) {
	_svt_cell_job.clear();
	_svt_cell_baker.unref();
	if (!_vt_svt_bake_queue.is_empty() || !_vt_svt_bake_waiting.is_empty()) {
		_vt_svt_bake_failed += _vt_svt_bake_queue.size() + _vt_svt_bake_waiting.size();
		_vt_svt_bake_error = p_reason;
	}
	if (_surface_svt && _surface_svt->is_initialized()) {
		for (const Variant &slot : _vt_svt_bake_waiting.keys()) {
			if (int(slot) >= 0) {
				_surface_svt->protect_page(int(slot), false);
			}
		}
	}
	_vt_svt_bake_queue.clear();
	_vt_svt_bake_waiting.clear();
}

void Terrain3D::_reset_vt_configuration() {
	// Old world addresses and channel dimensions cannot survive reconfiguration.
	_cancel_svt_bake("VT configuration changed; run Bake SVT again.");
	_svt_cell_cache.clear();
	_vt_shared_ready = false;
	invalidate_vt_materials();
}
void Terrain3D::set_vt_adaptive_enabled(bool p_enabled) {
	_vt_adaptive_enabled = p_enabled;
}
void Terrain3D::set_vt_debug_direct_material(bool p_enabled) {
	if (_vt_debug_direct_material == p_enabled) {
		return;
	}
	_vt_debug_direct_material = p_enabled;
	_destroy_vt_service();
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
}

void Terrain3D::_configure_vt_service() {
	if (_vt_debug_direct_material || !_surface_vt || !_surface_svt) {
		return;
	}
	if (_vt_shared_ready) {
		return;
	}
	// Detach both views before replacing their common pool. Clearing one view must
	// never destroy a pool that another view is still sampling.
	auto pool = Terrain3DVirtualTexture::create_page_pool();
	for (Terrain3DVirtualTexture *view : { _surface_vt, _surface_svt }) {
		view->clear();
		view->set_page_size(_vt_page_size);
		view->set_page_border(_vt_page_border);
		view->set_page_count(_vt_page_count);
		view->set_page_pool(pool);
		if (view == _surface_vt) {
			view->set_indirection_size(is_sector_avt() ? 2048 : MAX(64, _surface_vt_page_count * 4));
		}
		view->initialize();
	}
	_surface_vt_page_size = _surface_svt_page_size = _vt_page_size;
	_surface_vt_page_border = _surface_svt_page_border = _vt_page_border;
	_surface_vt_page_count = _surface_svt_page_count = _vt_page_count;
	_surface_vt_blocks.clear();
	_surface_vt_block_sizes.clear();
	_surface_vt_blocks_dirty = true;
	_vt_page_records.clear();
	_vt_registered_sectors.clear();
	_avt_directory_bytes.clear();
	_avt_plan_key.clear();
	_avt_page_plan.clear();
	_avt_registered_owners.clear();
	_avt_allocated_sizes.clear();
	_avt_sector_directory.unref();
	_avt_directory_mask = 0;
	_avt_sector_stats.clear();
	if (_vt_baker.is_null()) {
		Ref<Terrain3DSurfaceBaker> instance;
		instance.instantiate();
		_vt_baker = instance;
	}
	baker(_vt_baker)->configure(_vt_page_size, _vt_page_border, _vt_page_count);
	_vt_bound_albedo = RID();
	if (_initialized && _material.is_valid()) {
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
	_vt_materials_dirty = true;
	_vt_shared_ready = true;
}

void Terrain3D::_update_vt_service() {
	if (!_surface_svt_enabled) {
		_cancel_svt_bake("SVT was disabled; the offline bake was cancelled.");
	}
	if (!_surface_vt_enabled && !_surface_svt_enabled) {
		if (_vt_callback_registered && RS->has_method("virtual_texture_remove_update_callback")) {
			RS->call("virtual_texture_remove_update_callback", int64_t(get_instance_id()));
			_vt_callback_registered = false;
		}
		return;
	}
	if (_vt_debug_direct_material || !_data || _assets.is_null()) {
		return;
	}
	_configure_vt_service();
	Terrain3DSurfaceBaker *producer = baker(_vt_baker);
	if (!producer) {
		return;
	}
	if (!_vt_callback_registered && RS->has_method("virtual_texture_set_update_callback")) {
		RS->call("virtual_texture_set_update_callback", int64_t(get_instance_id()),
				Callable(producer, "render_pending").bind(_vt_baker));
		_vt_callback_registered = true;
	}
	if (_vt_materials_dirty) {
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
		_vt_material_signature = signature.hash();
		_vt_materials_dirty = false;
		// Re-request old addresses using the current materials; stale pages remain
		// hidden until their producer has completed again.
		for (const Vector2i &location : _data->get_region_locations()) {
			invalidate_surface_pages(location);
		}
	}
	RID albedo = producer->get_albedo_rid();
	if (albedo != _vt_bound_albedo && _material.is_valid()) {
		_vt_bound_albedo = albedo;
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
	if (_material.is_valid()) {
		RS->material_set_param(_material->get_material_rid(), "_avt_fade_enabled", is_sector_avt());
		if (is_sector_avt()) {
			PackedColorArray fades;
			fades.resize(256); fades.fill(Color(1, 1, 1, 1));
			const uint64_t now = Time::get_singleton()->get_ticks_msec();
			for (const Variant &key : _vt_page_records.keys()) {
				int slot = key;
				if (slot < 0 || slot >= 1024) { continue; }
				Dictionary record = _vt_page_records[key];
				if (record.get("kind", String()) != Variant("AVT")) { continue; }
				if (!producer->is_page_ready(slot)) { Color fade = fades[slot >> 2]; fade[slot & 3] = 0.f; fades[slot >> 2] = fade; record.erase("ready_since"); continue; }
				if (!record.has("ready_since")) { record["ready_since"] = int64_t(now); }
				float phase = CLAMP(float(now - uint64_t(int64_t(record["ready_since"]))) / 200.f, 0.f, 1.f);
				Color fade = fades[slot >> 2]; fade[slot & 3] = phase * phase * (3.f - 2.f * phase); fades[slot >> 2] = fade;
			}
			RS->material_set_param(_material->get_material_rid(), "_avt_slot_fade", fades);
		}
	}
	_process_svt_auto_bake();
}

void Terrain3D::_destroy_vt_service() {
	_svt_cell_baker.unref();
	_svt_cell_cache.clear();
	if (_vt_callback_registered && RS && RS->has_method("virtual_texture_remove_update_callback")) {
		RS->call("virtual_texture_remove_update_callback", int64_t(get_instance_id()));
	}
	_vt_callback_registered = false;
	_vt_baker.unref();
	_vt_bound_albedo = RID();
	_vt_shared_ready = false;
	_vt_page_records.clear();
	_vt_registered_sectors.clear();
	_vt_svt_bake_queue.clear();
	_vt_svt_bake_waiting.clear();
}

void Terrain3D::invalidate_vt_materials() {
	_vt_materials_dirty = true;
	_vt_source_revision++;
}

void Terrain3D::_invalidate_vt_slot(int p_slot) {
	if (_vt_baker.is_valid() && p_slot >= 0) {
		baker(_vt_baker)->invalidate_slot(p_slot);
	}
	_vt_page_records.erase(p_slot);
}

String Terrain3D::_svt_page_path(const Vector2i &p_address, int p_mip) const {
	if (_data_directory.is_empty()) {
		return String();
	}
	return _data_directory.path_join("svt_cells").path_join(tile_key(p_address, 0) + ".vtcell");
}

int Terrain3D::prepare_vt_capture() {
	Terrain3DSurfaceBaker *producer = baker(_vt_baker);
	if (!producer || _vt_debug_direct_material || !_data) {
		return 0;
	}
	// Reissue resident production into the same slots for a diagnostic capture.
	// This does not evict pages, edit terrain, or run a persistent full bake.
	const Array records = _vt_page_records.values();
	const int stored_size = _vt_page_size + 2 * _vt_page_border;
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
		bool p_svt, int p_mip, const Vector2i &p_address) {
	Terrain3DSurfaceBaker *producer = baker(_vt_baker);
	if (_vt_debug_direct_material || !producer || p_slot < 0 || p_payload.is_null()) {
		return;
	}
	Ref<Image> height = _data->make_vt_height_page(p_rect, _vt_page_size, _vt_page_border);
	if (height.is_null()) {
		return;
	}
	Dictionary record;
	record["slot"] = p_slot;
	record["kind"] = p_svt ? "SVT" : "AVT";
	record["state"] = "Pending bake";
	record["world_rect"] = p_rect;
	record["mip"] = p_mip;
	record["address"] = p_address;
	record["revision"] = int64_t(_vt_source_revision);
	record["source"] = p_payload->get_data();
	record["height"] = height->get_data();
	_vt_page_records[p_slot] = record;
	if (p_svt) {
		const float world = _region_size * _vertex_spacing;
		const float pixel = p_rect.size.x / _vt_page_size;
		const Rect2 footprint = p_rect.grow(pixel * _vt_page_border);
		Array sources;
		bool missing = false;
		for (const Vector2i &cell : _data->get_region_locations()) {
			const Rect2 rect(Vector2(cell) * world, Vector2(world, world));
			if (!rect.intersects(footprint)) {
				continue;
			}
			int requested_mip = MAX(0, int(Math::floor(Math::log(MAX(1.f, pixel * get_surface_svt_texels_per_meter())) / Math::log(2.f))));
			Dictionary source = _load_svt_cell(cell, requested_mip);
			if (source.is_empty()) {
				missing = true;
				if (_svt_auto_bake && !_data_directory.is_empty()) {
					if (_vt_svt_dirty_regions.is_empty()) {
						_vt_svt_edit_time = 0;
					}
					_vt_svt_dirty_regions[cell] = true;
				}
				continue;
			}
			Dictionary channels = source["images"];
			Dictionary piece;
			piece["cell_rect"] = rect;
			for (const String &name : { String("albedo_height"), String("normal_roughness"), String("params") }) {
				Ref<Image> full = channels[name];
				int level = 0; // Only the selected cell mip was read from disk.
				int mip_size = MAX(1, full->get_width() >> level);
				float step = world / mip_size;
				Rect2 area = footprint.intersection(rect);
				Vector2i origin(MAX(0, int(Math::floor((area.position.x - rect.position.x) / step)) - 1), MAX(0, int(Math::floor((area.position.y - rect.position.y) / step)) - 1));
				Vector2i end(MIN(mip_size, int(Math::ceil((area.get_end().x - rect.position.x) / step)) + 1), MIN(mip_size, int(Math::ceil((area.get_end().y - rect.position.y) / step)) + 1));
				piece[name] = cell_mip_crop(full, level, Rect2i(origin, end - origin));
				piece["source_rect"] = Rect2(rect.position + Vector2(origin) * step, Vector2(end - origin) * step);
			}
			sources.push_back(piece);
		}
		if (!missing && !sources.is_empty()) {
			record["state"] = "Pending cell copy";
			producer->queue_cell_page(p_slot, sources, p_rect);
		} else {
			record["state"] = "Missing/stale cell bake";
			producer->invalidate_slot(p_slot);
		}
		return;
	}
	producer->queue_page(p_slot, p_payload, height, p_rect, 1.f);
}

void Terrain3D::_invalidate_vt_region(const Vector2i &p_region) {
	_svt_cell_cache.clear();
	_vt_svt_dirty_regions[p_region] = true;
	_vt_svt_edit_time = Time::get_singleton()->get_ticks_msec();
	if (_vt_baker.is_null()) {
		return;
	}
	float world = float(_region_size) * _vertex_spacing;
	Rect2 affected(Vector2(p_region) * world, Vector2(world, world));
	Array keys = _vt_page_records.keys();
	for (int i = 0; i < keys.size(); i++) {
		Dictionary record = _vt_page_records[keys[i]];
		Rect2 rect = record["world_rect"];
		if (rect.grow(MAX(_vertex_spacing, rect.size.x * float(_vt_page_border + 1) / _vt_page_size)).intersects(affected)) {
			if (_vt_svt_bake_waiting.has(keys[i])) {
				Vector2i address = record["address"];
				_vt_svt_bake_queue.push_back(Vector3i(address.x, address.y, int(record["mip"])));
				_vt_svt_bake_waiting.erase(keys[i]);
			}
			baker(_vt_baker)->invalidate_slot(int(keys[i]));
			// Border edits can affect a neighbour's page. Remove its address too,
			// otherwise the scheduler would keep treating an invalid payload as a hit.
			for (const Dictionary &owner : _surface_vt->get_slot_owner_metadata(int(keys[i]))) {
				int mip = owner["mip"];
				Vector2i address = owner["virtual"];
				if (bool(owner["world_space"])) {
					int half = _surface_svt->get_indirection_size() >> 1;
					_surface_svt->release_world_page((address.x << mip) - half, (address.y << mip) - half, mip);
				} else {
					Vector2i sector = owner["sector"];
					int x = address.x - (_surface_vt->get_sector_block_origin_x(sector) >> mip);
					int y = address.y - (_surface_vt->get_sector_block_origin_y(sector) >> mip);
					_surface_vt->release_page(sector, mip, x, y);
				}
			}
			_vt_page_records.erase(keys[i]);
		}
	}
}

Dictionary Terrain3D::get_vt_material_textures() const {
	Dictionary result;
	if (_vt_debug_direct_material || _vt_baker.is_null()) {
		return result;
	}
	result["albedo_height"] = baker(_vt_baker)->get_albedo_rid();
	result["normal_roughness"] = baker(_vt_baker)->get_normal_rid();
	result["params"] = baker(_vt_baker)->get_params_rid();
	return result;
}
Dictionary Terrain3D::get_vt_settings() const {
	Dictionary result;
	result["page_size"] = _vt_page_size;
	result["border"] = _vt_page_border;
	result["page_count"] = _vt_page_count;
	// Three RGBA16F outputs, R16 IDs, and R16+R32F bake staging per slot.
	result["physical_cache_bytes"] = int64_t(_vt_page_size + 2 * _vt_page_border) * (_vt_page_size + 2 * _vt_page_border) * _vt_page_count * 32;
	result["pages_per_update"] = _vt_pages_per_update;
	result["shared_pool"] = _vt_shared_ready;
	result["adaptive"] = _vt_adaptive_enabled;
	result["avt_texels_per_pixel"] = _surface_vt_texels_per_pixel;
	result["avt_resolution"] = get_surface_vt_resolution(); // Legacy API only.
	result["avt_distance"] = _surface_vt_distance;
	result["avt_texels_per_meter"] = get_surface_vt_texels_per_meter();
	result["svt_texels_per_meter"] = get_surface_svt_texels_per_meter();
	result["svt_world_extent"] = (_surface_svt ? _surface_svt->get_indirection_size() : MAX(64, _surface_svt_page_count * 4)) * _surface_svt_page_world;
	result["avt_virtual_resolution"] = 64.f * get_surface_vt_texels_per_meter();
	result["avt_base_block_size"] = get_avt_base_block_size();
	result["avt_sector_world"] = is_sector_avt() ? 64.0 : double(_region_size * _vertex_spacing);
	result["avt_sector_stats"] = _avt_sector_stats;
	result["svt_effective_max_mip"] = _surface_svt ? _surface_svt->get_world_max_mip() : _surface_svt_max_mip;
	result["avt_selection_mode"] = _surface_vt_selection_mode;
	result["avt_region_grid"] = _surface_vt_region_grid;
	result["avt_region_offset"] = _surface_vt_region_offset;
	result["avt_forward_regions"] = _surface_vt_forward_regions;
	result["avt_region_rect"] = get_surface_vt_region_rect();
	result["callback_registered"] = _vt_callback_registered;
	result["material_signature"] = int64_t(_vt_material_signature);
	result["auto_bake"] = _svt_auto_bake;
	result["auto_pending_regions"] = _vt_svt_dirty_regions.size();
	result["bake_generation"] = int64_t(_vt_svt_bake_generation);
	result["bake_incremental"] = _vt_svt_bake_incremental;
	result["bake_total"] = _vt_svt_bake_total;
	result["cells_baked"] = int64_t(_svt_cells_baked);
	result["bake_done"] = _vt_svt_bake_done;
	result["bake_pending"] = _vt_svt_bake_queue.size() + _vt_svt_bake_waiting.size();
	result["bake_failed"] = _vt_svt_bake_failed;
	result["bake_error"] = _vt_svt_bake_error;
	if (_vt_baker.is_valid()) {
		result["producer"] = baker(_vt_baker)->get_stats();
	}
	if (_surface_vt) {
		result["residency"] = _surface_vt->get_stats();
	}
	return result;
}
Array Terrain3D::get_vt_pages() const {
	Array result;
	for (const Variant &key : _vt_page_records.keys()) {
		if (!_surface_vt || _surface_vt->get_slot_owner_count(int(key)) == 0) {
			continue;
		}
		Dictionary record = Dictionary(_vt_page_records[key]).duplicate();
		record.erase("source");
		record.erase("height");
		record["ready"] = _vt_baker.is_valid() && baker(_vt_baker)->is_page_ready(int(key));
		if (bool(record["ready"])) {
			record["state"] = "Ready";
		}
		record["owners"] = _surface_vt ? _surface_vt->get_slot_owner_metadata(int(key)) : Array();
		result.push_back(record);
	}
	return result;
}
Ref<Image> Terrain3D::get_vt_page_preview(int p_slot) {
	return _vt_baker.is_valid() ? baker(_vt_baker)->get_page_preview(p_slot) : Ref<Image>();
}
uint32_t Terrain3D::_svt_cell_signature(const Vector2i &p_cell) const {
	Dictionary signature;
	signature["materials"] = int64_t(_vt_material_signature);
	signature["density"] = get_surface_svt_texels_per_meter();
	signature["spacing"] = _vertex_spacing;
	signature["region_size"] = _region_size;
	// Neighbour heights affect normals at the cell edge.
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			Ref<Terrain3DRegion> region = _data->get_region(p_cell + Vector2i(x, y));
			if (region.is_null() || region->is_deleted()) {
				continue;
			}
			Array hashes;
			hashes.push_back(region->get_control_map().is_valid() ? Variant(region->get_control_map()->get_data()).hash() : 0);
			hashes.push_back(region->get_surface_map().is_valid() ? Variant(region->get_surface_map()->get_data()).hash() : 0);
			hashes.push_back(region->get_height_map().is_valid() ? Variant(region->get_height_map()->get_data()).hash() : 0);
			signature[Vector2i(x, y)] = hashes;
		}
	}
	return signature.hash();
}

Dictionary Terrain3D::_load_svt_cell(const Vector2i &p_cell, int p_mip) {
	const Vector3i cache_key(p_cell.x, p_cell.y, p_mip);
	if (p_mip >= 0 && _svt_cell_cache.has(cache_key)) {
		return _svt_cell_cache[cache_key];
	}
	String path = _svt_page_path(p_cell, 0);
	if (path.is_empty() || !FileAccess::file_exists(path)) {
		return Dictionary();
	}
	Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
	Variant value = file.is_valid() ? file->get_var(false) : Variant();
	if (value.get_type() != Variant::DICTIONARY) {
		return Dictionary();
	}
	Dictionary saved = value;
	if (int(saved.get("version", 0)) != 3 || uint32_t(int64_t(saved.get("signature", 0))) != _svt_cell_signature(p_cell)) {
		return Dictionary();
	}
	if (p_mip < 0) {
		return saved; // Startup validation reads no full source textures.
	}
	int resolution = saved.get("resolution", 0);
	int levels = saved.get("levels", 0);
	PackedInt64Array index = saved.get("index", PackedInt64Array());
	if (resolution < 1 || resolution > 8192 || levels < 1 || levels > 14 || index.size() != levels * 6) {
		return Dictionary();
	}
	int mip = MIN(p_mip, levels - 1), size = MAX(1, resolution >> mip);
	Dictionary channels;
	const String names[] = { "albedo_height", "normal_roughness", "params" };
	for (int channel = 0; channel < 3; ++channel) {
		int64_t offset = index[mip * 6 + channel * 2], length = index[mip * 6 + channel * 2 + 1];
		if (offset < 0 || length <= 0 || uint64_t(offset + length) > file->get_length()) {
			return Dictionary();
		}
		file->seek(offset);
		PackedByteArray data = file->get_buffer(length).decompress(int64_t(size) * size * 8, FileAccess::COMPRESSION_ZSTD);
		if (data.size() != int64_t(size) * size * 8) {
			return Dictionary();
		}
		channels[names[channel]] = Image::create_from_data(size, size, false, Image::FORMAT_RGBAH, data);
	}
	saved["images"] = channels;
	saved["bytes"] = int64_t(size) * size * 24;
	int64_t bytes = saved["bytes"];
	for (const Dictionary &cached : _svt_cell_cache.values()) {
		bytes += int64_t(cached["bytes"]);
	}
	// Bounded selected-mip cache; one oversized fine mip is allowed alone.
	while (!_svt_cell_cache.is_empty() && (bytes > 256 * 1024 * 1024 || _svt_cell_cache.size() >= 64)) {
		Variant key = _svt_cell_cache.keys()[0];
		Dictionary old = _svt_cell_cache[key];
		bytes -= int64_t(old["bytes"]);
		_svt_cell_cache.erase(key);
	}
	_svt_cell_cache[cache_key] = saved;
	return saved;
}

Array Terrain3D::get_svt_baked_pages() {
	if (!_vt_svt_catalog_loaded && !_data_directory.is_empty()) {
		_vt_svt_catalog_loaded = true;
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
			if (int(source.get("version", 0)) != 3) {
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
			_vt_svt_tiles[tile_key(cell, 0)] = tile;
		}
	}
	return _vt_svt_tiles.values();
}

int Terrain3D::bake_svt() {
	_svt_cell_baker.unref();
	_svt_cell_job.clear();
	if (!_data || _vt_debug_direct_material) {
		return 0;
	}
	set_surface_svt_enabled(true);
	_update_vt_service();
	_vt_svt_bake_queue.clear();
	for (const Variant &slot : _vt_svt_bake_waiting.keys()) {
		if (int(slot) >= 0) {
			_surface_svt->protect_page(int(slot), false);
		}
	}
	_vt_svt_bake_waiting.clear();
	_vt_svt_dirty_regions.clear();
	return _queue_svt_bake(Dictionary());
}

void Terrain3D::set_svt_auto_bake(bool p_enabled) {
	_svt_auto_bake = p_enabled;
	if (p_enabled && _data) {
		for (const Vector2i &location : _data->get_region_locations()) {
			_vt_svt_dirty_regions[location] = true;
		}
		_vt_svt_edit_time = Time::get_singleton()->get_ticks_msec();
	}
}

void Terrain3D::_process_svt_auto_bake() {
	if (!_svt_auto_bake || !_surface_svt_enabled || _data_directory.is_empty() || _vt_svt_dirty_regions.is_empty() ||
			!_vt_svt_bake_queue.is_empty() || !_vt_svt_bake_waiting.is_empty() ||
			Time::get_singleton()->get_ticks_msec() - _vt_svt_edit_time < 500) {
		return;
	}
	Dictionary dirty = _vt_svt_dirty_regions.duplicate();
	_vt_svt_dirty_regions.clear();
	_queue_svt_bake(dirty);
}

int Terrain3D::_queue_svt_bake(const Dictionary &p_dirty_regions) {
	_vt_svt_bake_generation++;
	_vt_svt_bake_incremental = !p_dirty_regions.is_empty();
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
			_vt_svt_bake_queue.push_back(Vector3i(cell.x, cell.y, 0));
		}
	}
	_vt_svt_bake_total = _vt_svt_bake_queue.size();
	_vt_svt_bake_done = 0;
	_vt_svt_bake_failed = 0;
	_vt_svt_bake_error = String();
	return _vt_svt_bake_total;
}

void Terrain3D::_process_svt_bake(int p_page_budget) {
	if (!_data || _data_directory.is_empty()) {
		return;
	}
	if (!_svt_cell_job.is_empty()) {
		Terrain3DSurfaceBaker *producer = baker(_svt_cell_baker);
		if (!producer) {
			return;
		}
		if (!producer->is_page_ready(0)) {
			int ticks = int(_svt_cell_job.get("ticks", 0)) + 1;
			_svt_cell_job["ticks"] = ticks;
			if (ticks < 600) {
				return;
			}
			_vt_svt_bake_failed++;
			_vt_svt_bake_error = "Cell bake timed out.";
		} else {
			Dictionary channels = producer->export_page(0);
			Vector2i cell = _svt_cell_job["cell"];
			bool valid = bool(channels.get("valid", false)) && uint32_t(int64_t(_svt_cell_job["signature"])) == _svt_cell_signature(cell);
			Dictionary images;
			int resolution = _svt_cell_job["resolution"];
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
				saved["version"] = 3;
				saved["signature"] = _svt_cell_job["signature"];
				saved["world_rect"] = _svt_cell_job["world_rect"];
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
				_vt_svt_bake_done++;
				_svt_cells_baked++;
				_svt_cell_cache.clear();
				_vt_svt_catalog_loaded = false;
				_vt_svt_tiles.clear();
				// Requeue resident runtime pages from the newly persisted source.
				const Rect2 cell_rect = _svt_cell_job["world_rect"];
				for (const Variant &key : _vt_page_records.keys()) {
					Dictionary record = _vt_page_records[key];
					Rect2 rect = record["world_rect"];
					if (record.get("kind", String()) != Variant("SVT") || !rect.grow(rect.size.x * _vt_page_border / _vt_page_size).intersects(cell_rect)) {
						continue;
					}
					Ref<Image> payload;
					if (_data->produce_surface_rect_page(rect, _vt_page_size, _vt_page_border, payload) >= 0) {
						_queue_vt_material_page(int(key), payload, rect, true, int(record["mip"]), record["address"]);
					}
				}
			} else {
				_vt_svt_bake_failed++;
				_vt_svt_bake_error = "Cell changed during baking or could not be saved: " + path;
			}
		}
		_svt_cell_job.clear();
		_vt_svt_bake_waiting.clear();
		_svt_cell_baker.unref();
		return;
	}
	if (_vt_svt_bake_queue.is_empty() || p_page_budget == 0) {
		return;
	}
	Vector3i request = _vt_svt_bake_queue[0];
	_vt_svt_bake_queue.remove_at(0);
	Vector2i cell(request.x, request.y);
	if (_vt_svt_bake_incremental && !_load_svt_cell(cell).is_empty()) {
		_vt_svt_bake_done++;
		return;
	}
	float world = _region_size * _vertex_spacing;
	int resolution = int(Math::ceil(world * get_surface_svt_texels_per_meter()));
	if (resolution < 1 || resolution > 8192) {
		_vt_svt_bake_failed++;
		_vt_svt_bake_error = "Cell source resolution exceeds the supported 8192 texels; lower SVT density.";
		return;
	}
	Rect2 rect(Vector2(cell) * world, Vector2(world, world));
	Ref<Image> ids;
	if (_data->produce_surface_rect_page(rect, resolution, 1, ids) < 0) {
		_vt_svt_bake_failed++;
		return;
	}
	Ref<Image> height = _data->make_vt_height_page(rect, resolution, 1);
	Ref<Terrain3DSurfaceBaker> producer;
	producer.instantiate();
	producer->configure(resolution, 1, 2);
	producer->set_materials(_assets->get_albedo_array_rid(), _assets->get_normal_array_rid(),
			_assets->get_texture_colors(), _assets->get_texture_normal_depths(), _assets->get_texture_ao_strengths(),
			_assets->get_texture_ao_light_affects(), _assets->get_texture_roughness_mods(), _assets->get_texture_uv_scales(),
			_assets->get_texture_detiles(), _assets->get_texture_slope_params());
	_svt_cell_baker = producer;
	_svt_cell_job["cell"] = cell;
	_svt_cell_job["world_rect"] = rect;
	_svt_cell_job["resolution"] = resolution;
	_svt_cell_job["signature"] = int64_t(_svt_cell_signature(cell));
	_vt_svt_bake_waiting[-1] = 0;
	producer->queue_page(0, ids, height, rect);
	RS->call_on_render_thread(Callable(producer.ptr(), "render_pending").bind(_svt_cell_baker));
}

void Terrain3D::_bind_vt_methods() {
#define VT_BIND_SETTING(name) \
	ClassDB::bind_method(D_METHOD("set_" #name, "value"), &Terrain3D::set_##name); \
	ClassDB::bind_method(D_METHOD("get_" #name), &Terrain3D::get_##name)
	VT_BIND_SETTING(vt_page_size);
	VT_BIND_SETTING(vt_page_border);
	VT_BIND_SETTING(vt_page_count);
	VT_BIND_SETTING(vt_pages_per_update);
#undef VT_BIND_SETTING
	ClassDB::bind_method(D_METHOD("set_vt_adaptive_enabled", "enabled"), &Terrain3D::set_vt_adaptive_enabled);
	ClassDB::bind_method(D_METHOD("is_vt_adaptive_enabled"), &Terrain3D::is_vt_adaptive_enabled);
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
