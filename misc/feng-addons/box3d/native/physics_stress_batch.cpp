#include "physics_stress_batch.h"
#include "misc/box3d_globals.hpp"
#include "objects/box3d_physics_direct_body_state_3d.hpp"
#include "objects/box3d_body_impl_3d.hpp"
#include "spaces/box3d_space_3d.hpp"

#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/physics_direct_body_state3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

void FengPhysicsStressBatch::_bind_methods() {
	ClassDB::bind_method(D_METHOD("create", "space", "count", "allow_sleep"), &FengPhysicsStressBatch::create);
	ClassDB::bind_method(D_METHOD("clear"), &FengPhysicsStressBatch::clear);
	ClassDB::bind_method(D_METHOD("reset"), &FengPhysicsStressBatch::reset);
	ClassDB::bind_method(D_METHOD("set_sleep_enabled", "enabled"), &FengPhysicsStressBatch::set_sleep_enabled);
	ClassDB::bind_method(D_METHOD("agitate", "round"), &FengPhysicsStressBatch::agitate);
	ClassDB::bind_method(D_METHOD("sync_visuals", "multimesh"), &FengPhysicsStressBatch::sync_visuals);
	ClassDB::bind_method(D_METHOD("inspect"), &FengPhysicsStressBatch::inspect);
	ClassDB::bind_method(D_METHOD("core_profile"), &FengPhysicsStressBatch::core_profile);
	ClassDB::bind_method(D_METHOD("initial_buffer"), &FengPhysicsStressBatch::initial_buffer);
	ClassDB::bind_method(D_METHOD("final_state_buffer"), &FengPhysicsStressBatch::final_state_buffer);
}

FengPhysicsStressBatch::~FengPhysicsStressBatch() { clear(); }

void FengPhysicsStressBatch::clear() {
	body_states.clear();
	auto *server = PhysicsServer3D::get_singleton();
	if (server != nullptr) {
		for (RID body : bodies) server->free_rid(body);
		if (shape.is_valid()) server->free_rid(shape);
	}
	bodies.clear();
	initial_poses.clear();
	shape = RID();
	visual_buffer.clear();
}

void FengPhysicsStressBatch::write_transform(int index, const Transform3D &pose, float *buffer) {
	float *p = buffer + index * 16;
	for (int row = 0; row < 3; ++row) {
		for (int column = 0; column < 3; ++column) p[row * 4 + column] = pose.basis.rows[row][column];
		p[row * 4 + 3] = pose.origin[row];
	}
}

void FengPhysicsStressBatch::create(const RID &space, int count, bool allow_sleep) {
	ERR_FAIL_COND(count < 1 || count > 60000 || !space.is_valid());
	clear();
	auto *server = PhysicsServer3D::get_singleton();
	sleep_enabled = allow_sleep;
	shape = server->box_shape_create();
	server->shape_set_data(shape, Vector3(0.3f, 0.3f, 0.3f));
	bodies.reserve(count);
	body_states.reserve(count);
	initial_poses.reserve(count);
	visual_buffer.resize(count * 16);
	float *buffer = visual_buffer.ptrw();
	uint32_t random = 0x5eeda11u;
	auto next = [&random]() { random = random * 1664525u + 1013904223u; return float(random >> 8) / 16777216.0f; };
	for (int i = 0; i < count; ++i) {
		const int x = i % 50, z = (i / 50) % 40, y = i / 2000;
		Transform3D pose(Basis(Vector3(0, 1, 0), (next() - 0.5f) * 0.06f),
				Vector3((x - 24.5f) * 0.68f, 0.9f + y * 0.68f, (z - 19.5f) * 0.68f));
		RID body = server->body_create();
		server->body_set_mode(body, PhysicsServer3D::BODY_MODE_RIGID);
		server->body_add_shape(body, shape);
		server->body_set_param(body, PhysicsServer3D::BODY_PARAM_MASS, 1.0f);
		server->body_set_param(body, PhysicsServer3D::BODY_PARAM_FRICTION, 0.5f);
		server->body_set_param(body, PhysicsServer3D::BODY_PARAM_BOUNCE, 0.05f);
		server->body_set_param(body, PhysicsServer3D::BODY_PARAM_LINEAR_DAMP_MODE, PhysicsServer3D::BODY_DAMP_MODE_REPLACE);
		server->body_set_param(body, PhysicsServer3D::BODY_PARAM_ANGULAR_DAMP_MODE, PhysicsServer3D::BODY_DAMP_MODE_REPLACE);
		server->body_set_param(body, PhysicsServer3D::BODY_PARAM_LINEAR_DAMP, 0.05f);
		server->body_set_param(body, PhysicsServer3D::BODY_PARAM_ANGULAR_DAMP, 0.05f);
		server->body_set_state(body, PhysicsServer3D::BODY_STATE_TRANSFORM, pose);
		server->body_set_state(body, PhysicsServer3D::BODY_STATE_CAN_SLEEP, allow_sleep);
		// Identical sparse contact observers in both backends; not 60,000 callbacks.
		if (i % 997 == 0) server->body_set_max_contacts_reported(body, 8);
		server->body_set_space(body, space);
		bodies.push_back(body);
		body_states.push_back(server->body_get_direct_state(body));
		initial_poses.push_back(pose);
		write_transform(i, pose, buffer);
		Color color = Color::from_hsv(0.48f + (y % 6) * 0.025f, 0.48f + (x % 3) * 0.1f, 0.78f + (z % 3) * 0.06f);
		if (y % 7 == 0) color = Color(0.94f, 0.63f, 0.23f);
		buffer[i * 16 + 12] = color.r;
		buffer[i * 16 + 13] = color.g;
		buffer[i * 16 + 14] = color.b;
		buffer[i * 16 + 15] = 1;
	}
}

void FengPhysicsStressBatch::reset() {
	auto *server = PhysicsServer3D::get_singleton();
	for (size_t i = 0; i < bodies.size(); ++i) {
		server->body_set_state(bodies[i], PhysicsServer3D::BODY_STATE_TRANSFORM, initial_poses[i]);
		server->body_set_state(bodies[i], PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY, Vector3());
		server->body_set_state(bodies[i], PhysicsServer3D::BODY_STATE_ANGULAR_VELOCITY, Vector3());
		server->body_set_state(bodies[i], PhysicsServer3D::BODY_STATE_SLEEPING, false);
	}
}

void FengPhysicsStressBatch::set_sleep_enabled(bool enabled) {
	sleep_enabled = enabled;
	auto *server = PhysicsServer3D::get_singleton();
	for (RID body : bodies) server->body_set_state(body, PhysicsServer3D::BODY_STATE_CAN_SLEEP, enabled);
}

void FengPhysicsStressBatch::agitate(int round) {
	auto *server = PhysicsServer3D::get_singleton();
	// Reproducible sparse kicks keep contact islands moving without teleports.
	for (size_t i = round % 7; i < bodies.size(); i += 7) {
		server->body_apply_central_impulse(bodies[i], Vector3((i % 3 - 1.0f) * 0.6f, 1.5f, ((i / 3) % 3 - 1.0f) * 0.6f));
	}
}

void FengPhysicsStressBatch::sync_visuals(const RID &multimesh) {
	auto *server = PhysicsServer3D::get_singleton();
	float *buffer = visual_buffer.ptrw();
	for (size_t i = 0; i < bodies.size(); ++i) {
		// Typed public accessor avoids allocating/copying a Transform3D Variant
		// through the extension boundary for every object, on both backends.
		Transform3D pose = body_states[i] != nullptr ? body_states[i]->get_transform() :
				Transform3D(server->body_get_state(bodies[i], PhysicsServer3D::BODY_STATE_TRANSFORM));
		write_transform(int(i), pose, buffer);
	}
	RenderingServer::get_singleton()->multimesh_set_buffer(multimesh, visual_buffer);
}

PackedFloat32Array FengPhysicsStressBatch::initial_buffer() const {
	PackedFloat32Array buffer = visual_buffer; // ptrw() performs copy-on-write.
	float *p = buffer.ptrw();
	for (size_t i = 0; i < bodies.size(); ++i) {
		const Transform3D &pose = initial_poses[i];
		for (int r = 0; r < 3; ++r) {
			for (int c = 0; c < 3; ++c) p[i * 16 + r * 4 + c] = pose.basis.rows[r][c];
			p[i * 16 + r * 4 + 3] = pose.origin[r];
		}
	}
	return buffer;
}

PackedFloat32Array FengPhysicsStressBatch::final_state_buffer() const {
	// Read-only diagnostic layout, matching benchmark rigid_state:
	// [count, then per body in creation order: transform columns(9), origin(3),
	//  linear(3), angular(3), sleeping(1=awake/0=sleep)].
	const int stride = 19;
	PackedFloat32Array result;
	result.resize(1 + int(bodies.size()) * stride);
	float *p = result.ptrw();
	p[0] = float(bodies.size());
	auto *server = PhysicsServer3D::get_singleton();
	int out = 1;
	for (const RID &body : bodies) {
		Transform3D xform = server->body_get_state(body, PhysicsServer3D::BODY_STATE_TRANSFORM);
		Vector3 linear = server->body_get_state(body, PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY);
		Vector3 angular = server->body_get_state(body, PhysicsServer3D::BODY_STATE_ANGULAR_VELOCITY);
		bool sleeping = (bool)server->body_get_state(body, PhysicsServer3D::BODY_STATE_SLEEPING);
		for (int column = 0; column < 3; ++column) {
			for (int row = 0; row < 3; ++row) p[out++] = xform.basis.rows[row][column];
		}
		p[out++] = xform.origin.x;
		p[out++] = xform.origin.y;
		p[out++] = xform.origin.z;
		p[out++] = linear.x;
		p[out++] = linear.y;
		p[out++] = linear.z;
		p[out++] = angular.x;
		p[out++] = angular.y;
		p[out++] = angular.z;
		p[out++] = sleeping ? 0.0f : 1.0f;
	}
	return result;
}

Dictionary FengPhysicsStressBatch::core_profile() const {
	Dictionary result;
	if (body_states.empty()) return result;
	auto *state = Object::cast_to<Box3DPhysicsDirectBodyState3D>(body_states.front());
	if (state == nullptr) return result;
	const b3Profile profile = b3World_GetProfile(state->get_body()->get_space()->get_world_id());
#define PROFILE_FIELD(field) result[#field] = profile.field
	PROFILE_FIELD(step);
	PROFILE_FIELD(pairs);
	PROFILE_FIELD(collide);
	PROFILE_FIELD(solve);
	PROFILE_FIELD(solverSetup);
	PROFILE_FIELD(prepareConstraints);
	PROFILE_FIELD(integrateVelocities);
	PROFILE_FIELD(warmStart);
	PROFILE_FIELD(solveImpulses);
	PROFILE_FIELD(integratePositions);
	PROFILE_FIELD(relaxImpulses);
	PROFILE_FIELD(applyRestitution);
	PROFILE_FIELD(storeImpulses);
	PROFILE_FIELD(transforms);
	PROFILE_FIELD(refit);
	PROFILE_FIELD(sleepIslands);
#undef PROFILE_FIELD
	return result;
}

Dictionary FengPhysicsStressBatch::inspect() const {
	auto *server = PhysicsServer3D::get_singleton();
	Dictionary result;
	int awake = 0, invalid = 0, escaped = 0, observed_contacts = 0, transform_mismatches = 0;
	float max_speed = 0, min_bottom = 1e20f, max_y = -1e20f;
	String backend;
	for (size_t i = 0; i < bodies.size(); ++i) {
		Transform3D pose = server->body_get_state(bodies[i], PhysicsServer3D::BODY_STATE_TRANSFORM);
		if (body_states[i] != nullptr && !body_states[i]->get_transform().is_equal_approx(pose)) ++transform_mismatches;
		Vector3 velocity = server->body_get_state(bodies[i], PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY);
		if (!pose.is_finite() || !velocity.is_finite()) { ++invalid; continue; }
		if (!(bool)server->body_get_state(bodies[i], PhysicsServer3D::BODY_STATE_SLEEPING)) ++awake;
		if (pose.origin.y < -2 || std::abs(pose.origin.x) > 24 || std::abs(pose.origin.z) > 20) ++escaped;
		max_speed = std::max(max_speed, (float)velocity.length());
		min_bottom = std::min(min_bottom, pose.origin.y - 0.3f * (std::abs(pose.basis.rows[1][0]) + std::abs(pose.basis.rows[1][1]) + std::abs(pose.basis.rows[1][2])));
		max_y = std::max(max_y, pose.origin.y);
		if (i % 997 == 0) {
			auto *state = server->body_get_direct_state(bodies[i]);
			if (state) {
				backend = state->get_class();
				observed_contacts += state->get_contact_count();
			}
		}
	}
	result["bodies"] = int(bodies.size());
	result["awake"] = awake;
	result["invalid"] = invalid;
	result["transform_mismatches"] = transform_mismatches;
	result["escaped"] = escaped;
	result["maximum_speed"] = max_speed;
	result["lowest_box_bottom"] = min_bottom;
	result["highest_center"] = max_y;
	result["observed_contacts"] = observed_contacts;
	result["backend_body_state"] = backend;
	if (backend.begins_with("Box3D")) result["actual_box3d_workers"] = box3d_worker_count();
	result["allow_sleep"] = sleep_enabled;
	return result;
}
