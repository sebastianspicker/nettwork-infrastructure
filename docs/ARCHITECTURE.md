# Architecture

<!-- markdownlint-disable MD013 -->

## System context

Nettwork is a SwiftUI app for documenting network infrastructure in a shared
organization workspace. The native app presents inventory, topology, IPAM,
floor plans, tracing, work orders, labels, reconciliation, administration, and
transfer workflows. It keeps a durable local SwiftData mirror and coordinates
authorized, account-scoped state with CloudKit.

Configured builds store authoritative workspace records in CloudKit. SwiftData
keeps a local copy, pending changes, a search index, and recovery state. Access
to that local state is tied to the current account session. There is no separate
backend server in this repository. The checked-in build has no
organization provider and therefore starts unconfigured rather than creating a
placeholder workspace.

New here? Read this page top to bottom once, then open the files in this
order: [NettworkApp.swift](../NettworkApp/Composition/NettworkApp.swift)
(entry point), [ProductionAppLaunch.swift](../NettworkApp/Composition/Runtime/ProductionAppLaunch.swift)
(startup), [TopologyWorkspaceModel.swift](../NettworkApp/Presentation/Features/Topology/TopologyWorkspaceModel.swift)
(a typical screen model), [TopologyWorkOrderContracts.swift](../Packages/NettworkCore/Sources/FeatureContracts/TopologyWorkOrderContracts.swift)
(the port it talks to), and [CloudForegroundSyncCoordinator.swift](../Packages/NettworkCore/Sources/CloudSync/CloudForegroundSyncCoordinator.swift)
(how data arrives).

What runs where, and what talks to what:

```mermaid
flowchart LR
    operator((Operator))
    subgraph device [iPhone, iPad or Mac]
        app[Nettwork app]
        platform[Platform adapters]
        mirror[(SwiftData mirror)]
        staging[(Private staging dirs)]
    end
    subgraph org [Organization iCloud]
        cloud[(CloudKit container)]
    end
    subgraph pages [GitHub Pages]
        demo[Static demo]
    end
    operator -->|taps and edits| app
    operator -.->|browses sample data| demo
    app -->|"camera, files, print"| platform
    app -->|"reads, outbox"| mirror
    app -->|"attachments, transfers"| staging
    app -->|"fetch changes, atomic saves"| cloud
```

Everything native runs in one app process per device; there is no server of
our own. The app reads only from the local `mirror` and writes authoritative
changes straight to `cloud` as conditional atomic saves. The `Alpha Local`
build swaps CloudKit for an on-device record store
(`LocalWorkspaceRecordTransport`) behind the same transport protocol. The
static demo is a separate artifact. It does not share runtime state or
services with the native app.

## Components and dependency direction

`NettworkCore` contains eight Swift library products. Arrows below point from a
module to a dependency. Only direct layering is drawn; every module may also
use anything its dependencies depend on (for example, everything reaches
`NetworkModel`):

```mermaid
flowchart TD
    subgraph appTarget [NettworkApp target]
        Composition
        Presentation
        AppPlatform[Platform]
    end
    subgraph core [NettworkCore package]
        Services[WorkspaceServices]
        Contracts[FeatureContracts]
        CloudSync
        Persistence
        ImportExport
        ContentSafety
        WCC[WorkspaceChangeControl]
        Model[NetworkModel]
    end
    Composition --> Presentation
    Composition --> AppPlatform
    Composition --> Services
    Presentation --> Contracts
    AppPlatform --> Contracts
    Services --> Contracts
    Services --> CloudSync
    Contracts --> ImportExport
    ImportExport --> ContentSafety
    CloudSync --> Persistence
    Persistence --> WCC
    ContentSafety --> WCC
    WCC --> Model
    classDef focus fill:#fde68a,stroke:#b45309,color:#1f2937
    class Contracts focus
```

`FeatureContracts` is the seam: screens in `Presentation` and adapters in
`Platform` see only its protocols, and `WorkspaceServices` implements them on
top of `CloudSync` and `Persistence`. Only `Composition` knows both sides and
wires them together.

The exact package graph is declared in `Packages/NettworkCore/Package.swift`
and enforced by `scripts/check-architecture.sh`. Its import rules match every
import form, including attributed imports (`@preconcurrency`, `@_exported`,
`@testable`) and declaration imports such as `import class SwiftData.ModelContext`.
The same check enforces these rules:

- No `NettworkCore` target imports SwiftUI, UIKit, or AppKit. Only `CloudSync`
  imports CloudKit, and only `Persistence` and `WorkspaceServices` may import
  SwiftData.
- `NetworkModel` stays independent of change-control and infrastructure
  modules, and `FeatureContracts` may not import `Persistence` or `CloudSync`.
- Presentation may not import CloudKit, SwiftData, `Persistence`, `CloudSync`,
  or `WorkspaceServices`. `NettworkApp/Platform` may not import SwiftData,
  CloudKit, `Persistence`, `CloudSync`, or `WorkspaceServices`.
- Presentation, Platform, and Composition share the app module, so the script
  also checks type names. Presentation may not name a type declared in
  Platform or Composition, and Platform may not name a type declared in
  Presentation or Composition. Only Composition reaches into the other two
  layers: it injects the Presentation-owned `WorkspaceShellState` and supplies
  destinations through `AppDestinationProviding`. It also builds the system
  Platform adapters in `Composition/Runtime`.

| Component | Responsibility |
| --- | --- |
| `NetworkModel` | Codable and Sendable records, identifiers, topology, hierarchy, templates, tracing, IPAM/VLAN rules, and validation |
| `WorkspaceChangeControl` | Authorized operation contexts, work orders, reservations, planned operations, activation, audit records, and mutation contracts |
| `Persistence` | SwiftData schema history and migration, local mirror, outbox, conflict/quarantine evidence, attachments, and search materialization |
| `CloudSync` | CloudKit transport contracts, remote validation, conditional atomic writes, receipt recovery, staged transfer, sessions, and foreground synchronization |
| `ContentSafety` | Bounded attachment decoding, allowlisting, sanitization, hashing, private staging, quotas, and evidence binding |
| `ImportExport` | Exact CSV schemas, archive formats, bounded parsing, verification, staged transfer, approval, export, and restore |
| `FeatureContracts` | UI-facing service protocols and the snapshot, request, and error values that Presentation consumes and WorkspaceServices implements |
| `WorkspaceServices` | Production feature services: session authorization, organization authorities, work-order mutation and planning, SwiftData read adapters and mirror projection, attachment and floor-plan evidence (including bounded PDF inspection and preview decoding), workspace transfer, sync state stores, OSLog sync telemetry, and audit export |
| `NettworkApp/Presentation` | SwiftUI shell and its workspace sync state (`Shell/WorkspaceShellState.swift`), navigation state and `nettwork://` route parsing (`Shell/Navigation.swift`), screens, feature models, view state, and document presentation |
| `NettworkApp/Platform` | Apple-platform adapters behind FeatureContracts ports: camera capture, user-selected files and archive packages, PDF labels and printing, and pasteboard |
| `NettworkApp/Composition` | App entry point, feature registry and optional feature capabilities, dependency injection, bootstrap, startup, and shutdown; `Composition/Runtime` assembles the production graph from organization input and CloudKit, one file per graph (foundation, cloud, attachment, transfer, organization authorities, floor plan, feature input) plus assembly validation and the system Platform capability factories |

## How the app starts

The `NettworkApp` entry point owns a `ProductionAppLaunchController` for the
SwiftUI scene lifetime. Startup is intentionally fail-closed:

```mermaid
flowchart TD
    Start[SwiftUI scene starts] --> Lookup{Configured provider name?}
    Lookup -- No --> Offline[Unconfigured feature graph and offline status]
    Lookup -- Yes --> Resolve[Resolve NSObject-backed provider]
    Resolve --> Input[Build and validate organization input]
    Input --> Assembly[Assemble storage, CloudKit, governance, and platform graph]
    Assembly --> Activate[Activate account and workspace session]
    Activate --> Verify[Verify membership and current authorization]
    Verify --> Lease[Acquire local namespace lease and reconcile identities]
    Lease --> Bootstrap[Inject features and run foreground synchronization]
    Resolve -. error .-> Failed[Visible startup failure]
    Input -. error .-> Failed
    Activate -. error .-> Failed
```

Assembly activates and verifies the account-scoped workspace before returning
the production graph. Bootstrap re-runs the idempotent activation boundary
before foreground synchronization. Failure invalidates the current session and
does not expose a permissive local workspace.

The organization provider supplies the `ModelContainer`, private directories,
CloudKit account and container, membership and sharing services, actor and
installation identity, operation policies, authorizations, transfer sources
and destinations, and telemetry stores. Each SwiftUI scene owns a weak iOS
presentation context and supplies system scan and label adapters. An
organization may replace that complete capability set through its assembly
input. See [CONFIGURATION.md](CONFIGURATION.md).

Where in the code:

- [NettworkApp.swift](../NettworkApp/Composition/NettworkApp.swift): `@main` scene and scene-phase hooks.
- [ProductionAppLaunch.swift](../NettworkApp/Composition/Runtime/ProductionAppLaunch.swift): provider lookup and `ProductionAppLaunchController`.
- [ProductionRuntimeAssembly.swift](../NettworkApp/Composition/Runtime/ProductionRuntimeAssembly.swift) and the `ProductionRuntime*Graph.swift` files beside it: graph assembly.
- [AppBootstrap.swift](../NettworkApp/Composition/AppBootstrap.swift): `ProductionAppBootstrapService`, activation and first sync.

## Data flows

### Foreground synchronization

What happens when the user taps **Sync now** (scene activation takes the same
path from step 3):

```mermaid
sequenceDiagram
    autonumber
    actor U as Operator
    participant shell as AppShell
    participant deps as AppDependencies
    participant sync as CloudForegroundSyncCoordinator
    participant ck as CloudKit
    participant mirror as SwiftDataCloudMirrorStore
    U->>shell: Sync now
    shell->>deps: onSynchronizeRequest
    deps->>sync: synchronizeForeground()
    sync->>ck: verify membership
    sync->>ck: fetchChanges()
    ck-->>sync: CloudChangeBatch
    sync->>mirror: validateRemoteReferences
    alt batch valid
        sync->>mirror: applyVerifiedBatch (one transaction)
        sync->>ck: replay outbox
    else batch rejected
        sync->>mirror: quarantine records
    end
    sync-->>deps: SyncReceipt
    deps-->>shell: syncStatus
```

`AppDependencies` drops a request while another sync is running (step 3), and
`ProductionAppBootstrapService` re-activates the session first if it lapsed.
Before validating, applying, and replaying, the coordinator checks that the session lease is still
current, so an account switch mid-sync stops the run instead of writing into
the wrong workspace. Step 8 is the only place remote records enter the mirror,
and it is all-or-nothing.

Where in the code: [AppShell.swift](../NettworkApp/Presentation/Shell/AppShell.swift),
[AppDependencies.swift](../NettworkApp/Composition/AppDependencies.swift),
[CloudForegroundSyncCoordinator.swift](../Packages/NettworkCore/Sources/CloudSync/CloudForegroundSyncCoordinator.swift),
[CloudKitRecordTransport.swift](../Packages/NettworkCore/Sources/CloudSync/CloudKitRecordTransport.swift),
[SwiftDataCloudMirrorStoreApply.swift](../Packages/NettworkCore/Sources/CloudSync/SwiftDataCloudMirrorStoreApply.swift),
[OutboxRecovery.swift](../Packages/NettworkCore/Sources/CloudSync/OutboxRecovery.swift)
(`CloudOutboxReplayer`). The same steps in words:

1. Verify the current account, workspace membership, actor, installation
   session, and local namespace lease.
2. Fetch a bounded remote batch and validate record schemas and references.
3. Apply the entire verified batch atomically to the SwiftData mirror. Rejected
   records are quarantined; the coordinator does not apply a valid subset of an
   invalid batch.
4. Replay eligible outbox work in dependency and shared-resource order.
5. Persist cursor and recovery state and return queue, conflict, quarantine,
   failure, and last-contact signals to the UI.

Account or session changes revoke the old namespace lease and purge ephemeral
state so stale callbacks cannot write into a new workspace.

Incremental search maintenance batches dependency frontiers, projected nodes,
incident edges, and affected entries in deterministic predicates of at most
900 keys. Source and target edge queries remain separate, with results
deduplicated by storage key. Namespace leases, transaction boundaries,
traversal limits, and the full-rebuild fallback remain authoritative.

### Inventory and topology reads

Favorites and recents share one inventory-result batch. The production adapter
uses one mirror projection and materializes inventory rows once, without
loading detail attachments, audit summaries, or traces. History publication is
bound to both session identity and the current history generation.

Read adapters reuse their last projection while a persisted mirror fingerprint
(row count, maintenance and visibility stamps, conflicts, and sync state) is
unchanged, so other stores on the same container also invalidate it. Audit
history is not part of the projection: object details, audit search, and
operations reports read the newest 5,000 audit events with a bounded query.

A successful topology snapshot carries an immutable index from parent IDs to
localized, sorted children. Recursive rows use this index for traversal and
expansion affordances. Physical inventory summaries use an iterative traversal
bounded to 128 explored paths and 512 segments by default; partial results
explicitly identify the limit. The public physical and rich trace APIs retain
their existing contracts.

IPAM validation indexes canonical prefixes by VRF, address family, network, and
length. Address checks examine ancestor prefixes, including reservations in
all containing prefixes. The index is transient and changes no stored schema.

### Controlled mutations and work orders

Presentation submits intent through feature contracts; it never grants
authority. WorkspaceServices derives current authority from the verified Cloud
session, actor, installation session, workspace lease, and organization policy,
then checks any presentation values for an exact match.

What happens when the user connects two ports and carries the change through
a work order:

```mermaid
sequenceDiagram
    autonumber
    actor U as Operator
    participant topo as TopologyWorkspaceModel
    participant ops as OperationsFeatureViewModel
    participant auth as ProductionFeatureMutationAuthority
    participant repo as CloudAuthoritativeMutationRepository
    participant ck as CloudKit
    U->>topo: Select two ports, Connect, Stage
    topo->>auth: stageTopology(request)
    auth-->>topo: work-order ID (draft only)
    U->>ops: Reserve
    ops->>auth: reserve(draft)
    auth->>repo: commit reservation
    repo->>ck: saveAtomically
    ck-->>repo: OperationReceipt
    auth->>repo: commit acknowledgement
    U->>ops: Begin execution, then Complete
    ops->>auth: beginExecution / complete(evidence)
    auth->>repo: commit transition
    repo->>ck: saveAtomically
```

Staging (steps 1–3) only stores a draft in the organization-supplied draft
store; nothing authoritative changes. The screen models reach `auth` through
the `FeatureContracts` adapters `AuthorizedWorkOrderDraftAdapter` and
`SwiftDataOperationsAdapter`; approval and cancellation are left out of the
diagram. Each later step re-verifies the session
and goes through `repo`, the single privileged write path: it validates the
mutation against fresh state, sends one conditional atomic save, and on a
lost response looks up the deterministic receipt instead of retrying. Other
devices see the result on their next sync. IPAM and template changes take the
same route via `stageIPAM` and `stageTemplate`.

Where in the code: [TopologyWorkspaceModel.swift](../NettworkApp/Presentation/Features/Topology/TopologyWorkspaceModel.swift)
(`prepareConnect`, `stage`),
[OperationsFeatureViewModel+Lifecycle.swift](../NettworkApp/Presentation/Features/Operations/OperationsFeatureViewModel+Lifecycle.swift),
[AuthorizedWorkOrderDraftAdapter.swift](../Packages/NettworkCore/Sources/WorkspaceServices/WorkOrders/AuthorizedWorkOrderDraftAdapter.swift),
[SwiftDataOperationsAdapter.swift](../Packages/NettworkCore/Sources/WorkspaceServices/Reads/SwiftDataOperationsAdapter.swift),
[ProductionFeatureMutationAuthority.Staging.swift](../Packages/NettworkCore/Sources/WorkspaceServices/WorkOrders/ProductionFeatureMutationAuthority.Staging.swift),
[ProductionFeatureMutationAuthority.Reservations.swift](../Packages/NettworkCore/Sources/WorkspaceServices/WorkOrders/ProductionFeatureMutationAuthority.Reservations.swift),
[CloudAuthoritativeMutationRepository.swift](../Packages/NettworkCore/Sources/CloudSync/CloudAuthoritativeMutationRepository.swift),
[WorkOrderLifecycle.swift](../Packages/NettworkCore/Sources/WorkspaceChangeControl/WorkOrderLifecycle.swift).

Topology and IPAM changes are staged as work-order operations. The production
authority validates exact current records, reserves affected resources with an
atomic Cloud mutation, obtains a separate server acknowledgement, and enforces
the work-order lifecycle. Execution and completion require a fresh matching
intent and acknowledgement. Completion revalidates model invariants before one
bounded conditional mutation. Cancellation must release reservations or carry
the explicit emergency-override evidence required by policy.

Deletion preconditions are fetched in one CloudKit operation for the bounded
mutation page. Every requested record and change tag must validate before the
atomic mutation proceeds; sentinel fencing remains part of that mutation.
Indeterminate CloudKit writes are resolved through deterministic receipts.
They are not blindly retried.

### Attachments and transfer

Attachment input is read through an opaque, bounded source. The content-safety
service verifies declared type against bytes, rejects unsupported or oversized
content, sanitizes accepted images or PDFs, hashes the result, stages it in a
private directory, and revalidates authorization around staging and binding.
Callers do not receive staging paths.

CSV import and archive restore use a separate activation path:

1. Parse and validate bounded input against exact, versioned formats.
2. Build a canonical candidate and dry-run report.
3. Require current administrator/write authorization and an empty, fresh target
   workspace.
4. Upload invisible staged records in bounded batches and verify their rolling
   digest.
5. Activate the workspace with one final conditional sentinel mutation.

The native CSV directory source reopens bounded byte streams for review and
activation while retaining security-scoped access. A throwing row callback
validates headers and constructs records directly. Raw CSV files and complete
row matrices are not retained together; the bounded domain-record planning
arrays remain part of the transfer contract.

Native archive verification copies and hashes entries into protected private
staging in fixed-size chunks, then closes the selected source. Its descriptor
retains metadata and digests behind an opaque payload handle. The preview owns
that staging until the restore store adopts it. Closing an old preview cannot
delete adopted staging. Terminal failures clean up; retryable failures retain
the durable sidecar under the transfer cleanup policy. Restore consumers read
one verified entry at a time and may materialize an individual entry within
the existing 64 MiB limit. Native upload envelopes retain verified durable-file
capabilities instead of aggregate inline asset bytes. Preflight verification
uses `.verification` beneath the configured archive restore staging root,
separate from operation directories. The in-memory archive interfaces remain
available, including legacy activation authorities.

At launch, the runtime removes staging that an earlier app kill left behind:
only items under the attachment staging, archive verification, and audit export
roots that carry the app's `.nettwork-staging` marker and are older than the
staging lifetime. Restore operation directories and CSV staging keep their
durable sidecars and are never swept.

Archive checksums establish integrity against accidental change; they do not
prove authenticity against a malicious archive writer.

## Data model

The core records and how they reference each other (IDs only; templates,
modules, work orders, and audit records are left out):

```mermaid
erDiagram
    Location ||--o{ Location : "parentID"
    Location ||--o{ Rack : "locationID"
    Rack ||--o{ Device : "rackID"
    Device ||--o{ Port : "deviceID"
    Port ||--o{ Cable : "endpointA / endpointB"
    Device ||--o{ Interface : "deviceID"
    Port |o--o{ Interface : "physicalPortID"
    VRF ||--o{ Prefix : "vrfID"
    VRF ||--o{ IPAddressRecord : "vrfID"
    Interface |o--o{ IPAddressRecord : "assignedInterfaceID"
    VLAN ||--o{ InterfaceVLANMembership : "vlanID"
    Interface ||--o{ InterfaceVLANMembership : "interfaceID"
```

`Location` through `Cable` is the physical side (where things are and how
they are cabled); `VRF`, `Prefix`, addresses, and VLANs are IPAM. `Interface` bridges the two. A `Cable` joins
exactly two ports, which is what trace walks. Addresses belong to a `VRF`, not
to a `Prefix`; the containing prefix is computed by the IPAM prefix index. All
records are plain Codable structs that the mirror and CloudKit store as
encoded records, so the schema lives in Swift, not in a database definition.

Where in the code: [Topology.swift](../Packages/NettworkCore/Sources/NetworkModel/Topology.swift)
(`Location`, `Rack`), [TopologyTemplates.swift](../Packages/NettworkCore/Sources/NetworkModel/TopologyTemplates.swift)
(`Device`), [TopologyConnections.swift](../Packages/NettworkCore/Sources/NetworkModel/TopologyConnections.swift)
(`Port`, `Cable`), [IPAMPrefixes.swift](../Packages/NettworkCore/Sources/NetworkModel/IPAMPrefixes.swift)
(`Prefix`, `VRF`), [IPAMRecords.swift](../Packages/NettworkCore/Sources/NetworkModel/IPAMRecords.swift)
(addresses, VLANs, interfaces), [WorkspaceRecordType.swift](../Packages/NettworkCore/Sources/WorkspaceChangeControl/WorkspaceRecordType.swift)
(the full list of synced record types).

## State ownership

| State | Owner and role |
| --- | --- |
| Authoritative workspace records and mutation receipts | Organization CloudKit private/shared databases |
| Local records, migrations, outbox, conflicts, quarantine, and search index | One namespace-scoped SwiftData store and revocable lease |
| Attachments and transfer staging | Distinct organization-provided private directories |
| Work-order reservations and audit evidence | Cloud-authoritative records mirrored locally |
| Sync and operation telemetry | Privacy-safe aggregate events plus organization-provided retention and metrics stores |
| Static demo state | In-memory browser state seeded only from `site/mock-data.js` |

## External and security boundaries

- The URL route `nettwork://object/<UUID>` uses an opaque object identifier; a
  route identifies an object but does not authorize access.
- CloudKit private and shared databases, account membership, share acceptance,
  subscription state, and schema are organization-owned service state.
- Client role checks are application policy. They do not protect a workspace
  from a hostile participant who independently has write access to CloudKit.
- Administrator authorization is required for privileged transfer and audit
  operations. Authorization is revalidated around sensitive side effects.
- Camera scanning accepts opaque Nettwork identifiers. The iOS scanner and
  label export/printing adapters present only through the owning scene's weak
  presentation context; they never search global application windows. macOS
  deliberately uses manual scan input and native label export/printing. Files,
  PDF, printing, and telemetry integrations remain behind platform or feature
  contracts.
- OSLog telemetry records operational outcomes and aggregates, not customer
  record contents. The organization still owns telemetry storage and retention.
- Local staging paths, signing assets, credentials, production identifiers, and
  organization configuration must not be committed.

## Build and deployment boundaries

`project.yml` is the source of truth for the generated Xcode project. The iOS
and macOS targets compile the same app source and all eight package products, with
platform-specific entitlements. `Nettwork.xcodeproj`,
SwiftPM `.build`, DerivedData, test results, and coverage output are generated.

CI runs the source gate and the Swift package build on macOS, then
generates the Xcode project and builds the macOS and iOS Simulator apps. These unsigned checks do not verify production signing, live
CloudKit, or device-only integrations. The separate Pages workflow validates
and deploys only `site/`.

## Placement rules and extension points

| Change | Location |
| --- | --- |
| Topology/IPAM type, invariant, trace, or template rule | `Packages/NettworkCore/Sources/NetworkModel` |
| Work order, reservation, audit, authorization, or mutation contract | `Packages/NettworkCore/Sources/WorkspaceChangeControl` |
| SwiftData model, migration, outbox, local query, or search index | `Packages/NettworkCore/Sources/Persistence` |
| Cloud record, remote validation, session, transport, or sync logic | `Packages/NettworkCore/Sources/CloudSync` |
| Attachment admission, decoding, sanitization, or evidence binding | `Packages/NettworkCore/Sources/ContentSafety` |
| CSV/archive format or staged transfer workflow | `Packages/NettworkCore/Sources/ImportExport` |
| Feature service protocol, snapshot, or request type shared by screens and services | `Packages/NettworkCore/Sources/FeatureContracts` |
| Production feature service, authority, SwiftData read adapter, or transfer workflow | `Packages/NettworkCore/Sources/WorkspaceServices` |
| Screen, feature model, or SwiftUI document-picker presentation | `NettworkApp/Presentation` |
| Production runtime assembly, organization input, or CloudKit wiring | `NettworkApp/Composition/Runtime` |
| File/document adapter or Apple-platform bridge | `NettworkApp/Platform` |

Add new organization-specific implementations through the production assembly
input and existing feature/platform protocols. Keep organization identities and
policy values outside reusable package modules.

## Scope and limitations

- The repository does not provide a standalone server. The default build has
  no fallback local-only mode; the separate `Release Alpha Local` build
  configuration selects the stage-1 local runtime (`LocalRuntimeOrganizationInputProvider`
  in `NettworkApp/Composition/Runtime`), which runs fully offline against a
  durable on-device record store with a single local administrator and no
  sharing. See [Production configuration](CONFIGURATION.md#alpha-local-runtime).
- The static demo is not a simulator, data migration tool, or service client.
- The local mirror is not an independent authority and must not outlive its
  account-scoped lease.
- The package does not embed an organization CloudKit container, signing setup,
  access policy, deployment process, or credential store.
