#[compute]
#version 450
#define CLV_HALF_OUTPUT
#define CLV_PARTITION_INPUT
#include "magic_gi_sh4_tensor.glslinc"
#include "magic_gi_clv_transfer_relight_body.glslinc"
