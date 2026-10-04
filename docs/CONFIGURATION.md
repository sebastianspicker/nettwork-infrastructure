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
the App Sandbox and outgoing network-client entitlement. The iOS Info.plist
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

## Required organization input

The complete source contract is
`NettworkApp/Composition/Runtime/ProductionRuntimeAssemblyInput.swift`. It
groups the required inputs as follows:

| Group | Required responsibilities |
| --- | --- |
| Workspace storage | SwiftData `ModelContainer`; distinct attachment, attachment-staging, CSV-staging, archive-restore, and audit directories; staging lifetime/protection; staged work-order draft store |
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
