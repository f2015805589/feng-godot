#[compute]
#version 450
// Screen cache ABI v2: one 8x8 receiver tile with local 2x2/full-pixel refinement.
// Diagnostic revision: partial stage-entry and size-guard counters v2.
// Body revision: view-depth plane gate, split edge dispatch ABI, sentinel handoff diagnostic.
// Import revision: post-size / pre-image-load partial-stage entry counters.
// Include fingerprint: post-empty-v2-revert; layout=C7E2242B48FBFFA9AB4338AA12968312AB9A2D2723202D8BFC0625C7917F4E3F partial=16EA03E6F33EB5FE291CB2B035C0A96D89020EDDE48EAD68F7AB71D2500ECEE3 body=F3E15C2BFA71B69C36E8D0A61C361F69440FDC07F491C1B541150C1DC37F959D header=20364DC7437B71C810859B53DDAFBDEB3642CC1B78C5A2F3BA5FBA77DCE85550.
#define CLV_SCREEN_STAGE_FAST 1
#include "magic_gi_clv_screen_header.glslinc"
#include "magic_gi_clv_approx_contract.glslinc"
#include "magic_gi_clv_debug_sample.glslinc"
#include "magic_gi_clv_screen_body.glslinc"
