# frozen_string_literal: true

require "objspace"
require "denebola"

def elapsed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

def median_us(repetitions = 1000)
  100.times { yield }
  Array.new(5) { elapsed { repetitions.times { yield } } * 1_000_000 / repetitions }.sort[2]
end

puts RUBY_DESCRIPTION
puts "fanout,chunk_bytes,insert_us,line_us"
text = "abcdefghij\n" * 100_000
[8, 16, 32, 64].each do |branching|
  [256, 512, 1024, 2048].each do |chunk_size|
    rope = Denebola::Rope.new(text, branching: branching, chunk_size: chunk_size)
    insert = median_us(300) { rope.insert(555_555, "x") }
    line = median_us(300) { rope.line(55_555) }
    puts "%d,%d,%.3f,%.3f" % [branching, chunk_size, insert, line]
  end
end

rope = text = nil
GC.start
before = ObjectSpace.memsize_of_all
source = "abcdefghij\n" * 1_000_000
rope = nil
build_ms = elapsed { rope = Denebola::Rope.new(source) } * 1000
source = nil
GC.start
memory_mb = (ObjectSpace.memsize_of_all - before) / 1024.0**2
results = {
  build_ms: build_ms,
  insert_us: median_us { rope.insert(5_555_555, "x") },
  line_us: median_us { rope.line(555_555) },
  point_us: median_us { rope.point_at(5_555_555) },
  offset_us: median_us { rope.offset_at(Denebola::Point.new(555_555, 5)) },
  slice_us: median_us { rope.byteslice(5_555_555, 1024) },
  memory_mb: memory_mb
}
puts "1,000,000 lines / 11,000,000 bytes, defaults:"
results.each { |name, value| puts "#{name}=#{format('%.3f', value)}" }

if ARGV.include?("--assert")
  # Shared CI hardware has a wider regression budget than the documented local targets.
  limits = {build_ms: 2400, insert_us: 150, line_us: 15, point_us: 30, offset_us: 30, slice_us: 60, memory_mb: 40}
  failures = limits.filter_map { |name, limit| "#{name}: #{results[name]} > #{limit}" if results[name] > limit }
  abort failures.join("\n") unless failures.empty?
end
