# frozen_string_literal: true

module Denebola
  # The number of line breaks is additive, except CR + LF is one break.
  class TextSummary
    FIELDS = %i[bytesize length utf16_length break_count longest_row longest_row_length
                first_line_length last_line_length starts_with_lf? ends_with_cr?].freeze
    attr_reader :bytesize, :length, :utf16_length, :break_count, :longest_row,
                :longest_row_length, :first_line_length, :last_line_length

    def initialize(bytesize: 0, length: 0, utf16_length: 0, break_count: 0,
                   longest_row: 0, longest_row_length: 0, first_line_length: 0,
                   last_line_length: 0, starts_with_lf: false, ends_with_cr: false)
      @bytesize, @length, @utf16_length, @break_count = bytesize, length, utf16_length, break_count
      @longest_row, @longest_row_length = longest_row, longest_row_length
      @first_line_length, @last_line_length = first_line_length, last_line_length
      @starts_with_lf, @ends_with_cr = starts_with_lf, ends_with_cr
      freeze
    end

    ZERO = new
    def self.zero = ZERO

    def self.from_text(text, line_ends: nil)
      if text.ascii_only? && !text.include?("\r")
        start = lines = first = longest = longest_row = 0
        while (ending = text.index("\n", start))
          width = ending - start
          first = width if lines.zero?
          longest, longest_row = width, lines if width > longest
          lines += 1
          start = ending + 1
          line_ends << start if line_ends
        end
        last = text.bytesize - start
        first = last if lines.zero?
        longest, longest_row = last, lines if last > longest
        return new(bytesize: text.bytesize, length: text.bytesize, utf16_length: text.bytesize,
                   break_count: lines, longest_row: longest_row, longest_row_length: longest,
                   first_line_length: first, last_line_length: last, starts_with_lf: text.start_with?("\n"))
      end
      rows = text.split(/\r\n|[\r\n\u2028\u2029]/, -1)
      rows = [""] if rows.empty?
      lengths = rows.map(&:length)
      longest = lengths.max
      chars = text.length
      supplementary = text.ascii_only? ? 0 : text.scan(/[\u{10000}-\u{10ffff}]/).length
      if line_ends
        offset = 0
        text.split(/(\r\n|[\r\n\u2028\u2029])/, -1).each_with_index do |part, index|
          offset += part.bytesize
          line_ends << offset if index.odd?
        end
      end
      new(bytesize: text.bytesize, length: chars, utf16_length: chars + supplementary,
          break_count: rows.length - 1, longest_row: lengths.index(longest), longest_row_length: longest,
          first_line_length: lengths.first, last_line_length: lengths.last,
          starts_with_lf: text.start_with?("\n"), ends_with_cr: text.end_with?("\r"))
    end

    def +(other)
      return other if bytesize.zero?
      return self if other.bytesize.zero?
      overlap = ends_with_cr? && other.starts_with_lf? ? 1 : 0
      bridge = last_line_length + other.first_line_length
      row = longest_row
      width = longest_row_length
      if bridge > width
        row, width = break_count, bridge
      end
      if other.longest_row_length > width
        row, width = break_count - overlap + other.longest_row, other.longest_row_length
      end
      self.class.new(bytesize: bytesize + other.bytesize, length: length + other.length,
                     utf16_length: utf16_length + other.utf16_length,
                     break_count: break_count + other.break_count - overlap,
                     longest_row: row, longest_row_length: width,
                     first_line_length: break_count.zero? ? first_line_length + other.first_line_length : first_line_length,
                     last_line_length: other.break_count.zero? ? last_line_length + other.last_line_length : other.last_line_length,
                     starts_with_lf: starts_with_lf?, ends_with_cr: other.ends_with_cr?)
    end

    def ==(other) = other.is_a?(TextSummary) && FIELDS.all? { |field| public_send(field) == other.public_send(field) }
    alias eql? ==
    def hash = FIELDS.map { |field| public_send(field) }.hash

    def starts_with_lf? = @starts_with_lf
    def ends_with_cr? = @ends_with_cr

    def project_combined(dimension, other)
      case dimension
      when :bytesize then bytesize + other.bytesize
      when :length then length + other.length
      when :utf16_length then utf16_length + other.utf16_length
      when :break_count then break_count + other.break_count - (ends_with_cr? && other.starts_with_lf? ? 1 : 0)
      else (self + other).public_send(dimension)
      end
    end
  end
end
