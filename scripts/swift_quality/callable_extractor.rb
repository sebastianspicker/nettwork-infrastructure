# frozen_string_literal: true

module SwiftQuality
  Callable = Struct.new(:id, :path, :targets, :symbol, :open_offset, :close_offset,
                        :open_line, :close_line, :sanitized, :clone_text, :test_file,
                        keyword_init: true)

  class CallableExtractor
    def initialize(path, targets, sanitized, clone_text, test_file, start_id)
      @path = path
      @targets = targets.sort
      @sanitized = sanitized
      @clone_text = clone_text
      @test_file = test_file
      @next_id = start_id
    end

    attr_reader :next_id

    def callables
      brace_pairs.each_with_object([]) do |(opening, closing), callables|
        symbol = callable_symbol(opening, closing)
        callables << build_callable(opening, closing, symbol) if symbol
      end
    end

    private

    def brace_pairs
      stack = []
      @sanitized.each_char.with_index.each_with_object([]) do |(character, index), pairs|
        stack << index if character == "{"
        pairs << [stack.pop, index] if character == "}" && !stack.empty?
      end
    end

    def callable_symbol(opening, closing)
      prefix = @sanitized[[opening - 2_000, 0].max...opening]
      suffix = prefix.split(/[{};]/).last.to_s
      function = suffix.match(/\bfunc\s+([A-Za-z_]\w*)[^{}]*\z/m)
      return "func #{function[1]}" if function
      return "init" if suffix.match?(/\binit(?:\?|!)?\s*(?:<[^{}]*>)?\s*\([^{}]*\)[^{}]*\z/m)
      return "deinit" if suffix.match?(/\bdeinit\s*\z/m)
      return "subscript" if suffix.match?(/\bsubscript\s*\([^{}]*\)[^{}]*\z/m)
      return "SwiftUI body" if suffix.match?(/\bvar\s+body\s*:[^{}=]*\z/m)
      return "closure" if closure_body?(suffix, @sanitized[(opening + 1)...closing])
    end

    def closure_body?(prefix, content)
      excluded = /\b(?:if|guard|while|for|switch|catch|do|else|class|struct|enum|protocol|extension|actor|func|init|deinit|subscript)\b[^{}]*\z/m
      return false if prefix.match?(excluded)
      return true if prefix.match?(/=\s*\z/m)
      return true if prefix.match?(/(?::|,|\(|\[)\s*\z/m) && content.match?(/\bin\b/m)

      prefix.match?(/\b[A-Za-z_]\w*(?:\s*\([^{}]*\))?\s*\z/m)
    end

    def build_callable(opening, closing, symbol)
      @next_id += 1
      Callable.new(
        id: @next_id, path: @path, targets: @targets, symbol: symbol,
        open_offset: opening, close_offset: closing,
        open_line: line_for(opening), close_line: line_for(closing),
        sanitized: @sanitized, clone_text: @clone_text, test_file: @test_file
      )
    end

    def line_for(offset)
      @sanitized[0...offset].count("\n") + 1
    end
  end
end
