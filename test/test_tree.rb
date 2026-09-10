# frozen_string_literal: true

require "test_helper"

class TreeTest < Minitest::Test
  Sum = Struct.new(:value) do
    def self.zero = new(0).freeze
    def +(other) = self.class.new(value + other.value).freeze
  end
  Item = Struct.new(:value) do
    def summary = Sum.new(value).freeze
  end

  def tree(values, branching: 4)
    Denebola::Tree.new(values.map { |value| Item.new(value).freeze }, summary: Sum, branching: branching)
  end

  def test_bulk_build_split_append_and_invariants
    [4, 8, 16, 32, 64].each do |branching|
      source = tree((1..257).to_a, branching: branching)
      source.check_invariants!
      258.times do |index|
        left, right = source.split_at(index)
        assert_equal (1..index).to_a, left.map(&:value)
        assert_equal ((index + 1)..257).to_a, right.map(&:value)
        joined = left.append(right)
        [left, right, joined].each(&:check_invariants!)
        assert_equal source.to_a, joined.to_a
      end
    end
  end

  def test_cursor_dimensions_bias_and_movement
    source = tree([2, 3, 5, 7])
    cursor = source.cursor(:value).seek(5)
    assert_equal 5, cursor.item.value
    assert_equal 5, cursor.summary.value
    assert_equal 7, cursor.next.value
    assert_equal 5, cursor.prev.value
    assert_equal 3, cursor.seek(5, bias: :left).item.value
    assert_equal [3, 5], cursor.read_until(10).map(&:value)
    assert_equal 7, cursor.item.value
    dimension = Class.new { def self.from_summary(summary) = summary.value }
    assert_equal 3, source.cursor(dimension).seek(2).item.value
  end

  def test_push_shares_untouched_branches
    source = tree((1..1000).to_a, branching: 8)
    changed = source.push(Item.new(1001).freeze)
    assert_same source.send(:root).entries.first, changed.send(:root).entries.first
    assert_equal 1000, source.size
    assert_equal 1001, changed.size
    assert_equal 1000 * 1001 / 2, source.summary.value
    changed.check_invariants!
  end

  def test_random_tree_operations
    random = Random.new(732)
    expected = []
    actual = tree(expected)
    2000.times do
      case random.rand(3)
      when 0
        value = random.rand(100)
        actual = actual.push(Item.new(value).freeze)
        expected << value
      when 1
        index = random.rand(expected.length + 1)
        values = Array.new(random.rand(20)) { random.rand(100) }
        actual = actual.replace_at(index, values.map { |value| Item.new(value).freeze })
        expected[index, index == expected.length ? 0 : 1] = values
      when 2
        start = random.rand(expected.length + 1)
        length = random.rand(expected.length - start + 1)
        actual = actual.slice(start, length)
        expected = expected.slice(start, length)
      end
      assert_equal expected, actual.map(&:value)
      actual.check_invariants!
    end
  end
end
