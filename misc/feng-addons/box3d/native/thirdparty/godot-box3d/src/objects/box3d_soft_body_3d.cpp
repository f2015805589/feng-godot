#include "box3d_soft_body_3d.hpp"

#include "../misc/type_conversions.hpp"
#include "../spaces/box3d_space_3d.hpp"
#include "box3d_shaped_object_impl_3d.hpp"
#include "soft_tasks.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <map>

Box3DSoftBody3D::~Box3DSoftBody3D() {
	set_space(nullptr);
}

void Box3DSoftBody3D::set_space(Box3DSpace3D *p_space) {
	if (space == p_space) {
		return;
	}
	if (space) {
		space->unregister_soft_body(this);
	}
	space = p_space;
	contact_caches.clear();
	if (space) {
		space->register_soft_body(this);
	}
	wake_up();
}

void Box3DSoftBody3D::set_mesh(RID p_mesh) {
	wake_up();
	particles.clear();
	contact_caches.clear();
	visual.clear();
	edges.clear();
	faces.clear();
	closed = false;
	tearable_layout = false;
	rest_volume = 0;
	seams.clear();
	neighbors.clear();
	bvh.clear();
	torn_seams = 0;
	total_weight = 0;
	bounds = AABB();
	if (!p_mesh.is_valid()) {
		return;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	if (!rs || rs->mesh_get_surface_count(p_mesh) == 0) {
		return;
	}
	Array arrays = rs->mesh_surface_get_arrays(p_mesh, 0);
	ERR_FAIL_COND(arrays.size() != Mesh::ARRAY_MAX);
	PackedVector3Array verts = arrays[Mesh::ARRAY_VERTEX];
	PackedInt32Array indices = arrays[Mesh::ARRAY_INDEX];
	if (indices.is_empty()) {
		indices.resize(verts.size());
		for (int i = 0; i < verts.size(); ++i) {
			indices[i] = i;
		}
	}
	ERR_FAIL_COND(indices.size() % 3 != 0);
	std::map<std::array<int64_t, 3>, int> welded;
	visual.reserve(verts.size());
	for (int i = 0; i < verts.size(); ++i) {
		const Vector3 v = verts[i];
		ERR_FAIL_COND(!v.is_finite());
		std::array<int64_t, 3> key = { int64_t(std::llround(v.x * 100000)), int64_t(std::llround(v.y * 100000)), int64_t(std::llround(v.z * 100000)) };
		auto found = welded.find(key);
		int id;
		if (found == welded.end()) {
			id = int(particles.size());
			welded[key] = id;
			Particle p;
			p.rest_id = id;
			p.rest = v;
			p.x = transform.xform(v);
			p.previous = p.x;
			particles.push_back(p);
		} else {
			id = found->second;
		}
		visual.push_back(id);
	}
	total_weight = float(particles.size());
	tearable_layout = true;
	std::vector<int> used(visual.size(), 0);
	std::map<std::pair<int, int>, std::vector<std::pair<int, int>>> sides;
	for (int i = 0; i < indices.size(); i += 3) {
		int a = indices[i], b = indices[i + 1], c = indices[i + 2];
		ERR_FAIL_COND(a < 0 || b < 0 || c < 0 || a >= int(visual.size()) || b >= int(visual.size()) || c >= int(visual.size()));
		const std::array<int, 3> render = { a, b, c };
		for (int v : render) {
			if (++used[v] > 1) {
				tearable_layout = false;
			}
		}
		a = visual[a];
		b = visual[b];
		c = visual[c];
		if (a == b || b == c || c == a) {
			continue;
		}
		int fi = int(faces.size());
		faces.push_back({ a, b, c, render });
		sides[std::minmax(a, b)].push_back({ fi, 0 });
		sides[std::minmax(b, c)].push_back({ fi, 1 });
		sides[std::minmax(c, a)].push_back({ fi, 2 });
	}
	closed = !faces.empty();
	for (const auto &entry : sides) {
		if (entry.second.size() == 2) {
			const auto &a = entry.second[0], &b = entry.second[1];
			seams.push_back({ a.first, b.first, a.second, b.second, float(particles[entry.first.first].x.distance_to(particles[entry.first.second].x)), false });
		} else {
			closed = false;
		}
	}
	rebuild_constraints();
	const Vector3 origin = particles.empty() ? Vector3() : particles[0].x;
	for (const Face &f : faces) {
		rest_volume += (particles[f.a].x - origin).dot((particles[f.b].x - origin).cross(particles[f.c].x - origin)) / 6.0f;
	}
	for (int index : pins) {
		if (index >= 0 && index < int(visual.size())) {
			particles[visual[index]].pinned = true;
		}
	}
	wake_up();
	update_bounds();
}

void Box3DSoftBody3D::set_transform(const Transform3D &p_transform) {
	if (!p_transform.is_finite() || std::abs(p_transform.basis.determinant()) < 1e-8) {
		return;
	}
	// SoftBody3D resets its Node3D transform to identity after submitting the
	// initial transform. Subsequent calls are world-space deltas, not absolute
	// poses (the Godot/Jolt backends use the same contract).
	Transform3D delta = p_transform;
	transform = p_transform * transform;
	for (auto &p : particles) {
		p.x = delta.xform(p.x);
		p.previous = p.x;
		p.velocity = Vector3();
	}
	// Rest distances are measured in the new world scale, independently of deformation.
	for (auto &e : edges) {
		e.length = transform.basis.xform(particles[e.a].rest - particles[e.b].rest).length();
	}
	for (auto &seam : seams) {
		const auto &f = faces[seam.f0];
		const std::array<int, 3> ids = { f.a, f.b, f.c };
		seam.rest_length = transform.basis.xform(particles[ids[seam.c0]].rest - particles[ids[(seam.c0 + 1) % 3]].rest).length();
	}
	rest_volume = 0;
	for (const auto &f : faces) {
		rest_volume += transform.basis.xform(particles[f.a].rest).dot(transform.basis.xform(particles[f.b].rest).cross(transform.basis.xform(particles[f.c].rest))) / 6.0f;
	}
	wake_up();
	update_bounds();
}

void Box3DSoftBody3D::pin(int i, bool value) {
	if (i < 0) {
		return;
	}
	if (value) {
		pins.insert(i);
	} else {
		pins.erase(i);
	}
	if (i >= int(visual.size())) {
		return;
	}
	int id = visual[i];
	particles[id].pinned = false;
	for (int p : pins) {
		if (p >= 0 && p < int(visual.size()) && visual[p] == id) {
			particles[id].pinned = true;
			break;
		}
	}
	particles[id].velocity = Vector3();
	wake_up();
}
void Box3DSoftBody3D::move(int i, Vector3 p) {
	if (i < 0 || i >= int(visual.size()) || !p.is_finite()) {
		return;
	}
	Particle &particle = particles[visual[i]];
	// Bone attachments submit identical pinned positions on every render frame.
	// A repeated handoff must not prevent a resting cloth from sleeping.
	if (particle.x == p) return;
	particle.x = p;
	particle.previous = p;
	particle.velocity = Vector3();
	wake_up();
	update_bounds();
}
Vector3 Box3DSoftBody3D::point(int i) const {
	return i >= 0 && i < int(visual.size()) ? particles[visual[i]].x : Vector3();
}
void Box3DSoftBody3D::apply_point_impulse(int i, const Vector3 &impulse) {
	if (i < 0 || i >= int(visual.size()) || !impulse.is_finite()) {
		return;
	}
	Particle &p = particles[visual[i]];
	if (!p.pinned) {
		p.velocity += impulse * inverse_mass(visual[i]);
		wake_up();
	}
}
void Box3DSoftBody3D::apply_point_force(int i, const Vector3 &force) {
	if (i < 0 || i >= int(visual.size()) || !force.is_finite()) {
		return;
	}
	Particle &p = particles[visual[i]];
	if (!p.pinned) {
		p.force += force;
		wake_up();
	}
}
void Box3DSoftBody3D::apply_central_impulse(const Vector3 &impulse) {
	if (!impulse.is_finite()) {
		return;
	}
	for (auto &p : particles) {
		if (!p.pinned) {
			p.velocity += impulse / std::max(mass, 0.001f);
		}
	}
	wake_up();
}
void Box3DSoftBody3D::apply_central_force(const Vector3 &force) {
	if (particles.empty() || !force.is_finite()) {
		return;
	}
	for (auto &p : particles) {
		if (!p.pinned) {
			p.force += force * (p.weight / total_weight);
		}
	}
	wake_up();
}
void Box3DSoftBody3D::set_state(PhysicsServer3D::BodyState state, const Variant &v) {
	if (state == PhysicsServer3D::BODY_STATE_TRANSFORM) {
		set_transform(v);
	} else if (state == PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY) {
		Vector3 velocity = v;
		if (velocity.is_finite()) {
			for (auto &p : particles) {
				if (!p.pinned) {
					p.velocity = velocity;
				}
			}
		}
		wake_up();
	} else if (state == PhysicsServer3D::BODY_STATE_SLEEPING) {
		wake_up();
		if (bool(v)) {
			sleeping = true;
			for (auto &p : particles) { p.velocity = Vector3(); p.previous = p.x; }
			remember_sleep_supports();
		}
	} else if (state == PhysicsServer3D::BODY_STATE_CAN_SLEEP) {
		can_sleep = bool(v);
		if (!can_sleep) wake_up();
	}
}
Variant Box3DSoftBody3D::get_state(PhysicsServer3D::BodyState state) const {
	if (state == PhysicsServer3D::BODY_STATE_TRANSFORM) {
		return Transform3D();
	}
	if (state == PhysicsServer3D::BODY_STATE_SLEEPING) {
		return sleeping;
	}
	if (state == PhysicsServer3D::BODY_STATE_CAN_SLEEP) {
		return can_sleep;
	}
	Vector3 velocity;
	if (state == PhysicsServer3D::BODY_STATE_LINEAR_VELOCITY && !particles.empty()) {
		for (const auto &p : particles) {
			velocity += p.velocity * p.weight;
		}
		velocity /= total_weight;
	}
	return velocity;
}

bool Box3DSoftBody3D::accepts(b3ShapeId shape) const {
	if (b3Shape_IsSensor(shape)) {
		return false;
	}
	auto *object = static_cast<Box3DShapedObjectImpl3D *>(b3Body_GetUserData(b3Shape_GetBody(shape)));
	return object && !exceptions.has(object->get_rid());
}
namespace {
struct Contact {
	Box3DSoftBody3D *body;
	float fraction = 1;
	Vector3 normal;
	Vector3 motion;
	b3ShapeId shape = b3_nullShapeId;
	Vector3 point;
	Vector3 origin;
	std::vector<b3CollisionPlane> *planes = nullptr;
	std::vector<Box3DSoftBody3D::RigidContact> *contacts = nullptr;
};
float cast_hit(b3ShapeId shape, b3Pos point, b3Vec3 normal, float fraction, uint64_t, int, int, void *data) {
	auto &c = *static_cast<Contact *>(data);
	if (!c.body->accepts(shape)) {
		return -1;
	}
	// #32: starting within contact slop can report fraction zero even while
	// moving away. Keep closing hits, let recovery planes resolve overlap.
	// Otherwise the first resting contact consumes the entire tangential/lift
	// motion and a particle cannot leave the floor again.
	if (fraction <= 1e-6f && b3Dot(normal, normal) > 0.5f && c.motion.dot(b3_to_godot(normal)) >= 0) {
		return -1;
	}
	if (fraction < c.fraction) {
		c.fraction = fraction;
		c.normal = b3_to_godot(normal);
		c.shape = shape;
		c.point = b3_to_godot(point);
	}
	return c.fraction;
}
bool plane_hit(b3ShapeId shape, const b3PlaneResult *planes, int count, void *data) {
	auto &c = *static_cast<Contact *>(data);
	if (!c.body->accepts(shape)) {
		return true;
	}
	for (int i = 0; i < count; ++i) {
		b3CollisionPlane p = {};
		p.plane = planes[i].plane;
		p.pushLimit = FLT_MAX;
		p.clipVelocity = true;
		c.planes->push_back(p);
		c.contacts->push_back({shape, c.origin + b3_to_godot(planes[i].point)});
	}
	return true;
}
} //namespace
void Box3DSoftBody3D::collide(Particle &p, float dt) {
	if (rigid_bounds.empty()) {
		p.velocity = (p.x - p.previous) / dt;
		return;
	}
	AABB swept(p.previous, Vector3());
	swept.expand_to(p.x);
	swept = swept.grow(thickness);
	bool nearby = false;
	for (const AABB &box : rigid_bounds) {
		if (swept.intersects(box)) {
			nearby = true;
			break;
		}
	}
	if (!nearby) {
		p.velocity = (p.x - p.previous) / dt;
		return;
	}
	Contact c;
	c.body = this;
	collision_planes.clear();
	rigid_contacts.clear();
	c.planes = &collision_planes;
	c.contacts = &rigid_contacts;
	auto world = space->get_world_id();
	b3QueryFilter filter = b3DefaultQueryFilter();
	b3Filter f = godot_to_b3_filter(layer, mask);
	filter.categoryBits = f.categoryBits;
	filter.maskBits = f.maskBits;
	Vector3 motion = p.x - p.previous;
	// Reconstruct XPBD velocity before collision recovery. Depenetration is a
	// position correction, not an extra launch impulse (also Jolt's ordering).
	p.velocity = motion / dt;
	c.motion = motion;
	const b3Vec3 center = b3Vec3_zero;
	b3ShapeProxy proxy = {};
	proxy.count = 1;
	proxy.radius = thickness;
	proxy.points = &center;
	if (motion.length_squared() > 1e-12f) {
		b3World_CastShape(world, godot_to_b3(p.previous), &proxy, godot_to_b3(motion), filter, cast_hit, &c);
		if (c.fraction < 1) {
			p.x = p.previous + motion * c.fraction + c.normal * 0.0001f;
			respond_rigid(p, c.shape, c.normal, c.point);
		}
	}
	b3Capsule mover = {};
	mover.radius = thickness;
	c.origin = p.x;
	b3World_CollideMover(world, godot_to_b3(p.x), &mover, filter, plane_hit, &c);
	if (!c.planes->empty()) {
		const b3PlaneSolverResult solved = b3SolvePlanes(b3Vec3_zero, c.planes->data(), int(c.planes->size()));
		p.x += b3_to_godot(solved.delta);
		for (size_t i = 0; i < collision_planes.size(); ++i) {
			// The positional solver intentionally tolerates small penetration.
			// Still cancel closing velocity at those resting contacts, otherwise
			// gravity accumulates until the next push and continually breaks sleep.
			const b3Plane &plane = collision_planes[i].plane;
			if (collision_planes[i].push > 0 || b3Dot(plane.normal, solved.delta) - plane.offset <= 1e-5f) {
				respond_rigid(p, rigid_contacts[i].shape, b3_to_godot(collision_planes[i].plane.normal), rigid_contacts[i].point);
			}
		}
	}
}

void Box3DSoftBody3D::respond_rigid(Particle &p, b3ShapeId shape, const Vector3 &normal, const Vector3 &point) {
	if (normal.length_squared() < 0.5f) return;
	const b3BodyId rigid = b3Shape_GetBody(shape);
	const bool dynamic = b3Body_GetType(rigid) == b3_dynamicBody;
	const Vector3 rigid_velocity = b3_to_godot(b3Body_GetWorldPointVelocity(rigid, godot_to_b3(point)));
	const Vector3 relative = p.velocity - rigid_velocity;
	const float vn = relative.dot(normal);
	if (vn >= 0) return;
	const float wp = total_weight / (std::max(mass, 0.001f) * p.weight);
	const float wr = dynamic ? b3Body_GetInverseMass(rigid) : 0;
	const Vector3 arm = dynamic ? point - b3_to_godot(b3Body_GetWorldCenter(rigid)) : Vector3();
	const b3Matrix3 inertia = dynamic ? b3Body_GetWorldInverseRotationalInertia(rigid) : b3Matrix3{};
	auto effective_mass = [&](const Vector3 &direction) {
		const b3Vec3 cross = godot_to_b3(arm.cross(direction));
		return wp + wr + b3Dot(cross, b3MulMV(inertia, cross));
	};
	const b3SurfaceMaterial material = b3Shape_GetSurfaceMaterial(shape);
	const float restitution = vn < -0.5f ? std::clamp(material.restitution, 0.0f, 1.0f) : 0;
	const float normal_impulse = -(1 + restitution) * vn / effective_mass(normal);
	Vector3 impulse = normal * normal_impulse;
	const Vector3 tangent = relative - normal * vn;
	const float speed = tangent.length();
	if (speed > 1e-6f) {
		const Vector3 direction = tangent / speed;
		impulse -= direction * std::min(speed / effective_mass(direction), std::max(0.0f, material.friction) * normal_impulse);
	}
	p.velocity += impulse * wp;
	if (dynamic) {
		b3Body_ApplyLinearImpulse(rigid, godot_to_b3(-impulse), godot_to_b3(point), true);
	}
}

void Box3DSoftBody3D::predict(float h) {
	if (sleeping) return;
	++motion_revision;
	bvh_dirty = render_dirty = true;
	const float base_inverse_mass = total_weight / std::max(mass, 0.001f);
	const Vector3 gravity = b3_to_godot(b3World_GetGravity(space->get_world_id()));
	const float attenuation = std::exp(-std::max(0.0f, damping + drag) * h);
	for (auto &p : particles) {
		p.previous = p.x;
		if (p.pinned || sleeping) {
			continue;
		}
		const float inv = base_inverse_mass / p.weight;
		p.velocity = (p.velocity + (gravity + p.force * inv) * h) * attenuation;
		p.x += p.velocity * h;
	}
	check_tearing();
}

void Box3DSoftBody3D::solve_constraints(float h) {
	if (sleeping) {
		return;
	}
	const float alpha = (1.0f - std::clamp(stiffness, 0.0f, 1.0f)) * 1e-5f / (h * h);
	constraint_particles.resize(particles.size());
	for (size_t i = 0; i < particles.size(); ++i) {
		constraint_particles[i] = { particles[i].x, inverse_mass(int(i)) };
	}
	auto &positions = constraint_particles;
	const float shrink_scale = std::max(0.01f, 1.0f - shrinking);
	const bool solve_volume = closed && pressure > 0 && std::abs(rest_volume) > 1e-9f;
	if (solve_volume) {
		volume_gradients.resize(particles.size());
	}
	for (auto &batch : constraint_batches) {
		for (int lane = 0; lane < batch.count; ++lane) {
			const auto &e = edges[batch.edges[lane]];
			batch.lambda[lane] = 0;
			batch.compliance[lane] = alpha * (e.bend ? 20.0f : 1.0f);
			const float weight = positions[e.a].inverse_mass + positions[e.b].inverse_mass;
			batch.inverse_effective_mass[lane] = weight > 0 ? 1.0f / (weight + batch.compliance[lane]) : 0;
			batch.target_length[lane] = e.length * shrink_scale;
		}
	}
	struct Iteration {
		Box3DSoftBody3D *body;
		bool volume;
		float compliance, target, lambda = 0;
	} step = { this, solve_volume, 1e-7f / (std::max(pressure, 0.001f) * h * h), rest_volume * shrink_scale * shrink_scale * shrink_scale };
	auto finish_iteration = [](void *data) {
		auto &step = *static_cast<Iteration *>(data);
		auto &body = *step.body;
		body.solve_batches(body.parallel_batch_end, int(body.constraint_batches.size()));
		if (step.volume) {
			auto &positions = body.constraint_particles;
			auto &gradients = body.volume_gradients;
			std::fill(gradients.begin(), gradients.end(), Vector3());
			float volume = 0;
			const Vector3 origin = positions[0].x;
			for (const auto &f : body.faces) {
				Vector3 a = positions[f.a].x - origin, b = positions[f.b].x - origin, c = positions[f.c].x - origin;
				volume += a.dot(b.cross(c)) / 6;
				gradients[f.a] += b.cross(c) / 6;
				gradients[f.b] += c.cross(a) / 6;
				gradients[f.c] += a.cross(b) / 6;
			}
			float denominator = 0;
			for (size_t i = 0; i < positions.size(); ++i) {
				if (positions[i].inverse_mass > 0) {
					denominator += positions[i].inverse_mass * gradients[i].length_squared();
				}
			}
			float dl = (-(volume - step.target) - step.compliance * step.lambda) / (denominator + step.compliance);
			step.lambda += dl;
			for (size_t i = 0; i < positions.size(); ++i) {
				if (positions[i].inverse_mass > 0) {
					positions[i].x += gradients[i] * (positions[i].inverse_mass * dl);
				}
			}
		}
	};
	const int iterations = std::clamp(precision, 1, 100);
	if (!constraint_batch_group_ends.empty()) {
		fengSoftParallelIterations(space->get_world_id(), int(constraint_batch_group_ends.size()), iterations, [](int begin, int end, void *data) {
			auto &body = *static_cast<Iteration *>(data)->body;
			for (int group = begin; group < end; ++group) {
				body.solve_batches(group == 0 ? 0 : body.constraint_batch_group_ends[group - 1], body.constraint_batch_group_ends[group]);
			}
		}, finish_iteration, &step);
	} else {
		// Small bodies may already run in an outer body batch: no nested jobs.
		for (int iteration = 0; iteration < iterations; ++iteration) finish_iteration(&step);
	}
	for (size_t i = 0; i < particles.size(); ++i) {
		particles[i].x = positions[i].x;
	}
}

void Box3DSoftBody3D::solve_batches(int begin, int end) {
	static_assert(sizeof(ConstraintParticle) == 4 * sizeof(float), "SIMD particles must contain xyz and inverse mass");
	for (int i = begin; i < end; ++i) {
		auto &batch = constraint_batches[i];
#if defined(__SSE2__) || defined(_M_X64)
		if (batch.count == 4) {
			Edge *e[4] = { &edges[batch.edges[0]], &edges[batch.edges[1]], &edges[batch.edges[2]], &edges[batch.edges[3]] };
			__m128 ax = _mm_load_ps(&constraint_particles[e[0]->a].x.x), ay = _mm_load_ps(&constraint_particles[e[1]->a].x.x);
			__m128 az = _mm_load_ps(&constraint_particles[e[2]->a].x.x), aw = _mm_load_ps(&constraint_particles[e[3]->a].x.x);
			__m128 bx = _mm_load_ps(&constraint_particles[e[0]->b].x.x), by = _mm_load_ps(&constraint_particles[e[1]->b].x.x);
			__m128 bz = _mm_load_ps(&constraint_particles[e[2]->b].x.x), bw = _mm_load_ps(&constraint_particles[e[3]->b].x.x);
			_MM_TRANSPOSE4_PS(ax, ay, az, aw);
			_MM_TRANSPOSE4_PS(bx, by, bz, bw);
			__m128 dx = _mm_sub_ps(bx, ax), dy = _mm_sub_ps(by, ay), dz = _mm_sub_ps(bz, az);
			const __m128 length = _mm_sqrt_ps(_mm_add_ps(_mm_add_ps(_mm_mul_ps(dx, dx), _mm_mul_ps(dy, dy)), _mm_mul_ps(dz, dz)));
			const __m128 target = _mm_load_ps(batch.target_length);
			const __m128 alpha = _mm_load_ps(batch.compliance);
			const __m128 lambda = _mm_load_ps(batch.lambda);
			const __m128 inv = _mm_load_ps(batch.inverse_effective_mass);
			__m128 dl = _mm_mul_ps(_mm_sub_ps(_mm_sub_ps(target, length), _mm_mul_ps(alpha, lambda)), inv);
			dl = _mm_and_ps(dl, _mm_cmpge_ps(length, _mm_set1_ps(1e-8f)));
			_mm_store_ps(batch.lambda, _mm_add_ps(lambda, dl));
			const __m128 correction = _mm_div_ps(dl, _mm_max_ps(length, _mm_set1_ps(1e-8f)));
			dx = _mm_mul_ps(dx, correction); dy = _mm_mul_ps(dy, correction); dz = _mm_mul_ps(dz, correction);
			ax = _mm_sub_ps(ax, _mm_mul_ps(dx, aw)); ay = _mm_sub_ps(ay, _mm_mul_ps(dy, aw)); az = _mm_sub_ps(az, _mm_mul_ps(dz, aw));
			bx = _mm_add_ps(bx, _mm_mul_ps(dx, bw)); by = _mm_add_ps(by, _mm_mul_ps(dy, bw)); bz = _mm_add_ps(bz, _mm_mul_ps(dz, bw));
			_MM_TRANSPOSE4_PS(ax, ay, az, aw);
			_MM_TRANSPOSE4_PS(bx, by, bz, bw);
			_mm_store_ps(&constraint_particles[e[0]->a].x.x, ax); _mm_store_ps(&constraint_particles[e[0]->b].x.x, bx);
			_mm_store_ps(&constraint_particles[e[1]->a].x.x, ay); _mm_store_ps(&constraint_particles[e[1]->b].x.x, by);
			_mm_store_ps(&constraint_particles[e[2]->a].x.x, az); _mm_store_ps(&constraint_particles[e[2]->b].x.x, bz);
			_mm_store_ps(&constraint_particles[e[3]->a].x.x, aw); _mm_store_ps(&constraint_particles[e[3]->b].x.x, bw);
			continue;
		}
#endif
		for (int lane = 0; lane < batch.count; ++lane) {
			auto &e = edges[batch.edges[lane]];
			if (batch.inverse_effective_mass[lane] == 0) continue;
			auto &a = constraint_particles[e.a], &b = constraint_particles[e.b];
			Vector3 delta = b.x - a.x;
			float length = delta.length();
			if (length < 1e-8f) continue;
			float dl = (-(length - batch.target_length[lane]) - batch.compliance[lane] * batch.lambda[lane]) * batch.inverse_effective_mass[lane];
			batch.lambda[lane] += dl;
			Vector3 correction = delta * (dl / length);
			a.x -= correction * a.inverse_mass;
			b.x += correction * b.inverse_mass;
		}
	}
}

void Box3DSoftBody3D::step_all(const HashSet<Box3DSoftBody3D *> &bodies, float dt) {
	if (bodies.is_empty() || dt <= 0) {
		return;
	}
	std::vector<Box3DSoftBody3D *> active;
	for (auto *body : bodies) {
		if (body->space && !body->particles.empty()) {
			body->check_wake();
			active.push_back(body);
			body->contact_tests = body->contacts_solved = 0;
		}
	}
	// Stable pair order, independent of hash table allocation.
	std::sort(active.begin(), active.end(), [](const auto *a, const auto *b) { return a->rid.get_id() < b->rid.get_id(); });
	const float h = std::min(dt, 0.1f) / 4;
	std::vector<Box3DSoftBody3D *> small_bodies;
	small_bodies.reserve(active.size());
	for (int substep = 0; substep < 4; ++substep) {
		small_bodies.clear();
		for (auto *body : active) {
			body->predict(h);
			if (!body->sleeping && body->constraint_batch_group_ends.empty()) small_bodies.push_back(body);
		}
		// A small mesh has too little work for internal constraint jobs. Batch
		// independent bodies instead, while large meshes keep their vertex groups.
		// These jobs touch only their own particles/constraints. Rigid impulses and
		// inter-body contacts stay ordered on the caller, with no nested job waits.
		if (!small_bodies.empty()) {
			struct Work { std::vector<Box3DSoftBody3D *> *bodies; float dt; } work = { &small_bodies, h };
			fengSoftParallelFor(small_bodies[0]->space->get_world_id(), int(small_bodies.size()), 1, [](int begin, int end, void *data) {
				auto &work = *static_cast<Work *>(data);
				for (int i = begin; i < end; ++i) (*work.bodies)[i]->solve_constraints(work.dt);
			}, &work);
		}
		for (auto *body : active) {
			if (!body->constraint_batch_group_ends.empty()) body->solve_constraints(h);
			if (!body->sleeping) {
				body->prepare_rigid_contacts();
			}
			for (auto &p : body->particles) {
				if (!p.pinned && !body->sleeping) {
					body->collide(p, h);
				}
			}
		}
		for (int iteration = 0; iteration < 2; ++iteration) {
			bool corrected = false;
			for (auto *body : active) {
				if (body->self_collision || (body->soft_collision && active.size() > 1)) {
					body->refit_bvh();
				}
			}
			for (size_t a = 0; a < active.size(); ++a) {
				auto &body = *active[a];
				if (body.self_collision && !body.sleeping) {
					corrected |= body.collide_soft(body);
				}
				if (!body.soft_collision) {
					continue;
				}
				for (size_t b = a + 1; b < active.size(); ++b) {
					auto &other = *active[b];
					if (!other.soft_collision || (body.sleeping && other.sleeping) ||
							!((body.mask & other.layer) || (other.mask & body.layer)) ||
							body.exceptions.has(other.rid) || other.exceptions.has(body.rid) ||
							body.bvh.empty() || other.bvh.empty() || !body.bvh[0].bounds.intersects(other.bvh[0].bounds)) {
						continue;
					}
					corrected |= body.collide_soft(other);
					corrected |= other.collide_soft(body);
				}
			}
			// With no position corrections the second pass has identical inputs.
			// Contacts still get both passes; substeps and precision are unchanged.
			if (!corrected) {
				break;
			}
		}
		for (auto *body : active) {
			if (!body->sleeping) body->update_bounds();
		}
	}
	for (auto *body : active) {
		body->update_sleep(dt);
		for (auto &p : body->particles) {
			p.force = Vector3();
		}
	}
	// Contacting soft meshes must settle as one island. Sleeping one while its
	// support still solves would alternately wake both and reset their timers.
	std::vector<bool> visited(active.size(), false);
	std::vector<size_t> island;
	for (size_t seed = 0; seed < active.size(); ++seed) {
		if (visited[seed]) continue;
		island.clear(); island.push_back(seed); visited[seed] = true;
		bool ready = true;
		for (size_t next = 0; next < island.size(); ++next) {
			auto &body = *active[island[next]];
			ready &= body.sleeping || (body.can_sleep && body.sleep_time >= 0.5f);
			for (size_t other = 0; other < active.size(); ++other) {
				if (!visited[other] && body.is_sleep_neighbor(*active[other])) { visited[other] = true; island.push_back(other); }
			}
		}
		if (!ready) continue;
		for (size_t index : island) {
			auto &body = *active[index];
			if (body.sleeping) continue;
			body.sleeping = true;
			for (auto &p : body.particles) { p.velocity = Vector3(); p.previous = p.x; }
			body.bvh_dirty = true;
			body.remember_sleep_supports();
		}
	}
}
void Box3DSoftBody3D::update_bounds() {
	bounds = particles.empty() ? AABB() : AABB(particles[0].x, Vector3());
	for (const auto &p : particles) {
		bounds.expand_to(p.x);
	}
	bounds = bounds.grow(thickness);
}
void Box3DSoftBody3D::update_rendering(PhysicsServer3DRenderingServerHandler *handler) {
	if (!handler || particles.empty()) {
		return;
	}
	if (!render_dirty && handler == last_render_handler) return;
	for (auto &p : particles) {
		p.normal = Vector3();
	}
	for (const auto &f : faces) {
		Vector3 n = (particles[f.c].x - particles[f.a].x).cross(particles[f.b].x - particles[f.a].x);
		particles[f.a].normal += n;
		particles[f.b].normal += n;
		particles[f.c].normal += n;
	}
	for (auto &p : particles) {
		p.normal.normalize();
	}
	for (int i = 0; i < int(visual.size()); ++i) {
		const auto &p = particles[visual[i]];
		handler->set_vertex(i, p.x);
		handler->set_normal(i, p.normal);
	}
	handler->set_aabb(bounds);
	render_dirty = false;
	last_render_handler = handler;
}

void Box3DSoftBody3D::wake_up() {
	++motion_revision;
	sleeping = false;
	sleep_time = 0;
	bvh_dirty = render_dirty = true;
}

void Box3DSoftBody3D::remember_sleep_supports() {
	sleep_supports.clear();
	sleep_soft_supports.clear();
	if (!space || particles.empty()) return;
	for (const auto *other : space->get_soft_bodies()) {
		if (is_sleep_neighbor(*other)) sleep_soft_supports.push_back({other->rid, other->motion_revision});
	}
	sleep_gravity = b3_to_godot(b3World_GetGravity(space->get_world_id()));
	b3QueryFilter filter = b3DefaultQueryFilter();
	const b3Filter f = godot_to_b3_filter(layer, mask);
	filter.categoryBits = f.categoryBits; filter.maskBits = f.maskBits;
	const AABB box = bounds.grow(0.01f);
	b3World_OverlapAABB(space->get_world_id(), {godot_to_b3(box.position), godot_to_b3(box.get_end())}, filter,
			[](b3ShapeId shape, void *context) {
				auto &body = *static_cast<Box3DSoftBody3D *>(context);
				if (!body.accepts(shape)) return true;
				const b3AABB aabb = b3Shape_GetAABB(shape);
				const Vector3 lo = b3_to_godot(aabb.lowerBound), hi = b3_to_godot(aabb.upperBound);
				body.sleep_supports.push_back({ shape, b3_to_godot(b3Body_GetTransform(b3Shape_GetBody(shape))), AABB(lo, hi-lo) });
				return true;
			}, this);
}

void Box3DSoftBody3D::check_wake() {
	if (!sleeping || !space) return;
	if (std::all_of(particles.begin(), particles.end(), [](const Particle &p) { return p.pinned; })) return;
	if (sleep_gravity != b3_to_godot(b3World_GetGravity(space->get_world_id()))) {
		wake_up(); return;
	}
	int soft_matches = 0;
	for (const auto *other : space->get_soft_bodies()) {
		if (!is_sleep_neighbor(*other)) continue;
		bool known = false;
		for (const auto &support : sleep_soft_supports) {
			if (other->rid == support.rid && other->motion_revision == support.revision) { known = true; break; }
		}
		if (!known) { wake_up(); return; }
		++soft_matches;
	}
	if (soft_matches != int(sleep_soft_supports.size())) { wake_up(); return; }
	// Removing, scaling or moving a support must wake an otherwise motionless
	// soft body. Merely querying current overlaps cannot detect a removed floor.
	for (const auto &support : sleep_supports) {
		if (!b3Shape_IsValid(support.shape) || !accepts(support.shape)) { wake_up(); return; }
		const b3AABB aabb = b3Shape_GetAABB(support.shape);
		const Vector3 lo = b3_to_godot(aabb.lowerBound), hi = b3_to_godot(aabb.upperBound);
		if (support.transform != b3_to_godot(b3Body_GetTransform(b3Shape_GetBody(support.shape))) || support.bounds != AABB(lo, hi-lo)) {
			wake_up(); return;
		}
	}
	b3QueryFilter filter = b3DefaultQueryFilter();
	const b3Filter f = godot_to_b3_filter(layer, mask);
	filter.categoryBits = f.categoryBits; filter.maskBits = f.maskBits;
	const AABB box = bounds.grow(0.01f);
	struct WakeQuery { Box3DSoftBody3D *body; int matched = 0; } query{this};
	b3World_OverlapAABB(space->get_world_id(), {godot_to_b3(box.position), godot_to_b3(box.get_end())}, filter,
			[](b3ShapeId shape, void *context) {
				auto &q = *static_cast<WakeQuery *>(context);
				auto &body = *q.body;
				if (!body.accepts(shape)) return true;
				const b3BodyId rigid = b3Shape_GetBody(shape);
				bool known = false;
				for (const auto &support : body.sleep_supports) known |= B3_ID_EQUALS(support.shape, shape);
				if (known) ++q.matched;
				if (!known || (b3Body_GetType(rigid) != b3_staticBody && b3Body_IsAwake(rigid))) body.wake_up();
				return body.sleeping;
			}, &query);
	if (sleeping && query.matched != int(sleep_supports.size())) wake_up();
}

bool Box3DSoftBody3D::is_sleep_neighbor(const Box3DSoftBody3D &other) const {
	return this != &other && soft_collision && other.soft_collision && !other.particles.empty() &&
			((mask & other.layer) || (other.mask & layer)) && !exceptions.has(other.rid) && !other.exceptions.has(rid) &&
			bounds.grow(0.01f).intersects(other.bounds);
}

void Box3DSoftBody3D::update_sleep(float dt) {
	if (sleeping || !can_sleep) return;
	// Use both velocity and accumulated point travel. Testing velocity alone
	// can incorrectly put a slowly creeping/deforming cloth to sleep.
	constexpr float speed_squared = 0.03f * 0.03f;
	constexpr float travel_squared = 0.01f * 0.01f;
	if (sleep_positions.size() != particles.size() || sleep_time == 0) {
		sleep_positions.resize(particles.size());
		for (size_t i = 0; i < particles.size(); ++i) sleep_positions[i] = particles[i].x;
	}
	for (size_t i = 0; i < particles.size(); ++i) {
		const auto &p = particles[i];
		if (p.velocity.length_squared() > speed_squared || p.x.distance_squared_to(sleep_positions[i]) > travel_squared) {
			sleep_time = 0;
			return;
		}
	}
	sleep_time += dt;
}
