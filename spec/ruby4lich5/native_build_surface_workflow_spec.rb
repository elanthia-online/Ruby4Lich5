# frozen_string_literal: true

require 'yaml'
require 'ruby4lich5/target_platform'

# The suite's native build surface steps after the aarch64 row: the lane PATH
# filter reads the selected platform, and the probe and gate labels follow the
# row's compiler instead of a literal gcc.
RSpec.describe 'Suite native build surface' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:job) { YAML.load_file(File.join(root, '.github/workflows/ruby4-bundled-gems-suite.yml')).fetch('jobs').fetch('build_ruby4_bundled_gems_suite') }

  def step(name)
    job.fetch('steps').find { |item| item['name'] == name } || raise("missing step #{name}")
  end

  it 'filters the lane PATH through lane-path.ps1 for the selected platform' do
    expect(job.dig('env', 'GEM_PLATFORM')).to eq('${{ needs.select_platform.outputs.platform }}')
    run = step('Build sanitized PATH').fetch('run')
    expect(run).to include(". (Join-Path $env:GITHUB_WORKSPACE 'lane-path.ps1')",
                           'Select-LanePathEntry -Entries $orig -Platform $env:GEM_PLATFORM')
    expect(run).not_to include('Where-Object')
  end

  it 'labels the compiler probe and gate from the selected row' do
    run = step('Resolve native build surface').fetch('run')
    expect(run).to include('$ccName = [IO.Path]::GetFileNameWithoutExtension($env:R4L5_TOOLCHAIN_CC)',
                           'where.exe $ccName', '[ordered]@{ $ccName = $gcc;', 'Searched $ccName=$gcc;')
    expect(run).not_to match(/@\{ gcc = |Searched gcc=/)
    labels = Ruby4Lich5::TargetPlatform.load_table.transform_values { |row| File.basename(row.toolchain.fetch('cc'), '.exe') }
    expect(labels).to eq('x64-mingw-ucrt' => 'gcc', 'aarch64-mingw-ucrt' => 'clang')
  end
end
