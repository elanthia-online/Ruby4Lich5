# frozen_string_literal: true

require 'ruby4lich5/smoke_contract'
require 'ruby4lich5/classification'

RSpec.describe Ruby4Lich5::SmokeContract do
  def lock_for(names)
    versions = names.to_h { |name| [name, '1.0.0'] }
    Ruby4Lich5::ResolutionLock.new(
      ruby_installer_version: '4.0.9-1', platform: 'x64-mingw-ucrt', requested_roots: versions,
      closure: names.map do |name|
        { name: name, version: '1.0.0', runtime_dependencies: [], classification: Ruby4Lich5::Classification.new(
          state: :pure, gem_name: name, gem_version: '1.0.0', reason: 'fixture', platform_asset: nil, msys2_packages: nil
        ) }
      end,
      registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}"
    )
  end

  it 'covers every selected root, including previously omitted concurrent-ruby and tzinfo-data' do
    result = described_class.for_lock(lock_for(%w[concurrent-ruby tzinfo-data sqlite3]))
    expect(result.fetch('roots').map { |root| root['name'] }).to eq(%w[concurrent-ruby tzinfo-data sqlite3])
    expect(result.fetch('roots').first.fetch('requires')).to eq(['concurrent'])
    expect(result.fetch('roots')[1].fetch('requires')).to eq(['tzinfo/data'])
    expect(result.fetch('gtk')).to be(false)
  end

  it 'refuses a newly selected root until a require definition is reviewed' do
    expect { described_class.for_lock(lock_for(['new-gem'])) }.to raise_error(ArgumentError, /new-gem has no safe smoke/)
  end

  it 'refuses unsafe require paths and marks GTK selection explicitly' do
    expect do
      described_class.for_lock(lock_for(['sqlite3']), definitions: { 'sqlite3' => ['../escape'] })
    end.to raise_error(ArgumentError, /no safe smoke/)
    expect(described_class.for_lock(lock_for(['gtk3'])).fetch('gtk')).to be(true)
  end
end
