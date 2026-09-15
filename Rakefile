# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) { |task| task.libs << "test"; task.pattern = "test/test_*.rb" }

task default: :test

namespace :test do
  task(:oracle) { ruby "-Ilib:test", "test/test_property.rb" }
end

task(:bench) do
  ruby "--yjit", "-Ilib", "bench/rope.rb"
  ruby "--yjit", "-Ilib", "bench/lazy_rope.rb"
end
namespace :bench do
  task(:assert) do
    ruby "--yjit", "-Ilib", "bench/rope.rb", "--assert"
    ruby "--yjit", "-Ilib", "bench/lazy_rope.rb", "--assert"
  end
end
