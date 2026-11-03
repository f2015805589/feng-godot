# Third-party components

- **NVIDIA LibNTC 0.10.0** — pinned official DLL and API headers, installed with `tools/setup_sdk.py` for offline authoring. Licensed under the NVIDIA RTX SDKs License, not the repository's MIT license. See `LICENSES/NVIDIA-LICENSE.txt` and `LICENSES/NVIDIA-ThirdPartyLicenses.txt`. The authoring DLL and SDK tools are excluded from portable game exports.
- **Portable decoder shader** — `shaders/decode.glsl` derives GenericInt8 inference math from NVIDIA's `RTXNTC-Library`, commit `35ec039503ef5e151c661beccc82390948dd5218`, `include/libntc/shaders/Inference.hlsli`. This software contains source code provided by NVIDIA Corporation. The NVIDIA license and notices apply to this shader too, including game exports without DLLs. The shader is not relicensed under MIT.
- **Convection Texture Tools (CVTT)** — BC7 CPU encoder, built into `feng_ntc.dll` from the separately supplied source directory. See `LICENSES/CVTT.txt`. The default build reuses the engine repository's copy; no private engine APIs are linked.
- **godot-cpp** — public GDExtension bindings, statically linked into `feng_ntc.dll`. See `LICENSES/godot-cpp.txt`.

Keep these notices with distributed plugin binaries. The first-party adapter code is covered by the surrounding feng-godot repository license.
