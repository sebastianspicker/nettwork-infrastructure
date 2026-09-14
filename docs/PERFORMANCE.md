# Performance measurements

<!-- markdownlint-disable MD013 -->

Local measurements and checks from 6 September 2026 cover inventory reads,
physical trace summaries, IPAM validation, hierarchy lookup, CloudKit deletion
preconditions, file-backed imports, persistence queries, and native CI coverage.
Public compatibility APIs and persistence schemas remain in place.

## Correctness and build results

The retained logs from 6 September 2026 record these results. They are a
historical snapshot, not the current status of a GitHub branch:

| Gate | Result |
| --- | --- |
| `make verify-source` | Format, script, web, configuration, syntax, assets, whitespace, architecture, quality, and documentation checks passed; zero quality violations |
| `make verify-package` | 231 XCTest tests and 2 Swift Testing tests passed with warnings treated as errors |
| `make verify-native` | XcodeGen generation, 56 macOS application tests, and the iOS Simulator application build passed |

The tests cover these contracts:

- Favorites and recents resolve through one batch, preserve ordering, omit
  missing or tombstoned objects, and reject stale history/session results.
  Hierarchy output preserves localized sibling ordering and orphan visibility.
- Summary traversal matches legacy metrics below limits and covers cycles,
  branching, cancellation, and the exact 512-segment boundary. IPAM tests compare
  the indexed implementation with the original validator using fixed seeds,
  IPv4/IPv6 inputs, nesting, duplicates, reservations, and tombstones.
- CloudKit tests exercise the actual batch-operation submission seam, including
  one operation for a bounded page, no operation for an empty page, missing
  results, changed tags, per-record failures, and transport-error precedence.
  These callbacks are simulated; they do not measure the CloudKit service.
- Persistence tests observe actual query-helper executions for 1,801 keys,
  enforce chunks of at most 900 keys, and cover namespace isolation, cyclic
  dependency frontiers, and incremental/full-materialization equivalence.
- CSV tests cover chunk boundaries, BOM and quoted CRLF handling, header and
  template compatibility, early table/aggregate limits, source ownership, and
  substitution between review and activation. Archive tests cover digest,
  approval and receipt equivalence, staged tampering, cancellation cleanup,
  adopted-stage ownership, and retry recovery after recreating the store.

The native configuration has no organization provider. Populated inventory and
hierarchy rendering, live CloudKit behavior, device-only integrations, signing,
and deployment were not verified. The GitHub workflow includes the native gate;
these results came from local runs, not hosted CI.

## Measurement method

The machine was an Apple M4 MacBook Air with 16 GiB RAM, macOS 26.6.2
(25G83), Xcode 26.6 (17F113), and Apple Swift 6.3.3. Builds used Release
optimization and warnings as errors, with command-local `DEVELOPER_DIR`.

The baseline was copied before production edits. Only the additive benchmark
target and harness were supplied to that copy. Both implementations used the
same fixtures:

- IPAM: 2,048 IPv4 /24 prefixes and 2,048 contained addresses in one VRF.
- Trace: a 512-segment physical chain. The measured count/length checksum is
  identical; the new summary also explicitly reports its segment-limit boundary.
- CSV: four tables of 30,000 rows, 120,000 records total, with 512-character
  name payloads; the CSV files total 63,375,751 bytes.
- Archive: four 16 MiB assets, 64 MiB total, with empty record and audit entries.

Two sequential baseline/optimized series each used five repetitions, giving
ten samples per reported workload. Domain workloads had one warmup per series.
Each file measurement ran in a fresh process after separate fixture generation.
Other task builds had completed; normal operating-system and desktop activity
remained. Filesystem caches were not reset. The tables retain all samples from
both series, including the substantial timing variation.

Timing ends at validation, summary calculation, CSV record decoding, or archive
verification. `/usr/bin/time -l` supplies whole-process peak resident memory.
Neither metric includes domain import planning, restore activation, or network
transfer. Checksums and record counts matched across applicable paths.

## Observed results

Times are milliseconds, shown as median (minimum–maximum).

| Workload | Baseline | Optimized |
| --- | --- | --- |
| IPAM validation | 180.431 (176.585–183.657) | 10.587 (7.329–19.073) |
| Physical trace summary metrics | 3.161 (2.590–3.652) | 0.995 (0.678–1.334) |
| CSV compatibility API | 1,826.125 (1,673.363–2,338.800) | 2,128.517 (1,671.142–3,156.149) |
| CSV file-backed API | 1,826.125 (1,673.363–2,338.800) | 1,978.403 (1,681.799–3,125.626) |
| Archive compatibility API | 41.883 (38.492–49.067) | 48.315 (39.139–71.311) |
| Archive file-backed API | 41.883 (38.492–49.067) | 78.553 (62.097–108.883) |

File-backed rows compare the new path with the original in-memory path for
the same source files. Their work differs: archive verification now copies
entries into protected private staging as well as hashing them.

Peak resident memory is MiB, shown as median (minimum–maximum).

| Workload | Baseline | Optimized |
| --- | --- | --- |
| CSV compatibility API | 216.094 (216.078–217.125) | 209.930 (208.703–211.125) |
| CSV file-backed API | 216.094 (216.078–217.125) | 210.805 (210.719–211.938) |
| Archive compatibility API | 132.828 (132.812–132.844) | 132.922 (117.312–132.984) |
| Archive file-backed API | 132.828 (132.812–132.844) | 77.391 (77.328–77.438) |

On these inputs, the observed median IPAM and summary times improved. Native
archive verification reduced median peak memory by 41.7%, while its median
elapsed time increased by 87.6%. CSV file-backed decoding reduced median peak
memory by 2.4%, while its median elapsed time increased by 8.3%. These results
establish no CSV speedup or compatibility-archive memory improvement. They are
local fixture measurements, not network or application-wide speed claims.

### Remaining domain-array memory

CSV decoding still returns all 120,000 domain records in this fixture. The
file-backed peak remains about 211 MiB even after removing aggregate raw CSV
buffers and intermediate row matrices. Whole-process RSS includes the record
array, parser state, allocator retention, and runtime overhead; this measurement
does not isolate bytes attributable only to domain records. Planning retains
its existing bounded arrays and may use additional memory beyond this benchmark.

Archive verification keeps metadata and digests instead of an aggregate
payload dictionary. Restore decoders can still materialize one entry up to
64 MiB, and domain-record arrays remain bounded by existing limits. The empty
record/audit archive fixture does not measure those arrays. Both benchmark runs
left their private preview-staging directories empty after cleanup.

## Reproduction and evidence

Run `make benchmark` with the full Xcode toolchain selected. The harness and
baseline compilation option are described in
[DEVELOPMENT.md](DEVELOPMENT.md#reproducible-performance-measurements).
Wall-clock thresholds are deliberately absent from ordinary CI.

Local raw samples, per-series summaries, environment reports, source hashes,
the pooled summary, and final gate logs are retained under
`artifacts/benchmarks/optimization-2026-09-06/`. Its `provenance` directory also
contains `baseline-core.tar.gz`, a source-only baseline package with the
benchmark harness, so the comparison does not depend on the temporary checkout.
These generated artifacts are ignored by Git and are not part of a fresh clone.
The current benchmark can be run from the published source, but reproducing
this exact before-and-after comparison requires the retained baseline and raw
samples. The tables above summarize the local run; they are not independently
reproducible from this checkout alone.
