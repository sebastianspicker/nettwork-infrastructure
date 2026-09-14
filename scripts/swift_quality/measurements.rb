# frozen_string_literal: true

require_relative "constants"

module SwiftQuality
  class Measurements
    def self.callable_lines(body)
      body.close_line - body.open_line + 1
    end

    def self.complexity(body, excluding: [])
      fragment = body.sanitized[body.open_offset..body.close_offset].dup
      excluding.each do |nested|
        start = nested.open_offset - body.open_offset
        finish = nested.close_offset - body.open_offset
        fragment[start..finish] = fragment[start..finish].tr("^\n", " ")
      end
      new(fragment).complexity
    end

    def initialize(fragment)
      @fragment = fragment
    end

    def complexity
      1 + decision_words + boolean_operators + ternary_count + switch_case_count
    end

    private

    def decision_words
      @fragment.scan(/\b(?:if|guard|while|for|repeat|catch)\b/).length
    end

    def boolean_operators
      @fragment.scan(/&&|\|\|/).length
    end

    def ternary_count
      @fragment.scan(/\?(?=[^\n;{}]*:)/).length
    end

    def switch_case_count
      switch_ranges.sum { |range| @fragment[range].scan(/^\s*case\b/).length }
    end

    def switch_ranges
      stack = []
      ranges = []
      @fragment.each_char.with_index do |character, index|
        stack << switch_opening?(index) if character == "{"
        next unless character == "}" && !stack.empty?

        opening = stack.pop
        ranges << (opening..index) if opening
      end
      ranges
    end

    def switch_opening?(index)
      before = @fragment[[index - 300, 0].max...index]
      before.match?(/\bswitch\b[^{}]*\z/m) ? index : false
    end
  end
end
