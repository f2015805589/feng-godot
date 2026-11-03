#include "soft_tasks.h"
#include "physics_world.h"
#include "scheduler.h"
#include "platform.h"
#if defined(B3_CPU_X86_X64)
#include <immintrin.h>
#endif

typedef struct fengSoftRange {
	int begin, end;
	fengSoftRangeTask *task;
	void *context;
} fengSoftRange;

static void fengRunSoftRange(void *context) {
	fengSoftRange *range = context;
	range->task(range->begin, range->end, range->context);
}

void fengSoftParallelFor(b3WorldId id, int count, int minimum_batch, fengSoftRangeTask *task, void *context) {
	if (count <= 0) return;
	b3World *world = b3GetWorldFromId(id);
	B3_ASSERT(!world->locked);
	int jobs = b3MinInt(world->workerCount, b3MinInt(32, count / b3MaxInt(1, minimum_batch)));
	if (jobs <= 1) {
		task(0, count, context);
		return;
	}
	// The rigid step and every earlier addon batch have finished. Reset the
	// bounded scheduler slots, reusing the workers rather than making a 2nd pool.
	if (world->scheduler != NULL) b3ResetScheduler(world->scheduler);
	fengSoftRange ranges[32];
	void *handles[32];
	for (int i = 0; i < jobs; ++i) {
		ranges[i] = (fengSoftRange){count * i / jobs, count * (i + 1) / jobs, task, context};
		if (i + 1 < jobs) handles[i] = world->enqueueTaskFcn(fengRunSoftRange, ranges + i, world->userTaskContext, "soft body");
	}
	fengRunSoftRange(ranges + jobs - 1);
	for (int i = 0; i + 1 < jobs; ++i) world->finishTaskFcn(handles[i], world->userTaskContext);
}

typedef struct fengSoftIterations {
	b3AtomicInt next_group, finished_groups, iteration;
	int groups, iterations;
	fengSoftRangeTask *group_task;
	fengSoftFinishTask *finish;
	void *context;
} fengSoftIterations;

static void fengRunSoftIterations(void *data) {
	fengSoftIterations *work = data;
	int idle = 0;
	while (b3AtomicLoadInt(&work->iteration) < work->iterations) {
		int group = b3AtomicLoadInt(&work->next_group);
		if (group < work->groups && b3AtomicCompareExchangeInt(&work->next_group, group, group + 1)) {
			idle = 0;
			work->group_task(group, group + 1, work->context);
			if (b3AtomicFetchAddInt(&work->finished_groups, 1) + 1 == work->groups) {
				// No other task can still write this iteration's vertices. The
				// last group executes the shared tail, regardless of worker ID.
				work->finish(work->context);
				b3AtomicStoreInt(&work->finished_groups, 0);
				int iteration = b3AtomicLoadInt(&work->iteration) + 1;
				b3AtomicStoreInt(&work->iteration, iteration);
				// Publishing the next group index is the release barrier for all
				// tail writes. At completion leave it closed (groups exhausted).
				if (iteration < work->iterations) b3AtomicStoreInt(&work->next_group, 0);
			}
		} else {
#if defined(B3_CPU_X86_X64)
			_mm_pause();
#endif
			if (++idle == 64) { b3Yield(); idle = 0; }
		}
	}
}

void fengSoftParallelIterations(b3WorldId id, int groups, int iterations,
		fengSoftRangeTask *group_task, fengSoftFinishTask *finish, void *context) {
	if (groups <= 0 || iterations <= 0) return;
	b3World *world = b3GetWorldFromId(id);
	B3_ASSERT(!world->locked);
	int jobs = b3MinInt(world->workerCount, b3MinInt(32, groups));
	if (jobs <= 1) {
		for (int iteration = 0; iteration < iterations; ++iteration) {
			group_task(0, groups, context);
			finish(context);
		}
		return;
	}
	if (world->scheduler != NULL) b3ResetScheduler(world->scheduler);
	fengSoftIterations work = {0};
	work.groups = groups;
	work.iterations = iterations;
	work.group_task = group_task;
	work.finish = finish;
	work.context = context;
	void *handles[32];
	for (int i = 0; i + 1 < jobs; ++i) {
		handles[i] = world->enqueueTaskFcn(fengRunSoftIterations, &work, world->userTaskContext, "soft constraints");
	}
	fengRunSoftIterations(&work);
	for (int i = 0; i + 1 < jobs; ++i) world->finishTaskFcn(handles[i], world->userTaskContext);
}
