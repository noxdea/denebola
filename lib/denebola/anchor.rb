# frozen_string_literal: true

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
      edits.sort_by { |range, _| range.begin }.each do |range, text|
        start = range.begin
        finish = range.end + (range.exclude_end? ? 0 : 1)
        raise ArgumentError, "invalid or overlapping edits" unless start.is_a?(Integer) && start >= previous && finish >= start
        previous = finish
        if offset < start
          transformed ||= offset + delta
        elsif offset <= finish
          transformed ||= start + delta + (bias == :right ? text.bytesize : 0)
        end
        delta += text.bytesize - (finish - start)
      end
      self.class.new(transformed || offset + delta, bias: bias)
    end
  end
end
