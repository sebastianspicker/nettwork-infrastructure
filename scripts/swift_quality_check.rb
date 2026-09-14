#!/usr/bin/env ruby
# frozen_string_literal: true

# A dependency-free lexical quality gate for Swift sources. It can run before
# Xcode is available and intentionally keeps its public CLI stable.

require_relative "swift_quality/analyzer"

module SwiftQuality
  def self.main(argv)
    root = argument_root(argv)
    diagnostics = Analyzer.new(root).run
    diagnostics.each { |item| puts format_diagnostic(item) }
    puts "swift-quality: #{diagnostics.length} violation#{diagnostics.length == 1 ? "" : "s"}"
    exit(diagnostics.empty? ? 0 : 1)
  end

  def self.argument_root(argv)
    root = Dir.pwd
    if argv.first == "--root"
      root = argv[1] || abort(usage)
      argv.shift(2)
    end
    abort(usage) unless argv.empty?

    root
  end

  def self.format_diagnostic(item)
    "#{item[:path]}:#{item[:line]}: [#{item[:category]}] #{item[:message]}"
  end

  def self.usage
    "usage: #{$PROGRAM_NAME} [--root PATH]"
  end
end

SwiftQuality.main(ARGV) if $PROGRAM_NAME == __FILE__
