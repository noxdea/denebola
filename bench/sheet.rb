# frozen_string_literal: true

require_relative "../lib/denebola"

def elapsed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

cells = Integer(ENV.fetch("SHEET_CELLS", "100000"))
raise "SHEET_CELLS must be positive" unless cells.positive?
columns_per_row = 1_000

def cell_updates(count, columns_per_row)
  Enumerator.new do |output|
    count.times { |index| output << [index / columns_per_row, index % columns_per_row, index % 10] }
  end
end

sheet = Denebola::Sheet.new
single_write_seconds = elapsed do
  cell_updates(cells, columns_per_row).each do |row, column, value|
    sheet = sheet.set(row, column, value)
  end
end
bulk_sheet = Denebola::Sheet.new
bulk_write_seconds = elapsed do
  bulk_sheet = bulk_sheet.set_many(cell_updates(cells, columns_per_row))
end

snapshot_seconds = elapsed { 1_000.times { sheet.snapshot } } / 1_000
full_summary_seconds = elapsed do
  sheet.summary(0, 0, sheet.row_count - 1, sheet.column_count - 1)
end
partial_summary_seconds = elapsed do
  sheet.summary(0, 0, sheet.row_count - 1, 0)
end

puts "cells=#{sheet.cell_count} set=#{format('%.3f', single_write_seconds)}s set_many=#{format('%.3f', bulk_write_seconds)}s snapshot=#{format('%.3f', snapshot_seconds * 1_000_000)}µs"
puts "full_rows_summary=#{format('%.3f', full_summary_seconds * 1_000_000)}µs partial_column_summary=#{format('%.3f', partial_summary_seconds * 1_000_000)}µs"

if ARGV.include?("--assert")
  abort "bulk result differs" unless bulk_sheet.cell_count == sheet.cell_count && bulk_sheet.summary(0, 0, sheet.row_count - 1, sheet.column_count - 1) == sheet.summary(0, 0, sheet.row_count - 1, sheet.column_count - 1)
  abort "snapshot exceeded 1 ms" unless snapshot_seconds < 0.001
  abort "incorrect full-range summary" unless sheet.summary(0, 0, sheet.row_count - 1, sheet.column_count - 1).count == cells
end
