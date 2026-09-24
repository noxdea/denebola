# frozen_string_literal: true

require_relative "../denebola"

module Denebola
  # Adapts a persistent Rope to Zaniah::UI::CodeEditor's buffer interface.
  # Zaniah is not required by Denebola; pass an instance as `buffer:`.
  class CodeEditorBuffer
    attr_reader :rope

    def initialize(rope = Rope.new)
      raise ArgumentError, "expected a Denebola::Rope" unless rope.is_a?(Rope)
      @rope = rope
      @undo = []
      @redo = []
    end

    def line_count = @rope.line_count
    def line(index) = @rope.line(index)
    def line_start(index) = @rope.line_start(index)
    def line_of(offset)
      row = @rope.point_at(offset).row
      row.positive? && @rope.line_start(row) > offset ? row - 1 : row
    end
    def to_s = @rope.to_s

    def replace(range, text)
      updated = @rope.replace(range, text)
      @undo << @rope
      @redo.clear
      @rope = updated
      self
    end

    def undo
      return self unless can_undo?
      @redo << @rope
      @rope = @undo.pop
      self
    end

    def redo
      return self unless can_redo?
      @undo << @rope
      @rope = @redo.pop
      self
    end

    def can_undo? = !@undo.empty?
    def can_redo? = !@redo.empty?
  end
end
