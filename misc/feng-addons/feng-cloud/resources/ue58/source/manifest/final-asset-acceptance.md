# UE 5.8 cloud asset closure — independent acceptance

- Source: `UE 5.8 Engine/Content source`
- Preserved plugin copy: `../Engine/Content`
- Manifest: `../manifest.csv`
- Packages: **25/25** source/destination SHA-256 matches; **51,992,833 bytes**.
- UE package parser: **25/25** parsed, **223** import rows, **0** parser errors.
- Hard `/Engine` package references: **17**, all found in the plugin snapshot; `/Script` code packages: **4**; unresolved `/Engine` references: **0**.

## The three `/Game` strings

- `T_CloudPattern.uasset` contains `/Game/T_CloudPattern.T_CloudPattern` at UTF-16 offset 19762; it is inside export `InterchangeAssetImportData_0` (18329–20812), whose class is `InterchangeAssetImportData` from `/Script/InterchangeEngine`. The string is after `TotalHeaderSize` and is not an ImportMap package dependency.
- `T_Lightning.uasset` contains `/Game/T_Lightning.T_Lightning` at UTF-16 offset 9984; it is inside export `InterchangeAssetImportData_0` (8584–11180), whose class is `InterchangeAssetImportData` from `/Script/InterchangeEngine`. The string is after `TotalHeaderSize` and is not an ImportMap package dependency.
- `T_Volume_PerlinWorley_Balanced.uasset` contains `/Game/T_Volume_PerlinWorley_Balanced.T_Volume_PerlinWorley_Balanced` at UTF-16 offset 13214; it is inside export `InterchangeAssetImportData_0` (11605–14486), whose class is `InterchangeAssetImportData` from `/Script/InterchangeEngine`. The string is after `TotalHeaderSize` and is not an ImportMap package dependency.

## Embedded bulk data

The separate UE package/bulk audit verified all 18 bulk payloads are local to their copied `.uasset` packages, found no sidecars, and found no virtualized/referenced payloads. I independently checked these two headers:

- `CloudWeatherTexture.uasset`: legacy-package-file-offset, method 0, 283,178 raw bytes, 283,242 compressed bytes including header; CRC, range, FIoHash prefix, and source/destination header bytes match.
- `T_CloudPattern.uasset`: package_trailer, method 3, 16,777,216 raw bytes, 10,020,197 compressed bytes including header; CRC, range, FIoHash prefix, and source/destination header bytes match.

## Deletion scope

For this cloud resource closure, no additional `/Engine` content package dependency remains outside the 25 copied packages. This is not a full backup of Unreal Engine `Engine/Content`; it does not establish that unrelated engine features or other projects do not use other files in that tree. The copied files are preserved UE source packages and still need conversion before Godot can import them as native resources.


Bulk reports: `package-payload-final-summary.md`, `package-payload-final.csv`, and `package-bulk-final.csv`.


