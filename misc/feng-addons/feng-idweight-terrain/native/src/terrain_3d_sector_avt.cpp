// World-aligned procedural AVT. Geometry regions are deliberately not sectors.
//
// This file owns the demand side of the near field: motion prediction, the plan key that decides
// when a selection is re-derived, the planning chain that derives it, the sector hierarchy, the
// address directory, and the install-or-reuse decision on a finished plan. The other two halves of
// the near field are their own files, because each runs in a different place: the selection runs on
// a worker (terrain_3d_avt_plan.cpp, behind the hand-off declared in terrain_3d_avt_plan.h), and the
// per-tick production pass runs on the main thread under the frame budget
// (terrain_3d_avt_produce.cpp). All three work on the records declared in terrain_3d_avt.h.
#include "terrain_3d.h"
#include "terrain_3d_avt_plan.h"
#include "terrain_3d_surface_baker.h"
#include "terrain_3d_vt_visibility.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <queue>
#include <tuple>
#include <unordered_set>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/time.hpp>

namespace {
// Local short names for the two world model constants the AVT files share; the values and the
// reasoning behind them are in terrain_3d_avt.h. They are used a few dozen times in this file, and
// the qualified spelling would bury the arithmetic that reads them.
constexpr float SECTOR_WORLD = AVT_SECTOR_WORLD;
// Demand leads footprint changes so asynchronous production completes before
// a normal mip transition. This does not alter the shader's mip selection.
constexpr float DEMAND_DENSITY_MARGIN = AVT_DEMAND_DENSITY_MARGIN;
// Motion look-ahead shaping. The velocity is smoothed because a single frame of
// jitter must not aim the plan; both rates are clamped because a teleport or a snap
// turn is not a prediction the page pipeline can serve.
constexpr float MOTION_SMOOTHING = 0.25f;
constexpr float MOTION_MAX_SPEED = 400.f;
constexpr float MOTION_LEAD_REACH_FRACTION = 0.5f;
// How fast the lead itself may move, in metres per second of lead change. The lead is a
// position derived from a velocity estimate, and a frame time that varies makes that
// estimate vary: without a slew limit a noisy frame time swings the plan by metres, which
// re-selects the whole working set and throws away the source jobs in flight for it.
constexpr float MOTION_LEAD_SLEW_RATE = 40.f;
// Two ticks closer together than this carry no new motion information: a displacement over
// almost no elapsed time is a velocity spike, and the demand plans with its result.
constexpr uint64_t MOTION_MIN_INTERVAL_US = 1000;
// The predicted transform is snapped to this grid (metres, and radians for yaw) so the
// plan key is stable while the camera moves inside one cell. A plan key that changes every
// frame re-derives the whole working set every frame: every page address is re-selected,
// every source job in flight for the previous selection is thrown away, and the worker
// time spent on it is wasted three times over.
constexpr float MOTION_PLAN_QUANTUM = 4.f;
// The eye height is quantized less coarsely: it is what the near field's screen density is
// measured from, and it follows the terrain continuously while the camera moves. A metre of
// error would move a mip boundary; the height is snapped only far enough to stop the plan
// key from changing on every frame of a smooth slope.
constexpr float MOTION_HEIGHT_QUANTUM = 2.f;
// The orientation is snapped for exactly the reason the position is, and it is the one that
// matters for a camera that turns: an exact basis changes the key on every frame of a pan,
// so every tick submits a plan and the next tick replaces it before the worker has finished
// - which throws the worker's time away, keeps the working set churning instead of
// converging, and is what makes a turn refine in visible blocks. Two degrees of yaw is
// under a third of a frame at a fast 6 degrees per frame, and the pages are still selected
// from the exact predicted transform: the key only decides when a selection is re-derived.
constexpr float MOTION_YAW_QUANTUM = 0.034906585f; // 2 degrees
constexpr float MOTION_PITCH_QUANTUM = 0.026179939f; // 1.5 degrees
constexpr float MOTION_ROLL_QUANTUM = 0.052359878f; // 3 degrees
using SectorKey = std::pair<int, int>;
// The demand cell's short name. The worker file spells the same alias for its own half; the record
// itself is `Terrain3DAVTSector` in terrain_3d_avt.h.
using Sector = Terrain3DAVTSector;
uint32_t sector_hash(int x, int y, int level) {
	return uint32_t(x) * 73856093u ^ uint32_t(y) * 19349663u ^ uint32_t(level) * 83492791u;
}
int floor_div(int value, int scale) { return int(std::floor(double(value) / scale)); }
// Owner keys are the 64-bit (x, y) pair the address directory and the page
// requests are both indexed by.
uint64_t avt_owner_key(const Vector2i &owner) { return (uint64_t(uint32_t(owner.x)) << 32) | uint32_t(owner.y); }
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
// The number of texels a level 0 sector block carries per page, as a multiple of its page
// count: `size * logical_ratio` is the block's virtual resolution for `SECTOR_WORLD`
// metres. Derived here rather than read from the plan, because the chain that re-configures a
// view publishes its directory before it submits the plan: the first publish of a configuration
// would otherwise read the previous configuration's ratio.
float Terrain3D::_avt_logical_ratio() const {
	return SECTOR_WORLD * _vt.surface_vt_texels_per_meter / (_vt.vt_page_size * get_avt_base_block_size());
}
// Motion look-ahead. A page costs several frames to assemble and a compressed page
// several more to encode and read back, so demand issued at the moment a page becomes
// visible can only ever be late: the view streams in. The plan therefore describes the
// camera's position one lead ahead, which turns the production latency into latency that
// the camera has not reached yet. The velocity is exponentially smoothed, so a stop
// decays the lead instead of leaving the plan aimed at a position the camera left, and
// an edit or a teleport is bounded by the clamps below.
void Terrain3D::_vt_update_motion_lead() {
	Camera3D *camera = get_camera();
	if (!camera || !camera->is_inside_tree() || _vt.vt_motion_lead_ms <= 0.f) {
		_vt.avt_motion_lead = Vector2();
		_vt.avt_motion_valid = false;
		_vt.avt_motion_velocity = Vector2();
		_vt.avt_retain_epochs = 8;
		_vt.avt_plan_refresh_frames = 1;
		return;
	}
	const Transform3D transform = camera->get_camera_transform();
	const Vector2 focus(transform.origin.x, transform.origin.z);
	const uint64_t now = Time::get_singleton()->get_ticks_usec();
	if (_vt.avt_motion_valid && now <= _vt.avt_motion_stamp_us + MOTION_MIN_INTERVAL_US) {
		return;
	}
	float delta = 0.f;
	if (_vt.avt_motion_valid && now > _vt.avt_motion_stamp_us) {
		delta = float(double(now - _vt.avt_motion_stamp_us) / 1000000.0);
		if (delta > 0.0005f) {
			Vector2 velocity = (focus - _vt.avt_motion_last_focus) / delta;
			if (velocity.length() > MOTION_MAX_SPEED) { velocity = velocity.normalized() * MOTION_MAX_SPEED; }
			_vt.avt_motion_velocity = _vt.avt_motion_velocity.lerp(velocity, MOTION_SMOOTHING);
		}
	}
	_vt.avt_motion_last_focus = focus;
	_vt.avt_motion_stamp_us = now;
	_vt.avt_motion_valid = true;
	const float lead_seconds = float(_vt.vt_motion_lead_ms) / 1000.f;
	// A plan pointing further than half the near field's reach would spend production on
	// terrain the camera may never approach, so the lead is clamped by the reach.
	const float max_lead = MAX(64.f, float(_vt.surface_vt_distance)) * MOTION_LEAD_REACH_FRACTION;
	Vector2 target = _vt.avt_motion_velocity * lead_seconds;
	if (target.length() > max_lead) { target = target.normalized() * max_lead; }
	// Slew limit: a real acceleration is followed within a few frames, a noisy frame time
	// is not followed at all.
	const float max_step = MOTION_LEAD_SLEW_RATE * MAX(delta, 0.001f);
	const Vector2 change = target - _vt.avt_motion_lead;
	_vt.avt_motion_lead = change.length() > max_step ? _vt.avt_motion_lead + change.normalized() * max_step : target;
	// Retention is measured in plan epochs, which are one install apart. The window is at least
	// one lead wide: the plan describes the view *ahead* of the camera, so the view being
	// rendered is covered by requests retained from the plans that preceded it.
	_vt.avt_retain_epochs = CLAMP(int(float(_vt.vt_motion_lead_ms) / 16.7f) + 8, 8, 96);
	// How often the plan is re-derived against the camera. A plan is a look-ahead artifact: it
	// names the pages the view will need a lead from now, and it is refreshed at half that lead,
	// so the page set it describes is never older than the interval and never less ahead than the
	// other half. Re-deriving it on every frame buys nothing - a page produced now is not needed
	// for a lead - and costs the whole planning chain, which is the visible scan, the sector
	// hierarchy, the address directory and the worker hand-off: measured at 0.19 ms, close to two
	// phase budgets on its own, on every frame of a turn. Derived from the lead rather than set
	// separately, so there is one number for how far ahead the plan looks.
	_vt.avt_plan_refresh_frames = uint64_t(CLAMP(int(float(_vt.vt_motion_lead_ms) / 16.7f) / 2, 2, 8));
}

Transform3D Terrain3D::_vt_lead_camera_transform(const Transform3D &p_camera_transform) const {
	if (_vt.avt_motion_lead == Vector2()) {
		return p_camera_transform;
	}
	Transform3D lead = p_camera_transform;
	lead.origin += Vector3(_vt.avt_motion_lead.x, 0.f, _vt.avt_motion_lead.y);
	return lead;
}

// The transform the plan key is derived from: the predicted transform snapped to a grid, so the
// key is unchanged while the camera moves inside one cell. A key that changes every frame
// re-plans the whole working set every frame, and every source job already in flight for the
// previous selection is thrown away with it. The demand itself still uses the exact predicted
// transform - snapping the geometry pages are selected from would move the mip boundaries the
// shader selects against, trading a key-identity problem for a paint one.
Transform3D Terrain3D::_vt_plan_key_transform(const Transform3D &p_camera_transform) const {
	Transform3D keyed = _vt_lead_camera_transform(p_camera_transform);
	keyed.origin.x = Math::round(keyed.origin.x / MOTION_PLAN_QUANTUM) * MOTION_PLAN_QUANTUM;
	keyed.origin.z = Math::round(keyed.origin.z / MOTION_PLAN_QUANTUM) * MOTION_PLAN_QUANTUM;
	keyed.origin.y = Math::round(keyed.origin.y / MOTION_HEIGHT_QUANTUM) * MOTION_HEIGHT_QUANTUM;
	// The orientation is snapped on the same grid idea. Yaw gets the finest step because it
	// is what a camera turn changes; pitch and roll get coarser ones, since a degree of
	// either moves the plan's frustum far less than a degree of yaw.
	const Vector3 euler = keyed.basis.get_euler();
	keyed.basis = Basis::from_euler(Vector3(
			Math::round(euler.x / MOTION_PITCH_QUANTUM) * MOTION_PITCH_QUANTUM,
			Math::round(euler.y / MOTION_YAW_QUANTUM) * MOTION_YAW_QUANTUM,
			Math::round(euler.z / MOTION_ROLL_QUANTUM) * MOTION_ROLL_QUANTUM));
	return keyed;
}

void Terrain3D::set_surface_vt_mip_distances(const PackedFloat32Array &p_distances) {
	PackedFloat32Array normalized;
	for (int i = 0; i < MIN(16, int(p_distances.size())); ++i) {
		const float previous = i ? normalized[i - 1] : 0.f;
		normalized.push_back(std::isfinite(p_distances[i]) ? MAX(previous + 0.01f, p_distances[i]) : previous + 1.f);
	}
	_vt.surface_vt_mip_distances = normalized;
	if (_initialized && _material.is_valid()) { _material->update(Terrain3DMaterial::UNIFORMS_ONLY); }
}
int Terrain3D::get_surface_vt_mip_for_distance(real_t p_distance) const {
	const int top = TerrainVT::log2_power_of_two(is_sector_avt() ? get_avt_base_block_size() : _vt.surface_vt_pages_per_axis);
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
	// Demand is planned for the predicted camera, which is where the view will be when
	// the pages being produced now are needed. The transform is the only difference: the
	// shader still selects mips from the real frustum.
	const Transform3D camera_transform = get_camera()->get_camera_transform();
	const Transform3D lead_transform = _vt_lead_camera_transform(camera_transform);
	const Vector3 camera_position = lead_transform.origin;
	const Vector2 focus(camera_position.x, camera_position.z);
	const float reach = MAX(64.f, float(_vt.surface_vt_distance));
	// Published before the plan is installed or reused, so the readings describe this tick
	// and not the last one that ran the whole planning chain.
	_vt.avt_sector_stats["motion_lead_m"] = _vt.avt_motion_lead.length();
	_vt.avt_sector_stats["motion_speed"] = _vt.avt_motion_velocity.length();
	_vt.avt_sector_stats["plan_origin"] = Vector2(lead_transform.origin.x, lead_transform.origin.z);
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
		if (is_valid_avt_plan_key(_vt.avt_plan_key)) {
			for (size_t i = 0; i < plan_key.size(); ++i) {
				if (plan_key[i] != _vt.avt_plan_key[i]) { first = int(i); break; }
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
	// `avt_plan_key` is deliberately left at the key the standing plan was planned for, so the
	// tick after the interval sees the change and plans.
	//
	// A key that was *invalidated* is not camera motion and does not wait: a region was added or
	// removed, a slot was swapped, the material or the pool was rebuilt, and the standing plan
	// describes a world that no longer exists. Only a key that changed because the view moved is
	// held for the interval, which is the whole of what the interval is for. Measured: without
	// this distinction a region whose slot had just been swapped rendered the missing-page
	// diagnostic until the interval expired.
	const uint64_t frame_now = Engine::get_singleton()->get_process_frames();
	const bool key_same = _vt.avt_plan_key == plan_key;
	const bool key_valid = is_valid_avt_plan_key(_vt.avt_plan_key);
	const bool refresh_due = !key_valid || _vt.avt_last_chain_frame == UINT64_MAX ||
			frame_now >= _vt.avt_last_chain_frame + _vt.avt_plan_refresh_frames;
	if (!key_same && !refresh_due) { _vt.avt_plan_refresh_skips++; }
	const int finished = _avt_install_or_reuse_plan(started, p_max_pages, key_same || !refresh_due);
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
	_vt.avt_sector_stats["coverage_radius"] = _vt.surface_svt_enabled ? reach : -1.f;
	// Phase timings for the uncached path, which is the one a moving camera takes on
	// every tick: the visible scan, the sector hierarchy, the address directory, the
	// hand-off to the refinement worker, the directory upload and the page production.
	// The predicted frustum, not the rendered one. `camera_transform` is the real one the
	// engine is using; only the plan moves ahead of it.
	TerrainVT::VisibleView view(lead_transform, get_camera()->get_camera_projection(),
			get_camera()->get_viewport() ? get_camera()->get_viewport()->get_visible_rect().size.y : 720.f,
			get_camera()->get_projection() == Camera3D::PROJECTION_ORTHOGONAL, 192.f);
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
	_vt.avt_pending_scan = _avt_scan_sectors(view, camera_position, bounds_ready, focus, reach);
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
	_vt.avt_plan_key = plan_key;
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

// Publishes the address directory of a finished hierarchy. The material is republished
// only when a uniform it reads changed: the directory texture is updated in place, so its
// new content is already visible to the shader, and republishing every uniform costs more
// than the whole tick budget.
void Terrain3D::_publish_avt_directory(const Terrain3DAVTHierarchy &p_hierarchy) {
	_vt.avt_sector_stats["directory_rebuilt"] = p_hierarchy.directory_dirty || p_hierarchy.root_level != _vt.avt_root_level;
	const bool rebind = _avt_publish_directory(p_hierarchy, p_hierarchy.directory_dirty);
	_vt.avt_sector_stats["visible_sectors"] = int(std::count_if(p_hierarchy.leaves.begin(), p_hierarchy.leaves.end(), [](const Sector &sector) { return sector.produce; }));
	_vt.avt_sector_stats["coarse_pages"] = p_hierarchy.coarse_roots;
	_vt.avt_sector_stats["coarse_world_size"] = SECTOR_WORLD * float(1 << p_hierarchy.root_level);
	_vt.avt_sector_stats["material_ms"] = 0.0;
	if (rebind && _material.is_valid()) {
		const uint64_t material_start = Time::get_singleton()->get_ticks_usec();
		_material->update(Terrain3DMaterial::REGION_ARRAYS);
		_vt.avt_sector_stats["material_ms"] = double(Time::get_singleton()->get_ticks_usec() - material_start) / 1000.0;
	}
}

// Fixed camera/configuration key: no per-frame Variant arrays or region scan.
// All source edits invalidate this key together with the source snapshot.
Terrain3DAVTPlanKey Terrain3D::_avt_plan_state(const bool p_bounds_ready) const {
	const Camera3D *camera = get_camera();
	// Filled in place and returned by value: this runs on every tick of a moving view, and the
	// byte array it used to be built into was a 512 byte allocation and a copy per tick.
	Terrain3DAVTPlanKey state = {};
	int component = 0;
	auto append = [&](double value) { state[component++] = value; };
	// The key describes what the plan is a function of, which is the predicted transform the
	// page set was derived from - not the rendered one, or a moving camera would re-plan every
	// frame while the predicted view had not changed at all.
	const Transform3D transform = _vt_plan_key_transform(camera->get_camera_transform());
	for (int row = 0; row < 3; ++row) for (int col = 0; col < 3; ++col) { append(transform.basis[row][col]); }
	for (int axis = 0; axis < 3; ++axis) { append(transform.origin[axis]); }
	const Projection projection = camera->get_camera_projection();
	for (int col = 0; col < 4; ++col) for (int row = 0; row < 4; ++row) { append(projection[col][row]); }
	const Rect2 viewport = camera->get_viewport()->get_visible_rect();
	append(viewport.position.x); append(viewport.position.y); append(viewport.size.x); append(viewport.size.y);
	append(p_bounds_ready); append(_region_size); append(_vertex_spacing);
	append(_vt.surface_vt_texels_per_meter); append(_vt.surface_vt_texels_per_pixel); append(_vt.vt_adaptive_enabled);
	// The far field's visible count is what reserves part of the pool, but it moves by a page
	// or two on every frame of a moving view. Bucketing it keeps the near field's plan
	// installable while its own footprint is unchanged; an exact count in the key re-planned
	// the whole working set whenever the far field gained or lost a single page.
	append((_vt.vt_svt_visible_pages / 16) * 16); append(_vt.surface_svt_enabled); append(_vt.surface_vt_distance);
	append(!_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty());
	append(_vt.vt_page_count); append(_vt.vt_page_size);
	return state;
}

// Only planning is cached. Page requests still touch residency and repair
// invalidated/evicted pages on every demand epoch, within the normal budget.
int Terrain3D::_avt_install_or_reuse_plan(const uint64_t p_started, const int p_max_pages, const bool p_same_plan) {
	bool installed = false;
	if (_vt.avt_refinement && _vt.avt_refinement->ready.load(std::memory_order_acquire)) {
		if (_vt.avt_refinement->key == _vt.avt_plan_key) {
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
			// The window is at least one lead wide: a page the plan moved ahead of is still
			// in the image being rendered, and dropping its request would let the pool evict
			// it out from under the view that has not caught up yet. The count is capped so a
			// look-ahead plan cannot reserve the whole pool with pages the camera has left -
			// and capped again by the room the completed plan left in its budget, so what this
			// installs is never larger than the residency it is served from. The planner
			// reserves that room; this is the same invariant, held where the append happens.
			const int retain_cap = MIN(128, MAX(0, _vt.avt_refinement->budget - int(_vt.avt_refinement->pages.size())));
			int retained = 0;
			for (const Terrain3DAVTPageRequest &page : _vt.avt_page_plan) {
				if (retained == retain_cap) { break; }
				if (page.last_visible_plan + uint64_t(_vt.avt_retain_epochs) < epoch ||
						std::binary_search(current.begin(), current.end(),
								std::array<int, 5>{ page.owner.x, page.owner.y, page.mip, page.x, page.y })) {
					continue;
				}
				_vt.avt_refinement->pages.push_back(page);
				++retained;
			}
			_vt.avt_retained_pages = retained;
			_vt.avt_sector_stats["retained_requests"] = retained;
			_vt.avt_sector_stats["retain_epochs"] = _vt.avt_retain_epochs;
			_vt.avt_page_plan = std::move(_vt.avt_refinement->pages);
			_vt.avt_sampled_pages = _vt.avt_refinement->sampled;
			_vt.avt_prefetch_plan = std::move(_vt.avt_refinement->warm);
			_vt.avt_prefetch_cursor = 0;
			_vt.avt_prefetch_cycle_pending = false;
			// A new plan is a new wanted set, so the source queue has to be retained again.
			_vt.avt_retain_applied = false;
			_vt.avt_sector_stats["refinement_requests_denied"] = _vt.avt_refinement->denied;
			_vt.avt_sector_stats["finest_requested_texel_world"] = _vt.avt_refinement->finest;
			_vt.avt_sector_stats["visible_root_pages"] = _vt.avt_refinement->roots;
			_vt.avt_sector_stats["requested_physical_pages"] = int(_vt.avt_page_plan.size());
			_vt.avt_sector_stats["prefetch_requests"] = int(_vt.avt_prefetch_plan.size());
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
		_vt.avt_plan_reused = !installed;
		_vt.avt_sector_stats["plan_reused"] = _vt.avt_plan_reused;
		_vt.avt_sector_stats["directory_rebuilt"] = false;
		const int produced = _produce_sector_avt_pages(p_max_pages);
		_vt.avt_sector_stats["cpu_update_ms"] = double(Time::get_singleton()->get_ticks_usec() - p_started) / 1000.0;
		return produced;
	}
	// A plan that is not being reused leaves the settled verdict false: the caller goes on to run
	// this tick's production pass, and it must not read the absence of an install as an idle plan
	// and skip the work the new view needs.
	_vt.avt_plan_reused = false;
	return -1;
}

// Enumerates the resident regions into 64 m demand cells, each sized to the mip
// its on-screen footprint needs.
Terrain3DAVTSectorScan Terrain3D::_avt_scan_sectors(const TerrainVT::VisibleView &p_view,
		const Vector3 &p_camera_position, const bool p_bounds_ready,
		const Vector2 &p_focus, const float p_reach) const {
	Terrain3DAVTSectorScan scan;
	// The conservative reach test, and the sample a cell gets from it. The plan worker applies the
	// same two steps in terrain_3d_avt_plan.cpp (`surrounding_sample`), and the two have to agree:
	// this one decides which cells exist at all, that one decides which of their pages are in reach,
	// so any difference between them is a page the plan asks for that no scan ever enumerated. They
	// are the same arithmetic because the camera position and the focus passed here are the same
	// point in XZ - the lead camera's - and they have to stay the same point for that to hold.
	auto in_reach = [&](const Rect2 &rect) {
		const Vector2 nearest(CLAMP(p_focus.x, rect.position.x, rect.get_end().x), CLAMP(p_focus.y, rect.position.y, rect.get_end().y));
		return nearest.distance_squared_to(p_focus) <= (p_reach + SECTOR_WORLD) * (p_reach + SECTOR_WORLD);
	};
	auto surrounding_sample = [&](const Rect2 &rect, const Vector2 &heights, TerrainVT::VisiblePatch &patch) {
		if (!in_reach(rect)) { return false; }
		patch.nearest = Vector3(CLAMP(p_camera_position.x, rect.position.x, rect.get_end().x),
				CLAMP(p_camera_position.y, heights.x, heights.y), CLAMP(p_camera_position.z, rect.position.y, rect.get_end().y));
		patch.distance = patch.nearest.distance_to(p_camera_position);
		// Conservative demand for a future camera yaw. This only spends idle/free
		// capacity and never changes the visible view's resolution or page budget.
		patch.density = p_view.orthographic ? p_view.focal : p_view.focal * 2.f / MAX(0.01f, patch.distance);
		return true;
	};
	scan.visible.reserve(_data->get_region_locations().size() * 64);
	std::map<SectorKey, size_t> overlapping;

	const float region_world = _region_size * _vertex_spacing;
	const bool aligned_regions = region_world >= SECTOR_WORLD && Math::is_equal_approx(region_world / SECTOR_WORLD, Math::round(region_world / SECTOR_WORLD));
	for (const Vector2i &location : _data->get_region_locations()) {
		Ref<Terrain3DRegion> region = _data->get_region(location);
		if (region.is_null() || region->is_deleted()) { continue; }
		Rect2 rect(Vector2(location) * region_world, Vector2(region_world, region_world));
		if (_vt.surface_svt_enabled && !in_reach(rect)) { continue; }
		int x0 = int(std::floor(rect.position.x / SECTOR_WORLD));
		int y0 = int(std::floor(rect.position.y / SECTOR_WORLD));
		int x1 = int(std::ceil(rect.get_end().x / SECTOR_WORLD)) - 1;
		int y1 = int(std::ceil(rect.get_end().y / SECTOR_WORLD)) - 1;
		if (!scan.has_world) { scan.world_x0 = x0; scan.world_y0 = y0; scan.world_x1 = x1; scan.world_y1 = y1; scan.has_world = true; }
		scan.world_x0 = MIN(scan.world_x0, x0); scan.world_y0 = MIN(scan.world_y0, y0);
		scan.world_x1 = MAX(scan.world_x1, x1); scan.world_y1 = MAX(scan.world_y1, y1);
		TerrainVT::VisiblePatch patch;
		if (!p_view.sample(rect, region->get_height_range(), patch) && !in_reach(rect)) { continue; }
		for (int y = y0; y <= y1; ++y) {
			for (int x = x0; x <= x1; ++x) {
				Rect2 sector_rect(Vector2(x, y) * SECTOR_WORLD, Vector2(SECTOR_WORLD, SECTOR_WORLD));
				if (_vt.surface_svt_enabled && !in_reach(sector_rect)) { continue; }
				// Clip against actual resident data, including regions smaller than a
				// sector and non-unit vertex spacing. Deduplicate overlapping regions.
				const Vector2 sector_heights = p_bounds_ready ? _vt.vt_source_snapshot->bounds(sector_rect.intersection(rect), region->get_height_range()) : region->get_height_range();
				const bool on_screen = p_view.sample(sector_rect.intersection(rect), sector_heights, patch);
				if (!on_screen && !surrounding_sample(sector_rect.intersection(rect), sector_heights, patch)) { continue; }
				const int base = get_avt_base_block_size();
				// Screen density predicts the derivative-selected mip used by the shader.
				const float required_density = MAX(0.001f, patch.density * _vt.surface_vt_texels_per_pixel * DEMAND_DENSITY_MARGIN);
				const int screen_mip = MAX(0, int(std::floor(std::log2(MAX(1.f, float(_vt.surface_vt_texels_per_meter) / required_density)))));
				int wanted = MAX(1, base >> MIN(15, screen_mip));
				if (!_vt.vt_adaptive_enabled) { wanted = base; }
				wanted = MIN(2048, wanted);
				Vector2i key(x, y);
				Sector sector = { key, key, 0, wanted, 1, on_screen, patch.distance, sector_heights };
				if (aligned_regions) { scan.visible.push_back(sector); }
				else {
					auto found = overlapping.find({ x, y });
					if (found == overlapping.end()) { overlapping[{ x, y }] = scan.visible.size(); scan.visible.push_back(sector); }
					else {
						Sector &previous = scan.visible[found->second];
						previous.produce |= on_screen; previous.wanted = MAX(previous.wanted, wanted); previous.distance = MIN(previous.distance, patch.distance);
						previous.heights.x = MIN(previous.heights.x, sector.heights.x); previous.heights.y = MAX(previous.heights.y, sector.heights.y);
					}
				}
			}
		}
	}
	return scan;
}

// Turns the scan into the working set: the 64 m cells sorted near to far, the
// hierarchy of coarse nodes above them, and the address budget they have to fit.
Terrain3DAVTHierarchy Terrain3D::_avt_build_hierarchy(const Terrain3DAVTSectorScan &p_scan) {
	Terrain3DAVTHierarchy hierarchy;
	hierarchy.directory_dirty = _vt.avt_directory_bytes.is_empty();
	// The world hierarchy supplies the footprint-selected coarse mips. Its
	// addresses remain stable during local refinement; residency is determined
	// below by the actual visible mip range, not by reserving every ancestor.
	const int pool_size = _vt.surface_vt->get_page_count();
	const bool offline_bake = !_vt.vt_svt_bake_queue.is_empty() || !_vt.vt_svt_bake_waiting.is_empty();
	// How much of the pool the near field's plan may name. `reserved` is what the plan may not
	// reach: at least what the far field needs, and at least a quarter of the pool.
	//
	// The quarter is the headroom the plan cannot do without. Production is asynchronous - a page
	// is allocated, assembled by a worker over several frames, and written when it arrives - so a
	// plan that reaches the pool's last slot makes every production evict the page it is about to
	// replace. Measured with the plan allowed to fill the pool: the planning chain ran five times
	// as often, the phase mean went from 0.13 to 0.7-1.0 ms, and the view still never converged.
	// The far field's own share is the other half of the same number, so the larger of the two is
	// what is held back.
	const int reserved = offline_bake ? pool_size / 2
			: (_vt.surface_svt_enabled ? MAX(pool_size / 4, MIN(pool_size / 2, _vt.vt_svt_visible_pages)) : 0);
	const int budget = MAX(4, pool_size - reserved);
	const int root_budget = MAX(4, budget / 4);
	int root_level = 1;
	while (root_level < 24) {
		int scale = 1 << root_level;
		int64_t count = int64_t(floor_div(p_scan.world_x1, scale) - floor_div(p_scan.world_x0, scale) + 1) *
				(floor_div(p_scan.world_y1, scale) - floor_div(p_scan.world_y0, scale) + 1);
		if (count <= root_budget) { break; }
		++root_level;
	}
	// More physical capacity must not remove the old coarsest virtual level.
	// That would change the shader's terminal mip and orphan ready root pages.
	root_level = MAX(root_level, _vt.avt_root_level);
	// The root level set is a flat vector searched in place rather than a `std::map`: it is a few
	// dozen entries, and a node-based container pays an allocation and a tree walk per insert for a
	// lookup a linear scan of that size beats. The same reasoning the page pipeline's queue records.
	std::vector<Sector> roots;
	for (const Sector &item : p_scan.visible) {
		hierarchy.leaves.push_back(item);
		int x = floor_div(item.location.x, 1 << root_level);
		int y = floor_div(item.location.y, 1 << root_level);
		// Reserved CPU owner namespace; the GPU hashes the unmodified world key.
		Vector2i owner(x, y + 0x40000000 + root_level * 0x100000);
		bool known = false;
		for (const Sector &root : roots) {
			if (root.location.x == x && root.location.y == y) { known = true; break; }
		}
		if (!known) { roots.push_back({ Vector2i(x, y), owner, root_level, 1, 1, true, 0.f }); }
	}
	std::vector<Sector> &sectors = hierarchy.leaves;
	std::sort(sectors.begin(), sectors.end(), [](const Sector &a, const Sector &b) {
		if (a.distance != b.distance) { return a.distance < b.distance; }
		return a.location.y == b.location.y ? a.location.x < b.location.x : a.location.y < b.location.y;
	});
	// Address-space budgeting is independent of physical residency. Leave atlas
	// headroom for coarse roots and for buddy allocator fragmentation.
	const int64_t virtual_budget = int64_t(2048) * 2048 * 3 / 4 - roots.size() - sectors.size();
	int virtual_bias = 0;
	for (;;) {
		int64_t area = 0;
		for (const Sector &sector : sectors) { if (!sector.produce) { continue; } int size = MAX(1, sector.wanted >> virtual_bias); area += int64_t(size) * size; }
		if (area <= virtual_budget || virtual_bias >= 11) { break; }
		++virtual_bias;
	}
	for (Sector &sector : sectors) { sector.size = MAX(1, sector.wanted >> virtual_bias); }
	// Keep a world hierarchy between the coarse roots and the 64 m sectors.
	// This prevents a sector without fine pages from jumping straight to a huge root.
	std::vector<Sector> coarse;
	// Takes the sector by value: it appends to `coarse` while the caller may be holding a
	// reference into it.
	auto add_parent = [&coarse](const Sector p_sector) {
		const int level = p_sector.level + 1;
		Vector2i key(floor_div(p_sector.location.x, 2), floor_div(p_sector.location.y, 2));
		for (Sector &node : coarse) {
			if (node.level != level || node.location.x != key.x || node.location.y != key.y) { continue; }
			node.produce |= p_sector.produce;
			node.heights.x = MIN(node.heights.x, p_sector.heights.x);
			node.heights.y = MAX(node.heights.y, p_sector.heights.y);
			return;
		}
		coarse.push_back({ key, Vector2i(key.x, key.y + 0x40000000 + level * 0x100000), level, 1, 1, p_sector.produce, p_sector.distance, p_sector.heights });
	};
	for (const Sector &sector : sectors) { add_parent(sector); }
	// Build each parent once from the previous level, rather than revisiting
	// the entire ancestor chain for every leaf in a large visible world. The entries of the level
	// being read are the ones already there, so the loop reads through a snapshot of the size:
	// everything `add_parent` appends belongs to the next level.
	for (int level = 1; level < root_level; ++level) {
		const size_t end = coarse.size();
		for (size_t i = 0; i < end; ++i) {
			if (coarse[i].level == level) { add_parent(coarse[i]); }
		}
	}
	// Ordered as the keyed set it replaces was, so the working set keeps the order it had: the
	// level first, then x, then y, read backwards.
	std::sort(coarse.begin(), coarse.end(), [](const Sector &a, const Sector &b) {
		if (a.level != b.level) { return a.level < b.level; }
		return a.location.x == b.location.x ? a.location.y < b.location.y : a.location.x < b.location.x;
	});
	for (auto item = coarse.rbegin(); item != coarse.rend(); ++item) { hierarchy.working.push_back(*item); }
	_vt.avt_sector_stats["virtual_budget_bias"] = virtual_bias;
	// The three numbers the plan is a function of, published together: the plan is bounded by the
	// budget, the budget by the pool, and a plan at the pool's size is the state that cannot
	// converge. Reading them from one report is what tells the two apart.
	_vt.avt_sector_stats["pool_pages"] = pool_size;
	_vt.avt_sector_stats["plan_budget"] = budget;
	hierarchy.working.insert(hierarchy.working.end(), sectors.begin(), sectors.end());
	std::stable_sort(hierarchy.working.begin(), hierarchy.working.end(), [](const Sector &a, const Sector &b) { return a.produce > b.produce; });
	hierarchy.owners.reserve(hierarchy.working.size());
	for (const Sector &sector : hierarchy.working) { if (sector.produce) { hierarchy.owners.insert(avt_owner_key(sector.owner)); } }
	hierarchy.root_level = root_level;
	hierarchy.coarse_roots = int(roots.size());
	hierarchy.budget = budget;
	return hierarchy;
}

// Keeps the virtual block directory in step with the working set: releases the
// addresses of views the camera has left, allocates or resizes the rest, and
// reclaims address space when a visible block cannot be allocated otherwise.
void Terrain3D::_avt_sync_address_directory(Terrain3DAVTHierarchy &r_hierarchy, const Vector2 &p_focus, const float p_reach) {
	auto in_reach = [&](const Rect2 &rect) {
		const Vector2 nearest(CLAMP(p_focus.x, rect.position.x, rect.get_end().x), CLAMP(p_focus.y, rect.position.y, rect.get_end().y));
		return nearest.distance_squared_to(p_focus) <= (p_reach + SECTOR_WORLD) * (p_reach + SECTOR_WORLD);
	};
	bool &directory_dirty = r_hierarchy.directory_dirty;
	auto release_address = [&](const Terrain3DAVTCachedAddress &address) {
		_vt.surface_vt->unregister_sector(address.owner);
		_vt.vt_registered_sectors.erase(address.owner);
		_vt.avt_allocated_sizes.erase(avt_owner_key(address.owner));
		directory_dirty = true;
	};
	// Looking away does not invalidate material content. Keep addresses and cached
	// pages near the camera; physical pages remain evictable under actual demand.
	for (auto item = _vt.avt_cached_addresses.begin(); item != _vt.avt_cached_addresses.end();) {
		const Terrain3DAVTCachedAddress &address = item->second;
		const float span = SECTOR_WORLD * float(1 << address.level);
		Rect2 rect(Vector2(address.location) * span, Vector2(span, span));
		if (!r_hierarchy.owners.count(item->first) && _vt.surface_svt_enabled && !in_reach(rect)) {
			release_address(address);
			item = _vt.avt_cached_addresses.erase(item);
		} else { ++item; }
	}
	auto reclaim_addresses = [&]() {
		// Visible demand wins. Old views never force a lower virtual resolution.
		for (auto item = _vt.avt_cached_addresses.begin(); item != _vt.avt_cached_addresses.end();) {
			if (!r_hierarchy.owners.count(item->first)) { release_address(item->second); item = _vt.avt_cached_addresses.erase(item); }
			else { ++item; }
		}
		for (const Sector &sector : r_hierarchy.working) {
			auto allocated = _vt.avt_allocated_sizes.find(avt_owner_key(sector.owner));
			if (allocated != _vt.avt_allocated_sizes.end() && allocated->second > sector.size && _vt.surface_vt->resize_sector(sector.owner, sector.size)) {
				allocated->second = sector.size; directory_dirty = true;
			}
		}
	};
	for (const Sector &sector : r_hierarchy.working) {
		auto allocated = _vt.avt_allocated_sizes.find(avt_owner_key(sector.owner));
		int previous_size = allocated != _vt.avt_allocated_sizes.end() ? allocated->second : 0;
		if (previous_size == 0) {
			bool registered = _vt.surface_vt->register_sector(sector.owner, sector.size);
			if (!registered && sector.produce) { reclaim_addresses(); registered = _vt.surface_vt->register_sector(sector.owner, sector.size); }
			if (registered) {
				_vt.vt_registered_sectors[sector.owner] = true; _vt.avt_allocated_sizes[avt_owner_key(sector.owner)] = sector.size; directory_dirty = true;
			}
		} else if (previous_size < sector.size) {
			bool resized = _vt.surface_vt->resize_sector(sector.owner, sector.size);
			if (!resized && sector.produce) { reclaim_addresses(); resized = _vt.surface_vt->resize_sector(sector.owner, sector.size); }
			directory_dirty |= resized;
			if (resized) { _vt.avt_allocated_sizes[avt_owner_key(sector.owner)] = sector.size; }
		}
		if (_vt.surface_vt->has_sector(sector.owner)) { _vt.avt_cached_addresses[avt_owner_key(sector.owner)] = { sector.location, sector.owner, sector.level }; }
	}
	_vt.avt_registered_owners.clear();
	for (const auto &entry : _vt.avt_cached_addresses) { _vt.avt_registered_owners.push_back(entry.second.owner); }
	_vt.avt_sector_stats["retained_sector_addresses"] = int(_vt.avt_cached_addresses.size());
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
	for (Sector &sector : r_hierarchy.working) { sector.size = _vt.surface_vt->has_sector(sector.owner) ? _vt.surface_vt->get_sector_block_size(sector.owner) : 0; }
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
	auto remap_plan = [&](std::vector<Terrain3DAVTPageRequest> &plan) {
		for (auto it = plan.begin(); it != plan.end();) {
			auto address = _vt.avt_cached_addresses.find(avt_owner_key(it->owner));
			if (address == _vt.avt_cached_addresses.end() || !_vt.surface_vt->has_sector(it->owner)) { it = plan.erase(it); continue; }
			const auto &node = address->second;
			const int size = _vt.surface_vt->get_sector_block_size(it->owner);
			const float world = SECTOR_WORLD * float(1 << node.level);
			const float logical = node.level ? 1.f : size * logical_ratio;
			const int mip = int(std::round(std::log2(it->rect.size.x * logical / world)));
			if (mip < 0 || mip > TerrainVT::log2_power_of_two(size)) { it = plan.erase(it); continue; }
			it->mip = mip;
			++it;
		}
	};
	// Camera motion changes demand, not existing virtual addresses. Avoid
	// re-deriving every page mip when the address directory and scale agree.
	if (r_hierarchy.directory_dirty || logical_ratio != _vt.avt_plan_logical_ratio) {
		remap_plan(_vt.avt_page_plan);
		remap_plan(_vt.avt_prefetch_plan);
		_vt.avt_plan_logical_ratio = logical_ratio;
		// The addresses the source queue is retained against just changed.
		_vt.avt_retain_applied = false;
	}
	_vt.avt_prefetch_cursor = 0;
	_vt.avt_prefetch_cycle_pending = false;
	_vt.avt_idle_revision = 0;
	if (!_vt.vt_page_pipeline) { _vt.vt_page_pipeline = std::make_unique<Terrain3DPagePipeline>(_vt.vt_page_workers); }
	TerrainAVT::PlanInput input;
	input.working = r_hierarchy.working;
	input.source = _vt.vt_source_snapshot;
	input.view = p_view;
	input.bounds_ready = p_bounds_ready;
	input.camera_position = p_camera_position;
	input.focus = p_focus;
	input.reach = p_reach;
	input.exact_radius = float(_cdlod_enabled && _tessellation_level == 0 ? _cdlod_patch_size * _vertex_spacing * _cdlod_lod_scale * 0.7 / (1 << _tessellation_level) : 0);
	input.logical_ratio = logical_ratio;
	input.texels_per_pixel = _vt.surface_vt_texels_per_pixel;
	input.budget = r_hierarchy.budget;
	input.root_level = r_hierarchy.root_level;
	input.page_size = _vt.vt_page_size;
	_vt.vt_page_pipeline->submit_task([job, input]() mutable { TerrainAVT::plan_pages(*job, input); });
}

// Publishes the sector directory the shader reads. A sparse hash directory
// decouples GPU sector lookup from region layer IDs: two RGBA32F texels hold an
// exact world key/level and block origin/size. Returns whether it changed.
bool Terrain3D::_avt_publish_directory(const Terrain3DAVTHierarchy &p_hierarchy, const bool p_directory_dirty) {
	bool directory_changed = false;
	if (!p_directory_dirty && p_hierarchy.root_level == _vt.avt_root_level) { return false; }
	int entries = 1;
	while (entries < int(_vt.avt_cached_addresses.size()) * 2) { entries <<= 1; }
	int width = MIN(1024, entries * 2);
	int height = MAX(1, entries * 2 / width);
	PackedByteArray bytes;
	bytes.resize(int64_t(width) * height * 4 * sizeof(float));
	bytes.fill(0);
	uint8_t *output = bytes.ptrw();
	std::vector<bool> occupied(entries, false);
	int detailed = 0, max_size = 0;
	// The block size the shader reads is this ratio, and the planner only records it in the
	// plan it submits after publishing, so derive the live value instead of reading
	// `_vt.avt_plan_logical_ratio`: on the first publish of a configuration that member is
	// still its default of zero, and a zero block size collapses every fragment of the
	// sector onto the block's first page.
	const float logical_ratio = _avt_logical_ratio();
	for (const auto &cached : _vt.avt_cached_addresses) {
		const Terrain3DAVTCachedAddress &sector = cached.second;
		if (!_vt.surface_vt->has_sector(sector.owner)) { continue; }
		uint32_t index = sector_hash(sector.location.x, sector.location.y, sector.level) & (entries - 1);
		while (occupied[index]) { index = (index + 1) & (entries - 1); }
		occupied[index] = true;
		int size = _vt.surface_vt->get_sector_block_size(sector.owner);
		float entry[8] = { float(sector.location.x), float(sector.location.y), float(sector.level), 1.f,
				float(_vt.surface_vt->get_sector_block_origin_x(sector.owner)), float(_vt.surface_vt->get_sector_block_origin_y(sector.owner)), float(size), sector.level ? 1.f : float(size) * logical_ratio };
		std::memcpy(output + int64_t(index) * sizeof(entry), entry, sizeof(entry));
		if (sector.level == 0 && p_hierarchy.owners.count(cached.first)) { ++detailed; max_size = MAX(max_size, size); }
	}
	directory_changed = bytes != _vt.avt_directory_bytes || p_hierarchy.root_level != _vt.avt_root_level;
	bool uniform_changed = false;
	if (directory_changed) {
		const bool recreated = !(_vt.avt_sector_directory.is_valid() &&
				_vt.avt_sector_directory->get_width() == width && _vt.avt_sector_directory->get_height() == height);
		Ref<Image> image = Image::create_from_data(width, height, false, Image::FORMAT_RGBAF, bytes);
		if (_vt.avt_sector_directory.is_valid() && _vt.avt_sector_directory->get_width() == width && _vt.avt_sector_directory->get_height() == height) { _vt.avt_sector_directory->update(image); }
		else { _vt.avt_sector_directory = ImageTexture::create_from_image(image); }
		// Only a uniform the shader reads needs a material republish: the texture update
		// in place is already visible to it, and the republish is not free.
		uniform_changed = recreated || (entries - 1) != _vt.avt_directory_mask || p_hierarchy.root_level != _vt.avt_root_level;
		_vt.avt_directory_bytes = bytes;
		_vt.avt_directory_mask = entries - 1;
		_vt.avt_root_level = p_hierarchy.root_level;
	}
	_vt.avt_sector_stats["independent_sectors"] = detailed;
	_vt.avt_sector_stats["max_allocated_resolution"] = max_size * _vt.vt_page_size;
	return uniform_changed;
}
