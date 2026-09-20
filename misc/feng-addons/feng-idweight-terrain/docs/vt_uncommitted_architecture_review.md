# Uncommitted terrain architecture review

Scope: the terrain addon's tracked diff and new source/test files, including native
VT planning, production, compression, shader sampling, diagnostics, editor resource
observation, and lifecycle fixes. This is a review of the working tree, not just the
latest unified-compression change.

## Assessment

The main boundaries are sound: immutable planner input separates worker selection
from node state; the producer owns GPU page storage; demand submits requests rather
than encoding textures; bounded arrival queue and request-priority helpers are
independent of Godot nodes; editor signal cleanup stays with the object that owns
the observation. A shared VT state aggregate remains a coordination point rather
than a fully encapsulated service, so file separation alone is not proof of complete
decoupling. No broad class hierarchy rewrite is warranted by these changes.

The review identified smaller contracts that should have one owner:

* The public tier setting was unified, but the node still stored two immutable Auto
  normal settings and carried a separate update branch. These states and setup calls
  are removed. Legacy setters remain side-effect-free compatibility inputs; getters
  preserve Auto and diagnostics preserve their historical keys.
* Normal/parameter codec selection was repeated in resolution, resource allocation,
  and encode dispatch. Shared inline helpers own those mappings. Backend explicit
  channel APIs retain their current behavior; this is not another codec-policy change.
* Plan-key readers depended on anonymous array offsets, and motion reset and spatial
  refresh independently defined the same distance threshold. Named key layout and
  a shared inline threshold preserve the fixed-size representation and existing math.
* The visibility bound contained a duplicated nested condition. Removing it preserves
  the calculation and both anisotropic/non-anisotropic branches.
* The standalone priority regression was not part of the default test build. It now
  builds alongside the addressing/sampling/arrival contract test.

## Allocation and compatibility constraints

No new per-frame script callbacks, RefCounted resources, dictionaries, dynamic
containers, or heap-backed policy objects are introduced. Plan keys remain fixed-size
values; mapping and threshold helpers inline scalar operations. Existing page budgets,
cache capacities, queue ownership, shader layouts, compression choices, and disk data
formats remain unchanged. Editor observation code is retained: its signal lifetimes
are different responsibilities, not duplicate logic requiring a generic manager.

## Integration validation

Windows debug and release builds passed. Standalone tests passed for addressing,
100,000 arrival-queue churn operations, 20,000 sampled Jacobian bounds, and request
priority ordering. Real D3D12 regressions passed for unified raw/BC7/BC3 rendering
and format selection, snap/displacement plan refresh with slow-turn debounce, and
grazing/rotated anisotropic sampling.

GPU regression artifacts:

* `bin/terrain-vtnormal-compression-_i40sir3/`
* `bin/terrain-snap-turn-79yvz3nm/`
* `bin/terrain-vtaniso-nleryx8x/`

The performance baseline is the unified-compression DLL from immediately before this
architecture cleanup, saved as `bin/terrain-project-lifetime-ke6fwkn0/architecture_before.dll`.
The copied test-1 project uses the existing 1920×1080 FRP/D3D12 repeated-motion script.
Performance runs are serial, with no concurrent compilation or GPU regressions.

The first comparison measured VT CPU 0.739 → 0.754 ms and viewport GPU
0.981 → 0.937 ms (mean of repeated-motion windows 2–4, startup excluded).
Reverse-order runs measured intermediate/new 0.756 ms CPU versus old 0.717 ms;
GPU was 0.803 versus 0.810 ms. These small CPU differences do not establish
zero overhead. The final implementation therefore retains the original sequential
plan-key writer, with only section boundaries named by the shared layout contract.
Its snap/displacement regression was rerun successfully in
`bin/terrain-snap-turn-jr8_wphq/`; debug and release builds were refreshed.

The first three runs had identical per-window object counts
`2728, 3077, 3116, 2987, 3059, 2963`. The reversed old run differed by 24 objects
in one intermediate window and settled at the same 2963. This supports bounded
object lifetime, not a claim that async frame-by-frame counts are always identical.
No new allocation operations were added to the runtime hot path.

Final sequential-writer run: VT CPU 0.678 ms, viewport GPU 1.015 ms;
object counts [2728, 3077, 3116, 2987, 3059, 2963]. CPU was below both baseline runs. GPU timings varied
across runs; shaders, dispatch count and physical formats were not changed by this
cleanup. Raw logs use the `architecture_perf_*.log` prefix in the copied project.
