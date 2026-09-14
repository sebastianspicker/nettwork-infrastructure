# Security

## Reporting a sensitive issue

Do not include credentials, private network details, customer data, or an
exploit against a live workspace in a public issue or pull request.

If this repository offers GitHub's private vulnerability reporting, use
**Security → Report a vulnerability**. Otherwise, ask a maintainer for a private
reporting channel without posting the sensitive details. No response-time or
supported-release policy has been established for this source repository.

A useful report identifies the affected code or revision, the required access,
reproduction steps using sample data, and the expected impact.

## Configuration and data

The default build uses example identifiers and has no organization provider.
Real deployments must supply their own CloudKit configuration, signing,
authorization, storage, and retention policies. See
[Production configuration](docs/CONFIGURATION.md).

Keep credentials, provisioning profiles, private keys, workspace exports, and
organization-specific configuration outside Git. Ignore rules help prevent
accidental additions, but do not remove files already tracked or erase history.
If a credential has been published, revoke or rotate it at its issuer before
addressing repository cleanup.

The browser demo contains sample data and has no backend. Its status indicators
and event history do not report live network activity.

## Trust boundaries

CloudKit access controls must enforce the deployment's trust model. Client-side
role checks do not protect against a participant who can write directly to the
CloudKit workspace. Archive checksums detect changes to content; they do not
authenticate its author. The [architecture guide](docs/ARCHITECTURE.md) describes
these boundaries and the handling of sessions, attachments, and transfers.
