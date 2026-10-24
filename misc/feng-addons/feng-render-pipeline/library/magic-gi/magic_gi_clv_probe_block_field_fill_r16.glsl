#[compute]
#version 450
#define MAGIC_GI_CLV_BAKED_SH_RGBA16F
// Scaled half-float layout17 producer: exact SH9-to-irradiance-tensor field encoding (codec tag 16).
// Host dispatch is gated to format-v6 data with validated exact-BVH visibility.
#include "magic_gi_clv_probe_block_field_fill_declarations.glslinc"
#include "magic_gi_visibility.glslinc"
#define MAGIC_INDEX_BINDING 15
#include "magic_gi_index.glslinc"
#define MAGIC_CLUSTER_BINDING 16
#include "magic_gi_probe_clusters.glslinc"
#include "magic_gi_clv_probe_visibility.glslinc"
#include "magic_gi_clv_baked_sh_layout.glslinc"
#include "magic_gi_sh.glslinc"
#include "magic_gi_clv_probe_block_field_fill_body.glslinc"
