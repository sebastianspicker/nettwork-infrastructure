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
        "FeatureContracts" => ["NetworkModel", "WorkspaceChangeControl", "ContentSafety", "ImportExport"],
        "WorkspaceServices" => [
          "NetworkModel", "WorkspaceChangeControl", "Persistence", "CloudSync", "ContentSafety", "ImportExport", "FeatureContracts"
        ]
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

# Presentation and Platform compile into one app module, so imports cannot
# keep screens away from Platform adapters; their type names can.
check_platform_types_stay_out_of_presentation() {
    local names matches status=0
    names="$(rg -oN --no-filename --glob '*.swift' -r '$1' \
        '^\s*(?:(?:public|private|fileprivate|internal|final|nonisolated|@MainActor|@unchecked)\s+)*(?:class|struct|enum|actor|protocol|typealias)\s+(\w+)' \
        NettworkApp/Platform)" || status=$?
    if ((status > 1)); then
        echo "architecture: rg failed with exit $status while collecting Platform type names" >&2
        exit 1
    fi
    [[ -n "$names" ]] || return 0
    status=0
    matches="$(printf '%s\n' "$names" | sort -u | rg -n -w -F --glob '*.swift' -f - NettworkApp/Presentation)" || status=$?
    if ((status > 1)); then
        echo "architecture: rg failed with exit $status while checking Platform types in Presentation" >&2
        exit 1
    fi
    if [[ -n "$matches" ]]; then
        fail "Presentation must not reference Platform adapter types; inject them through Composition"
        printf '%s\n' "$matches" >&2
    fi
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
    "WorkspaceServices must not import SwiftUI, UIKit, AppKit, or CloudKit" \
    '^\s*import\s+(SwiftUI|UIKit|AppKit|CloudKit)\b' \
    Packages/NettworkCore/Sources/WorkspaceServices

forbid_imports \
    "Presentation must not import CloudKit, SwiftData, Persistence, CloudSync, or WorkspaceServices" \
    '^\s*import\s+(CloudKit|SwiftData|Persistence|CloudSync|WorkspaceServices)\b' \
    NettworkApp/Presentation

forbid_imports \
    "Platform adapters must not import SwiftData, CloudKit, Persistence, CloudSync, or WorkspaceServices" \
    '^\s*import\s+(SwiftData|CloudKit|Persistence|CloudSync|WorkspaceServices)\b' \
    NettworkApp/Platform

check_platform_types_stay_out_of_presentation

if ((failures)); then
    exit 1
fi

echo "architecture: package direction and import boundaries passed"
