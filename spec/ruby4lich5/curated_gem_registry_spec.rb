# frozen_string_literal: true

require 'ruby4lich5/curated_gem_registry'
require 'json'

RSpec.describe Ruby4Lich5::CuratedGemRegistry do
  def fixture_path(*segments)
    File.join(__dir__, '..', 'fixtures', 'curated-gems', *segments)
  end

  def load_fixture(*segments)
    JSON.parse(File.read(fixture_path(*segments)))
  end

  describe '#initialize with no data' do
    it 'defaults to an empty registry -- nothing known, nothing approved' do
      registry = described_class.new

      expect(registry.known?('anything')).to be(false)
      expect(registry.approved?('anything', 'x64-mingw-ucrt', '4.0')).to be(false)
      expect(registry.bundle_default_roots).to eq([])
      expect(registry.content_digest).to be_nil
    end

    it 'accepts an explicit empty Hash the same way, as the documented intentional default' do
      expect(described_class.new({}).known?('anything')).to be(false)
    end
  end

  describe 'regression: non-Hash data must never silently pass as the empty-registry default' do
    # Real bug, found in review: an earlier #validate! called #empty? before
    # confirming the receiver was even a Hash. [].empty? and "".empty? are
    # both true, so an Array or String silently passed as "the empty
    # registry" instead of being rejected; nil.empty? doesn't exist at all,
    # so that case leaked a raw NoMethodError instead of ValidationError.
    # Every one of these four must now raise ValidationError, not silently
    # succeed and not raise the wrong exception class.
    { 'an Array' => [], 'a String' => '', 'nil' => nil }.each do |label, value|
      it "rejects #{label} instead of treating it as the empty-registry default" do
        expect { described_class.new(value) }.to raise_error(described_class::ValidationError, /must be an object/)
      end
    end
  end

  describe '.load_file requires the full schema/gems envelope even for an empty-looking document' do
    %w[empty_object.json empty_array.json empty_string.json null.json].each do |filename|
      it "rejects #{filename} rather than treating it as the empty-registry default" do
        expect { described_class.load_file(fixture_path('invalid', filename)) }
          .to raise_error(described_class::ValidationError)
      end
    end

    it 'still rejects a literal {} passed directly with require_envelope: true' do
      expect { described_class.new({}, require_envelope: true) }
        .to raise_error(described_class::ValidationError, /empty/)
    end
  end

  describe 'valid fixtures' do
    it 'accepts a minimal pure-gem registry' do
      registry = described_class.new(load_fixture('valid', 'minimal.json'))

      expect(registry.known?('example-pure-gem')).to be(true)
      expect(registry.approved?('example-pure-gem', 'x64-mingw-ucrt', '4.0')).to be(true)
      expect(registry.classification_for('example-pure-gem', 'x64-mingw-ucrt', '4.0')).to eq('pure')
      expect(registry.msys2_packages_for('example-pure-gem', 'x64-mingw-ucrt', '4.0')).to eq([])
      expect(registry.bundle_default_roots).to eq(['example-pure-gem'])
    end

    it 'accepts a native_self_contained gem with msys2_packages' do
      registry = described_class.new(load_fixture('valid', 'native_self_contained.json'))

      expect(registry.classification_for('example-native-gem', 'x64-mingw-ucrt', '4.0')).to eq('native_self_contained')
      expect(registry.msys2_packages_for('example-native-gem', 'x64-mingw-ucrt', '4.0'))
        .to eq(['mingw-w64-ucrt-x86_64-example'])
    end

    it 'allows msys2_packages to legitimately overlap across different gems' do
      registry = described_class.new(load_fixture('valid', 'overlapping_packages.json'))

      expect(registry.msys2_packages_for('example-native-gem-a', 'x64-mingw-ucrt', '4.0'))
        .to include('mingw-w64-ucrt-x86_64-shared-lib')
      expect(registry.msys2_packages_for('example-native-gem-b', 'x64-mingw-ucrt', '4.0'))
        .to include('mingw-w64-ucrt-x86_64-shared-lib')
    end
  end

  describe 'invalid fixtures' do
    invalid_fixtures = %w[
      bad_schema_version.json
      unknown_top_level_field.json
      unknown_gem_entry_field.json
      unknown_target_leaf_field.json
      duplicate_key.json
      bad_approval_value.json
      classification_native_needs_system_lib.json
      classification_ruby_bundled.json
      missing_msys2_packages_when_self_contained.json
      empty_msys2_packages_when_self_contained.json
      msys2_packages_present_when_pure.json
      unsafe_identifier_gem_name.json
      unsafe_identifier_platform.json
      unsafe_identifier_ruby_abi.json
      unsafe_identifier_msys2_package.json
    ]

    # Two real rejection points exist: parse_strict (duplicate keys,
    # malformed JSON) and #initialize (every semantic schema check).
    # duplicate_key.json is the only fixture caught by the first -- data
    # never successfully reaches #new for it (confirmed directly: every
    # other fixture here parses cleanly). Asserted per-fixture below, not a
    # blanket "either raise point is a pass" rescue -- that would have let
    # an unexpected parse_strict failure on any *other* fixture (e.g. a
    # typo making it malformed JSON) silently count as a pass without ever
    # exercising #initialize's own rejection at all.
    (invalid_fixtures - ['duplicate_key.json']).each do |filename|
      it "rejects #{filename} at #initialize, after parsing successfully" do
        raw_text = File.read(fixture_path('invalid', filename))
        data = described_class.parse_strict(raw_text)

        expect { described_class.new(data) }.to raise_error(described_class::ValidationError)
      end
    end

    it 'rejects duplicate_key.json at .parse_strict itself, before #initialize is ever reachable' do
      raw_text = File.read(fixture_path('invalid', 'duplicate_key.json'))

      expect { described_class.parse_strict(raw_text) }.to raise_error(described_class::ValidationError)
    end
  end

  describe '.parse_strict' do
    it 'raises on a genuinely duplicate JSON key, not silently keeping the last one' do
      raw_text = File.read(fixture_path('invalid', 'duplicate_key.json'))

      expect { described_class.parse_strict(raw_text) }.to raise_error(described_class::ValidationError, /duplicate key/)
    end

    it 'raises on malformed JSON' do
      expect { described_class.parse_strict('{not valid json') }.to raise_error(described_class::ValidationError)
    end
  end

  describe '.load_file' do
    it 'loads a real file, computing a real sha256: content digest over its exact bytes' do
      path = fixture_path('valid', 'minimal.json')
      registry = described_class.load_file(path)

      expected_digest = "sha256:#{Digest::SHA256.hexdigest(File.binread(path))}"
      expect(registry.content_digest).to eq(expected_digest)
      expect(registry.known?('example-pure-gem')).to be(true)
    end

    it 'raises on a file that is not valid UTF-8' do
      path = fixture_path('invalid', 'bad_encoding.json')

      expect { described_class.load_file(path) }.to raise_error(described_class::ValidationError, /UTF-8/)
    end
  end

  describe '#self_build_packages_for (KnownNativeGems-compatible facade query)' do
    it 'returns the current-target packages for a native_self_contained gem' do
      registry = described_class.new(load_fixture('valid', 'native_self_contained.json'))

      expect(registry.self_build_packages_for('example-native-gem')).to eq(['mingw-w64-ucrt-x86_64-example'])
    end

    it 'returns nil for a known pure gem -- not a self-build candidate at all' do
      registry = described_class.new(load_fixture('valid', 'minimal.json'))

      expect(registry.self_build_packages_for('example-pure-gem')).to be_nil
    end

    it 'returns nil for an unknown gem, matching KnownNativeGems.packages_for exactly' do
      registry = described_class.new(load_fixture('valid', 'minimal.json'))

      expect(registry.self_build_packages_for('totally-unknown-gem')).to be_nil
    end

    describe 'regression: an approved native_pass_through gem must never be mistaken for a self-build candidate' do
      # Real bug, found in review before this method had a real caller: an
      # earlier version gated only on #known? (registry membership), so an
      # approved native_pass_through entry -- a real, current case
      # (upstream sqlite3/ffi now ship precompiled x64-mingw-ucrt builds
      # matching Ruby 4.0's ABI) -- returned [] (empty, but truthy) instead
      # of nil. Classifier#self_build_classification branches on that exact
      # nil-vs-Array truthiness; a truthy empty Array would have silently
      # produced :native_self_contained with zero packages to build with,
      # instead of failing closed as :native_needs_system_lib the moment a
      # gem's upstream precompiled build ever disappears.
      let(:registry) { described_class.new(load_fixture('valid', 'native_pass_through.json')) }

      it 'returns nil, not an empty Array, for a native_pass_through gem' do
        result = registry.self_build_packages_for('example-pass-through-gem')

        expect(result).to be_nil
        expect(result).not_to eq([])
      end
    end

    # Real regression case, per review: an earlier version of this method
    # took no ruby_abi parameter at all, hardcoded to CURRENT_RUBY_ABI
    # ('4.0') internally -- a caller resolving under a genuinely different
    # Ruby (e.g. a real future 4.1.x RubyInstaller) had no way to ask this
    # method about that target at all, so it would silently keep answering
    # against 4.0-series registry entries regardless of what was actually
    # resolved and classified.
    describe 'ruby_abi: override -- querying a target other than CURRENT_RUBY_ABI' do
      let(:registry) do
        described_class.new(
          {
            'schema' => 2,
            'gems'   => {
              'example-native-gem' => {
                'approval'       => 'approved',
                'bundle_default' => false,
                'targets'        => {
                  'x64-mingw-ucrt' => {
                    '4.0' => {
                      'expected_classification' => 'pure'
                    },
                    '4.1' => {
                      'expected_classification' => 'native_self_contained',
                      'msys2_packages'          => ['mingw-w64-ucrt-x86_64-example']
                    }
                  }
                }
              }
            }
          }
        )
      end

      it 'queries the given ruby_abi, not CURRENT_RUBY_ABI, when explicitly overridden' do
        expect(registry.self_build_packages_for('example-native-gem', ruby_abi: '4.1'))
          .to eq(['mingw-w64-ucrt-x86_64-example'])
      end

      it 'still defaults to CURRENT_RUBY_ABI when no override is given, matching every existing caller' do
        expect(registry.self_build_packages_for('example-native-gem')).to be_nil
      end

      it 'fails closed (returns nil) for a ruby_abi the registry genuinely has no entry for at all' do
        expect(registry.self_build_packages_for('example-native-gem', ruby_abi: '4.2')).to be_nil
      end
    end
  end

  describe 'query methods against an unapproved/unknown target' do
    let(:registry) { described_class.new(load_fixture('valid', 'minimal.json')) }

    it 'reports not approved for a platform/abi with no target entry' do
      expect(registry.approved?('example-pure-gem', 'arm64-darwin', '4.0')).to be(false)
      expect(registry.classification_for('example-pure-gem', 'arm64-darwin', '4.0')).to be_nil
      expect(registry.msys2_packages_for('example-pure-gem', 'arm64-darwin', '4.0')).to eq([])
    end

    it 'reports not approved for a gem with no entry at all' do
      expect(registry.approved?('never-heard-of-it', 'x64-mingw-ucrt', '4.0')).to be(false)
    end
  end

  describe 'regression: internal state must be immune to mutation via a returned value' do
    # Real bug, found in CodeRabbit review: msys2_packages_for returned a
    # live reference into @gems -- mutating the returned Array permanently
    # corrupted this registry's own internal state for every future query,
    # not just the caller's local variable.
    let(:registry) { described_class.new(load_fixture('valid', 'native_self_contained.json')) }

    it 'returns a frozen array from msys2_packages_for; mutating it never touches internal state' do
      packages = registry.msys2_packages_for('example-native-gem', 'x64-mingw-ucrt', '4.0')

      expect(packages).to be_frozen
      expect { packages << 'injected-package' }.to raise_error(FrozenError)
      expect(registry.msys2_packages_for('example-native-gem', 'x64-mingw-ucrt', '4.0'))
        .to eq(['mingw-w64-ucrt-x86_64-example'])
    end

    it 'returns a frozen content_digest from .load_file' do
      loaded = described_class.load_file(fixture_path('valid', 'minimal.json'))

      expect(loaded.content_digest).to be_frozen
    end

    it "never freezes the caller's own input data as a side effect" do
      packages = ['mingw-w64-ucrt-x86_64-example']
      data = {
        'schema' => 2,
        'gems'   => {
          'example-native-gem' => {
            'approval'       => 'approved',
            'bundle_default' => false,
            'targets'        => {
              'x64-mingw-ucrt' => {
                '4.0' => { 'expected_classification' => 'native_self_contained', 'msys2_packages' => packages }
              }
            }
          }
        }
      }

      described_class.new(data)

      expect(packages).not_to be_frozen
    end
  end

  describe 'regression: duplicate top-level keys that only collide after normalization' do
    # Real bug, found in CodeRabbit review: stringify_top_level called
    # key.to_s and inserted unconditionally, so a hand-built Hash with both
    # a Symbol and a String form of the same top-level key (:schema and
    # "schema") silently let the later one win instead of raising -- the
    # same silent-overwrite failure mode .parse_strict's
    # allow_duplicate_key: false already closes for real JSON input, but
    # unguarded for this class's other documented input shape.
    it 'raises rather than silently keeping whichever value inserted last' do
      data = { schema: 1, 'schema' => 2, gems: {} }

      expect { described_class.new(data) }.to raise_error(described_class::ValidationError, /duplicate top-level key/)
    end
  end

  describe 'build roles name gems with something to build' do
    def registry_with(build_role, targets)
      described_class.new({ 'schema' => 2, 'gems' => {
        'demo' => { 'approval' => 'approved', 'bundle_default' => false, 'build_role' => build_role, 'targets' => targets }
      } })
    end

    let(:self_built) { { 'expected_classification' => 'native_self_contained', 'msys2_packages' => ['mingw-w64-demo-lib'] } }
    let(:passed_through) { { 'expected_classification' => 'native_pass_through' } }
    let(:pure) { { 'expected_classification' => 'pure' } }

    it 'accepts a repack gem passed through on one platform and self-built on another, as sqlite3 is' do
      registry = registry_with('repack', 'x64-mingw-ucrt' => { '4.0' => passed_through }, 'aarch64-mingw-ucrt' => { '4.0' => self_built })
      expect(registry.names_for_role('repack')).to eq(['demo'])
      expect(registry.classification_for('demo', 'x64-mingw-ucrt', '4.0')).to eq('native_pass_through')
    end

    it 'rejects a gtk or repack role with no self-built target or with a pure target' do
      %w[gtk repack].each do |role|
        expect { registry_with(role, 'x64-mingw-ucrt' => { '4.0' => passed_through }) }
          .to raise_error(described_class::ValidationError, /demo build_role #{role} requires a native_self_contained target/)
        expect { registry_with(role, 'x64-mingw-ucrt' => { '4.0' => self_built }, 'aarch64-mingw-ucrt' => { '4.0' => pure }) }
          .to raise_error(described_class::ValidationError, /no pure target/)
      end
    end

    it 'leaves none and tooling roles unconstrained' do
      %w[none tooling].each { |role| expect(registry_with(role, 'x64-mingw-ucrt' => { '4.0' => pure }).names_for_role(role)).to eq(['demo']) }
    end

    it 'holds for the checked-in registry' do
      registry = described_class.load_file(File.expand_path('../../config/curated-gems.json', __dir__))
      expect(registry.names_for_role('repack')).to contain_exactly('curses', 'ox', 'sqlite3')
    end
  end
end
