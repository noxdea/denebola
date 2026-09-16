# frozen_string_literal: true

module Denebola
  module Edit
    def self.sort(edits)
      edits.each_with_index.sort_by { |edit, index| [edit[0], edit[1], index] }.map!(&:first)
    end

    def self.normalize_text(text)
      raise TypeError, "text must be a String" unless text.is_a?(String)
      string = text.encoding == Encoding::UTF_8 ? text : text.encode(Encoding::UTF_8)
      raise ArgumentError, "text must be valid UTF-8" unless string.valid_encoding?
      string
    end
  end
  private_constant :Edit
end
