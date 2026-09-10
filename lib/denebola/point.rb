# frozen_string_literal: true

module Denebola
  class Point
    attr_reader :row, :column
    def initialize(row = 0, column = 0, **keywords)
      @row, @column = keywords.fetch(:row, row), keywords.fetch(:column, column)
      unless @row.is_a?(Integer) && @column.is_a?(Integer) && @row >= 0 && @column >= 0
        raise ArgumentError, "row and column must be nonnegative integers"
      end
      freeze
    end
    def ==(other) = other.is_a?(Point) && row == other.row && column == other.column
    alias eql? ==
    def hash = [row, column].hash
    def to_a = [row, column]
    def inspect = "#<Denebola::Point row=#{row} column=#{column}>"
  end
end
