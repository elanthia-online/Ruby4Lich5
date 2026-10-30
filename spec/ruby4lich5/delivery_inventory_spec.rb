# frozen_string_literal: true

require 'ruby4lich5/sqlite3_recovery_update'
require 'ruby4lich5/installer_inventory_check'
require 'ruby4lich5/classification'
require 'tmpdir'
require 'fileutils'
require 'rubygems/user_interaction'
require 'open3'

RSpec.describe 'P1 recovery preparation and installer inventory' do
  def build_gem(name, version, abi: '4.0')
    spec = Gem::Specification.new(name, version) do |item|
      item.summary = 'fixture'
      item.authors = ['fixture']
      item.platform = Gem::Platform.new('x64-mingw-ucrt')
      item.files = []
    end
    if name == 'sqlite3'
      path = "lib/sqlite3/#{abi}/sqlite3_native.so"
      FileUtils.mkdir_p(File.dirname(File.join(@pkg_dir, path)))
      File.write(File.join(@pkg_dir, path), 'fixture extension bytes, never executed')
      spec.files = [path]
    end
    filename = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Dir.chdir(@pkg_dir) { Gem::Package.build(spec) }
    end
    File.join(@pkg_dir, filename)
  end

  def manifest_unit(name, version, path)
    filename = File.basename(path)
    digest = "sha256:#{Digest::SHA256.file(path).hexdigest}"
    {
      'id' => name, 'members' => [name],
      'artifact' => { 'url' => "https://rubygems.org/downloads/#{filename}", 'filename' => filename, 'sha256' => digest, 'archive' => 'gem' },
      'packages' => [{ 'name' => name, 'version' => version, 'filename' => filename, 'sha256' => digest }],
      'install_order' => [name]
    }
  end

  def write_lock(versions = { 'sqlite3' => '2.10.2', 'ox' => '1.0.0' })
    closure = versions.map do |name, version|
      { name: name, version: version, runtime_dependencies: [],
        classification: Ruby4Lich5::Classification.new(
          state: :native_self_contained, gem_name: name, gem_version: version,
          reason: 'fixture', platform_asset: nil, msys2_packages: ['fixture-pkg']
        ) }
    end
    lock = Ruby4Lich5::ResolutionLock.new(
      ruby_installer_version: '4.0.9-1', platform: 'x64-mingw-ucrt', requested_roots: versions, closure: closure,
      registry_commit_sha: 'a' * 40, registry_content_digest: "sha256:#{'b' * 64}"
    )
    File.write(File.join(@pkg_dir, 'resolution-lock.json'), JSON.generate(lock.to_h))
  end

  around do |example|
    Dir.mktmpdir('delivery-inventory-') do |directory|
      @pkg_dir = directory
      @sqlite_path = build_gem('sqlite3', '2.10.2')
      ox_path = build_gem('ox', '1.0.0')
      # Package construction leaves its source tree; the installer gate reads only gems.
      @manifest = { 'schema' => 1, 'targets' => [{ 'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt', 'units' => [
        manifest_unit('sqlite3', '2.10.2', @sqlite_path), manifest_unit('ox', '1.0.0', ox_path)
      ] }] }
      @versions = [{ 'number' => '2.10.2', 'platform' => 'x64-mingw-ucrt', 'sha' => Digest::SHA256.file(@sqlite_path).hexdigest }]
      write_lock
      example.run
    end
  end

  def prepare
    Ruby4Lich5::Sqlite3RecoveryUpdate.prepare(manifest: @manifest, gem_path: @sqlite_path, versions: @versions)
  end

  def check_installer
    Ruby4Lich5::InstallerInventoryCheck.validate!(manifest: @manifest, pkg_dir: @pkg_dir)
  end

  it 'checks only applicable current installer packages while retaining legacy and obsolete recovery closures' do
    path = File.join(@pkg_dir, 'resolution-lock.json')
    lock_data = JSON.parse(File.read(path))
    contract = { 'schema' => 1, 'lich5_commit' => 'a' * 40, 'lich_version' => '5.24.0',
                 'gemfile_sha256' => 'b' * 64, 'lock_sha256' => 'c' * 64, 'reader_sha256' => 'd' * 64,
                 'promotable' => true, 'overrides' => {}, 'ruby_installer_version' => '4.0.9-1',
                 'ruby_inventory' => { 'ruby_version' => '4.0.9', 'platform' => 'x64-mingw-ucrt', 'ruby_abi' => '4.0', 'gems' => {} },
                 'expected_packages' => %w[sqlite3 ox].to_h { |name| [name, { 'version' => name == 'ox' ? '1.0.0' : '2.10.2', 'dependencies' => {} }] } }
    lock_data['contract'] = contract
    File.write(path, JSON.generate(lock_data))
    target = @manifest.fetch('targets').first
    target['contract'] = contract
    current = target.fetch('units').find { |unit| unit['id'] == 'ox' }
    legacy = Marshal.load(Marshal.dump(current))
    legacy.fetch('packages').first['version'] = '0.9.0'
    current['id'] = 'ox-ranged'
    current['lich_versions'] = { 'min_inclusive' => '5.24.0' }
    target.fetch('units').unshift(legacy)
    obsolete = Marshal.load(Marshal.dump(legacy))
    obsolete['id'] = 'retired'
    obsolete['members'] = ['retired']
    obsolete['install_order'] = ['retired']
    obsolete.fetch('packages').first['name'] = 'retired'
    obsolete['lifecycle'] = { 'state' => 'obsolete' }
    target.fetch('units') << obsolete
    expect(check_installer).to be(true)
  end

  it 'changes only the sqlite3 unit to the original RubyGems file, preserving order and input' do
    original = @manifest.fetch('targets').first.fetch('units').first
    original['packages'].first['version'] = '2.10.1'
    before = JSON.generate(@manifest)
    result = prepare
    expect(JSON.generate(@manifest)).to eq(before)
    expect(result.fetch('targets').first.fetch('units').last).to eq(@manifest.fetch('targets').first.fetch('units').last)
    unit = result.fetch('targets').first.fetch('units').first
    expect(unit['id']).to eq('sqlite3')
    expect(unit.dig('artifact', 'url')).to eq('https://rubygems.org/downloads/sqlite3-2.10.2-x64-mingw-ucrt.gem')
    expect(unit.dig('artifact', 'sha256')).to eq("sha256:#{@versions.first.fetch('sha')}")
    expect(unit.fetch('packages').first.fetch('version')).to eq('2.10.2')
  end

  it 'rejects RubyGems metadata digest mismatch' do
    @versions.first['sha'] = 'a' * 64
    expect { prepare }.to raise_error(ArgumentError, /differs from RubyGems/)
  end

  it 'prepares and validates the SQLite manifest through the offline CLI' do
    input = File.join(@pkg_dir, 'input.json')
    metadata = File.join(@pkg_dir, 'versions.json')
    output = File.join(@pkg_dir, 'R4L5-gem-manifest.json')
    File.write(input, JSON.generate(@manifest))
    File.write(metadata, JSON.generate(@versions))
    script = File.expand_path('../../bin/prepare_sqlite3_recovery.rb', __dir__)
    text, status = Open3.capture2e(RbConfig.ruby, script, input, @sqlite_path, metadata, output)
    expect(status).to be_success, text
    expect(JSON.parse(File.read(output))).to eq(prepare)
  end

  it 'rejects missing target ABI even with matching upstream digest' do
    # Rebuild from only the old ABI contents, rather than leaving the previous source path.
    FileUtils.rm_rf(File.join(@pkg_dir, 'lib/sqlite3/4.0'))
    @sqlite_path = build_gem('sqlite3', '2.10.2', abi: '3.4')
    @versions.first['sha'] = Digest::SHA256.file(@sqlite_path).hexdigest
    expect { prepare }.to raise_error(ArgumentError, /Ruby 4.0 extension/)
  end

  it 'refuses an update that would leave sqlite3 selectable through another unit' do
    units = @manifest.fetch('targets').first.fetch('units')
    units << JSON.parse(JSON.generate(units.first))
    expect { prepare }.to raise_error(ArgumentError, /exactly one single-member/)
  end

  it 'accepts an installer with the approved versions, exact lock and Windows sqlite3 ABI' do
    expect(check_installer).to be(true)
  end

  it 'rejects different package bytes even when every accepted version matches' do
    @manifest.fetch('targets').first.fetch('units').last.fetch('packages').first['sha256'] = "sha256:#{'0' * 64}"
    expect { check_installer }.to raise_error(ArgumentError, /package bytes differ/)
  end

  it 'rejects an old accepted manifest rather than allowing a vulnerable installer bake' do
    @manifest.fetch('targets').first.fetch('units').first.fetch('packages').first['version'] = '2.10.1'
    expect { check_installer }.to raise_error(ArgumentError, /at least 2.10.2/)
  end

  it 'rejects unrelated latest-version drift' do
    FileUtils.rm(File.join(@pkg_dir, 'ox-1.0.0-x64-mingw-ucrt.gem'))
    build_gem('ox', '1.1.0')
    expect { check_installer }.to raise_error(ArgumentError, /ox: accepted "1.0.0", staged "1.1.0"/)
  end

  it 'rejects omitted, additional or duplicate gem packages' do
    build_gem('extra', '1.0.0')
    expect { check_installer }.to raise_error(ArgumentError, /extra: accepted nil/)
    FileUtils.rm(File.join(@pkg_dir, 'extra-1.0.0-x64-mingw-ucrt.gem'))
    build_gem('ox', '1.1.0')
    expect { check_installer }.to raise_error(ArgumentError, /duplicate staged gem ox/)
    FileUtils.rm(Dir.glob(File.join(@pkg_dir, 'ox-*.gem')))
    expect { check_installer }.to raise_error(ArgumentError, /ox: accepted "1.0.0", staged nil/)
  end

  it 'rejects a lock that describes different versions than its actual gems' do
    write_lock('sqlite3' => '2.10.2', 'ox' => '1.1.0')
    expect { check_installer }.to raise_error(ArgumentError, /differs from resolution lock/)
  end

  it 'accepts locked build tooling omitted by the factory from the runtime bundle' do
    write_lock('sqlite3' => '2.10.2', 'ox' => '1.0.0', 'pkg-config' => '1.5.8', 'native-package-installer' => '1.1.9')
    expect(check_installer).to be(true)
  end

  it 'does not allow a missing runtime member just because build tooling is omitted' do
    write_lock('sqlite3' => '2.10.2', 'ox' => '1.0.0', 'pkg-config' => '1.5.8', 'runtime-extra' => '1.0.0')
    expect { check_installer }.to raise_error(ArgumentError, /differs from resolution lock/)
  end

  it 'rejects build tooling accidentally staged for delivery' do
    write_lock('sqlite3' => '2.10.2', 'ox' => '1.0.0', 'pkg-config' => '1.5.8')
    path = build_gem('pkg-config', '1.5.8')
    @manifest.fetch('targets').first.fetch('units') << manifest_unit('pkg-config', '1.5.8', path)
    expect { check_installer }.to raise_error(ArgumentError, /differs from resolution lock/)
  end
end
