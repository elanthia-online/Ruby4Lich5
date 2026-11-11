# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'ruby4lich5/contract_planner'
require 'ruby4lich5/curated_gem_registry'
require 'ruby4lich5/default_root_selection'
require 'ruby4lich5/msys2_bootstrap'
require 'ruby4lich5/promotion_plan'
require 'ruby4lich5/runtime_contract'
require 'ruby4lich5/sqlite3_recovery_update'

# The x64-mingw-ucrt values the platform-table refactor touches, computed
# from whatever +lib/+ is first on the load path and whatever +bin/+ and
# +config/+ live under +root+. The committed golden
# (spec/fixtures/platform-table/x64-snapshot.json) was produced by running
# this same module against a checkout of the pre-refactor tree, so the
# spec comparing it to the current tree proves equality with that tree
# rather than restating the table's own constants.
#
# Not captured here:
# - the platform ContractPlanner.plan threads into the build-tooling
#   classifier and BuildPlanner#plan_for (covered separately in
#   spec/ruby4lich5/runtime_contract_spec.rb);
# - the GTK/curses seed list derived by bin/derive_curated_gems_seed.rb;
# - the target-platform gate in bin/capture_ruby_inventory.rb.
module X64PlatformSnapshot
  CANDIDATE_TAGS = %w[
    R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1
    R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-45
    R4L5-gem-bundle-x64-mingw-ucrt-candidate-0-1
    R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-0
    R4L5-gem-bundle-x64-mingw-ucrt-candidate-1
    R4L5-gem-bundle-x64-mingw-ucrt
    R4L5-gem-bundle-x64-mingw-ucrtXcandidate-1-1
    R4L5-gem-bundle-aarch64-mingw-ucrt-candidate-1-1
    R4L5-gem-bundle-x64-mingw32-candidate-1-1
    r4l5-gem-bundle-x64-mingw-ucrt-candidate-1-1
    R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1-extra
  ].freeze

  PLATFORMS = %w[ruby x64-mingw-ucrt aarch64-mingw-ucrt x64-mingw32 x86-mingw32 java].freeze

  def self.capture(root)
    registry = Ruby4Lich5::CuratedGemRegistry.load_file(File.join(root, 'config', 'curated-gems.json'))
    {
      'default_root_selection_platform'       => Ruby4Lich5::DefaultRootSelection::PLATFORM,
      'curated_gem_registry_current_platform' => Ruby4Lich5::CuratedGemRegistry::CURRENT_PLATFORM,
      'sqlite3_recovery_update'               => { 'platform' => Ruby4Lich5::Sqlite3RecoveryUpdate::PLATFORM, 'filename' => Ruby4Lich5::Sqlite3RecoveryUpdate::FILENAME },
      'msys2_bootstrap_packages'              => Ruby4Lich5::Msys2Bootstrap::PACKAGES,
      'self_build_packages'                   => registry.instance_variable_get(:@gems).keys.sort.to_h { |name| [name, registry.self_build_packages_for(name)] },
      'derived_msys2_packages'                => derived_msys2_packages(root, registry),
      'promotion_candidate_tags'              => CANDIDATE_TAGS.to_h { |tag| [tag, promotion_accepts?(tag)] },
      'runtime_contract_inventory_platforms'  => PLATFORMS.to_h { |platform| [platform, contract_accepts?(inventory_platform: platform)] },
      'runtime_contract_package_platforms'    => PLATFORMS.to_h { |platform| [platform, contract_accepts?(package_platform: platform)] },
      'prepare_frozen_gtk'                    => frozen_gtk(root)
    }
  end

  # Mirrors bin/derive_dynamic_msys2_packages.rb's own union over the
  # committed default-root closure, the same selection
  # msys2_package_list_reviewed_delta_spec.rb uses.
  def self.derived_msys2_packages(root, registry)
    plan = JSON.parse(File.read(File.join(root, 'spec', 'fixtures', 'curated-gems-seed', 'resolved-plan.json')))
    names = plan.values.flatten(1).filter_map { |entry| entry.fetch('name') unless entry.fetch('classification').fetch('state') == 'ruby_bundled' }.uniq
    (Ruby4Lich5::Msys2Bootstrap::PACKAGES + names.flat_map { |name| registry.self_build_packages_for(name) || [] }).uniq.sort
  end

  def self.promotion_accepts?(tag)
    Ruby4Lich5::PromotionPlan.build(candidate_bytes: '{}', live_bytes: '{}', candidate_tag: tag, repository: 'owner/repo', assets: [], source_sha: 'a' * 40)
    true
  rescue ArgumentError => e
    raise unless e.message == 'invalid candidate identity'
    false
  rescue KeyError, JSON::ParserError
    true
  end

  def self.contract_accepts?(inventory_platform: 'x64-mingw-ucrt', package_platform: 'ruby')
    package = { 'version' => '1.0.0', 'platform' => package_platform, 'sha256' => 'b' * 64, 'dependencies' => {} }
    data = {
      'schema' => 2, 'lich5_commit' => 'a' * 40, 'gemfile_sha256' => 'c' * 64, 'lock_sha256' => 'd' * 64,
      'reader_sha256' => 'e' * 64, 'windows_contract_sha256' => 'f' * 64, 'overrides' => {}, 'promotable' => false,
      'ruby_installer_version' => '4.0.9-1', 'build_roles' => { 'gtk' => [] },
      'ruby_inventory' => { 'ruby_version' => '4.0.9', 'ruby_abi' => '4.0', 'platform' => inventory_platform, 'gems' => {} },
      'expected_packages' => { 'demo' => package }, 'locked_packages' => { 'demo' => package }
    }
    Ruby4Lich5::RuntimeContract.validate!(data, ruby_installer_version: '4.0.9-1')
  rescue Ruby4Lich5::RuntimeContract::Error
    false
  end

  # Runs the real CLI against a manifest whose decoy targets precede the
  # x64 one, so the captured unit shows which target the CLI selects.
  def self.frozen_gtk(root)
    Dir.mktmpdir('r4l5-platform-snapshot') do |directory|
      targets = [%w[4.0 aarch64-mingw-ucrt], %w[3.4 x64-mingw-ucrt], %w[4.0 x64-mingw-ucrt], %w[4.0 x64-mingw32]].map do |abi, platform|
        bytes = "#{abi} #{platform} gtk3 bytes"
        filename = "gtk3-#{abi}-#{platform}.gem"
        File.write(File.join(directory, filename), bytes)
        package = { 'name' => 'gtk3', 'version' => '1.0', 'filename' => filename, 'sha256' => "sha256:#{Digest::SHA256.hexdigest(bytes)}" }
        unit = { 'id' => 'gtk3-runtime', 'members' => ['gtk3'], 'packages' => [package], 'install_order' => ['gtk3'],
                 'artifact' => { 'url' => "https://example.test/#{filename}.zip", 'filename' => "#{filename}.zip", 'archive' => 'zip', 'sha256' => "sha256:#{'a' * 64}" } }
        { 'ruby_abi' => abi, 'platform' => platform, 'units' => [unit] }
      end
      manifest = File.join(directory, 'manifest.json')
      File.write(manifest, JSON.generate('schema' => 1, 'targets' => targets))
      output = File.join(directory, 'frozen')
      text, status = Open3.capture2e({ 'GEM_PLATFORM' => nil }, RbConfig.ruby, File.join(root, 'bin', 'prepare_frozen_gtk.rb'), manifest, directory, output)
      raise "prepare_frozen_gtk.rb failed: #{text}" unless status.success?
      { 'unit_json' => File.read(File.join(output, 'unit.json')), 'pkg' => Dir.children(File.join(output, 'pkg')).sort }
    end
  end
end
