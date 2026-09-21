// Copyright © 2026 Terrain3D contributors.

// Terrain3D's virtual texture service, part 3 of 4: the diagnostics.
//
// What the dock, the editor inspector, the debug overlay and the tests read: `get_vt_settings()`
// (the per-tick telemetry every performance test in native/tests is written against),
// `get_vt_pages()`, the page and material previews, the published arrays the material binds, and
// the compression probe a codec test uses as its reference. Read-only: nothing here changes the
// service.
//
// `get_vt_settings()` is one flat dictionary - every consumer reads a key by name, so the shape is
// a compatibility surface and stays flat - but it is assembled by owner rather than written out
// here: each view and the fade report the keys their own fields back, from the file that owns those
// fields, and `_report_vt_service()` below adds the service's. A key added for a view therefore
// belongs in that view's file, next to the field it reads.
//
// The other halves: terrain_3d_vt_service.cpp (settings and lifetime),
// terrain_3d_vt_service_pages.cpp (page plumbing and the cell store) and
// terrain_3d_vt_service_bake.cpp (the far field's bake and its cell files).

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_vt_service_internal.h"
#include "terrain_3d_virtual_texture.h"

#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/time.hpp>

// The two helpers the four halves share; see terrain_3d_vt_service_internal.h for what it holds
// and why it is a header.
using namespace terrain_surface_vt;

// Compresses and decodes one image through the near field's codec, so a test can verify the
// codec path where page production has nothing to bake from. The page pipeline itself never
// runs a CPU codec; this is the reference for how lossy the requested codec is.
Dictionary Terrain3D::probe_vt_atlas_compression(const Ref<Image> &p_image) const {
	if (!_vt.vt_baker.is_valid()) {
		return Dictionary();
	}
	return baker(_vt.vt_baker)->probe_tier_compression(Terrain3DSurfaceBaker::TIER_AVT, p_image);
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

// The telemetry, in the order a reader asks about it: the shared service, the near field, the far
// field, then the page-arrival fade. Four owners rather than one 180 line function, so a key is
// written beside the field it reads and the next subsystem's keys do not have to be threaded
// through this file.
Dictionary Terrain3D::get_vt_settings() const {
	Dictionary result;
	_report_vt_service(result);
	_report_avt(result);
	_report_svt(result);
	_report_vt_fade(result);
	return result;
}

// The service's own half: the pool and the page footprint, both views' storage cost, the producer
// handles, the tick's cost and its phases, and the far field's bake bookkeeping.
void Terrain3D::_report_vt_service(Dictionary &r_result) const {
	Dictionary &result = r_result;
	result["page_size"] = _vt.vt_page_size;
	result["border"] = _vt.vt_page_border;
	// The near field's anisotropy as the triple that says whether the request survives the gutter:
	// `avt_anisotropy` is what the terrain holds (zero means "follow the viewport"), `requested` is
	// that resolved against the viewport, and `effective` is what the shader and the planner use.
	// The last two differ only when the request is wider than the page's border texels can sample,
	// which is the one thing about anisotropy that used to be silent; see
	// `Terrain3D::get_avt_anisotropy()` and docs/vt_sampling_review.md.
	result["avt_anisotropy"] = _vt.surface_vt_anisotropy;
	result["avt_anisotropy_requested"] = get_avt_anisotropy_request(get_camera());
	result["avt_anisotropy_effective"] = get_avt_anisotropy(get_camera());
	result["page_count"] = _vt.vt_page_count;
	result["effective_page_count"] = _vt.pool.capacity;
	// How many times the service built a page pool. Building one releases every resident
	// page, because the atlas cannot be resized in place.
	result["pool_generation"] = _vt.pool.generation;
	result["auto_capacity"] = _vt.vt_auto_capacity;
	// Material page arrays, in bytes. The uncompressed figure is the formula over the slot
	// count (three RGBA16F outputs plus the R16/R32F bake sources, 32 bytes per stored texel)
	// and it is what the pool costs with no codec applied; `physical_cache_bytes` is what the
	// arrays actually cost today, which is the staging pool - the encoder ring once every tier
	// is compressed - plus one compressed copy per tier that resolved. Reporting only the
	// formula made a compressed pool look unchanged, and the per-tier numbers are what a
	// comparison between an AVT codec, an SVT codec and both has to read.
	const int64_t uncompressed_cache_bytes = int64_t(_vt.vt_page_size + 2 * _vt.vt_page_border) *
			(_vt.vt_page_size + 2 * _vt.vt_page_border) * _vt.vt_page_count * 32;
	Dictionary producer_stats;
	if (_vt.vt_baker.is_valid()) {
		producer_stats = baker(_vt.vt_baker)->get_stats();
	}
	result["physical_cache_bytes_uncompressed"] = uncompressed_cache_bytes;
	result["physical_cache_bytes"] = producer_stats.is_empty()
			? uncompressed_cache_bytes
			: int64_t(producer_stats.get("material_bytes", uncompressed_cache_bytes));
	result["material_staging_bytes"] = int64_t(producer_stats.get("staging_bytes", uncompressed_cache_bytes));
	result["material_compressed_bytes"] = int64_t(producer_stats.get("compressed_bytes", 0));
	result["surface_vt_compression_bytes"] = int64_t(producer_stats.get("avt_bytes", 0));
	result["surface_svt_compression_bytes"] = int64_t(producer_stats.get("svt_bytes", 0));
	result["surface_vt_compression_slots"] = int64_t(producer_stats.get("avt_slots", 0));
	result["surface_svt_compression_slots"] = int64_t(producer_stats.get("svt_slots", 0));
	result["surface_vt_compression_ready_slots"] = int64_t(producer_stats.get("avt_ready_slots", 0));
	result["surface_svt_compression_ready_slots"] = int64_t(producer_stats.get("svt_ready_slots", 0));
	result["pages_per_update"] = _vt.vt_pages_per_update;
	// Page production and look-ahead: how many source threads assemble pages, and what the
	// last plan was aimed at. Both views' own readings are in their own reports.
	result["page_workers"] = _vt.vt_page_workers > 0
			? _vt.vt_page_workers
			: (_vt.vt_page_pipeline ? _vt.vt_page_pipeline->get_worker_count() : Terrain3DPagePipeline::default_worker_count());
	result["shared_pool"] = _vt.vt_shared_ready;
	// What this frame can and cannot do on the GPU, resolved at runtime the way `rd_gpu_copy.cpp`
	// resolves the direct page store (`has_method`, so a stock engine answers false and prints
	// nothing). These three are exactly the capabilities a GPU-side demand source needs, and they are
	// the H4 probe's answer recorded on the running binary rather than read out of the source: see
	// `docs/vt_hdrp_avt_alignment.md` section 7.7.5 for what each one settles and which of them is
	// absent.
	RenderingDevice *rd = RenderingServer::get_singleton() != nullptr ? RenderingServer::get_singleton()->get_rendering_device() : nullptr;
	result["rd_direct_store"] = rd != nullptr && rd->has_method("texture_copy_from_buffer");
	result["rd_async_buffer_readback"] = rd != nullptr && rd->has_method("buffer_get_data_async");
	result["rd_async_texture_readback"] = rd != nullptr && rd->has_method("texture_get_data_async");
	// Main-thread cost of the VT section of the last physics tick, its worst frame so far, and
	// the phases inside it. `svt_cpu_ms` is the far-field pass and is reported by the far field.
	result["vt_cpu_ms"] = _vt.vt_cpu_ms;
	result["vt_cpu_peak_ms"] = _vt.vt_cpu_peak_ms;
	Dictionary phases;
	phases["service"] = _vt.vt_service_ms;
	phases["avt"] = _vt.vt_avt_ms;
	phases["svt"] = _vt.vt_svt_ms;
	phases["avt_peak"] = _vt.vt_avt_peak_ms;
	phases["svt_peak"] = _vt.vt_svt_peak_ms;
	phases["topup"] = _vt.vt_topup_ms;
	phases["fade"] = _vt.vt_fade_ms;
	phases["bake"] = _vt.vt_bake_ms;
	result["vt_phases"] = phases;
	// Resident far-field cell sources: what the runtime copies pages from without touching
	// a file or re-baking, and how close that cache is to its memory budget.
	if (_vt.svt_cells.is_valid()) {
		result["svt_cells"] = _vt.svt_cells->get_stats();
	}
	// Atlas compression: the request, what the baker resolved it to, and the reason a
	// request was refused (unsupported codec, no encoder, or an unloadable format). The
	// legacy keys report the near field, which is what a single compression switch used to
	// control; both tiers carry their own keys as well.
	result["vt_atlas_compression"] = _vt.surface_vt_compression;
	result["surface_vt_compression"] = _vt.surface_vt_compression;
	result["surface_svt_compression"] = _vt.surface_svt_compression;
	result["surface_vt_diffuse_compression"] = _vt.surface_vt_compression;
	result["surface_svt_diffuse_compression"] = _vt.surface_svt_compression;
	result["surface_vt_normal_compression"] = get_surface_vt_normal_compression();
	result["surface_svt_normal_compression"] = get_surface_svt_normal_compression();
	if (_vt.vt_baker.is_valid()) {
		const Dictionary avt_compression = baker(_vt.vt_baker)->get_tier_compression_info(Terrain3DSurfaceBaker::TIER_AVT);
		result["vt_atlas_compression_available"] = avt_compression.get("available", 0);
		result["vt_atlas_compression_applied"] = avt_compression.get("applied", 0);
		result["vt_atlas_compression_name"] = avt_compression.get("name", String());
		result["vt_atlas_compression_reason"] = avt_compression.get("reason", String());
		const Dictionary svt_compression = baker(_vt.vt_baker)->get_tier_compression_info(Terrain3DSurfaceBaker::TIER_SVT);
		result["surface_vt_compression_available"] = avt_compression.get("available", 0);
		result["surface_vt_compression_applied"] = avt_compression.get("applied", 0);
		result["surface_vt_compression_name"] = avt_compression.get("name", String());
		result["surface_vt_compression_reason"] = avt_compression.get("reason", String());
		result["surface_svt_compression_available"] = svt_compression.get("available", 0);
		result["surface_svt_compression_applied"] = svt_compression.get("applied", 0);
		result["surface_svt_compression_name"] = svt_compression.get("name", String());
		result["surface_svt_compression_reason"] = svt_compression.get("reason", String());
		result["avt_storage"] = avt_compression;
		result["svt_storage"] = svt_compression;
	}
	result["editor_preview"] = _vt.vt_editor_preview;
	result["editor_preview_active"] = is_vt_editor_preview_active();
	result["callback_registered"] = _vt.vt_callback_registered;
	result["material_signature"] = int64_t(_vt.vt_material_signature);
	result["auto_bake"] = _vt.svt_auto_bake;
	result["auto_pending_regions"] = _vt.bake.dirty_regions.size();
	result["bake_generation"] = int64_t(_vt.bake.generation);
	result["bake_incremental"] = _vt.bake.incremental;
	result["bake_total"] = _vt.bake.total;
	result["cells_baked"] = int64_t(_vt.bake.cells_baked);
	result["bake_done"] = _vt.bake.done;
	result["svt_source_pending"] = int64_t(_vt.svt_pending_pages.size());
	result["bake_pending"] = _vt.bake.pending();
	result["bake_failed"] = _vt.bake.failed;
	result["bake_error"] = _vt.bake.error;
	if (_vt.vt_baker.is_valid()) {
		result["producer"] = producer_stats;
	}
	if (_vt.surface_vt) {
		result["residency"] = _vt.surface_vt->get_stats();
	}
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
