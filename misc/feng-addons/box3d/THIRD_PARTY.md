# Third-party source provenance

All third-party code remains MIT licensed. Retain the license files when
distributing this addon, including binary-only packages.

| Component | Repository | Pinned revision | License |
| --- | --- | --- | --- |
| Box3D | https://github.com/erincatto/box3d | `3fc20f5b453ba9e14cdf54ecafa87a2a4bcdf53c` | `native/thirdparty/box3d/LICENSE` |
| Godot Box3D adapter | https://github.com/bearlikelion/godot-box3d | `c16ba7c9e30020e0616e7903622e8c2a8e31d948` (`v0.3.1`) | `native/thirdparty/godot-box3d/LICENSE` |
| godot-cpp | https://github.com/godotengine/godot-cpp | Shared checkout SDK, API 4.5 | `../feng-idweight-terrain/native/godot-cpp/LICENSE.md` |

The Box3D snapshot contains its library sources, public headers, and CMake build
files. The adapter snapshot contains its C++ sources. Upstream Godot test scripts
are in `tests/upstream/` under the adapter's MIT license. Samples, screenshots,
CI scripts, and build artifacts are not vendored.

Local changes to the adapter:

- The three PhysicsServer/direct-state extension classes use `float` in their
  scalar overrides, matching this checkout's generated Godot 4.5 API metadata.
  No Godot engine source changes are required.
- The addon has its own CMake build and reuses the shared godot-cpp SDK. Its native
  library is `bin/box3d.dll` (Windows) or `bin/box3d.so` (Linux).
- The GDExtension manifest requires 4.5 and disables live DLL reload. Replacing a
  physics server while worlds are alive requires an engine restart.
- `backend_activation_test.gd` also checks the actual server class, so a fallback
  to Godot/Jolt cannot produce a passing activation result.
- Direct ray/point/shape queries now fill the native `collider` pointer as well
  as its ID. Previously script queries hit geometry but returned a null collider.
  Ray results also propagate Box3D's mesh triangle index (`-1` for primitives).
- Editor-only construction of unsupported soft-body and separation-ray resources
  tolerates the null RID used for property/default documentation. Runtime creation
  still reports these unsupported features. The soft-body shrinking-factor virtuals
  are implemented as defaults so first-run help generation can query all properties.
