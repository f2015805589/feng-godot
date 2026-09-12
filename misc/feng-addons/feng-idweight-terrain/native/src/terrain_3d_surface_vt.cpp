// Copyright © 2026 Terrain3D contributors.
#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_virtual_texture.h"
#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/time.hpp>

namespace {
Terrain3DSurfaceBaker *baker(const Ref<RefCounted> &p_ref) {
	return Object::cast_to<Terrain3DSurfaceBaker>(p_ref.ptr());
}
String tile_key(const Vector2i &p_address, int p_mip) {
	return String::num_int64(p_address.x) + "_" + String::num_int64(p_address.y) + "_" + String::num_int64(p_mip);
}
Dictionary pack_channels(const Dictionary &p_channels) {
	Dictionary result;
	for (const String &name : { String("albedo_height"), String("normal_roughness"), String("params") }) {
		Ref<Image> image = p_channels.get(name, Variant());
		if (image.is_null()) { return Dictionary(); }
		Dictionary channel;
		channel["size"] = image->get_size();
		channel["format"] = int(image->get_format());
		channel["data"] = image->get_data();
		result[name] = channel;
	}
	return result;
}
Dictionary unpack_channels(const Dictionary &p_channels) {
	Dictionary result;
	for (const String &name : { String("albedo_height"), String("normal_roughness"), String("params") }) {
		Dictionary channel = p_channels.get(name, Dictionary());
		Vector2i size = channel.get("size", Vector2i());
		int format = channel.get("format", -1);
		if (size.x <= 0 || size.x > 4224 || size.x != size.y ||
				(format != Image::FORMAT_RGBAH && format != Image::FORMAT_RGBAF)) { return Dictionary(); }
		Ref<Image> image = Image::create_from_data(size.x, size.y, false, Image::Format(format), channel.get("data", PackedByteArray()));
		if (image.is_null() || image->is_empty()) { return Dictionary(); }
		result[name] = image;
	}
	return result;
}
}

void Terrain3D::set_vt_page_size(int p_size) {
	p_size = CLAMP(p_size, 16, 1024);
	if (_vt_page_size == p_size) { return; }
	_vt_page_size = p_size;
	_reset_vt_configuration();
}
void Terrain3D::set_vt_page_border(int p_border) {
	p_border = CLAMP(p_border, 1, 16);
	if (_vt_page_border == p_border) { return; }
	_vt_page_border = p_border;
	_reset_vt_configuration();
}
void Terrain3D::set_vt_page_count(int p_count) {
	p_count = CLAMP(p_count, 8, 1024);
	if (_vt_page_count == p_count) { return; }
	_vt_page_count = p_count;
	_reset_vt_configuration();
}
void Terrain3D::set_vt_pages_per_update(int p_pages) { _vt_pages_per_update = CLAMP(p_pages, 1, 64); }

void Terrain3D::_cancel_svt_bake(const String &p_reason) {
	if (!_vt_svt_bake_queue.is_empty() || !_vt_svt_bake_waiting.is_empty()) {
		_vt_svt_bake_failed += _vt_svt_bake_queue.size() + _vt_svt_bake_waiting.size();
		_vt_svt_bake_error = p_reason;
	}
	if (_surface_svt && _surface_svt->is_initialized()) {
		for (const Variant &slot : _vt_svt_bake_waiting.keys()) { _surface_svt->protect_page(int(slot), false); }
	}
	_vt_svt_bake_queue.clear();
	_vt_svt_bake_waiting.clear();
}

void Terrain3D::_reset_vt_configuration() {
	// Old world addresses and channel dimensions cannot survive reconfiguration.
	_cancel_svt_bake("VT configuration changed; run Bake SVT again.");
	_vt_shared_ready = false;
	invalidate_vt_materials();
}
void Terrain3D::set_vt_adaptive_enabled(bool p_enabled) { _vt_adaptive_enabled = p_enabled; }
void Terrain3D::set_vt_debug_direct_material(bool p_enabled) {
	if (_vt_debug_direct_material == p_enabled) { return; }
	_vt_debug_direct_material = p_enabled;
	_destroy_vt_service();
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
}

void Terrain3D::_configure_vt_service() {
	if (_vt_debug_direct_material || !_surface_vt || !_surface_svt) { return; }
	if (_vt_shared_ready) { return; }
	// Detach both views before replacing their common pool. Clearing one view must
	// never destroy a pool that another view is still sampling.
	auto pool = Terrain3DVirtualTexture::create_page_pool();
	for (Terrain3DVirtualTexture *view : { _surface_vt, _surface_svt }) {
		view->clear();
		view->set_page_size(_vt_page_size);
		view->set_page_border(_vt_page_border);
		view->set_page_count(_vt_page_count);
		view->set_page_pool(pool);
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
	if (_vt_baker.is_null()) {
		Ref<Terrain3DSurfaceBaker> instance;
		instance.instantiate();
		_vt_baker = instance;
	}
	baker(_vt_baker)->configure(_vt_page_size, _vt_page_border, _vt_page_count);
	_vt_bound_albedo = RID();
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::REGION_ARRAYS); }
	_vt_materials_dirty = true;
	_vt_shared_ready = true;
}

void Terrain3D::_update_vt_service() {
	if (!_surface_svt_enabled) { _cancel_svt_bake("SVT was disabled; the offline bake was cancelled."); }
	if (!_surface_vt_enabled && !_surface_svt_enabled) {
		if (_vt_callback_registered && RS->has_method("virtual_texture_remove_update_callback")) {
			RS->call("virtual_texture_remove_update_callback", int64_t(get_instance_id()));
			_vt_callback_registered = false;
		}
		return;
	}
	if (_vt_debug_direct_material || !_data || _assets.is_null()) { return; }
	_configure_vt_service();
	Terrain3DSurfaceBaker *producer = baker(_vt_baker);
	if (!producer) { return; }
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
		for (const Vector2i &location : _data->get_region_locations()) { invalidate_surface_pages(location); }
	}
	RID albedo = producer->get_albedo_rid();
	if (albedo != _vt_bound_albedo && _material.is_valid()) {
		_vt_bound_albedo = albedo;
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
	}
	_process_svt_auto_bake();
}

void Terrain3D::_destroy_vt_service() {
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
	if (_vt_baker.is_valid() && p_slot >= 0) { baker(_vt_baker)->invalidate_slot(p_slot); }
	_vt_page_records.erase(p_slot);
}

String Terrain3D::_svt_page_path(const Vector2i &p_address, int p_mip) const {
	if (_data_directory.is_empty()) { return String(); }
	return _data_directory.path_join("svt").path_join(tile_key(p_address, p_mip) + ".vtpage");
}

void Terrain3D::_queue_vt_material_page(int p_slot, const Ref<Image> &p_payload, const Rect2 &p_rect,
		bool p_svt, int p_mip, const Vector2i &p_address) {
	Terrain3DSurfaceBaker *producer = baker(_vt_baker);
	if (_vt_debug_direct_material || !producer || p_slot < 0 || p_payload.is_null()) { return; }
	Ref<Image> height = _data->make_vt_height_page(p_rect, _vt_page_size, _vt_page_border);
	if (height.is_null()) { return; }
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
		String path = _svt_page_path(p_address, p_mip);
		record["path"] = path;
		bool exists = !path.is_empty() && FileAccess::file_exists(path);
		if (exists && (!_vt_offline_producing || _vt_svt_bake_incremental)) {
			Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
			Variant data = file.is_valid() ? file->get_var(false) : Variant();
			if (data.get_type() == Variant::DICTIONARY) {
				Dictionary saved = data;
				record["cache_reason"] = "Invalid channel data";
				if (int(saved.get("version", 0)) != 1) { record["cache_reason"] = "Cache version changed"; }
				else if (uint32_t(int64_t(saved.get("materials", 0))) != _vt_material_signature) { record["cache_reason"] = "Material settings changed"; }
				else if (int(saved.get("border", -1)) != _vt_page_border) { record["cache_reason"] = "Page border changed"; }
				else if (saved.get("source", Variant()) != record["source"]) { record["cache_reason"] = "Surface data changed"; }
				else if (saved.get("height", Variant()) != record["height"]) { record["cache_reason"] = "Height data changed"; }
				if (int(saved.get("version", 0)) == 1 && uint32_t(int64_t(saved.get("materials", 0))) == _vt_material_signature &&
						int(saved.get("border", -1)) == _vt_page_border && saved.get("source", Variant()) == record["source"] &&
						saved.get("height", Variant()) == record["height"]) {
					Dictionary channels = unpack_channels(saved.get("channels", Dictionary()));
					if (!channels.is_empty()) {
						record["state"] = "Pending upload";
						record.erase("cache_reason");
						producer->queue_cached_page(p_slot, channels);
						Dictionary tile = record.duplicate();
						tile["preview"] = channels["albedo_height"];
						tile["path"] = path;
						_vt_svt_tiles[tile_key(p_address, p_mip)] = tile;
						return;
					}
				}
			}
		}
		if (!_vt_offline_producing) {
			// Normal VT rendering exposes missing/stale tiles as diagnostics.
			// A dirty-page automatic bake or manual full bake produces replacements.
			record["state"] = exists ? "Stale/invalid bake" : "Missing bake";
			producer->invalidate_slot(p_slot);
			return;
		}
	}
	producer->queue_page(p_slot, p_payload, height, p_rect, 1.f);
}

void Terrain3D::_invalidate_vt_region(const Vector2i &p_region) {
	_vt_svt_dirty_regions[p_region] = true;
	_vt_svt_edit_time = Time::get_singleton()->get_ticks_msec();
	if (_vt_baker.is_null()) { return; }
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
	if (_vt_debug_direct_material || _vt_baker.is_null()) { return result; }
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
	result["bake_done"] = _vt_svt_bake_done;
	result["bake_pending"] = _vt_svt_bake_queue.size() + _vt_svt_bake_waiting.size();
	result["bake_failed"] = _vt_svt_bake_failed;
	result["bake_error"] = _vt_svt_bake_error;
	if (_vt_baker.is_valid()) { result["producer"] = baker(_vt_baker)->get_stats(); }
	if (_surface_vt) { result["residency"] = _surface_vt->get_stats(); }
	return result;
}
Array Terrain3D::get_vt_pages() const {
	Array result;
	for (const Variant &key : _vt_page_records.keys()) {
		if (!_surface_vt || _surface_vt->get_slot_owner_count(int(key)) == 0) { continue; }
		Dictionary record = Dictionary(_vt_page_records[key]).duplicate();
		record.erase("source");
		record.erase("height");
		record["ready"] = _vt_baker.is_valid() && baker(_vt_baker)->is_page_ready(int(key));
		if (bool(record["ready"])) { record["state"] = "Ready"; }
		record["owners"] = _surface_vt ? _surface_vt->get_slot_owner_metadata(int(key)) : Array();
		result.push_back(record);
	}
	return result;
}
Ref<Image> Terrain3D::get_vt_page_preview(int p_slot) {
	return _vt_baker.is_valid() ? baker(_vt_baker)->get_page_preview(p_slot) : Ref<Image>();
}
Array Terrain3D::get_svt_baked_pages() {
	// Catalog loading is an explicit editor operation, not part of the per-frame
	// scheduler. Previously baked tiles remain visible even when they are evicted.
	if (!_vt_svt_catalog_loaded && !_data_directory.is_empty()) {
		_vt_svt_catalog_loaded = true;
		String directory = _data_directory.path_join("svt");
		if (DirAccess::dir_exists_absolute(directory)) {
			for (const String &name : DirAccess::get_files_at(directory)) {
				if (!name.ends_with(".vtpage")) { continue; }
				String key = name.get_basename();
				if (_vt_svt_tiles.has(key)) { continue; }
				Ref<FileAccess> file = FileAccess::open(directory.path_join(name), FileAccess::READ);
				Variant value = file.is_valid() ? file->get_var(false) : Variant();
				if (value.get_type() != Variant::DICTIONARY) { continue; }
				Dictionary saved = value;
				Dictionary channels = unpack_channels(saved.get("channels", Dictionary()));
				PackedStringArray parts = key.split("_");
				if (channels.is_empty() || parts.size() != 3) { continue; }
				Dictionary tile;
				tile["world_rect"] = saved.get("world_rect", Rect2());
				tile["preview"] = channels["albedo_height"];
				tile["path"] = directory.path_join(name);
				tile["address"] = Vector2i(parts[0].to_int(), parts[1].to_int());
				tile["mip"] = parts[2].to_int();
				tile["kind"] = "SVT";
				tile["slot"] = -1;
				tile["border"] = saved.get("border", _vt_page_border);
				_vt_svt_tiles[key] = tile;
			}
		}
	}
	return _vt_svt_tiles.values();
}

int Terrain3D::bake_svt() {
	if (!_data || _vt_debug_direct_material) { return 0; }
	set_surface_svt_enabled(true);
	_update_vt_service();
	_vt_svt_bake_queue.clear();
	for (const Variant &slot : _vt_svt_bake_waiting.keys()) { _surface_svt->protect_page(int(slot), false); }
	_vt_svt_bake_waiting.clear();
	_vt_svt_dirty_regions.clear();
	return _queue_svt_bake(Dictionary());
}

void Terrain3D::set_svt_auto_bake(bool p_enabled) {
	_svt_auto_bake = p_enabled;
	if (p_enabled && _data) {
		for (const Vector2i &location : _data->get_region_locations()) { _vt_svt_dirty_regions[location] = true; }
		_vt_svt_edit_time = Time::get_singleton()->get_ticks_msec();
	}
}

void Terrain3D::_process_svt_auto_bake() {
	if (!_svt_auto_bake || !_surface_svt_enabled || _data_directory.is_empty() || _vt_svt_dirty_regions.is_empty() ||
			!_vt_svt_bake_queue.is_empty() || !_vt_svt_bake_waiting.is_empty() ||
			Time::get_singleton()->get_ticks_msec() - _vt_svt_edit_time < 500) { return; }
	Dictionary dirty = _vt_svt_dirty_regions.duplicate();
	_vt_svt_dirty_regions.clear();
	_queue_svt_bake(dirty);
}

int Terrain3D::_queue_svt_bake(const Dictionary &p_dirty_regions) {
	_vt_svt_bake_generation++;
	_vt_svt_bake_incremental = !p_dirty_regions.is_empty();
	Dictionary unique;
	float region_world = _region_size * _vertex_spacing;
	float page_world = _surface_svt_page_world;
	for (const Vector2i &location : _data->get_region_locations()) {
		Vector2 start = Vector2(location) * region_world;
		for (int y = int(Math::floor(start.y / page_world)); y < int(Math::ceil((start.y + region_world) / page_world)); y++) {
			for (int x = int(Math::floor(start.x / page_world)); x < int(Math::ceil((start.x + region_world) / page_world)); x++) {
				Vector2i address(x, y);
				for (int mip = 0; mip <= _surface_svt->get_world_max_mip(); mip++) {
					Vector2i aligned((address.x >> mip) << mip, (address.y >> mip) << mip);
					if (_vt_svt_bake_incremental) {
						float span = page_world * float(1 << mip);
						Rect2 footprint(Vector2(aligned) * page_world, Vector2(span, span));
						footprint = footprint.grow(MAX(_vertex_spacing, span * float(_vt_page_border + 1) / _vt_page_size));
						bool affected = false;
						for (const Variant &dirty : p_dirty_regions.keys()) {
							if (footprint.intersects(Rect2(Vector2(Vector2i(dirty)) * region_world, Vector2(region_world, region_world)))) {
								affected = true;
								break;
							}
						}
						if (!affected) { continue; }
					}
					String key = tile_key(aligned, mip);
					if (!unique.has(key)) {
						unique[key] = true;
						_vt_svt_bake_queue.push_back(Vector3i(aligned.x, aligned.y, mip));
					}
				}
			}
		}
	}
	_vt_svt_bake_total = _vt_svt_bake_queue.size();
	_vt_svt_bake_done = 0;
	_vt_svt_bake_failed = 0;
	_vt_svt_bake_error = String();
	return _vt_svt_bake_total;
}

void Terrain3D::_process_svt_bake(int p_page_budget) {
	Terrain3DSurfaceBaker *producer = baker(_vt_baker);
	if (!producer || !_surface_svt || (_vt_svt_bake_queue.is_empty() && _vt_svt_bake_waiting.is_empty())) { return; }
	// Only dirty-page persistence and manual baking read completed SVT pages back.
	// Idle frames and ordinary AVT updates never perform this readback.
	int exports_remaining = _vt_svt_bake_incremental ? 1 : _vt_pages_per_update;
	for (const Variant &key : _vt_svt_bake_waiting.keys()) {
		int slot = key;
		if (!producer->is_page_ready(slot)) {
			int ticks = int(_vt_svt_bake_waiting[key]) + 1;
			_vt_svt_bake_waiting[key] = ticks;
			if (ticks >= 600) {
				_surface_svt->protect_page(slot, false);
				_vt_svt_bake_waiting.erase(key);
				_vt_svt_bake_failed++;
				_vt_svt_bake_error = "VT Pass did not complete a page; check the renderer and shader errors.";
			}
			continue;
		}
		if (exports_remaining-- <= 0) { break; }
		Dictionary channels = producer->export_page(slot);
		if (!bool(channels.get("valid", false))) {
			_surface_svt->protect_page(slot, false);
			_vt_svt_bake_waiting.erase(key);
			_vt_svt_bake_failed++;
			_vt_svt_bake_error = "Cannot read back a completed material page.";
			continue;
		}
		Dictionary record = _vt_page_records.get(slot, Dictionary());
		if (record.is_empty()) {
			_surface_svt->protect_page(slot, false);
			_vt_svt_bake_waiting.erase(key);
			_vt_svt_bake_failed++;
			_vt_svt_bake_error = "Page ownership changed during baking.";
			continue;
		}
		Vector2i address = record["address"];
		int mip = record["mip"];
		Dictionary saved;
		saved["version"] = 1;
		saved["materials"] = int64_t(_vt_material_signature);
		saved["border"] = _vt_page_border;
		saved["source"] = record["source"];
		saved["height"] = record["height"];
		saved["channels"] = pack_channels(channels);
		saved["world_rect"] = record["world_rect"];
		String path = _svt_page_path(address, mip);
		if (!path.is_empty()) {
			DirAccess::make_dir_recursive_absolute(path.get_base_dir());
			Ref<FileAccess> file = FileAccess::open(path, FileAccess::WRITE);
			if (file.is_valid()) { file->store_var(saved, false); }
			else {
				_vt_svt_bake_failed++;
				_vt_svt_bake_error = "Cannot save SVT page: " + path;
			}
		}
		Dictionary tile = record.duplicate();
		tile.erase("source"); tile.erase("height");
		tile["preview"] = channels["albedo_height"];
		tile["path"] = path;
		_vt_svt_tiles[tile_key(address, mip)] = tile;
		_surface_svt->protect_page(slot, false);
		_vt_svt_bake_waiting.erase(key);
		_vt_svt_bake_done++;
	}
	// Automatic maintenance yields after one page to limit editing-frame stalls.
	int available = MIN(_vt_svt_bake_incremental ? 1 : _vt_pages_per_update, MAX(0, _vt_page_count / 2 - int(_vt_svt_bake_waiting.size())));
	if (p_page_budget >= 0) { available = MIN(available, p_page_budget); }
	while (available-- > 0 && !_vt_svt_bake_queue.is_empty()) {
		Vector3i request = _vt_svt_bake_queue[0];
		Vector2i address(request.x, request.y);
		int mip = request.z;
		bool miss = false;
		int slot = _surface_svt->request_world_page_internal(address.x, address.y, mip, &miss);
		if (slot < 0) {
			// Current AVT demand may temporarily occupy the cache. Wait for an
			// available slot instead of evicting visible AVT or dropping this job.
			break;
		}
		_invalidate_vt_slot(slot);
		Ref<Image> page;
		if (_data->produce_sparse_surface_page(address.x, address.y, mip, _surface_svt_page_world,
					_vt_page_size, _vt_page_border, page) < 0 || !_surface_svt->write_page(slot, page)) {
			_surface_svt->release_world_page(address.x, address.y, mip);
			_vt_svt_bake_queue.remove_at(0);
			_vt_svt_bake_failed++;
			_vt_svt_bake_error = "Cannot produce source data for an SVT page.";
			continue;
		}
		float span = _surface_svt_page_world * float(1 << mip);
		Rect2 rect(Vector2(address) * _surface_svt_page_world, Vector2(span, span));
		_vt_offline_producing = true;
		_queue_vt_material_page(slot, page, rect, true, mip, address);
		_vt_offline_producing = false;
		// A valid persisted tile needs no readback or file rewrite. This also
		// makes automatic startup validation cheap for unchanged pages.
		Dictionary queued = _vt_page_records.get(slot, Dictionary());
		if (_vt_svt_bake_incremental && queued.get("state", String()) == Variant("Pending upload")) {
			_vt_svt_bake_done++;
		} else {
			_surface_svt->protect_page(slot, true);
			_vt_svt_bake_waiting[slot] = 0;
		}
		_vt_svt_bake_queue.remove_at(0);
	}
	_surface_svt->commit();
	if (_surface_vt && _surface_vt->is_initialized()) { _surface_vt->commit(); }
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
