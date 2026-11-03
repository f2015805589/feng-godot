#pragma once
#include <box3d/id.h>

#ifdef __cplusplus
extern "C" {
#endif
// Synchronous addon work on the world's existing workers, after b3World_Step.
// Callbacks must only write disjoint addon memory; never mutate the rigid world.
typedef void fengSoftRangeTask(int begin, int end, void *context);
void fengSoftParallelFor(b3WorldId world, int count, int minimum_batch, fengSoftRangeTask *task, void *context);
// Keep workers inside a multi-iteration solve. Each iteration finishes all
// disjoint groups, then calls finish once before publishing the next iteration.
// The callbacks must not dispatch nested jobs. Works with inline enqueuers too.
typedef void fengSoftFinishTask(void *context);
void fengSoftParallelIterations(b3WorldId world, int groups, int iterations,
		fengSoftRangeTask *group_task, fengSoftFinishTask *finish, void *context);
#ifdef __cplusplus
}
#endif
