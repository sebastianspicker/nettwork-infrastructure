#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="${NETTWORK_BENCHMARK_ROOT:-$repository_root}/Packages/NettworkCore"
output_directory="${NETTWORK_BENCHMARK_OUTPUT:-$repository_root/artifacts/benchmarks/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
repetitions="${NETTWORK_BENCHMARK_REPETITIONS:-5}"
if [[ ! "$repetitions" =~ ^[1-9][0-9]*$ ]]; then
    echo "NETTWORK_BENCHMARK_REPETITIONS must be a positive integer" >&2
    exit 1
fi
mkdir -p "$output_directory"
shopt -s nullglob
existing_measurements=("$output_directory"/*.json)
if ((${#existing_measurements[@]})); then
    echo "Choose an output directory without prior measurements" >&2
    exit 1
fi
build_arguments=(--package-path "$package_root" -c release --product NettworkBenchmarks -Xswiftc -warnings-as-errors)
if [[ "${NETTWORK_BENCHMARK_BASELINE:-0}" == 1 ]]; then
    build_arguments+=(-Xswiftc -DNETTWORK_BASELINE)
fi
swift build "${build_arguments[@]}"
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
binary="$binary_directory/NettworkBenchmarks"
{
    swift --version 2>&1
    xcodebuild -version
    sw_vers
    sysctl -n machdep.cpu.brand_string
    sysctl hw.memsize
    printf 'repetitions=%s\n' "$repetitions"
} >"$output_directory/environment.txt"
"$binary" ipam 2048 "$repetitions" | tee "$output_directory/ipam.json"
"$binary" trace 512 "$repetitions" | tee "$output_directory/trace.json"
"$binary" prepare-csv 30000 1 "$output_directory/csv"
"$binary" prepare-archive 16 1 "$output_directory/archive"
for ((repetition = 1; repetition <= repetitions; repetition++)); do
    /usr/bin/time -l "$binary" csv-memory 30000 1 "$output_directory/csv" \
        >"$output_directory/csv-memory-$repetition.json" 2>"$output_directory/csv-memory-$repetition.memory.txt"
    /usr/bin/time -l "$binary" archive-memory 16 1 "$output_directory/archive" \
        >"$output_directory/archive-memory-$repetition.json" 2>"$output_directory/archive-memory-$repetition.memory.txt"
    if [[ "${NETTWORK_BENCHMARK_BASELINE:-0}" != 1 ]]; then
        /usr/bin/time -l "$binary" csv-file 30000 1 "$output_directory/csv" \
            >"$output_directory/csv-file-$repetition.json" 2>"$output_directory/csv-file-$repetition.memory.txt"
        /usr/bin/time -l "$binary" archive-file 16 1 "$output_directory/archive" \
            >"$output_directory/archive-file-$repetition.json" 2>"$output_directory/archive-file-$repetition.memory.txt"
    fi
done
ruby "$repository_root/scripts/benchmark_summary.rb" "$output_directory"
printf 'Benchmark evidence: %s\n' "$output_directory"
