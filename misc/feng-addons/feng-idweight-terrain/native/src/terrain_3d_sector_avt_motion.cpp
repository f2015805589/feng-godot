// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Terrain3D's near field, part 2 of 3: motion prediction and the plan key.

// One of three files that own the near field's planning. A page costs several frames to assemble
// and a compressed one several more to encode and read back, so demand issued at the moment a page
// becomes visible can only ever be late. The plan therefore describes the camera one lead ahead -
// both where it will be and where it will be looking, because a turn brings new world into the
// frustum exactly as a step does: `_vt_update_motion_lead()` smooths the velocity and the turn rate
// and slews both leads so that a noisy frame time cannot swing the working set, and
// `_vt_plan_key_transform()` quantizes the predicted transform so the key only changes when the
// camera leaves a cell - a key that changed every frame would re-derive every page address and
// throw away the worker's time on each tick.
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
// Turn look-ahead shaping. A camera that turns sweeps new world into the frustum at every distance
// at once - twenty degrees is seventy metres of terrain at 200 m - so the angle needs the same
// treatment the linear speed gets, and the two clamps below are the ones a turn can abuse.
//
// A rotation larger than this in one interval is a snap and not a turn: `snap()`, a teleport, a
// cut. The camera did not travel through that angle and no interval of it predicts the next one,
// so it must not aim the plan.
constexpr float MOTION_MAX_TURN_STEP = 0.4363323f; // 25 degrees per interval
// The rate is clamped as the linear speed is, so a burst of intervals arriving together cannot
// turn one frame into a whole revolution of lead.
constexpr float MOTION_MAX_TURN_RATE = 8.f; // radians per second
// The lead is an angle for the same reason the sweep is one: a single angle moves the frustum by
// the same amount at every distance. It is derived - the turn rate times the lead - and capped
// here, because the cap is what the plan's cost is a function of: the pages a turn brings into the
// frustum are pages the pool then has to hold, and the near field's phase mean follows the working
// set the plan names. 15 degrees is the angle a 60 degrees per second turn covers in one default
// lead of 250 ms, so a realistic swipe gets the lead it asks for and only a stress-rate turn is
// held back. Measured on `native/tests/vt_turn_budget.gd`: 15 degrees reads the same near-field
// mean as no turn lead at all (0.101 ms, at the budget's edge on this machine, where the baseline
// is the same coin flip), while 45 degrees reads 2.7x it (0.27-0.30 ms). The cap is where that
// trade lives, and it is the one number to raise for a view that turns harder than it serves.
constexpr float MOTION_MAX_TURN_LEAD = 0.2617994f; // 15 degrees
// And slew limited like the linear lead, in radians per second of lead change: the start of a real
// turn is followed within a few frames, a single noisy interval is not followed at all.
constexpr float MOTION_TURN_SLEW_RATE = 6.f;
}

// Motion look-ahead. A page costs several frames to assemble and a compressed page
// several more to encode and read back, so demand issued at the moment a page becomes
// visible can only ever be late: the view streams in. The plan therefore describes the
// camera one lead ahead - its position and its gaze, for the reason the two clamps exist:
// a turn is a way of moving the frustum, and it is the one the position alone cannot
// express. The velocity and the turn rate are exponentially smoothed, so a stop or a turn
// that ends decays the lead instead of leaving the plan aimed where the camera no longer
// is, and an edit, a teleport or a snap is bounded by the clamps below.
void Terrain3D::_vt_update_motion_lead() {
	Camera3D *camera = get_camera();
	if (!camera || !camera->is_inside_tree() || _vt.vt_motion_lead_ms <= 0.f) {
		_vt.avt_motion_lead = Vector2();
		_vt.avt_motion_valid = false;
		_vt.avt_motion_velocity = Vector2();
		_vt.avt_motion_turn = Vector3();
		_vt.avt_motion_turn_lead = Vector3();
		_vt.avt_motion_last_forward = Vector3();
		_vt.avt_retain_epochs = 8;
		_vt.avt_plan_refresh_frames = 1;
		return;
	}
	const Transform3D transform = camera->get_camera_transform();
	const Vector2 focus(transform.origin.x, transform.origin.z);
	const Vector3 forward = -transform.basis.get_column(2);
	const uint64_t now = Time::get_singleton()->get_ticks_usec();
	if (_vt.avt_motion_valid && now <= _vt.avt_motion_stamp_us + MOTION_MIN_INTERVAL_US) {
		return;
	}
	float delta = 0.f;
	if (_vt.avt_motion_valid && now > _vt.avt_motion_stamp_us) {
		delta = float(double(now - _vt.avt_motion_stamp_us) / 1000000.0);
		if (delta > 0.0005f) {
			const Vector2 displacement = focus - _vt.avt_motion_last_focus;
			const float discontinuity_distance = avt_motion_spatial_discontinuity_distance(
				float(_vt.surface_vt_distance));
			const bool displacement_cut = displacement.length_squared() >
				discontinuity_distance * discontinuity_distance;
			if (displacement_cut) {
				// A large position step has already crossed the working-set window. Do not slew
				// the old lead toward the new position: that would keep planning the old location
				// while the standing plan is still the only safe draw fallback.
				_vt.avt_motion_velocity = Vector2();
				_vt.avt_motion_lead = Vector2();
				_vt.avt_last_chain_frame = UINT64_MAX;
				_vt.avt_refinement.reset();
				_vt.avt_discard_retained = true;
			} else {
				Vector2 velocity = displacement / delta;
				if (velocity.length() > MOTION_MAX_SPEED) { velocity = velocity.normalized() * MOTION_MAX_SPEED; }
				_vt.avt_motion_velocity = _vt.avt_motion_velocity.lerp(velocity, MOTION_SMOOTHING);
			}
			// The gaze's rotation over the interval, as an axis and an angle. Two forward
			// vectors cannot see roll, which is the point: see the state's note.
			const Vector3 cross = _vt.avt_motion_last_forward.cross(forward);
			// asin(|a x b|) folds angles above 90 degrees back toward zero. In
			// particular, an exact 180 degree cut has a zero cross product and was
			// mistaken for no turn. atan2 keeps the full [0, pi] interval while the
			// dot product carries the sign that distinguishes a reversal.
			const float dot = CLAMP(_vt.avt_motion_last_forward.dot(forward), -1.f, 1.f);
			const float step = std::atan2(cross.length(), dot);
			if (step > MOTION_MAX_TURN_STEP) {
				// A snap. The interval holds no turn rate to smooth. Clear the already
				// applied lead as well: leaving it to slew down points the next plan at
				// the old view for several frames. The next demand must bypass the normal
				// refresh interval, and any refinement still owned by the terrain is
				// superseded. The worker lambda owns its shared_ptr, so this does not
				// cancel or invalidate work that is already executing.
				_vt.avt_motion_turn = Vector3();
				_vt.avt_motion_turn_lead = Vector3();
				_vt.avt_last_chain_frame = UINT64_MAX;
				_vt.avt_refinement.reset();
				_vt.avt_discard_retained = true;
			} else {
				Vector3 turn = cross.length() > 1e-6f ? cross.normalized() * (step / delta) : Vector3();
				if (turn.length() > MOTION_MAX_TURN_RATE) { turn = turn.normalized() * MOTION_MAX_TURN_RATE; }
				_vt.avt_motion_turn = _vt.avt_motion_turn.lerp(turn, MOTION_SMOOTHING);
			}
		}
	}
	_vt.avt_motion_last_focus = focus;
	_vt.avt_motion_last_forward = forward;
	_vt.avt_motion_stamp_us = now;
	_vt.avt_motion_valid = true;
	const float lead_seconds = float(_vt.vt_motion_lead_ms) / 1000.f;
	// A plan pointing further than half the near field's reach would spend production on
	// terrain the camera may never approach, so the lead is clamped by the reach.
	const float max_lead = MAX(64.f, float(_vt.surface_vt_distance)) * MOTION_LEAD_REACH_FRACTION;
	Vector2 target = _vt.avt_motion_velocity * lead_seconds;
	if (target.length() > max_lead) { target = target.normalized() * max_lead; }
	// Slew limit: a real acceleration is followed within a few frames, a noisy frame time
	// is not followed at all. The turn lead is slewed on the same interval, at its own rate.
	const float interval = MAX(delta, 0.001f);
	const float max_step = MOTION_LEAD_SLEW_RATE * interval;
	const Vector2 change = target - _vt.avt_motion_lead;
	_vt.avt_motion_lead = change.length() > max_step ? _vt.avt_motion_lead + change.normalized() * max_step : target;
	// The turn lead, shaped exactly like the linear one: a target, a cap and the same slew limit.
	// It is what a turn actually needs, and the reason the plan describes a frustum and not a point.
	const Vector3 turn_target_unslewed = _vt.avt_motion_turn * lead_seconds;
	const float turn_reach = turn_target_unslewed.length();
	const Vector3 turn_target = turn_reach > MOTION_MAX_TURN_LEAD
			? turn_target_unslewed * (MOTION_MAX_TURN_LEAD / turn_reach)
			: turn_target_unslewed;
	const float max_turn_step = MOTION_TURN_SLEW_RATE * interval;
	const Vector3 turn_change = turn_target - _vt.avt_motion_turn_lead;
	_vt.avt_motion_turn_lead = turn_change.length() > max_turn_step
			? _vt.avt_motion_turn_lead + turn_change.normalized() * max_turn_step
			: turn_target;
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
	Transform3D lead = p_camera_transform;
	if (_vt.avt_motion_lead != Vector2()) {
		lead.origin += Vector3(_vt.avt_motion_lead.x, 0.f, _vt.avt_motion_lead.y);
	}
	// The gaze is turned as well, about the axis the camera is turning around. Moving the eye
	// alone describes the frustum the camera will have while looking where it looks now, which is
	// what a turn makes wrong: the new world a turn brings in is off to the side of that frustum,
	// so the plan named none of it and the pages for it arrived after it was already on screen.
	const float turn = _vt.avt_motion_turn_lead.length();
	// A stopped camera's smoothed turn decays into float subnormals while TAA
	// keeps the editor drawing. Squaring those components in length() underflows:
	// dividing by that inaccurate length no longer yields a unit axis. Treat an
	// imperceptible turn as identity before entering the axis-angle constructor.
	if (turn > 1e-6f) {
		// Normalize explicitly at the constructor boundary. The smoothed vector is
		// repeatedly lerped and may contain enough accumulated error that division
		// by the previously computed float length does not satisfy Basis' strict
		// unit-axis check, especially while the editor keeps rendering for TAA.
		const Vector3 turn_axis = _vt.avt_motion_turn_lead.normalized();
		if (turn_axis.is_normalized()) {
			lead.basis = Basis(turn_axis, turn) * p_camera_transform.basis;
		}
	}
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
