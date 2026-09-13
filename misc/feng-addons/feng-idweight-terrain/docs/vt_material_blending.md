# VT material blending correction

AVT and SVT material arrays already use linear filtering. Packed R16 IDs and
indirection entries intentionally use nearest reads; interpolating packed IDs
would corrupt material identities.

The bake shader previously computed triangle weights from output pixel positions.
Their fractional coordinates were always (0.5, 0.5), even when dozens of output
pixels covered one source ID cell. Nearest-resampled IDs consequently produced
material blocks instead of the direct shader's triangle gradient.

For output pixels no larger than the source ID spacing, production now supplies a
world-aligned corner grid and its origin/spacing separately from the output page.
The shader computes barycentric weights in that grid, while material texture
footprints retain the output texel size. Only the needed source rectangle is
sampled, then copied into the existing staging allocation. AVT and offline SVT
use the same helper. The existing minified source path remains for pixels larger
than the source spacing; this change is not a new anisotropic/minification filter.

The SVT source signature now includes the corner-interpolation revision. Existing
cell caches are treated as stale and must be rebaked (automatically when auto
bake is enabled, otherwise through Bake SVT).

GPU regression: `vt_adaptive_runner.py --blend` compares a two-material gradient
against direct shading and replaces source albedo bindings after caching to rule
out direct-shader fallback. The old DLL in `terrain-vtadaptive-ir9jhz9y` fails
8 sample checks (`terrain-vtadaptive-by60z00q`). The corrected DLL passes AVT and
SVT gradient checks and controls with no errors (`terrain-vtadaptive-ahhnupgn`).
This tests flat triangle gradients; it does not establish pixel-identical output
for every slope, triplanar projection or low-density SVT configuration.
