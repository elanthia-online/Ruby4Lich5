# frozen_string_literal: true

require 'ruby4lich5/gem_manifest_generator'
require 'ruby4lich5/installed_gem_closure'
require 'ruby4lich5/rubygems_client'
require 'tmpdir'
require 'digest'

RSpec.describe Ruby4Lich5::GemManifestGenerator do
  def node(name, version, deps = [])
    { name: name, version: version, runtime_dependency_names: deps }
  end

  # @param names [Array<String>] the full closure, e.g. gtk3 stack + os
  # @return [#resolve] a stand-in for InstalledGemClosure
  def stub_closure(nodes)
    instance_double(Ruby4Lich5::InstalledGemClosure, resolve: nodes)
  end

  # Writes a real staged .gem-shaped file with the given content and returns
  # the directory it lives in, so pure-digest tests hash real bytes rather
  # than asserting against a mock.
  def stage_gem_file(dir, filename, content)
    File.write(File.join(dir, filename), content)
  end

  # @param names [Array<String>] closure member names to mark as
  #   'native_self_contained' -- every remaining GTK3_STACK name not passed
  #   here still needs an explicit entry, so callers list the full set they
  #   care about; anything absent from +extra+ defaults to GTK3_STACK/self-
  #   contained, matching this project's real default closure.
  def delivery_states(self_contained: described_class::GTK3_STACK, pass_through: [], pure: [])
    {}.tap do |states|
      self_contained.each { |name| states[name] = 'native_self_contained' }
      pass_through.each { |name| states[name] = 'native_pass_through' }
      pure.each { |name| states[name] = 'pure' }
    end
  end

  let(:rubygems_client) { instance_double(Ruby4Lich5::RubygemsClient) }
  let(:native_digest_lookup) { ->(name, version) { "sha256:native-digest-#{name}-#{version}" } }
  let(:bundle_asset) do
    { tag: 'R4L5-gem-bundle-x64-mingw-ucrt', filename: 'R4L5-gem-bundle-x64-mingw-ucrt.zip', sha256: 'sha256:' + ('b' * 64) }
  end

  around do |example|
    Dir.mktmpdir('ruby4lich5-manifest-spec-') { |dir| @pkg_dir = dir; example.run }
  end

  def build_generator(root_names:, delivery_states_by_name:, closure_nodes:)
    described_class.new(
      root_names: root_names,
      delivery_states_by_name: delivery_states_by_name,
      ruby_abi: '4.0',
      platform: 'x64-mingw-ucrt',
      repo: 'elanthia-online/Ruby4Lich5',
      bundle_asset: bundle_asset,
      pkg_dir: @pkg_dir,
      native_digest_lookup: native_digest_lookup,
      rubygems_client: rubygems_client,
      closure_resolver: stub_closure(closure_nodes)
    )
  end

  describe '#generate' do
    it 'produces the schema/targets envelope' do
      generator = build_generator(
        root_names: described_class::GTK3_STACK,
        delivery_states_by_name: delivery_states,
        closure_nodes: described_class::GTK3_STACK.map { |n| node(n, '4.3.6') }
      )

      result = generator.generate

      expect(result['schema']).to eq(1)
      expect(result['targets']).to eq(
        [{ 'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt', 'units' => result['targets'].first['units'] }]
      )
    end

    it 'raises UnknownDeliveryStateError for a resolved closure member with no recorded delivery state' do
      generator = build_generator(
        root_names: ['sqlite3'], delivery_states_by_name: {}, closure_nodes: [node('sqlite3', '2.9.5')]
      )

      expect { generator.generate }.to raise_error(described_class::UnknownDeliveryStateError, /sqlite3/)
    end

    it 'raises UnknownDeliveryStateError for a delivery state outside the accepted three' do
      generator = build_generator(
        root_names: ['sqlite3'], delivery_states_by_name: { 'sqlite3' => 'native_needs_system_lib' },
        closure_nodes: [node('sqlite3', '2.9.5')]
      )

      expect { generator.generate }.to raise_error(described_class::UnknownDeliveryStateError, /native_needs_system_lib/)
    end

    context 'the GTK3 stack' do
      it 'groups the whole stack plus its private pure deps into one gtk3-runtime unit, bundle artifact' do
        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') }
        closure[described_class::GTK3_STACK.index('cairo')] = node('cairo', '1.18.5', ['red-colors'])
        closure << node('red-colors', '0.4.0', ['matrix'])
        closure << node('matrix', '0.4.3')

        { 'red-colors' => '0.4.0', 'matrix' => '0.4.3' }.each do |name, version|
          content = "fixture #{name} gem bytes"
          stage_gem_file(@pkg_dir, "#{name}-#{version}.gem", content)
          digest = Digest::SHA256.hexdigest(content)
          allow(rubygems_client).to receive(:versions).with(name)
                                                      .and_return([{ 'number' => version, 'platform' => 'ruby', 'sha' => digest }])
        end

        generator = build_generator(
          root_names: described_class::GTK3_STACK,
          delivery_states_by_name: delivery_states(pure: %w[red-colors matrix]),
          closure_nodes: closure
        )
        unit = generator.generate['targets'].first['units'].find { |u| u['id'] == 'gtk3-runtime' }

        expect(unit['members']).to include(*described_class::GTK3_STACK, 'red-colors', 'matrix')
        expect(unit['artifact']).to eq(
          'url'      => 'https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-bundle-x64-mingw-ucrt.zip',
          'filename' => 'R4L5-gem-bundle-x64-mingw-ucrt.zip',
          'sha256'   => bundle_asset[:sha256],
          'archive'  => 'zip'
        )
        glib2_package = unit['packages'].find { |p| p['name'] == 'glib2' }
        expect(glib2_package).to eq(
          'name' => 'glib2', 'version' => '4.3.6', 'filename' => 'glib2-4.3.6-x64-mingw-ucrt.gem',
          'sha256' => 'sha256:native-digest-glib2-4.3.6'
        )
      end
    end

    context 'a standalone native_self_contained gem' do
      it 'gets its own individual-release artifact, R4L5-prefixed filename' do
        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } + [node('sqlite3', '2.9.5')]
        generator = build_generator(
          root_names: described_class::GTK3_STACK + ['sqlite3'],
          delivery_states_by_name: delivery_states(self_contained: described_class::GTK3_STACK + ['sqlite3']),
          closure_nodes: closure
        )

        unit = generator.generate['targets'].first['units'].find { |u| u['id'] == 'sqlite3' }

        expect(unit['members']).to eq(['sqlite3'])
        expect(unit['packages'].first['filename']).to eq(unit['artifact']['filename'])
        expect(unit['artifact']).to eq(
          'url'      => 'https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-sqlite3-2.9.5-x64-mingw-ucrt/R4L5-sqlite3-2.9.5-x64-mingw-ucrt.gem',
          'filename' => 'R4L5-sqlite3-2.9.5-x64-mingw-ucrt.gem',
          'sha256'   => 'sha256:native-digest-sqlite3-2.9.5',
          'archive'  => 'gem'
        )
      end

      it 'calls native_digest_lookup exactly once, not twice, for the same (name, version)' do
        # A standalone single-native-member unit needs the same fact for
        # both its own artifact block (artifact_for) and its packages entry
        # (build_package) -- real duplicate call found in review 2026-07-11,
        # since the real lookup shells out to `gh api` per call.
        calls = []
        counting_lookup = lambda do |name, version|
          calls << [name, version]
          "sha256:native-digest-#{name}-#{version}"
        end
        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } + [node('sqlite3', '2.9.5')]
        generator = described_class.new(
          root_names: described_class::GTK3_STACK + ['sqlite3'],
          delivery_states_by_name: delivery_states(self_contained: described_class::GTK3_STACK + ['sqlite3']),
          ruby_abi: '4.0', platform: 'x64-mingw-ucrt', repo: 'elanthia-online/Ruby4Lich5', bundle_asset: bundle_asset,
          pkg_dir: @pkg_dir, native_digest_lookup: counting_lookup, rubygems_client: rubygems_client,
          closure_resolver: stub_closure(closure)
        )

        generator.generate

        expect(calls.count(['sqlite3', '2.9.5'])).to eq(1)
      end

      it 'does not carry a cached digest across two separate #generate calls on the same instance' do
        # Real bug, found in review 2026-07-11, verified directly by the
        # reviewer: the cache was created lazily inside native_digest_for
        # (`@native_digest_cache ||= {}`), which persists for the life of
        # the object -- a second real #generate call on the same instance
        # would silently reuse the first run's digests even if the injected
        # lookup would now return something different. Memoization is meant
        # to scope to one generation run, not the object's whole lifetime.
        responses = { 'sqlite3' => %w[sha256-run-one sha256-run-two] }
        call_counts = Hash.new(0)
        changing_lookup = lambda do |name, _version|
          call_counts[name] += 1
          if name == 'sqlite3'
            "sha256:#{responses.fetch(name)[call_counts[name] - 1]}#{'0' * 50}"
          else
            "sha256:native-digest-#{name}"
          end
        end
        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } + [node('sqlite3', '2.9.5')]
        generator = described_class.new(
          root_names: described_class::GTK3_STACK + ['sqlite3'],
          delivery_states_by_name: delivery_states(self_contained: described_class::GTK3_STACK + ['sqlite3']),
          ruby_abi: '4.0', platform: 'x64-mingw-ucrt', repo: 'elanthia-online/Ruby4Lich5', bundle_asset: bundle_asset,
          pkg_dir: @pkg_dir, native_digest_lookup: changing_lookup, rubygems_client: rubygems_client,
          closure_resolver: stub_closure(closure)
        )

        first_run_digest = generator.generate['targets'].first['units'].find { |u| u['id'] == 'sqlite3' }['artifact']['sha256']
        second_run_digest = generator.generate['targets'].first['units'].find { |u| u['id'] == 'sqlite3' }['artifact']['sha256']

        expect(first_run_digest).to include('sha256-run-one')
        expect(second_run_digest).to include('sha256-run-two')
        expect(second_run_digest).not_to eq(first_run_digest)
      end
    end

    context 'a standalone native_pass_through gem (regression, 2026-07-13 audit finding)' do
      it 'uses the shared bundle artifact, never an R4L5 individual-release URL' do
        content = 'fixture sqlite3 x64-mingw-ucrt gem bytes'
        stage_gem_file(@pkg_dir, 'sqlite3-2.9.5-x64-mingw-ucrt.gem', content)
        digest = Digest::SHA256.hexdigest(content)
        allow(rubygems_client).to receive(:versions).with('sqlite3').and_return(
          [{ 'number' => '2.9.5', 'platform' => 'x64-mingw-ucrt', 'sha' => digest }]
        )

        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } + [node('sqlite3', '2.9.5')]
        generator = build_generator(
          root_names: described_class::GTK3_STACK + ['sqlite3'],
          delivery_states_by_name: delivery_states(pass_through: ['sqlite3']),
          closure_nodes: closure
        )

        unit = generator.generate['targets'].first['units'].find { |u| u['id'] == 'sqlite3' }

        expect(unit['artifact']).to eq(
          'url'      => 'https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-bundle-x64-mingw-ucrt.zip',
          'filename' => 'R4L5-gem-bundle-x64-mingw-ucrt.zip',
          'sha256'   => bundle_asset[:sha256],
          'archive'  => 'zip'
        )
      end

      it 'includes the target platform in its package filename, and verifies against the target-platform digest' do
        content = 'fixture sqlite3 x64-mingw-ucrt gem bytes'
        stage_gem_file(@pkg_dir, 'sqlite3-2.9.5-x64-mingw-ucrt.gem', content)
        digest = Digest::SHA256.hexdigest(content)
        allow(rubygems_client).to receive(:versions).with('sqlite3').and_return(
          [{ 'number' => '2.9.5', 'platform' => 'ruby', 'sha' => 'f' * 64 },
           { 'number' => '2.9.5', 'platform' => 'x64-mingw-ucrt', 'sha' => digest }]
        )

        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } + [node('sqlite3', '2.9.5')]
        generator = build_generator(
          root_names: described_class::GTK3_STACK + ['sqlite3'],
          delivery_states_by_name: delivery_states(pass_through: ['sqlite3']),
          closure_nodes: closure
        )

        unit = generator.generate['targets'].first['units'].find { |u| u['id'] == 'sqlite3' }
        package = unit['packages'].find { |p| p['name'] == 'sqlite3' }

        expect(package).to eq(
          'name' => 'sqlite3', 'version' => '2.9.5', 'filename' => 'sqlite3-2.9.5-x64-mingw-ucrt.gem',
          'sha256' => "sha256:#{digest}"
        )
      end

      it 'raises when the staged file only matches the ruby-platform digest, not the target-platform one' do
        content = 'fixture sqlite3 gem bytes'
        stage_gem_file(@pkg_dir, 'sqlite3-2.9.5-x64-mingw-ucrt.gem', content)
        local_digest = Digest::SHA256.hexdigest(content)
        allow(rubygems_client).to receive(:versions).with('sqlite3').and_return(
          [{ 'number' => '2.9.5', 'platform' => 'ruby', 'sha' => local_digest }]
        )

        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } + [node('sqlite3', '2.9.5')]
        generator = build_generator(
          root_names: described_class::GTK3_STACK + ['sqlite3'],
          delivery_states_by_name: delivery_states(pass_through: ['sqlite3']),
          closure_nodes: closure
        )

        expect { generator.generate }.to raise_error(described_class::DigestValidationError, /unverifiable/)
      end
    end

    context 'candidate-to-live promotion regression (2026-07-10 review finding)' do
      it "never lets a fresher native-gem digest leak into the still-live bundle's own artifact digest, or vice versa" do
        # The real scenario the workflow fix (Phase 14 addendum) exists for:
        # individual native-gem releases clobber unconditionally on every
        # publish run, but the bundle zip itself only changes when *this*
        # run actually promotes to the live tag. A run that instead
        # publishes a candidate still reclobbers glib2's own release --
        # meaning the true current glib2 digest can genuinely differ from
        # what's baked inside the still-unchanged live zip. The generator
        # must thread both values through faithfully from their own
        # independent sources, never conflate or derive one from the
        # other -- this locks that invariant at the data-model level, since
        # the workflow-level "did they actually drift apart" scenario
        # itself isn't something RSpec can exercise (real gh state).
        stale_bundle_digest = "sha256:#{'1' * 64}" # the still-live zip's own, unchanged digest
        fresh_glib2_digest = "sha256:#{'2' * 64}"  # glib2's real *current* release digest, reclobbered since

        digest_lookup = lambda do |name, version|
          name == 'glib2' && version == '4.3.6' ? fresh_glib2_digest : "sha256:native-digest-#{name}-#{version}"
        end
        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') }
        generator = described_class.new(
          root_names: described_class::GTK3_STACK, delivery_states_by_name: delivery_states, ruby_abi: '4.0',
          platform: 'x64-mingw-ucrt', repo: 'elanthia-online/Ruby4Lich5', bundle_asset: bundle_asset.merge(sha256: stale_bundle_digest),
          pkg_dir: @pkg_dir, native_digest_lookup: digest_lookup, rubygems_client: rubygems_client,
          closure_resolver: stub_closure(closure)
        )

        unit = generator.generate['targets'].first['units'].find { |u| u['id'] == 'gtk3-runtime' }

        expect(unit['artifact']['sha256']).to eq(stale_bundle_digest)
        expect(unit['packages'].find { |p| p['name'] == 'glib2' }['sha256']).to eq(fresh_glib2_digest)
      end

      it "tags the bundle artifact URL with the candidate's own tag, never a hardcoded live tag" do
        # The actual reported bug, reproduced directly: a run that publishes
        # a candidate must generate a manifest whose artifact URL points at
        # *that candidate*, not at a separately-assumed live tag -- the
        # package list below always comes from this same run's own dist/pkg,
        # so if the artifact URL pointed elsewhere (the old hardcoded
        # behavior), a self-heal client would fetch a different bundle than
        # the one these package filenames/versions actually describe.
        candidate_asset = { tag: 'R4L5-gem-bundle-x64-mingw-ucrt-candidate',
                             filename: 'R4L5-gem-bundle-x64-mingw-ucrt.zip', sha256: 'sha256:' + ('9' * 64) }
        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') }
        generator = described_class.new(
          root_names: described_class::GTK3_STACK, delivery_states_by_name: delivery_states, ruby_abi: '4.0',
          platform: 'x64-mingw-ucrt', repo: 'elanthia-online/Ruby4Lich5', bundle_asset: candidate_asset, pkg_dir: @pkg_dir,
          native_digest_lookup: native_digest_lookup, rubygems_client: rubygems_client, closure_resolver: stub_closure(closure)
        )

        unit = generator.generate['targets'].first['units'].find { |u| u['id'] == 'gtk3-runtime' }

        expect(unit['artifact']['url']).to eq(
          'https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-gem-bundle-x64-mingw-ucrt-candidate/R4L5-gem-bundle-x64-mingw-ucrt.zip'
        )
      end
    end

    context 'a pure gem with its own real dependency (tzinfo -> concurrent-ruby)' do
      it 'computes and validates the digest against RubyGems.org, bare filename, bundle artifact' do
        tzinfo_content = 'fixture tzinfo gem bytes'
        concurrent_ruby_content = 'fixture concurrent-ruby gem bytes'
        stage_gem_file(@pkg_dir, 'tzinfo-2.0.6.gem', tzinfo_content)
        stage_gem_file(@pkg_dir, 'concurrent-ruby-1.3.7.gem', concurrent_ruby_content)
        tzinfo_digest = "sha256:#{Digest::SHA256.hexdigest(tzinfo_content)}"
        concurrent_ruby_digest = "sha256:#{Digest::SHA256.hexdigest(concurrent_ruby_content)}"

        allow(rubygems_client).to receive(:versions).with('tzinfo')
                                                    .and_return([{ 'number' => '2.0.6', 'platform' => 'ruby', 'sha' => tzinfo_digest.delete_prefix('sha256:') }])
        allow(rubygems_client).to receive(:versions).with('concurrent-ruby')
                                                    .and_return([{ 'number' => '1.3.7', 'platform' => 'ruby', 'sha' => concurrent_ruby_digest.delete_prefix('sha256:') }])

        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } +
                  [node('tzinfo', '2.0.6', ['concurrent-ruby']), node('concurrent-ruby', '1.3.7')]
        generator = build_generator(
          root_names: described_class::GTK3_STACK + %w[tzinfo concurrent-ruby],
          delivery_states_by_name: delivery_states(pure: %w[tzinfo concurrent-ruby]),
          closure_nodes: closure
        )

        unit = generator.generate['targets'].first['units'].find { |u| u['id'] == 'tzinfo' }

        expect(unit['members']).to contain_exactly('tzinfo', 'concurrent-ruby')
        expect(unit['install_order']).to eq(%w[concurrent-ruby tzinfo])
        expect(unit['artifact']['archive']).to eq('zip')
        tzinfo_package = unit['packages'].find { |p| p['name'] == 'tzinfo' }
        expect(tzinfo_package).to eq(
          'name' => 'tzinfo', 'version' => '2.0.6', 'filename' => 'tzinfo-2.0.6.gem', 'sha256' => tzinfo_digest
        )
        concurrent_ruby_package = unit['packages'].find { |p| p['name'] == 'concurrent-ruby' }
        expect(concurrent_ruby_package).to eq(
          'name' => 'concurrent-ruby', 'version' => '1.3.7', 'filename' => 'concurrent-ruby-1.3.7.gem',
          'sha256' => concurrent_ruby_digest
        )
      end
    end

    context 'a pure gem whose staged file does not match RubyGems.org' do
      it 'raises DigestValidationError naming both the computed and the expected digest' do
        tampered_content = 'tampered or corrupted bytes'
        stage_gem_file(@pkg_dir, 'os-1.1.4.gem', tampered_content)
        remote_digest = "sha256:#{'f' * 64}"
        allow(rubygems_client).to receive(:versions).with('os')
                                                    .and_return([{ 'number' => '1.1.4', 'platform' => 'ruby', 'sha' => 'f' * 64 }])

        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } + [node('os', '1.1.4')]
        generator = build_generator(
          root_names: described_class::GTK3_STACK + ['os'], delivery_states_by_name: delivery_states(pure: ['os']), closure_nodes: closure
        )
        local_digest = "sha256:#{Digest::SHA256.hexdigest(tampered_content)}"

        expect { generator.generate }.to raise_error(described_class::DigestValidationError) do |error|
          expect(error.message).to match(/os 1\.1\.4/)
          expect(error.message).to include(local_digest)
          expect(error.message).to include(remote_digest)
        end
      end
    end

    context 'RubyGems.org has no matching version for a staged pure gem' do
      it 'raises DigestValidationError rather than shipping an unverified digest' do
        stage_gem_file(@pkg_dir, 'os-1.1.4.gem', 'whatever bytes')
        allow(rubygems_client).to receive(:versions).with('os').and_return([])

        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } + [node('os', '1.1.4')]
        generator = build_generator(
          root_names: described_class::GTK3_STACK + ['os'], delivery_states_by_name: delivery_states(pure: ['os']), closure_nodes: closure
        )

        expect { generator.generate }.to raise_error(described_class::DigestValidationError, /unverifiable/)
      end
    end

    context 'the staged pure gem file is missing entirely' do
      it 'raises DigestValidationError naming the missing path' do
        closure = described_class::GTK3_STACK.map { |n| node(n, '4.3.6') } + [node('os', '1.1.4')]
        generator = build_generator(
          root_names: described_class::GTK3_STACK + ['os'], delivery_states_by_name: delivery_states(pure: ['os']), closure_nodes: closure
        )

        expect { generator.generate }.to raise_error(described_class::DigestValidationError, /not found/)
      end
    end
  end
end
