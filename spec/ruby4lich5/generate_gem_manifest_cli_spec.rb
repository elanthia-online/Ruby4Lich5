# frozen_string_literal: true

require 'ruby4lich5/gem_manifest_generator'
require 'ruby4lich5/resolution_lock'
require 'ruby4lich5/classification'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'open3'
require 'rubygems/package'

# Real subprocess integration test for bin/generate_gem_manifest.rb -- proves
# the CLI's own ARGV-parsing/wiring (ResolutionLock deserialization,
# StagedGemSpecFinder, NativeGemDigestFetcher, JSON output, exit codes)
# works end to end as an actual external process, not just via internal Ruby
# doubles the way gem_manifest_generator_spec.rb already covers the
# generator's own logic.
#
# Deliberately native_self_contained-only, no pure/pass-through gems: those
# digest checks call out to the real RubyGems.org API (RubygemsClient's real
# HTTP default), which this suite otherwise never does (every other
# pure/pass-through digest spec injects a stub). Keeping this one
# network-free means it stays fast and doesn't make CI depend on
# RubyGems.org being reachable -- the pure/pass-through cross-check paths
# are already locked at the unit level in gem_manifest_generator_spec.rb.
RSpec.describe 'bin/generate_gem_manifest.rb (CLI integration)' do
  def build_real_gem(dir, name, version)
    spec = Gem::Specification.new(name, version) { |s| s.summary = 'fixture'; s.authors = ['fixture']; s.files = [] }
    yield spec if block_given?
    Dir.chdir(dir) { Gem::Package.build(spec) }
  end

  # A minimal fake `gh`, first on PATH for the subprocess -- returns a
  # canned "release view"-shaped response naming the real sha256 of the
  # staged .gem file its own tag argument refers to, so the CLI's own
  # NativeGemDigestFetcher gets a real, verifiable digest without touching
  # a real GitHub API. Keyed by the *exact* tag NativeGemDigestFetcher
  # constructs (+"R4L5-<name>-<version>-<platform>"+), not a name prefix --
  # a loose prefix match would wrongly resolve e.g. "cairo-gobject"'s tag to
  # plain "cairo"'s digest, since one is a real string prefix of the other.
  def write_fake_gh(bin_dir, pkg_dir, name_versions, platform: 'x64-mingw-ucrt')
    digests = name_versions.to_h do |name, version|
      path = File.join(pkg_dir, "#{name}-#{version}.gem")
      tag = "R4L5-#{name}-#{version}-#{platform}"
      [tag, "sha256:#{Digest::SHA256.file(path).hexdigest}"]
    end

    script = <<~RUBY
      #!/usr/bin/env ruby
      require 'json'
      tag_arg = ARGV.find { |a| a.start_with?('repos/') }
      tag = tag_arg.split('/').last
      digests = #{digests.inspect}
      digest = digests[tag]
      abort "fake gh: no canned digest for tag \#{tag}" unless digest
      puts({ assets: [{ name: "\#{tag}.gem", digest: digest }] }.to_json)
    RUBY
    path = File.join(bin_dir, 'gh')
    File.write(path, script)
    FileUtils.chmod('+x', path)
  end

  # @return [Hash] a {ResolutionLock#initialize}-shaped closure entry,
  #   classified native_self_contained (the only state that needs no real
  #   network digest check, matching this whole spec's network-free
  #   constraint)
  def self_contained_entry(name, version)
    { name: name, version: version, runtime_dependencies: [],
      classification: Ruby4Lich5::Classification.new(
        state: :native_self_contained, gem_name: name, gem_version: version,
        reason: 'fixture', platform_asset: nil, msys2_packages: ['fixture-pkg']
      ) }
  end

  # @return [Hash] a {ResolutionLock#initialize}-shaped closure entry,
  #   classified ruby_bundled -- never staged, no artifact
  def bundled_entry(name, version)
    { name: name, version: version, runtime_dependencies: [],
      classification: Ruby4Lich5::Classification.new(
        state: :ruby_bundled, gem_name: name, gem_version: version,
        reason: 'fixture', platform_asset: nil, msys2_packages: nil
      ) }
  end

  # Writes a real, valid ResolutionLock's own #to_h JSON to +path+ -- the
  # CLI's only source of root names, ruby_abi, platform, and delivery
  # states (2026-07-13 audit finding: the old CSV-args boundary let a
  # dispatch string disagree with what was actually resolved/staged; a real
  # lock structurally can't).
  def write_lock_json(path, requested_root_names, version: '1.0.0', platform: 'x64-mingw-ucrt')
    requested_roots = requested_root_names.to_h { |name| [name, version] }
    closure = requested_root_names.map { |name| self_contained_entry(name, version) }
    lock = Ruby4Lich5::ResolutionLock.new(
      ruby_installer_version: '4.0.5-1', platform: platform, requested_roots: requested_roots, closure: closure,
      registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}"
    )
    File.write(path, JSON.pretty_generate(lock.to_h))
  end

  around do |example|
    Dir.mktmpdir('generate-gem-manifest-cli-spec-') do |root|
      @pkg_dir = File.join(root, 'pkg')
      @bin_dir = File.join(root, 'bin')
      @lock_path = File.join(root, 'resolution-lock.json')
      @out_path = File.join(root, 'manifest.json')
      FileUtils.mkdir_p(@pkg_dir)
      FileUtils.mkdir_p(@bin_dir)
      example.run
    end
  end

  def run_cli(args)
    cli_path = File.expand_path('../../bin/generate_gem_manifest.rb', __dir__)
    env = { 'PATH' => "#{@bin_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', nil)}" }
    Open3.capture2e(env, 'ruby', cli_path, *args)
  end

  it 'generates a real manifest from a real lock and real staged .gem files via a real subprocess' do
    all_native = Ruby4Lich5::GemManifestGenerator::GTK3_STACK + %w[sqlite3]
    all_native.each { |name| build_real_gem(@pkg_dir, name, '1.0.0') }
    write_fake_gh(@bin_dir, @pkg_dir, all_native.to_h { |name| [name, '1.0.0'] })
    write_lock_json(@lock_path, all_native)

    args = [@lock_path, 'elanthia-online/Ruby4Lich5', 'R4L5-gem-bundle-x64-mingw-ucrt-candidate',
            'R4L5-gem-bundle-x64-mingw-ucrt.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path]
    stdout_and_err, status = run_cli(args)

    expect(status).to be_success, "CLI failed: #{stdout_and_err}"
    expect(File.exist?(@out_path)).to be(true)

    manifest = JSON.parse(File.read(@out_path))
    units = manifest['targets'].first['units']
    expect(units.map { |u| u['id'] }).to contain_exactly('gtk3-runtime', 'sqlite3')

    sqlite3_unit = units.find { |u| u['id'] == 'sqlite3' }
    expect(sqlite3_unit['artifact']['archive']).to eq('gem')
    expected_digest = "sha256:#{Digest::SHA256.file(Dir.glob(File.join(@pkg_dir, 'sqlite3-*.gem')).first).hexdigest}"
    expect(sqlite3_unit['packages'].first['sha256']).to eq(expected_digest)

    # The bundle-artifact unit must carry *this run's own* tag (the
    # candidate passed on the command line), never a hardcoded live one --
    # the real bug this whole design fixes (2026-07-10 review finding).
    gtk3_unit = units.find { |u| u['id'] == 'gtk3-runtime' }
    expect(gtk3_unit['artifact']['url']).to start_with(
      'https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-gem-bundle-x64-mingw-ucrt-candidate/'
    )
  end

  it 'prepares immutable candidate native URLs and digests without calling gh' do
    names = Ruby4Lich5::GemManifestGenerator::GTK3_STACK + %w[ox curses]
    names.each do |name|
      build_real_gem(@pkg_dir, name, '1.0.0') { |spec| spec.platform = Gem::Platform.new('x64-mingw-ucrt') }
    end
    write_lock_json(@lock_path, names)
    # A subprocess attempting any legacy native digest lookup must fail.
    File.write(File.join(@bin_dir, 'gh'), "#!/bin/sh\nexit 99\n")
    FileUtils.chmod('+x', File.join(@bin_dir, 'gh'))
    tag = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1'
    args = [@lock_path, 'elanthia-online/Ruby4Lich5', tag, 'bundle.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path, tag]
    output, status = run_cli(args)
    expect(status).to be_success, output
    units = JSON.parse(File.read(@out_path)).fetch('targets').first.fetch('units')
    units.select { |unit| %w[ox curses].include?(unit['id']) }.each do |unit|
      expect(unit.dig('artifact', 'url')).to include("/releases/download/#{tag}/")
      expect(unit.fetch('packages').first.fetch('filename')).to eq(unit.dig('artifact', 'filename'))
      path = File.join(@pkg_dir, "#{unit['id']}-1.0.0-x64-mingw-ucrt.gem")
      expect(unit.dig('artifact', 'sha256')).to eq("sha256:#{Digest::SHA256.file(path).hexdigest}")
    end
    require 'ruby4lich5/gem_manifest_validator'
    expect(Ruby4Lich5::GemManifestValidator.validate!(JSON.parse(File.read(@out_path)))).to be(true)
  end

  it "derives the role map from the lock's own classifications, not any dispatch-string shape" do
    # Regression, 2026-07-13 audit finding: the old boundary threaded two
    # independently-derived CSV name lists through the CLI, which could
    # disagree with each other or with the workflow's own dispatch
    # defaults. Proves the new boundary has exactly one source -- swapping
    # the lock's own recorded delivery state for a name (never any CLI
    # argument) is what changes this unit's shape, since a lock built with
    # no classification other than native_self_contained cannot express a
    # different role at all; the assertion that matters is that units are
    # grouped and typed purely from #{@lock_path}'s own content.
    all_native = Ruby4Lich5::GemManifestGenerator::GTK3_STACK
    all_native.each { |name| build_real_gem(@pkg_dir, name, '1.0.0') }
    write_fake_gh(@bin_dir, @pkg_dir, all_native.to_h { |name| [name, '1.0.0'] })
    write_lock_json(@lock_path, all_native)

    args = [@lock_path, 'elanthia-online/Ruby4Lich5', 'R4L5-gem-bundle-x64-mingw-ucrt-candidate',
            'R4L5-gem-bundle-x64-mingw-ucrt.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path]
    stdout_and_err, status = run_cli(args)

    expect(status).to be_success, "CLI failed: #{stdout_and_err}"
    manifest = JSON.parse(File.read(@out_path))
    unit_ids = manifest['targets'].first['units'].map { |u| u['id'] }

    expect(unit_ids).to eq(['gtk3-runtime']) # exactly one unit, driven by the lock's own requested_roots
  end

  it 'exits nonzero and writes nothing when a declared root was never staged' do
    write_fake_gh(@bin_dir, @pkg_dir, {})
    write_lock_json(@lock_path, ['sqlite3']) # no gemspec ever built for sqlite3 in @pkg_dir

    args = [@lock_path, 'elanthia-online/Ruby4Lich5', 'R4L5-gem-bundle-x64-mingw-ucrt-candidate',
            'R4L5-gem-bundle-x64-mingw-ucrt.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path]
    _stdout_and_err, status = run_cli(args)

    expect(status).not_to be_success
    expect(File.exist?(@out_path)).to be(false)
  end

  it 'excludes a ruby_bundled requested root entirely, rather than crashing looking for its staged file' do
    # CodeRabbit finding, 2026-07-13: a requested root that itself
    # classifies ruby_bundled (never staged, no artifact) previously
    # reached InstalledGemClosure as if it were a real staged member,
    # which would raise MissingSpecError -- or, if that were patched
    # without also filtering GemManifestGenerator's own root_names,
    # GemUnitGrouper::ArgumentError instead (a root absent from the
    # resolved closure). Neither should happen; it should simply be
    # omitted, exactly like any other ruby_bundled closure member.
    all_native = Ruby4Lich5::GemManifestGenerator::GTK3_STACK + %w[sqlite3]
    all_native.each { |name| build_real_gem(@pkg_dir, name, '1.0.0') }
    write_fake_gh(@bin_dir, @pkg_dir, all_native.to_h { |name| [name, '1.0.0'] })

    requested_roots = all_native.to_h { |name| [name, '1.0.0'] }.merge('webrick' => '1.9.1')
    closure = all_native.map { |name| self_contained_entry(name, '1.0.0') } + [bundled_entry('webrick', '1.9.1')]
    lock = Ruby4Lich5::ResolutionLock.new(
      ruby_installer_version: '4.0.5-1', platform: 'x64-mingw-ucrt', requested_roots: requested_roots, closure: closure,
      registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}"
    )
    File.write(@lock_path, JSON.pretty_generate(lock.to_h))

    args = [@lock_path, 'elanthia-online/Ruby4Lich5', 'R4L5-gem-bundle-x64-mingw-ucrt-candidate',
            'R4L5-gem-bundle-x64-mingw-ucrt.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path]
    stdout_and_err, status = run_cli(args)

    expect(status).to be_success, "CLI failed: #{stdout_and_err}"
    unit_ids = JSON.parse(File.read(@out_path))['targets'].first['units'].map { |u| u['id'] }
    expect(unit_ids).to contain_exactly('gtk3-runtime', 'sqlite3') # 'webrick' never gets a unit at all
  end

  it 'generates a manifest when a staged gem depends on an unstaged ruby_bundled gem' do
    all_native = Ruby4Lich5::GemManifestGenerator::GTK3_STACK + ['ox']
    all_native.each do |name|
      build_real_gem(@pkg_dir, name, '1.0.0') do |spec|
        spec.add_runtime_dependency('bigdecimal', '>= 3.0') if name == 'ox'
      end
    end
    write_fake_gh(@bin_dir, @pkg_dir, all_native.to_h { |name| [name, '1.0.0'] })
    closure = all_native.map { |name| self_contained_entry(name, '1.0.0') }
    closure.find { |entry| entry[:name] == 'ox' }[:runtime_dependencies] = [
      { name: 'bigdecimal', requirement: Gem::Requirement.new('>= 3.0') }
    ]
    closure.unshift(bundled_entry('bigdecimal', '4.0.1'))
    lock = Ruby4Lich5::ResolutionLock.new(
      ruby_installer_version: '4.0.9-1', platform: 'x64-mingw-ucrt',
      requested_roots: all_native.to_h { |name| [name, '1.0.0'] }, closure: closure,
      registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}"
    )
    File.write(@lock_path, JSON.pretty_generate(lock.to_h))

    output, status = run_cli([@lock_path, 'elanthia-online/Ruby4Lich5', 'candidate',
                              'bundle.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path])

    expect(status).to be_success, "CLI failed: #{output}"
    units = JSON.parse(File.read(@out_path))['targets'].first['units']
    expect(units.flat_map { |unit| unit['packages'].map { |package| package['name'] } }).to match_array(all_native)
    expect(units.find { |unit| unit['id'] == 'ox' }['install_order']).to eq(['ox'])
  end

  it 'generates a runtime manifest without locked but unstaged build tooling' do
    names = Ruby4Lich5::GemManifestGenerator::GTK3_STACK + ['ox']
    names.each do |name|
      build_real_gem(@pkg_dir, name, '1.0.0') do |spec|
        spec.add_runtime_dependency('pkg-config', '>= 1.0') if name == 'glib2'
      end
    end
    write_fake_gh(@bin_dir, @pkg_dir, names.to_h { |name| [name, '1.0.0'] })
    closure = names.map { |name| self_contained_entry(name, '1.0.0') }
    closure.find { |entry| entry[:name] == 'glib2' }[:runtime_dependencies] = [
      { name: 'pkg-config', requirement: Gem::Requirement.new('>= 1.0') }
    ]
    closure.unshift(self_contained_entry('pkg-config', '1.5.8'))
    lock = Ruby4Lich5::ResolutionLock.new(
      ruby_installer_version: '4.0.9-1', platform: 'x64-mingw-ucrt',
      requested_roots: names.to_h { |name| [name, '1.0.0'] }, closure: closure,
      registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}"
    )
    File.write(@lock_path, JSON.pretty_generate(lock.to_h))
    output, status = run_cli([@lock_path, 'elanthia-online/Ruby4Lich5', 'candidate',
                              'bundle.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path])
    expect(status).to be_success, output
    units = JSON.parse(File.read(@out_path))['targets'].first['units']
    expect(units.flat_map { |unit| unit['packages'].map { |package| package['name'] } }).to match_array(names)
  end

  it 'exits with code 2 and writes nothing when the lock file is malformed' do
    File.write(@lock_path, 'not valid json')

    args = [@lock_path, 'elanthia-online/Ruby4Lich5', 'R4L5-gem-bundle-x64-mingw-ucrt-candidate',
            'R4L5-gem-bundle-x64-mingw-ucrt.zip', "sha256:#{'c' * 64}", @pkg_dir, @out_path]
    _stdout_and_err, status = run_cli(args)

    expect(status.exitstatus).to eq(2)
    expect(File.exist?(@out_path)).to be(false)
  end
end
