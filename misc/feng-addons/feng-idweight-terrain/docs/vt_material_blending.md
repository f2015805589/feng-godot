# VT material blending

AVT/SVT material arrays use linear filtering. Packed R16 IDs and indirection entries
use nearest reads so interpolation preserves material identities.

For output pixels no larger than the source-ID spacing, production supplies a world-aligned
corner grid with its own origin/spacing. The bake shader derives triangle barycentric weights
on that grid while material texture footprints use the output-page texel size.
AVT and offline SVT share the same source-rectangle helper and staging layout.
Larger pixels use the existing minified-source path.

The SVT source signature includes the corner-interpolation revision. Stale cells must
rebake, through Auto Bake or manual Bake SVT.

## Historical regression evidence

GPU regression: `vt_adaptive_runner.py --blend` compares a two-material gradient
against direct shading and replaces source albedo bindings after caching to rule
out direct-shader fallback. The old DLL in `terrain-vtadaptive-ir9jhz9y` fails
8 sample checks (`terrain-vtadaptive-by60z00q`). The corrected DLL passes AVT and
SVT gradient checks and controls with no errors (`terrain-vtadaptive-ahhnupgn`).
This tests flat triangle gradients; it does not establish pixel-identical output
for every slope, triplanar projection or low-density SVT configuration.
