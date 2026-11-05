#[compute]
#version 450
// Float32 cascade blending, with independent OLV lighting domains.
#include "magic_gi_clv_blend_bounds.glslinc"
#include "magic_gi_clv_premix_body.glslinc"
