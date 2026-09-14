# frozen_string_literal: true

require_relative "constants"

module SwiftQuality
  class CloneDetector
    Candidate = Struct.new(:left, :right, :left_start, :left_finish, :right_start,
                           :right_finish, :count, :tokens, keyword_init: true)

    def initialize(bodies)
      @bodies = bodies
      @logical_line_cache = {}
    end

    def diagnostics
      reports = []
      grouped = {}
      @bodies.flat_map(&:targets).uniq.sort.each do |target|
        reports_for_target(target).each do |candidate|
          key = candidate_key(candidate)
          grouped[key] ||= { candidate: candidate, targets: [] }
          grouped[key][:targets] << target
        end
      end
      grouped.values.each { |report| reports << report_for(report[:candidate], report[:targets].sort) }
      reports.sort_by { |report| [report[:path], report[:line], report[:sort_key]] }
    end

    private

    def reports_for_target(target)
      candidates = candidates_for(target)
      suppress_overlapping(candidates)
    end

    def candidates_for(target)
      occurrences = Hash.new { |hash, key| hash[key] = [] }
      @bodies.select { |body| body.targets.include?(target) }.each do |body|
        logical_lines(body).each_cons(PRODUCTION_CLONE_LINES).with_index do |window, index|
          occurrences[signature(window)] << [body, index]
        end
      end
      occurrences.values.flat_map { |entries| candidates_from(non_overlapping_seeds(entries)) }
                 .uniq { |item| candidate_key(item) }
    end

    # Windows that overlap within one callable can only produce overlapping
    # source spans. Retaining one seed per seven-line segment preserves real
    # same-callable duplicates while bounding repeated-line input.
    def non_overlapping_seeds(entries)
      entries.group_by { |body, _position| body.id }.values.flat_map do |body_entries|
        keep_non_overlapping_seed_positions(body_entries.sort_by { |_body, position| position })
      end
    end

    def keep_non_overlapping_seed_positions(entries)
      entries.each_with_object([]) do |entry, kept|
        position = entry[1]
        kept << entry if kept.empty? || position >= kept.last[1] + PRODUCTION_CLONE_LINES
      end
    end

    def candidates_from(entries)
      entries.combination(2).each_with_object([]) do |(left, right), candidates|
        candidate = build_candidate(left, right)
        candidates << candidate if candidate
      end
    end

    def build_candidate(left, right)
      left_body, left_position = left
      right_body, right_position = right
      return if identical_start?(left_body, left_position, right_body, right_position)

      starts, finishes = maximal_span(left_body, left_position, right_body, right_position)
      candidate = candidate(left_body, right_body, starts, finishes)
      candidate if meets_policy?(candidate)
    end

    def identical_start?(left_body, left_position, right_body, right_position)
      left_body.id == right_body.id && left_position == right_position
    end

    def maximal_span(left_body, left_position, right_body, right_position)
      left_lines = logical_lines(left_body)
      right_lines = logical_lines(right_body)
      starts = [left_position, right_position]
      finishes = [left_position + PRODUCTION_CLONE_LINES - 1, right_position + PRODUCTION_CLONE_LINES - 1]
      extend_left(left_lines, right_lines, starts)
      extend_right(left_lines, right_lines, finishes)
      [starts, finishes]
    end

    def extend_left(left_lines, right_lines, starts)
      while starts.all?(&:positive?) && equal_lines?(left_lines, starts[0] - 1, right_lines, starts[1] - 1)
        starts[0] -= 1
        starts[1] -= 1
      end
    end

    def extend_right(left_lines, right_lines, finishes)
      while finishes[0] + 1 < left_lines.length && finishes[1] + 1 < right_lines.length &&
            equal_lines?(left_lines, finishes[0] + 1, right_lines, finishes[1] + 1)
        finishes[0] += 1
        finishes[1] += 1
      end
    end

    def equal_lines?(left_lines, left_index, right_lines, right_index)
      left_lines[left_index][:normalized] == right_lines[right_index][:normalized]
    end

    def candidate(left, right, starts, finishes)
      lines = logical_lines(left)
      Candidate.new(
        left: left, right: right, left_start: starts[0], left_finish: finishes[0],
        right_start: starts[1], right_finish: finishes[1],
        count: finishes[0] - starts[0] + 1,
        tokens: lines[starts[0]..finishes[0]].sum { |line| line[:tokens] }
      )
    end

    def meets_policy?(candidate)
      lines, tokens = policy_for(candidate)
      candidate.count >= lines && candidate.tokens >= tokens && !source_spans_overlap?(candidate)
    end

    def policy_for(candidate)
      return [TEST_CLONE_LINES, TEST_CLONE_TOKENS] if candidate.left.test_file || candidate.right.test_file

      [PRODUCTION_CLONE_LINES, PRODUCTION_CLONE_TOKENS]
    end

    def source_spans_overlap?(candidate)
      same_file?(candidate.left, candidate.right) &&
        ranges_overlap?(span(candidate.left, candidate.left_start, candidate.left_finish),
                        span(candidate.right, candidate.right_start, candidate.right_finish))
    end

    def suppress_overlapping(candidates)
      accepted = []
      candidates.sort_by { |item| [-item.count, -item.tokens, candidate_key(item)] }.each do |candidate|
        accepted << candidate unless accepted.any? { |chosen| candidates_overlap?(candidate, chosen) }
      end
      accepted
    end

    def candidates_overlap?(left, right)
      candidate_spans(left).any? do |left_span|
        candidate_spans(right).any? { |right_span| same_file?(left_span[:body], right_span[:body]) && ranges_overlap?(left_span[:range], right_span[:range]) }
      end
    end

    def candidate_spans(candidate)
      [
        { body: candidate.left, range: span(candidate.left, candidate.left_start, candidate.left_finish) },
        { body: candidate.right, range: span(candidate.right, candidate.right_start, candidate.right_finish) }
      ]
    end

    def span(body, start, finish)
      lines = logical_lines(body)
      lines[start][:line]..lines[finish][:line]
    end

    def same_file?(left, right)
      left.path == right.path
    end

    def ranges_overlap?(left, right)
      left.begin <= right.end && right.begin <= left.end
    end

    def report_for(candidate, targets)
      left_range = span(candidate.left, candidate.left_start, candidate.left_finish)
      right_range = span(candidate.right, candidate.right_start, candidate.right_finish)
      {
        path: candidate.left.path, line: left_range.begin,
        sort_key: candidate_key(candidate),
        message: "#{candidate.left.symbol} lines #{format_range(left_range)} duplicates #{candidate.right.path}:#{format_range(right_range)} in #{candidate.right.symbol} (#{candidate.count} logical lines, #{candidate.tokens} tokens, targets #{targets.join(', ')})"
      }
    end

    def candidate_key(candidate)
      [candidate.left.id, candidate.left_start, candidate.left_finish,
       candidate.right.id, candidate.right_start, candidate.right_finish]
    end

    def signature(lines)
      lines.map { |line| line[:normalized] }.join("\u0000")
    end

    def format_range(range)
      "#{range.begin}-#{range.end}"
    end

    def logical_lines(body)
      return @logical_line_cache[body.id] if @logical_line_cache.key?(body.id)

      original = body.clone_text.lines
      structural = body.sanitized.lines
      range = (body.open_line - 1)..(body.close_line - 1)
      @logical_line_cache[body.id] = range.each_with_object([]) do |number, lines|
        clone_line = original[number].to_s.strip
        structural_line = structural[number].to_s.strip
        next if clone_line.empty? || structural_line.empty? || clone_line.match?(/\A[{}]+\z/)

        normalized = clone_line.gsub(/\s+/, " ").strip
        lines << { normalized: normalized, line: number + 1, tokens: token_count(normalized) }
      end
    end

    def token_count(line)
      line.scan(/[A-Za-z_]\w*|\d+(?:\.\d+)?|\"(?:\\.|[^\"])*\"|\S/).length
    end
  end
end
