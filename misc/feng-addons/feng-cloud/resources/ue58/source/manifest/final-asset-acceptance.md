# UE 5.8 cloud asset closure — independent acceptance

- Source: `UE 5.8 Engine/Content source`
- Preserved plugin copy: `../Engine/Content`
- Manifest: `../manifest.csv`
- Packages: **25/25** source/destination SHA-256 matches; **51,992,833 bytes**.
- UE package parser: **25/25** parsed, **223** import rows, **0** parser errors.
- Hard `/Engine` package references: **17**, all found in the plugin snapshot; `/Script` code packages: **4**; unresolved `/Engine` references: **0**.

## Import metadata

These `/Game` strings lie after `TotalHeaderSize`, inside `InterchangeAssetImportData_0`
exports of `/Script/InterchangeEngine.InterchangeAssetImportData`; they are import metadata,
not ImportMap package dependencies:

| Package | String | UTF-16 offset | Export range |
| --- | --- | ---: | --- |
| `T_CloudPattern.uasset` | `/Game/T_CloudPattern.T_CloudPattern` | 19762 | 18329–20812 |
| `T_Lightning.uasset` | `/Game/T_Lightning.T_Lightning` | 9984 | 8584–11180 |
| `T_Volume_PerlinWorley_Balanced.uasset` | `/Game/T_Volume_PerlinWorley_Balanced.T_Volume_PerlinWorley_Balanced` | 13214 | 11605–14486 |

## Embedded bulk data

The separate UE package/bulk audit verified all 18 bulk payloads are local to their copied `.uasset` packages, found no sidecars, and found no virtualized/referenced payloads. The independent header checks covered:

- `CloudWeatherTexture.uasset`: legacy-package-file-offset, method 0, 283,178 raw bytes, 283,242 compressed bytes including header; CRC, range, FIoHash prefix, and source/destination header bytes match.
- `T_CloudPattern.uasset`: package_trailer, method 3, 16,777,216 raw bytes, 10,020,197 compressed bytes including header; CRC, range, FIoHash prefix, and source/destination header bytes match.

## Closure scope

The 25 copied packages contain this cloud resource closure’s `/Engine` dependencies. This evidence covers only that closure. Keep unrelated Unreal content according to its own users. Godot runtime conversions are stored separately under `resources/ue58/converted`.

Bulk reports: `package-payload-final-summary.md`, `package-payload-final.csv`, and `package-bulk-final.csv`.
