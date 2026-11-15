# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'x64_platform_snapshot'

# The same values X64PlatformSnapshot captures, for whichever row
# +GEM_PLATFORM+ selected when +lib/+ was loaded (the constants are fixed at
# load, so a spec runs this in a subprocess). X64PlatformSnapshot itself stays
# x64-only: its frozen-GTK run unsets +GEM_PLATFORM+ and its contract probe
# defaults to an x64 inventory, and its golden must not move.
#
# Unlike the x64 golden, a golden captured here is captured from this tree:
# it pins the row's values against later drift, it does not prove equality
# with any earlier tree.
module PlatformSnapshot
  def self.candidate_tags(platform)
    X64PlatformSnapshot::CANDIDATE_TAGS.map { |tag| tag.sub('x64-mingw-ucrt', platform) }.push(
      'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1'
    ).uniq
  end

  def self.capture(root)
    platform = Ruby4Lich5::TargetPlatform.current.name
    registry = Ruby4Lich5::CuratedGemRegistry.load_file(File.join(root, 'config', 'curated-gems.json'))
    {
      'platform'                              => platform,
      'default_root_selection_platform'       => Ruby4Lich5::DefaultRootSelection::PLATFORM,
      'curated_gem_registry_current_platform' => Ruby4Lich5::CuratedGemRegistry::CURRENT_PLATFORM,
      'sqlite3_recovery_update'               => { 'platform' => Ruby4Lich5::Sqlite3RecoveryUpdate::PLATFORM, 'filename' => Ruby4Lich5::Sqlite3RecoveryUpdate::FILENAME },
      'msys2_bootstrap_packages'              => Ruby4Lich5::Msys2Bootstrap::PACKAGES,
      'self_build_packages'                   => registry.instance_variable_get(:@gems).keys.sort.to_h { |name| [name, registry.self_build_packages_for(name)] },
      'derived_msys2_packages'                => X64PlatformSnapshot.derived_msys2_packages(root, registry),
      'promotion_candidate_tags'              => candidate_tags(platform).to_h { |tag| [tag, X64PlatformSnapshot.promotion_accepts?(tag)] },
      'runtime_contract_inventory_platforms'  => X64PlatformSnapshot::PLATFORMS.to_h { |item| [item, X64PlatformSnapshot.contract_accepts?(inventory_platform: item, package_platform: 'ruby')] },
      'runtime_contract_package_platforms'    => X64PlatformSnapshot::PLATFORMS.to_h { |item| [item, X64PlatformSnapshot.contract_accepts?(inventory_platform: platform, package_platform: item)] },
      'prepare_frozen_gtk'                    => frozen_gtk(root, platform)
    }
  end

  # X64PlatformSnapshot.frozen_gtk with the selected platform handed to the
  # CLI: decoy targets for x64 and another ABI precede this row's target.
  def self.frozen_gtk(root, platform)
    Dir.mktmpdir('r4l5-platform-snapshot') do |directory|
      targets = [%w[4.0 x64-mingw-ucrt], ['3.4', platform], ['4.0', platform], %w[4.0 x64-mingw32]].uniq.map do |abi, target|
        bytes = "#{abi} #{target} gtk3 bytes"
        filename = "gtk3-#{abi}-#{target}.gem"
        File.write(File.join(directory, filename), bytes)
        package = { 'name' => 'gtk3', 'version' => '1.0', 'filename' => filename, 'sha256' => "sha256:#{Digest::SHA256.hexdigest(bytes)}" }
        unit = { 'id' => 'gtk3-runtime', 'members' => ['gtk3'], 'packages' => [package], 'install_order' => ['gtk3'],
                 'artifact' => { 'url' => "https://example.test/#{filename}.zip", 'filename' => "#{filename}.zip", 'archive' => 'zip', 'sha256' => "sha256:#{'a' * 64}" } }
        { 'ruby_abi' => abi, 'platform' => target, 'units' => [unit] }
      end
      manifest = File.join(directory, 'manifest.json')
      File.write(manifest, JSON.generate('schema' => 1, 'targets' => targets))
      output = File.join(directory, 'frozen')
      text, status = Open3.capture2e({ 'GEM_PLATFORM' => platform }, RbConfig.ruby, File.join(root, 'bin', 'prepare_frozen_gtk.rb'), manifest, directory, output)
      raise "prepare_frozen_gtk.rb failed: #{text}" unless status.success?
      { 'unit_json' => File.read(File.join(output, 'unit.json')), 'pkg' => Dir.children(File.join(output, 'pkg')).sort }
    end
  end

  # Runs {.capture} in a fresh Ruby with +GEM_PLATFORM+ set, so every
  # load-time constant reads that row.
  def self.capture_in_subprocess(root, platform)
    script = "require 'json'; require #{File.join(root, 'spec', 'support', 'platform_snapshot').inspect}; " \
             "print JSON.generate(PlatformSnapshot.capture(#{root.inspect}))"
    text, error, status = Open3.capture3({ 'GEM_PLATFORM' => platform }, RbConfig.ruby, '-I', File.join(root, 'lib'), '-e', script)
    raise "platform snapshot for #{platform} failed: #{error}" unless status.success?

    JSON.parse(text)
  end
end
