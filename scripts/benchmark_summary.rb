#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

# Keep every raw sample in the sibling files. This report is descriptive only;
# machine speed and filesystem caching are never a CI acceptance threshold.
def distribution(values)
  sorted = values.sort
  middle = sorted.length / 2
  median = sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
  { samples: sorted.length, minimum: sorted.first, median: median, maximum: sorted.last }
end

def summarize(paths)
  reports = paths.map { |path| JSON.parse(File.read(path)) }
  sizes = reports.map { |report| report.fetch("size") }.uniq
  abort "incomparable benchmark input sizes" unless sizes.length == 1

  timing = reports.flat_map { |report| report.fetch("milliseconds") }
  checksums = reports.map { |report| report.fetch("checksum").to_f / report.fetch("milliseconds").length }.uniq
  abort "benchmark checksums differ" unless checksums.length == 1

  memory = paths.map do |path|
    sidecar = path.sub(/\.json\z/, ".memory.txt")
    next unless File.file?(sidecar)

    match = File.read(sidecar).match(/(\d+)\s+maximum resident set size/)
    abort "missing process memory measurement: #{sidecar}" unless match

    Integer(match[1])
  end.compact
  result = { size: sizes.first, checksum_per_sample: checksums.first, milliseconds: distribution(timing) }
  result[:maximum_resident_bytes] = distribution(memory) unless memory.empty?
  result
end

root = ARGV.fetch(0) { abort "usage: #{$PROGRAM_NAME} BENCHMARK_OUTPUT_DIRECTORY" }
paths = Dir.glob(File.join(root, "*.json")).reject { |path| File.basename(path) == "summary.json" }
groups = paths.group_by { |path| JSON.parse(File.read(path)).fetch("workload") }
abort "no benchmark measurements" if groups.empty?

report = groups.sort.to_h.transform_values { |group| summarize(group) }
File.write(File.join(root, "summary.json"), JSON.pretty_generate(report) + "\n")
puts JSON.pretty_generate(report)
