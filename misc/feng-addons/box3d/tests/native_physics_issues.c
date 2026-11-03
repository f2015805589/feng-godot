// Focused checks for upstream physics issues using the same linked core as the addon.
#include <box3d/box3d.h>
#include <box3d/collision.h>
#include "physics_world.h"
#include "contact.h"
#include "platform.h"
#include "soft_tasks.h"
#include <math.h>
#include <stdio.h>
#ifdef _WIN32
#include <windows.h>
#endif

static int failures;
static void check(bool ok, const char *message) {
	printf("%s %s\n", ok ? "PASS" : "FAIL", message);
	if (!ok) ++failures;
}

static b3BodyId box(b3WorldId world, b3BodyType type, b3Pos position, b3Vec3 extent, b3ShapeId *shape) {
	b3BodyDef bd = b3DefaultBodyDef();
	bd.type = type;
	bd.position = position;
	bd.enableSleep = false;
	b3BodyId body = b3CreateBody(world, &bd);
	b3ShapeDef sd = b3DefaultShapeDef();
	b3BoxHull hull = b3MakeBoxHull(extent.x, extent.y, extent.z);
	*shape = b3CreateHullShape(body, &sd, &hull.base);
	return body;
}

static b3Contact *first_contact(b3WorldId id) {
	b3World *world = b3GetWorldFromId(id);
	for (int i = 0; i < world->contacts.count; ++i) {
		b3Contact *c = world->contacts.data + i;
		if (c->contactId == i && c->manifoldCount > 0) return c;
	}
	return NULL;
}

static void material_recycling(void) {
	b3WorldDef wd = b3DefaultWorldDef();
	b3WorldId id = b3CreateWorld(&wd);
	b3ShapeId floor, shape;
	box(id, b3_staticBody, (b3Pos){0,-0.1f,0}, (b3Vec3){5,0.1f,5}, &floor);
	b3BodyId body = box(id, b3_dynamicBody, (b3Pos){0,0.5f,0}, (b3Vec3){0.5f,0.5f,0.5f}, &shape);
	for (int i = 0; i < 90; ++i) b3World_Step(id, 1.0f/60, 4);
	b3Contact *contact = first_contact(id);
	check(contact != NULL, "material fixture has persistent contact");
	if (contact) {
		b3Shape_SetFriction(floor, 0.0f);
		check(!(contact->flags & b3_relativeTransformValid), "friction invalidates cached contact material");
		b3World_Step(id, 1.0f/60, 4);
		contact = first_contact(id);
		check(contact && contact->friction == 0, "recycled contact updates zero friction");
		b3SurfaceMaterial material = b3Shape_GetSurfaceMaterial(floor);
		material.friction = 1.0f;
		material.tangentVelocity = (b3Vec3){2,0,0};
		b3Shape_SetSurfaceMaterial(floor, material);
		b3World_Step(id, 1.0f/60, 4);
		contact = first_contact(id);
		check(contact && fabsf(contact->tangentVelocity.x) > 1.9f, "stationary conveyor material refreshes");
		b3Shape_SetRestitution(shape, 0.8f);
		check(contact && !(contact->flags & b3_relativeTransformValid), "restitution invalidates cache");
		b3Body_SetAwake(body, false);
		material.friction = 0.4f;
		b3Shape_SetSurfaceMaterial(floor, material);
		check(b3Body_IsAwake(body), "editing supporting material wakes sleeping contact");
	}
	b3DestroyWorld(id);
}

typedef struct CastWitness { float fraction; b3Vec3 normal; bool hit; } CastWitness;
static float cast_witness(b3ShapeId shape, b3Pos point, b3Vec3 normal, float fraction, uint64_t material, int triangle, int child, void *context) {
	(void)shape; (void)point; (void)material; (void)triangle; (void)child;
	CastWitness *witness = context;
	*witness = (CastWitness){fraction, normal, true};
	return fraction;
}
static void initial_contact_normal(void) {
	b3WorldDef wd = b3DefaultWorldDef();
	b3WorldId world = b3CreateWorld(&wd);
	b3ShapeId floor;
	box(world, b3_staticBody, (b3Pos){0,-0.1f,0}, (b3Vec3){5,0.1f,5}, &floor);
	b3Vec3 center = b3Vec3_zero;
	b3ShapeProxy proxy = { .points = &center, .radius = 0.025f, .count = 1 };
	CastWitness result = {0};
	b3World_CastShape(world, (b3Pos){0,0.0201f,0}, &proxy, (b3Vec3){0,0.1f,0}, b3DefaultQueryFilter(), cast_witness, &result);
	check(result.hit && result.fraction == 0 && result.normal.y > 0.99f, "slop-region cast preserves separating normal for departure filtering");
	b3DestroyWorld(world);
}

static void dense_mesh(void) {
	b3WorldDef wd = b3DefaultWorldDef();
	b3WorldId id = b3CreateWorld(&wd);
	b3BodyDef bd = b3DefaultBodyDef();
	b3BodyId floor = b3CreateBody(id, &bd);
	b3MeshData *mesh = b3CreateGridMesh(33, 33, 0.02f, 0, true);
	int expected = mesh->triangleCount;
	b3ShapeDef sd = b3DefaultShapeDef();
	b3CreateMeshShape(floor, &sd, mesh, (b3Vec3){1,1,1});
	b3ShapeId shape;
	b3BodyId body = box(id, b3_dynamicBody, (b3Pos){0,0.1f,0}, (b3Vec3){0.8f,0.1f,0.8f}, &shape);
	for (int i = 0; i < 30; ++i) b3World_Step(id, 1.0f/60, 4);
	b3Contact *contact = first_contact(id);
	int count = contact && (contact->flags & b3_simMeshContact) ? contact->meshContact.triangleCache.count : 0;
	printf("dense_mesh cached=%d expected=%d\n", count, expected);
	check(count == expected && count > 256, "dense mesh retains every overlapping triangle");
	check(b3Body_GetPosition(body).y > 0.08f, "dense mesh supports resting box");
	b3DestroyWorld(id);
	b3DestroyMesh(mesh);
}

typedef struct IterationWitness {
	int round, values[31];
	b3AtomicInt errors;
} IterationWitness;

static void iteration_group(int begin, int end, void *context) {
	IterationWitness *w = context;
	for (int i = begin; i < end; ++i) {
		if (w->values[i] != w->round) b3AtomicFetchAddInt(&w->errors, 1);
		// Vary task duration so the tail cannot accidentally rely on worker order.
		if ((i + w->round) % 7 == 0) b3Yield();
		w->values[i] = w->round + 1;
	}
}

static void iteration_tail(void *context) {
	IterationWitness *w = context;
	for (int i = 0; i < 31; ++i) {
		if (w->values[i] != w->round + 1) b3AtomicFetchAddInt(&w->errors, 1);
	}
	++w->round;
}

static void *inline_enqueue(b3TaskCallback *task, void *context, void *user, const char *name) {
	(void)user; (void)name;
	task(context);
	return NULL;
}
static void inline_finish(void *handle, void *user) { (void)handle; (void)user; }

static void iterative_soft_jobs(void) {
	const int workers[] = { 1, 2, 4, 8, 4 };
	for (int mode = 0; mode < 5; ++mode) {
		b3WorldDef wd = b3DefaultWorldDef();
		wd.workerCount = workers[mode];
		if (mode == 4) { wd.enqueueTask = inline_enqueue; wd.finishTask = inline_finish; }
		b3WorldId world = b3CreateWorld(&wd);
		bool ok = true;
		for (int repeat = 0; repeat < 32; ++repeat) {
			IterationWitness witness = {0};
			int iterations = repeat % 2 == 0 ? 1 : 100;
			fengSoftParallelIterations(world, 31, iterations, iteration_group, iteration_tail, &witness);
			ok &= witness.round == iterations && b3AtomicLoadInt(&witness.errors) == 0;
		}
		printf("soft_iterations workers=%d inline=%d\n", workers[mode], mode == 4);
		check(ok, "all constraint groups finish before each shared tail, including inline workers");
		b3DestroyWorld(world);
	}
}

int main(void) {
	setvbuf(stdout, NULL, _IONBF, 0);
#ifdef _WIN32
	// A failing automated test must exit instead of showing a desktop dialog.
	SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
#endif
	puts("material fixture");
	material_recycling();
	dense_mesh();
	initial_contact_normal();
	iterative_soft_jobs();
	printf("RESULT: %s\n", failures ? "FAIL" : "PASS");
	return failures != 0;
}
