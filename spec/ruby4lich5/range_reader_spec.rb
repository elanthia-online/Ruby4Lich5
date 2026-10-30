# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'

RSpec.describe 'Published range reader verification' do
  let(:commit) { 'a' * 40 }
  let(:cli) { File.expand_path('../../bin/verify_range_reader.rb', __dir__) }
  let(:policy) { File.binread(File.expand_path('../../vendor/lich5/recovery_unit_policy.rb', __dir__)) }
  let(:recovery) { File.binread(File.expand_path('../../vendor/lich5/dependency_recovery-ranged.rb', __dir__)) }
  let(:status) { instance_double(Process::Status, success?: true) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      FileUtils.mkdir_p(File.join(directory, 'lib'))
      File.write(File.join(directory, 'lib/version.rb'), "LICH_VERSION = '5.24.0'\n")
      @manifest = File.join(directory, 'manifest.json')
      File.write(@manifest, JSON.generate('targets' => [{ 'units'        => [{ 'lich_versions' => { 'min_inclusive' => '5.24.0' } }],
                                                          'range_reader' => { 'release' => 'v5.24.0', 'commit' => commit } }]))
      example.run
    end
  end

  before do
    stub_const('ARGV', [@manifest, @directory])
    allow(Open3).to receive(:capture2).with('git', '-C', @directory, 'rev-parse', 'HEAD').and_return(["#{commit}\n", status])
    allow(Open3).to receive(:capture2).with('git', '-C', @directory, 'show', "#{commit}:lib/recovery_unit_policy.rb").and_return([policy, status])
    allow(Open3).to receive(:capture2).with('git', '-C', @directory, 'show', "#{commit}:lib/dependency_recovery.rb").and_return([recovery, status])
  end

  it 'accepts only the exact reviewed recovery and policy bytes at the declared release and full commit' do
    expect { load cli }.not_to raise_error
  end

  it 'rejects an unimplemented or changed recovery source at an otherwise matching release identity' do
    allow(Open3).to receive(:capture2).with('git', '-C', @directory, 'show', "#{commit}:lib/dependency_recovery.rb").and_return([recovery + "\n# changed\n", status])
    expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }.and output(/differs from reviewed/).to_stderr
  end

  it 'rejects tag/version mismatches before treating a capability as released' do
    File.write(File.join(@directory, 'lib/version.rb'), "LICH_VERSION = '5.23.0'\n")
    expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }.and output(/release version differs/).to_stderr
  end
end
