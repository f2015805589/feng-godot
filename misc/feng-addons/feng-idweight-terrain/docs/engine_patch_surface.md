# Engine patch surface

This addon builds on the Feng Godot fork, but everything that is specific to it lives here, under
`misc/feng-addons/`. This file lists the **only** places where the fork's engine source differs
from upstream for the terrain's sake, so an engine upgrade can be re-applied mechanically instead
of diffing a whole tree.

Rule for anything added here: **additive, one file, no build-file change.** A new `.cpp` under
`servers/rendering/` is compiled by the `*.cpp` glob in `servers/rendering/SCsub`, so nothing has
to be registered; and the body of a fork-local method is kept out of the engine's own translation
units so an upstream merge never conflicts inside them.

## 1. `RenderingDevice::texture_copy_from_buffer` - GPU side page storage

**What it does.** Copies a texture region straight from a device buffer. `texture_update()` takes
CPU bytes, so content produced on the GPU (an encoded virtual texture page) has to be read back to
the CPU and uploaded again, and the page cannot be published as resident until that round trip has
happened - measured at two frames, and up to 96 across a pool rebuild. With this call the copy is
recorded in the same submission as the passes that produced the content, so a page is resident on
the frame it is produced in.

**Patch surface (three spots, ~200 lines total):**

| file | change |
|---|---|
| `servers/rendering/rendering_device.h` | declaration of `texture_copy_from_buffer` (~14 lines of comment + 1 signature), next to `texture_update` |
| `servers/rendering/rendering_device.cpp` | one `ClassDB::bind_method` line in `_bind_methods()` (~line 9066) so a GDExtension can resolve it |
| `servers/rendering/rendering_device_gpu_buffer_copy.cpp` | **new file**, the whole implementation |

The implementation records `RDG::TYPE_TEXTURE_UPDATE` - the same buffer-to-image copy the upload
path already records, and which both the Vulkan and D3D12 backends implement - with the producing
buffer as the source and **its resource tracker** attached, so the render graph orders the copy
after the command that wrote the buffer and barriers the two. Nothing in `drivers/` changes.

**Requirements it enforces**, all of which already hold for the page arrays:

* the destination needs `TEXTURE_USAGE_CAN_COPY_TO_BIT` or `TEXTURE_USAGE_CAN_UPDATE_BIT` (on
  Vulkan both map to `VK_IMAGE_USAGE_TRANSFER_DST_BIT`; D3D12 needs no resource flag to be a copy
  target, and `CAN_COPY_TO` would only add `ALLOW_UNORDERED_ACCESS`, which block formats do not
  support anyway);
* the source buffer must satisfy the driver's copy alignment - 256 byte rows and 512 byte offsets
  on D3D12. A storage buffer is created with `BUFFER_USAGE_TRANSFER_FROM_BIT` already
  (`storage_buffer_create`), so it is a legal source on Vulkan with no flag change;
* `p_row_pitch` is the **byte** pitch of one source row and the region is in texels. For a block
  compressed destination both are block aligned, and the backends convert the pitch to the
  block-relative row length themselves;
* it must not be called with a draw or compute list open - the same rule `texture_update()` has.

## 2. Addon side - how the extension uses it without depending on it

`native/src/rd_gpu_copy.{h,cpp}` resolves the method **by name at runtime** and caches the method
bind, so nothing links against the fork:

* `RenderingDevice::has_method("texture_copy_from_buffer")` decides availability. On a stock engine
  (or a fork that has moved on) the answer is no, no engine error is printed, and the baker keeps
  its readback path - the terrain still works, with the extra frames of latency.
* The method bind is looked up with the signature hash the engine compares against, taken from this
  fork's own `--dump-extension-api`:

  ```powershell
  bin\godot.windows.editor.x86_64.exe --headless --dump-extension-api --path <tmp>
  # RenderingDevice.texture_copy_from_buffer -> "hash": 1147505037
  ```

  **If the engine-side signature is ever changed, refresh that number** in
  `native/src/rd_gpu_copy.cpp` (`TEXTURE_COPY_FROM_BUFFER_HASH`). Until it is refreshed the lookup
  resolves to no method and the extension uses the readback path again - a performance regression,
  never a wrong call.

`native/src/terrain_3d_surface_baker.cpp` then stores a page two ways from one place: the direct
copy when the capability is present (`direct_store`), the readback and upload when it is not. The
statistic that shows which one ran is in the producer stats:
`encode_readbacks` (zero on the direct path), `encode_ring_pages`, and
`ready_latency_frames_mean` / `ready_latency_frames_max` - the frames between producing a page and
its encoded layers being resident, which the direct path makes zero.

## Re-applying after an engine upgrade

1. Search the new engine source for `texture_copy_from_buffer`. If it is absent, re-apply the three
   spots above (the file is self-contained; the two edits outside it are one declaration and one
   binding line).
2. Rebuild the engine: `scons platform=windows target=editor arch=x86_64`.
3. Refresh `TEXTURE_COPY_FROM_BUFFER_HASH` from `--dump-extension-api` **only if the signature
   changed**.
4. Rebuild the addon from `misc/feng-addons/feng-idweight-terrain/native`:
   `scons platform=windows target=template_debug arch=x86_64`.
