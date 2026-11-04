#pragma once

#include <box3d/id.h>
#include <box3d/types.h>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/physics_server3d_rendering_server_handler.hpp>
#include <godot_cpp/templates/hash_set.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <array>
#include <algorithm>
#include <vector>
#if defined(__SSE2__) || defined(_M_X64)
#include <emmintrin.h>
#endif

using namespace godot;
class Box3DSpace3D;

// Mesh-based XPBD, coupled to Box3D's rigid collision world. Visual seam vertices
// share particles; no mesh/RD reads occur during the physics step.
class Box3DSoftBody3D {
public:
	struct Particle {
		Vector3 rest, x, previous, velocity, normal, force;
		float weight = 1;
		int rest_id = 0;
		bool pinned = false;
	};
	struct Edge {
		int a, b;
		float length;
		bool bend = false;
	};
	struct Face {
		int a, b, c;
		std::array<int, 3> visual;
	};
	struct Seam {
		int f0, f1, c0, c1;
		float rest_length;
		bool broken = false;
	};
	struct RigidContact {
		b3ShapeId shape;
		Vector3 point;
	};
	// Per-particle result of the read-only rigid collision pass. It owns its
	// plane slice because b3SolvePlanes writes the accumulated push back into
	// the planes the response pass reads. Nothing here is shared between
	// particles, so query_rigid() has no cross-particle side effects.
	struct RigidQueryResult {
		bool cast_hit = false;
		Vector3 normal, point;
		b3ShapeId cast_shape = b3_nullShapeId;
		b3Vec3 solved_delta = {};
		std::vector<b3CollisionPlane> planes;
		std::vector<RigidContact> contacts;
	};
	RID rid;
	uint64_t instance_id = 0;
	Box3DSpace3D *space = nullptr;
	Transform3D transform;
	std::vector<Particle> particles;
	std::vector<int> visual;
	std::vector<Edge> edges;
	std::vector<Face> faces;
	HashSet<int> pins;
	HashSet<RID> exceptions;
	uint32_t layer = 1, mask = 1;
	int precision = 5;
	float mass = 1, stiffness = 0.5f, pressure = 0, damping = 0.01f, drag = 0, shrinking = 0;
	bool ray_pickable = true, sleeping = false, closed = false;
	bool can_sleep = true;
	float rest_volume = 0;
	AABB bounds;
	bool self_collision = true, soft_collision = true, tearing = false;
	float thickness = 0.025f, tear_ratio = 1.8f;
	int max_tears_per_step = 8, torn_seams = 0;
	uint64_t contact_tests = 0, contacts_solved = 0;
	bool tearable_layout = false;

	~Box3DSoftBody3D();
	void set_space(Box3DSpace3D *p_space);
	void set_mesh(RID p_mesh);
	void set_transform(const Transform3D &p_transform);
	void set_state(PhysicsServer3D::BodyState p_state, const Variant &p_value);
	Variant get_state(PhysicsServer3D::BodyState p_state) const;
	void pin(int p_vertex, bool p_pin);
	void move(int p_vertex, Vector3 p_position);
	Vector3 point(int p_vertex) const;
	void apply_point_impulse(int p_vertex, const Vector3 &p_impulse);
	void apply_point_force(int p_vertex, const Vector3 &p_force);
	void apply_central_impulse(const Vector3 &p_impulse);
	void apply_central_force(const Vector3 &p_force);
	void wake_up();
	static void step_all(const HashSet<Box3DSoftBody3D *> &p_bodies, float p_dt);
	Dictionary configure(const Dictionary &p_options);
	Dictionary statistics() const;
	int cut(const Vector3 &p_from, const Vector3 &p_to, float p_radius);
	void update_rendering(PhysicsServer3DRenderingServerHandler *p_handler);
	bool accepts(b3ShapeId p_shape) const;

private:
	float sleep_time = 0;
	Vector3 sleep_gravity;
	std::vector<Vector3> sleep_positions;
	struct SleepSupport {
		b3ShapeId shape;
		Transform3D transform;
		AABB bounds;
	};
	std::vector<SleepSupport> sleep_supports;
	struct SleepSoftSupport { RID rid; uint64_t revision; };
	std::vector<SleepSoftSupport> sleep_soft_supports;
	uint64_t motion_revision = 0;
	bool bvh_dirty = true, render_dirty = true;
	PhysicsServer3DRenderingServerHandler *last_render_handler = nullptr;
	void update_sleep(float p_dt);
	void check_wake();
	void remember_sleep_supports();
	bool is_sleep_neighbor(const Box3DSoftBody3D &p_other) const;
	// Keep just the hot solver fields together. The render/rest/velocity data in
	// Particle must not occupy cache lines for every constraint iteration.
	struct alignas(16) ConstraintParticle {
		Vector3 x;
		float inverse_mass;
	};
	std::vector<Vector3> volume_gradients;
	std::vector<ConstraintParticle> constraint_particles;
	// Disjoint vertex clusters are solved in parallel; cross-cluster edges run
	// afterwards. Rebuilt after a tear, never during the parallel solver.
	std::vector<int> constraint_group_ends;
	int parallel_edge_end = 0;
	struct ConstraintBatch {
		std::array<int, 4> edges;
		int count;
		// Iterations load/store whole SIMD vectors instead of gathering solver
		// parameters from four scattered topology records for every constraint.
		alignas(16) float target_length[4] = {}, compliance[4] = {}, inverse_effective_mass[4] = {}, lambda[4] = {};
		// Endpoint indices are cached next to the batch so neither the substep
		// setup nor the solver has to scatter-read Edge records just to find the
		// two particles. Filled together with the constants above.
		int a[4] = {}, b[4] = {};
	};
	std::vector<ConstraintBatch> constraint_batches;
	std::vector<int> constraint_batch_group_ends;
	int parallel_batch_end = 0;
	// Constraint setup cache. alpha/compliance/inverse_effective_mass/target_length
	// do not depend on particle positions, only on h, stiffness, shrinking,
	// inverse masses and topology. h is shared by all four substeps of a step, so
	// the first substep computes them and the next three only clear lambda.
	// Invalidation: mesh rebuild bumps constraint_revision, pin changes bump it
	// too, tearing/cut rebuilds change torn_seams, and mass/total weight are
	// compared directly.
	bool constraint_setup_valid = false;
	float constraint_setup_h = 0.0f;
	float constraint_setup_stiffness = 0.0f;
	float constraint_setup_shrinking = 0.0f;
	float constraint_setup_mass = 0.0f;
	float constraint_setup_total_weight = 0.0f;
	int constraint_setup_torn_seams = 0;
	uint64_t constraint_setup_revision = 0;
	uint64_t constraint_revision = 0;
	std::vector<Seam> seams;
	// Rest-topology neighbors stay excluded after a tear. Newly split twins
	// start coincident; treating them as penetrating contacts would explode them.
	std::vector<std::vector<int>> neighbors;
	float total_weight = 0;
	// Hot collision bounds store min/max directly. Four aligned lanes let the
	// BVH refit and overlap test use one SIMD operation per bound, like Jolt's
	// AABox traversal, without repeated Godot AABB position/size conversions.
	struct alignas(16) ContactBounds {
		float lower[4] = {}, upper[4] = {};
		ContactBounds() = default;
		explicit ContactBounds(const Vector3 &p) {
			for (int i = 0; i < 3; ++i) { lower[i] = upper[i] = p[i]; }
		}
		void expand(const Vector3 &p) {
#if defined(__SSE2__) || defined(_M_X64)
			const __m128 v = _mm_set_ps(0, p.z, p.y, p.x);
			_mm_store_ps(lower, _mm_min_ps(_mm_load_ps(lower), v));
			_mm_store_ps(upper, _mm_max_ps(_mm_load_ps(upper), v));
#else
			for (int i = 0; i < 3; ++i) {
				lower[i] = std::min(lower[i], float(p[i]));
				upper[i] = std::max(upper[i], float(p[i]));
			}
#endif
		}
		void grow(float r) {
#if defined(__SSE2__) || defined(_M_X64)
			const __m128 v = _mm_set_ps(0, r, r, r);
			_mm_store_ps(lower, _mm_sub_ps(_mm_load_ps(lower), v));
			_mm_store_ps(upper, _mm_add_ps(_mm_load_ps(upper), v));
#else
			for (int i = 0; i < 3; ++i) { lower[i] -= r; upper[i] += r; }
#endif
		}
		void merge(const ContactBounds &b) {
#if defined(__SSE2__) || defined(_M_X64)
			_mm_store_ps(lower, _mm_min_ps(_mm_load_ps(lower), _mm_load_ps(b.lower)));
			_mm_store_ps(upper, _mm_max_ps(_mm_load_ps(upper), _mm_load_ps(b.upper)));
#else
			for (int i = 0; i < 3; ++i) { lower[i] = std::min(lower[i], b.lower[i]); upper[i] = std::max(upper[i], b.upper[i]); }
#endif
		}
		bool intersects(const ContactBounds &b) const {
#if defined(__SSE2__) || defined(_M_X64)
			return _mm_movemask_ps(_mm_or_ps(_mm_cmpgt_ps(_mm_load_ps(lower), _mm_load_ps(b.upper)),
					_mm_cmpgt_ps(_mm_load_ps(b.lower), _mm_load_ps(upper)))) == 0;
#else
			return lower[0] <= b.upper[0] && upper[0] >= b.lower[0] && lower[1] <= b.upper[1] && upper[1] >= b.lower[1] && lower[2] <= b.upper[2] && upper[2] >= b.lower[2];
#endif
		}
		bool contains(const ContactBounds &b) const {
#if defined(__SSE2__) || defined(_M_X64)
			return _mm_movemask_ps(_mm_or_ps(_mm_cmpgt_ps(_mm_load_ps(lower), _mm_load_ps(b.lower)),
					_mm_cmpgt_ps(_mm_load_ps(b.upper), _mm_load_ps(upper)))) == 0;
#else
			for (int i = 0; i < 3; ++i) if (lower[i] > b.lower[i] || upper[i] < b.upper[i]) return false;
			return true;
#endif
		}
	};
	struct BVHNode {
		ContactBounds bounds;
		int left = -1, right = -1, begin = 0, count = 0;
	};
	std::vector<BVHNode> bvh;
	std::vector<ContactBounds> face_bounds;
	std::vector<ContactBounds> fitted_vertex_bounds;
	uint64_t bvh_revision = 0;
	std::vector<int> face_order, query_stack, candidates;
	struct CandidateBatch {
		ContactBounds bounds;
		uint64_t revision = 0;
		std::vector<int> faces;
	};
	// Keep separate candidates for each recent collider. Alternating self and
	// inter-body contacts must not evict every vertex's BVH query each pass.
	// Four LRU entries bound memory; eviction only repeats a query, never skips it.
	struct ContactCache {
		RID target;
		uint64_t last_used = 0;
		std::vector<CandidateBatch> vertices;
	};
	std::vector<ContactCache> contact_caches;
	uint64_t contact_cache_clock = 0;
	std::vector<RigidQueryResult> rigid_query_results;
	std::vector<AABB> rigid_bounds;
	void prepare_rigid_contacts();
	int build_bvh(int p_begin, int p_end);
	void refit_bvh();
	void query_faces(const ContactBounds &p_box);
	void query_faces(const ContactBounds &p_box, std::vector<int> &p_results, std::vector<int> &p_stack) const;
	float inverse_mass(int p_index) const;
	void rebuild_constraints();
	void group_constraints();
	void batch_constraints();
	void split_torn_seams();
	void check_tearing();
	void predict(float p_dt);
	void solve_constraints(float p_dt);
	void solve_batches(int p_begin, int p_end);
	bool collide_soft(Box3DSoftBody3D &p_other);
	bool self_contact_excluded(int p_particle, int p_face) const;
	void update_bounds();
	// Split of the former collide(): the query pass only reads the rigid world
	// and writes this particle's own result, the response pass applies velocity
	// impulses in particle order.
	void query_rigid(Particle &p, float p_dt, RigidQueryResult &r_result);
	void apply_rigid(Particle &p, const RigidQueryResult &p_result);
	// Worker body of the parallel query pass. Only touches particles in
	// [p_begin, p_end) and their own result slots.
	static void run_rigid_queries(int p_begin, int p_end, void *p_data);
	void respond_rigid(Particle &p, b3ShapeId p_shape, const Vector3 &p_normal, const Vector3 &p_point);
};
