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
#define sample_clv sample_clv_r7
// Reimport this parent when the CLV sampler include changes; the helper keeps
// explicit toroidal seam gathers and filters only interior radiance values.
#include "magic_gi_clv_sample.glslinc"
#undef sample_clv
#include "magic_gi_layout14_node_visibility_helpers.glslinc"
#include "magic_gi_clv_field_b14_sample.glslinc"
#define MAGIC_GI_GATHER_DIAGNOSTIC_OUTPUTS
#define MAGIC_GI_GATHER_WORK_OUTPUTS
// Same raw 18-vec4/probe signal used by the Layout14 field fill; B host binds
// directional.raw_lighting here only while the Layout14 B root is active.
layout(set = 0, binding = 35, std430) readonly buffer Layout14RawDirectionalSource {
	vec4 values[];
} layout14_raw_directional_source;
#define MAGIC_GI_RAW_SOURCE_SH
#define MAGIC_GI_DIRECTIONAL_SH_COEFFICIENT(probe_index, coefficient_index) \
	layout14_raw_directional_source.values[(probe_index) * 18 + (coefficient_index)]
#include "magic_gi_gather.glslinc"
#undef MAGIC_GI_DIRECTIONAL_SH_COEFFICIENT
#undef MAGIC_GI_RAW_SOURCE_SH

#define MAGIC_GI_LAYOUT14_B_CACHE_STAGE_ALLOWED (!prt_stage_active || prt_v2_cache_stage)
#define sample_clv(world, normal, receiver_triangle, receiver_patch, secondary, primary, cache_weight, complete_support, cache_blend_weight) sample_clv_layout14_b(pixel, world, normal, receiver_triangle, receiver_patch, secondary, primary, cache_weight, complete_support, cache_blend_weight)
#include "magic_gi_apply_shared_tail.glslinc"
#undef sample_clv
#undef MAGIC_GI_LAYOUT14_B_CACHE_STAGE_ALLOWED
