# frozen_string_literal: true

require 'ruby4lich5/default_root_selection'

RSpec.describe Ruby4Lich5::DefaultRootSelection do
  describe '.resolve_versions' do
    it "resolves gtk3 to the fixed GTK3_VERSION, never a RubygemsClient lookup" do
      rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
      allow(rubygems_client).to receive(:latest_version).with(any_args) { |name| "#{name}-latest" }

      result = described_class.resolve_versions(rubygems_client: rubygems_client)

      expect(result['gtk3']).to eq(described_class::GTK3_VERSION)
      expect(rubygems_client).not_to have_received(:latest_version).with('gtk3')
    end

    it 'resolves every RUNTIME_GEMS root via RubygemsClient#latest_version' do
      rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
      allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

      result = described_class.resolve_versions(rubygems_client: rubygems_client)

      described_class::RUNTIME_GEMS.each do |name|
        expect(result[name]).to eq("#{name}-resolved")
        expect(rubygems_client).to have_received(:latest_version).with(name)
      end
    end

    it 'never includes cairo as an independent root -- the actual fix for the cairo-version/closure mismatch gap' do
      rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
      allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

      result = described_class.resolve_versions(rubygems_client: rubygems_client)

      expect(result).not_to have_key('cairo')
      # Not just "the result has no cairo key" -- the stub above answers
      # any name, so a stray #latest_version('cairo') call whose result
      # was simply never stored would still pass the key check alone.
      # This confirms the interaction itself never happens.
      expect(rubygems_client).not_to have_received(:latest_version).with('cairo')
    end

    it 'returns exactly gtk3 plus RUNTIME_GEMS, no more, no fewer' do
      rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
      allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

      result = described_class.resolve_versions(rubygems_client: rubygems_client)

      expect(result.keys).to contain_exactly('gtk3', *described_class::RUNTIME_GEMS)
    end

    # gtk3_version:/runtime_gems: overrides, added for F2's own cutover --
    # a real workflow's ruby-gnome-version/runtime-gems dispatch inputs
    # need to drive resolution instead of this module's fixed defaults,
    # without a second, independent copy of "resolve gtk3 at a given
    # version plus every given runtime gem via latest_version" existing
    # anywhere else.
    describe 'gtk3_version:/runtime_gems: overrides' do
      it 'uses the given gtk3_version instead of GTK3_VERSION, still never a RubygemsClient lookup' do
        rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
        allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

        result = described_class.resolve_versions(rubygems_client: rubygems_client, gtk3_version: '9.9.9')

        expect(result['gtk3']).to eq('9.9.9')
        expect(rubygems_client).not_to have_received(:latest_version).with('gtk3')
      end

      it 'resolves exactly the given runtime_gems instead of RUNTIME_GEMS, each via latest_version' do
        rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
        allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

        result = described_class.resolve_versions(rubygems_client: rubygems_client, runtime_gems: %w[custom-gem-a custom-gem-b])

        expect(result.keys).to contain_exactly('gtk3', 'custom-gem-a', 'custom-gem-b')
        expect(result['custom-gem-a']).to eq('custom-gem-a-resolved')
        expect(result['custom-gem-b']).to eq('custom-gem-b-resolved')
      end

      it "keeps the caller-supplied gtk3_version authoritative even if runtime_gems also names 'gtk3'" do
        # Regression, found in review 2026-07-13: only bin/resolve_bundle_lock.rb
        # filtered 'gtk3' out of its own runtime_gems_csv before calling
        # here -- this module itself never enforced it, so a caller (or a
        # future second caller) passing runtime_gems: ['gtk3'] would let
        # Hash#merge silently overwrite gtk3_version with a live
        # rubygems_client.latest_version('gtk3') result instead. Reproduced
        # live before fixing: returned {"gtk3"=>"gtk3-resolved", ...},
        # not the given override.
        rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
        allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

        result = described_class.resolve_versions(
          rubygems_client: rubygems_client, gtk3_version: '9.9.9', runtime_gems: %w[gtk3 custom-gem]
        )

        expect(result['gtk3']).to eq('9.9.9')
        expect(result.keys).to contain_exactly('gtk3', 'custom-gem')
        expect(rubygems_client).not_to have_received(:latest_version).with('gtk3')
      end

      it 'accepts an empty runtime_gems -- a real GTK3-only dispatch, not an error' do
        # Regression, per review 2026-07-13: bin/resolve_bundle_lock.rb
        # used to reject an empty post-filter runtime_gems_csv outright,
        # but this module itself already handles it correctly -- nothing
        # here requires at least one ordinary runtime root. requested_roots
        # collapses to exactly {'gtk3' => gtk3_version}, still a valid
        # non-empty Hash (ResolutionLock#validate_requested_roots! only
        # requires non-empty, not "more than just gtk3").
        rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
        allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

        result = described_class.resolve_versions(rubygems_client: rubygems_client, runtime_gems: [])

        expect(result).to eq({ 'gtk3' => described_class::GTK3_VERSION })
        expect(rubygems_client).not_to have_received(:latest_version)
      end

      it "raises ReservedRootError if a caller passes 'cairo' in runtime_gems, rather than silently resolving it a second time" do
        # Real gap, found in audit 2026-07-13: an earlier version of this
        # test asserted the opposite -- that cairo, if passed, was
        # "resolved exactly like any other requested runtime gem," which
        # directly contradicted this module's own header comment ("cairo
        # is never an independent root"). Reproduced live before fixing:
        # runtime_gems: ['cairo'] returned {"gtk3"=>"...", "cairo"=>"9.9.9"},
        # a version RubygemsClient resolved independently of gtk3's own
        # real resolved closure -- the exact TOCTOU-shaped drift this
        # module exists to prevent.
        rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
        allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

        expect { described_class.resolve_versions(rubygems_client: rubygems_client, runtime_gems: %w[cairo custom-gem]) }
          .to raise_error(described_class::ReservedRootError, /cairo/)
        expect(rubygems_client).not_to have_received(:latest_version).with('cairo')
      end

      it 'defaults to GTK3_VERSION/RUNTIME_GEMS when no override is given, matching every existing caller' do
        rubygems_client = instance_double(Ruby4Lich5::RubygemsClient)
        allow(rubygems_client).to receive(:latest_version) { |name| "#{name}-resolved" }

        result = described_class.resolve_versions(rubygems_client: rubygems_client)

        expect(result['gtk3']).to eq(described_class::GTK3_VERSION)
        expect(result.keys).to contain_exactly('gtk3', *described_class::RUNTIME_GEMS)
      end
    end
  end

  describe '.genuine_target_ruby?' do
    it 'needs both Gem::Platform.local and Gem.platforms to name the platform' do
      arm = Gem::Platform.new('aarch64-mingw-ucrt')
      allow(Gem::Platform).to receive(:local).and_return(arm)
      allow(Gem).to receive(:platforms).and_return([Gem::Platform::RUBY, arm])
      expect(described_class.genuine_target_ruby?('aarch64-mingw-ucrt')).to be(true)

      allow(Gem).to receive(:platforms).and_return([Gem::Platform::RUBY])
      expect(described_class.genuine_target_ruby?('aarch64-mingw-ucrt')).to be(false)
    end

    it 'refuses a host Ruby that only added the target to Gem.platforms' do
      allow(Gem::Platform).to receive(:local).and_return(Gem::Platform.new('x86_64-linux'))
      allow(Gem).to receive(:platforms).and_return([Gem::Platform::RUBY, Gem::Platform.new('aarch64-mingw-ucrt')])
      expect(described_class.genuine_target_ruby?('aarch64-mingw-ucrt')).to be(false)
    end
  end
end
