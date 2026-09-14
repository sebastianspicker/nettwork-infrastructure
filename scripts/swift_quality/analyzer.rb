# frozen_string_literal: true

require_relative "constants"
require_relative "source_inventory"
require_relative "lexer"
require_relative "callable_extractor"
require_relative "measurements"
require_relative "clone_detector"

module SwiftQuality
  class Analyzer
    attr_reader :root, :diagnostics

    def initialize(root)
      @root = File.expand_path(root)
      @diagnostics = []
      @inventory = SourceInventory.new(@root)
      @callable_number = 0
      @bodies = []
    end

    def run
      files = @inventory.files
      targets = @inventory.targets_for(files)
      files.each { |path| inspect_file(path, targets.fetch(path)) }
      @inventory.non_swift_files.each { |path| inspect_non_swift_file(path) }
      add_clone_diagnostics
      @diagnostics.sort_by { |item| [item[:path], item[:line], item[:category], item[:message]] }
    end

    private

    def inspect_file(path, targets)
      relative = @inventory.relative_path(path)
      source = File.binread(path)
      add_file_length(relative, source)
      sanitized, clone_text = Lexer.lex(source)
      callables = extract_callables(relative, targets, sanitized, clone_text)
      callables.each { |body| inspect_callable(body, nested_in(body, callables)) }
    end

    def inspect_non_swift_file(path)
      relative = @inventory.relative_path(path)
      source = File.binread(path)
      limit = @inventory.non_swift_limit(path)
      return unless source.lines.count > limit

      add(relative, 1, "file-length", "#{File.extname(path).delete_prefix('.')} source file has #{source.lines.count} physical lines (max #{limit})")
    end

    def add_file_length(relative, source)
      limit = @inventory.test_file?(relative) ? MAX_TEST_FILE_LINES : MAX_PRODUCTION_FILE_LINES
      return unless source.lines.count > limit

      kind = @inventory.test_file?(relative) ? "test" : "production"
      add(relative, 1, "file-length", "#{kind} Swift file has #{source.lines.count} physical lines (max #{limit})")
    end

    def extract_callables(relative, targets, sanitized, clone_text)
      extractor = CallableExtractor.new(relative, targets, sanitized, clone_text,
                                        @inventory.test_file?(relative), @callable_number)
      callables = extractor.callables
      @callable_number = extractor.next_id
      callables
    end

    def inspect_callable(body, nested)
      add_callable_length(body)
      add_complexity(body, nested)
      @bodies << body
    end

    def nested_in(body, callables)
      callables.select do |candidate|
        candidate.id != body.id && candidate.open_offset > body.open_offset && candidate.close_offset < body.close_offset
      end
    end

    def add_callable_length(body)
      lines = Measurements.callable_lines(body)
      return unless lines > MAX_CALLABLE_LINES

      add(body.path, body.open_line, "callable-length", "#{body.symbol} has #{lines} physical lines (max #{MAX_CALLABLE_LINES})")
    end

    def add_complexity(body, nested)
      complexity = Measurements.complexity(body, excluding: nested)
      return unless complexity > MAX_COMPLEXITY

      add(body.path, body.open_line, "complexity", "#{body.symbol} has lexical cyclomatic complexity #{complexity} (max #{MAX_COMPLEXITY})")
    end

    def add_clone_diagnostics
      CloneDetector.new(@bodies).diagnostics.each do |report|
        add(report[:path], report[:line], "clone", report[:message])
      end
    end

    def add(path, line, category, message)
      @diagnostics << { path: path, line: line, category: category, message: message }
    end
  end
end
