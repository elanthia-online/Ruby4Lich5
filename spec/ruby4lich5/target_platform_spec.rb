# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'ruby4lich5/target_platform'
require_relative '../support/x64_platform_snapshot'

RSpec.describe Ruby4Lich5::TargetPlatform do
  let(:x64_entry) { JSON.parse(File.read(described_class::TABLE)).fetch('platforms').fetch('x64-mingw-ucrt') }

  # A second, synthetic row: proves the table is keyed by platform without
  # shipping unreviewed values for a real second platform.
  let(:demo_entry) do
    x64_entry.merge('rubyinstaller_asset_suffix' => 'demo', 'runner' => 'demo-runner', 'msystem' => 'DEMO64', 'msys2_prefix' => 'demo64',
                    'msys2_package_prefix' => 'mingw-w64-demo', 'gem_bundle_tag' => 'R4L5-gem-bundle-demo-mingw-ucrt',
                    'msys2_bootstrap_packages' => %w[base-devel mingw-w64-demo-cc])
  end

  around { |example| Dir.mktmpdir('r4l5-platforms') { |directory| @directory = directory; example.run } }

  def write(name, document)
    path = File.join(@directory, name)
    File.write(path, document.is_a?(String) ? document : JSON.generate(document))
    path
  end

  def table(platforms = { 'x64-mingw-ucrt' => x64_entry, 'demo-mingw-ucrt' => demo_entry })
    write('platforms.json', 'schema' => 1, 'platforms' => platforms)
  end

  def target(platform = 'x64-mingw-ucrt')
    write('target-ruby.json', 'platform' => platform)
  end

  describe 'selection' do
    it 'defaults to x64-mingw-ucrt from the real checked-in configuration' do
      selected = described_class.select(env: {})
      expect(selected.name).to eq('x64-mingw-ucrt')
      expect(selected.gem_bundle_tag).to eq('R4L5-gem-bundle-x64-mingw-ucrt')
    end

    it 'falls back to target-ruby.json when neither an argument nor GEM_PLATFORM is given' do
      expect(described_class.select(env: {}, table: table, target: target('demo-mingw-ucrt')).name).to eq('demo-mingw-ucrt')
    end

    it 'honors GEM_PLATFORM over target-ruby.json' do
      expect(described_class.select(env: { 'GEM_PLATFORM' => 'demo-mingw-ucrt' }, table: table, target: target).name).to eq('demo-mingw-ucrt')
    end

    it 'honors an explicit name over GEM_PLATFORM' do
      selected = described_class.select('x64-mingw-ucrt', env: { 'GEM_PLATFORM' => 'demo-mingw-ucrt' }, table: table, target: target)
      expect(selected.name).to eq('x64-mingw-ucrt')
    end

    it 'returns the row values for the selected platform' do
      selected = described_class.select('demo-mingw-ucrt', env: {}, table: table, target: target)
      expect(selected.msys2_bootstrap_packages).to eq(%w[base-devel mingw-w64-demo-cc])
      expect(selected.msystem).to eq('DEMO64')
      expect(selected.candidate_tag_pattern).to match('R4L5-gem-bundle-demo-mingw-ucrt-candidate-1-1')
      expect(selected.candidate_tag_pattern).not_to match('R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1')
    end

    it 'rejects an unknown platform rather than falling back' do
      expect { described_class.select('aarch64-mingw-ucrt', env: {}, table: table, target: target) }
        .to raise_error(described_class::Error, /unknown platform "aarch64-mingw-ucrt"/)
      expect { described_class.select(env: { 'GEM_PLATFORM' => 'x86-mingw32' }) }.to raise_error(described_class::Error, /unknown platform/)
    end

    it 'rejects an empty or unsafe GEM_PLATFORM instead of treating it as unset' do
      expect { described_class.select(env: { 'GEM_PLATFORM' => '' }, table: table, target: target) }.to raise_error(described_class::Error, /must not be nil or empty/)
      expect { described_class.select(env: { 'GEM_PLATFORM' => '../x64' }, table: table, target: target) }.to raise_error(described_class::Error, /disallowed characters/)
    end

    it 'returns deeply frozen rows' do
      selected = described_class.select(env: {})
      expect(selected).to be_frozen
      expect(selected.msys2_bootstrap_packages).to be_frozen.and(all(be_frozen))
      expect(selected.toolchain).to be_frozen
    end
  end

  describe 'table validation' do
    def rejects(document, pattern)
      expect { described_class.load_table(write('bad.json', document)) }.to raise_error(described_class::Error, pattern)
    end

    it 'accepts the checked-in table' do
      expect(described_class.load_table.keys).to eq(['x64-mingw-ucrt'])
    end

    it 'rejects malformed JSON and duplicate keys' do
      rejects('{', /malformed platform table JSON/)
      rejects('{"schema": 1, "schema": 1, "platforms": {}}', /malformed platform table JSON/)
    end

    it 'rejects a wrong schema, extra top-level keys and an empty table' do
      rejects({ 'schema' => 2, 'platforms' => { 'x64-mingw-ucrt' => x64_entry } }, /schema 1/)
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry }, 'extra' => true }, /exactly/)
      rejects({ 'schema' => 1, 'platforms' => {} }, /non-empty/)
    end

    it 'rejects missing, extra or malformed row fields' do
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.except('msystem') } }, /must define exactly/)
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.merge('extra' => 'x') } }, /must define exactly/)
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.merge('msystem' => 7) } }, /msystem must be a String/)
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.merge('msys2_prefix' => 'a/b') } }, /disallowed characters/)
      rejects({ 'schema' => 1, 'platforms' => { '..' => x64_entry } }, /platform name/)
    end

    it 'rejects a tag base that does not name its own platform' do
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.merge('gem_bundle_tag' => 'R4L5-gem-bundle-aarch64-mingw-ucrt') } },
              /gem_bundle_tag must be R4L5-gem-bundle-x64-mingw-ucrt/)
    end

    it 'rejects empty, repeated or other-environment bootstrap packages' do
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.merge('msys2_bootstrap_packages' => []) } }, /non-empty array/)
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.merge('msys2_bootstrap_packages' => %w[make make]) } }, /repeat/)
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.merge('msys2_bootstrap_packages' => %w[mingw-w64-clang-aarch64-clang]) } },
              /another MSYS2 environment/)
    end

    it 'rejects a toolchain without exactly the known tools' do
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.merge('toolchain' => x64_entry['toolchain'].except('objdump')) } }, /toolchain must define exactly/)
      rejects({ 'schema' => 1, 'platforms' => { 'x64-mingw-ucrt' => x64_entry.merge('toolchain' => x64_entry['toolchain'].merge('cc' => '')) } }, /toolchain cc/)
    end
  end

  # The golden was captured by running X64PlatformSnapshot against the
  # pre-table tree, so this proves every refactored x64 value and decision
  # is unchanged rather than restating config/platforms.json.
  describe 'x64 snapshot against the pre-table tree' do
    let(:root) { File.expand_path('../..', __dir__) }
    let(:golden) { JSON.parse(File.read(File.join(root, 'spec/fixtures/platform-table/x64-snapshot.json'))) }

    it 'reproduces every captured x64 value exactly' do
      skip 'GEM_PLATFORM selects a non-default platform' if ENV.fetch('GEM_PLATFORM', 'x64-mingw-ucrt') != 'x64-mingw-ucrt'
      actual = X64PlatformSnapshot.capture(root)
      expect(actual.keys).to eq(golden.keys)
      golden.each_key { |key| expect(actual.fetch(key)).to eq(golden.fetch(key)), key }
    end
  end
end
