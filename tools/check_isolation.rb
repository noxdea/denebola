# frozen_string_literal: true

spec = Gem::Specification.load(File.expand_path("../denebola.gemspec", __dir__))
abort "runtime dependency found" unless spec.runtime_dependencies.empty?
Dir[File.expand_path("../lib/**/*.rb", __dir__)].each do |file|
  abort "application dependency in #{file}" if File.read(file).match?(/\b(?:Zaniah|Tessera|Canopus|Quire)\b/)
end
puts "Isolated pure Ruby runtime: OK"
