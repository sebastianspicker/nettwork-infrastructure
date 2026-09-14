#!/usr/bin/env bash

set -euo pipefail

repository_root="${NETTWORK_ARCHITECTURE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repository_root"

failures=0

fail() {
    echo "architecture: $*" >&2
    failures=1
}

forbid_imports() {
    local description="$1"
    local pattern="$2"
    shift 2
    local matches
    matches="$(rg -n --glob '*.swift' "$pattern" "$@" || :)"
    if [[ -n "$matches" ]]; then
        fail "$description"
        printf '%s\n' "$matches" >&2
    fi
}

check_package_dependencies() {
    swift package --package-path Packages/NettworkCore dump-package | ruby -rjson -e '
      expected = {
        "NetworkModel" => [],
        "WorkspaceChangeControl" => ["NetworkModel"],
        "Persistence" => ["NetworkModel", "WorkspaceChangeControl"],
        "CloudSync" => ["NetworkModel", "WorkspaceChangeControl", "Persistence"],
        "ContentSafety" => ["NetworkModel", "WorkspaceChangeControl"],
        "ImportExport" => ["NetworkModel", "WorkspaceChangeControl", "ContentSafety"]
      }
      targets = JSON.parse(STDIN.read).fetch("targets").to_h { |target| [target.fetch("name"), target] }
      failures = []
      expected.each do |name, dependencies|
        target = targets[name]
        unless target
          failures << "missing target #{name}"
          next
        end
        unless target.fetch("type") == "regular"
          failures << "#{name} must be a regular target"
        end
        actual = target.fetch("dependencies", []).map do |dependency|
          dependency.fetch("byName", dependency.fetch("product", []))[0]
        end
        failures << "#{name} dependencies are #{actual.inspect}; expected #{dependencies.inspect}" unless actual == dependencies
      end
      abort("architecture: package dependency direction failed:\n#{failures.join("\n")}") unless failures.empty?
    '
}

if ! check_package_dependencies; then
    failures=1
fi

forbid_imports \
    "NetworkModel must remain independent of change control and infrastructure" \
    '^\s*import\s+(WorkspaceChangeControl|CloudKit|SwiftData|Persistence|CloudSync|ContentSafety|ImportExport)\b' \
    Packages/NettworkCore/Sources/NetworkModel

forbid_imports \
    "Presentation must not import CloudKit, SwiftData, Persistence, or CloudSync" \
    '^\s*import\s+(CloudKit|SwiftData|Persistence|CloudSync)\b' \
    NettworkApp/Presentation

forbid_imports \
    "production sources must import NetworkModel, not the retired NetworkDomain module" \
    '^\s*import\s+NetworkDomain\b' \
    NettworkApp Packages/NettworkCore/Sources

legacy_paths="$(rg -n \
    --glob '*.swift' --glob '*.sh' --glob Makefile --glob project.yml \
    'NettworkApp/(Features|Models|Services|Views)/|(^|/)Nettwork(UI)?Tests/' \
    NettworkApp Tests Packages scripts Makefile project.yml || :)"
if [[ -n "$legacy_paths" ]]; then
    fail "retired app or test source paths remain referenced"
    printf '%s\n' "$legacy_paths" >&2
fi

if ((failures)); then
    exit 1
fi

echo "architecture: package direction and import boundaries passed"
