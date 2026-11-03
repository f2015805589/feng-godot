#pragma once

// Cached per process from the platform's CPU topology, clamped to [1, B3_MAX_WORKERS].
// Windows counts physical cores (including hybrid efficiency cores), not SMT threads.
// Includes the calling thread; this is a topology default, not a runtime autotuner.
int box3d_default_worker_count();
