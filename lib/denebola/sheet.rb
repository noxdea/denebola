# frozen_string_literal: true

module Denebola
  class Sheet
    # Maps current axis coordinates to stable RangeIndex coordinates. Structural
    # edits split or remove these runs without moving unaffected index entries.
    # ponytail: flat runs make edits O(S) and rectangle queries O(Sr×Sc); use a persistent interval tree if fragmented-axis workloads dominate.
    class IndexAxis
      Segment = Struct.new(:length, :index_start, keyword_init: true)

      attr_reader :extent, :next_index, :segments

      def initialize(segments: [], extent: 0, next_index: 0)
        @segments = segments.freeze
        @extent, @next_index = extent, next_index
        freeze
      end

      def self.identity(extent)
        new(segments: extent.positive? ? [segment(extent, 0)] : [], extent: extent, next_index: extent)
      end

      def ensure_length(length)
        return self if length == extent
        raise ArgumentError, "axis length cannot shrink" unless length > extent

        append(length - extent)
      end

      def index_at(position)
        raise RangeError, "axis position out of bounds" unless position.is_a?(Integer) && position.between?(0, extent - 1)

        offset = 0
        segments.each do |segment|
          return segment.index_start + position - offset if position < offset + segment.length
          offset += segment.length
        end
        raise "axis mapping is incomplete"
      end

      def ranges(first, last)
        return [] if first > last || first >= extent

        last = [last, extent - 1].min
        offset = 0
        segments.filter_map do |segment|
          finish = offset + segment.length - 1
          from = [first, offset].max
          to = [last, finish].min
          mapped = [segment.index_start + from - offset, segment.index_start + to - offset] if from <= to
          offset = finish + 1
          mapped
        end
      end

      def insert(at, count)
        return self if count.zero?

        left, right = split(at)
        self.class.new(segments: coalesce(left + [self.class.segment(count, next_index)] + right),
                       extent: extent + count, next_index: next_index + count)
      end

      def delete(at, count)
        count = [count, extent - at].min
        return self if count.zero?

        left, tail = split(at)
        _removed, right = split_segments(tail, count)
        self.class.new(segments: coalesce(left + right), extent: extent - count, next_index: next_index)
      end

      def check_invariants!
        raise "invalid axis extent" unless segments.sum(&:length) == extent
        raise "invalid axis segment" unless segments.all? { |segment| segment.length.positive? && segment.index_start >= 0 }
        raise "coalescible axis segments" if segments.each_cons(2).any? { |left, right| left.index_start + left.length == right.index_start }
        true
      end

      private

      def append(length)
        self.class.new(segments: coalesce(segments + [self.class.segment(length, next_index)]),
                       extent: extent + length, next_index: next_index + length)
      end

      def split(position)
        raise RangeError, "axis position out of bounds" unless position.between?(0, extent)
        left, right = split_segments(segments, position)
        [left, right]
      end

      def split_segments(items, length)
        left = []
        right = []
        offset = 0
        items.each do |segment|
          before = [[length - offset, 0].max, segment.length].min
          left << self.class.segment(before, segment.index_start) if before.positive?
          after = segment.length - before
          right << self.class.segment(after, segment.index_start + before) if after.positive?
          offset += segment.length
        end
        [left, right]
      end

      def coalesce(items)
        items.each_with_object([]) do |segment, result|
          previous = result.last
          if previous && previous.index_start + previous.length == segment.index_start
            result[-1] = self.class.segment(previous.length + segment.length, previous.index_start)
          else
            result << segment
          end
        end
      end

      def self.segment(length, index_start) = Segment.new(length:, index_start:).freeze
    end

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
    private_constant :IndexAxis, :ColumnSummary, :RowSummary, :Gap, :Cell, :Row

    attr_reader :row_count, :column_count, :cell_count

    def self.from_rows(rows, column_count, branching, range_index = nil, row_axis = nil, column_axis = nil)
      sheet = allocate
      sheet.instance_variable_set(:@branching, branching)
      sheet.__send__(:initialize_state, rows, column_count, range_index, row_axis, column_axis)
    end
    private_class_method :from_rows

    def initialize(branching: DEFAULT_BRANCHING)
      raise ArgumentError, "branching must be an even integer >= 4" unless branching.is_a?(Integer) && branching >= 4 && branching.even?
      @branching = branching
      initialize_state(Tree.new(summary: RowSummary, branching: branching), 0, nil)
    end

    def initialize_state(rows, column_count, range_index, row_axis = nil, column_axis = nil)
      raise ArgumentError, "column_count must be a non-negative integer" unless column_count.is_a?(Integer) && column_count >= 0
      @rows = rows
      @row_count = @rows.summary.row_count
      @column_count = column_count
      @cell_count = @rows.summary.values.count
      @range_index = range_index
      @row_axis = row_axis || IndexAxis.identity(@row_count)
      @column_axis = column_axis || IndexAxis.identity(@column_count)
      raise ArgumentError, "row-axis extent differs from sheet" unless @row_axis.extent == @row_count
      raise ArgumentError, "column-axis extent differs from sheet" unless @column_axis.extent == @column_count
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
      rows = concat(concat(before, tree([updated], RowSummary)), after)
      new_column_count = [@column_count, column + 1].max
      row_axis = @row_axis.ensure_length([row_count, row + 1].max)
      column_axis = @column_axis.ensure_length(new_column_count)
      index = if new_column_count <= 1
        nil
      elsif @range_index
        @range_index.update(row_axis.index_at(row), column_axis.index_at(column), self[row, column], value)
      else
        RangeIndex.from_rows(rows, row_axis, column_axis)
      end
      with_rows(rows, new_column_count, index, row_axis, column_axis)
    end

    # Apply [row, column, value] edits against one snapshot; the last duplicate wins.
    def set_many(changes)
      grouped = {}
      changes.each do |change|
        raise ArgumentError, "each cell change must contain row, column, and value" unless change.respond_to?(:length) && change.length == 3

        row, column, value = change
        validate_coordinate(row, column)
        (grouped[row] ||= {})[column] = value
      end
      return self if grouped.empty?

      updates = []
      new_row_count = row_count
      new_column_count = column_count
      grouped.sort.each do |row, values|
        edits = values.sort
        has_value = false
        edits.each do |column, value|
          next if value.nil?

          has_value = true
          new_row_count = row + 1 if row + 1 > new_row_count
          new_column_count = column + 1 if column + 1 > new_column_count
        end
        updates << [row, edits] if row < row_count || has_value
      end
      return self if updates.empty?

      result = []
      update_index = 0
      position = 0
      changed = false

      @rows.each do |item|
        if item.is_a?(Gap)
          finish = position + item.length
          while update_index < updates.length && updates[update_index][0] < finish
            row, edits = updates[update_index]
            append_gap(result, row - position) if row > position
            updated = updated_row(nil, edits)
            append_row(result, updated)
            changed ||= !updated.nil?
            position = row + 1
            update_index += 1
          end
          append_gap(result, finish - position) if finish > position
          position = finish
        else
          if update_index < updates.length && updates[update_index][0] == position
            updated = updated_row(item, updates[update_index][1])
            append_row(result, updated)
            changed ||= !updated.equal?(item)
            update_index += 1
          else
            result << item
          end
          position += 1
        end
      end

      while update_index < updates.length
        row, edits = updates[update_index]
        append_gap(result, row - position) if row > position
        updated = updated_row(nil, edits)
        append_row(result, updated)
        changed ||= !updated.nil?
        position = row + 1
        update_index += 1
      end
      append_gap(result, new_row_count - position) if new_row_count > position
      return self unless changed || new_row_count != row_count || new_column_count != column_count

      rows = tree(result, RowSummary)
      row_axis = @row_axis.ensure_length(new_row_count)
      column_axis = @column_axis.ensure_length(new_column_count)
      index = if new_column_count <= 1
        nil
      elsif @range_index
        range_index = @range_index
        updates.each do |row, edits|
          edits.each do |column, value|
            old_value = self[row, column]
            if old_value != value
              range_index = range_index.update(row_axis.index_at(row), column_axis.index_at(column), old_value, value)
            end
          end
        end
        range_index
      else
        RangeIndex.from_rows(rows, row_axis, column_axis)
      end
      with_rows(rows, new_column_count, index, row_axis, column_axis)
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
      rows = concat(concat(before, tree([replacement], RowSummary)), after)
      index = if column_count <= 1
        nil
      elsif @range_index
        @range_index.update(@row_axis.index_at(row), @column_axis.index_at(column), self[row, column], nil)
      else
        RangeIndex.from_rows(rows, @row_axis, @column_axis)
      end
      with_rows(rows, column_count, index)
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
      raise "missing 2D range index for partial summary" unless @range_index
      row_ranges = @row_axis.ranges(top, bottom)
      column_ranges = @column_axis.ranges(left, right)
      row_ranges.sum(Summary.zero) do |row_first, row_last|
        column_ranges.sum(Summary.zero) do |column_first, column_last|
          @range_index.summary(row_first, column_first, row_last, column_last)
        end
      end
    end

    def insert_rows(at, count)
      validate_insert(at, count, row_count)
      return self if count.zero?
      before, after = split_axis(@rows, at, :row)
      inserted = tree([Gap.new(count, axis: :row)], RowSummary)
      rows = concat(concat(before, inserted), after)
      row_axis = @row_axis.insert(at, count)
      index = @range_index || RangeIndex.new if column_count > 1
      with_rows(rows, column_count, index, row_axis)
    end

    def delete_rows(at, count)
      validate_delete(at, count, row_count)
      return self if count.zero? || at == row_count
      before, tail = split_axis(@rows, at, :row)
      removed_count = [count, row_count - at].min
      removed, after = split_axis(tail, removed_count, :row)
      rows = concat(before, after)
      index = @range_index
      if index && column_count > 1
        row = at
        removed.each do |item|
          if item.is_a?(Gap)
            row += item.length
            next
          end
          row_index = @row_axis.index_at(row)
          column = 0
          item.columns.each do |cell|
            if cell.is_a?(Cell)
              index = index.update(row_index, @column_axis.index_at(column), cell.value, nil)
              column += 1
            else
              column += cell.length
            end
          end
          row += 1
        end
      end
      row_axis = @row_axis.delete(at, count)
      with_rows(rows, column_count, index, row_axis)
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
      rows = tree(coalesce_gaps(rows, :row), RowSummary)
      new_column_count = column_count + count
      column_axis = @column_axis.insert(at, count)
      index = @range_index || RangeIndex.new if new_column_count > 1
      with_rows(rows, new_column_count, index, @row_axis, column_axis)
    end

    def delete_columns(at, count)
      validate_delete(at, count, column_count)
      return self if count.zero? || at == column_count
      rows = []
      index = @range_index
      delete_count = [count, column_count - at].min
      row = 0
      @rows.each do |item|
        if item.is_a?(Gap)
          rows << item
          row += item.length
          next
        end
        if index && column_count - delete_count > 1
          each_column(item.columns, at, at + delete_count - 1) do |column, value|
            index = index.update(@row_axis.index_at(row), @column_axis.index_at(column), value, nil)
          end
        end
        if item.is_a?(Row) && at < item.columns.summary.column_count
          columns = delete_axis(item.columns, at, [count, item.columns.summary.column_count - at].min, :column)
          rows << (columns.summary.values.count.zero? ? Gap.new(1, axis: :row) : Row.new(columns))
        else
          rows << item
        end
        row += 1
      end
      rows = tree(coalesce_gaps(rows, :row), RowSummary)
      new_column_count = column_count - delete_count
      column_axis = @column_axis.delete(at, count)
      index = nil if new_column_count <= 1
      index ||= RangeIndex.new if new_column_count > 1
      with_rows(rows, new_column_count, index, @row_axis, column_axis)
    end

    def snapshot = self

    def check_invariants!
      @rows.check_invariants!
      @row_axis.check_invariants!
      @column_axis.check_invariants!
      raise "incorrect row-axis extent" unless @row_axis.extent == row_count
      raise "incorrect column-axis extent" unless @column_axis.extent == column_count
      if column_count > 1
        raise "missing 2D range index" unless @range_index
        @range_index.check_invariants!
        range_summary = indexed_summary(0, 0, row_count - 1, column_count - 1)
        raise "incorrect 2D range-index summary" unless range_summary == @rows.summary.values
      end

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
    def with_rows(rows, columns, range_index = nil, row_axis = @row_axis, column_axis = @column_axis)
      self.class.__send__(:from_rows, rows, columns, @branching, range_index, row_axis, column_axis)
    end

    def indexed_summary(top, left, bottom, right)
      return Summary.zero if top > bottom || left > right

      row_ranges = @row_axis.ranges(top, bottom)
      column_ranges = @column_axis.ranges(left, right)
      row_ranges.sum(Summary.zero) do |row_first, row_last|
        column_ranges.sum(Summary.zero) do |column_first, column_last|
          @range_index.summary(row_first, column_first, row_last, column_last)
        end
      end
    end

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

    def updated_row(row, edits)
      columns = row ? row.columns : empty_columns
      updated = update_columns(columns, edits)
      return row if row && updated.equal?(columns)
      return nil if updated.summary.values.count.zero?

      Row.new(updated)
    end

    def update_columns(columns, edits)
      return columns if edits.empty?

      extent = [columns.summary.column_count, *edits.filter_map { |column, value| column + 1 unless value.nil? }].max
      result = []
      changed = false
      position = 0
      edit_index = 0

      columns.each do |item|
        if item.is_a?(Gap)
          finish = position + item.length
          while edit_index < edits.length && edits[edit_index][0] < finish
            column, value = edits[edit_index]
            if value.nil?
              append_gap(result, column - position + 1, :column) if column >= position
              position = column + 1
            else
              append_gap(result, column - position, :column) if column > position
              result << Cell.new(value)
              position = column + 1
              changed = true
            end
            edit_index += 1
          end
          append_gap(result, finish - position, :column) if finish > position
          position = finish
        else
          if edit_index < edits.length && edits[edit_index][0] == position
            value = edits[edit_index][1]
            if value.nil?
              append_gap(result, 1, :column)
              changed = true
            elsif value == item.value
              result << item
            else
              result << Cell.new(value)
              changed = true
            end
            edit_index += 1
          else
            result << item
          end
          position += 1
        end
      end

      while edit_index < edits.length
        column, value = edits[edit_index]
        if !value.nil?
          append_gap(result, column - position, :column) if column > position
          result << Cell.new(value)
          position = column + 1
          changed = true
        end
        edit_index += 1
      end
      append_gap(result, extent - position, :column) if extent > position
      return columns unless changed

      tree(result, ColumnSummary)
    end

    def append_row(items, row)
      append_gap(items, 1) unless row
      items << row if row
    end

    def append_gap(items, length, axis = :row)
      return if length.zero?

      if items.last.is_a?(Gap)
        items[-1] = Gap.new(items.last.length + length, axis: axis)
      else
        items << Gap.new(length, axis: axis)
      end
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
