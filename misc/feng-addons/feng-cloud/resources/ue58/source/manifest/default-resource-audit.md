# UE 5.8 default volumetric-cloud resource audit

Active Deferred formulas and channel reachability are defined in [`conservative-density-formulas.md`](conservative-density-formulas.md), backed by `active_deferred_material_ast.json` (SHA-256 `D6821214559A8F43B95EA001479A8C07801E51479E2ADBA8FDD3522F6EC5E358`) and `conservative_density_active_paths.json` (SHA-256 `DF7EBCB491B2A149AF3DE0ED7097A97598A2B0CC2715FB28BC07C8A5E8A70B3C`). This file records the package/property inventory.

Generated UTC: 2026-10-07T03:33:26.867396+00:00

## Scope and result

Read-only parse of the canonical 25-package UE resource snapshot at `F:\godot\worktrees\auto-feng-cloud\misc\feng-addons\feng-cloud\resources\ue58\source\manifest.csv`. The snapshot contains 17 cloud-directory packages and eight imported engine/function dependencies. The independent byte check found **25/25 package files SHA-256 matched source to plugin copy** (51,992,833 bytes). The package parser decoded 25 package summaries/import/export maps, **18/18 texture exports** with zero texture-property parse errors, the default material instance, and its parent material graph (280 graph nodes, 349 direct expression-input edges). No UE editor, engine build, or GPU rendering was used.

This is source-package metadata and serialized graph evidence. It does **not** convert texture payloads to Godot images, compile the Unreal material, or establish runtime platform texture format. The package-local bulk audit is separately recorded in `C:\Temp\feng-cloud-ue58-20261007\package-payload-final-summary.md` and verifies the bulk payloads reside in these `.uasset` files.

## Package and property stream parsing

The decoded package summary uses UE5 object version fields from the packages. At/above UE5 object version 1011, `UStruct::SerializeVersionedTaggedProperties` prepends one `EClassSerializationControlExtension` byte to root UObject property data; observed prefix `0x00` is `NoExtension` (`Class.cpp:1521–1528, 1588–1596`). For UE5 version >=1012, the property tag parser uses complete type names (FName + property type tree + size + flags); the UE version threshold is declared in `ObjectVersion.h:82`, and property extensions are handled in `PropertyTag.cpp:370+`. This explains the seven texture files whose property stream starts with a leading zero byte; without skipping it, the first tag was misread as an invalid FName.

Parser output: `C:\Temp\feng-cloud-ue58-20261007\default-resource-audit-final\ue58_cloud_default_resource_decode.json` (SHA-256 `D000C7D19588B93387CD624B5E7045D57A5AD3F07362F4C54BB79E42C25D9FB7`). Parser source: `C:\Temp\feng-cloud-ue58-20261007\default-resource-audit-final\analyze_ue58_cloud_defaults.py` (SHA-256 `7BD9F50D7DDC64259B72A14CCC83469B80A13428932158BC05693FECC8250D80`). The parser covers source textures, this instance, and its parent graph; it is not a general-purpose UE package reader.

## TextureSource inventory

“sRGB tag” reports whether a per-asset serialized property exists. If absent, UE `UTexture` initializes `SRGB=true` (`Texture.cpp:148–156`) and `UVolumeTexture` does likewise (`VolumeTexture.cpp:109–114`); `Texture.cpp:772–778` can force it off for mask/normal/alpha/HDR compression. Accordingly the table does not treat a missing tag as proof of final platform sampling behavior. `NumMips` and `NumSlices` are source data fields, not a promise that every cooked target uses that exact platform mip chain.

| Asset | Kind | TextureSource (W×H×slices) | Source format | Mips | Serialized sRGB | Compression / sampling settings | SHA-256 prefix |
|---|---|---:|---|---:|---|---|---|
| `Black_1x1_EXR_Texture` | Texture2D | 1×1×1 | TSF_RGBA16F | 1 | explicit false | TC_HDR; filter=TF_Nearest | `D1BE8E68444C` |
| `CloudGradientTexture` | Texture2D | 32×16×1 | TSF_BGRA8 | 1 | omitted | class default; — | `400C0F1D4C80` |
| `CloudWeatherTexture` | Texture2D | 512×512×1 | TSF_BGRA8 | 1 | omitted | class default; mip=TMGS_NoMipmaps, NeverStream=true | `5348FD8F0606` |
| `DefaultVolumeTexture` | VolumeTexture | 4×4×4 | TSF_BGRA8 | 1 | omitted | class default; mip=TMGS_NoMipmaps, filter=TF_Nearest, NeverStream=true | `AA12FC3920F9` |
| `DefaultVolumeTexture2D` | Texture2D | 8×8×1 | TSF_BGRA8 | 1 | omitted | class default; filter=TF_Nearest | `5AC139FDF879` |
| `T_CloudMask` | Texture2D | 1024×1024×1 | TSF_RGBA32F | 1 | explicit false | TC_VectorDisplacementmap; no-alpha=true | `12A258CD0F3B` |
| `T_CloudPattern` | Texture2D | 1024×1024×1 | TSF_RGBA32F | 1 | explicit false | TC_HDR; mip=TMGS_Blur1, maxsize=256 | `0A8225097AD4` |
| `T_Lightning` | Texture2D | 512×512×1 | TSF_RGBA16F | 1 | explicit false | TC_HalfFloat; mip=TMGS_NoMipmaps, no-alpha=true | `19D9B4F6AF47` |
| `T_NoiseErosion` | Texture2D | 1024×32×1 | TSF_BGRA8 | 1 | omitted | class default; — | `0B9117A9B8FB` |
| `T_NoiseShape` | Texture2D | 16384×128×1 | TSF_BGRA8 | 1 | omitted | class default; — | `DF75D3E04587` |
| `T_NoiseShape64` | Texture2D | 4096×64×1 | TSF_BGRA8 | 1 | omitted | class default; — | `A21EA9EAE126` |
| `T_Profile_08` | Texture2D | 256×256×1 | TSF_RGBA16F | 1 | explicit false | TC_HDR; — | `25334827F007` |
| `T_VolumeNoiseErosion32` | VolumeTexture | 32×32×32 | TSF_BGRA8 | 1 | explicit false | TC_Masks; mip=TMGS_NoMipmaps, filter=TF_Trilinear, NeverStream=true | `875FCFD07CA8` |
| `T_VolumeNoiseShape128` | VolumeTexture | 128×128×128 | TSF_BGRA8 | 1 | explicit false | TC_Masks; mip=TMGS_NoMipmaps, filter=TF_Trilinear, NeverStream=true | `36430CD673E5` |
| `T_VolumeNoiseShape64` | VolumeTexture | 64×64×64 | TSF_BGRA8 | 1 | explicit false | TC_Masks; mip=TMGS_NoMipmaps, filter=TF_Trilinear, NeverStream=true | `588A0E8A3DAE` |
| `T_Volume_PerlinWorley_Balanced` | Texture2D | 2048×1024×1 | TSF_RGBA16F | 1 | explicit false | class default; — | `28DA5AB378A2` |
| `VT_Lightning` | VolumeTexture | 64×64×64 | TSF_RGBA16F | 1 | omitted | TC_Grayscale; — | `EDC8453190B0` |
| `VT_PerlinWorley_Balanced` | VolumeTexture | 128×128×128 | TSF_RGBA16F | 1 | omitted | TC_VectorDisplacementmap; mip=TMGS_NoMipmaps, NeverStream=true | `89542FBE266D` |

Key default-instance bindings:

| Parameter | Resolved texture package | TextureSource |
|---|---|---|
| `Layout_CloudHeightProfile` | `/Engine/EngineSky/VolumetricClouds/T_Profile_08` | 256×256×1 TSF_RGBA16F |
| `Layout_CloudGlobalPattern` | `/Engine/EngineSky/VolumetricClouds/T_CloudPattern` | 1024×1024×1 TSF_RGBA32F |
| `Layout_GlobalCloudMask` | `/Engine/EngineSky/VolumetricClouds/T_CloudMask` | 1024×1024×1 TSF_RGBA32F |
| `Noise_Texture3D` | `/Engine/EngineSky/VolumetricClouds/VT_PerlinWorley_Balanced` | 128×128×128 TSF_RGBA16F |

Instance: `/Engine/EngineSky/VolumetricClouds/m_SimpleVolumetricCloud_Inst` → parent `/Engine/EngineSky/VolumetricClouds/m_SimpleVolumetricCloud`; instance export SHA-256 `9094A7AB8742BF44C8AFB9CF8CA17BB1E992FC3D0E335A4917EC3B0FB76ADC18`.

The instance serializes four global texture overrides (table above) and one unrelated scalar `RefractionDepthBias=0`. Its four cloud texture references are resolved via ImportMap to packages under `/Engine/EngineSky/VolumetricClouds`. In the parent graph, the three texture-object parameters for cloud profile, global pattern, and global mask have a `Black_1x1_EXR_Texture` fallback, while `Noise_Texture3D` falls back to `/Engine/EngineResources/DefaultVolumeTexture`; the instance replaces all four. The parent also contains two direct `VT_Lightning` texture sample references, but these are separate graph nodes associated with storm/lightning content, not MI overrides.

## Parent material graph

Parent: `/Engine/EngineSky/VolumetricClouds/m_SimpleVolumetricCloud`, SHA-256 `221F421770B7F5D99905BB2A1AF5DE4C9EDD7B5FB741ABF5A65923239D28B725`. Serialized properties: `MaterialDomain=MD_Volume`, `BlendMode=BLEND_Additive`, `bUsedWithVolumetricCloud=true`, `bCanMaskedBeAssumedOpaque=true`, and `PixelDepthOffsetMode=PDOM_Legacy`.

Serialized parameter defaults (as stored in the parent material graph):

| Parameter | Default |
|---|---:|
| `Cloud_AlbedoColor` | (0.98, 0.98, 0.98, 0.5) |
| `Layout_WindControls` | (1, 1, 0.5, 0.333333) |
| `Layout_CloudGlobalScale` | 256.0 |
| `Noise2_Coordinates` | (60, 60, 75, -6) |
| `Noise3_Coordinates` | (30, 40, 25, 8) |
| `Noise1_Coordinates` | (4.167, 4.444, 9.091, 7) |
| `Cloud_GlobalCoverage` | -0.20000000298023224 |
| `Layout_CloudType` | (1, 1, 1, 2) |
| `Cloud_GlobalDensity` | 0.00800000037997961 |
| `Storm_LightningColor` | (2, 1.8, 2, 10) |
| `Storm_AlbedoColor` | (0.3, 0.3375, 0.375, 0.333333) |
| `Layout_CloudPerTypeScale` | (1, 1, 1, 1) |
| `Storm_LightningTexScale` | 6.0 |
| `Layout_CloudTypeMask` | (0, 0, 0, 1) |
| `Multiscatter_Controls` | (0.666667, 0.25, 0.18, 1) |
| `Phase_Controls` | (0.8, 0.166667, 0.575, 1) |
| `Noise3_MultChannel` | (0, 0, 1, 0.4) |
| `Noise_Bias` | (0.5, 0.8, 0.5, 0) |
| `Noise_Strength` | (0.8, 0.08, 0.03, 2.5) |
| `Storm_LightningAnim` | (0, 0.1, 0, 1) |
| `Storm_LightningClouds` | (6, 0.05, 0.175, 2.5) |
| `Storm_LightningMasks` | (10, 5, 0.5, 1) |

Important advanced-output wiring:

- `MaterialExpressionVolumetricAdvancedMaterialOutput_0` is serialized as the material’s advanced volume output. `PhaseG`, `PhaseG2`, and `PhaseBlend` are the R/G/B components of `Phase_Controls=(0.8, 0.166667, 0.575, 1)`; `MultiScatteringContribution`, `MultiScatteringOcclusion`, and `MultiScatteringEccentricity` are the R/G/B components of `Multiscatter_Controls=(0.666667, 0.25, 0.18, 1)`. `ConservativeDensity` comes from a `MakeFloat4` function-call node with channels named `ConservativeDensity.r/g/b/a`. The follow-up report expands each active channel and its default branch.
- The initial direct-edge scan did not expand the material-function closure, so its statements about which profile samples were active and whether the profile affected a material output were incomplete. The follow-up closure establishes the active `.b` profile formula and also expands the `.a` noise branch and SubsurfaceColor dependencies. See `conservative-density-formulas.md`; this graph/CDO analysis still does not compile the UE material or evaluate its texture pixels.
- The 2D noise/detail textures packaged alongside the material are not all the actual default instance bindings. The default 3D noise input is `VT_PerlinWorley_Balanced` (128³ RGBA16F; its per-asset sRGB property is not serialized in this export); `T_VolumeNoiseShape64/128` and `T_VolumeNoiseErosion32` are additional source assets, not the instance’s `Noise_Texture3D` override.

## UE altitude/profile reference

UE computes the sample altitude relative to the cloud layer as a sphere/radius calculation, not just world-space Z. `VolumetricCloudMaterialPixelCommon.ush:23–34` converts the layer center, planet radius, bottom radius, and top radius from km to cm and sets `ToNormAltitude=1/(TopRadius-BottomRadius)`. At each cloud sample (`:61–64`):

```text
CloudSampleAltitude = length(AbsoluteWorldPosition - CloudLayerCenter)
AltitudeAbovePlanet = CloudSampleAltitude - PlanetRadius
CloudSampleAltitudeInLayer = CloudSampleAltitude - BottomRadius
CloudSampleNormAltitudeInLayer = saturate(CloudSampleAltitudeInLayer / (TopRadius - BottomRadius))
```

The normalized coordinate feeds the active Deferred expressions in
[`conservative-density-formulas.md`](conservative-density-formulas.md). That file records
serialized graph/CDO analysis; shader compilation and numerical source-texture evaluation are separate checks.

## Evidence files and limits

- Canonical plugin package manifest SHA-256: `29C5D466A5DCB947A569213A9442BD04E16739AD74CCF40CD15F52FE81891AEC`.
- UE source-anchor hashes are recorded in the JSON under `source_file_sha256`; e.g. `Class.cpp` `521022C37B0E556CB82DC885C6B8E1ED69332BCBA49316B4B767AAD8AA1A809A` with these additional anchors: `VolumetricCloudMaterialPixelCommon.ush` `934D751D3628DF578AE54810322BDC45A272F1F9947F72900CBF09FF007C52AB` and `VolumetricCloud.usf` `2ED5B6412AA200DF40C88FF838B7129A43EDB92B159D2B2791179C0E31A84C64`; volume texture defaults are anchored by `VolumeTexture.cpp` `3836AF679D356356E61E96516EC05D50500838BAE3CAB9C55F26A5B51FC4F2FF`; advanced material output by `MaterialExpressionVolumetricAdvancedMaterialOutput.h` `4BAD60F6FBD1A831183941E0BC9A6377C033569233813E69EB1C2550FEB2D092`; static-switch constructor by `MaterialExpressions.cpp` `9930F4DF181E6FEC9DC720D2F2968CFAA377C93FC2D7045A950AE08CF7A59371`.
- Package bulk locality and sidecar findings are in the independently generated package-payload report. This audit does not validate the integrity of pixels after UE decompression, reimport, or Godot conversion.
- Static material graph parsing enumerates serialized object nodes and direct FExpressionInput edges; it does not compile the expression graph or prove which shader permutations are selected for a particular quality level.
- Some class-default expression fields and non-serialized texture settings are intentionally labeled as absent rather than guessed. Material parameter defaults printed above are serialized asset values.
