#[compute]
#version 450
// R32F layout17 producer for isolated baked-SH fields (codec tag 32, scale 1).
// Legacy/live PRT remains on the original 32-byte JobRecord shader.
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
