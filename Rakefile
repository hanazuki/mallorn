require 'rspec/core/rake_task'
require 'rubygems/package_task'

RSpec::Core::RakeTask.new(:spec)

Gem::PackageTask.new(Gem::Specification.load('mallorn.gemspec')).define

desc 'Build the gem into pkg/'
task build: :gem

task default: :spec
