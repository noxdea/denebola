# frozen_string_literal: true

require "test_helper"
require "objspace"

class PropertyTest < Minitest::Test
  ALPHABET = ["a", "bc", "日本", "😀", "e\u0301", "\r", "\n", "\r\n", "\u2028", "\u2029", "👩‍💻"].freeze

  def test_one_hundred_thousand_random_edits_against_string
    random = Random.new(54_821)
    expected = ""
    rope = Denebola::Rope.new(expected, chunk_size: 32, branching: 8)
    snapshots = []
    Integer(ENV.fetch("DENEBOLA_ORACLE_EDITS", "100000")).times do |iteration|
      offsets = [0]
      expected.each_char { |char| offsets << offsets.last + char.bytesize }
      start_index = random.rand(offsets.length)
      end_index = [start_index + random.rand(9), offsets.length - 1].min
      start, finish = offsets.values_at(start_index, end_index)
      text = Array.new(random.rand(expected.bytesize > 4096 ? 2 : 6)) { ALPHABET.sample(random: random) }.join
      if iteration % 37 == 0 && start.positive?
        edits = [[0...offsets[1], "X"], [start...finish, text]]
        rope = rope.apply_edits(edits)
        expected = "X" + expected.byteslice(offsets[1], start - offsets[1]) + text + expected.byteslice(finish..)
      else
        rope = rope.replace(start...finish, text)
        expected = expected.byteslice(0, start) + text + expected.byteslice(finish..)
      end
      assert_equal expected, rope.to_s, "edit #{iteration}"
      if iteration % 100 == 0
        rope.check_invariants!
        lines = expected.split(/\r\n|[\r\n\u2028\u2029]/, -1)
        lines = [""] if expected.empty?
        assert_equal lines.length, rope.line_count
        lines.each_with_index { |line, row| assert_equal line, rope.line(row), "line #{row} after edit #{iteration}" }
      end
      snapshots << [rope, expected.dup] if iteration % 1000 == 0
    end
    snapshots.each { |snapshot, text| assert_equal text, snapshot.to_s }
  end

  def test_text_summary_monoid_laws_and_string_oracle
    random = Random.new(983)
    5000.times do
      strings = Array.new(3) { Array.new(random.rand(8)) { ALPHABET.sample(random: random) }.join }
      a, b, c = strings.map { |text| Denebola::TextSummary.from_text(text) }
      assert_equal (a + b) + c, a + (b + c)
      assert_equal Denebola::TextSummary.from_text(strings.join), a + b + c
      assert_equal a, a + Denebola::TextSummary.zero
      assert_equal a, Denebola::TextSummary.zero + a
    end
  end

  def test_memory_is_bounded_when_old_snapshots_are_released
    rope = Denebola::Rope.new("abcdefghij\n" * 10_000)
    random = Random.new(184)
    retained = []
    [1000, 9000].each do |count|
      count.times do
        offset = random.rand(rope.bytesize)
        rope = rope.replace(offset...(offset + 1), "x")
      end
      GC.start
      retained << ObjectSpace.each_object(Denebola::Tree::Node).count
    end
    assert_operator retained.last, :<=, retained.first + 10
    assert_equal 110_000, rope.bytesize
    rope.check_invariants!
  end
end
