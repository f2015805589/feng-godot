# Terrain engine interfaces

Terrain production code lives under `misc/feng-addons/feng-idweight-terrain`.
The two fork interfaces below connect it to the renderer. Keep engine changes additive,
bind signatures explicitly and verify the FRP integration after an upstream upgrade.
Other FRP integration points are documented in [the engine contract](../../../../doc/frp-engine-contract.md).

## GPU buffer-to-texture copy

`RenderingDevice::texture_copy_from_buffer` records GPU-produced block data directly
into a sampled texture. Its patch surface is:

- Declaration in `servers/rendering/rendering_device.h`
- ClassDB binding in `servers/rendering/rendering_device.cpp`
- Implementation in `servers/rendering/rendering_device_gpu_buffer_copy.cpp`

`servers/rendering/SCsub` includes the implementation through its source glob.
The method records `RDG::TYPE_TEXTURE_UPDATE` with the source buffer's resource tracker,
so Vulkan/D3D12 render-graph dependencies order the copy after encoding and before sampling.

Requirements:

- Destination usage includes CAN_COPY_TO or CAN_UPDATE; compressed D3D12 arrays use the
  supported update usage rather than requesting an unsupported UAV flag
- Source offset and byte row pitch satisfy backend alignment: D3D12 uses 512-byte offsets
  and 256-byte rows. Block formats also require block-aligned source/region geometry
- `p_row_pitch` is bytes; `p_region` is texels
- Draw/compute lists are closed before recording the copy

`native/src/rd_gpu_copy.{h,cpp}` resolves the optional method by name and exact signature
hash, without linking to fork-only C++ symbols. Refresh the hash only when the signature changes:

```powershell
bin\godot.windows.editor.x86_64.exe --headless --dump-extension-api --path <tmp>
# RenderingDevice.texture_copy_from_buffer: hash 1147505037
```

When the method or hash is unavailable, the baker uses asynchronous block readback plus
render-callback upload. Direct copying avoids that round trip; `encode_readbacks`,
`encode_ring_pages` and `ready_latency_frames_mean/max` describe the actual path.
The fallback changes latency, while retaining page-content and readiness checks.

## Render-thread production callback

`RenderingServer.virtual_texture_set_update_callback(id, callable)` registers the producer;
`virtual_texture_remove_update_callback(id)` releases it. The registry and mutex live in
`servers/rendering/rendering_server.{h,cpp}`, together with their ClassDB bindings and
`execute_virtual_texture_updates()`.

`FRPPassContext::execute_virtual_texture_updates()` executes callbacks in the native
**VT Pass** (ID 1), before GBuffer. Main-thread demand queues jobs; the callback records
bake/copy/encode work on the main RenderingDevice inside the render frame. Installing
the API alone is insufficient: the active renderer must execute the callback.

The addon probes the methods at runtime and reports `callback_registered` through
`get_vt_settings()`. A missing hook emits one warning and leaves material-page production
unavailable; rebuild the engine from this checkout. Explicit direct/editor paths remain
separate from cached-material rendering. Teardown unregisters the producer before releasing
its owner, and pending work respects the producer's frame budget.

## Upgrade checklist

1. Verify declarations, ClassDB signatures and the buffer-copy implementation in the new tree
2. Verify registry/removal and the FRP VT operation still execute at the required frame position
3. Rebuild the engine: `scons platform=windows target=editor arch=x86_64`
4. If the copy signature changed, refresh `TEXTURE_COPY_FROM_BUFFER_HASH` from the dumped API
5. Rebuild from the addon's `native/`: `scons platform=windows target=template_debug arch=x86_64`
6. Run `native/tests/vt_material_runner.py` with that engine; require callback registration
   and actual material-page production, then test direct-copy/fallback readiness as applicable

See [native tests](../native/tests/README.md) for drivers, isolated fixtures and image gates.
