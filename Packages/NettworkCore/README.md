# NettworkCore

<!-- markdownlint-disable MD013 -->

`NettworkCore` contains the Swift libraries shared by the iOS and macOS apps.
They model network equipment and connections, coordinate work orders, store and
synchronize workspace data, validate attachments, and import or export records.
The package is developed here alongside the app; it is not published as a
separately versioned dependency.

## Requirements

- Swift tools and language mode 6
- iOS 18 or later, or macOS 15 or later

The package declares no third-party package dependencies.

## Library products

| Product | Responsibility | Direct product dependencies |
| --- | --- | --- |
| `NetworkModel` | Codable/Sendable topology, hierarchy, templates, tracing, identifiers, IPAM/VLAN, and validation | None |
| `WorkspaceChangeControl` | Authorization contexts, work orders, reservations, planned operations, activation, mutation contracts, and audit records | `NetworkModel` |
| `Persistence` | SwiftData schema/migrations, local mirror, outbox, conflicts, attachments, maintenance, and search index | `NetworkModel`, `WorkspaceChangeControl` |
| `CloudSync` | CloudKit contracts, remote validation, sessions, conditional writes, recovery receipts, staged transfer, and foreground sync | `NetworkModel`, `WorkspaceChangeControl`, `Persistence` |
| `ContentSafety` | Bounded attachment decoding, sanitization, hashing, private staging, quota, and evidence binding | `NetworkModel`, `WorkspaceChangeControl` |
| `ImportExport` | Exact CSV/archive formats, bounded parsing, staging, verification, approval, export, and restore | `NetworkModel`, `WorkspaceChangeControl`, `ContentSafety` |
| `FeatureContracts` | UI-facing feature service protocols and their snapshot, request, and error values | `NetworkModel`, `WorkspaceChangeControl`, `ContentSafety`, `ImportExport` |
| `WorkspaceServices` | Production implementations of the feature contracts: session authorization, work-order mutation, SwiftData read adapters, evidence, transfer, sync state, and audit export | `NetworkModel`, `WorkspaceChangeControl`, `Persistence`, `CloudSync`, `ContentSafety`, `ImportExport`, `FeatureContracts` |

The manifest and `scripts/check-architecture.sh` enforce this dependency
direction. See [the architecture guide](../../docs/ARCHITECTURE.md) for the app
composition, runtime flows, state ownership, and security boundaries around
these libraries.

## Choosing a product

Use the narrowest product that owns the required behavior:

- Start with `NetworkModel` for pure network records and invariants.
- Add `WorkspaceChangeControl` when changes require authorization, reservation,
  work-order lifecycle, or audit intent.
- Add `Persistence` only for SwiftData-backed local state.
- Add `CloudSync` for CloudKit transport, remote validation, authoritative
  mutation, session, or synchronization behavior.
- Add `ContentSafety` for bounded attachment admission and evidence binding.
- Add `ImportExport` for CSV/archive formats and staged workspace transfer.
- Add `FeatureContracts` for the protocols and values shared by app screens and
  the services that back them.
- Add `WorkspaceServices` only from app composition, which assembles the
  production services; screens depend on `FeatureContracts` instead.

`CloudSync` provides transport and synchronization contracts but does not choose
an organization CloudKit container, account, share policy, schema deployment,
or credential source. Those are application-composition responsibilities.

## Behavioral contracts

- `NetworkModel` validates aggregate invariants around commands and uses stable
  operation identifiers for idempotence.
- Authorized operation contexts are account-, actor-, installation-, and
  session-generation scoped; stale or mismatched contexts are rejected.
- A SwiftData namespace lease is revoked on account/session change so delayed
  work cannot write into another workspace.
- Verified remote batches apply atomically. Invalid records are quarantined
  rather than partially applied.
- Conditional Cloud writes use deterministic receipts to resolve indeterminate
  outcomes before any retry.
- Attachment admission is bounded and opaque; callers do not receive private
  staging paths.
- CSV schemas and header order are exact and versioned. Archive restore requires
  verification, explicit approval, current authorization, and a fresh distinct
  target. Checksums establish integrity, not writer authenticity.

Treat public Codable representations, stable identifiers, schema versions,
archive/CSV formats, migration history, mutation receipts, and authorization
semantics as compatibility boundaries.

## Build and test

From the repository root:

```sh
make check-architecture
make verify-package
```

From this directory:

```sh
swift package dump-package
swift build
swift test
```

Tests are split by production product under `Tests/`. SwiftPM output in
`.build/` and `.swiftpm/` is generated and must not be edited or documented as
source.

The package tests use local adapters and test doubles. Passing them does not
verify a real CloudKit container, production authorization policy, signing,
security-scoped files, camera capture, printing, or physical-device behavior.
