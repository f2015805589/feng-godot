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
	// The delivery matrix and the assembly it resolved to, first because everything below is a
	// consequence of it: the four cells say what was asked for, the three booleans say which
	// services therefore exist, and a reader that wants to know why a view is missing an object
	// reads the two together. `delivery_names` is the readable form, so a diagnostic line does not
	// have to map the numbers. See docs/vt_delivery_assembly.md.
	result["delivery_near_material"] = get_vt_delivery(int(TerrainVT::Tier::Near), int(TerrainVT::ChannelGroup::Material));
	result["delivery_near_height"] = get_vt_delivery(int(TerrainVT::Tier::Near), int(TerrainVT::ChannelGroup::Height));
	result["delivery_far_material"] = get_vt_delivery(int(TerrainVT::Tier::Far), int(TerrainVT::ChannelGroup::Material));
	result["delivery_far_height"] = get_vt_delivery(int(TerrainVT::Tier::Far), int(TerrainVT::ChannelGroup::Height));
	result["delivery_names"] = String("near/material=") + TerrainVT::delivery_name(_vt.delivery.get(TerrainVT::Tier::Near, TerrainVT::ChannelGroup::Material)) +
			" near/height=" + TerrainVT::delivery_name(_vt.delivery.get(TerrainVT::Tier::Near, TerrainVT::ChannelGroup::Height)) +
			" far/material=" + TerrainVT::delivery_name(_vt.delivery.get(TerrainVT::Tier::Far, TerrainVT::ChannelGroup::Material)) +
			" far/height=" + TerrainVT::delivery_name(_vt.delivery.get(TerrainVT::Tier::Far, TerrainVT::ChannelGroup::Height));
	// A service exists iff a cell selected its method, so these three are the whole of what was
	// assembled, and `vt_shader_arms` is whether the material's generated code carries any VT arms
	// at all - false is the no-VT build, not a build whose arms are branched around.
	result["avt_service"] = has_avt_delivery();
	result["svt_service"] = has_svt_delivery();
	result["clipmap_service"] = has_clipmap_delivery();
	result["clipmap_atlas_service"] = has_clipmap_atlas_delivery();
	// Which methods a cell may name, per channel group, and the sentence for each one it may not:
	// the matrix refuses a method this build cannot deliver (`is_vt_delivery_supported()`), so a
	// panel disables a row from published state rather than from its own hard-coded list, and the
	// reason it shows is the same sentence the setter logs. Without this a reader sees four cells
	// that all look writable and has to infer the refusal from a service that is missing.
	Dictionary delivery_supported;
	Dictionary delivery_unsupported;
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		const String group_name = TerrainVT::group_name(TerrainVT::ChannelGroup(group));
		PackedInt32Array allowed;
		Dictionary refused;
		for (int method = 0; method < TerrainVT::DELIVERY_COUNT; method++) {
			if (is_vt_delivery_supported(group, method)) {
				allowed.push_back(method);
			} else {
				refused[TerrainVT::delivery_name(TerrainVT::Delivery(method))] = get_vt_delivery_unsupported_reason(group, method);
			}
		}
		delivery_supported[group_name] = allowed;
		delivery_unsupported[group_name] = refused;
	}
	result["delivery_supported"] = delivery_supported;
	result["delivery_unsupported"] = delivery_unsupported;
	// Whether any ring object exists, which is the clipmap's own "is this used" question and what its
	// debug view and preview are gated on. `clipmap_service` above is the matrix's answer; this is the
	// object's, and the two differ exactly when `debug_update_vt_clipmap()` has built a ring to
	// measure the mechanism while no cell names the method.
	result["clipmap_ring"] = has_vt_clipmap_ring();
	// The two editor previews, counted: how many asks each got and how many of those did the work.
	// The difference is the asks a delivery gate refused, and it is the reading behind "a method no
	// row selects owns no layout, so its debug view neither draws nor scans". See
	// `get_avt_layout_preview()` and `get_clipmap_layout_preview()`.
	result["avt_preview_calls"] = int64_t(_vt.avt_preview_calls);
	result["avt_preview_computed"] = int64_t(_vt.avt_preview_computed);
	result["clipmap_preview_calls"] = int64_t(_vt.clipmap_preview_calls);
	result["clipmap_preview_computed"] = int64_t(_vt.clipmap_preview_computed);
	result["vt_shader_arms"] = needs_vt_shader_arms();
	// Whether the region texture array still has to carry the diffuse/normal group, which is the
	// case exactly when no service delivers it. Published because it is the other half of the
	// assembly statement: with every cell direct the array is not a fallback, it is the renderer.
	result["surface_array_upload_needed"] = is_surface_array_upload_needed();
	// The clipmap ring: the object that exists and what it cost. `selected` is the matrix's claim for
	// this group and `configured` is the object; a reader can therefore tell "the mechanism exists and
	// nothing delivers it" (a ring the entry built while every cell is `Direct`) from "no ring at
	// all" without reading a log. The per-group entry carries the addressing that says a level is
	// *current* rather than approximate (each level's centre, ring and `valid`), the counters that
	// say what the ring has produced, and the upload bytes: the CPU side is incremental and a
	// whole-layer transfer is not, so the second half is a published measurement rather than an
	// assumption. `invalidation_calls` / `invalidated_texels` are the same statement for an edit: a
	// changed rect is re-produced rather than the ring. See docs/vt_delivery_assembly.md section 6.
	result["clipmap_size"] = _vt.clipmap_size;
	result["clipmap_levels_setting"] = _vt.clipmap_levels;
	result["clipmap_base_world"] = _vt.clipmap_base_world;
	result["clipmap_budget_texels"] = _vt.clipmap_budget_texels;
	result["clipmap_produced_texels"] = _vt.clipmap_produced_texels;
	// ---- The clipmap atlas: the same rings, block-organised and block-uploaded ------------------
	// The mechanism's own readings, published beside the ring's so the load comparison is one report
	// rather than two programs. The numbers that matter are the update *unit*: `block_uploads` is how
	// many block rects were published (against the ring's whole-layer `upload_bytes`), and
	// `blocks_loaded` / `blocks_retained` are the rolling evidence - a scroll that reloaded the grid
	// would report `blocks_retained` at zero.
	result["clipmap_atlas_available"] = has_vt_clipmap_atlas();
	result["clipmap_atlas_rings"] = _vt.clipmap_atlas_rings;
	result["clipmap_atlas_global_texels"] = _vt.clipmap_atlas_global_texels;
	result["clipmap_atlas_blocks_per_frame"] = _vt.clipmap_atlas_blocks_per_frame;
	result["clipmap_atlas_produced_texels"] = _vt.clipmap_atlas_produced_texels;
	result["clipmap_atlas_block_uploads"] = _vt.clipmap_atlas_block_uploads;
	result["clipmap_atlas_scroll_events"] = _vt.clipmap_atlas_scroll_events;
	result["clipmap_atlas_blocks_loaded"] = _vt.clipmap_atlas_blocks_loaded;
	result["clipmap_atlas_blocks_retained"] = _vt.clipmap_atlas_blocks_retained;
	result["clipmap_atlas_preview_calls"] = int64_t(_vt.clipmap_atlas_preview_calls);
	result["clipmap_atlas_preview_computed"] = int64_t(_vt.clipmap_atlas_preview_computed);
	Dictionary clipmap_atlas;
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		const Terrain3DClipmapAtlas *atlas = _vt.clipmap_atlas[group].get();
		Dictionary entry;
		entry["configured"] = atlas != nullptr && atlas->is_configured();
		entry["selected"] = _vt.delivery.group_uses(TerrainVT::ChannelGroup(group), TerrainVT::Delivery::ClipmapAtlas);
		entry["source"] = atlas != nullptr ? atlas->get_source_name() : String("none");
		entry["source_available"] = has_clipmap_source(group);
		if (atlas != nullptr && atlas->is_configured()) {
			entry["rings"] = atlas->get_rings();
			entry["blocks"] = atlas->get_block_count();
			entry["slots"] = atlas->get_slot_count();
			entry["cells"] = atlas->get_cell_count();
			entry["channels"] = atlas->get_channel_count();
			entry["block_size"] = atlas->get_config().block_size;
			entry["block_world"] = atlas->get_config().base_world;
			entry["width"] = atlas->get_atlas_width();
			entry["height"] = atlas->get_atlas_height();
			entry["produced_texels"] = int64_t(atlas->get_produced_texels());
			entry["upload_bytes"] = int64_t(atlas->get_upload_bytes());
			entry["block_uploads"] = int64_t(atlas->get_block_uploads());
			entry["pending_jobs"] = atlas->get_pending_jobs();
			entry["scroll_events"] = int64_t(atlas->get_scroll_events());
			entry["blocks_loaded"] = int64_t(atlas->get_edge_blocks_loaded());
			entry["blocks_retained"] = int64_t(atlas->get_interior_blocks_retained());
			entry["last_scroll_loaded"] = int64_t(atlas->get_last_scroll_loaded());
			entry["last_scroll_retained"] = int64_t(atlas->get_last_scroll_retained());
			entry["update_calls"] = int64_t(atlas->get_update_calls());
			entry["idle_updates"] = int64_t(atlas->get_idle_updates());
			// The two readings the settle criteria are written against: how many cells point at a
			// current block right now, and how many are waiting for one.
			int current = 0;
			int pending_cells = 0;
			int baked_cells = 0;
			for (int cell = 0; cell < atlas->get_cell_count(); cell++) {
				current += atlas->is_cell_current(cell) ? 1 : 0;
				pending_cells += atlas->get_cell_pending_slot(cell) >= 0 ? 1 : 0;
				baked_cells += atlas->is_cell_baked(cell) ? 1 : 0;
			}
			entry["current_cells"] = current;
			// The *material* readiness: a cell whose block's baked rect the producer has acknowledged.
			// It is the gate the material arm reads, so a measurement of "the near material is there"
			// is this number and not the source residency above.
			entry["baked_cells"] = baked_cells;
			entry["pending_bake_rects"] = atlas->get_pending_bake_rect_count();
			// A cell is either serving a block or waiting for one, and never neither: that identity is
			// the anti-flash property the per-frame timeline is evidence for - the replacement is built
			// in a spare slot before the block it replaces is released, so no frame has a gap.
			entry["pending_cells"] = pending_cells;
			entry["serving_or_loading"] = current + pending_cells;
			entry["ring_reports"] = atlas->get_ring_reports();
			entry["layout"] = atlas->get_layout_report();
		}
		clipmap_atlas[TerrainVT::group_name(TerrainVT::ChannelGroup(group))] = entry;
	}
	result["clipmap_atlas"] = clipmap_atlas;
	// The material group's detail layer: the request (density, budget, radius), what it delivered
	// (resident/valid/starved tiles, bytes) and its source and bake counters. One dictionary, because
	// "asked for 1024" and "has 1024 resident and baked" are the two halves a reader has to compare
	// and neither is the acceptance on its own. It is published both at the service level and nested
	// in the material ring's entry below: the ring's entry is where a reader looks for the material
	// group's own state, and the density acceptance reads the nested shape.
	const Dictionary detail_material = get_vt_detail_settings();
	result["detail_material"] = detail_material;
	Dictionary clipmap;
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		const TerrainVT::ChannelGroup channel = TerrainVT::ChannelGroup(group);
		const Terrain3DClipmap *ring = _vt.clipmap[group].get();
		Dictionary entry;
		entry["configured"] = ring != nullptr && ring->is_configured();
		entry["selected"] = _vt.delivery.group_uses(channel, TerrainVT::Delivery::Clipmap);
		entry["source"] = ring != nullptr ? ring->get_source_name() : String("none");
		// Whether this build has a *source* for the group, which is the same answer the matrix's
		// acceptance is read from (`has_clipmap_source()`): a reader can therefore tell "the mechanism
		// exists and nothing delivers it" from "this build cannot deliver it at all", and which of the
		// two a refused cell is.
		entry["source_available"] = has_clipmap_source(group);
		// Whether the generated shader carries *this group's* ring arm. It is the narrower reading
		// beside `vt_shader_arms` above and it moves on its own: a group delivered `Direct` in both
		// bands compiles no ring code and binds no ring uniform, and a build can carry one group's arm
		// without the other's. Read from the material's verdict rather than from the policy, because
		// the verdict is what the compiled string is.
		entry["shader_arm"] = _material.is_valid() && _material->is_shader_using_clipmap(group);
		if (ring != nullptr) {
			entry["size"] = ring->get_size();
			entry["levels"] = ring->get_level_count();
			entry["channels"] = ring->get_channel_count();
			entry["base_world"] = ring->get_base_world();
			entry["valid_levels"] = ring->get_level_valid_count();
			entry["pending_jobs"] = ring->get_pending_jobs();
			entry["texture_layers"] = ring->get_texture_layer_count();
			entry["produced_texels"] = int64_t(ring->get_produced_texels());
			entry["full_productions"] = int64_t(ring->get_full_level_productions());
			entry["upload_bytes"] = int64_t(ring->get_upload_bytes());
			entry["update_calls"] = int64_t(ring->get_update_calls());
			entry["idle_updates"] = int64_t(ring->get_idle_updates());
			entry["invalidation_calls"] = int64_t(ring->get_invalidation_calls());
			entry["invalidated_texels"] = int64_t(ring->get_invalidated_texels());
			// The bake's own accounting, in the same unit the production counters above are in: what a
			// producer has written into the ring's layers, and what is still owed. A level's `baked` is
			// the last rect's answer, so these are what say whether the ring is one strip behind or one
			// level behind.
			entry["baked_texels"] = int64_t(ring->get_baked_texels());
			entry["bake_dispatches"] = int64_t(ring->get_bake_dispatches());
			entry["bake_rejects"] = int64_t(ring->get_bake_rejects());
			entry["pending_bake_rects"] = ring->get_pending_bake_rect_count();
			entry["level_reports"] = ring->get_level_reports();
		}
		// The material group's finer half, in the entry of the group it belongs to: a fragment's
		// fallback chain runs detail -> this ring -> the payload evaluation -> the array, so the two
		// granularities of the same group are read together.
		if (channel == TerrainVT::ChannelGroup::Material) {
			entry["detail"] = detail_material;
		}
		clipmap[TerrainVT::group_name(channel)] = entry;
	}
	result["clipmap"] = clipmap;
	result["page_size"] = _vt.vt_page_size;
	result["border"] = _vt.vt_page_border;
	// The near field's anisotropy as the triple that says which bound decides it: `avt_anisotropy` is
	// what the terrain holds (zero means "follow the viewport"), `sampler` is the tap count the
	// viewport's filtering level gives the material samplers, `requested` is that setting resolved
	// against the sampler, and `effective` is what the shader and the planner use. `requested` and
	// `effective` differ when the page's border texels cannot sample the request; `sampler` and
	// `requested` differ when a project asks for more filtering than its viewport renders with, in
	// which case `effective` is the sampler's number and the grazing view is filtered for that many
	// taps instead of aliasing on an assumption of more. See `Terrain3D::get_avt_anisotropy()` and
	// docs/vt_sampling_review.md.
	result["avt_anisotropy"] = _vt.surface_vt_anisotropy;
	result["avt_anisotropy_sampler"] = get_avt_anisotropy_sampler(get_camera());
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
	// The encode ring's allocation and admission, and the two numbers behind them: the peak the live
	// page-budget settings can reach (what the allocation was made for) and what one ring position
	// costs. A budget raised above `encode_ring_allocated / 2` would be a rate the staging cannot
	// admit, so a probe reads these rather than inferring the ceiling from the settings.
	result["encode_ring_capacity"] = int64_t(producer_stats.get("encode_ring_capacity", 0));
	result["encode_ring_allocated"] = int64_t(producer_stats.get("encode_ring_allocated", 0));
	result["page_budget_ceiling"] = int64_t(producer_stats.get("page_budget_ceiling", 0));
	result["encode_page_bytes"] = int64_t(producer_stats.get("encode_page_bytes", 0));
	result["material_compressed_bytes"] = int64_t(producer_stats.get("compressed_bytes", 0));
	result["surface_vt_compression_bytes"] = int64_t(producer_stats.get("avt_bytes", 0));
	result["surface_svt_compression_bytes"] = int64_t(producer_stats.get("svt_bytes", 0));
	result["surface_vt_compression_slots"] = int64_t(producer_stats.get("avt_slots", 0));
	result["surface_svt_compression_slots"] = int64_t(producer_stats.get("svt_slots", 0));
	result["surface_vt_compression_ready_slots"] = int64_t(producer_stats.get("avt_ready_slots", 0));
	result["surface_svt_compression_ready_slots"] = int64_t(producer_stats.get("svt_ready_slots", 0));
	result["pages_per_update"] = _vt.vt_pages_per_update;
	// Page production and look-ahead: how many source threads assemble pages, and what the
	// last plan was aimed at. Both views' own readings are in their own reports. `page_workers` is
	// the near field's live pool when it exists - the tier moves it - and `page_workers_setting`
	// is the floor the caller configured; the far field keeps the floor.
	result["page_workers"] = _vt.vt_page_pipeline ? _vt.vt_page_pipeline->get_worker_count()
												  : (_vt.vt_page_workers > 0
																  ? _vt.vt_page_workers
																  : Terrain3DPagePipeline::default_worker_count());
	result["page_workers_setting"] = _vt.vt_page_workers;
	result["shared_pool"] = _vt.vt_shared_ready;
	// What this frame can and cannot do on the GPU, resolved at runtime the way `rd_gpu_copy.cpp`
	// resolves the direct page store (`has_method`, so a stock engine answers false and prints
	// nothing). These three are exactly the capabilities a GPU-side demand source needs, and they are
	// the H4 probe's answer recorded on the running binary rather than read out of the source: see
	// `docs/vt_reference_avt_alignment.md` section 7.7.5 for what each one settles and which of them is
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
	phases["clipmap"] = _vt.vt_clipmap_ms;
	phases["detail"] = _vt.vt_detail_ms;
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

// The state string the debug page list publishes for one record. Spelled beside the enum so the
// two cannot drift; the strings are the ones the tests and the editor dock read.
const char *Terrain3DVTState::PageRecord::state_name() const {
	switch (state) {
		case PENDING_BAKE:
			return "Pending bake";
		case PENDING_CELL_COPY:
			return "Pending cell copy";
		case MISSING_BAKE:
			return "Missing bake";
		case PENDING_RESIDENT_FALLBACK:
			return "Pending resident fallback";
		case MISSING_STALE_CELL_BAKE:
			return "Missing/stale cell bake";
		case NO_RESIDENT_PAYLOAD:
			return "No resident payload";
		case READY:
			return "Ready";
	}
	return "Pending bake";
}

// One record as the dictionary `get_vt_pages()` hands a script. The production path never builds
// this: a page's record is written once per production and a String-keyed Dictionary there measured
// 14.7 us of an 18.3 us per-page publish, so the shape a diagnostic wants is assembled on the
// diagnostic. `source` is deliberately absent - it is the payload Ref, and the page list is a
// description of residency, not a way to read the image back.
Dictionary Terrain3D::_vt_page_record_dictionary(const Terrain3DVTState::PageRecord &p_record) const {
	Dictionary record;
	record["slot"] = p_record.slot;
	record["kind"] = p_record.svt ? "SVT" : "AVT";
	record["state"] = p_record.state_name();
	record["world_rect"] = p_record.world_rect;
	record["mip"] = p_record.mip;
	record["address"] = p_record.address;
	record["revision"] = p_record.revision;
	record["queued_frame"] = p_record.queued_frame;
	if (p_record.cells > 0) {
		record["cells"] = p_record.cells;
	}
	return record;
}

Array Terrain3D::get_vt_pages() const {
	Array result;
	// The owners of a slot are recorded by the *pool*, which both views share, so the view that can
	// be asked about a slot is whichever one exists. Reading the near view alone - which used to be
	// the only way, because a node always had both views - reported an empty list whenever only the
	// far field was selected, and two suites read that as a page that had been lost.
	const Terrain3DVirtualTexture *view = _vt.surface_vt ? _vt.surface_vt : _vt.surface_svt;
	for (const auto &entry : _vt.vt_page_records) {
		const int key = entry.first;
		if (view == nullptr || view->get_slot_owner_count(key) == 0) {
			continue;
		}
		// The script-facing dictionary is materialized here, on the diagnostic call, rather than
		// built by the production path: see `Terrain3DVTState::PageRecord`.
		Dictionary record = _vt_page_record_dictionary(entry.second);
		record["ready"] = _vt.vt_baker.is_valid() && baker(_vt.vt_baker)->is_page_ready(key);
		if (bool(record["ready"])) {
			record["state"] = "Ready";
		}
		const Array owners = view->get_slot_owner_metadata(key);
		record["owners"] = owners;
		for (Dictionary owner : owners) {
			if (bool(owner["world_space"])) { continue; }
			// Only the near field records a non-world-space owner, so this is the one part of the
			// record that needs it; a build without it has no such owner to describe.
			if (_vt.surface_vt == nullptr) { continue; }
			const Vector2i sector = owner["sector"];
			const int mip = owner["mip"];
			owner["local_mip"] = mip;
			const uint64_t sector_key = (uint64_t(uint32_t(sector.x)) << 32) | uint32_t(sector.y);
			const auto cached = _vt.avt_cached_addresses.find(sector_key);
			if (cached != _vt.avt_cached_addresses.end()) {
				owner["resolution_level"] = cached->second.resolution_level;
				owner["logical_pages"] = cached->second.logical_pages;
			}
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

// The clipmap's debug payload: the world squares the ring's levels occupy right now and the rects
// each one still has queued. One entry per ring that exists, so a group with no ring appears as
// nothing at all rather than as a ring with zero levels, and a terrain with no ring - which in this
// build is every terrain whose rings only `debug_update_vt_clipmap()` built - returns an empty
// dictionary: the scan is refused, not drawn empty, which is the rule `get_avt_layout_preview()`
// follows for AVT and the reason the two preview counters exist. The gate is therefore "is there a
// ring", not "does a cell name the method": a ring that exists is what a picture of a ring is a
// picture of, whichever door built it.
//
// The focus is reported beside the levels because it is what the levels are snapped to: a level's
// `center` is its own texel-snapped focus, so the three together say whether a level is current or
// still holds the one it replaces.
Dictionary Terrain3D::get_clipmap_layout_preview() const {
	Dictionary result;
	_vt.clipmap_preview_calls++;
	if (!has_vt_clipmap_ring()) {
		return result;
	}
	_vt.clipmap_preview_computed++;
	const Vector2 focus = v3v2(get_clipmap_target_position());
	result["focus"] = focus;
	result["size"] = _vt.clipmap_size;
	result["levels_setting"] = _vt.clipmap_levels;
	result["base_world"] = _vt.clipmap_base_world;
	result["budget_texels"] = _vt.clipmap_budget_texels;
	Array rings;
	for (int group = 0; group < TerrainVT::GROUP_COUNT; group++) {
		const TerrainVT::ChannelGroup channel = TerrainVT::ChannelGroup(group);
		const Terrain3DClipmap *ring = _vt.clipmap[group].get();
		if (ring == nullptr || !ring->is_configured()) {
			continue;
		}
		Dictionary entry;
		entry["group"] = TerrainVT::group_name(channel);
		entry["source"] = ring->get_source_name();
		entry["size"] = ring->get_size();
		entry["channels"] = ring->get_channel_count();
		entry["base_world"] = ring->get_base_world();
		entry["valid_levels"] = ring->get_level_valid_count();
		entry["pending_jobs"] = ring->get_pending_jobs();
		entry["produced_texels"] = int64_t(ring->get_produced_texels());
		entry["upload_bytes"] = int64_t(ring->get_upload_bytes());
		entry["levels"] = ring->get_layout_reports();
		rings.push_back(entry);
	}
	result["rings"] = rings;
	return result;
}
