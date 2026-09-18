// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3D's near field, part 2 of 3: motion prediction and the plan key.

// One of three files that own the near field's planning. A page costs several frames to assemble
// and a compressed one several more to encode and read back, so demand issued at the moment a page
// becomes visible can only ever be late. The plan therefore describes the camera's position one
// lead ahead: `_vt_update_motion_lead()` smooths the velocity and slews the lead so that a noisy
// frame time cannot swing the working set, and `_vt_plan_key_transform()` quantizes the predicted
// transform so the key only changes when the camera leaves a cell - a key that changed every frame
// would re-derive every page address and throw away the worker's time on each tick.
//
// The other two: `terrain_3d_sector_avt.cpp` (the entry point and its configuration) and
// `terrain_3d_sector_avt_hierarchy.cpp` (the scan, the hierarchy and the address directory).

#include "terrain_3d.h"

#include <godot_cpp/classes/time.hpp>

#include <cmath>

namespace {
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
