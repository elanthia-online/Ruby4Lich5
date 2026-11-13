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

  def stub_extractor_listing(paths)
    allow(Open3).to receive(:capture3)
      .with('git', '-C', 'candidate-checkout', 'ls-tree', '-r', '--name-only', commit, '--', 'lib/zip_archive.rb', 'lib/archive.rb', 'lib/archive')
      .and_return([paths.map { |path| "#{path}\n" }.join, '', status])
  end

  it 'uses exact Git blob bytes rather than newline-transformed checkout files' do
    allow(Open3).to receive(:capture3).with('git', '-C', 'candidate-checkout', 'rev-parse', 'HEAD').and_return(["#{commit}\n", '', status])
    stub_extractor_listing([])
    %w[Gemfile Gemfile.lock lib/runtime_gem_contract.rb lib/dependency_recovery.rb lib/recovery_unit_policy.rb lib/version.rb
       lib/accepted_gem_policy.rb lib/startup_policy_compatibility.rb].each do |path|
      allow(Open3).to receive(:capture3).with('git', '-C', 'candidate-checkout', 'show', "#{commit}:#{path}").and_return(["#{path}\ncanonical LF bytes\n", '', status])
    end
    load cli
    expect(File.binread(File.join(@directory, 'Gemfile'))).to eq("Gemfile\ncanonical LF bytes\n")
    expect(File.binread(File.join(@directory, 'lib/runtime_gem_contract.rb'))).not_to include("\r")
  end

  it 'also seals the archive reader recovery extracts with, when the commit has one' do
    allow(Open3).to receive(:capture3).with('git', '-C', 'candidate-checkout', 'rev-parse', 'HEAD').and_return(["#{commit}\n", '', status])
    reader = %w[lib/archive.rb lib/archive/tar_gz.rb lib/archive/zip.rb]
    stub_extractor_listing(reader)
    (%w[Gemfile Gemfile.lock lib/runtime_gem_contract.rb lib/dependency_recovery.rb lib/recovery_unit_policy.rb lib/version.rb
        lib/accepted_gem_policy.rb lib/startup_policy_compatibility.rb] + reader).each do |path|
      allow(Open3).to receive(:capture3).with('git', '-C', 'candidate-checkout', 'show', "#{commit}:#{path}").and_return(["#{path}\n", '', status])
    end
    load cli
    reader.each { |path| expect(File.binread(File.join(@directory, path))).to eq("#{path}\n") }
    expect(Dir.children(File.join(@directory, 'lib/archive')).sort).to eq(%w[tar_gz.rb zip.rb])
    expect(File.exist?(File.join(@directory, 'lib/zip_archive.rb'))).to be(false)
  end

  # The reviewed-reader check compares the sealed set with the vendored one,
  # so a reader file outside the pattern must stop sealing, not be dropped.
  [['a hyphenated file', 'lib/archive/tar-gz.rb'], ['a nested file', 'lib/archive/zip/entry.rb'], ['a non-Ruby file', 'lib/archive/README.md']].each do |label, path|
    it "refuses to seal a candidate whose archive reader has #{label}" do
      allow(Open3).to receive(:capture3).with('git', '-C', 'candidate-checkout', 'rev-parse', 'HEAD').and_return(["#{commit}\n", '', status])
      stub_extractor_listing(['lib/archive.rb', path])
      expect(Open3).not_to receive(:capture3).with('git', '-C', 'candidate-checkout', 'show', anything)
      expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output(/Unsupported candidate archive reader file: #{Regexp.escape(path)}/).to_stderr
      expect(Dir.children(@directory)).to be_empty
    end
  end

  it 'rejects a checkout at a different full candidate SHA before copying any source' do
    allow(Open3).to receive(:capture3).with('git', '-C', 'candidate-checkout', 'rev-parse', 'HEAD').and_return(["#{'b' * 40}\n", '', status])
    expect(Open3).not_to receive(:capture3).with('git', '-C', 'candidate-checkout', 'show', anything)
    expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }.and output(/Wrong candidate checkout/).to_stderr
    expect(Dir.children(@directory)).to be_empty
  end
end
