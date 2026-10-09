# FRP runtime performance (2026-10-10)

B0 used engine binary version `2c964d3e9` (GUI SHA-256 `6370AD8DBF63411F8D8422763B43D1776D845F8AA2AD3197ADC3351BA3BE0FEA`); this identifies the engine binary, not every addon source. B3 used an uncommitted measurement snapshot based on `b2d37ada` (GUI SHA-256 `61D5869B181693C3A947920F2CA2329D7D22D812D1F85D93A3A37A12F35F3F61`; source manifest SHA-256 `F493BF539B954AEE0012EF02D8AC958B25D8E94D6D1DD11728A8E8BC24AAC5C0`).

## Runtime workloads

Both samples used the saved test-1 scene at 1485×897 on D3D12 / RTX 3080 Ti, with VT preview off, VSync and FPS caps disabled, and Tracy disconnected. Values are milliseconds, shown as p50 / p95.

| Workload | Build | Frames | Viewport CPU | Viewport GPU | Frame wall |
|---|---|---:|---:|---:|---:|
| Static | B0 | 7,791 | 1.847 / 2.077 | 3.038 / 3.095 | 3.835 / 4.191 |
| Static | B3 | 8,943 | 1.625 / 1.855 | 2.808 / 2.831 | 3.299 / 3.689 |
| Moving | B0 | 7,442 | 1.954 / 2.562 | 2.988 / 3.315 | 3.943 / 5.400 |
| Moving | B3 | 8,409 | 1.712 / 2.177 | 2.950 / 3.064 | 3.463 / 4.761 |

B3 viewport CPU p50 is about 12% lower in both workloads. GPU differences are small and variable; these runs do not attribute them to a GPU algorithm change. Frame wall p50 also falls in both samples.

The editor comparison is not resolution matched: 1491×900 → 1496×903. CPU p50 changed from 2.122 to 2.007 ms static and 2.193 to 2.065 ms moving; GPU time was essentially unchanged.

## Implementation context

The candidate moves shared RD value helpers below their consumers, uses one stateless shadow-policy base, avoids script-marker mutex/string work while Tracy is disconnected, and reads volume frame generation through a scalar accessor instead of copying the full packet. These changes are not individually isolated by the runtime comparison. The Terrain 256 MiB cache cap and the final four cleanup edits landed after the B3 measurement and are not represented by these numbers.

## Provenance and limits

B0 summary: C:/Temp/feng-perf-phase0-b2d37-20261009-0287326cb9cc/test1/runtime_data/b3_phase3_b0_control_20261010_01/baseline_summary.json (SHA-256 2347865E3B4FA8308C859A897FF5FCFD72F1D7B59ADED5F32DBE508B7A90442A).

B3 summary: C:/Temp/feng-perf-phase0-b2d37-20261009-0287326cb9cc/test1/runtime_data/b3_phase3_candidate_20261010_01/baseline_summary.json (SHA-256 E7646D563A511A1EB1E75C55964F74921C26E34105E0B5CA75C7CD87C75FD06F).

B0 and B3 report the same shutdown RD warnings. Perfetto was not built or run. These samples do not isolate each code change or establish results on other hardware.
