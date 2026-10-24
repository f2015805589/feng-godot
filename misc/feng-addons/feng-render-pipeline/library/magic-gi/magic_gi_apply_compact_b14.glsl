#[compute]
#version 450
// Reimport after CLV approximate patch-prefilter revision 1.
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_ballot : require
#define MAGIC_GI_PRT_COMPACT_QUEUE_VARIANT 1
#include "magic_gi_apply_shared_head.glslinc"
#include "magic_gi_prt_queue_append.glslinc"
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
#define sample_clv sample_clv_r7
// Reimport this parent when the CLV sampler include changes; the helper keeps
// explicit toroidal seam gathers and filters only interior radiance values.
#include "magic_gi_clv_sample.glslinc"
#undef sample_clv
#include "magic_gi_layout14_node_visibility_helpers.glslinc"
#include "magic_gi_clv_field_b14_sample.glslinc"
#define MAGIC_GI_GATHER_DIAGNOSTIC_OUTPUTS
#define MAGIC_GI_GATHER_WORK_OUTPUTS
#include "magic_gi_gather.glslinc"

#define sample_clv(world, normal, receiver_triangle, receiver_patch, secondary, primary, cache_weight, complete_support, cache_blend_weight) sample_clv_layout14_b(pixel, world, normal, receiver_triangle, receiver_patch, secondary, primary, cache_weight, complete_support, cache_blend_weight)
#include "magic_gi_apply_shared_tail.glslinc"
#undef sample_clv
