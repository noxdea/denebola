# frozen_string_literal: true

require "test_helper"
require "rbconfig"

class RopeTest < Minitest::Test
  def test_public_api_and_persistence
    rope = Denebola::Rope.new("hello\nworld", chunk_size: 4)
    assert_equal 11, rope.bytesize
    assert_equal 2, rope.line_count
    assert_equal "world", rope.line(1)
    assert_equal "hello", rope.byteslice(0, 5).to_s
    assert_equal "hello, there\nworld", rope.insert(5, ", there").to_s
    assert_equal "\nworld", rope.delete(0..4).to_s
    assert_equal "Xlo\nwoYd", rope.apply_edits([[0..2, "X"], [8..9, "Y"]]).to_s
    assert_equal Denebola::Point.new(1, 1), rope.point_at(7)
    assert_equal 7, rope.offset_at(Denebola::Point.new(row: 1, column: 1))
    assert_equal "hello\nworld", rope.to_s
    rope.check_invariants!
  end

  def test_all_line_breaks_across_chunk_and_edit_boundaries
    text = "a\r\nb\rc\nd\u2028e\u2029"
    rope = Denebola::Rope.new(text, chunk_size: 4)
    assert_equal ["a", "b", "c", "d", "e", ""], Array.new(rope.line_count) { |row| rope.line(row) }
    6.times do |row|
      offset = rope.line_start(row)
      assert_equal Denebola::Point.new(row, 0), rope.point_at(offset)
      assert_equal offset, rope.offset_at(Denebola::Point.new(row, 0))
    end
    split_crlf = Denebola::Rope.new("abc\r", chunk_size: 4).insert(4, "\nxyz")
    assert_equal 2, split_crlf.line_count
    assert_equal "xyz", split_crlf.line(1)
    assert_equal 5, split_crlf.line_start(1)
    assert_equal "abc\nxyz", split_crlf.delete(3...4).to_s
    split_crlf.check_invariants!
  end

  def test_unicode_bytes_points_utf16_and_grapheme_chunks
    text = "é👩‍💻e\u0301\r\n日本😀"
    rope = Denebola::Rope.new(text, chunk_size: 4)
    assert_equal text.scan(/\X/), rope.each_chunk.to_a.flat_map { |chunk| chunk.scan(/\X/) }
    offset = units = 0
    text.each_codepoint do |codepoint|
      assert_equal units, rope.utf16_offset_at(offset)
      assert_equal offset, rope.offset_at_utf16(units)
      assert_raises(RangeError) { rope.offset_at_utf16(units + 1) } if codepoint > 0xffff
      offset += codepoint.chr(Encoding::UTF_8).bytesize
      units += codepoint > 0xffff ? 2 : 1
    end
    assert_equal offset, rope.offset_at_utf16(units)
    assert_equal Denebola::Point.new(1, 2), rope.point_at(rope.bytesize - 4)
    assert_equal Denebola::Point.new(1, 4), rope.utf16_point_at(rope.bytesize)
    assert_equal rope.bytesize, rope.offset_at_utf16_point(Denebola::Point.new(1, 4))
  end

  def test_invalid_boundaries_and_ranges
    rope = Denebola::Rope.new("a😀b")
    assert_raises(RangeError) { rope.insert(2, "x") }
    assert_raises(RangeError) { rope.delete(1...3) }
    assert_raises(RangeError) { rope.byteslice(-1, 2) }
    assert_raises(RangeError) { rope.line(1) }
    assert_raises(RangeError) { rope.offset_at(Denebola::Point.new(0, 4)) }
    assert_raises(ArgumentError) { Denebola::Rope.new("\xff".b.force_encoding("UTF-8")) }
    assert_raises(ArgumentError) { rope.apply_edits([[0...3, "x"], [2...5, "y"]]) }
  end

  def test_anchors_across_insertions_deletions_and_batch_edits
    rope = Denebola::Rope.new("abcdef")
    assert_equal 2, rope.anchor(2, bias: :left).transform([[2...2, "XYZ"]]).offset
    assert_equal 5, rope.anchor(2).transform([[2...2, "XYZ"]]).offset
    assert_equal 1, rope.anchor(3, bias: :left).transform([[1...5, "X"]]).offset
    assert_equal 2, rope.anchor(3).transform([[1...5, "X"]]).offset
    assert_equal 7, rope.anchor(6).transform([[0...1, "XY"], [3...4, "Z"]]).offset
  end

  def test_batch_edit_order_and_anchor_bias_share_a_contract
    rope = Denebola::Rope.new("abcd")
    edits = [[2...2, "X"], [2...2, "Y"], [2...3, "R"]]

    assert_equal "abXYRd", rope.apply_edits(edits).to_s
    assert_equal 2, rope.anchor(2, bias: :left).transform(edits).offset
    assert_equal 5, rope.anchor(2, bias: :right).transform(edits).offset

    reversed_insertions = [[2...2, "Y"], [2...2, "X"], [2...3, "R"]]
    assert_equal "abYXRd", rope.apply_edits(reversed_insertions).to_s
    assert_equal 5, rope.anchor(2).transform(reversed_insertions).offset
  end

  def test_insert_and_replacement_at_the_same_offset_are_order_independent
    rope = Denebola::Rope.new("abcd")
    insertion = [1...1, "XY"]
    deletion = [1...3, ""]
    replacement = [1...3, "Q"]

    [[insertion, deletion], [deletion, insertion]].each do |edits|
      assert_equal "aXYd", rope.apply_edits(edits).to_s
      assert_equal 1, rope.anchor(1, bias: :left).transform(edits).offset
      assert_equal 3, rope.anchor(1, bias: :right).transform(edits).offset
    end

    [[insertion, replacement], [replacement, insertion]].each do |edits|
      assert_equal "aXYQd", rope.apply_edits(edits).to_s
      assert_equal 3, rope.anchor(2, bias: :left).transform(edits).offset
      assert_equal 4, rope.anchor(2, bias: :right).transform(edits).offset
    end
  end

  def test_batch_edit_order_uses_utf8_byte_offsets_and_round_trips_inverse_edits
    rope = Denebola::Rope.new("a😀b")
    edits = [[1...1, "é"], [1...1, "界"], [1...5, "🙂"]]
    assert_equal "aé界🙂b", rope.apply_edits(edits).to_s
    assert_equal 1, rope.anchor(1, bias: :left).transform(edits).offset
    assert_equal 10, rope.anchor(1, bias: :right).transform(edits).offset

    insertion = [[1...1, "日本"]]
    inverse = [[1...7, ""]]
    changed = rope.apply_edits(insertion)
    assert_equal rope.to_s, changed.apply_edits(inverse).to_s
    %i[left right].each do |bias|
      anchor = rope.anchor(1, bias: bias).transform(insertion).transform(inverse)
      assert_equal 1, anchor.offset
    end
  end

  def test_exact_equal_nonempty_ranges_remain_overlapping
    rope = Denebola::Rope.new("abcd")
    edits = [[1...3, "X"], [1...3, "Y"]]
    assert_raises(ArgumentError) { rope.apply_edits(edits) }
    assert_raises(ArgumentError) { rope.anchor(1).transform(edits) }
    assert_raises(ArgumentError) { rope.anchor(0).transform([[1...3, "X"], [2...4, "Y"]]) }

    assert_equal rope.apply_edits([[1...3, "X"]]).to_s, rope.apply_edits([[1..2, "X"]]).to_s
    %i[left right].each do |bias|
      exclusive = rope.anchor(2, bias: bias).transform([[1...3, "X"]]).offset
      assert_equal exclusive, rope.anchor(2, bias: bias).transform([[1..2, "X"]]).offset
    end
  end

  def test_anchor_normalizes_edit_text_like_rope
    rope = Denebola::Rope.new("abcd")
    utf16 = "A".encode(Encoding::UTF_16LE)
    windows = "あ".encode(Encoding::Windows_31J)

    assert_equal "aAbcd", rope.apply_edits([[1...1, utf16]]).to_s
    assert_equal 2, rope.anchor(1).transform([[1...1, utf16]]).offset
    assert_equal 3, rope.anchor(4).transform([[1...3, utf16]]).offset

    assert_equal "aあbcd", rope.apply_edits([[1...1, windows]]).to_s
    assert_equal 4, rope.anchor(1).transform([[1...1, windows]]).offset
    assert_equal 7, rope.anchor(4).transform([[1...1, windows]]).offset

    invalid = "\xff".b.force_encoding(Encoding::UTF_8)
    rope_error = assert_raises(ArgumentError) { rope.apply_edits([[1...1, invalid]]) }
    anchor_error = assert_raises(ArgumentError) { rope.anchor(1).transform([[1...1, invalid]]) }
    assert_equal rope_error.message, anchor_error.message

    rope_error = assert_raises(TypeError) { rope.apply_edits([[1...1, Object.new]]) }
    anchor_error = assert_raises(TypeError) { rope.anchor(1).transform([[1...1, Object.new]]) }
    assert_equal rope_error.message, anchor_error.message
  end

  def test_internal_edit_helpers_load_with_public_subfiles
    code = 'raise unless Denebola.const_defined?(:Edit, false)'
    assert system(RbConfig.ruby, "-Ilib", "-e", "require 'denebola/rope'; #{code}")
    assert system(RbConfig.ruby, "-Ilib", "-e",
                  "require 'denebola/anchor'; #{code}; raise unless Denebola::Anchor.new(1).transform([[1...1, 'A']]).offset == 2")
  end

  def test_empty_rope
    rope = Denebola::Rope.new
    assert_equal "", rope.line(0)
    assert_equal "x", rope.insert(0, "x").to_s
    assert_equal "", rope.byteslice(0, 0).to_s
    assert_equal Denebola::Point.new(0, 0), rope.point_at(0)
  end

  def test_grapheme_clusters_are_preserved_at_edited_chunk_boundaries
    source = Denebola::Rope.new("abcde12345678", chunk_size: 4)
    [source.insert(4, "\u0301"), source.apply_edits([[4...4, "\u0301"], [10...10, "é"]])].each do |rope|
      assert_equal rope.to_s.scan(/\X/), rope.each_chunk.flat_map { |chunk| chunk.scan(/\X/) }
      rope.check_invariants!
    end
  end
end
