# Development

<!-- markdownlint-disable MD013 -->

## Supported toolchain

Development and CI run on macOS. The project declares Swift 6, iOS 18, macOS
15, Xcode 16 project format, and XcodeGen 2.46 as minimums.

| Tool | Used by |
| --- | --- |
| Full Xcode, `swift`, and `swiftc` | App generation/builds, package builds/tests, syntax parsing, `plutil`, and `sips` |
| XcodeGen 2.46+ | Generation of `Nettwork.xcodeproj` from `project.yml` |
| Ruby with YAML and JSON | Project, architecture, and source-quality checks |
| Git, Bash, `rg`, and `jq` | Repository, script, architecture, and asset checks |
| Node.js 22.13+ and npm | Locked ESLint, Prettier, jscpd, and Markdown tooling |
| ShellCheck and shfmt | Shell correctness and four-space formatting |
| Xcode-provided `swift format` | Deterministic four-space Swift formatting, import ordering, and production force-operation safety linting |

One Homebrew/npm setup that provides the non-Xcode tools is:

```sh
brew install xcodegen jq ripgrep shellcheck shfmt
npm ci --ignore-scripts --no-audit --no-fund
```

Verify that the active developer directory points to full Xcode, not only the
Command Line Tools:

```sh
xcode-select --print-path
xcodebuild -version
xcodegen --version
swift --version
```

Use a command-local `DEVELOPER_DIR` to select an installed full Xcode without
changing the machine-wide developer directory. The repository does not pin a particular
Xcode application bundle beyond the declared minimum project format and SDKs.

## Generate the Xcode project

`project.yml` is authoritative. From the repository root, run:

```sh
make generate
```

This creates the ignored `Nettwork.xcodeproj`. Regenerate after changing
targets, schemes, settings, package products, source roots, resources, or test
bundles. Do not manually maintain the generated project.

The generated schemes are:

- `Nettwork`: iOS application and `NettworkTests`
- `Nettwork macOS`: macOS application and `NettworkMacTests`

## Validation commands

Run commands from the repository root unless stated otherwise.

| Command | Scope |
| --- | --- |
| `make check` | Everything CI runs: `verify-source`, `verify-package`, and `verify-native` |
| `make format` | Formats maintained Swift, shell, and demo sources |
| `make check-format` | Checks Swift formatting (general and production configurations) without modifying files; shell and web formatting are checked by `check-scripts` and `check-web` |
| `make check-scripts` | Runs Ruby syntax, ShellCheck, shfmt, Bash parsing, and script clone detection |
| `make check-web` | Checks `site/` with ESLint, Prettier, clone detection, and semantic demo validation |
| `make verify-source` | CI source gate; does not build app targets or run package/app tests |
| `make verify-package` | Complete `NettworkCore` Swift package tests with compiler warnings treated as errors |
| `make verify-native` | Generates the Xcode project, tests the macOS app bundle, and builds the iOS Simulator app without signing |
| `make benchmark` | Release measurements with fixed fixtures; no wall-clock pass/fail thresholds |
| `make check-architecture` | Exact package dependencies, forbidden imports per layer, and no Platform type names in Presentation; requires `rg`, `swift`, and `ruby` |
| `make check-quality` | Authored-source physical limits plus Swift callable length, complexity, and exact-clone checks |
| `make check-assets` | Asset JSON, references, dimensions, opacity, required colors, and target settings |
| `make lint-docs` | Locked Markdown linting for root and package documentation |

For a documentation-only change, run:

```sh
make lint-docs
make check-whitespace
git diff --check
```

For package-only work, either run the root target or work inside the package:

```sh
make verify-package
cd Packages/NettworkCore
swift test -Xswiftc -warnings-as-errors
```

The authored-source checks limit production Swift files to 380 physical lines,
Swift test files and HTML/CSS files to 500, JavaScript to 400, Ruby and MJS to
300, and shell files to 200. Production Swift additionally rejects force
unwraps, force tries, implicitly unwrapped optionals, and assignment
expressions.

## Native app builds and tests

Run the complete native gate with `make verify-native`. It generates the
project and puts macOS and iOS build products in separate ignored DerivedData
directories. Override `NATIVE_DERIVED_DATA` to isolate concurrent runs.
Individual `xcodebuild` commands also require project generation.

To use a particular installed Xcode without changing the global developer
directory, set `DEVELOPER_DIR` in your shell. Adjust this path to your installed Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
make generate
```

The macOS scheme has a stable destination:

```sh
xcodebuild -project Nettwork.xcodeproj -scheme 'Nettwork macOS' -destination 'platform=macOS' build
xcodebuild -project Nettwork.xcodeproj -scheme 'Nettwork macOS' -destination 'platform=macOS' test
```

An iOS simulator build does not require a named device:

```sh
xcodebuild -project Nettwork.xcodeproj -scheme Nettwork -destination 'generic/platform=iOS Simulator' build
```

Tests require a concrete installed simulator. List valid destinations, then use
one of the reported destination specifiers:

```sh
xcodebuild -project Nettwork.xcodeproj -scheme Nettwork -showdestinations
xcodebuild -project Nettwork.xcodeproj -scheme Nettwork -destination 'platform=iOS Simulator,name=<installed iPad>,OS=<installed OS>' test
xcodebuild -project Nettwork.xcodeproj -scheme Nettwork -destination 'platform=iOS Simulator,name=<installed iPhone>,OS=<installed OS>' test
```

Application build/test success does not establish production signing,
CloudKit schema/account behavior, camera capture, document workflows, PDF
printing, or other device integration. Those require the organization setup
described in [CONFIGURATION.md](CONFIGURATION.md) and proportional device
testing.

## Reproducible performance measurements

`make benchmark`
builds `NettworkBenchmarks` in Release mode and writes JSON timing samples,
process peak-memory reports, a descriptive `summary.json`, and toolchain details
in a fresh run directory under ignored `artifacts/benchmarks/`. It uses fixed identifiers and these default fixtures:

- 2,048 IPv4 /24 prefixes and 2,048 contained addresses in one VRF.
- One 512-segment physical chain, summarized once per sample.
- Four CSV tables with 30,000 rows each and a 512-character name payload.
- Four 16 MiB archive assets with empty record and audit entries.

Domain workloads have one warmup and five timed repetitions. File workloads
run in five fresh processes after a separate fixture-generation process;
`/usr/bin/time -l` records maximum resident set size in bytes on macOS.
`NETTWORK_BENCHMARK_REPETITIONS` and `NETTWORK_BENCHMARK_OUTPUT` override the
sample count and output directory. Compare medians and the full range on the
same machine with other build work stopped. Filesystem cache state is not
reset, so these are warm-cache local measurements.

For a preserved baseline checkout, copy only the benchmark source directory
and its additive executable manifest entry into that checkout, then set
`NETTWORK_BENCHMARK_ROOT` to its root and `NETTWORK_BENCHMARK_BASELINE=1`.
This compilation flag selects the original physical trace and in-memory file
APIs. Keep input sizes and repetitions identical. The collecting compatibility
APIs remain measurable separately from file-backed paths.

The import benchmark ends at bounded record decoding or archive verification;
it does not measure CloudKit uploads, full domain planning, or activation.
CSV domain-record arrays remain allocated by design. Archive restore may still
materialize one entry up to 64 MiB. Deterministic tests enforce output and
operation-count contracts; wall-clock measurements are not CI thresholds.

See [PERFORMANCE.md](PERFORMANCE.md) for measured baseline comparisons,
variability, memory limits, and the corresponding local verification results.

## Static demo

The demo is maintained directly in `site/`; it is not generated from SwiftUI.
The public demo is at <https://sebastianspicker.github.io/nettwork/>.
Validate and preview it locally with:

```sh
make check-web
python3 -m http.server 4173 --bind 127.0.0.1 --directory site
```

The Pages artifact keeps its own files under `site/`. Its validator rejects
missing required files, common secret material, credential/configuration file
types, root-absolute assets, and runtime dependencies on screenshots.

README screenshots live in `docs/screenshots/`, outside the Pages artifact.
Capture them from the local demo using only its bundled sample data. Keep the
README captions explicit about which application is pictured; the browser demo
is not a native app capture.

## Editing boundaries

- Add reusable model and service behavior to the narrowest `NettworkCore`
  product. Preserve the dependency graph in [ARCHITECTURE.md](ARCHITECTURE.md).
- Put a protocol or value type that Presentation consumes and a service
  implements in `FeatureContracts`; keep view models, views, and view state in
  `NettworkApp/Presentation`.
- Put production service behavior (authorization derivation, SwiftData reads,
  work-order mutation, transfer, evidence binding) in `WorkspaceServices` and
  cover it with `swift test` in `WorkspaceServicesTests`.
- Put adapters that need UIKit, AppKit, VisionKit, printing, the pasteboard, or
  user-selected files in `NettworkApp/Platform`, behind a `FeatureContracts`
  port.
- Put production assembly, organization input, and CloudKit wiring in
  `NettworkApp/Composition/Runtime`; it is the only place that sees every layer.
- Update `project.yml`, not the generated Xcode project, for target changes.
- Replace `Design/Brand/NettworkIconMaster.png` only through the process in the
  [brand guide](../Design/Brand/README.md), then regenerate and validate icons.
- Treat `.build/`, `.swiftpm/`, `Nettwork.xcodeproj`, DerivedData, build output,
  test results, coverage, `.serena/`, and `.repowise/` as generated or local
  state rather than maintained source.

## CI coverage

The macOS CI workflow selects a full installed Xcode, installs the locked Node
toolchain with Node 22, installs ShellCheck, shfmt, and XcodeGen, then runs
`make verify-source`, `make verify-package`, and `make verify-native`. Native
coverage includes the macOS application test bundle and an iOS Simulator
application build. Signing, live CloudKit, and device-only integrations remain
separate verification requirements.

The separate Pages workflow installs the same locked Node toolchain on Ubuntu,
runs `make check-web` and uploads `site/`. Repository
Pages enablement, the deployed URL, and production availability are external
state and are not verified by these workflows.
