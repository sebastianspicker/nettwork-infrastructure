# Contributing to Nettwork

<!-- markdownlint-disable MD013 -->

Start with the [README](README.md) to try the demo or build the app. The
[development guide](docs/DEVELOPMENT.md) covers the toolchain and validation
commands; the [architecture guide](docs/ARCHITECTURE.md) explains where code
belongs.

## Report a problem

Include what you expected, what happened, and the smallest steps that reproduce
it. Say whether the problem affects the native app or the browser demo. For
native issues, include the OS and Xcode versions and whether the workspace was
configured. Use sample data in screenshots and logs.

For sensitive reports, follow [Security](SECURITY.md). Do not post credentials,
private network maps, account identifiers, or customer records in public issues.

## Prepare a change

Keep each pull request focused on one problem. Describe the user-visible result
and include the checks you ran, along with any checks you could not run.

- Change targets and settings in `project.yml`, then run `make generate`.
- Keep reusable behavior in the appropriate `NettworkCore` library.
- Keep organization identifiers, policies, and secrets out of shared defaults.
- Use bundled sample data for demo changes and README screenshots.
- Update the relevant guide when behavior or setup changes.

## Check your work

Install the tooling described in [Development](docs/DEVELOPMENT.md) first.

| Change | Checks |
| --- | --- |
| Documentation | `make lint-docs`, `make check-whitespace`, and check links and images |
| Browser demo | `make check-web` and test the changed flow at desktop and mobile sizes |
| Swift source or build configuration | `make verify-source`, `make verify-package`, and `make verify-native` |

Add or update tests when behavior changes. Do not commit generated projects,
build output, local configuration, or benchmark artifacts. Native checks use
unsigned builds; live CloudKit and physical-device behavior need separate
verification in a configured environment.
