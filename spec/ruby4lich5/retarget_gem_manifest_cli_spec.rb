# frozen_string_literal: true

require 'tmpdir'
require 'json'
require 'open3'

RETARGET_SPEC_CANDIDATE_TAG = 'R4L5-gem-bundle-x64-mingw-ucrt-candidate'
RETARGET_SPEC_LIVE_TAG = 'R4L5-gem-bundle-x64-mingw-ucrt'

RSpec.describe 'bin/retarget_gem_manifest.rb (CLI integration)' do
  def sample_manifest
    {
      'schema'  => 1,
      'targets' => [{
        'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt',
        'units' => [
          { 'id'       => 'gtk3-runtime',
            'artifact' => { 'url' => "https://github.com/elanthia-online/Ruby4Lich5/releases/download/#{RETARGET_SPEC_CANDIDATE_TAG}/R4L5-gem-bundle-x64-mingw-ucrt.zip",
                             'filename' => 'R4L5-gem-bundle-x64-mingw-ucrt.zip', 'sha256' => "sha256:#{'a' * 64}", 'archive' => 'zip' } },
          { 'id'       => 'sqlite3',
            'artifact' => { 'url' => 'https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-sqlite3-2.9.5-x64-mingw-ucrt/R4L5-sqlite3-2.9.5-x64-mingw-ucrt.gem',
                             'filename' => 'R4L5-sqlite3-2.9.5-x64-mingw-ucrt.gem', 'sha256' => "sha256:#{'b' * 64}", 'archive' => 'gem' } }
        ]
      }]
    }
  end

  around do |example|
    Dir.mktmpdir('retarget-gem-manifest-cli-spec-') do |dir|
      @input_path = File.join(dir, 'manifest.json')
      @output_path = File.join(dir, 'retargeted.json')
      File.write(@input_path, JSON.generate(sample_manifest))
      example.run
    end
  end

  def run_cli(*args)
    cli_path = File.expand_path('../../bin/retarget_gem_manifest.rb', __dir__)
    Open3.capture2e('ruby', cli_path, *args)
  end

  it "retargets only the unit(s) whose artifact references the candidate tag, leaves individual native releases alone" do
    stdout_and_err, status = run_cli(@input_path, RETARGET_SPEC_CANDIDATE_TAG, RETARGET_SPEC_LIVE_TAG, @output_path)

    expect(status).to be_success, "CLI failed: #{stdout_and_err}"
    result = JSON.parse(File.read(@output_path))
    units = result['targets'].first['units']

    gtk3_unit = units.find { |u| u['id'] == 'gtk3-runtime' }
    expect(gtk3_unit['artifact']['url']).to eq(
      "https://github.com/elanthia-online/Ruby4Lich5/releases/download/#{RETARGET_SPEC_LIVE_TAG}/R4L5-gem-bundle-x64-mingw-ucrt.zip"
    )
    expect(gtk3_unit['artifact']['sha256']).to eq("sha256:#{'a' * 64}") # bytes unchanged, only the tag moved

    sqlite3_unit = units.find { |u| u['id'] == 'sqlite3' }
    expect(sqlite3_unit['artifact']['url']).to eq(
      'https://github.com/elanthia-online/Ruby4Lich5/releases/download/R4L5-sqlite3-2.9.5-x64-mingw-ucrt/R4L5-sqlite3-2.9.5-x64-mingw-ucrt.gem'
    )
  end

  it 'exits nonzero and writes nothing when old_tag matches nothing in the manifest' do
    _stdout_and_err, status = run_cli(@input_path, 'R4L5-gem-bundle-x64-mingw-ucrt-wrong-tag', RETARGET_SPEC_LIVE_TAG, @output_path)

    expect(status).not_to be_success
    expect(File.exist?(@output_path)).to be(false)
  end

  it 'exits nonzero when the input file does not exist' do
    _stdout_and_err, status = run_cli('/no/such/file.json', RETARGET_SPEC_CANDIDATE_TAG, RETARGET_SPEC_LIVE_TAG, @output_path)

    expect(status).not_to be_success
  end

  it 'refuses to retarget immutable run candidates or write an output file' do
    tag = "#{RETARGET_SPEC_CANDIDATE_TAG}-123-1"
    File.write(@input_path, JSON.generate(sample_manifest).gsub(RETARGET_SPEC_CANDIDATE_TAG, tag))
    text, status = run_cli(@input_path, tag, RETARGET_SPEC_LIVE_TAG, @output_path)
    expect(status).not_to be_success
    expect(text).to include('immutable candidates must retain artifact URLs')
    expect(File.exist?(@output_path)).to be(false)
  end

  it 'exits nonzero when the input file is not valid JSON' do
    File.write(@input_path, 'not json')

    _stdout_and_err, status = run_cli(@input_path, RETARGET_SPEC_CANDIDATE_TAG, RETARGET_SPEC_LIVE_TAG, @output_path)

    expect(status).not_to be_success
  end
end
