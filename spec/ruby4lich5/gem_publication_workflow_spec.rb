# frozen_string_literal: true

require 'yaml'

RSpec.describe 'Gem publication job preparation' do
  it 'checks out source before Ruby setup and artifact downloads, without persisting credentials' do
    workflow = YAML.load_file(File.expand_path('../../.github/workflows/ruby4-bundled-gems-suite.yml', __dir__))
    steps = workflow.fetch('jobs').fetch('publish_ruby4_bundled_gems_suite').fetch('steps')
    checkout = steps.index { |step| step['uses'].to_s.start_with?('actions/checkout@') }

    expect(checkout).not_to be_nil
    expect(steps[checkout].fetch('with').fetch('persist-credentials')).to be(false)
    consumers = steps.each_index.select do |index|
      steps[index]['uses'].to_s.match?(%r{\A(?:ruby/setup-ruby|actions/download-artifact)@})
    end
    expect(consumers).not_to be_empty
    expect(consumers).to all(be > checkout)
  end
end
