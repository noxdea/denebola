# frozen_string_literal: true

require "test_helper"

class SheetTest < Minitest::Test
  def test_sparse_cells_summaries_and_persistent_snapshots
    sheet = Denebola::Sheet.new.set(1, 1, 2).set(1, 3, 4).set(3, 1, "note")
    snapshot = sheet.snapshot

    assert_same sheet, snapshot
    assert_equal [4, 4, 3], [sheet.row_count, sheet.column_count, sheet.cell_count]
    assert_equal 6, sheet.summary(1, 1, 1, 3).sum
    assert_equal 2, sheet.summary(0, 0, 3, 3).min
    assert_equal 4, sheet.summary(0, 0, 3, 3).max
    assert_equal({ Integer => 2, String => 1 }, sheet.summary(0, 0, 3, 3).types)
    assert_equal [[Denebola::Point.new(1, 1), 2], [Denebola::Point.new(1, 3), 4],
                  [Denebola::Point.new(3, 1), "note"]], sheet.each_in(0, 0, 3, 3).to_a

    edited = sheet.set(1, 1, 9).delete(1, 3)
    assert_equal 2, snapshot[1, 1]
    assert_equal 4, snapshot[1, 3]
    assert_equal 9, edited[1, 1]
    assert_nil edited[1, 3]
    sheet.check_invariants!
  end

  def test_each_in_forwards_reference_and_value_to_a_source_callback
    sheet = Denebola::Sheet.new.set(2, 4, 9)
    values = {}
    callback = ->(reference, value) { values[reference] = value }

    sheet.each_in(0, 0, 5, 5, &callback)

    assert_equal({ Denebola::Point.new(2, 4) => 9 }, values)
  end

  def test_insert_and_delete_rows_and_columns_shift_values_without_changing_old_snapshots
    sheet = Denebola::Sheet.new.set(1, 1, 11).set(4, 3, 43)
    inserted = sheet.insert_rows(1, 2).insert_columns(2, 3)

    assert_equal 11, inserted[3, 1]
    assert_equal 43, inserted[6, 6]
    assert_equal 7, inserted.row_count
    assert_equal 7, inserted.column_count
    restored = inserted.delete_rows(1, 2).delete_columns(2, 3)
    assert_equal 11, restored[1, 1]
    assert_equal 43, restored[4, 3]
    assert_equal 11, sheet[1, 1]
    assert_nil sheet[3, 3]
    inserted.check_invariants!
  end

  def test_deleting_cells_coalesces_sparse_rows_and_columns
    sheet = Denebola::Sheet.new.set(0, 0, 1).set(0, 5, 2).set(8, 3, 3)
    sheet = sheet.delete(0, 0).delete(0, 5).delete(8, 3)

    assert_equal 9, sheet.row_count
    assert_equal 6, sheet.column_count
    assert_equal 0, sheet.cell_count
    assert_empty sheet.each_in(0, 0, 20, 20).to_a
    sheet.check_invariants!
  end

  def test_set_many_applies_duplicate_dense_and_sparse_edits_persistently
    source = Denebola::Sheet.new.set(0, 0, "old").set(2, 4, 9)
    changed = source.set_many([
      [0, 0, "new"], [0, 1, 2], [0, 1, 3], [2, 4, nil], [2, 3, 6],
      [5, 100, 7], [1_000_000, 16_383, 8], [1_000_001, 20, nil]
    ])

    assert_same source, source.snapshot
    assert_equal "old", source[0, 0]
    assert_equal 9, source[2, 4]
    assert_equal "new", changed[0, 0]
    assert_equal 3, changed[0, 1]
    assert_nil changed[2, 4]
    assert_equal 6, changed[2, 3]
    assert_equal 7, changed[5, 100]
    assert_equal 8, changed[1_000_000, 16_383]
    assert_equal [1_000_001, 16_384, 5], [changed.row_count, changed.column_count, changed.cell_count]
    assert_equal 24, changed.summary(0, 0, 1_000_000, 16_383).sum
    changed.check_invariants!
  end

  def test_set_many_noops_and_invalid_input
    sheet = Denebola::Sheet.new.set(1, 2, "same")

    assert_same sheet, sheet.set_many([[1, 2, "same"], [10_000, 0, nil]])
    assert_raises(ArgumentError) { sheet.set_many([[2, 3, 1], [-1, 0, 2]]) }
    assert_raises(ArgumentError) { sheet.set_many([[0, 0]]) }
    assert_equal "same", sheet[1, 2]
    sheet.check_invariants!
  end

  def test_single_column_sheets_skip_the_unneeded_2d_index
    sheet = Denebola::Sheet.new.set_many(100.times.map { |row| [row, 0, row] })

    assert_nil sheet.instance_variable_get(:@range_index)
    assert_equal 4_950, sheet.summary(0, 0, 99, 0).sum
    assert_nil sheet.instance_variable_get(:@range_index)

    wider = sheet.set(50, 1, "label")
    refute_nil wider.instance_variable_get(:@range_index)
    assert_equal({ Integer => 100 }, wider.summary(0, 0, 99, 0).types)
    assert_equal({ String => 1 }, wider.summary(0, 1, 99, 1).types)
    wider.check_invariants!
  end

  def test_random_bulk_edits_match_sequential_edits
    random = Random.new(9401)
    30.times do
      original = Denebola::Sheet.new
      40.times do
        original = original.set(random.rand(20), random.rand(20), random.rand(100))
      end
      changes = Array.new(100) do
        [random.rand(25), random.rand(25), random.rand(5).zero? ? nil : random.rand(100)]
      end
      # Duplicate some coordinates to verify that input order defines the winner.
      changes.concat(changes.first(10).map { |row, column, value| [row, column, value] })
      expected = changes.reduce(original) { |sheet, (row, column, value)| sheet.set(row, column, value) }
      actual = original.set_many(changes)

      assert_equal expected.row_count, actual.row_count
      assert_equal expected.column_count, actual.column_count
      assert_equal expected.cell_count, actual.cell_count
      assert_equal expected.each_in(0, 0, 24, 24).to_a, actual.each_in(0, 0, 24, 24).to_a
      assert_equal expected.summary(0, 0, 24, 24), actual.summary(0, 0, 24, 24)
      actual.check_invariants!
    end
  end

  def test_validation_and_string_values_are_isolated
    text = +"value"
    sheet = Denebola::Sheet.new.set(0, 0, text)
    text.replace("changed")

    assert_equal "value", sheet[0, 0]
    assert_raises(ArgumentError) { sheet.set(-1, 0, 1) }
    assert_raises(ArgumentError) { sheet.summary(2, 0, 1, 0) }
    assert_raises(ArgumentError) { sheet.insert_rows(2, 1) }
  end

  def test_deterministic_edits_match_a_hash_reference
    random = Random.new(19)
    sheet = Denebola::Sheet.new
    cells = {}

    500.times do |step|
      case random.rand(6)
      when 0
        row, column = random.rand(16), random.rand(16)
        value = random.rand(4).zero? ? "v#{step}" : random.rand(-20..20)
        sheet = sheet.set(row, column, value)
        cells[[row, column]] = value
      when 1
        row, column = random.rand(16), random.rand(16)
        sheet = sheet.delete(row, column)
        cells.delete([row, column])
      when 2
        at, count = random.rand(sheet.row_count + 1), random.rand(1..3)
        sheet = sheet.insert_rows(at, count)
        cells = cells.each_with_object({}) { |((row, column), value), result| result[[row >= at ? row + count : row, column]] = value }
      when 3
        next if sheet.row_count.zero?
        at, count = random.rand(sheet.row_count), random.rand(1..3)
        sheet = sheet.delete_rows(at, count)
        cells = cells.each_with_object({}) do |((row, column), value), result|
          result[[row >= at + count ? row - count : row, column]] = value unless row >= at && row < at + count
        end
      when 4
        at, count = random.rand(sheet.column_count + 1), random.rand(1..3)
        sheet = sheet.insert_columns(at, count)
        cells = cells.each_with_object({}) { |((row, column), value), result| result[[row, column >= at ? column + count : column]] = value }
      when 5
        next if sheet.column_count.zero?
        at, count = random.rand(sheet.column_count), random.rand(1..3)
        sheet = sheet.delete_columns(at, count)
        cells = cells.each_with_object({}) do |((row, column), value), result|
          result[[row, column >= at + count ? column - count : column]] = value unless column >= at && column < at + count
        end
      end

      expected = cells.sort.map { |(row, column), value| [Denebola::Point.new(row, column), value] }
      actual = sheet.each_in(0, 0, [sheet.row_count - 1, 0].max, [sheet.column_count - 1, 0].max).to_a
      assert_equal expected, actual, "step=#{step}"
      cells.each { |(row, column), value| assert_equal value, sheet[row, column], "step=#{step} cell=#{row},#{column}" }
      top = random.rand(sheet.row_count + 1)
      bottom = random.rand(top..[sheet.row_count, top].max)
      left = random.rand(sheet.column_count + 1)
      right = random.rand(left..[sheet.column_count, left].max)
      selected = cells.filter_map do |(row, column), value|
        value if row >= top && row <= bottom && column >= left && column <= right
      end
      selected_numbers = selected.grep(Numeric)
      summary = sheet.summary(top, left, bottom, right)
      assert_equal selected.length, summary.count, "step=#{step} summary count"
      assert_equal selected_numbers.sum, summary.sum, "step=#{step} summary sum"
      selected_numbers.empty? ? assert_nil(summary.min) : assert_equal(selected_numbers.min, summary.min, "step=#{step} summary min")
      selected_numbers.empty? ? assert_nil(summary.max) : assert_equal(selected_numbers.max, summary.max, "step=#{step} summary max")
      sheet.check_invariants!
    end
  end

  def test_range_summaries_match_enumerated_values
    sheet = Denebola::Sheet.new
    20.times { |row| 20.times { |column| sheet = sheet.set(row, column, row * column) if (row + column) % 4 == 0 } }

    100.times do |seed|
      random = Random.new(seed)
      top, bottom = random.rand(20), random.rand(20)
      left, right = random.rand(20), random.rand(20)
      top, bottom = [top, bottom].minmax
      left, right = [left, right].minmax
      values = sheet.each_in(top, left, bottom, right).map { |_, value| value }
      summary = sheet.summary(top, left, bottom, right)

      assert_equal values.length, summary.count
      assert_equal values.sum, summary.sum
      values.empty? ? assert_nil(summary.min) : assert_equal(values.min, summary.min)
      values.empty? ? assert_nil(summary.max) : assert_equal(values.max, summary.max)
    end
  end

  def test_partial_rectangle_summary_uses_cached_2d_ranges_without_enumerating_trees
    cells = 600.times.flat_map do |row|
      [[row * 2, 1, row], [row * 2, 7, row.even? ? "label" : row * 3]]
    end
    sheet = Denebola::Sheet.new.set_many(cells)
    top, bottom, left, right = 120, 980, 7, 7
    expected_values = cells.filter_map do |row, column, value|
      value if row.between?(top, bottom) && column.between?(left, right)
    end
    numeric = expected_values.grep(Numeric)
    expected = Denebola::Sheet::Summary.new(count: expected_values.length, sum: numeric.sum,
      min: numeric.min, max: numeric.max, types: expected_values.group_by(&:class).transform_values(&:length))
    original_each = Denebola::Tree.instance_method(:each)
    Denebola::Tree.send(:remove_method, :each)
    Denebola::Tree.define_method(:each) { |*| raise "partial summary enumerated a tree" }

    assert_equal expected, sheet.summary(top, left, bottom, right)
  ensure
    if original_each
      Denebola::Tree.send(:remove_method, :each)
      Denebola::Tree.define_method(:each, original_each)
    end
  end

  def test_partial_summaries_track_replacements_deletions_and_old_snapshots
    original = Denebola::Sheet.new.set_many([
      [0, 0, 0], [1, 0, -5], [100, 7, 10], [1_000_000, 16_383, "far"]
    ])
    changed = original.set(1, 0, 10.0).delete(100, 7)

    assert_equal Denebola::Sheet::Summary.new(count: 3, sum: 5, min: -5, max: 10,
      types: { Integer => 3 }), original.summary(0, 0, 1_000_000, 7)
    assert_equal Denebola::Sheet::Summary.new(count: 2, sum: 10.0, min: 0, max: 10.0,
      types: { Integer => 1, Float => 1 }), changed.summary(0, 0, 1_000_000, 7)
    assert_equal Denebola::Sheet::Summary.new(count: 1, sum: 0, types: { String => 1 }),
      changed.summary(1_000_000, 16_383, 2_000_000, 16_383)
    assert_equal Denebola::Sheet::Summary.zero, changed.summary(2_000_000, 0, 3_000_000, 16_383)
    changed.check_invariants!
  end
end
