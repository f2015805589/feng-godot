# UE 5.8 cloud package bulk-payload audit

- Canonical packages checked: 25.
- Copied source/destination SHA-256 matches: 25/25.
- Package classifications: {'local-bulk-verified': 18, 'no-bulk-data': 7}.
- Verified payload record types: {('legacy-package-file-offset', 'same_uasset', True): 11, ('package_trailer', 'local', True): 7}.
- Exact UE package sidecars found: 0.

## Interpretation

The no-trailer files are not assumed to be self-contained merely because a sidecar search was empty. Each compressed payload is accepted only when the serialized FEditorBulkData offset points to its FCompressedBuffer header inside the same .uasset, its PayloadSize matches TotalRawSize, and its FIoHash matches the header hash prefix. Trailer entries are accepted only when trailer access mode is local and the local range/header/hash/size agree.

## Scope limits

This checks only the 25 canonical cloud/material-function package files and their UE 5.8 bulk-data locators. It does not certify unrelated files under the full Unreal Engine Content tree. Package import/reference closure and the three ambiguous /Game strings are tracked separately; this report does not replace that audit.

## Source contract

- `FPackagePath.cpp`: EPackageExtension maps `.uexp`, `.ubulk`, `.uptnl`, `.m.ubulk`, and `.upayload`.
- `EditorBulkData.cpp`: non-trailer, non-reference payloads load via `OpenReadPackage(PackagePath)`, seek to `OffsetInFile`, then deserialize; package-trailer payloads load through FPackageTrailer local payload lookup.
- `EditorBulkData.h`: external locator flags are IsVirtualized, HasPayloadSidecarFile, ReferencesLegacyFile, ReferencesWorkspaceDomain, and StoredInPackageTrailer.

## Result

All 18 payload-bearing package files have bulk data local to the copied .uasset files; the other 7 package files contain no bulk payload record. No listed UE bulk sidecars or non-local trailer payloads were found.

