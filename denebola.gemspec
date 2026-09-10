# frozen_string_literal: true

require_relative "lib/denebola/version"

Gem::Specification.new do |spec|
  spec.name = "denebola"
  spec.version = Denebola::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Persistent summary B+ trees and Unicode text ropes in pure Ruby"
  spec.description = "Immutable, structurally shared trees with summary dimensions, UTF-8 text editing, line and UTF-16 indexing, and anchors."
  spec.homepage = "https://github.com/noxdea/denebola"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]
end
