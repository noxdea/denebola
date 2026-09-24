# frozen_string_literal: true

spec = Gem::Specification.load(File.expand_path("../denebola.gemspec", __dir__))
abort "runtime dependency found" unless spec.runtime_dependencies.empty?
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "denebola"
require "denebola/code_editor_buffer"
forbidden = %w[zaniah tessera canopus quire]
abort "application dependency loaded" if $LOADED_FEATURES.any? do |path|
  forbidden.any? { |name| path.match?(%r{/(?:#{name})(?:/|\.rb\z)}) }
end
puts "Isolated pure Ruby runtime: OK"
