# frozen_string_literal: true

require_relative "../lib/denebola"

def elapsed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
end

sizes = ENV.fetch("SHEET_RANGE_ROWS", "1000,5000,20000").split(",").map { |size| Integer(size) }
queries = Integer(ENV.fetch("SHEET_RANGE_QUERIES", "500"))
raise "row sizes and query count must be positive" unless sizes.all?(&:positive?) && queries.positive?

puts RUBY_DESCRIPTION
sizes.each do |rows|
  edits = Enumerator.new do |output|
    rows.times do |row|
      output << [row * 3, 7, row]
      output << [row * 3, 100_003, "outside"]
    end
  end
  sheet, build_seconds = elapsed { Denebola::Sheet.new.set_many(edits) }
  expected = Denebola::Sheet::Summary.new(count: rows, sum: rows * (rows - 1) / 2,
    min: 0, max: rows - 1, types: { Integer => rows })
  summary = nil
  _, query_seconds = elapsed do
    queries.times { summary = sheet.summary(0, 7, rows * 3, 7) }
  end
  raise "incorrect partial-column summary for #{rows} rows" unless summary == expected

  puts "rows=#{rows} cells=#{sheet.cell_count} build=#{format('%.3f', build_seconds)}s " \
    "partial_column_query=#{format('%.2f', query_seconds * 1_000_000 / queries)}µs " \
    "queries=#{queries}"
end
