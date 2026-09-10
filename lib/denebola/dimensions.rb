# frozen_string_literal: true

module Denebola
  module Dimensions
    BYTES = ->(summary) { summary.bytesize }
    CHARACTERS = ->(summary) { summary.length }
    UTF16 = ->(summary) { summary.utf16_length }
    LINE_BREAKS = ->(summary) { summary.break_count }
  end
end
