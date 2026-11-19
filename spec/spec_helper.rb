system('bundle', 'exec', 'rake', 'tree-sitter', chdir: File.expand_path('..', __dir__), exception: true)

require 'mallorn'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
