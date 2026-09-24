# frozen_string_literal: true

require "denebola/code_editor_buffer"
require "zaniah/ui"
require_relative "test_helper"

class CodeEditorBufferTest < Minitest::Test
  def test_line_interface_uses_rope_byte_offsets
    buffer = Denebola::CodeEditorBuffer.new(Denebola::Rope.new("😀 hi\r\n日本\n"))
    assert_equal 3, buffer.line_count
    assert_equal ["😀 hi", "日本", ""], (0...3).map { |index| buffer.line(index) }
    assert_equal [0, 9, 16], (0...3).map { |index| buffer.line_start(index) }
    assert_equal [0, 1, 2], [0, 9, 16].map { |offset| buffer.line_of(offset) }
    assert_equal 0, buffer.line_of(8), "the CR/LF gap belongs to the preceding editor line"
    assert_equal "😀 hi\r\n日本\n", buffer.to_s
  end

  def test_replace_undo_redo_preserves_immutable_snapshots
    original = Denebola::Rope.new("one\ntwo")
    buffer = Denebola::CodeEditorBuffer.new(original)
    refute buffer.can_undo?
    refute buffer.can_redo?

    assert_same buffer, buffer.replace(0...3, "first")
    assert_equal "first\ntwo", buffer.to_s
    assert_equal "one\ntwo", original.to_s
    assert buffer.can_undo?
    assert_same buffer, buffer.undo
    assert_equal "one\ntwo", buffer.to_s
    assert buffer.can_redo?
    assert_same buffer, buffer.redo
    assert_equal "first\ntwo", buffer.to_s

    buffer.undo
    buffer.replace(4...7, "three")
    refute buffer.can_redo?
    assert_equal "one\nthree", buffer.to_s
    assert_same buffer, buffer.redo
    assert_equal "one\nthree", buffer.to_s
  end

  def test_invalid_edit_does_not_change_history
    buffer = Denebola::CodeEditorBuffer.new(Denebola::Rope.new("é"))
    assert_raises(RangeError) { buffer.replace(1...1, "x") }
    assert_equal "é", buffer.to_s
    refute buffer.can_undo?
    assert_raises(ArgumentError) { Denebola::CodeEditorBuffer.new("not a rope") }
  end

  def test_zaniah_code_editor_integration
    editor = Zaniah::UI::CodeEditor.new(buffer: Denebola::CodeEditorBuffer.new(Denebola::Rope.new("abc\ndef")))
    assert_equal "abc\ndef", editor.value
    editor.replace(1...2, "😀")
    assert_equal "a😀c\ndef", editor.value
    assert_equal "a😀c", editor.buffer.line(0)
    editor.text_action(:undo)
    assert_equal "abc\ndef", editor.value
    editor.text_action(:redo)
    assert_equal "a😀c\ndef", editor.value
  end
end
