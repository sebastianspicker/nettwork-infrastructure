# Production configuration

<!-- markdownlint-disable MD013 -->

## Start here

The default project opens without a connected organization workspace.
`Config/Base.xcconfig` uses example bundle/container values, supplies no Apple
Developer team or signing identity, and leaves
`NETTWORK_PRODUCTION_CONFIGURATION_PROVIDER` empty. With that default, the app
starts with an unconfigured feature graph and an offline status.

This guide describes what your integration must provide. You will need to
implement a configuration provider in the app target and supply your own
CloudKit setup, access rules, storage, and retention policy.

## Build settings and entitlements

| Setting | Checked-in behavior | Organization responsibility |
| --- | --- | --- |
| `PRODUCT_BUNDLE_IDENTIFIER` | Example iOS and macOS identifiers in `project.yml` | Set registered identifiers for each target |
| Apple Developer team/signing | Not set | Configure team, certificates, provisioning, and distribution |
| `NETTWORK_ICLOUD_CONTAINER` | `iCloud.com.example.nettwork` | Set a provisioned organization container |
| `NETTWORK_CLOUDKIT_ENVIRONMENT` | Development for Debug, Production for Release | Deploy and verify the corresponding CloudKit schema and service state |
| `NETTWORK_APNS_ENVIRONMENT` | Development for Debug, production for Release | Provision push entitlements for each signed target |
| `NETTWORK_PRODUCTION_CONFIGURATION_PROVIDER` | Empty | Name a provider class compiled into the app target |

Both targets request CloudKit and push entitlements. The macOS target also uses
the App Sandbox with the outgoing network-client, user-selected file
read/write and printing entitlements. The iOS Info.plist
declares camera use for scanning asset labels and the `nettwork` URL scheme.

Keep local overrides and credentials outside version control. The repository
ignores `*.local.xcconfig`, `Config/Local.xcconfig`, environment files, signing
keys, certificates, and provisioning profiles. There is no checked-in include
chain or secret-loading convention for a local configuration file, so integrate
organization settings through the organization's Xcode/XcodeGen or CI setup
rather than assuming an undocumented file is loaded.

## Configuration provider

At launch, `ProductionAppLaunchConfiguration` reads the
`NettworkProductionConfigurationProvider` Info.plist value, resolves that class
with `NSClassFromString`, verifies that it is `NSObject`-backed and conforms to
`ProductionRuntimeOrganizationInputProviding`, constructs it, and requests a
`ProductionRuntimeAssembly.OrganizationInput`.

The provider therefore must be compiled into the application module and
reachable by its configured runtime class name. It is an application composition
extension point, not a dynamically downloaded plugin or an environment-variable
configuration object. The protocol and assembly input are internal app types;
an organization build must add its provider to the app target rather than
expecting a standalone binary package to configure Nettwork. The policy values
and service protocols that the input carries come from the `WorkspaceServices`
package product, so provider source imports it.

An absent provider is a supported unconfigured state. A blank/malformed value,
unresolvable class, invalid organization input, or startup failure produces a
visible failure and no production feature graph.

## Alpha Local runtime

The `Release Alpha Local` build configuration (`Config/AlphaLocal.xcconfig`,
Release-based) sets `NETTWORK_PRODUCTION_CONFIGURATION_PROVIDER` to the in-repo
`NettworkLocalRuntimeProvider`. `Config/Base.xcconfig` stays empty, so Debug and
Release builds remain unconfigured. Build it with the `Nettwork Alpha Local`
(iOS) or `Nettwork macOS Alpha Local` scheme after `make generate`, or:

```sh
make generate
xcodebuild -project Nettwork.xcodeproj -scheme 'Nettwork Alpha Local' \
  -configuration 'Release Alpha Local' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

What the local runtime does:

- Runs fully offline. The authoritative records live in a durable file store on
  the device; nothing is sent to CloudKit or any other service, and the
  SwiftData mirror has CloudKit sync disabled.
- Creates one local identity and one owner-private workspace on first launch and
  reuses them afterwards. The single local user is the workspace administrator;
  that role exists only through this provider and is still re-verified against
  the persisted identity on every privileged operation.
- Starts with an empty workspace. Add data with a CSV import or an archive
  restore from the Transfer screen; floor plans, evidence, CSV folders and
  archives are picked in the app, and CSV exports use the in-app file exporter.
- Keeps everything below Application Support `Nettwork/LocalRuntime/v1/`:
  `identity.json`, `workspaces/<workspaceID>/server/` (record store),
  `workspaces/<workspaceID>/mirror.store`, `workspaces/<workspaceID>/history/`
  (Favorites and Recents), `workspaces/<workspaceID>/drafts/` (staged work-order
  drafts, kept across relaunches), `attachments/`,
  `staging/{attachments,csv,restore}/`, `audit/` and `exports/audit/`
  (published audit exports, never overwritten). On iOS these directories use
  the `completeUntilFirstUserAuthentication` protection class.

What it does not do:

- No sharing, invitations or second user; share acceptance fails with a typed
  error. No staged-transfer garbage collection, and corrective resolutions are
  unavailable.
- No backup or sync between devices. Deleting the app deletes the workspace;
  a damaged `identity.json` stops startup instead of being replaced.
- It is not the stage-2 iCloud deployment. A CloudKit workspace still needs an
  organization configuration provider, as described below.

## Required organization input

The complete source contract is
`NettworkApp/Composition/Runtime/ProductionRuntimeAssemblyInput.swift`. It
groups the required inputs as follows:

| Group | Required responsibilities |
| --- | --- |
| Workspace storage | SwiftData `ModelContainer`; distinct attachment, attachment-staging, CSV-staging, archive-restore, audit, and history directories (the history directory holds the per-account, per-workspace Favorites and Recents JSON files: object IDs only, at most 50 recents and 500 favorites; a damaged file starts empty and is moved aside to `*.corrupt` on the next write); staging lifetime/protection; staged work-order draft store |
| Cloud workspace | Account/workspace identity; `CKContainer`; optional subscription; record/staged-asset bounds; approved staged-transfer cleanup policy; workspace context/share/bootstrap services; actor and installation identity; remote record validator |
| Telemetry | Non-empty subsystem; retention policy; privacy-safe external signal provider and metrics store |
| Operation governance | Bounded-operation policies and budgets; measurement sink; work-order and attachment policies; corrective-resolution provider; audit destination; archive verifier; floor-plan work metadata |
| Feature context | Initial floor/anchor context; template and operations policy; live authorization providers; transfer sources/destinations; workspace share callbacks |
| Platform capability override | Optional complete replacement for system QR capture and PDF label generation/export/printing adapters |

Assembly validation
(`NettworkApp/Composition/Runtime/ProductionRuntimeAssemblyValidation.swift`)
rejects invalid core identity, bounds, quotas, and operation policy values.
Storage URLs must be file URLs and the organization-provided directories must
be distinct. These checks validate shape and safety invariants;
they do not prove that remote service configuration, permissions, or filesystem
protection are operational.

When the platform override is `nil`, the app supplies scene-owned system
capabilities. iOS uses the camera scanner and presents label export/printing
from a weak controller anchor owned by that SwiftUI scene. macOS keeps the
manual scan path and uses native label export/printing. Supplying an override
replaces this four-adapter set; it does not relax authorization, namespace, or
opaque-label validation. Providers must pass either `nil` or a complete
`PlatformCapabilities` value deliberately.

## Data and authorization responsibilities

- Supply an account-scoped CloudKit workspace and services that can activate,
  verify membership, share/accept workspaces, and bootstrap required state.
- Provide a SwiftData container for the current schema and private directories
  with organization-approved backup, retention, and file-protection behavior.
- Derive actor, role, installation, and operation authorization from trusted
  organization state. Values submitted by Presentation are assertions to match,
  not sources of authority.
- Define work-order, attachment, staging, quota, cancellation-release, telemetry,
  and performance policies with positive, bounded values.
- Provide explicit destinations and current authorization for CSV, archive, and
  audit export; provide bounded, security-scoped sources for import/restore.
- Decide whether staged-transfer garbage collection is approved. A `nil` policy
  deliberately means it is not approved.

CloudKit role policy is enforced by the official client. It cannot defend
against a participant who has independent write access and bypasses the client.
CloudKit sharing and security configuration must therefore enforce the
organization's actual trust model.

## Production readiness checks

Before treating a build as deployable, verify outside this repository:

1. Registered bundle IDs, team, certificates, profiles, sandbox, CloudKit, and
   push entitlements for both intended targets.
2. A real CloudKit container, deployed schema, account/share model,
   subscriptions, permissions, quotas, and environment selection.
3. Provider construction and validation with production policy, storage,
   authorization, telemetry, and any intentional platform-capability override.
4. Fresh-account startup, membership verification, account switching, session
   invalidation, foreground sync, conflict/quarantine recovery, and offline
   behavior.
5. Conditional mutation and indeterminate-write receipt recovery under real
   CloudKit failure modes.
6. Work-order reservation acknowledgement, completion, cancellation release,
   audit export, and administrator authorization.
7. CSV/archive limits, empty-workspace activation, malicious input handling,
   attachment sanitization, and security-scoped source lifetimes.
8. Camera scanning, file import/export, PDF rendering/printing, deep links, and
   file protection on supported physical devices.
9. Privacy review for logs, metrics, retention, backups, and exported artifacts.

CI checks source and builds the Swift package, the macOS app, and the
iOS Simulator app without signing. It does not perform the deployment checks
above. Verify signing, live CloudKit behavior, and device integrations in your
organization's environment.
