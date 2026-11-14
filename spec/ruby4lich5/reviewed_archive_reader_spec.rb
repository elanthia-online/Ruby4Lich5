# frozen_string_literal: true

require 'json'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'ruby4lich5/reviewed_archive_reader'
require 'ruby4lich5/recovery_consumers'

RSpec.describe Ruby4Lich5::ReviewedArchiveReader do
  reader = { 'lib/archive.rb' => "module Archive; end\n", 'lib/archive/zip.rb' => "# zip\n", 'lib/archive/tar_gz.rb' => "# tar\n" }.freeze

  around do |example|
    Dir.mktmpdir do |directory|
      @root = directory
      example.run
    end
  end

  def write_tree(directory, files)
    files.each do |path, bytes|
      FileUtils.mkdir_p(File.join(directory, File.dirname(path)))
      File.binwrite(File.join(directory, path), bytes)
    end
    directory
  end

  # A pin and vendored copies for +files+, as the re-vendor writes them.
  def pin(files, digests: files.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) })
    source = File.join(@root, 'ranged-source.json')
    File.write(source, JSON.generate('source_commit' => 'a' * 40, 'files' => {}, 'reader_files' => digests))
    { source: source, vendored: write_tree(File.join(@root, 'vendored'), files) }
  end

  def candidate(files)
    write_tree(File.join(@root, 'candidate'), files)
  end

  it 'accepts a sealed source holding exactly the reviewed reader' do
    expect(described_class.matches?(candidate(reader), **pin(reader))).to be(true)
  end

  it 'accepts a source with no reader against an empty pin, as for a commit before the reader existed' do
    expect(described_class.matches?(candidate('lib/dependency_recovery.rb' => "# recovery\n"), **pin({}))).to be(true)
  end

  {
    'a changed byte'                           => reader.merge('lib/archive/zip.rb' => "# zip!\n"),
    'a missing file'                           => reader.except('lib/archive/tar_gz.rb'),
    'an extra reviewed-shape file'             => reader.merge('lib/archive/rar.rb' => "# rar\n"),
    'an extra file the factory would not seal' => reader.merge('lib/archive/zip/entry.rb' => "# nested\n"),
    'the older single-file reader alongside'   => reader.merge('lib/zip_archive.rb' => "# old\n")
  }.each do |label, files|
    it "refuses a sealed source with #{label}" do
      expect(described_class.matches?(candidate(files), **pin(reader))).to be(false)
    end
  end

  it 'refuses any reader against an empty pin' do
    expect(described_class.matches?(candidate(reader), **pin({}))).to be(false)
  end

  it 'refuses vendored copies that differ from their pin' do
    options = pin(reader)
    File.binwrite(File.join(options.fetch(:vendored), 'lib/archive.rb'), "module Archive; 1; end\n")
    expect { described_class.pinned(**options) }.to raise_error(ArgumentError, /copies differ from their pin/)
  end

  # A re-vendor from a lich-5 tree where a merge brought the old reader back
  # would otherwise pin the dead file beside the new one.
  it 'refuses a pin holding both the old single-file reader and the new one' do
    expect { described_class.pinned(**pin(reader.merge('lib/zip_archive.rb' => "# old\n"))) }
      .to raise_error(ArgumentError, /holds both the old and the new reader/)
  end

  it 'still accepts a pin of the old single-file reader on its own' do
    old = { 'lib/zip_archive.rb' => "# old\n" }
    expect(described_class.matches?(candidate(old), **pin(old))).to be(true)
  end

  it 'refuses a malformed pin' do
    [{ 'lib/archive.rb' => 'short' }, { '../lib/archive.rb' => 'a' * 64 }, { 'lib/archive/tar-gz.rb' => 'a' * 64 }].each do |digests|
      expect { described_class.pinned(**pin({}, digests: digests)) }.to raise_error(ArgumentError, /invalid reviewed archive reader pin/)
    end
    File.write(File.join(@root, 'ranged-source.json'), JSON.generate('files' => {}))
    expect { described_class.pinned(source: File.join(@root, 'ranged-source.json'), vendored: File.join(@root, 'none')) }
      .to raise_error(ArgumentError, /invalid reviewed archive reader pin/)
  end

  it 'keeps the repository pin and vendored copies consistent' do
    expect(described_class.pinned).to be_a(Hash)
  end

  it 'uses the same file pattern the seal script accepts' do
    seal = File.read(File.expand_path('../../bin/seal_contract_source.rb', __dir__))
    expect(seal).to include(described_class::PATH.source)
  end

  describe '.files_at' do
    def git(directory, *args)
      _out, error, status = Open3.capture3('git', '-C', directory, '-c', 'user.name=spec', '-c', 'user.email=spec@example.invalid',
                                           '-c', 'core.autocrlf=false', '-c', 'commit.gpgsign=false', *args)
      raise error unless status.success?
    end

    def commit_tree(files)
      directory = candidate(files)
      git(directory, 'init', '-q')
      git(directory, 'add', '-A')
      git(directory, 'commit', '-q', '-m', 'tree')
      [directory, Open3.capture2('git', '-C', directory, 'rev-parse', 'HEAD').first.strip]
    end

    it 'lists the same reader files as a checkout of that commit, hidden and nested ones included' do
      files = reader.merge('lib/archive/.hidden.rb' => "# hidden\n", 'lib/archive/.d/x.rb' => "# x\n", 'lib/archive/zip/entry.rb' => "# nested\n",
                           'lib/archives.rb' => "# not the reader\n", 'lib/dependency_recovery.rb' => "# recovery\n")
      directory, head = commit_tree(files)
      expect(described_class.files_at(directory, head)).to eq(described_class.files_in(directory))
      expect(described_class.files_in(directory).keys).to eq(%w[lib/archive.rb lib/archive/.d/x.rb lib/archive/.hidden.rb lib/archive/tar_gz.rb
                                                                lib/archive/zip.rb lib/archive/zip/entry.rb])
    end

    it 'hashes raw blob bytes' do
      directory, head = commit_tree('lib/archive.rb' => "module Archive\r\nend\r\n")
      expect(described_class.files_at(directory, head)).to eq('lib/archive.rb' => Digest::SHA256.hexdigest("module Archive\r\nend\r\n"))
    end

    it 'refuses a reader entry that is not a regular file' do
      directory = candidate(reader)
      File.symlink('zip.rb', File.join(directory, 'lib/archive/link.rb'))
      git(directory, 'init', '-q')
      git(directory, 'add', '-A')
      git(directory, 'commit', '-q', '-m', 'tree')
      expect { described_class.files_at(directory, 'HEAD') }.to raise_error(ArgumentError, %r{lib/archive/link.rb is not a regular file})
    end

    it 'refuses a commit git cannot list' do
      directory, = commit_tree(reader)
      expect { described_class.files_at(directory, 'f' * 40) }.to raise_error(ArgumentError, /cannot list the archive reader/)
    end
  end

  describe 'the ranged recovery consumer' do
    let(:context) do
      { 'ranged_consumer' => { 'commit' => 'f' * 40, 'sha256' => Digest::SHA256.hexdigest("# recovery\n"), 'policy_sha256' => Digest::SHA256.hexdigest("# policy\n") } }
    end

    before do
      allow(Digest::SHA256).to receive(:file).and_call_original
      allow(File).to receive(:expand_path).and_call_original
      allow(File).to receive(:expand_path).with('preparation/range-consumer/lib/dependency_recovery.rb', Ruby4Lich5::RecoveryConsumers::ROOT)
                                          .and_return(File.join(@root, 'sealed/lib/dependency_recovery.rb'))
      write_tree(File.join(@root, 'sealed'), 'lib/dependency_recovery.rb' => "# recovery\n", 'lib/recovery_unit_policy.rb' => "# policy\n")
    end

    it 'accepts a sealed copy whose reader matches the pin' do
      allow(described_class).to receive(:pinned).and_return({})
      expect(Ruby4Lich5::RecoveryConsumers.entry('ranged', context: context).fetch('absolute_path')).to end_with('sealed/lib/dependency_recovery.rb')
    end

    it 'fails closed on an unreviewed reader before recovery can load it' do
      allow(described_class).to receive(:pinned).and_return({})
      write_tree(File.join(@root, 'sealed'), 'lib/archive.rb' => "# unreviewed\n")
      expect { Ruby4Lich5::RecoveryConsumers.entry('ranged', context: context) }.to raise_error(/archive reader differs from reviewed source/)
    end
  end
end
