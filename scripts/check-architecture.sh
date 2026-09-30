#!/usr/bin/env bash

set -euo pipefail

repository_root="${NETTWORK_ARCHITECTURE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repository_root"

failures=0

for tool in rg swift ruby; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "architecture: required tool '$tool' is not installed or not on PATH" >&2
        exit 1
    }
done

fail() {
    echo "architecture: $*" >&2
    failures=1
}

forbid_imports() {
    local description="$1"
    local pattern="$2"
    shift 2
    local matches status=0
    matches="$(rg -n --glob '*.swift' "$pattern" "$@")" || status=$?
    if ((status > 1)); then
        echo "architecture: rg failed with exit $status while checking: $description" >&2
        exit 1
    fi
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
        "ImportExport" => ["NetworkModel", "WorkspaceChangeControl", "ContentSafety"],
        "FeatureContracts" => ["NetworkModel", "WorkspaceChangeControl", "ContentSafety", "ImportExport"]
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
    "FeatureContracts must not import UI frameworks, SwiftData, CloudKit, Persistence, or CloudSync" \
    '^\s*import\s+(SwiftUI|SwiftData|CloudKit|UIKit|AppKit|Persistence|CloudSync)\b' \
    Packages/NettworkCore/Sources/FeatureContracts

forbid_imports \
    "Presentation must not import CloudKit, SwiftData, Persistence, or CloudSync" \
    '^\s*import\s+(CloudKit|SwiftData|Persistence|CloudSync)\b' \
    NettworkApp/Presentation

if ((failures)); then
    exit 1
fi

echo "architecture: package direction and import boundaries passed"
