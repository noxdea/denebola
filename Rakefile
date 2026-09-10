# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) { |task| task.libs << "test"; task.pattern = "test/test_*.rb" }

task default: :test

namespace :test do
  task(:oracle) { ruby "-Ilib:test", "test/test_property.rb" }
end

task(:bench) { ruby "--yjit", "-Ilib", "bench/rope.rb" }
namespace :bench do
  task(:assert) { ruby "--yjit", "-Ilib", "bench/rope.rb", "--assert" }
end
