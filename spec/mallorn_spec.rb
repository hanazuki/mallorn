RSpec.describe Mallorn do
  it 'exposes a valid gem version' do
    expect(Gem::Version.new(described_class::VERSION).to_s).to eq(described_class::VERSION)
  end
end
