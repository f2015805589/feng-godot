# Per-light fog extensions

FFogLightExtension is an optional Node child of a Light3D (default light_path is ".."). The registry joins it to FRP's same-frame native base RID arrays. It does not scan the scene tree, replace a Light3D, or alter WorldEnvironment. Each World3D has a weak registry; expired nodes and extensions from another world are ignored.

## Main-thread snapshot

Split the snapshot by thread boundary. In the main-thread `_frp_prepare` phase call `FFogLightExtensionRegistry.snapshot_metadata_for_world(world_id)`. This enumerates only registered weak entries and resolves Nodes/Resources into plain values and RIDs; it does not need native light arrays yet. After the native frame inputs are published, call `join_native_frame(metadata, frame_inputs, world_id)` from the later renderer callback. The join reads only the metadata and frame dictionaries, and never calls back into a Node or Resource. `snapshot_for_world(world_id, frame_inputs)` remains a compatibility wrapper for code that already has both inputs on the main thread.

`snapshot_metadata_for_world` returns `{valid, abi_version: 1, world_id, registry_generation, snapshot_generation, by_light_rid}`. The `by_light_rid` dictionary is keyed by native `Light3D.get_base()` RID and each row contains only plain values and RIDs. Take a fresh metadata snapshot each frame so transform, cookie RID, and property revisions match that frame. `join_native_frame` requires the same explicit world ID because the native frame ABI does not include a world ID. It validates frame-input ABI v1, light counts, unique valid RIDs, snapshot generation, and native light kind, then preserves the native frame order. Registered but currently culled/inactive lights are valid metadata and are ignored for this frame; malformed or cross-world rows fail closed.

The joined snapshot contains one row per active native light in this exact order:

1. omni
2. spot
3. area
4. directional

Every row contains the native base RID and plain metadata. It contains no Node or Resource object. A LightFunction Texture2D is resolved on the main thread to a borrowed RenderingDevice texture RID and paired with its signed Resource instance ID, change revision, and sRGB choice. Resource IDs are valid whenever nonzero; their sign is not meaningful.

The registry only reads the native light RID arrays supplied in the frame. If a count and array length disagree, any RID is invalid, or a RID is duplicated, the snapshot is invalid. A missing extension creates a neutral record. Duplicate extensions on one light fail closed: the first registered node remains active.

## Provider and set-3 descriptors

Call `FFogLightExtensionProvider.update_frame_inputs(joined_snapshot, main_rd)` on the render side. The main_rd must be the RenderingServer main RenderingDevice. The provider returns owned output RIDs for the current lease:

| Set | Binding | RD descriptor | Payload |
| --- | ---: | --- | --- |
| 3 | 0 | storage buffer | 144-byte ABI v2 record per active light |
| 3 | 1 | sampler + 2D-array texture | linear RGBA16F, 256×256 cookie layers |
| 3 | 2 | uniform buffer | 16-byte ABI/frame header |

The returned value dictionary names these RIDs as `records_buffer`, `cookie_texture_array`, `cookie_sampler`, and `header_buffer`. It also reports `record_stride_bytes`, `record_count`, `record_order`, `native_type_counts` (`[omni, spot, area, directional]`), and `record_offsets` (type name to first flat index). Consumers should resolve a native type-local light index with `ffog_light_extension_record_index()` and the same-frame type counts, then validate `frame_generation`, `registry_generation`, and `cookie_array_generation` before using cached bindings.

Include fog_light_extension.glslinc once in the FRP lighting shader. Use ffog_light_function_color(record_index, froxel_world_position) to obtain a linear RGB multiplier and apply it to that light's contribution once. The helper returns white for disabled, absent, unsupported, or out-of-bounds cookies. Cookie alpha is ignored. The native AreaLight3D source atlas remains a separate input and is not replaced by this optional cookie.

Unique source textures are deduplicated by RD RID, Resource ID, source revision, sRGB flag, dimensions, and format. A compute resample maintains aspect ratio and white-pads to the fixed layer size. No CPU image readback occurs. When no valid cookie is active, the descriptor remains bindable through a provider-owned 1×1 white 2D-array texture and the header reports zero cookie layers. A cookie source that cannot be used is reported as a neutral fallback; other per-light metadata remains available.

Returned RIDs belong to the provider and are borrowed until the next update or release(). Consumers must stop submitting work that references these outputs before releasing the provider. Source texture RIDs are borrowed and never freed by this provider.

## Record ABI v2

All offsets are bytes; the GLSL declaration is the executable layout.

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | mat4 | world to light-local transform, column-major |
| 64 | vec4 | mapping range, spot half-angle tangent, area half-width, area half-height |
| 80 | vec4 | mapping scale XY and offset XY |
| 96 | vec4 | barn-door cosine, length in meters, enabled, cookie blend strength |
| 112 | uvec4 | mapping type, cookie layer (0xffffffff means none), shadow policy, feature bits |
| 128 | vec4 | explicit capsule source length in meters, local axis index (0=X, 1=Y, 2=Z), reserved, reserved |

The header lanes are ABI version 2, record count, cookie layer count, and the low 32 bits of frame generation. The provider result also reports the full frame generation, registry generation, and cookie-array generation for same-frame validation. Consumers must select a stride from the header ABI before indexing the SSBO; unknown versions fail closed. ABI v1 can be handled as a 128-byte legacy layout, while this provider emits v2 only.

Mapping types are none, directional orthographic, spot perspective, omni dual paraboloid, and area plane. Godot lights point along local -Z. Zero mapping_range_m uses the native positional-light range; directional mapping uses a 100 m half-width unless overridden. Spot angle and area size come from the associated native light. Explicit mapping scale/offset are applied after projection.

The cookie strength defaults to zero and blends white toward the sampled linear RGB. `mark_light_function_texture_changed()` advances the texture revision after an in-place image update; `Resource.changed` is also observed when emitted. Changing node properties advances its metadata revision.

Capsule source length defaults to zero, producing point-light integration. A nonzero length is explicit authored metadata and is never inferred from `Light3D.size`. The local X/Y/Z axis defaults to Y; the renderer maps it to world space from the orthonormal light transform. Length is in meters. `FFogCapsuleLight.integrate()` and `ffog_integrate_capsule_light()` mirror UE's point/line integral, including the cell-radius distance bias with a 0.01 m minimum. The returned line direction is UE's unnormalized average of the normalized endpoint vectors. The caller applies the native range/spot mask separately; Godot `Light3D.size` is not treated as capsule length.

## Barn doors and shadows

Area barn-door metadata follows UE's shared four-sided controls: angle is clamped to 0–88 degrees (default 88), and length is meters (default 0.2 m, equivalent to UE's 20 cm). It is enabled only for an AreaLight3D when length is positive and angle is below 88 degrees. The volumetric consumer applies the door geometry/fade; the extension provider does not invent a second attenuation.

Shadow policy defaults to the native shadow path. DISABLED asks the consumer to skip volumetric shadowing. HARDWARE_RT_OPT_IN is only a request; the current Godot D3D12 backend does not expose hardware RT, so the consumer must retain the native raster shadow fallback there. The metadata does not claim a hardware RT result.

`static_lighting_key` is an optional stable key on the directional light
extension. It is copied into the main-thread metadata snapshot and then joined
to the same-frame native directional row. It is value metadata only and does
not change the 144-byte GPU record. The VLM consumer compares it exactly with
the resource's key before applying a static directional shadow or suppressing
the matching live Sun.

## Validation

tests/run_fog_light_extension_tests.py exercises real Light3D and Texture2D resources, world isolation, native RID order, default-neutral behavior, projection, signed Resource IDs, and byte offsets in a disposable headless project. It does not create a RenderingDevice cookie array or claim GPU resampling/rendering validation.

