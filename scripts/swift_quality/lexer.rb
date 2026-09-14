# frozen_string_literal: true

module SwiftQuality
  class Lexer
    def self.lex(source)
      new(source).lex
    end

    def initialize(source)
      @source = source
      @structural = +""
      @clone_text = +""
      @index = 0
      @block_comment_depth = 0
      @string = nil
    end

    def lex
      consume until @index >= @source.length
      [@structural, @clone_text]
    end

    private

    def consume
      return consume_comment if @block_comment_depth.positive?
      return consume_string if @string
      return consume_line_comment if @source[@index, 2] == "//"
      return start_comment if @source[@index, 2] == "/*"

      start = string_start
      return start_string(start) if start

      append(@source[@index])
      @index += 1
    end

    def consume_comment
      if @source[@index, 2] == "/*"
        blank("  "); @block_comment_depth += 1; @index += 2
      elsif @source[@index, 2] == "*/"
        blank("  "); @block_comment_depth -= 1; @index += 2
      else
        blank(@source[@index]); @index += 1
      end
    end

    def consume_string
      closing = @string[:quote] + ("#" * @string[:hashes])
      return close_string(closing) if @source[@index, closing.length] == closing

      character = @source[@index]
      @structural << (character == "\n" ? "\n" : " ")
      @clone_text << character
      consume_escape(character)
    end

    def consume_escape(character)
      if @string[:hashes].zero? && character == "\\" && @index + 1 < @source.length
        escaped = @source[@index + 1]
        @structural << (escaped == "\n" ? "\n" : " ")
        @clone_text << escaped
        @index += 2
      else
        @index += 1
      end
    end

    def close_string(closing)
      @structural << (" " * closing.length)
      @clone_text << closing
      @index += closing.length
      @string = nil
    end

    def consume_line_comment
      newline = @source.index("\n", @index) || @source.length
      @source[@index...newline].each_char { |character| blank(character) }
      @index = newline
    end

    def start_comment
      blank("  "); @block_comment_depth = 1; @index += 2
    end

    def start_string(start)
      quote, hashes = start
      length = quote.length + hashes
      @structural << (" " * length)
      @clone_text << @source[@index, length]
      @index += length
      @string = { quote: quote, hashes: hashes }
    end

    def string_start
      hashes = 0
      hashes += 1 while @source[@index + hashes] == "#"
      marker = @source[@index + hashes, 3] == '"""' ? '"""' : (@source[@index + hashes] == '"' ? '"' : nil)
      marker ? [marker, hashes] : nil
    end

    def append(character)
      @structural << character
      @clone_text << character
    end

    def blank(characters)
      @structural << characters.tr("^\n", " ")
      @clone_text << characters.tr("^\n", " ")
    end
  end
end
