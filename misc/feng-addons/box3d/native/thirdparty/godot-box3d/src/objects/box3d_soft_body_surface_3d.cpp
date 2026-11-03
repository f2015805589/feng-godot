#include "../misc/type_conversions.hpp"
#include "../spaces/box3d_space_3d.hpp"
#include "box3d_soft_body_3d.hpp"
#include "soft_tasks.h"

#include <box3d/box3d.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <numeric>

namespace {
std::array<int, 3> vertices(const Box3DSoftBody3D::Face &f) {
	return { f.a, f.b, f.c };
}

Vector3 closest_triangle(const Vector3 &p, const Vector3 &a, const Vector3 &b, const Vector3 &c, Vector3 &weights) {
	const Vector3 ab = b - a, ac = c - a, ap = p - a;
	float d1 = ab.dot(ap), d2 = ac.dot(ap);
	if (d1 <= 0 && d2 <= 0) {
		weights = Vector3(1, 0, 0);
		return a;
	}
	const Vector3 bp = p - b;
	float d3 = ab.dot(bp), d4 = ac.dot(bp);
	if (d3 >= 0 && d4 <= d3) {
		weights = Vector3(0, 1, 0);
		return b;
	}
	float vc = d1 * d4 - d3 * d2;
	if (vc <= 0 && d1 >= 0 && d3 <= 0) {
		float v = d1 / std::max(1e-20f, d1 - d3);
		weights = Vector3(1 - v, v, 0);
		return a + ab * v;
	}
	const Vector3 cp = p - c;
	float d5 = ab.dot(cp), d6 = ac.dot(cp);
	if (d6 >= 0 && d5 <= d6) {
		weights = Vector3(0, 0, 1);
		return c;
	}
	float vb = d5 * d2 - d1 * d6;
	if (vb <= 0 && d2 >= 0 && d6 <= 0) {
		float w = d2 / std::max(1e-20f, d2 - d6);
		weights = Vector3(1 - w, 0, w);
		return a + ac * w;
	}
	float va = d3 * d6 - d5 * d4;
	if (va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0) {
		float w = (d4 - d3) / std::max(1e-20f, d4 - d3 + d5 - d6);
		weights = Vector3(0, 1 - w, w);
		return b + (c - b) * w;
	}
	float sum = va + vb + vc;
	if (std::abs(sum) < 1e-20f) {
		weights = Vector3(1, 0, 0);
		return a;
	}
	weights = Vector3(va, vb, vc) / sum;
	return a * weights.x + b * weights.y + c * weights.z;
}

float segment_distance_squared(const Vector3 &a, const Vector3 &b, const Vector3 &c, const Vector3 &d) {
	Vector3 u = b - a, v = d - c, w = a - c;
	float aa = u.dot(u), bb = u.dot(v), cc = v.dot(v), dd = u.dot(w), ee = v.dot(w);
	float denom = aa * cc - bb * bb;
	float s = denom > 1e-12f ? std::clamp((bb * ee - cc * dd) / denom, 0.0f, 1.0f) : 0;
	float t = cc > 1e-12f ? std::clamp((bb * s + ee) / cc, 0.0f, 1.0f) : 0;
	s = aa > 1e-12f ? std::clamp((bb * t - dd) / aa, 0.0f, 1.0f) : 0;
	return (w + u * s - v * t).length_squared();
}
} //namespace

float Box3DSoftBody3D::inverse_mass(int i) const {
	return particles[i].pinned ? 0 : total_weight / (std::max(mass, 0.001f) * particles[i].weight);
}

Dictionary Box3DSoftBody3D::configure(const Dictionary &options) {
	can_sleep = options.get("can_sleep", can_sleep);
	self_collision = options.get("self_collision", self_collision);
	soft_collision = options.get("soft_collision", soft_collision);
	const float old_thickness = thickness;
	thickness = std::clamp(float(options.get("collision_radius", thickness)), 0.001f, 0.5f);
	if (thickness != old_thickness) fitted_vertex_bounds.clear();
	tear_ratio = std::clamp(float(options.get("tear_ratio", tear_ratio)), 1.05f, 20.0f);
	max_tears_per_step = std::clamp(int(options.get("max_tears_per_step", max_tears_per_step)), 1, 128);
	// Node3D may submit its owned render mesh after configuration. Keep the
	// requested setting; topology support is checked when tearing is evaluated.
	tearing = bool(options.get("tearing", tearing));
	wake_up();
	update_bounds();
	return statistics();
}

Dictionary Box3DSoftBody3D::statistics() const {
	Dictionary result;
	result["particles"] = int(particles.size());
	result["visual_vertices"] = int(visual.size());
	result["triangles"] = int(faces.size());
	result["torn_seams"] = torn_seams;
	result["tearing_supported"] = tearable_layout;
	result["tearing_enabled"] = tearing && tearable_layout;
	result["self_collision"] = self_collision;
	result["soft_collision"] = soft_collision;
	result["sleeping"] = sleeping;
	result["can_sleep"] = can_sleep;
	result["constraint_groups"] = int(constraint_group_ends.size());
	result["parallel_edges"] = parallel_edge_end;
	result["constraints"] = int(edges.size());
	result["contact_tests"] = int64_t(contact_tests);
	result["contacts_solved"] = int64_t(contacts_solved);
	float weights = 0;
	float kinetic = 0, maximum_speed_squared = 0;
	Vector3 center;
	for (const auto &p : particles) {
		weights += p.weight;
		center += p.x * p.weight;
		const float speed_squared = p.velocity.length_squared();
		kinetic += p.weight * speed_squared;
		maximum_speed_squared = std::max(maximum_speed_squared, speed_squared);
	}
	result["particle_mass_sum"] = weights * mass / std::max(total_weight, 1.0f);
	result["kinetic_energy"] = 0.5f * kinetic * mass / std::max(total_weight, 1.0f);
	result["maximum_speed"] = std::sqrt(maximum_speed_squared);
	result["center_of_mass"] = center / std::max(weights, 1e-12f);
	return result;
}

void Box3DSoftBody3D::rebuild_constraints() {
	bvh_dirty = render_dirty = true;
	contact_caches.clear();
	edges.clear();
	std::map<std::pair<int, int>, std::vector<int>> links;
	for (const auto &f : faces) {
		links[std::minmax(f.a, f.b)].push_back(f.c);
		links[std::minmax(f.b, f.c)].push_back(f.a);
		links[std::minmax(f.c, f.a)].push_back(f.b);
	}
	if (neighbors.empty()) {
		neighbors.resize(particles.size());
		for (const auto &entry : links) {
			int a = entry.first.first, b = entry.first.second;
			neighbors[a].push_back(b);
			neighbors[b].push_back(a);
		}
	}
	for (const auto &entry : links) {
		int a = entry.first.first, b = entry.first.second;
		edges.push_back({ a, b, float(transform.basis.xform(particles[a].rest - particles[b].rest).length()), false });
		if (entry.second.size() == 2) {
			int c = entry.second[0], d = entry.second[1];
			if (c != d) {
				edges.push_back({ c, d, float(transform.basis.xform(particles[c].rest - particles[d].rest).length()), true });
			}
		}
	}
	group_constraints();
	batch_constraints();
	face_order.resize(faces.size());
	std::iota(face_order.begin(), face_order.end(), 0);
	bvh.clear();
	fitted_vertex_bounds.clear();
	bvh.reserve(faces.size() * 2);
	if (!faces.empty()) {
		build_bvh(0, int(faces.size()));
	}
	refit_bvh();
}

void Box3DSoftBody3D::group_constraints() {
	constraint_group_ends.clear();
	parallel_edge_end = 0;
	if (particles.size() < 1024 || edges.empty()) {
		return;
	}
	std::vector<std::vector<int>> connected(particles.size());
	for (const auto &edge : edges) {
		connected[edge.a].push_back(edge.b);
		connected[edge.b].push_back(edge.a);
	}
	std::vector<int> group(particles.size(), -1), queue;
	queue.reserve(128);
	int group_count = 0;
	for (int seed = 0; seed < int(particles.size()); ++seed) {
		if (group[seed] >= 0) continue;
		queue.clear();
		queue.push_back(seed);
		group[seed] = group_count;
		for (size_t next = 0; next < queue.size() && queue.size() < 128; ++next) {
			for (int vertex : connected[queue[next]]) {
				if (group[vertex] >= 0) continue;
				group[vertex] = group_count;
				queue.push_back(vertex);
				if (queue.size() == 128) break;
			}
		}
		++group_count;
	}
	std::vector<std::vector<Edge>> groups(group_count + 1);
	for (const auto &edge : edges) {
		const int index = group[edge.a] == group[edge.b] ? group[edge.a] : group_count;
		groups[index].push_back(edge);
	}
	edges.clear();
	for (int i = 0; i <= group_count; ++i) {
		edges.insert(edges.end(), groups[i].begin(), groups[i].end());
		if (i < group_count) constraint_group_ends.push_back(int(edges.size()));
	}
	parallel_edge_end = constraint_group_ends.back();
}

void Box3DSoftBody3D::batch_constraints() {
	constraint_batches.clear();
	constraint_batch_group_ends.clear();
	// Color each independent cluster once. Four constraints with no shared
	// endpoint can use SIMD without turning Gauss-Seidel into a Jacobi solver.
	std::vector<uint64_t> used(particles.size(), 0);
	int begin = 0;
	for (size_t group = 0; group <= constraint_group_ends.size(); ++group) {
		const int end = group < constraint_group_ends.size() ? constraint_group_ends[group] : int(edges.size());
		std::fill(used.begin(), used.end(), 0);
		std::array<std::vector<int>, 64> colors;
		for (int i = begin; i < end; ++i) {
			const auto &e = edges[i];
			const uint64_t unavailable = used[e.a] | used[e.b];
			int color = 0;
			while (color < 64 && (unavailable & (uint64_t(1) << color))) ++color;
			if (color == 64) {
				// Pathological high-valence vertices still retain every constraint.
				constraint_batches.push_back({ { i, i, i, i }, 1 });
				continue;
			}
			used[e.a] |= uint64_t(1) << color;
			used[e.b] |= uint64_t(1) << color;
			colors[color].push_back(i);
		}
		for (const auto &color : colors) {
			for (size_t i = 0; i < color.size(); i += 4) {
				ConstraintBatch batch;
				batch.count = std::min(4, int(color.size() - i));
				for (int lane = 0; lane < 4; ++lane) batch.edges[lane] = color[i + std::min(lane, batch.count - 1)];
				constraint_batches.push_back(batch);
			}
		}
		if (group < constraint_group_ends.size()) constraint_batch_group_ends.push_back(int(constraint_batches.size()));
		begin = end;
	}
	parallel_batch_end = constraint_batch_group_ends.empty() ? 0 : constraint_batch_group_ends.back();
}

int Box3DSoftBody3D::build_bvh(int begin, int end) {
	int index = int(bvh.size());
	bvh.push_back({});
	if (end - begin <= 4) {
		bvh[index].begin = begin;
		bvh[index].count = end - begin;
		return index;
	}
	auto center = [&](int fi) { const auto &f=faces[fi]; return (particles[f.a].x+particles[f.b].x+particles[f.c].x)/3; };
	AABB box(center(face_order[begin]), Vector3());
	for (int i = begin + 1; i < end; ++i) {
		box.expand_to(center(face_order[i]));
	}
	int axis = box.size.max_axis_index(), middle = (begin + end) / 2;
	std::nth_element(face_order.begin() + begin, face_order.begin() + middle, face_order.begin() + end,
			[&](int a, int b) { return center(a)[axis] < center(b)[axis]; });
	int left = build_bvh(begin, middle), right = build_bvh(middle, end);
	bvh[index].left = left;
	bvh[index].right = right;
	return index;
}

void Box3DSoftBody3D::refit_bvh() {
	if (!bvh_dirty) return;
	bvh_dirty = false;
	bool reusable = fitted_vertex_bounds.size() == particles.size();
	if (reusable) {
		for (size_t i = 0; i < particles.size(); ++i) {
			ContactBounds swept(particles[i].x);
			swept.expand(particles[i].previous);
			if (!fitted_vertex_bounds[i].contains(swept)) { reusable = false; break; }
		}
	}
	if (reusable) return;
	++bvh_revision;
	// Conservative fat bounds are reusable only while *every* current and
	// previous vertex stays inside them. Large deformations rebuild immediately.
	// This retains swept tests, unlike updating self-collision less frequently.
	const float margin = std::min(thickness, 0.02f);
	fitted_vertex_bounds.resize(particles.size());
	for (size_t i = 0; i < particles.size(); ++i) {
		fitted_vertex_bounds[i] = ContactBounds(particles[i].x);
		fitted_vertex_bounds[i].expand(particles[i].previous);
		fitted_vertex_bounds[i].grow(margin);
	}
	face_bounds.resize(faces.size());
	auto refit_faces = [](int begin, int end, void *data) {
		auto &body = *static_cast<Box3DSoftBody3D *>(data);
		for (int i = begin; i < end; ++i) {
			auto &box = body.face_bounds[i];
			box = body.fitted_vertex_bounds[body.faces[i].a];
			for (int id : vertices(body.faces[i])) {
				box.merge(body.fitted_vertex_bounds[id]);
			}
			box.grow(body.thickness);
		}
	};
	if (space && faces.size() >= 1024) {
		fengSoftParallelFor(space->get_world_id(), int(faces.size()), 256, refit_faces, this);
	} else {
		refit_faces(0, int(faces.size()), this);
	}
	for (int i = int(bvh.size()) - 1; i >= 0; --i) {
		auto &node = bvh[i];
		if (node.left >= 0) {
			node.bounds = bvh[node.left].bounds;
			node.bounds.merge(bvh[node.right].bounds);
		} else {
			node.bounds = face_bounds[face_order[node.begin]];
			for (int j = node.begin + 1; j < node.begin + node.count; ++j) {
				node.bounds.merge(face_bounds[face_order[j]]);
			}
		}
	}
}

void Box3DSoftBody3D::query_faces(const ContactBounds &box) {
	query_faces(box, candidates, query_stack);
}

void Box3DSoftBody3D::query_faces(const ContactBounds &box, std::vector<int> &results, std::vector<int> &stack) const {
	results.clear();
	stack.clear();
	if (bvh.empty()) {
		return;
	}
	stack.push_back(0);
	while (!stack.empty()) {
		int index = stack.back();
		stack.pop_back();
		const auto &node = bvh[index];
		if (!node.bounds.intersects(box)) {
			continue;
		}
		if (node.left >= 0) {
			stack.push_back(node.left);
			stack.push_back(node.right);
		} else {
			for (int i = node.begin; i < node.begin + node.count; ++i) {
				int face = face_order[i];
				if (face_bounds[face].intersects(box)) {
					results.push_back(face);
				}
			}
		}
	}
}

bool Box3DSoftBody3D::self_contact_excluded(int particle, int face) const {
	const int rest = particles[particle].rest_id;
	const auto &connected = neighbors[rest];
	for (int v : vertices(faces[face])) {
		const int other_rest = particles[v].rest_id;
		if (other_rest == rest || std::find(connected.begin(), connected.end(), other_rest) != connected.end()) return true;
	}
	return false;
}

bool Box3DSoftBody3D::collide_soft(Box3DSoftBody3D &other) {
	const float radius = thickness + other.thickness;
	const bool same = this == &other;
	bool corrected = false;
	auto found = std::find_if(contact_caches.begin(), contact_caches.end(), [&](const ContactCache &cache) { return cache.target == other.rid; });
	if (found == contact_caches.end()) {
		if (contact_caches.size() < 4) {
			contact_caches.push_back({});
			found = contact_caches.end() - 1;
		} else {
			found = std::min_element(contact_caches.begin(), contact_caches.end(), [](const ContactCache &a, const ContactCache &b) { return a.last_used < b.last_used; });
			found->vertices.clear();
		}
		found->target = other.rid;
	}
	found->last_used = ++contact_cache_clock;
	auto &candidate_batches = found->vertices;
	candidate_batches.resize(particles.size());
	{
		struct Query { Box3DSoftBody3D *body, *other; std::vector<CandidateBatch> *batches; } query = { this, &other, &candidate_batches };
		fengSoftParallelFor(space->get_world_id(), int(particles.size()), 256, [](int begin, int end, void *data) {
			auto &context = *static_cast<Query *>(data);
			std::vector<int> stack;
			for (int i = begin; i < end; ++i) {
				const auto &p = context.body->particles[i];
				auto &batch = (*context.batches)[i];
				ContactBounds box(p.previous);
				box.expand(p.x);
				box.grow(context.body->thickness);
				if (batch.revision == context.other->bvh_revision && batch.bounds.contains(box)) continue;
				box.grow(std::min(context.body->thickness, 0.02f));
				if (stack.capacity() == 0) stack.reserve(64);
				context.other->query_faces(box, batch.faces, stack);
				if (context.body == context.other) {
					batch.faces.erase(std::remove_if(batch.faces.begin(), batch.faces.end(), [&](int face) {
						return context.body->self_contact_excluded(i, face);
					}), batch.faces.end());
				}
				batch.bounds = box;
				batch.revision = context.other->bvh_revision;
			}
		}, &query);
	}
	for (int i = 0; i < int(particles.size()); ++i) {
		auto &p = particles[i];
		const std::vector<int> *list = &candidate_batches[i].faces;
		// The batch just checked the swept query. Until a contact has moved a
		// vertex, an empty result is still empty; don't reconstruct that query.
		if (!corrected && list->empty()) continue;
		bool filtered = true;
		ContactBounds query(p.previous);
		query.expand(p.x);
		query.grow(thickness);
		if (!candidate_batches[i].bounds.contains(query)) {
			// An earlier contact can move this particle as a triangle vertex.
			// Requery in that case so batching never loses a newly reachable face.
			other.query_faces(query);
			list = &other.candidates;
			filtered = false;
		}
		for (int fi : *list) {
			const auto ids = vertices(other.faces[fi]);
			if (same && !filtered && self_contact_excluded(i, fi)) continue;
			++contact_tests;
			auto &a = other.particles[ids[0]], &b = other.particles[ids[1]], &c = other.particles[ids[2]];
			Vector3 n = (b.x - a.x).cross(c.x - a.x);
			const float n_squared = n.length_squared();
			if (n_squared < 1e-18f) continue;
			const Vector3 old_n = (b.previous - a.previous).cross(c.previous - a.previous);
			const float old_n_squared = old_n.length_squared();
			const float plane0 = (p.previous - a.previous).dot(old_n), plane1 = (p.x - a.x).dot(n);
			const bool may_cross = plane0 * plane1 < 0 && plane0 * plane0 > 1e-12f * old_n_squared;
			// A same-side point farther than the contact radius from the infinite
			// plane cannot hit its triangle. Reject fat-BVH candidates before the
			// barycentric search and square roots, retaining all swept crossings.
			if (!may_cross && plane1 * plane1 >= radius * radius * n_squared) continue;
			Vector3 weights;
			Vector3 q = closest_triangle(p.x, a.x, b.x, c.x, weights);
			Vector3 delta = p.x - q;
			if (!may_cross && delta.length_squared() >= radius * radius) continue;
			n /= std::sqrt(n_squared);
			bool crossing = false;
			if (may_cross) {
				const float d0 = plane0 / std::sqrt(old_n_squared), d1 = (p.x - a.x).dot(n);
				float t = std::abs(d0) / (std::abs(d0) + std::abs(d1));
				Vector3 ip = p.previous.lerp(p.x, t);
				Vector3 hit = closest_triangle(ip, a.previous.lerp(a.x, t), b.previous.lerp(b.x, t), c.previous.lerp(c.x, t), weights);
				crossing = hit.distance_squared_to(ip) < radius * radius;
				if (crossing) {
					q = a.x * weights.x + b.x * weights.y + c.x * weights.z;
				} else {
					q = closest_triangle(p.x, a.x, b.x, c.x, weights);
				}
			}
			if (!crossing && delta.length_squared() >= radius * radius) {
				continue;
			}
			if (crossing) {
				n *= plane0 >= 0 ? 1 : -1;
			} else if (delta.length_squared() > 1e-12f) {
				n = delta.normalized();
			} else {
				n *= plane0 >= 0 ? 1 : -1;
			}
			float penetration = radius - (p.x - q).dot(n);
			if (penetration <= 0) {
				continue;
			}
			float wp = inverse_mass(i);
			float wa = other.inverse_mass(ids[0]), wb = other.inverse_mass(ids[1]), wc = other.inverse_mass(ids[2]);
			float denom = wp + wa * weights.x * weights.x + wb * weights.y * weights.y + wc * weights.z * weights.z;
			if (denom < 1e-12f) {
				continue;
			}
			Vector3 correction = n * (penetration / denom);
			p.x += correction * wp;
			a.x -= correction * (wa * weights.x);
			b.x -= correction * (wb * weights.y);
			c.x -= correction * (wc * weights.z);
			// Separation repairs overlap; it must not become delta-position / dt
			// kinetic energy, especially at a new tear. Exchange only the closing
			// relative velocity using the same barycentric effective mass.
			const Vector3 relative = p.velocity - a.velocity * weights.x - b.velocity * weights.y - c.velocity * weights.z;
			const float vn = relative.dot(n);
			if (vn < 0) {
				const Vector3 impulse = n * (-vn / denom);
				p.velocity += impulse * wp;
				a.velocity -= impulse * (wa * weights.x);
				b.velocity -= impulse * (wb * weights.y);
				c.velocity -= impulse * (wc * weights.z);
			}
			if (wp > 0) {
				if (sleeping) wake_up();
				bvh_dirty = render_dirty = true;
				++motion_revision;
			}
			if (wa + wb + wc > 0) {
				if (other.sleeping) other.wake_up();
				other.bvh_dirty = other.render_dirty = true;
				++other.motion_revision;
			}
			++contacts_solved;
			corrected = true;
		}
	}
	return corrected;
}

void Box3DSoftBody3D::prepare_rigid_contacts() {
	rigid_bounds.clear();
	AABB swept(particles[0].x, Vector3());
	for (const auto &p : particles) {
		swept.expand_to(p.x);
		swept.expand_to(p.previous);
	}
	swept = swept.grow(thickness);
	b3AABB box = { godot_to_b3(swept.position), godot_to_b3(swept.position + swept.size) };
	b3QueryFilter filter = b3DefaultQueryFilter();
	b3Filter f = godot_to_b3_filter(layer, mask);
	filter.categoryBits = f.categoryBits;
	filter.maskBits = f.maskBits;
	b3World_OverlapAABB(space->get_world_id(), box, filter, [](b3ShapeId shape, void *context) {
		auto *body=static_cast<Box3DSoftBody3D *>(context);
		if (body->accepts(shape)) {
			b3AABB a=b3Shape_GetAABB(shape);
			Vector3 lower=b3_to_godot(a.lowerBound),upper=b3_to_godot(a.upperBound);
			body->rigid_bounds.push_back(AABB(lower,upper-lower));
		}
		return true; }, this);
}

void Box3DSoftBody3D::check_tearing() {
	if (!tearing || !tearable_layout) {
		return;
	}
	int count = 0;
	for (auto &seam : seams) {
		if (seam.broken) {
			continue;
		}
		const auto ids = vertices(faces[seam.f0]);
		if (particles[ids[seam.c0]].x.distance_to(particles[ids[(seam.c0 + 1) % 3]].x) > seam.rest_length * tear_ratio) {
			seam.broken = true;
			++torn_seams;
			if (++count >= max_tears_per_step) {
				break;
			}
		}
	}
	if (count) {
		split_torn_seams();
	}
}

int Box3DSoftBody3D::cut(const Vector3 &from, const Vector3 &to, float radius) {
	if (!tearing || !tearable_layout || !from.is_finite() || !to.is_finite() || !std::isfinite(radius) || radius <= 0) {
		return 0;
	}
	int count = 0;
	for (auto &seam : seams) {
		if (seam.broken) {
			continue;
		}
		const auto ids = vertices(faces[seam.f0]);
		const auto &a = particles[ids[seam.c0]], &b = particles[ids[(seam.c0 + 1) % 3]];
		if (segment_distance_squared(a.x, b.x, from, to) <= radius * radius) {
			seam.broken = true;
			++count;
			++torn_seams;
		}
	}
	if (count) {
		split_torn_seams();
		wake_up();
	}
	return count;
}

void Box3DSoftBody3D::split_torn_seams() {
	// Union triangle corners only across intact seams. The expanded visual mesh
	// reserves one vertex per corner, so splitting never reallocates a GPU buffer.
	std::vector<int> parents(faces.size() * 3);
	std::iota(parents.begin(), parents.end(), 0);
	auto find = [&](int x) { while (parents[x]!=x) { parents[x]=parents[parents[x]]; x=parents[x]; } return x; };
	for (const auto &seam : seams) {
		if (seam.broken) {
			continue;
		}
		const auto a = vertices(faces[seam.f0]), b = vertices(faces[seam.f1]);
		for (int j = 0; j < 2; ++j) {
			int ca = (seam.c0 + j) % 3;
			for (int k = 0; k < 2; ++k) {
				int cb = (seam.c1 + k) % 3;
				if (a[ca] == b[cb]) {
					parents[find(seam.f1 * 3 + cb)] = find(seam.f0 * 3 + ca);
				}
			}
		}
	}
	std::map<int, std::map<int, std::vector<int>>> groups;
	for (int fi = 0; fi < int(faces.size()); ++fi) {
		auto ids = vertices(faces[fi]);
		for (int c = 0; c < 3; ++c) {
			groups[ids[c]][find(fi * 3 + c)].push_back(fi * 3 + c);
		}
	}
	for (auto &entry : groups) {
		Particle original = particles[entry.first];
		size_t corners = 0;
		for (const auto &g : entry.second) {
			corners += g.second.size();
		}
		bool first = true;
		for (const auto &g : entry.second) {
			int id = first ? entry.first : int(particles.size());
			Particle copy = original;
			copy.weight = original.weight * float(g.second.size()) / float(corners);
			copy.force = original.force * (copy.weight / original.weight);
			copy.pinned = false;
			for (int corner : g.second) {
				auto &face = faces[corner / 3];
				int c = corner % 3;
				if (c == 0) {
					face.a = id;
				} else if (c == 1) {
					face.b = id;
				} else {
					face.c = id;
				}
				visual[face.visual[c]] = id;
				if (pins.has(face.visual[c])) {
					copy.pinned = true;
				}
			}
			if (first) {
				particles[id] = copy;
			} else {
				particles.push_back(copy);
			}
			first = false;
		}
	}
	// An opened shell can no longer sustain internal volume pressure.
	closed = false;
	rebuild_constraints();
	update_bounds();
}
