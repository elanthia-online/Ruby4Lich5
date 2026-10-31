# frozen_string_literal: true

require 'tmpdir'
require 'ruby4lich5/published_startup_releases'

RSpec.describe 'Published client revalidation before promotion' do
  let(:cli) { File.expand_path('../../bin/check_published_clients.rb', __dir__) }
  let(:inventory) { { 'schema' => 1, 'repository' => 'elanthia-online/lich-5', 'complete' => true, 'release_ids' => [], 'clients' => [] } }

  around do |example|
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'context.json')
      File.write(path, JSON.generate('supported_startup_policy' => { 'published_releases' => inventory }))
      @context_path = path
      example.run
    end
  end

  before { stub_const('ARGV', [@context_path]) }

  it 'permits the same fully captured inventory' do
    allow(Ruby4Lich5::PublishedStartupReleases).to receive(:capture).and_return(inventory)
    expect { load cli }.not_to raise_error
  end

  it 'stops admission if a release appears or acquisition becomes unavailable after approval' do
    allow(Ruby4Lich5::PublishedStartupReleases).to receive(:capture).and_return(inventory.merge('release_ids' => [1]))
    expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }.and output(/published clients changed/).to_stderr
    allow(Ruby4Lich5::PublishedStartupReleases).to receive(:capture).and_raise(ArgumentError, 'API unavailable')
    expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }.and output(/API unavailable/).to_stderr
  end
end
