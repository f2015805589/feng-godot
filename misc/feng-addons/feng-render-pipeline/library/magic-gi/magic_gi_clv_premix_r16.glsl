#[compute]
#version 450
// Float16 cascade blending, with independent OLV lighting domains.
#define CLV_HALF_OUTPUT
#include "magic_gi_clv_blend_bounds.glslinc"
#include "magic_gi_clv_premix_body.glslinc"
