// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3D's near field, part 1 of 5: the demand entry point and its configuration.

// One of five files that own the near field. `_update_sector_avt()` is the driver:
// it predicts the lead transform, derives the plan key, decides whether the previous plan can be
// reused, and otherwise runs the chain - scan, hierarchy, address directory, publish - and submits
// the result. The tier settings here are the ones the sector size is derived from
// (`get_avt_base_block_size()` and `_avt_logical_ratio()`), so they live beside the driver that
// reads them rather than in the properties file.
//
// The other four: `terrain_3d_sector_avt_motion.cpp` (the lead and the plan key),
// `terrain_3d_sector_avt_hierarchy.cpp` (the scan, the hierarchy, the address directory and its
// publication), `terrain_3d_avt_plan.cpp` (the plan worker this driver submits to) and
// `terrain_3d_avt_produce.cpp` (the production pass that spends the tick's budget on the installed
// plan). The prologue the trio of scan-side files share is `terrain_3d_sector_avt_internal.h`.

#include "terrain_3d_sector_avt_internal.h"

#include "terrain_3d.h"
#include "terrain_3d_avt_plan.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_vt_visibility.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/time.hpp>

using namespace TerrainAVT;

namespace {
constexpr float MOTION_PLAN_DEVIATION_COSINE = 0.9612617f; // cos(16 degrees), including 2-degree key quantization.

// A page's world *span* as an exact key, in 1/64 m units. The churn counters in
// `_avt_install_or_reuse_plan()` compare two generations by coverage rather than by address:
// `(mip, x, y)` and `(mip + 1, x / 2, y / 2)` cover the same rect, and so does the same rect after a
// sector's block size is raised, at one mip lower. Equality of the *rect* is the right question for
// "the same page", and intersection is the right question for "the same ground at another level" -
// a coarser page contains the ground, it is not the same rect.
//
// The quantum is 1/64 m because it has to be finer than the finest page and coarser than a float's
// resolution at world scale. The finest page is a 64 m sector at 2048 blocks, a span of 0.03125 m,
// so 0.015625 m keeps two distinct spans apart; and a float32 holds about 7 decimal digits, so at
// 4 km its own error is ~2.4e-4 m, far below the quantum, so two spellings of one span cannot land
// in different buckets.
constexpr double PAGE_SPAN_KEY_SCALE = 64.0;

int64_t avt_page_span_key(const Rect2 &p_rect) {
	return int64_t(std::llround(double(p_rect.size.x) * PAGE_SPAN_KEY_SCALE));
}

// The standing key stores each basis row in groups of three. The rendered
// forward axis is the third column, so its entries are 2, 5 and 8. The
// camera can move through a normal debounce interval, but once it is more than
// about one turn lead away from the standing plan, waiting for the interval
// makes the rendered frustum catch the plan from behind. Compare the cosine
// directly so this stays a cheap hot-path dot product; the small margin over
// 15 degrees absorbs the key's 2-degree yaw quantization.
bool avt_plan_angular_deviation_exceeded(const Transform3D &p_camera_transform, const Terrain3DAVTPlanKey &p_plan_key) {
	if (!is_valid_avt_plan_key(p_plan_key)) { return false; }
	const Vector3 camera_forward = -p_camera_transform.basis.get_column(2);
	const Vector3 plan_forward = avt_plan_key_forward(p_plan_key);
	const float camera_length = camera_forward.length();
	const float plan_length = plan_forward.length();
	if (camera_length <= 1e-6f || plan_length <= 1e-6f) { return false; }
	const float cosine = CLAMP(camera_forward.dot(plan_forward) / (camera_length * plan_length), -1.f, 1.f);
	return cosine < MOTION_PLAN_DEVIATION_COSINE;
}

// The key is for the lead transform, so compare the standing key with the camera position after
// removing the lead that is current this tick. A steady camera and a steady lead therefore do not
// force a plan every frame; an actual position error accumulates until it crosses the same bounded
// near-field fraction used by the discontinuity path.
bool avt_plan_spatial_deviation_exceeded(const Transform3D &p_camera_transform,
		const Terrain3DAVTPlanKey &p_plan_key, const Vector2 &p_motion_lead, const float p_reach) {
	if (!is_valid_avt_plan_key(p_plan_key)) { return false; }
	const Vector2 standing_origin = avt_plan_key_origin_xz(p_plan_key);
	const Vector2 standing_camera = standing_origin;
	const Vector2 camera_origin(p_camera_transform.origin.x, p_camera_transform.origin.z);
	const Vector2 deviation = camera_origin - standing_camera;
	const float threshold = avt_motion_spatial_discontinuity_distance(p_reach);
	return deviation.length_squared() > threshold * threshold;
}

}

// The taps a fragment actually gets, read from the one owner of that number: Godot's material
// samplers are built per viewport with `anisotropy_max = 1 << level`
// (`MaterialStorage::samplers_rd_allocate`), and a viewport's level defaults to the project's
// `rendering/textures/default_filters/anisotropic_filtering_level`, which is 4x. There is no
// per-material anisotropy in Godot, so the terrain cannot raise this: a wider
// `surface_vt_anisotropy` is a wish, not a tap count. The level math must not believe the wish.
//
// Why it matters, in the units the shader selects in. A grazing pixel's major-axis footprint is
// `ratio` times its minor-axis one. Anisotropic filtering answers that by clamping the minor axis to
// `major / taps` - so the mip it samples is the one whose texel is `major / taps` - and then taking
// `taps` samples at a stride of exactly one texel of that mip. Full coverage, no aliasing. A shader
// that picks the mip for a larger `taps` than the sampler has asks for a page whose texel is finer
// than `major / taps`; the sampler clamps only within the mips it may read (an AVT page is one
// physical mip, and the atlas carries exactly one), so it stays on that finer page and covers it
// with a stride of `assumed / actual` texels. The texels in between are never read: that is
// undersampling, and at a grazing angle it is visible as the distant ground crawling frame to frame.
float Terrain3D::get_avt_anisotropy_sampler(const Camera3D *p_camera) const {
	int level = 2;
	if (p_camera && p_camera->get_viewport()) {
		level = int(p_camera->get_viewport()->get_anisotropic_filtering_level());
	}
	return float(1 << CLAMP(level, 0, 4));
}

// The request as a number: the setting, or the sampler's own level when the setting is zero ("auto",
// which is the behaviour before the setting existed). Kept apart from the answer below because a
// report that printed only one of them could not say which bound reduced the other.
float Terrain3D::get_avt_anisotropy_request(const Camera3D *p_camera) const {
	int requested = _vt.surface_vt_anisotropy;
	if (requested <= 0) {
		requested = int(get_avt_anisotropy_sampler(p_camera));
	}
	return float(CLAMP(requested, 1, 16));
}

// The number the shader and the demand footprint both use: the request above, clamped by what the
// sampler delivers and by what the page gutter can sample. Two hard bounds and no policy - a
// filtering footprint can neither take taps the viewport does not give it nor reach past the border
// texels a page carries. With the mip selection holding the minor axis at about one texel, a ratio
// of n spans about n texels along the major axis, so `n / 2 + 0.5 <= border`, i.e. the gutter admits
// `2 * border - 1`. The shipped pair is a five-texel gutter and an 8x request, and on a stock
// project (4x filtering) the effective number is therefore 4, which is the fix for the grazing
// aliasing described above. `avt_anisotropy`, `..._sampler`, `..._requested` and `..._effective` in
// `get_vt_settings()` are the readings a project checks to see which bound binds. See
// docs/vt_sampling_review.md.
float Terrain3D::get_avt_anisotropy(const Camera3D *p_camera) const {
	const float supported = MAX(1.f, 2.f * float(_vt.vt_page_border) - 1.f);
	return MIN(MIN(get_avt_anisotropy_request(p_camera), get_avt_anisotropy_sampler(p_camera)), supported);
}

// The request above, as a setting. Unlike a density change this moves no page footprint - a page's
// world span is the same whatever the filtering footprint is - so it reconfigures nothing and
// releases nothing. The effective value is part of the AVT plan's state key, so a changed setting
// makes the next tick re-derive the plan by itself, which is what that key entry is for.
void Terrain3D::set_surface_vt_anisotropy(const int p_anisotropy) {
	const int clamped = CLAMP(p_anisotropy, 0, 16);
	if (_vt.surface_vt_anisotropy == clamped) { return; }
	_vt.surface_vt_anisotropy = clamped;
	if (_material.is_valid()) {
		RS->material_set_param(_material->get_material_rid(), "_surface_vt_anisotropy", get_avt_anisotropy(get_camera()));
	}
}

void Terrain3D::set_surface_vt_texels_per_meter(real_t p_value) {
	if (!std::isfinite(p_value)) { return; }
	p_value = CLAMP(p_value, 1.f, 8192.f);
	if (_vt.surface_vt_texels_per_meter == p_value) { return; }
	_vt.surface_vt_texels_per_meter = p_value;
	_reset_vt_configuration(); // A changed density changes every page footprint.
}

void Terrain3D::set_surface_svt_texels_per_meter(real_t p_value) {
	if (!std::isfinite(p_value)) { return; }
	set_surface_svt_page_world(_vt.vt_page_size / CLAMP(p_value, 0.01f, 8192.f));
}

int Terrain3D::get_avt_base_block_size() const {
	int size = 1;
	while (size < 64.f * _vt.surface_vt_texels_per_meter / _vt.vt_page_size) { size <<= 1; }
	return size;
}

// Local page-table depth follows the maximum allocation, not the tier count.
int Terrain3D::get_avt_mip_level_cap() const {
	return TerrainVT::log2_power_of_two(get_avt_base_block_size());
}

// The sample level at which the fallback table takes over, in the sample's own level units. It is
// derived from the two texel sizes rather than configured, so it cannot disagree with the tables it
// describes: the finest fallback texel is `avt_coarse.page_world / page_size`, the finest upgrade
// texel is `1 / texels_per_meter`, and the level between them is what separates "this sample is an
// upgrade" from "the fallback answers this sample". A zero means the two tiers are the same
// resolution and there is no upgrade range at all, which is the case the shader must not read as
// "everything is an upgrade".
float Terrain3D::get_avt_adaptive_threshold_level() const {
	const float fine_texel = 1.f / MAX(1.f, float(_vt.surface_vt_texels_per_meter));
	const float coarse_texel = _vt.avt_coarse.page_world / float(MAX(1, _vt.vt_page_size));
	if (_vt.avt_coarse.page_world <= 0.f || coarse_texel <= fine_texel) { return 0.f; }
	return std::log2(coarse_texel / fine_texel);
}

// An explicit sector resolution tier count. Legacy zero migrates to three.
void Terrain3D::set_surface_vt_mip_levels(const int p_levels) {
	const int clamped = p_levels <= 0 ? 3 : CLAMP(p_levels, 2, 16);
	if (_vt.surface_vt_mip_levels == clamped) { return; }
	_vt.surface_vt_mip_levels = clamped;
	invalidate_avt_plan_key(_vt.avt_plan.key);
	_vt.avt_settled.unverify();
}

// The number of texels a level 0 sector block carries per page, as a multiple of its page
// count: `size * logical_ratio` is the block's virtual resolution for `SECTOR_WORLD`
// metres. Derived here rather than read from the plan, because the chain that re-configures a
// view publishes its directory before it submits the plan: the first publish of a configuration
// would otherwise read the previous configuration's ratio.
float Terrain3D::_avt_logical_ratio() const {
	return SECTOR_WORLD * _vt.surface_vt_texels_per_meter / (_vt.vt_page_size * float(get_avt_base_block_size()));
}

// The near field's share of the tick's page budget: half of `vt_pages_per_update` while the far
// field is drawing from the same number, all of it otherwise. A pure function of the live VT
// configuration, spelled once because two readers size against it and they must not disagree.
//
// The tick hands the pass this many pages (`terrain_3d.cpp`), and the plan's own budget is a
// *residency* bound (`_avt_build_hierarchy()`, `pool - reserved`) with no term for how fast that
// residency can be filled. So the planner is the other reader: `_avt_submit_plan()` sizes the
// plan's unsampled tail - the speculative apron and the retention window - by this allowance times
// the refresh interval, which is the pages one plan generation can actually produce. Without that
// term a plan names its whole residency budget whatever the supply, and the measured result is a
// permanent sampled deficit, a pool with no free slot and a far field starved to its coarsest mip
// (`docs/vt_reference_avt_alignment.md` sections 7.5-7.7).
//
// The even split stays even, and that is now a measured decision rather than an inherited one. A
// fixed half looks wasteful - the far field's own demand is about **0.1 page a tick** once its
// root pyramid is pinned, while the near field consumes everything it is given - so the split was
// tried demand-aware, with the near field taking the remainder above a two-page floor for the far
// field (`docs/vt_reference_avt_alignment.md` section 7.7.1). The near field then produced fourteen a
// tick instead of eight and the sampled deficit did not fall at all: `n_miss` rose 41%, `evict`
// 54%, `fade_starts` 38% and `alloc` 38% against the same run with the term below and the even
// split. The near field's churn scales with its allowance, so its supply is not the binding
// constraint and giving it more buys churn rather than coverage. Do not re-try this without a
// measurement that says the demand has stopped scaling with the budget.
int Terrain3D::_avt_tick_allowance() const {
	const int remaining = _vt.vt_debug_direct_material ? 4 : _vt.vt_pages_per_update;
	return has_svt_delivery() ? MAX(1, remaining / 2) : remaining;
}

// The burst's half of the same split. It is a *rate* on top of the steady allowance and never a
// replacement for it: a burst asks for `AVT_COLD_BURST_FACTOR` times the configured page budget,
// bounded by what one pass may be handed and never below the steady share the far field's split
// already reserved. Off in the diagnostic direct-material mode, whose budget is pinned to four
// pages so the diagnostic measures what it always measured.
int Terrain3D::_avt_burst_allowance() const {
	if (_vt.avt_cold_burst_ticks <= 0 || _vt.vt_debug_direct_material) { return 0; }
	return avt_cold_burst_allowance(_vt.vt_pages_per_update, _avt_tick_allowance(), _vt.avt_cold_burst_ticks);
}

// The shared rate the burst moves. The producer admits this many page *writes* per displayed
// frame and the source queue holds this many prepared pages; the near field's own allowance is the
// third reader. All three are the same decision - how fast this view is filled - so they are spelled
// once. The steady value is the configured budget, which is what the producer has always been given.
int Terrain3D::_avt_page_budget() const {
	const int burst = _avt_burst_allowance();
	return burst > 0 ? burst : MAX(1, _vt.vt_pages_per_update);
}

void Terrain3D::set_surface_vt_mip_distances(const PackedFloat32Array &p_distances) {
	PackedFloat32Array normalized;
	for (int i = 0; i < MIN(16, int(p_distances.size())); ++i) {
		const float previous = i ? normalized[i - 1] : 0.f;
		normalized.push_back(std::isfinite(p_distances[i]) ? MAX(previous + 0.01f, p_distances[i]) : previous + 1.f);
	}
	_vt.surface_vt_mip_distances = normalized;
	invalidate_avt_plan_key(_vt.avt_plan.key);
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
}

int Terrain3D::get_surface_vt_mip_for_distance(real_t p_distance) const {
	const int top = is_sector_avt() ? _vt.surface_vt_mip_levels - 1 : TerrainVT::log2_power_of_two(_vt.surface_vt_pages_per_axis);
	int mip = 0;
	float edge = 8.f;
	while (mip < top) {
		if (mip < _vt.surface_vt_mip_distances.size()) { edge = _vt.surface_vt_mip_distances[mip]; }
		if (p_distance <= edge) { break; }
		++mip; edge *= 2.f;
	}
	return mip;
}

void Terrain3D::set_surface_vt_selection_mode(int p_mode) {
	p_mode = CLAMP(p_mode, 0, 2);
	if (_vt.surface_vt_selection_mode == p_mode) { return; }
	_vt.surface_vt_selection_mode = p_mode;
	_vt.vt_view_focus_valid = false;
	// A legacy region coordinate and a 64 m sector coordinate describe different
	// footprints. They cannot share cached address ownership across a mode switch.
	_reset_vt_configuration();
	notify_property_list_changed();
}

// One AVT demand pass per physics tick, in four phases: decide whether this tick
// plans at all, scan the resident regions into demand cells, turn that scan into
// a sorted working set with an address directory, and submit the page selection
// to a worker. Page production happens on every tick, planned or not.
int Terrain3D::_update_sector_avt(int p_max_pages) {
	if (!_vt.surface_vt || !_data || !_vt.vt_shared_ready || !get_camera()) { return 0; }
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	_vt.avt_sector_ticks++;
	// One tick of the cold-view burst is spent here, before the pass it pays for. The burst is armed
	// by the motion sampler where it recognises a cut (`_vt_arm_cold_view()`) and re-armed by the
	// production pass for as long as the plan the cut installed is still mostly missing, so counting
	// it down on the tick rather than on the pass keeps a burst from lasting longer than the ticks it
	// names. The rate the three consumers read is refreshed here too: the producer's frame budget and
	// the source queue window are not re-published by anything else while a plan is being produced.
	if (_vt.avt_cold_burst_ticks > 0) { --_vt.avt_cold_burst_ticks; ++_vt.avt_cold_burst_spent; }
	const int page_budget = _avt_page_budget();
	// The rate the producer's frame budget and the source queue window are both set from, published
	// on every tick rather than on the tick it moves. Both readers have to move together - a burst
	// that raised only one of them would stall on the other - and the source pipeline is built
	// lazily inside the production pass, so a change-detected publish can run on the one tick the
	// pipeline does not exist yet and leave the queue at the steady window for the whole burst.
	// Measured: a 180-degree cut at 1920x1080 kept `avt_source_queue_limit` at 32 while
	// `avt_page_budget` read 96, which held page completion to ~32 a frame and the ground flat for
	// twenty frames. Three atomic stores and one integer derivation a tick are not worth a state
	// machine that can miss.
	if (Terrain3DSurfaceBaker *producer = Object::cast_to<Terrain3DSurfaceBaker>(_vt.vt_baker.ptr())) {
		producer->set_page_budget(page_budget);
	}
	if (_vt.vt_page_pipeline) { _vt.vt_page_pipeline->set_queue_limit(page_budget); }
	if (_vt.svt_page_pipeline) { _vt.svt_page_pipeline->set_queue_limit(page_budget); }
	// The feedback switch's source, for the pages the burst has not served yet. It is a material
	// parameter, so it is re-published every tick it is on - a material rebuilt in the middle of a
	// cold view would come back with the default - and once when it turns off. Off is the steady
	// state and costs nothing.
	const bool cold_svt_source = _vt.avt_feedback_source == AVT_FEEDBACK_SOURCE_SVT && _vt.avt_burst_from_cut;
	if (cold_svt_source || cold_svt_source != _vt.avt_cold_svt_published) {
		if (_material.is_valid()) {
			RS->material_set_param(_material->get_material_rid(), "_avt_cold_svt_source", cold_svt_source);
		}
		_vt.avt_cold_svt_published = cold_svt_source;
	}
	// The arrival blend is off for the frames a cut's view is filling. It is the shader's own early
	// out (`surface_vt_page_fade()` answers 1 for every slot at zero frames), so the pages of a view
	// nothing had produced for are drawn as themselves the moment they land instead of being held at
	// the level they replaced for the length of the ramp. See `AVT_COLD_BURST_FADE_FRAMES`. Published
	// every tick rather than on change: the setting is republished by any material rebuild, and the
	// window is a handful of frames. `vt_page_fade_frames` itself is never changed.
	if (_material.is_valid()) {
		RS->material_set_param(_material->get_material_rid(), "_surface_vt_page_fade_frames",
				_vt.avt_burst_from_cut ? AVT_COLD_BURST_FADE_FRAMES : _vt.vt_page_fade_frames);
	}
	if (_vt.avt_cold_burst_ticks > 0) { _vt.avt_burst_peak = MAX(_vt.avt_burst_peak, page_budget); }
	// Fine eligibility follows the rendered frustum, as does the Inspector preview.
	// Keep motion tracking for refresh diagnostics, without excluding current cells
	// when a predicted turn points away from them.
	const Transform3D camera_transform = get_camera()->get_camera_transform();
	(void)_vt_lead_camera_transform(camera_transform);
	const Vector3 camera_position = camera_transform.origin;
	const Vector2 focus(camera_position.x, camera_position.z);
	const float reach = MAX(64.f, float(_vt.surface_vt_distance));
	// Published before the plan is installed or reused, so the readings describe this tick
	// and not the last one that ran the whole planning chain.
	_vt.avt_sector_stats["motion_lead_m"] = _vt.avt_motion_lead.length();
	_vt.avt_sector_stats["motion_speed"] = _vt.avt_motion_velocity.length();
	// The turn half of the reading: the estimated rate and the lead actually aimed with. A turn
	// whose lead is zero is a turn the plan is not ahead of, which is the one thing to look at
	// when a view streams while turning and not while running.
	_vt.avt_sector_stats["motion_turn_deg_s"] = Math::rad_to_deg(_vt.avt_motion_turn.length());
	_vt.avt_sector_stats["motion_turn_lead_deg"] = Math::rad_to_deg(_vt.avt_motion_turn_lead.length());
	_vt.avt_sector_stats["plan_origin"] = focus;
	_vt.avt_sector_stats["camera_origin"] = Vector2(camera_transform.origin.x, camera_transform.origin.z);
	if (!_vt.vt_source_snapshot) { _vt.vt_source_snapshot = Terrain3DPagePipeline::snapshot(_data, _region_size, _vertex_spacing, _surface_density); }
	const bool bounds_ready = _vt.vt_source_snapshot->bounds_ready.load(std::memory_order_acquire);

	const uint64_t plan_state_started = Time::get_singleton()->get_ticks_usec();
	const Terrain3DAVTPlanKey plan_key = _avt_plan_state(bounds_ready);
	_vt.avt_plan_state_sum_ms += double(Time::get_singleton()->get_ticks_usec() - plan_state_started) / 1000.0;
	// Diagnostic: a plan key that changes every frame re-plans the whole working set, so
	// which component moved is the question worth answering. Component indices follow
	// `_avt_plan_state` (9 basis, 3 origin, 16 projection, 4 viewport, then the scalars), which is
	// also the element index of the key; an invalidated key has no component to report.
	{
		int first = -1;
		if (is_valid_avt_plan_key(_vt.avt_plan.key)) {
			for (size_t i = 0; i < plan_key.size(); ++i) {
				if (plan_key[i] != _vt.avt_plan.key[i]) { first = int(i); break; }
			}
		}
		_vt.avt_sector_stats["plan_key_dirty_component"] = first;
		_vt.avt_sector_stats["plan_key_unchanged"] = first < 0;
	}
	_vt.avt_key_sum_ms += double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	const uint64_t install_started = Time::get_singleton()->get_ticks_usec();
	// A changed key does not have to mean a new plan: the plan is a look-ahead artifact, and the
	// chain that derives it is the most expensive thing in the tick. Inside the refresh interval a
	// changed key reuses the standing plan, which is what the production pass then works from.
	// `avt_plan.key` is deliberately left at the key the standing plan was planned for, so the
	// tick after the interval sees the change and plans.
	//
	// A key that was *invalidated* is not camera motion and does not wait: a region was added or
	// removed, a slot was swapped, the material or the pool was rebuilt, and the standing plan
	// describes a world that no longer exists. Only a key that changed because the view moved is
	// held for the interval, which is the whole of what the interval is for. Measured: without
	// this distinction a region whose slot had just been swapped rendered the missing-page
	// diagnostic until the interval expired.
	const uint64_t frame_now = Engine::get_singleton()->get_process_frames();
	const bool key_same = _vt.avt_plan.key == plan_key;
	const bool key_valid = is_valid_avt_plan_key(_vt.avt_plan.key);
	const bool angular_refresh = !key_same && avt_plan_angular_deviation_exceeded(camera_transform, _vt.avt_plan.key);
	const bool spatial_refresh = avt_plan_spatial_deviation_exceeded(camera_transform,
			_vt.avt_plan.key, _vt.avt_motion_lead, reach);
	const bool refresh_due = !key_valid || _vt.avt_last_chain_frame == UINT64_MAX ||
			frame_now >= _vt.avt_last_chain_frame + _vt.avt_plan_refresh_frames || angular_refresh || spatial_refresh;
	_vt.avt_sector_stats["plan_spatial_refresh"] = spatial_refresh;
	_vt.avt_sector_stats["discard_retained_pending"] = _vt.avt_discard_retained;
	if (!key_same && !refresh_due) { _vt.avt_plan_refresh_skips++; }
	// A spatial deviation can be large even while quantization leaves the key unchanged. Let it
	// enter the existing chain path; otherwise `key_same` would turn the guard into a diagnostic
	// with no effect.
	const bool reuse_plan = (key_same && !spatial_refresh) || !refresh_due;
	const int finished = _avt_install_or_reuse_plan(started, p_max_pages, reuse_plan);
	_vt.avt_install_sum_ms += double(Time::get_singleton()->get_ticks_usec() - install_started) / 1000.0;
	// Where a tick's cost goes, summed over the session: the plan key, the install or reuse
	// decision - which includes a production pass on every path, so it is not the tick's total -
	// and the planning chain a moving camera pays on the ticks where the key changed. The
	// per-pass sums are beside them, and `idle_ticks` is the count of ticks the production pass
	// answered as already settled.
	auto publish_tick_sums = [this]() {
		const uint64_t produce_calls = _vt.avt_reuse_ticks + _vt.avt_chain_ticks;
		_vt.avt_sector_stats["sector_ticks"] = int64_t(_vt.avt_sector_ticks);
		_vt.avt_sector_stats["reuse_ticks"] = int64_t(_vt.avt_reuse_ticks);
		_vt.avt_sector_stats["chain_ticks"] = int64_t(_vt.avt_chain_ticks);
		_vt.avt_sector_stats["capacity_skip_ticks"] = int64_t(_vt.avt_capacity_skip_ticks);
		_vt.avt_sector_stats["plan_refresh_skips"] = int64_t(_vt.avt_plan_refresh_skips);
		_vt.avt_sector_stats["plan_refresh_frames"] = int64_t(_vt.avt_plan_refresh_frames);
		_vt.avt_sector_stats["idle_ticks"] = int64_t(produce_calls - MIN(produce_calls, _vt.avt_pass_count));
		_vt.avt_sector_stats["key_sum_ms"] = _vt.avt_key_sum_ms;
		_vt.avt_sector_stats["plan_state_sum_ms"] = _vt.avt_plan_state_sum_ms;
		_vt.avt_sector_stats["install_sum_ms"] = _vt.avt_install_sum_ms;
		_vt.avt_sector_stats["chain_sum_ms"] = _vt.avt_chain_sum_ms;
		_vt.avt_sector_stats["produce_sum_ms"] = _vt.avt_produce_sum_ms;
		_vt.avt_sector_stats["update_sum_ms"] = _vt.avt_update_sum_ms;
		_vt.avt_sector_stats["wrapper_sum_ms"] = _vt.avt_wrapper_sum_ms;
	};
	auto leave = [this, &publish_tick_sums, started](const int p_result) {
		_vt.avt_update_sum_ms += double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
		publish_tick_sums();
		return p_result;
	};
	if (finished >= 0) {
		_vt.avt_reuse_ticks++;
		return leave(finished);
	}
	_vt.avt_chain_ticks++;
	_vt.avt_last_chain_frame = frame_now;

	_vt.avt_sector_stats["plan_reused"] = false;
	_vt.avt_sector_stats["coverage_center"] = focus;
	_vt.avt_sector_stats["coverage_radius"] = has_svt_delivery() ? reach : -1.f;
	// Phase timings for the uncached path, which is the one a moving camera takes on
	// every tick: the visible scan, the sector hierarchy, the address directory, the
	// hand-off to the refinement worker, the directory upload and the page production.
	TerrainVT::VisibleView view(camera_transform, get_camera()->get_camera_projection(),
			get_camera()->get_viewport() ? get_camera()->get_viewport()->get_visible_rect().size.y : 720.f,
			get_camera()->get_projection() == Camera3D::PROJECTION_ORTHOGONAL, 192.f);
	view.anisotropy = get_avt_anisotropy(get_camera());
	if (_material.is_valid()) {
		RS->material_set_param(_material->get_material_rid(), "_surface_vt_anisotropy", view.anisotropy);
	}
	// The chain runs in one pass. Staging it across ticks was tried and reverted: the
	// install/reuse path above resets the stage cursor, so a chain that was interrupted
	// between phases could be discarded before it published, which left the directory
	// stale and the view rendering the missing-page diagnostic for whole sectors.
	//
	// The scratch members the phases hand each other are reused rather than rebuilt, so a
	// plan tick does not reallocate the scan and the hierarchy it is about to discard.
	uint64_t phase_start = Time::get_singleton()->get_ticks_usec();
	const uint64_t chain_started = phase_start;
	auto mark_phase = [this, &phase_start](const char *p_key) {
		const uint64_t now = Time::get_singleton()->get_ticks_usec();
		_vt.avt_sector_stats[p_key] = double(now - phase_start) / 1000.0;
		phase_start = now;
	};
	_vt.avt_pending_scan = _avt_scan_sectors(view, camera_position, bounds_ready, Vector2(camera_transform.origin.x, camera_transform.origin.z), reach);
	mark_phase("scan_ms");
	_vt.avt_pending_hierarchy = _avt_build_hierarchy(_vt.avt_pending_scan);
	_vt.avt_pending_scan = Terrain3DAVTSectorScan();
	mark_phase("hierarchy_ms");
	_avt_sync_address_directory(_vt.avt_pending_hierarchy, focus, reach);
	mark_phase("sync_ms");
	_publish_avt_directory(_vt.avt_pending_hierarchy);
	mark_phase("publish_ms");
	_avt_submit_plan(_vt.avt_pending_hierarchy, plan_key, view, camera_position, bounds_ready, focus, reach);
	mark_phase("submit_ms");
	_vt.avt_chain_sum_ms += double(Time::get_singleton()->get_ticks_usec() - chain_started) / 1000.0;
	_vt.avt_plan.key = plan_key;
	_vt.avt_pending_hierarchy = Terrain3DAVTHierarchy();

	_vt.avt_sector_stats["height_bounds_ready"] = bounds_ready;
	_vt.avt_sector_stats["retained_hierarchy"] = true;
	_vt.avt_sector_stats["planning_pending"] = true;
	_vt.avt_sector_stats["base_virtual_resolution"] = SECTOR_WORLD * _vt.surface_vt_texels_per_meter;
	_vt.avt_sector_stats["base_page_entries"] = SECTOR_WORLD * _vt.surface_vt_texels_per_meter / _vt.vt_page_size;
	_vt.avt_sector_stats["indirection_size"] = 2048;
	const uint64_t produce_started = Time::get_singleton()->get_ticks_usec();
	const int produced = _produce_sector_avt_pages(p_max_pages);
	_vt.avt_produce_sum_ms += double(Time::get_singleton()->get_ticks_usec() - produce_started) / 1000.0;
	mark_phase("produce_ms");
	_vt.avt_sector_stats["cpu_update_ms"] = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	return leave(produced);
}

// Fixed camera/configuration key: no per-frame Variant arrays or region scan.
// All source edits invalidate this key together with the source snapshot.
Terrain3DAVTPlanKey Terrain3D::_avt_plan_state(const bool p_bounds_ready) const {
	const Camera3D *camera = get_camera();
	// Filled in place and returned by value: this runs on every tick of a moving view, and the
	// byte array it used to be built into was a 512 byte allocation and a copy per tick.
	Terrain3DAVTPlanKey state = {};
	// Quantize the rendered camera used by the sector scan. Motion prediction must
	// not rotate the demand away from the image currently being drawn.
	const Transform3D transform = _vt_plan_key_transform(camera->get_camera_transform());
	int component = TERRAIN_AVT_PLAN_BASIS_OFFSET;
	auto append = [&](double value) { state[component++] = value; };
	for (int row = 0; row < 3; ++row) for (int col = 0; col < 3; ++col) { append(transform.basis[row][col]); }
	component = TERRAIN_AVT_PLAN_ORIGIN_OFFSET;
	for (int axis = 0; axis < 3; ++axis) { append(transform.origin[axis]); }
	const Projection projection = camera->get_camera_projection();
	component = TERRAIN_AVT_PLAN_PROJECTION_OFFSET;
	for (int col = 0; col < 4; ++col) for (int row = 0; row < 4; ++row) { append(projection[col][row]); }
	const Rect2 viewport = camera->get_viewport()->get_visible_rect();
	component = TERRAIN_AVT_PLAN_VIEWPORT_OFFSET;
	append(viewport.position.x); append(viewport.position.y); append(viewport.size.x); append(viewport.size.y);
	component = TERRAIN_AVT_PLAN_SCALARS_OFFSET;
	append(p_bounds_ready); append(_region_size); append(_vertex_spacing);
	append(_vt.surface_vt_texels_per_meter); append(_vt.surface_vt_texels_per_pixel); append(_vt.vt_adaptive_enabled);
	// The far field's visible count is what reserves part of the pool, but it moves by a page
	// or two on every frame of a moving view. Bucketing it keeps the near field's plan
	// installable while its own footprint is unchanged; an exact count in the key re-planned
	// the whole working set whenever the far field gained or lost a single page.
	append((_vt.vt_svt_visible_pages / 16) * 16); append(has_svt_delivery()); append(_vt.surface_vt_distance);
	append(_vt.bake.busy());
	append(_vt.vt_page_count); append(_vt.vt_page_size);
	append(get_avt_anisotropy(camera));
	// The chain's depth is part of what a plan is a function of: a shorter chain is a different
	// page set, and a setting changed under a standing plan has to make the next tick re-derive it.
	append(get_avt_mip_level_cap());
	// Protected far roots consume physical slots independently of visible detail.
	append(_vt.svt_roots.pages.size());
	append(_vt.surface_vt_mip_levels);
	for (int i = 0; i < 16; ++i) { append(i < _vt.surface_vt_mip_distances.size() ? _vt.surface_vt_mip_distances[i] : -1.f); }
	return state;
}

// Only planning is cached. Page requests still touch residency and repair
// invalidated/evicted pages on every demand epoch, within the normal budget.
int Terrain3D::_avt_install_or_reuse_plan(const uint64_t p_started, const int p_max_pages, const bool p_same_plan) {
	bool installed = false;
	if (_vt.avt_refinement && _vt.avt_refinement->ready.load(std::memory_order_acquire)) {
		if (_vt.avt_refinement->key == _vt.avt_plan.key) {
			// Sizing the pool for the pages the image actually samples, not for everything the
			// plan names. The speculative apron is a function of the leftover budget, so
			// counting it here closes a loop - a larger pool allows a larger apron, which asks
			// for a larger pool - and the pair grows until the capacity cap: measured at 1024
			// slots holding 53 near-field pages. The apron and the retained tail live in the
			// slack of that capacity instead.
			//
			// The same loop runs one step wider through the retention window, which is appended
			// to the plan after this call: a request that counted it asked for capacity the plan
			// only holds for a few epochs, and the request is what the pool's growth is driven
			// by. `sampled` is the pages the image is shading, which is the number above.
			// No floor of one here: a request of zero pages must not grow the pool, which is what
			// a minimum of eight slots per request would do on every empty plan.
			if (_ensure_vt_capacity(_vt.avt_refinement->sampled + _vt.vt_svt_visible_pages)) {
				// The pool is waiting for a larger capacity, so this tick produced nothing and
				// did not classify either. Counted separately from the settled shortcut, which
				// reads the same way from the outside.
				_vt.avt_capacity_skip_ticks++;
				return 0;
			}
			// A grazing mip can disappear for one plan and reappear immediately.
			// Let recently requested jobs finish instead of repeatedly cancelling
			// their prepared source bytes. Current visibility always comes first.
			const uint64_t epoch = ++_vt.avt_plan_epoch;
			// The retained scan compares every address in the plan against every address
			// still requested. A tree node per address costs more than one tick's whole
			// budget, so the current set is a sorted array searched in place.
			std::vector<std::array<int, 5>> current;
			current.reserve(_vt.avt_refinement->pages.size());
			for (Terrain3DAVTPageRequest &page : _vt.avt_refinement->pages) {
				page.last_visible_plan = epoch;
				current.push_back({ page.owner.x, page.owner.y, page.mip, page.x, page.y });
			}
			std::sort(current.begin(), current.end());
			// P0e: attribute the address churn. `current` is the selection the worker just made and
			// `_vt.avt_plan.pages` is still the plan that was standing until now, so this is the one
			// place where two generations can be compared. An address in the first that is not in the
			// second needs a physical slot of its own, bought out of whatever the pool can recycle at
			// the tick's allowance - which is the churn the phase E run measures (`alloc` and `evict`
			// advancing together, `free` pinned at 0). What those new addresses *are* decides which
			// mechanism can remove them:
			//
			// * carried - the previous plan already named this address. No slot, no production; the
			//   number says how much of each generation is stable.
			// * overlapped - the address is new, but a previous page **of the same owner** had a rect
			//   that intersects this one. Another level means another span, so "the same ground at a
			//   level the rule re-derived" shows up as an *overlapping* rect, never as an equal one -
			//   the first version of these counters tested rect equality and read a structural zero,
			//   which was an artefact of the test and not a property of the addressing. This is the
			//   counter that decides the level question.
			// * rescaled - the owner was in the previous plan but at no such *span*: the sector's
			//   virtual block size stepped (`_avt_sync_address_directory()` only ever raises it), or
			//   the refinement walk reached a new mip in it.
			// * reselected - the owner and the span were both in the previous plan, but this page was
			//   not. The same scale, a different page: the boundary decisions
			//   (`projected > 1.f`, `minimum_density * span <= page_size * 2.f`) moved.
			// * new_sector - no page of this owner was in the previous plan at all, so the view
			//   reached an owner it was not looking at. Legitimate demand that no policy removes.
			//
			// `plan_dropped` is the other direction: addresses the previous plan named that this one
			// does not, which is what the retention window has to hold and what the pool may finally
			// evict. Section 7.7.1 records why these counters exist - a supply change was measured,
			// rejected, and left the question of what the churn *is* unanswered.
			std::vector<std::array<int, 5>> previous;
			// One entry per (owner, span): whether that owner's *scale* is one the previous plan had.
			std::vector<std::array<int64_t, 3>> previous_scales;
			// The previous plan's rects grouped by owner, which is what the overlap test needs. Only
			// pages of one owner can overlap - their rects are laid out on that owner's own grid - so
			// the scan per new page is bounded by the few pages an owner has.
			std::vector<std::pair<std::array<int, 2>, Rect2>> previous_by_owner;
			previous.reserve(_vt.avt_plan.pages.size());
			previous_scales.reserve(_vt.avt_plan.pages.size());
			previous_by_owner.reserve(_vt.avt_plan.pages.size());
			for (const Terrain3DAVTPageRequest &page : _vt.avt_plan.pages) {
				previous.push_back({ page.owner.x, page.owner.y, page.mip, page.x, page.y });
				previous_scales.push_back({ int64_t(page.owner.x), int64_t(page.owner.y),
						avt_page_span_key(page.rect) });
				previous_by_owner.push_back({ { page.owner.x, page.owner.y }, page.rect });
			}
			std::sort(previous.begin(), previous.end());
			std::sort(previous_scales.begin(), previous_scales.end());
			previous_scales.erase(std::unique(previous_scales.begin(), previous_scales.end()), previous_scales.end());
			std::sort(previous_by_owner.begin(), previous_by_owner.end(),
					[](const std::pair<std::array<int, 2>, Rect2> &p_left, const std::pair<std::array<int, 2>, Rect2> &p_right) {
						return p_left.first < p_right.first;
					});
			int carried = 0;
			int overlapped = 0;
			int new_sector = 0;
			int rescaled = 0;
			for (const Terrain3DAVTPageRequest &page : _vt.avt_refinement->pages) {
				const std::array<int, 5> address{ page.owner.x, page.owner.y, page.mip, page.x, page.y };
				if (std::binary_search(previous.begin(), previous.end(), address)) {
					++carried;
					continue;
				}
				const std::array<int, 2> owner{ page.owner.x, page.owner.y };
				const std::pair<std::array<int, 2>, Rect2> owner_key{ owner, Rect2() };
				const auto range = std::equal_range(previous_by_owner.begin(), previous_by_owner.end(), owner_key,
						[](const std::pair<std::array<int, 2>, Rect2> &p_left, const std::pair<std::array<int, 2>, Rect2> &p_right) {
							return p_left.first < p_right.first;
						});
				if (range.first == range.second) {
					// No page of this owner was in the previous plan at all: the view reached an
					// owner it was not looking at. Real demand.
					++new_sector;
					continue;
				}
				for (auto entry = range.first; entry != range.second; ++entry) {
					if (entry->second.intersects(page.rect)) { ++overlapped; break; }
				}
				const std::array<int64_t, 3> scale{ int64_t(page.owner.x), int64_t(page.owner.y),
						avt_page_span_key(page.rect) };
				if (!std::binary_search(previous_scales.begin(), previous_scales.end(), scale)) {
					++rescaled;
				}
			}
			// P2: *which way* the refinement depth moved, per owner. The first attempt at this asked
			// the same question of the overlap test - was the previous rect over this ground finer,
			// equal, or coarser than the new page - and all four of its buckets were structurally
			// single-valued: `coarser` came out equal to `overlapped` in every generation of that run,
			// and the other three never printed a value but zero. That is a tautology and not a
			// property of the world: **a newly refined child always intersects its parent, and the
			// parent is always in the previous plan**, so "the previous rect here was larger" is what
			// being a child *means*. The identity is even provable from the counters that remain:
			// `overlapped + new_sector == selected - carried` in every generation, which is exactly
			// "no new address lacked a covering rect of its owner". A counter that cannot take more
			// than one value is not a measurement (section 9).
			//
			// Depth per owner is the quantity that can take three values, so it is what is compared:
			// the finest world span each plan offers for each owner. Finer than before is the walk
			// reaching a deeper mip in that owner, or that owner's block size stepping (the two are
			// told apart by `sector_size_grows`, which counts the sectors whose size stepped), and
			// coarser is the walk giving up a level it had. World span rather than the mip index,
			// because a block-size step moves the mip index of an unchanged span.
			auto min_span_by_owner = [](const std::vector<std::pair<std::array<int, 2>, Rect2>> &p_sorted,
											const std::array<int, 2> &p_owner, float &r_min) {
				const std::pair<std::array<int, 2>, Rect2> key{ p_owner, Rect2() };
				const auto range = std::equal_range(p_sorted.begin(), p_sorted.end(), key,
						[](const std::pair<std::array<int, 2>, Rect2> &p_left, const std::pair<std::array<int, 2>, Rect2> &p_right) {
							return p_left.first < p_right.first;
						});
				if (range.first == range.second) { return false; }
				r_min = FLT_MAX;
				for (auto entry = range.first; entry != range.second; ++entry) { r_min = MIN(r_min, entry->second.size.x); }
				return true;
			};
			// The new selection's rects, grouped the same way, so the two plans can be compared owner
			// by owner without a map on the hot path.
			std::vector<std::pair<std::array<int, 2>, Rect2>> current_by_owner;
			current_by_owner.reserve(current.size());
			for (const Terrain3DAVTPageRequest &page : _vt.avt_refinement->pages) {
				current_by_owner.push_back({ { page.owner.x, page.owner.y }, page.rect });
			}
			std::sort(current_by_owner.begin(), current_by_owner.end(),
					[](const std::pair<std::array<int, 2>, Rect2> &p_left, const std::pair<std::array<int, 2>, Rect2> &p_right) {
						return p_left.first < p_right.first;
					});
			int depth_deepened = 0;
			int depth_receded = 0;
			int depth_same = 0;
			for (auto entry = current_by_owner.begin(); entry != current_by_owner.end();) {
				const std::array<int, 2> owner = entry->first;
				float previous_min = 0.f;
				float current_min = FLT_MAX;
				while (entry != current_by_owner.end() && entry->first == owner) { current_min = MIN(current_min, entry->second.size.x); ++entry; }
				if (!min_span_by_owner(previous_by_owner, owner, previous_min)) { continue; } // new_sector above
				if (current_min < previous_min * (1.f - 1e-4f)) {
					++depth_deepened;
				} else if (current_min > previous_min * (1.f + 1e-4f)) {
					++depth_receded;
				} else {
					++depth_same;
				}
			}
			const int selected = int(_vt.avt_refinement->pages.size());
			// A plan that mostly names ground the previous one did not is a view nothing has produced
			// for: a snap turn, a teleport, a camera that left the working set. The motion sampler arms
			// the same cold state where it recognises the cut itself; this arms it from the plan, so a
			// cut that fell inside one refresh interval, or that was not a rotation at all, is covered
			// too. A moving camera's consecutive plans overlap heavily - `carried` is most of the
			// selection - so ordinary streaming never reaches the threshold.
			if (selected > 0 && selected - carried > selected / 2) { _vt_arm_cold_view(); }
			_vt.avt_sector_stats["plan_selected"] = selected;
			_vt.avt_sector_stats["plan_carried"] = carried;
			_vt.avt_sector_stats["plan_overlapped"] = overlapped;
			_vt.avt_sector_stats["plan_new_area"] = selected - carried;
			_vt.avt_sector_stats["plan_new_sector"] = new_sector;
			_vt.avt_sector_stats["plan_rescaled"] = rescaled;
			_vt.avt_sector_stats["plan_reselected"] = selected - carried - new_sector - rescaled;
			// Owners whose finest span moved, which is the level question the address counters
			// cannot answer. `depth_deepened` plus `depth_same` plus `depth_receded` is the number
			// of owners both plans held; compare it with `avt_sectors` for how much of the near
			// field that is.
			_vt.avt_sector_stats["plan_depth_deepened"] = depth_deepened;
			_vt.avt_sector_stats["plan_depth_receded"] = depth_receded;
			_vt.avt_sector_stats["plan_depth_same"] = depth_same;
			_vt.avt_sector_stats["plan_dropped"] = int(previous.size()) - carried;
			// The window is at least one lead wide: a page the plan moved ahead of is still
			// in the image being rendered, and dropping its request would let the pool evict
			// it out from under the view that has not caught up yet.
			//
			// It is bounded twice, and the two bounds answer different questions. `retain_cap`
			// is the planner's *rate* term - the part of it the apron did not spend - so the
			// completed plan never holds more unsampled pages than one refresh window can produce.
			// The budget expression beside it is the *residency* invariant, held where the append
			// happens: what this installs is never larger than the residency it is served from.
			// The residency bound alone was what stood here, as a fixed `MIN(128, budget - size)`,
			// and it let the window keep a hundred addresses for `retain_epochs` generations while
			// every one of them held a slot the sampled set needed (section 7.7).
			const bool discard_retained = _vt.avt_discard_retained;
			const int retain_cap = discard_retained ? 0 :
				MIN(_vt.avt_refinement->retain_cap,
						MAX(0, _vt.avt_refinement->budget - int(_vt.avt_refinement->pages.size())));
			// Which of the previous view's pages the window holds is a decision about mips, not about
			// plan order. The plan is laid out coarse end first, so taking its first `retain_cap`
			// entries keeps the coarsest pages - the ones the always-resident fallback ladder already
			// answers for, and the cheapest to produce again - and drops the fine ones, which are
			// exactly the pages a level regression costs a source read, a bake and an arrival ramp to
			// get back. The candidates are therefore ordered by fineness (the smallest world span
			// first), then by how recently the view asked for them, so the window keeps the deepest
			// level of each sector the view has just left. That is the whole point of the window: a
			// level the view has left stays addressable and resident, so coming back to it is a
			// switch rather than a rebuild.
			std::vector<const Terrain3DAVTPageRequest *> retainable;
			retainable.reserve(64);
			for (const Terrain3DAVTPageRequest &page : _vt.avt_plan.pages) {
				// The fallback ladder is re-published by every plan and is reserved in the pool; it
				// needs no window.
				if (page.owner == avt_coarse_owner()) { continue; }
				if (page.last_visible_plan + uint64_t(_vt.avt_retain_epochs) < epoch ||
						std::binary_search(current.begin(), current.end(),
								std::array<int, 5>{ page.owner.x, page.owner.y, page.mip, page.x, page.y })) {
					continue;
				}
				retainable.push_back(&page);
			}
			std::stable_sort(retainable.begin(), retainable.end(),
					[](const Terrain3DAVTPageRequest *p_left, const Terrain3DAVTPageRequest *p_right) {
						if (p_left->rect.size.x != p_right->rect.size.x) { return p_left->rect.size.x < p_right->rect.size.x; }
						return p_left->last_visible_plan > p_right->last_visible_plan;
					});
			int retained = 0;
			float retained_finest = 0.f;
			for (const Terrain3DAVTPageRequest *page : retainable) {
				if (retained == retain_cap) { break; }
				Terrain3DAVTPageRequest retained_page = *page;
				// A retained request belongs to the previous view. Keep it available
				// for residency, but never let it outrank pages the current image
				// samples when the producer refills its queue.
				retained_page.priority.kind = TerrainVT::PageRequestKind::OPTIONAL;
				_vt.avt_refinement->pages.push_back(retained_page);
				retained_finest = retained_finest > 0.f ? MIN(retained_finest, page->rect.size.x) : page->rect.size.x;
				++retained;
			}
			_vt.avt_retained_pages = retained;
			if (discard_retained) {
				// The old plan remains resident and drawable until normal demand classification
				// evicts it; only its retained source requests are omitted from this wanted set.
				_vt.avt_discard_retained = false;
			}
			_vt.avt_sector_stats["retained_requests"] = retained;
			// The finest world span the window holds, so the reading says *what level* the window is
			// keeping rather than only how many pages it kept. A window whose finest entry is a
			// whole-cell page is one that kept the fallback ladder; one whose finest entry is a
			// sub-metre page is one that kept the level the view just left.
			_vt.avt_sector_stats["retained_finest_texel_world"] = retained_finest;
			// The rate term as derived, as spent, and as it landed: `plan_tail_cap` is the whole
			// term, `plan_retain_share` what the retention append was allowed, and
			// `plan_apron_pages` the speculative part of the plan the refinement walk accepted. A
			// plan whose tail sits at the term is a plan at the production rate; one well under it
			// is a plan with nothing speculative to do.
			_vt.avt_sector_stats["plan_tail_cap"] = _vt.avt_refinement->tail_cap;
			_vt.avt_sector_stats["plan_retain_share"] = _vt.avt_refinement->retain_cap;
			_vt.avt_sector_stats["plan_apron_pages"] = int(_vt.avt_refinement->pages.size()) - retained - _vt.avt_refinement->sampled;
			_vt.avt_sector_stats["retain_epochs"] = _vt.avt_retain_epochs;
			// The selection and the retention flags are one operation: a new plan is a new wanted
			// set, so the source queue has to be retained again.
			_vt.avt_plan.install(std::move(_vt.avt_refinement->pages), _vt.avt_refinement->sampled,
					std::move(_vt.avt_refinement->warm));
			_vt.avt_density_scale = float(_vt.surface_vt_texels_per_pixel) * std::exp2(-float(_vt.avt_refinement->mip_bias));
			if (_material.is_valid()) {
				RS->material_set_param(_material->get_material_rid(), "_avt_density_scale", _vt.avt_density_scale);
			}
			_vt.avt_sector_stats["capacity_mip_bias"] = _vt.avt_refinement->mip_bias;
			_vt.avt_sector_stats["sampling_density_scale"] = _vt.avt_density_scale;
			_vt.avt_prefetch_cursor = 0;
			_vt.avt_prefetch_cycle_pending = false;
			_vt.avt_sector_stats["refinement_requests_denied"] = _vt.avt_refinement->denied;
			_vt.avt_sector_stats["finest_requested_texel_world"] = _vt.avt_refinement->finest;
			_vt.avt_sector_stats["visible_root_pages"] = _vt.avt_refinement->roots;
			_vt.avt_sector_stats["requested_physical_pages"] = int(_vt.avt_plan.pages.size());
			// What the plan is made of, by level: the histogram of local mips over the 64 m sector
			// pages it holds and the count of world-node pages. The fine entries are what a fragment
			// samples and the coarse ones are the fallback ladder above them, which is the residency
			// a shorter chain could give back. See `Terrain3DAVTRefinement::level_mips`.
			_vt.avt_sector_stats["plan_level_mips"] = _vt.avt_refinement->level_mips;
			_vt.avt_sector_stats["plan_world_pages"] = _vt.avt_refinement->world_pages;
			// How much of the plan exists for ground the view did not sample. It is the reading that
			// says whether a cell beside the frustum's edge holds a chain or a single whole-cell page.
			_vt.avt_sector_stats["plan_invisible_cell_pages"] = _vt.avt_refinement->invisible_cell_pages;
			_vt.avt_sector_stats["prefetch_requests"] = int(_vt.avt_plan.prefetch.size());
			_vt.avt_sector_stats["planning_ms"] = double(_vt.avt_refinement->elapsed_us) / 1000.;
			_vt.avt_sector_stats["plan_age_ms"] = double(p_started - _vt.avt_refinement->submitted_us) / 1000.;
			installed = true;
		}
		_vt.avt_refinement.reset();
	}
	_vt.avt_sector_stats["planning_pending"] = bool(_vt.avt_refinement);
	// Finish an in-flight plan instead of replacing it on every camera tick.
	// Installing a completed plan must not insert an idle planning frame. Its
	// requests remain active while the next camera view is submitted below.
	if (p_same_plan || _vt.avt_refinement) {
		_vt.avt_settled.reused = !installed;
		_vt.avt_sector_stats["plan_reused"] = _vt.avt_settled.reused;
		_vt.avt_sector_stats["directory_rebuilt"] = false;
		const int produced = _produce_sector_avt_pages(p_max_pages);
		_vt.avt_sector_stats["cpu_update_ms"] = double(Time::get_singleton()->get_ticks_usec() - p_started) / 1000.0;
		return produced;
	}
	// A plan that is not being reused leaves the settled verdict false: the caller goes on to run
	// this tick's production pass, and it must not read the absence of an install as an idle plan
	// and skip the work the new view needs.
	_vt.avt_settled.reused = false;
	return -1;
}

// Submits this key's page selection to the plan pipeline. The selection is the
// expensive half (it walks the visible mip interval per cell), so it runs on the
// plan worker and arrives through _avt_install_or_reuse_plan on a later tick.
void Terrain3D::_avt_submit_plan(Terrain3DAVTHierarchy &r_hierarchy, const Terrain3DAVTPlanKey &p_plan_key,
		const TerrainVT::VisibleView &p_view,
		const Vector3 &p_camera_position, const bool p_bounds_ready, const Vector2 &p_focus, const float p_reach) {
	// Refine only visible page footprints. The refinement walk never enumerates a
	// virtual image's full mip pyramid (256 squared entries need zero resident
	// pages until requested). Budget exhaustion must remain visible in diagnostics.
	for (Sector &sector : r_hierarchy.working) {
		sector.size = _vt.surface_vt->has_sector(sector.owner) ? _vt.surface_vt->get_sector_block_size(sector.owner) : 0;
		const auto cached = _vt.avt_cached_addresses.find(avt_owner_key(sector.owner));
		if (cached != _vt.avt_cached_addresses.end()) {
			sector.logical_pages = cached->second.logical_pages;
			sector.resolution_level = cached->second.resolution_level;
		}
	}
	const float logical_ratio = _avt_logical_ratio();
	auto job = std::make_shared<Terrain3DAVTRefinement>();
	// The plan carries the key it was planned for, which is the key this tick
	// publishes at its end. The install step compares it against the member, so it
	// must be the new key and not the one being replaced.
	job->key = p_plan_key;
	job->submitted_us = Time::get_singleton()->get_ticks_usec();
	_vt.avt_refinement = job;
	// Keep producing the last completed view while its successor is being planned.
	// A virtual block can grow without changing a physical page's world footprint.
	// Addresses use full-resolution local blocks. Remove requests for downgraded cells;
	// the new dense image replaces the old plan atomically on layout changes.
	if (r_hierarchy.directory_dirty) {
		for (auto *pages : { &_vt.avt_plan.pages, &_vt.avt_plan.prefetch }) {
			pages->erase(std::remove_if(pages->begin(), pages->end(), [&](const Terrain3DAVTPageRequest &page) {
				return !_vt.surface_vt->has_sector(page.owner);
			}), pages->end());
		}
		_vt.avt_plan.forget_retention();
	}
	_vt.avt_prefetch_cursor = 0;
	_vt.avt_prefetch_cycle_pending = false;
	// The set the shortcut verified is about to be replaced by this plan's own selection.
	_vt.avt_settled.unverify();
	if (!_vt.vt_page_pipeline) { _vt.vt_page_pipeline = std::make_unique<Terrain3DPagePipeline>(_vt.vt_page_workers); }
	TerrainAVT::PlanInput input;
	input.working = r_hierarchy.working;
	input.source = _vt.vt_source_snapshot;
	input.view = p_view;
	input.bounds_ready = p_bounds_ready;
	input.camera_position = p_camera_position;
	input.priority_camera_position = get_camera()->get_camera_transform().origin;
	input.focus = p_focus;
	input.reach = p_reach;
	input.exact_radius = float(_cdlod_enabled && _tessellation_level == 0 ? _cdlod_patch_size * _vertex_spacing * _cdlod_lod_scale * 0.7 / (1 << _tessellation_level) : 0);
	input.logical_ratio = logical_ratio;
	input.texels_per_pixel = _vt.surface_vt_texels_per_pixel;
	input.budget = r_hierarchy.budget;
	// The plan's rate term: the pages it may name beyond the ones the image samples, which is the
	// pages one refresh window can produce at the allowance the tick actually hands this pass. Both
	// halves are live configuration - `vt_pages_per_update` with the far field's share rule, and the
	// refresh interval the motion lead derives - so the term tracks a camera that speeds up or a
	// project that raises the page budget, and it cannot drift from the supply: `_avt_tick_allowance()`
	// is the same call `terrain_3d.cpp` splits the tick with.
	input.tail_cap = _avt_tick_allowance() * int(_vt.avt_plan_refresh_frames);
	input.root_level = r_hierarchy.root_level;
	input.page_size = _vt.vt_page_size;
	input.coarse = _vt.avt_coarse;
	input.section_world = get_avt_local_section_world();
	input.mip_level_cap = MIN(get_avt_mip_level_cap(), TerrainVT::log2_power_of_two(get_avt_local_block_size()));
	_vt.vt_page_pipeline->submit_task([job, input]() mutable { TerrainAVT::plan_pages(*job, input); });
}

// The near field's half of `get_vt_settings()`: the motion lead, the standing plan's visible
// readings, the density and sector geometry the plan is derived from, and the two stage
// dictionaries. It is written here rather than in the report file because every key below reads a
// field this family owns.
void Terrain3D::_report_avt(Dictionary &r_result) const {
	Dictionary &result = r_result;
	result["motion_lead_ms"] = _vt.vt_motion_lead_ms;
	result["motion_lead_m"] = _vt.avt_motion_lead.length();
	result["motion_speed"] = _vt.avt_motion_velocity.length();
	result["motion_turn_deg_s"] = Math::rad_to_deg(_vt.avt_motion_turn.length());
	result["motion_turn_lead_deg"] = Math::rad_to_deg(_vt.avt_motion_turn_lead.length());
	result["visible_late_pages"] = _vt.avt_late_pages;
	result["visible_late_worst_ms"] = double(_vt.avt_late_worst_us) / 1000.0;
	result["visible_retained_pages"] = _vt.avt_retained_pages;
	result["adaptive"] = _vt.vt_adaptive_enabled;
	result["avt_feedback"] = _vt.avt_feedback;
	// Which page path the feedback switch answers an unserved cold page from, and whether that is
	// what the shader is currently reading.
	result["avt_feedback_source"] = _vt.avt_feedback_source;
	result["avt_cold_svt_source"] = _vt.avt_cold_svt_published;
	result["avt_texels_per_pixel"] = _vt.surface_vt_texels_per_pixel;
	// The near field's share of the tick's page budget as it stood for the last pass, beside
	// `pages_per_update` which is the whole of it. The two together are the supply the plan's rate
	// term is sized against, so a probe that reports `avt_tail_cap` without them cannot say what
	// the plan was measured against.
	result["avt_allowance"] = _avt_tick_allowance();
	// The cold-view burst: whether one is armed, what rate it asks for, and what it has done. The
	// steady allowance and the configured page budget are beside them, so a reading of "the burst
	// never armed" and "the burst armed and moved nothing" are told apart.
	result["avt_cold_burst_ticks"] = _vt.avt_cold_burst_ticks;
	result["avt_cold_burst_allowance"] = _avt_burst_allowance();
	result["avt_cold_burst_peak"] = _vt.avt_burst_peak;
	result["avt_cold_burst_pages"] = _vt.avt_burst_pages;
	result["avt_cold_burst_spent"] = _vt.avt_cold_burst_spent;
	result["avt_page_budget"] = _avt_page_budget();
	result["avt_page_budget_steady"] = _vt.vt_pages_per_update;
	result["avt_source_queue_limit"] = _vt.vt_page_pipeline ? _vt.vt_page_pipeline->get_queue_limit()
			: int(Terrain3DPagePipeline::QUEUE_CAPACITY);
	result["avt_resolution"] = get_surface_vt_resolution(); // Legacy API only.
	result["avt_distance"] = _vt.surface_vt_distance;
	result["avt_texels_per_meter"] = get_surface_vt_texels_per_meter();
	result["avt_virtual_resolution"] = 64.f * get_surface_vt_texels_per_meter();
	result["avt_base_block_size"] = get_avt_base_block_size();
	// Requested versus effective chain length and the budget-limited resolution.
	// The fallback grid's own mip boundary: its dense chain starts at its mip 1, and its mip 0
	// address space is what the block registration reserves. It is a property of the grid, and it
	// stays one by construction.
	result["avt_max_adaptive_level"] = 1;
	// The sample level at or above which that grid answers and the sector directory is not touched.
	// Derived from the two tiers' texel sizes, so it is the number the shader's read order and the
	// plan's classification share rather than a constant either of them could drift from.
	result["avt_adaptive_threshold_level"] = get_avt_adaptive_threshold_level();
	result["avt_local_block_size"] = get_avt_local_block_size();
	result["avt_effective_mip_levels"] = _vt.surface_vt_mip_levels;
	result["avt_local_mip_levels"] = get_avt_mip_level_cap() + 1;
	result["avt_sector_resolution_levels"] = _vt.surface_vt_mip_levels;
	result["avt_coarse_pages"] = int(_vt.avt_coarse.pages.size());
	result["avt_coarse_size"] = _vt.avt_coarse.size;
	result["avt_effective_texels_per_meter"] = _vt.surface_vt_texels_per_meter;
	result["avt_coarse_texels_per_meter"] = _vt.avt_coarse.size > 0 ? _vt.vt_page_size / _vt.avt_coarse.page_world : 0.f;
	result["avt_mip_levels"] = _vt.surface_vt_mip_levels;
	result["avt_mip_level_cap"] = get_avt_mip_level_cap();
	result["avt_sector_world"] = is_sector_avt() ? double(get_avt_local_section_world()) : double(_region_size * _vertex_spacing);
	result["avt_sector_stats"] = _vt.avt_sector_stats;
	result["avt_peak_stats"] = _vt.avt_peak_stats;
	result["avt_peak_age_ms"] = _vt.avt_peak_stamp_us == 0 ? -1.0
			: double(Time::get_singleton()->get_ticks_usec() - _vt.avt_peak_stamp_us) / 1000.0;
	result["avt_selection_mode"] = _vt.surface_vt_selection_mode;
	result["avt_region_grid"] = _vt.surface_vt_region_grid;
	result["avt_region_offset"] = _vt.surface_vt_region_offset;
	result["avt_forward_regions"] = _vt.surface_vt_forward_regions;
	result["avt_region_rect"] = get_surface_vt_region_rect();
}
