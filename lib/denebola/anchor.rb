# frozen_string_literal: true

require_relative "edit"

module Denebola
  # A position transformed explicitly by edits against its current snapshot.
  class Anchor
    attr_reader :offset, :bias
    def initialize(offset, bias: :right)
      raise ArgumentError, "offset must be nonnegative" unless offset.is_a?(Integer) && offset >= 0
      raise ArgumentError, "bias must be :left or :right" unless %i[left right].include?(bias)
      @offset, @bias = offset, bias
      freeze
    end

    def transform(edits)
      delta = 0
      previous = 0
      transformed = nil
      normalized = edits.map do |range, text|
        raise TypeError, "expected a Range of byte offsets" unless range.is_a?(Range)
        start = range.begin
        finish = range.end + (range.exclude_end? ? 0 : 1)
        raise ArgumentError, "invalid edit" unless start.is_a?(Integer) && finish.is_a?(Integer) && start >= 0 && finish >= start
        [start, finish, Edit.normalize_text(text)]
      end
      Edit.sort(normalized).each do |start, finish, text|
        raise ArgumentError, "invalid or overlapping edits" if start < previous
        previous = finish
        if offset < start
          transformed ||= offset + delta
        elsif offset <= finish
          position = start + delta
          transformed = position + text.bytesize if bias == :right
          transformed ||= position
        end
        delta += text.bytesize - (finish - start)
      end
      self.class.new(transformed || offset + delta, bias: bias)
    end
  end
end
