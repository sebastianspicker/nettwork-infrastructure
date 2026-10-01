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

# Matches attributed imports (`@preconcurrency`, `@_exported`, `@testable`) and
# declaration imports (`import class SwiftData.ModelContext`).
import_pattern() {
    printf '%s' '^\s*(@[A-Za-z_]+(\([^)]*\))?\s+)*import\s+((typealias|struct|class|enum|protocol|let|var|func|actor)\s+)?('"$1"')(\.|\s|$)'
}

forbid_imports() {
    local description="$1"
    local pattern
    pattern="$(import_pattern "$2")"
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

# Presentation, Platform, and Composition compile into one app module, so
# imports cannot keep the layers apart; their type names can.
forbid_type_names() {
    local source_layer="$1" target_layer="$2" description="$3"
    local names matches status=0
    names="$(rg -oN --no-filename --glob '*.swift' -r '$1' \
        '^\s*(?:(?:@\w+(?:\([^)]*\))?|public|private|fileprivate|internal|final|nonisolated|open|package|indirect)\s+)*(?:class|struct|enum|actor|protocol|typealias)\s+(\w+)' \
        "NettworkApp/$source_layer")" || status=$?
    if ((status > 1)); then
        echo "architecture: rg failed with exit $status while collecting $source_layer type names" >&2
        exit 1
    fi
    [[ -n "$names" ]] || return 0
    status=0
    matches="$(printf '%s\n' "$names" | sort -u | rg -n -w -F --glob '*.swift' -f - "NettworkApp/$target_layer")" || status=$?
    if ((status > 1)); then
        echo "architecture: rg failed with exit $status while checking $source_layer types in $target_layer" >&2
        exit 1
    fi
    if [[ -n "$matches" ]]; then
        fail "$description"
        printf '%s\n' "$matches" >&2
    fi
}

if ! check_package_dependencies; then
    failures=1
fi

sources=Packages/NettworkCore/Sources

forbid_imports \
    "NettworkCore package targets must not import SwiftUI, UIKit, or AppKit" \
    'SwiftUI|SwiftUICore|UIKit|AppKit' \
    "$sources"

# CloudSync is the CloudKit adapter; no other package target may touch CloudKit.
forbid_imports \
    "Only CloudSync may import CloudKit in NettworkCore" \
    'CloudKit' \
    "$sources"/{NetworkModel,WorkspaceChangeControl,Persistence,ContentSafety,ImportExport,FeatureContracts,WorkspaceServices}

forbid_imports \
    "Only Persistence and WorkspaceServices may import SwiftData in NettworkCore" \
    'SwiftData' \
    "$sources"/{NetworkModel,WorkspaceChangeControl,CloudSync,ContentSafety,ImportExport,FeatureContracts}

forbid_imports \
    "NetworkModel must remain independent of change control and infrastructure" \
    'WorkspaceChangeControl|CloudKit|SwiftData|Persistence|CloudSync|ContentSafety|ImportExport' \
    "$sources/NetworkModel"

forbid_imports \
    "FeatureContracts must not import UI frameworks, SwiftData, CloudKit, Persistence, or CloudSync" \
    'SwiftUI|SwiftUICore|SwiftData|CloudKit|UIKit|AppKit|Persistence|CloudSync' \
    "$sources/FeatureContracts"

forbid_imports \
    "WorkspaceServices must not import SwiftUI, UIKit, AppKit, or CloudKit" \
    'SwiftUI|SwiftUICore|UIKit|AppKit|CloudKit' \
    "$sources/WorkspaceServices"

forbid_imports \
    "Presentation must not import CloudKit, SwiftData, Persistence, CloudSync, or WorkspaceServices" \
    'CloudKit|SwiftData|Persistence|CloudSync|WorkspaceServices' \
    NettworkApp/Presentation

forbid_imports \
    "Platform adapters must not import SwiftData, CloudKit, Persistence, CloudSync, or WorkspaceServices" \
    'SwiftData|CloudKit|Persistence|CloudSync|WorkspaceServices' \
    NettworkApp/Platform

forbid_type_names Platform Presentation \
    "Presentation must not reference Platform adapter types; inject them through Composition"
forbid_type_names Composition Presentation \
    "Presentation must not reference Composition types; Composition injects Presentation-owned state"
forbid_type_names Presentation Platform \
    "Platform adapters must not reference Presentation types"
forbid_type_names Composition Platform \
    "Platform adapters must not reference Composition types; Composition constructs the adapters"

if ((failures)); then
    exit 1
fi

echo "architecture: package direction, import boundaries, and app layer type names passed"
