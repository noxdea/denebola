# frozen_string_literal: true

require "objspace"
require "tempfile"
require "denebola"

def elapsed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

line = ("x" * 63) + "\n"
line_count = 262_144

Tempfile.create("denebola-lazy-bench") do |file|
  file.binmode
  256.times { file.write(line * 1024) }
  file.flush

  GC.start
  memory_before = ObjectSpace.memsize_of_all
  rope = nil
  open_ms = elapsed { rope = Denebola::LazyRope.open(file.path, chunk_size: 65_536, cache_chunks: 4) } * 1000
  open_memory_mb = (ObjectSpace.memsize_of_all - memory_before) / 1024.0**2
  index_ms = elapsed { rope.line_count(exact: true) } * 1000
  rows = [0, line_count / 3, line_count / 2, line_count - 1]
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  1_000.times { |index| rope.line(rows[index % rows.length]) }
  line_us = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000

  results = {
    open_ms: open_ms,
    open_memory_mb: open_memory_mb,
    cached_mb: rope.cached_bytes / 1024.0**2,
    index_ms: index_ms,
    line_us: line_us
  }
  puts "LazyRope / #{file.size} bytes:"
  results.each { |name, value| puts "#{name}=#{format('%.3f', value)}" }

  if ARGV.include?("--assert")
    limits = {open_ms: 100, open_memory_mb: 2, cached_mb: 0.3, index_ms: 4_000, line_us: 100}
    failures = limits.filter_map { |name, limit| "#{name}: #{results[name]} > #{limit}" if results[name] > limit }
    abort failures.join("\n") unless failures.empty?
  end
ensure
  rope&.close
end
