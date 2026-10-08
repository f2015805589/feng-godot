# UE 5.8 cloud package bulk-payload audit

- Canonical packages checked: 25.
- Copied source/destination SHA-256 matches: 25/25.
- Package classifications: {'local-bulk-verified': 18, 'no-bulk-data': 7}.
- Verified payload record types: {('legacy-package-file-offset', 'same_uasset', True): 11, ('package_trailer', 'local', True): 7}.
- Exact UE package sidecars found: 0.

## Interpretation

Each compressed payload is accepted when the serialized FEditorBulkData offset points to its FCompressedBuffer header inside the same .uasset, its PayloadSize matches TotalRawSize, and its FIoHash matches the header hash prefix. Trailer entries are accepted only when trailer access mode is local and the local range/header/hash/size agree.

## Scope limits

This covers the 25 canonical cloud/material-function packages and their UE 5.8 bulk-data locators. [Package-reference closure and import metadata](final-asset-acceptance.md) have a separate audit.

## Source contract

- `FPackagePath.cpp`: EPackageExtension maps `.uexp`, `.ubulk`, `.uptnl`, `.m.ubulk`, and `.upayload`.
- `EditorBulkData.cpp`: non-trailer, non-reference payloads load via `OpenReadPackage(PackagePath)`, seek to `OffsetInFile`, then deserialize; package-trailer payloads load through FPackageTrailer local payload lookup.
- `EditorBulkData.h`: external locator flags are IsVirtualized, HasPayloadSidecarFile, ReferencesLegacyFile, ReferencesWorkspaceDomain, and StoredInPackageTrailer.
