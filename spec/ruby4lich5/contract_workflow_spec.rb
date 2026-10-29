# frozen_string_literal: true

require 'yaml'
require 'ruby4lich5/known_native_gems'
require 'ruby4lich5/smoke_contract'
require 'ruby4lich5/gem_manifest_generator'

RSpec.describe 'Shared runtime contract wiring' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:workflow) { YAML.safe_load_file(File.join(root, '.github/workflows/ruby4-bundled-gems-suite.yml'), aliases: true) }
  let(:jobs) { workflow.fetch('jobs') }
  let(:build) { jobs.fetch('build_ruby4_bundled_gems_suite') }
  let(:registry) { Ruby4Lich5::KnownNativeGems.registry }

  it 'requires an explicit candidate commit and verifies the checkout before resolution' do
    steps = build.fetch('steps')
    selected = steps.find { |step| step.dig('with', 'repository') == 'elanthia-online/lich-5' }
    expect(selected.dig('with', 'ref')).to eq('${{ inputs.lich5-commit }}')
    actual = steps.index { |step| step['name'] == 'Verify candidate source identity' }
    resolve = steps.index { |step| step['name'] == 'Derive dynamic bundle resolution (lock + MSYS2 package list)' }
    expect(actual).to be < resolve
    expect(steps[actual].fetch('run')).to include('git -C contract-source rev-parse HEAD', '-cne $env:LICH5_COMMIT')
  end

  it 'captures the pristine inventory before resolving or installing application gems' do
    steps = build.fetch('steps')
    inventory = steps.index { |step| step['name'] == 'Capture pristine target RubyInstaller inventory' }
    resolve = steps.index { |step| step['name'] == 'Derive dynamic bundle resolution (lock + MSYS2 package list)' }
    expect(inventory).to be < resolve
    expect(steps[resolve].fetch('run')).to include('$env:LICH5_COMMIT', '$env:RUBY_INVENTORY', '$env:VERSION_OVERRIDES')
  end

  it 'has one configured Ruby version and relays it to smoke instead of a blank dispatch default' do
    target = JSON.parse(File.read(File.join(root, 'config/target-ruby.json')))
    expect(File.read(File.join(root, '.ruby-version')).strip).to eq(target.fetch('ruby_installer_version').split('-').first)
    expect(jobs.fetch('smoke_ruby4_bundled_gems_suite').dig('env', 'RUBY_INSTALLER_VERSION')).to eq('${{ needs.build_ruby4_bundled_gems_suite.outputs.ruby-installer-version }}')
  end

  it 'takes GTK preparation and grouping from the same ordered registry roles' do
    expect(registry.names_for_role('gtk')).to eq(Ruby4Lich5::GemManifestGenerator::GTK3_STACK)
    expect(registry.names_for_role('repack')).to match_array(%w[ox curses])
    expect(registry.smoke_definitions.keys).to include(*registry.bundle_default_roots)
  end

  it 'checks override eligibility before the first candidate upload' do
    steps = jobs.fetch('publish_ruby4_bundled_gems_suite').fetch('steps')
    prepare = steps.find { |step| step['name'] == 'Prepare candidate assets and manifest' }.fetch('run')
    expect(prepare).to include('bin/require_runtime_contract.rb', 'Restore-UpstreamGemPackages', '$upstream -cnotcontains $_.Name')
  end

  it 'pins GTK source by full commit and verifies its digest before extraction' do
    script = build.fetch('steps').filter_map { |step| step['run'] }.join("\n")
    expect(script).to include('codeload.github.com/ruby-gnome/ruby-gnome/zip/$env:GTK_SOURCE_COMMIT', '-ExpectedDigest $env:GTK_SOURCE_DIGEST')
    expect(script).not_to include('archive/refs/tags/')
    expect(script).not_to match(/& \$(?:env:GEM_EXE|gemExe) fetch /)
  end

  it 'checks accepted live recovery and attests the exact installer contract' do
    installer = File.read(File.join(root, '.github/workflows/build-ruby4lich5-installer.yaml'))
    expect(installer).to include('bin/check_ruby_inventory.rb', 'bin/fetch_contract_document.rb', 'bin/record_installer_contract.rb')
    expect(installer).not_to include('bin/check_installer_inventory.rb manifest/R4L5-gem-manifest.json')
  end
end
