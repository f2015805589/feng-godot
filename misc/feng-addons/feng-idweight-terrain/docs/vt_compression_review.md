# VT page compression and fast-view changes

## Normal-space contract

Authoring normal maps are decoded per material by `idweight_decode_normal()`, including
that material's normal strength. Projection and material weights are applied during
`surface_bake_accumulate_layer()`. The canonical baked page contains the normalized,
signed **world-space blended normal** in RGB and roughness in A. It is not a copy of
one source normal map. Existing disk cells and uncompressed staging retain this layout.

At runtime a compressed normal page stores an octahedral encoding of the full sphere:
BC7 uses RG; BC3 uses AG. Both retain negative world-space components, including negative
Y. Hardware decompresses BC blocks; terrain sampling reconstructs the world-space vector
before virtual-mip/page-transition blending and GBuffer output. Deferred lighting still
decodes the GBuffer and evaluates the BxDF. Moving page reconstruction to BxDF would
require a different GBuffer contract and would not fix blending encoded page normals.

The final material output no longer applies the already-consumed source normal strength
a second time. The independent distant-normal amplifier remains.

## Settings and storage

AVT and SVT each expose one compression setting: Uncompressed / BC7 / BC3. Every
physical material array of that tier uses the selected block codec, including the
parameter array. BC7 normals store octahedral coordinates in RG; BC3 normals store
them in AG, but the physical format is ordinary BC3 for all three arrays. There is
no public BC5, BC3N, Auto, or independent diffuse/normal selector.

Historical diffuse properties remain loadable aliases. Historical normal overrides
are accepted but ignored so they cannot override the tier setting regardless of
resource property order. New scenes serialize only the unified tier property.

The existing three-array layout and generated AO are retained. Raw staging and disk
cells retain signed world normals plus roughness. Compressed parameters retain half
normal strength in R, AO parameters in G/B, and validity plus roughness in A. Metadata
and RIDs publish together; export reconstructs the canonical disk layout. No extra
arrays or encoding dispatches are introduced by unifying the codec setting.

## Encoder corrections

* BC3 alpha indices occupy 48 bits. The previous single 32-bit accumulator lost tail
  indices. They are now written across both output words.
* Signed baked normals must not be clamped directly into UNORM color blocks. They now
  use the normal-specific layout above.
* Endpoint fitting uses a bounded farthest-pair fit instead of the componentwise box
  diagonal, which collapses anti-correlated colors.
* BC7 selects between mode 6 and mode 5 by quantized error. Mode 5 has independent
  color/alpha indices, preserving height or roughness independent of RGB. This is a
  bounded runtime encoder, not an exhaustive offline BC7 quality search.

BC3, BC5, and BC7 all use 16 bytes per 4×4 block. BC3 does not halve BC7 storage.
The layout follows Microsoft's [block compression documentation](https://learn.microsoft.com/en-us/windows/win32/direct3d10/d3d10-graphics-programming-guide-resources-block-compression)
and [BC7 mode reference](https://learn.microsoft.com/en-us/windows/win32/direct3d11/bc7-format-mode-reference).

## Motion and scheduling

Snap turns and discontinuous displacement invalidate stale prediction and discard old
retained production requests when a replacement plan installs. Existing resident pages
remain available as fallback. A spatial guard refreshes plans after substantial movement
even when the normal debounce has not expired. Page demand still uses predicted motion,
but production urgency uses the actual eye position, protecting current near detail from
being outranked by predicted future detail. Page budgets and cache sizes are unchanged.

The retained-request table mixes high coordinate bits before masking its power-of-two
capacity; mip-aligned coordinates otherwise create long linear-probe clusters.

## Validation before the unified-setting follow-up

Real D3D12 GPU tests passed: independent block decode, BC3 page alpha export, AVT/SVT
independent diffuse/normal combinations, existing compressed rendering/production-rate
tests, snap/displacement debounce, and lost-page recovery. Block tests use the engine's
independent BC decompressor. Tested negative-normal angular errors were below 0.7° for
BC5 and 1.6° for BC3N; these are fixture results, not universal bounds.

The normal rendering fixture's AVT mean absolute RGB error against raw was 0.00179
(BC5) and 0.00219 (BC3N); diffuse remained identical when only normals were compressed.
Tests cover normal strength 1.8 and independent roughness. GPU readbacks belong to the
tests/export path; runtime D3D12 encoding still reports zero readbacks.

### Project measurement

Isolated copy of `F:/godot/project/test-1`, `render/test.tscn`, FRP/D3D12, RTX 3080 Ti,
1920×1080, debug extension, 1024 physical pages, 16-page production budget. The camera
repeated the same 240-tick moving path; averages below use repeated-motion windows 2–4,
excluding startup, first traversal, and the final stationary window. Measurements were
run serially without compilation or other GPU tests. No timing readback screenshots
were taken. Old/new order was reversed to check drift.

| Run | Terrain VT CPU monitor | Whole viewport GPU |
| --- | ---: | ---: |
| Before, initial run | 0.687 ms | 0.904 ms |
| Final implementation | 0.672 ms | 1.005 ms |
| Before, repeated after final | 0.675 ms | 0.915 ms |

CPU is effectively unchanged at this precision; the first intermediate implementation
was slower (0.766 ms) before fixing retained-table hashing. Correct compressed normals
and the improved encoder cost approximately 0.09–0.10 ms of viewport GPU time in this
fixture. This is not a claim of zero GPU overhead or a measurement of the encoder alone.
All runs produced the same cumulative page count at corresponding windows and reported
zero runtime encoding readbacks. Logs are under `bin/terrain-project-lifetime-ke6fwkn0/`
as `compression_perf_before.log`, `compression_perf_final.log`, and
`compression_perf_before_repeat.log`.

The final 180° near-arrival diagnostic captured 96 frames in the same project copy.
Mean absolute RGB difference from its settled reference fell from 0.00407 to 0.00018;
the largest fraction above the diagnostic's difference threshold was 0.0174%.
Settled missing pages, pending pages, active fades, and fade queue were all zero.
This screenshot/readback diagnostic is not a real-time latency measurement and the
scene is dark, so it does not establish that all page updates are visually imperceptible.
Artifacts: `bin/terrain-near-arrival-run-11bf_ooj/near_arrival_output/`.
Both Windows debug and release extension builds completed successfully.

Arbitrary instant movement into uncached content cannot be guaranteed invisible with
a finite page budget. These changes reduce obsolete work and prioritize visible near
detail; they do not make the cache unlimited.

## Unified-setting follow-up

The normal rendering regression now checks one editor/storage property per tier,
ignores legacy normal overrides, asserts matching physical diffuse/normal/parameter
formats, and compares raw/BC7/BC3 albedo, normals, and roughness for both AVT and SVT.
Earlier performance numbers above describe the previous independent-codec implementation,
not a fresh measurement of the unified BC7 normal format.

Follow-up validation passed on D3D12: unified normal/roughness rendering matrix and
compressed rendering/production-rate regression; Windows debug and release builds passed.
Artifacts: `bin/terrain-vtnormal-compression-gwyscxzj/` and
`bin/terrain-vtcompress-render-7phsqa_g/`.
