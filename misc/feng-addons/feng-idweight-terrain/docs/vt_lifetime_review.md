# VT lifetime and page-arrival review

## Reproduction and measurement

The reported project is `F:/godot/project/test-1`, scene `render/test.tscn`,
using FRP / D3D12. `native/tests/vt_project_lifetime_probe.py` copies the project
and current addons into an isolated fixture before importing or running it.
It does not write to the source project. The probe currently supplies the test
project's FRP autoload and `render/test_compositor.tres` explicitly.

The baseline sampled six windows of 240 physics frames: initially stationary,
four identical camera traversals, then stationary again. VT CPU means in ms:
`0.941, 0.831, 0.768, 0.768, 0.825, 0.202`. Static memory was approximately
`548, 591, 592, 623, 544, 527 MiB`; object counts also fell in the final windows.
This run did **not** reproduce sustained CPU or memory growth. It is a bounded
reproduction, not proof that every editor workload is leak-free.

`get_vt_settings()` reports milliseconds. Custom `Performance` monitors registered
as `MONITOR_TYPE_TIME` must instead return seconds: the editor multiplies by 1000
when displaying milliseconds. The old terrain callbacks returned milliseconds,
making the displayed CPU time 1000 times too large. `vt_cpu_peak` is the maximum
since initialization, so a rising peak alone does not establish rising frame cost.
The monitor fix changes neither scheduling nor the diagnostic dictionary's units.

## Page-arrival contracts

The page fade owns its state in `terrain_3d_vt_state.h` and behavior in
`terrain_3d_vt_fade.cpp`. Pool teardown explicitly resets this state. The independent
`terrain_vt_arrival_queue.h` owns only a slot-indexed FIFO, without Godot or terrain
dependencies. One physical slot has at most one queue record; remove, append and
pop are O(1). Storage is bounded by the pool size instead of retaining an ever
longer consumed prefix when arrivals keep the old vector queue nonempty.

A replaced slot publishes zero blend weight while WAITING or ARMED. Its countdown
starts after the first released zero-weight frame. Changing a positive fade
duration rescales remaining ticks; shortening the duration cannot wrap a negative
blend byte into an unrelated unsigned value. Disabling fades or rebuilding the
pool discards obsolete arrivals.

The material shader respects the fade of a parent that arrives with its child.
It carries the unresolved contribution toward a settled ancestor. Additional
ancestor samples occur only during overlapping arrivals; the settled sampling
path remains unchanged. This addresses a concrete source of page-grid flashes,
not all possible texture discontinuities or the unavoidable initial loading of
a hierarchy without resident ancestors.

## Plugin ownership

GDScript resource lifetime here is reference counting plus explicit Node/RID
ownership, not a tracing garbage collector that periodically sweeps the scene.
The audit found stale signal subscriptions and retained cache entries:

* The terrain editor and asset dock now unbind the previous terrain/assets source
  on selection changes, scene changes and shutdown. Dock reparenting restores the
  current subscriptions on re-entry.
* List containers remove old asset ID subscriptions on rebuild. Entries disconnect
  setting/file/instancing/count signals before changing the edited resource.
  Texture entries also stop allocating an unparented mesh-only enable button:
  one such orphan per entry caused 33 CanvasItem RID / 66 ObjectDB exit warnings
  in the graphical dock regression. Mesh entries still create and parent it.
* `Terrain3DObjects` rebinds its data source and matches the exact bound child
  transform callback on connection/disconnection.
* Setup-dialog dismissals use weak references, pruned on subsequent user events;
  still-live nodes retain their dismissed state.
* FRP texture signatures live on the `RenderSceneBuffersRD` whose named texture
  context they describe. Destroying that buffer destroys the signature, without
  a manager-side history of dead object IDs.
* FRP inspector renderer selections retain their renderer while the edited owner
  is alive; weak owners allow editor events to prune expired selections. This
  state is not serialized into profiles.

These operations run on changes or teardown, not by adding per-frame scans.
RenderDoc's temporary viewport list is already bounded; Tracy uses one download
request; this review did not establish an unbounded leak in either plugin.

The native audit also found bounded current-work containers: source jobs (32),
SVT decoded cells (64 / 256 MiB), one active refinement plan, capped retention,
and demand-age entries cleared when there are no misses (also guarded at 8192).
Map-slot capacity can grow to its historical maximum of 1024; that can produce a
bounded step in table-fill cost. Persisted-bake probes and edit stamps scale with
visited/edited cells and do not scan their complete history per frame. Their
growth was not established as the cause of this report; edit stamps must not be
discarded as if they were disposable cache entries because they invalidate stale
bakes.

## Measured results

Windows debug extension, RTX 3080 Ti, D3D12, isolated fixtures:

| Measurement | Before | After |
| --- | --- | --- |
| Settled synthetic VT CPU mean | 0.0608 ms | 0.0611 ms |
| Project movement windows, CPU mean | 0.831 / 0.768 / 0.768 / 0.825 ms | 0.873 / 0.786 / 0.802 / 0.808 ms |
| Project final stationary window mean | 0.202 ms | 0.216 ms |

These short runs show comparable CPU cost, not a measured speedup. Timing varies
with asynchronous production and scheduling. The final project window returned
to 2654 objects and about 527 MiB static memory. Fade queue capacity stayed at
1024 and live entries returned to zero. The baseline and corrected project logs
are `bin/terrain-project-lifetime-9tn1epcu/lifetime.log` and
`bin/terrain-project-lifetime-0hhx0ubk/lifetime.log` respectively.

A longer run (`--windows 24`, 5760 sampled frames, including 22 repeated moving
windows) reports moving-window means of 0.764–0.840 ms, averaging 0.794 ms; the
last stationary window is 0.216 ms. Moving-window static memory cycles between
about 556 and 623 MiB and object counts between 2753 and 2900. Queue capacity is
always 1024. The final queue is empty. This longer run also did not reproduce a
sustained rise in total VT CPU cost. Log:
`bin/terrain-project-lifetime-d5aysu7_/lifetime.log`.

The synthetic lifetime regression ran 2000 stationary-invalidating ticks and
2000 moving-invalidating ticks. Queue capacity stayed at 128; maximum live queue
size in the moving window was 10. It verifies the queue bound and fade-control
contracts, and reports CPU/memory observations; it does not assert that every
single CPU sample or memory reading must be identical.

Monitor units, rendered page-fade progression and 8-page pool pressure tests
passed. A recovery test exposed a sampling race: GPU readiness can become true
after the CPU classification snapshot. The test now requires both readiness and
zero missing pages within its original 240-tick deadline, preserving the recovery
requirement instead of asserting synchrony between independent stages.
Both BC7 and uncompressed recovery passed in 21 ticks after that correction.

Debug and release native builds succeeded. The full FRP regression passed all
17 stages, including buffer/renderer ownership checks and editor preview
(`bin/deferred-tests-r6sm019_`). The graphical terrain dock passed after the
orphan-button fix with no RID/ObjectDB leak warning
(`bin/feng-editor-dock-clean-1mojxhze/editor_dock_graphical.log`). The editor idle
test also completed all page production with zero missing pixels, and switching
BC7/uncompressed preserved the pool generation and capacity
(`bin/feng-editor-dock-clean-k0j8cfk1/editor_dock_graphical.log`).
The headless editor lifecycle regression passed with zero errors and zero leak
reports (`bin/terrain_lifecycle_ukeu94i0/lifecycle.log`). It exercises old/new
resource signals, dock/list reparenting, repeated control reconstruction, terrain
data/child callback rebinding, and live/dead dismissal weak references. It runs
as a real editor plugin so shutdown follows the normal editor lifecycle; it
does not suppress resource or RID leak reports.

## Comparison with HDRPVirtualTexture

Local reference: `F:/godot/HDRPVirtualTexture/Packages/com.noovertime.virtual-texture/Runtime`.

* `Pass/CorePass.cs` separates reallocation, feedback/readback, deduplication,
  sorting and page rendering. Persistent native lists/sets are cleared and reused.
* `Pass/RequestAsyncReadBackPass.cs` uses asynchronous GPU readback.
* `Pass/ReallocateVirtualPagePass.cs` limits reallocation to camera/sector changes
  and removes obsolete virtual images.
* `Pass/RenderingPagePass.cs` uses a fixed physical-page LRU and bounded production;
  `Utility/Constant.cs` specifies 1023 physical pages and 16 new pages per frame.
* `Core/PhysicalPageAtlas.cs` reuses GPU arrays/buffers and releases them explicitly.
* `ShaderLibrary/VirtualTexture.hlsl` selects pages by derivative footprint and
  falls back through coarser levels.

The terrain implementation already has bounded physical residency, asynchronous
source production, hierarchical fallback and frame budgets. These mechanisms do
not justify replacing the AVT architecture. The reference itself documents remap
limitations, and its readback disposal requires care; it is not a universal
correctness oracle. The fixes above repair local lifecycle and blend contracts
while preserving the existing subsystem boundaries.

## Regression entry points

Run from the repository root after rebuilding the native extension:

```powershell
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_monitors_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_page_fade_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_lifetime_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_idle_cost_runner.py --driver d3d12
python misc/feng-addons/feng-idweight-terrain/native/tests/vt_project_lifetime_probe.py --project F:/godot/project/test-1
python misc/scripts/test_feng_terrain_lifecycle.py
python misc/scripts/test_frp_pipeline.py --driver d3d12
```

Run GPU measurements serially. Keep current CPU samples separate from cumulative
peaks, and compare repeating movement windows after startup rather than attributing
initial shader compilation or page production to a lifetime leak.
