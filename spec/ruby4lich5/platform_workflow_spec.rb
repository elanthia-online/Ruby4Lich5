# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative '../support/x64_workflow_snapshot'

RSpec.describe 'Platform-parameterized workflows' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:workflows) { X64WorkflowSnapshot::WORKFLOWS.to_h { |name| [name, YAML.load_file(File.join(root, '.github/workflows', name))] } }
  let(:platform_readers) do
    %w[platform-table.ps1 gem-bundle-artifact.ps1 accepted-gem-manifest.ps1 prepare-gem-promotion.ps1 gem-manifest-promotion.ps1
       gem-candidate-publication.ps1 gem-candidate-bundle.ps1 frozen-gtk.ps1]
  end

  # Drops a GEM_PLATFORM the pre-R3 value lacked, after checking it is x64,
  # then any step entry left with nothing platform-dependent but its name.
  def without_added_platform(expected, actual)
    actual.each do |name, workflow|
      workflow.fetch('jobs').each do |id, job|
        before = expected.dig(name, 'jobs', id)
        next unless before

        if job['env']&.key?('GEM_PLATFORM') && !before.fetch('env').key?('GEM_PLATFORM')
          expect(job['env'].delete('GEM_PLATFORM')).to eq('x64-mingw-ucrt')
        end
        job.fetch('steps').each do |step|
          prior = before.fetch('steps').find { |item| item['name'] == step['name'] }
          next unless step.dig('env', 'GEM_PLATFORM') && !prior&.dig('env', 'GEM_PLATFORM')

          expect(step['env'].delete('GEM_PLATFORM')).to eq('x64-mingw-ucrt')
          step.delete('env') if step['env'].empty?
        end
        job['steps'].reject! { |step| step.keys == ['name'] }
      end
    end
  end

  it 'evaluates every x64 name, runner, group, MSYS2 setting, env and artifact exactly as before the table' do
    expected = JSON.parse(File.read(File.join(root, 'spec/fixtures/platform-table/x64-workflow-snapshot.json')))
    actual = JSON.parse(JSON.generate(X64WorkflowSnapshot.capture(root)))
    without_added_platform(expected, actual)
    expect(actual).to eq(expected)
    # Spot-check the identities other workflows and scripts key off.
    suite = expected.fetch('ruby4-bundled-gems-suite.yml').fetch('jobs')
    expect(suite.dig('publish_ruby4_bundled_gems_suite', 'concurrency', 'group')).to eq('publish-ruby4-bundled-gems-suite-x64-mingw-ucrt')
    expect(suite.dig('smoke_ruby4_bundled_gems_suite', 'name')).to eq('Smoke packaged Ruby4 bundled gems suite (windows-ucrt64)')
    expect(expected.dig('promote-gem-candidate.yml', 'concurrency', 'group')).to eq('gem-manifest-promotion-x64-mingw-ucrt')
  end

  it 'evaluates the parameterized values from the selected row rather than from x64 literals' do
    row = Ruby4Lich5::TargetPlatform.new('demo-mingw-ucrt', {
      'rubyinstaller_asset_suffix' => 'demo', 'runner' => 'demo-runner', 'msystem' => 'DEMO64', 'msys2_prefix' => 'demo64',
      'msys2_package_prefix' => 'mingw-w64-demo', 'msys2_bootstrap_packages' => ['base-devel'],
      'toolchain' => { 'cc' => 'cc.exe', 'make' => 'make.exe', 'pkg_config' => 'pkgconf.exe', 'objdump' => 'dump.exe' },
      'gem_bundle_tag' => 'R4L5-gem-bundle-demo-mingw-ucrt'
    })
    demo = workflows.to_h { |name, data| [name, X64WorkflowSnapshot.workflow(data, row)] }
    text = JSON.generate(demo.slice('ruby4-bundled-gems-suite.yml', 'msys2-package-list-diagnostic.yml', 'rubyinstaller-provenance.yml'))
    expect(text).not_to match(/x64|ucrt64|UCRT64|windows-latest/)
    suite = demo.fetch('ruby4-bundled-gems-suite.yml').fetch('jobs')
    expect(suite.dig('publish_ruby4_bundled_gems_suite', 'concurrency', 'group')).to eq('publish-ruby4-bundled-gems-suite-demo-mingw-ucrt')
    expect(suite.dig('build_ruby4_bundled_gems_suite', 'runs-on')).to eq('demo-runner')
    expect(JSON.generate(suite)).to include('ruby4-bundled-gems-windows-demo64', 'rubyinstaller-$rubyInstallerVersion-demo.7z', 'releases/download/R4L5-gem-bundle-demo-mingw-ucrt/')
    promotion = demo.fetch('promote-gem-candidate.yml')
    expect(promotion.dig('concurrency', 'group')).to eq('gem-manifest-promotion-demo-mingw-ucrt')
    expect(promotion.dig('jobs', 'recover', 'runs-on')).to eq('demo-runner')
    # inspect and promote only handle release state on the x64 host.
    expect(promotion.dig('jobs', 'inspect', 'runs-on')).to eq('windows-latest')
    installer = demo.fetch('build-ruby4lich5-installer.yaml').fetch('jobs')
    expect(installer.dig('build_installer', 'runs-on')).to eq('demo-runner')
    expect(JSON.generate(installer.fetch('build_installer'))).to include('ruby4-bundled-gems-windows-demo64', 'rubyinstaller-$env:RUBY_INSTALLER_VERSION-demo.exe')
    # The draft lock stays the coordinator's literal x64 group until R8/R10.
    expect(installer.dig('draft_release', 'concurrency', 'group')).to eq('gem-manifest-promotion-x64-mingw-ucrt')
  end

  it 'adds an optional platform input whose default keeps existing dispatches on x64' do
    workflows.except('validate-novel-gem.yml').each_value do |data|
      input = data.fetch(true).fetch('workflow_dispatch').fetch('inputs').fetch('platform')
      expect(input.fetch('default')).to eq('x64-mingw-ucrt')
      expect(input.fetch('required', false)).to be(false)
      expect(input.fetch('type', 'string')).to eq('string')
    end
    expect(workflows.fetch('validate-novel-gem.yml').dig(true, 'workflow_dispatch', 'inputs')).not_to have_key('platform')
    expect(Ruby4Lich5::TargetPlatform.select('x64-mingw-ucrt').name).to eq(JSON.parse(File.read(File.join(root, 'config/target-ruby.json'))).fetch('platform'))
  end

  it 'validates the input with the shared platform-table reader before any platform-dependent job' do
    action = YAML.load_file(File.join(root, '.github/actions/select-target-platform/action.yml'))
    expect(action.dig('runs', 'steps').size).to eq(1)
    step = action.dig('runs', 'steps').first
    expect(step.fetch('shell')).to eq('pwsh')
    expect(step.dig('env', 'PLATFORM_INPUT')).to eq('${{ inputs.platform }}')
    expect(step.fetch('run')).to include("'platform-table.ps1'", 'Get-TargetPlatform -Platform $env:PLATFORM_INPUT', '"GEM_PLATFORM=$($row.name)"')
    expect(step.fetch('run')).not_to include('${{')
    expect(action.fetch('outputs').keys).to match_array(X64WorkflowSnapshot.action_outputs(Ruby4Lich5::TargetPlatform.current).keys)
    action.fetch('outputs').each { |key, output| expect(output.fetch('value')).to eq("${{ steps.row.outputs.#{key} }}") }
    workflows.except('validate-novel-gem.yml').each do |name, data|
      selections = data.fetch('jobs').values.flat_map { |job| job.fetch('steps') }.select { |item| item['uses'] == X64WorkflowSnapshot::ACTION }
      expect(selections.size).to eq(1), name
      expect(selections.first.dig('with', 'platform')).to eq('${{ inputs.platform }}')
    end
  end

  # Without GEM_PLATFORM the helpers silently fall back to target-ruby.json's
  # x64, which an x64 comparison can never catch.
  it 'hands the validated platform to every step that runs platform-reading repository code' do
    workflows.except('validate-novel-gem.yml').each do |name, data|
      data.fetch('jobs').each do |id, job|
        selected = false
        job.fetch('steps').each do |step|
          selected ||= step['uses'] == X64WorkflowSnapshot::ACTION
          run = step['run'].to_s
          bins = run.scan(%r{bin[/\\](\w+\.rb)}).flatten.select { |file| File.read(File.join(root, 'bin', file)).include?("require_relative '../lib/") }
          next if bins.empty? && platform_readers.none? { |file| run.include?(file) }

          value = step.dig('env', 'GEM_PLATFORM') || job.dig('env', 'GEM_PLATFORM')
          expect(selected || value).to be_truthy, "#{name} #{id} #{step['name']}"
          expect(value).to match(/\A\$\{\{ needs\.\w+\.outputs\.platform \}\}\z/), "#{name} #{id} #{step['name']}" unless selected
        end
      end
    end
  end
end
