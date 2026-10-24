#[compute]
#version 450
// Reimport after CLV approximate patch-prefilter revision 1.
#define MAGIC_GI_PRT_COMPACT_QUEUE_VARIANT 0
#include "magic_gi_apply_shared_head.glslinc"
#include "magic_gi_clv_layout.glslinc"

#define MAGIC_INDEX_BINDING 22
#define MAGIC_CLUSTER_BINDING 24
#define MAGIC_GI_USE_PROBE_NEIGHBOR_MASK
#define MAGIC_GI_USE_PROBE_NEIGHBOR_CELL_LIST
#include "magic_gi_index.glslinc"
#include "magic_gi_probe_clusters.glslinc"

#include "magic_gi_visibility.glslinc"
#include "magic_gi_sh.glslinc"
// Keep shared helpers top-level; the Godot GLSL importer does not expand nested includes.
#include "magic_gi_clv_probe_visibility.glslinc"
#include "magic_gi_clv_approx_contract.glslinc"
#include "magic_gi_clv_field_layout.glslinc"
// Reimport this parent when the CLV sampler include changes; the helper keeps
// explicit toroidal seam gathers and filters only interior radiance values.
#include "magic_gi_clv_sample.glslinc"
#define MAGIC_GI_GATHER_DIAGNOSTIC_OUTPUTS
#define MAGIC_GI_GATHER_WORK_OUTPUTS
#include "magic_gi_gather.glslinc"

#include "magic_gi_apply_shared_tail.glslinc"
