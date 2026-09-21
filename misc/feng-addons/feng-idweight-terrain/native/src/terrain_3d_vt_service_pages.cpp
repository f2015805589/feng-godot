// Copyright © 2026 Terrain3D contributors.

// Terrain3D's virtual texture service, part 2 of 4: page plumbing and the cell store.
//
// Invalidation - one slot, one region, every material - the queue that turns a payload the
// producer finished into a material page, the resident far-field cell sources a page is assembled
// from, and the two helpers that decide whether such a page can be assembled at all. None of it
// plans demand; the demand passes are in terrain_3d_surface_views_far_walk.cpp,
// terrain_3d_surface_views_near.cpp and terrain_3d_sector_avt.cpp.
//
// The other halves: terrain_3d_vt_service.cpp (settings and lifetime),
// terrain_3d_vt_service_report.cpp (the diagnostics) and terrain_3d_vt_service_bake.cpp (the far
// field's bake and its cell files).

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_vt_service_internal.h"
#include "terrain_3d_virtual_texture.h"
#include "terrain_vt_cell.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/time.hpp>

#include <memory>
#include <utility>
#include <vector>

// The two helpers the four halves share; see terrain_3d_vt_service_internal.h for what it holds
// and why it is a header.
using namespace terrain_surface_vt;

void Terrain3D::_process_async_svt_pages() {
	if (_vt.svt_pending_pages.empty() || !_data || _vt.vt_baker.is_null()) { return; }
	if (!_vt.svt_page_pipeline) { _vt.svt_page_pipeline = std::make_unique<Terrain3DPagePipeline>(_vt.vt_page_workers); }
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
				record["source"] = result.payload;
			}
			bool cell_copy_queued = false;
			if (result.missing.empty() && !result.sources.is_empty()) {
				record["state"] = "Pending cell copy";
				baker(_vt.vt_baker)->queue_cell_page(slot, result.sources, it->second.rect,
						Terrain3DSurfaceBaker::TIER_SVT);
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
								it->second.rect, 1.f, source_grid, Terrain3DSurfaceBaker::TIER_SVT);
						cell_copy_queued = true;
					}
				}
				if (!cell_copy_queued) {
					record["state"] = "Missing/stale cell bake";
				}
				// A running explicit job already covers these cells: a full bake covers every
				// region. Arming the automatic job here makes it start the frame the explicit
				// job drains and replace its job-scoped progress counters.
				const bool explicit_job = _vt.bake.explicit_job || _vt.bake.busy();
				if (_vt.svt_auto_bake && !_data_directory.is_empty() && !explicit_job) {
					for (const Vector2i &cell : result.missing) {
						if (_vt.bake.dirty_regions.is_empty()) { _vt.bake.edit_time = 0; }
						_vt.bake.dirty_regions[cell] = true;
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

void Terrain3D::invalidate_vt_materials() {
	_vt.vt_materials_dirty = true;
	_vt.vt_source_revision++;
}

void Terrain3D::_flush_source_wakes() {
	if (_vt.vt_page_pipeline) { _vt.vt_page_pipeline->flush_wakes(); }
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->flush_wakes(); }
}

// The wakes a demand pass owes, released unless the tick will release them itself. A pass driven
// directly has no tick to wait for.
void Terrain3D::_flush_source_wakes_unless_ticking() {
	if (_vt.vt_tick_active) { return; }
	_flush_source_wakes();
}

void Terrain3D::_invalidate_vt_slot(int p_slot) {
	// The slot's content is gone, so whatever it holds next is an arrival. The fade has to be
	// told here and not only by the demand pass's readiness check: a page dropped and produced
	// again between two passes is an arrival no pass ever saw as empty, so it landed as a step -
	// the rectangular pop the fade exists to prevent. A page whose production is lost is
	// invalidated through this function, and so is the slot a page is about to be written into,
	// which is what makes every produced page an arrival the fade can see.
	_vt_mark_page_waiting(p_slot);
	_vt.svt_pending_pages.erase(p_slot);
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->cancel({p_slot, 0, 0, 0, 0}); }
	if (_vt.vt_baker.is_valid() && p_slot >= 0) {
		baker(_vt.vt_baker)->invalidate_slot(p_slot);
	}
	_vt.vt_page_records.erase(p_slot);
}

String Terrain3D::_svt_page_path(const Vector2i &p_address) const {
	if (_data_directory.is_empty()) {
		return String();
	}
	// Mip 0 names the cell; the cell's own mip chain lives inside the file.
	return TerrainVTCell::path(_data_directory, p_address, 0);
}

// How long a published page may stay without content before demand produces it again. Long
// enough that a bake, a cell copy and an asynchronous page read all complete first, short
// enough that a production that was dropped, refused, or that failed leaves the view missing
// for a fraction of a second.
static const uint64_t SVT_PAGE_RETRY_FRAMES = 30;

// A page is only a hit when its content is actually there. The virtual texture's
// indirection entry survives an invalidation - `_invalidate_vt_slot()` clears the material
// slot, not the table - so a page whose production was dropped, refused for lack of a
// source, or lost to a failed cell copy stays named by the table while the shader samples
// an empty layer. `request_world_page_internal()` then reports it as a hit, so nothing ever
// retried it: that is the far field that loads on one run and not on the next. Demand asks
// the producer, and only a page with content or with a recent production in flight is a hit.
//
// Both demand passes, the near field's production pass and the service ask this, so it belongs
// to page plumbing rather than to either view, and it sits beside the record it reads.
bool Terrain3D::_vt_page_production_stale(int p_slot) {
	return _vt_page_production_stale(p_slot, -1);
}

bool Terrain3D::_vt_page_production_stale(int p_slot, int p_ready) {
	if (p_slot < 0) {
		return true;
	}
	// A caller that has already asked the producer about a whole set passes that answer in,
	// so a verification pass costs one lock instead of one per page. The retry window below
	// is read from this side's records and needs no lock either way.
	if (p_ready < 0) {
		Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
		p_ready = (producer && producer->is_page_ready(p_slot)) ? 1 : 0;
	}
	if (p_ready != 0) {
		return false;
	}
	if (_vt.vt_page_records.has(p_slot)) {
		const Dictionary record = _vt.vt_page_records[p_slot];
		const uint64_t queued = uint64_t(int64_t(record.get("queued_frame", 0)));
		const uint64_t now = Engine::get_singleton()->get_process_frames();
		return now > queued + SVT_PAGE_RETRY_FRAMES;
	}
	return true;
}

bool Terrain3D::debug_invalidate_vt_page(int p_slot) {
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	if (!producer || p_slot < 0 || !producer->is_page_ready(p_slot)) {
		return false;
	}
	// This clears the page's compiled parameter page, which is the flag the shader reads to
	// decide whether a page is samplable. The demand pass then finds the address published over
	// empty content and produces it again, which is the arrival a fade is for.
	_invalidate_vt_slot(p_slot);
	return true;
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
		Ref<Image> source = record.get("source", Ref<Image>());
		if (source.is_null() || source->get_width() != stored_size || source->get_height() != stored_size) {
			continue;
		}
		_queue_vt_material_page(slot, source, record.get("world_rect", Rect2()),
				record.get("kind", String()) == Variant("SVT"), record.get("mip", 0),
				record.get("address", Vector2i()));
		++queued;
	}
	return queued;
}

bool Terrain3D::debug_lose_vt_page_readiness(int p_slot) {
	Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr());
	if (!producer || p_slot < 0 || !producer->is_page_ready(p_slot)) {
		return false;
	}
	producer->debug_clear_readiness(p_slot);
	return true;
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
	// The slot's content is being (re)written from here, so it is waiting for content until the
	// fade pass finds it ready. Every production funnels through this call, which is what makes
	// the arrival decision complete: a page re-produced into a *fresh* slot has no earlier
	// unready reading anywhere else.
	_vt_mark_page_waiting(p_slot);
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
	// The record holds the source image, not its bytes. A page's payload is a few hundred
	// kilobytes, and copying it into a String-keyed dictionary on every production put that
	// copy on the page-production path - and kept a second full copy of every resident page
	// alive for the rest of the session. A Ref is a refcount.
	record["source"] = p_payload;
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
				producer->queue_cell_page(p_slot, pieces, p_rect, Terrain3DSurfaceBaker::TIER_SVT);
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
		producer->queue_page(p_slot, ids, height, p_rect, 1.f, source_grid, Terrain3DSurfaceBaker::TIER_SVT);
		return;
	}
	if (p_prepared) {
		producer->queue_page(p_slot, p_prepared->ids, p_prepared->height, p_rect, 1.f, p_prepared->grid,
				p_svt ? Terrain3DSurfaceBaker::TIER_SVT : Terrain3DSurfaceBaker::TIER_AVT);
		return;
	}
	Ref<Image> ids = p_payload;
	const Vector3 source_grid = bake_source_grid(_data, p_rect, _vt.vt_page_size, _vt.vt_page_border,
			_vertex_spacing / _surface_density, ids, height);
	if (height.is_null()) { height = _data->make_vt_height_page(p_rect, _vt.vt_page_size, _vt.vt_page_border); }
	producer->queue_page(p_slot, ids, height, p_rect, 1.f, source_grid,
			p_svt ? Terrain3DSurfaceBaker::TIER_SVT : Terrain3DSurfaceBaker::TIER_AVT);
}

void Terrain3D::_invalidate_vt_region(const Vector2i &p_region) {
	_vt.vt_source_snapshot.reset();
	_vt.avt_refinement.reset();
	invalidate_avt_plan_key(_vt.avt_plan.key);
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
	_vt.bake.dirty_regions[p_region] = true;
	_vt.bake.edit_time = Time::get_singleton()->get_ticks_msec();
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
			if (_vt.bake.waiting.has(keys[i])) {
				Vector2i address = record["address"];
				_vt.bake.queue.push_back(Vector3i(address.x, address.y, int(record["mip"])));
				_vt.bake.waiting.erase(keys[i]);
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
