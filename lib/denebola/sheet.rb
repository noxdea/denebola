# frozen_string_literal: true

module Denebola
  class Sheet
    class Summary
      attr_reader :count, :sum, :min, :max, :types

      def initialize(count: 0, sum: 0, min: nil, max: nil, types: {})
        @count, @sum, @min, @max = count, sum, min, max
        @types = types.freeze
        freeze
      end

      ZERO = new
      def self.zero = ZERO
      def self.value(value)
        numeric = value.is_a?(Numeric) && (value <=> value)
        new(count: 1, sum: value.is_a?(Numeric) ? value : 0,
            min: numeric ? value : nil, max: numeric ? value : nil,
            types: { value.class => 1 })
      end

      def +(other)
        types = @types.dup
        other.types.each { |type, count| types[type] = types.fetch(type, 0) + count }
        types.freeze
        self.class.new(count: count + other.count, sum: sum + other.sum,
                       min: extreme(min, other.min, :min), max: extreme(max, other.max, :max),
                       types: types)
      end

      def ==(other) = other.is_a?(Summary) && [count, sum, min, max, types] == [other.count, other.sum, other.min, other.max, other.types]
      alias eql? ==
      def hash = [count, sum, min, max, types].hash

      private

      def extreme(left, right, direction)
        return right if left.nil?
        return left if right.nil?
        comparison = left <=> right
        return nil unless comparison
        direction == :min ? (comparison <= 0 ? left : right) : (comparison >= 0 ? left : right)
      end
    end

    class ColumnSummary
      attr_reader :values, :column_count
      def initialize(values: Summary.zero, column_count: 0)
        @values, @column_count = values, column_count
        freeze
      end
      ZERO = new
      def self.zero = ZERO
      def +(other) = self.class.new(values: values + other.values, column_count: column_count + other.column_count)
      def ==(other) = other.is_a?(ColumnSummary) && values == other.values && column_count == other.column_count
      alias eql? ==
      def hash = [values, column_count].hash
    end

    class RowSummary
      attr_reader :values, :row_count
      def initialize(values: Summary.zero, row_count: 0)
        @values, @row_count = values, row_count
        freeze
      end
      ZERO = new
      def self.zero = ZERO
      def +(other) = self.class.new(values: values + other.values, row_count: row_count + other.row_count)
      def ==(other) = other.is_a?(RowSummary) && values == other.values && row_count == other.row_count
      alias eql? ==
      def hash = [values, row_count].hash
    end

    class Gap
      attr_reader :length
      def initialize(length, axis:)
        raise ArgumentError, "gap length must be positive" unless length.is_a?(Integer) && length.positive?
        @length, @axis = length, axis
        @summary = axis == :row ? RowSummary.new(row_count: length) : ColumnSummary.new(column_count: length)
        freeze
      end
      attr_reader :summary
    end

    class Cell
      attr_reader :value
      def initialize(value)
        @value = value.is_a?(String) ? value.dup.freeze : value
        @summary = ColumnSummary.new(values: Summary.value(@value), column_count: 1)
        freeze
      end
      attr_reader :summary
    end

    class Row
      attr_reader :columns
      def initialize(columns)
        @columns = columns
        @summary = RowSummary.new(values: columns.summary.values, row_count: 1)
        freeze
      end
      attr_reader :summary
    end

    DEFAULT_BRANCHING = Tree::DEFAULT_BRANCHING
    private_constant :ColumnSummary, :RowSummary, :Gap, :Cell, :Row

    attr_reader :row_count, :column_count, :cell_count

    def self.from_rows(rows, column_count, branching)
      sheet = allocate
      sheet.instance_variable_set(:@branching, branching)
      sheet.__send__(:initialize_state, rows, column_count)
    end
    private_class_method :from_rows

    def initialize(branching: DEFAULT_BRANCHING)
      raise ArgumentError, "branching must be an even integer >= 4" unless branching.is_a?(Integer) && branching >= 4 && branching.even?
      @branching = branching
      initialize_state(Tree.new(summary: RowSummary, branching: branching), 0)
    end

    def initialize_state(rows, column_count)
      raise ArgumentError, "column_count must be a non-negative integer" unless column_count.is_a?(Integer) && column_count >= 0
      @rows = rows
      @row_count = @rows.summary.row_count
      @column_count = column_count
      @cell_count = @rows.summary.values.count
      freeze
    end
    private :initialize_state

    def [](row, column)
      validate_coordinate(row, column)
      _index, item, prefix = @rows.locate(row, :row_count)
      return nil unless item.is_a?(Row) && row == prefix.row_count
      column_at(item.columns, column)
    end

    def set(row, column, value)
      validate_coordinate(row, column)
      return delete(row, column) if value.nil?
      rows = row >= row_count ? insert_axis(@rows, row_count, row - row_count + 1, :row) : @rows
      before, tail = split_axis(rows, row, :row)
      current, after = split_axis(tail, 1, :row)
      item = current[0]
      item = Row.new(empty_columns) unless item.is_a?(Row)
      columns = set_column(item.columns, column, value)
      updated = Row.new(columns)
      with_rows(concat(concat(before, tree([updated], RowSummary)), after), [@column_count, column + 1].max)
    end

    def delete(row, column)
      validate_coordinate(row, column)
      return self if row >= row_count || column >= column_count
      before, tail = split_axis(@rows, row, :row)
      current, after = split_axis(tail, 1, :row)
      item = current[0]
      return self unless item.is_a?(Row)
      columns = delete_column(item.columns, column)
      return self if columns.equal?(item.columns)
      replacement = columns.summary.values.count.zero? ? Gap.new(1, axis: :row) : Row.new(columns)
      with_rows(concat(concat(before, tree([replacement], RowSummary)), after), column_count)
    end

    def each_in(top, left, bottom, right)
      return enum_for(__method__, top, left, bottom, right) unless block_given?
      validate_range(top, left, bottom, right)
      return self if top >= row_count || left >= column_count
      _, tail = split_axis(@rows, top, :row)
      rows, = split_axis(tail, [bottom + 1 - top, row_count - top].min, :row)
      row = top
      rows.each do |item|
        if item.is_a?(Gap)
          row += item.length
          next
        end
        each_column(item.columns, left, right) { |column, value| yield Point.new(row, column), value }
        row += 1
      end
      self
    end

    def summary(top, left, bottom, right)
      validate_range(top, left, bottom, right)
      return Summary.zero if top >= row_count || left >= column_count
      _, tail = split_axis(@rows, top, :row)
      rows, = split_axis(tail, [bottom + 1 - top, row_count - top].min, :row)
      return rows.summary.values if left.zero? && right >= column_count - 1
      result = Summary.zero
      # ponytail: partial-column summaries visit occupied rows; use a 2D range tree if O(log² n) queries become necessary.
      rows.each do |item|
        next unless item.is_a?(Row)
        result += column_summary(item.columns, left, right)
      end
      result
    end

    def insert_rows(at, count)
      validate_insert(at, count, row_count)
      return self if count.zero?
      before, after = split_axis(@rows, at, :row)
      inserted = tree([Gap.new(count, axis: :row)], RowSummary)
      with_rows(concat(concat(before, inserted), after), column_count)
    end

    def delete_rows(at, count)
      validate_delete(at, count, row_count)
      return self if count.zero? || at == row_count
      before, tail = split_axis(@rows, at, :row)
      _, after = split_axis(tail, [count, row_count - at].min, :row)
      with_rows(concat(before, after), column_count)
    end

    def insert_columns(at, count)
      validate_insert(at, count, column_count)
      return self if count.zero?
      rows = []
      @rows.each do |item|
        if item.is_a?(Row) && at < item.columns.summary.column_count
          rows << Row.new(insert_axis(item.columns, at, count, :column))
        else
          rows << item
        end
      end
      with_rows(tree(coalesce_gaps(rows, :row), RowSummary), column_count + count)
    end

    def delete_columns(at, count)
      validate_delete(at, count, column_count)
      return self if count.zero? || at == column_count
      rows = []
      @rows.each do |item|
        if item.is_a?(Row) && at < item.columns.summary.column_count
          columns = delete_axis(item.columns, at, [count, item.columns.summary.column_count - at].min, :column)
          rows << (columns.summary.values.count.zero? ? Gap.new(1, axis: :row) : Row.new(columns))
        else
          rows << item
        end
      end
      with_rows(tree(coalesce_gaps(rows, :row), RowSummary), column_count - [count, column_count - at].min)
    end

    def snapshot = self

    def check_invariants!
      @rows.check_invariants!
      actual_rows = 0
      actual_cells = 0
      previous_gap = false
      @rows.each do |item|
        raise "adjacent row gaps" if previous_gap && item.is_a?(Gap)
        if item.is_a?(Gap)
          actual_rows += item.length
          previous_gap = true
        else
          raise "invalid row item" unless item.is_a?(Row)
          item.columns.check_invariants!
          actual_rows += 1
          actual_cells += item.columns.summary.values.count
          previous_gap = false
          previous_column_gap = false
          item.columns.each do |cell|
            raise "adjacent column gaps" if previous_column_gap && cell.is_a?(Gap)
            raise "invalid column item" unless cell.is_a?(Gap) || cell.is_a?(Cell)
            previous_column_gap = cell.is_a?(Gap)
          end
        end
      end
      raise "incorrect row count" unless actual_rows == row_count
      raise "incorrect cell count" unless actual_cells == cell_count
      raise "invalid column count" unless column_count >= 0
      true
    end

    private

    def validate_coordinate(row, column)
      raise ArgumentError, "row and column must be non-negative integers" unless row.is_a?(Integer) && row >= 0 && column.is_a?(Integer) && column >= 0
    end

    def validate_range(top, left, bottom, right)
      validate_coordinate(top, left)
      validate_coordinate(bottom, right)
      raise ArgumentError, "range end precedes range start" if bottom < top || right < left
    end

    def validate_insert(at, count, extent)
      raise ArgumentError, "insert position must be within the sheet" unless at.is_a?(Integer) && at.between?(0, extent)
      raise ArgumentError, "count must be a non-negative integer" unless count.is_a?(Integer) && count >= 0
    end

    def validate_delete(at, count, extent)
      raise ArgumentError, "delete position must be within the sheet" unless at.is_a?(Integer) && at.between?(0, extent)
      raise ArgumentError, "count must be a non-negative integer" unless count.is_a?(Integer) && count >= 0
    end

    def empty_columns = Tree.new(summary: ColumnSummary, branching: @branching)
    def empty_tree(summary) = Tree.new(summary: summary, branching: @branching)
    def tree(items, summary) = Tree.new(items, summary: summary, branching: @branching)
    def with_rows(rows, columns) = self.class.__send__(:from_rows, rows, columns, @branching)

    def split_axis(source, position, axis)
      total = axis == :row ? source.summary.row_count : source.summary.column_count
      raise RangeError, "axis position out of bounds" unless position.is_a?(Integer) && position.between?(0, total)
      summary_type = axis == :row ? RowSummary : ColumnSummary
      return [source, empty_tree(summary_type)] if position == total
      index, item, prefix = source.locate(position, axis == :row ? :row_count : :column_count)
      local = position - (axis == :row ? prefix.row_count : prefix.column_count)
      return source.split_at(index) if local.zero?
      before, after = source.split_at(index)
      left_length = item.length
      left = before.push(Gap.new(local, axis: axis))
      right = tree([Gap.new(left_length - local, axis: axis)], summary_type).append(after.slice(1, after.size - 1))
      [left, right]
    end

    def concat(left, right)
      return right if left.empty?
      return left if right.empty?
      last = left[left.size - 1]
      first = right[0]
      return left.append(right) unless last.is_a?(Gap) && first.is_a?(Gap)
      left = left.replace_at(left.size - 1, [Gap.new(last.length + first.length, axis: last_axis(last))])
      left.append(right.slice(1, right.size - 1))
    end

    def last_axis(gap)
      gap.summary.is_a?(RowSummary) ? :row : :column
    end

    def insert_axis(source, at, count, axis)
      before, after = split_axis(source, at, axis)
      summary_type = axis == :row ? RowSummary : ColumnSummary
      concat(concat(before, tree([Gap.new(count, axis: axis)], summary_type)), after)
    end

    def delete_axis(source, at, count, axis)
      before, tail = split_axis(source, at, axis)
      _, after = split_axis(tail, [count, (axis == :row ? tail.summary.row_count : tail.summary.column_count)].min, axis)
      concat(before, after)
    end

    def set_column(columns, column, value)
      columns = insert_axis(columns, columns.summary.column_count, column + 1 - columns.summary.column_count, :column) if column >= columns.summary.column_count
      before, tail = split_axis(columns, column, :column)
      _current, after = split_axis(tail, 1, :column)
      concat(concat(before, tree([Cell.new(value)], ColumnSummary)), after)
    end

    def delete_column(columns, column)
      return columns if column >= columns.summary.column_count
      before, tail = split_axis(columns, column, :column)
      current, after = split_axis(tail, 1, :column)
      return columns unless current[0].is_a?(Cell)
      concat(concat(before, tree([Gap.new(1, axis: :column)], ColumnSummary)), after)
    end

    def column_at(columns, column)
      return nil if column >= columns.summary.column_count
      _, item, prefix = columns.locate(column, :column_count)
      item.is_a?(Cell) && column == prefix.column_count ? item.value : nil
    end

    def each_column(columns, left, right)
      return if left >= columns.summary.column_count
      _, tail = split_axis(columns, left, :column)
      selected, = split_axis(tail, [right + 1 - left, columns.summary.column_count - left].min, :column)
      column = left
      selected.each do |item|
        if item.is_a?(Gap)
          column += item.length
        else
          yield column, item.value
          column += 1
        end
      end
    end

    def column_summary(columns, left, right)
      return Summary.zero if left >= columns.summary.column_count
      _, tail = split_axis(columns, left, :column)
      selected, = split_axis(tail, [right + 1 - left, columns.summary.column_count - left].min, :column)
      selected.summary.values
    end

    def coalesce_gaps(items, axis)
      items.each_with_object([]) do |item, result|
        if item.is_a?(Gap) && result.last.is_a?(Gap)
          result[-1] = Gap.new(result.last.length + item.length, axis: axis)
        else
          result << item
        end
      end
    end
  end
end
