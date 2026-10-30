# frozen_string_literal: true

require 'tmpdir'
require 'open3'

RSpec.describe 'Pinned candidate source acquisition' do
  let(:cli) { File.expand_path('../../bin/seal_contract_source.rb', __dir__) }
  let(:commit) { 'a' * 40 }
  let(:status) { instance_double(Process::Status, success?: true) }

  around do |example|
    Dir.mktmpdir { |directory| @directory = directory; example.run }
  end

  before { stub_const('ARGV', ['candidate-checkout', commit, @directory]) }

  it 'uses exact Git blob bytes rather than newline-transformed checkout files' do
    allow(Open3).to receive(:capture3).with('git', '-C', 'candidate-checkout', 'rev-parse', 'HEAD').and_return(["#{commit}\n", '', status])
    %w[Gemfile Gemfile.lock lib/runtime_gem_contract.rb lib/dependency_recovery.rb lib/recovery_unit_policy.rb lib/version.rb].each do |path|
      allow(Open3).to receive(:capture3).with('git', '-C', 'candidate-checkout', 'show', "#{commit}:#{path}").and_return(["#{path}\ncanonical LF bytes\n", '', status])
    end
    load cli
    expect(File.binread(File.join(@directory, 'Gemfile'))).to eq("Gemfile\ncanonical LF bytes\n")
    expect(File.binread(File.join(@directory, 'lib/runtime_gem_contract.rb'))).not_to include("\r")
  end

  it 'rejects a checkout at a different full candidate SHA before copying any source' do
    allow(Open3).to receive(:capture3).with('git', '-C', 'candidate-checkout', 'rev-parse', 'HEAD').and_return(["#{'b' * 40}\n", '', status])
    expect(Open3).not_to receive(:capture3).with('git', '-C', 'candidate-checkout', 'show', anything)
    expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }.and output(/Wrong candidate checkout/).to_stderr
    expect(Dir.children(@directory)).to be_empty
  end
end
