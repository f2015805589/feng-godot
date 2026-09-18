// Copyright © 2026 Terrain3D contributors.

// Terrain3D's virtual texture service, part 3 of 4: the diagnostics.
//
// What the dock, the editor inspector, the debug overlay and the tests read: `get_vt_settings()`
// (the per-tick telemetry every performance test in native/tests is written against),
// `get_vt_pages()`, the page and material previews, the published arrays the material binds, and
// the compression probe a codec test uses as its reference. Read-only: nothing here changes the
// service.
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
	// Page production and look-ahead: how many source threads assemble pages, what the
	// last plan was aimed at, and the two readings that tell a page still inside its
	// production window from one the image being rendered is missing.
	result["page_workers"] = _vt.vt_page_workers > 0
			? _vt.vt_page_workers
			: (_vt.vt_page_pipeline ? _vt.vt_page_pipeline->get_worker_count() : Terrain3DPagePipeline::default_worker_count());
	result["motion_lead_ms"] = _vt.vt_motion_lead_ms;
	result["motion_lead_m"] = _vt.avt_motion_lead.length();
	result["motion_speed"] = _vt.avt_motion_velocity.length();
	result["motion_turn_deg_s"] = Math::rad_to_deg(_vt.avt_motion_turn.length());
	result["motion_turn_lead_deg"] = Math::rad_to_deg(_vt.avt_motion_turn_lead.length());
	result["visible_late_pages"] = _vt.avt_late_pages;
	result["visible_late_worst_ms"] = double(_vt.avt_late_worst_us) / 1000.0;
	result["visible_retained_pages"] = _vt.avt_retained_pages;
	result["shared_pool"] = _vt.vt_shared_ready;
	result["adaptive"] = _vt.vt_adaptive_enabled;
	result["avt_feedback"] = _vt.avt_feedback;
	result["svt_feedback"] = _vt.svt_feedback;
	result["avt_texels_per_pixel"] = _vt.surface_vt_texels_per_pixel;
	result["avt_resolution"] = get_surface_vt_resolution(); // Legacy API only.
	result["avt_distance"] = _vt.surface_vt_distance;
	result["avt_texels_per_meter"] = get_surface_vt_texels_per_meter();
	result["svt_texels_per_meter"] = get_surface_svt_texels_per_meter();
	result["svt_world_extent"] = (_vt.surface_svt ? _vt.surface_svt->get_indirection_size() : MAX(64, _vt.surface_svt_page_count * 4)) * _vt.surface_svt_page_world;
	result["avt_virtual_resolution"] = 64.f * get_surface_vt_texels_per_meter();
	result["avt_base_block_size"] = get_avt_base_block_size();
	result["avt_sector_world"] = is_sector_avt() ? 64.0 : double(_region_size * _vertex_spacing);
	result["avt_sector_stats"] = _vt.avt_sector_stats;
	result["avt_peak_stats"] = _vt.avt_peak_stats;
	result["avt_peak_age_ms"] = _vt.avt_peak_stamp_us == 0 ? -1.0
			: double(Time::get_singleton()->get_ticks_usec() - _vt.avt_peak_stamp_us) / 1000.0;
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
	result["svt_stats"] = _vt.svt_stats;
	result["svt_worst_ms"] = _vt.svt_worst_ms;
	result["svt_worst_frames_ago"] = double(Engine::get_singleton()->get_process_frames() - _vt.svt_worst_frame);
	// Main-thread cost of the VT section of the last physics tick, its worst frame so
	// far, and the far-field demand pass inside it.
	result["vt_cpu_ms"] = _vt.vt_cpu_ms;
	result["vt_cpu_peak_ms"] = _vt.vt_cpu_peak_ms;
	result["svt_cpu_ms"] = _vt.svt_cpu_ms;
	// The page-arrival fade, in the order a reader asks about it: the requested ramp length, the
	// ramps the last tick advanced, the arrivals still waiting for content, the ones armed and
	// waiting their turn, the ramps started, the most one tick has started - which is what says
	// whether a burst is being spread or is still arriving as one step - and the longest ramp still
	// running.
	result["vt_page_fade_frames"] = _vt.vt_page_fade_frames;
	result["vt_page_fade_active_slots"] = _vt.vt_page_fade_active;
	result["vt_page_fade_pending_slots"] = _vt.vt_page_fade_pending;
	result["vt_page_fade_held_slots"] = _vt.vt_page_fade_held;
	result["vt_page_fade_starts"] = int64_t(_vt.vt_page_fade_starts);
	result["vt_page_fade_starts_peak"] = _vt.vt_page_fade_starts_peak;
	result["vt_page_fade_ticks_max"] = _vt.vt_page_fade_ticks_max;
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
		result["producer"] = producer_stats;
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
