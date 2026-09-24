// Copyright © 2026 Terrain3D contributors.

// Terrain3D's virtual texture service, part 4 of 4: the far field's bake and its cell files.
//
// `bake_svt()`, the automatic pass behind it, the queue that serializes the two, and the .vtcell
// contract: the cell signature, the reader used to validate a bake, and the browser that lists
// what is baked. A bake writes cells to disk, which is a different job from producing pages - and
// it is the only half of the service that touches the filesystem.
//
// The other halves: terrain_3d_vt_service.cpp (settings and lifetime),
// terrain_3d_vt_service_pages.cpp (page plumbing and the cell store) and
// terrain_3d_vt_service_report.cpp (the diagnostics).

#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_vt_service_internal.h"
#include "terrain_vt_cell.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <utility>

// The two helpers the four halves share; see terrain_3d_vt_service_internal.h for what it holds
// and why it is a header.
using namespace terrain_surface_vt;

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

void Terrain3D::_cancel_svt_bake(const String &p_reason) {
	_vt.bake.cell_job.clear();
	_vt.bake.cell_baker.unref();
	// What the job still owed is lost, and only a job that owed something has a reason to record.
	if (_vt.bake.abandon() > 0) {
		_vt.bake.error = p_reason;
	}
	if (_vt.surface_svt && _vt.surface_svt->is_initialized()) {
		for (const Variant &slot : _vt.bake.waiting.keys()) {
			if (int(slot) >= 0) {
				_vt.surface_svt->protect_page(int(slot), false);
			}
		}
	}
	_vt.bake.queue.clear();
	_vt.bake.waiting.clear();
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
				return TerrainVTCell::source_hashes(
						region->get_control_map().is_valid() ? Variant(region->get_control_map()->get_data()).hash() : 0,
						region->get_surface_map().is_valid() ? Variant(region->get_surface_map()->get_data()).hash() : 0,
						region->get_height_map().is_valid() ? Variant(region->get_height_map()->get_data()).hash() : 0);
			});
}

Dictionary Terrain3D::_load_svt_cell(const Vector2i &p_cell) {
	// Explicit/incremental bake validation only. Runtime reads use the worker.
	const String path = _svt_page_path(p_cell);
	if (path.is_empty() || !FileAccess::file_exists(path)) { return Dictionary(); }
	Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
	const Variant value = file.is_valid() ? file->get_var(false) : Variant();
	if (value.get_type() != Variant::DICTIONARY) { return Dictionary(); }
	const Dictionary saved = value;
	return TerrainVTCell::header_is_current(saved, _svt_cell_signature(p_cell)) ? saved : Dictionary();
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
			String path = _svt_page_path(cell);
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
	_vt.bake.cell_baker.unref();
	_vt.bake.cell_job.clear();
	if (!_data || _vt.vt_debug_direct_material) {
		return 0;
	}
	set_surface_svt_enabled(true);
	_update_vt_service();
	_vt.bake.queue.clear();
	for (const Variant &slot : _vt.bake.waiting.keys()) {
		if (int(slot) >= 0) {
			_vt.surface_svt->protect_page(int(slot), false);
		}
	}
	_vt.bake.waiting.clear();
	_vt.bake.dirty_regions.clear();
	// The explicit job owns the progress counters until it has fully drained, including the
	// cell it happens to be baking when its queue empties.
	_vt.bake.explicit_job = true;
	return _queue_svt_bake(Dictionary());
}

void Terrain3D::set_svt_auto_bake(bool p_enabled) {
	_vt.svt_auto_bake = p_enabled;
	if (p_enabled && _data) {
		for (const Vector2i &location : _data->get_region_locations()) {
			_vt.bake.dirty_regions[location] = true;
		}
		_vt.bake.edit_time = Time::get_singleton()->get_ticks_msec();
	}
}

void Terrain3D::_process_svt_auto_bake() {
	if (is_vt_editor_preview_active() || !_vt.svt_auto_bake || !has_svt_delivery() || _data_directory.is_empty() || _vt.bake.dirty_regions.is_empty() ||
			_vt.bake.busy() || _vt.bake.explicit_job ||
			Time::get_singleton()->get_ticks_msec() - _vt.bake.edit_time < 500) {
		return;
	}
	Dictionary dirty = _vt.bake.dirty_regions.duplicate();
	_vt.bake.dirty_regions.clear();
	_queue_svt_bake(dirty);
}

int Terrain3D::_queue_svt_bake(const Dictionary &p_dirty_regions) {
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
			_vt.bake.queue.push_back(Vector3i(cell.x, cell.y, 0));
		}
	}
	// The job starts once its queue holds what it will drain: the counters describe this job and no
	// earlier one.
	_vt.bake.begin(!p_dirty_regions.is_empty());
	return _vt.bake.total;
}

void Terrain3D::_process_svt_bake(int p_page_budget) {
	if (!_data || _data_directory.is_empty()) {
		return;
	}
	if (!_vt.bake.cell_job.is_empty()) {
		Terrain3DSurfaceBaker *producer = baker(_vt.bake.cell_baker);
		if (!producer) {
			return;
		}
		if (!producer->is_page_ready(0)) {
			int ticks = int(_vt.bake.cell_job.get("ticks", 0)) + 1;
			_vt.bake.cell_job["ticks"] = ticks;
			if (ticks < 600) {
				return;
			}
			_vt.bake.fail("Cell bake timed out.");
		} else {
			Dictionary channels = producer->export_page(0);
			Vector2i cell = _vt.bake.cell_job["cell"];
			bool valid = bool(channels.get("valid", false)) && uint32_t(int64_t(_vt.bake.cell_job["signature"])) == _svt_cell_signature(cell);
			Dictionary images;
			int resolution = _vt.bake.cell_job["resolution"];
			if (valid) {
				for (const String &name : { String("albedo_height"), String("normal_roughness"), String("params") }) {
					Ref<Image> image = channels[name];
					image = image->get_region(Rect2i(1, 1, resolution, resolution));
					valid = image->generate_mipmaps() == OK && valid;
					images[name] = image;
				}
			}
			String path = _svt_page_path(cell);
			// The resident copy is published first and independently of the file: it is what
			// the runtime reads, and a read-only or full disk must not stop the far field
			// from being served from device memory.
			Vector2i evicted(INT32_MAX, INT32_MAX);
			bool resident = false;
			if (valid && _vt.svt_cells.is_valid() && _vt.svt_cells->is_initialized()) {
				const Ref<Image> cell_channels[3] = { images["albedo_height"], images["normal_roughness"], images["params"] };
				resident = _vt.svt_cells->publish_cell(cell, _svt_cell_state_key(cell),
						_vt.bake.cell_job["world_rect"], cell_channels, resolution, &evicted);
				if (resident) { _vt.svt_cell_file_probe[(int64_t(cell.x) << 32) ^ uint32_t(cell.y)] = 1; }
			}
			if (valid) {
				Dictionary saved;
				saved["version"] = TerrainVTCell::FORMAT_VERSION;
				saved["signature"] = _vt.bake.cell_job["signature"];
				saved["world_rect"] = _vt.bake.cell_job["world_rect"];
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
				_vt.bake.complete_cell();
				_vt.vt_svt_catalog_loaded = false;
				_vt.vt_svt_tiles.clear();
				// Requeue the pages that sample this cell, so they are assembled from the
				// bake that just landed instead of the payloads they were baked from. A cell
				// that was evicted to make room has to be requeued the same way: its pages
				// now name a layer that holds another cell.
				const Rect2 requeue_rects[] = { Rect2(_vt.bake.cell_job["world_rect"]),
					evicted.x == INT32_MAX ? Rect2() : Rect2(Vector2(evicted) * float(_region_size) * _vertex_spacing,
															Vector2(float(_region_size) * _vertex_spacing, float(_region_size) * _vertex_spacing)) };
				for (const Rect2 &cell_rect : requeue_rects) {
					if (cell_rect.size.x <= 0.f) {
						continue;
					}
					for (const auto &entry : _vt.vt_page_records) {
						const Terrain3DVTState::PageRecord &record = entry.second;
						const Rect2 rect = record.world_rect;
						if (!record.svt || !rect.grow(rect.size.x * _vt.vt_page_border / _vt.vt_page_size).intersects(cell_rect)) {
							continue;
						}
						Ref<Image> payload;
						_queue_vt_material_page(entry.first, payload, rect, true, record.mip, record.address);
					}
				}
			} else {
				_vt.bake.fail("Cell changed during baking or could not be saved: " + path);
			}
		}
		_vt.bake.cell_job.clear();
		_vt.bake.waiting.clear();
		_vt.bake.cell_baker.unref();
		return;
	}
	if (_vt.bake.queue.is_empty() || p_page_budget == 0) {
		return;
	}
	Vector3i request = _vt.bake.take_next();
	Vector2i cell(request.x, request.y);
	if (_vt.bake.incremental && !_load_svt_cell(cell).is_empty()) {
		// The cell is already baked on disk: it counts as done, but it is not a bake of this
		// session, so the cumulative `cells_baked` is deliberately left alone here.
		_vt.bake.done++;
		return;
	}
	float world = _region_size * _vertex_spacing;
	int resolution = int(Math::ceil(world * get_surface_svt_texels_per_meter()));
	if (resolution < 1 || resolution > 8192) {
		_vt.bake.fail("Cell source resolution exceeds the supported 8192 texels; lower SVT density.");
		return;
	}
	Rect2 rect(Vector2(cell) * world, Vector2(world, world));
	Ref<Image> ids;
	if (_data->produce_surface_rect_page(rect, resolution, 1, ids) < 0) {
		_vt.bake.failed++;
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
	_vt.bake.cell_baker = producer;
	_vt.bake.cell_job["cell"] = cell;
	_vt.bake.cell_job["world_rect"] = rect;
	_vt.bake.cell_job["resolution"] = resolution;
	_vt.bake.cell_job["signature"] = int64_t(_svt_cell_signature(cell));
	_vt.bake.waiting[-1] = 0;
	const Vector3 source_grid = bake_source_grid(_data, rect, resolution, 1,
			_vertex_spacing / _surface_density, ids, height);
	if (height.is_null()) { height = _data->make_vt_height_page(rect, resolution, 1); }
	producer->queue_page(0, ids, height, rect, 1.f, source_grid);
	RS->call_on_render_thread(Callable(producer.ptr(), "render_pending").bind(_vt.bake.cell_baker));
}
