# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'

require 'digest'
require 'ruby4lich5/reviewed_archive_reader'

RSpec.describe 'Published range reader verification' do
  reader = { 'lib/archive.rb' => "module Archive; end\n", 'lib/archive/zip.rb' => "# zip\n" }.freeze

  let(:commit) { @commit }
  let(:cli) { File.expand_path('../../bin/verify_range_reader.rb', __dir__) }
  let(:policy) { File.binread(File.expand_path('../../vendor/lich5/recovery_unit_policy.rb', __dir__)) }
  let(:recovery) { File.binread(File.expand_path('../../vendor/lich5/dependency_recovery-ranged.rb', __dir__)) }
  let(:status) { instance_double(Process::Status, success?: true) }

  # The release checkout is a real git repository, so the reader files are
  # listed and read from its blobs; recovery and policy stay stubbed.
  def git(*args)
    output, error, status = Open3.capture3('git', '-C', @directory, '-c', 'user.name=spec', '-c', 'user.email=spec@example.invalid',
                                           '-c', 'core.autocrlf=false', '-c', 'commit.gpgsign=false', *args)
    raise error unless status.success?

    output
  end

  def release(files)
    files.each do |path, bytes|
      FileUtils.mkdir_p(File.join(@directory, File.dirname(path)))
      File.binwrite(File.join(@directory, path), bytes)
    end
    git('add', '-A')
    git('commit', '-q', '--allow-empty', '-m', 'release')
    @commit = git('rev-parse', 'HEAD').strip
    File.write(@manifest, JSON.generate('targets' => [{ 'units'        => [{ 'lich_versions' => { 'min_inclusive' => '5.24.0' } }],
                                                        'range_reader' => { 'release' => 'v5.24.0', 'commit' => @commit } }]))
  end

  # The vendored reviewed reader as path => bytes; empty while the pin is.
  def reviewed_reader
    vendored = Ruby4Lich5::ReviewedArchiveReader::VENDORED
    Ruby4Lich5::ReviewedArchiveReader.files_in(vendored).keys.to_h { |path| [path, File.binread(File.join(vendored, path))] }
  end

  def pin(files)
    allow(Ruby4Lich5::ReviewedArchiveReader).to receive(:pinned).and_return(files.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }.sort.to_h)
  end

  def refused(pattern)
    expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }.and output(pattern).to_stderr
  end

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = File.join(directory, 'release')
      @manifest = File.join(directory, 'manifest.json')
      FileUtils.mkdir_p(@directory)
      git('init', '-q')
      release('lib/version.rb' => "LICH_VERSION = '5.24.0'\n")
      example.run
    end
  end

  before do
    stub_const('ARGV', [@manifest, @directory])
    # Whatever commit an example releases, recovery and policy are the
    # reviewed bytes unless the example says otherwise.
    allow(Open3).to receive(:capture2).and_wrap_original do |original, *args, **options|
      case args
      in ['git', '-C', ^@directory, 'show', /:lib\/recovery_unit_policy\.rb\z/] then [policy, status]
      in ['git', '-C', ^@directory, 'show', /:lib\/dependency_recovery\.rb\z/] then [recovery, status]
      else original.call(*args, **options)
      end
    end
  end

  it 'accepts only the exact reviewed recovery and policy bytes at the declared release and full commit' do
    release(reviewed_reader)
    expect { load cli }.not_to raise_error
  end

  it 'rejects an unimplemented or changed recovery source at an otherwise matching release identity' do
    allow(Open3).to receive(:capture2).with('git', '-C', @directory, 'show', "#{commit}:lib/dependency_recovery.rb").and_return([recovery + "\n# changed\n", status])
    expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }.and output(/differs from reviewed/).to_stderr
  end

  describe 'the archive reader' do
    before { pin(reader) }

    it 'accepts exactly the reviewed reader files' do
      release(reader)
      expect { load cli }.not_to raise_error
    end

    it 'accepts the reviewed bytes at a later commit than the reviewed one' do
      release(reader)
      release('README.md' => "# later\n")
      expect { load cli }.not_to raise_error
    end

    {
      'a changed reader file'      => reader.merge('lib/archive/zip.rb' => "# zip!\n"),
      'an extra reader file'       => reader.merge('lib/archive/rar.rb' => "# rar\n"),
      'an extra hidden file'       => reader.merge('lib/archive/.rar.rb' => "# rar\n"),
      'the older reader alongside' => reader.merge('lib/zip_archive.rb' => "# old\n")
    }.each do |label, files|
      it "refuses a release with #{label}" do
        release(files)
        refused(/archive reader differs from reviewed source/)
      end
    end

    it 'refuses a release missing a reader file' do
      release(reader.except('lib/archive/zip.rb'))
      refused(/archive reader differs from reviewed source/)
    end

    it 'refuses a release with no reader against a filled pin' do
      refused(/archive reader differs from reviewed source/)
    end
  end

  it 'accepts a release with no reader against an empty pin, as today' do
    pin({})
    expect { load cli }.not_to raise_error
  end

  it 'checks nothing when no unit carries a range' do
    File.write(@manifest, JSON.generate('targets' => [{ 'units' => [{}], 'range_reader' => nil }]))
    expect(Open3).not_to receive(:capture2)
    expect { load cli }.not_to raise_error
  end

  it 'rejects tag/version mismatches before treating a capability as released' do
    File.write(File.join(@directory, 'lib/version.rb'), "LICH_VERSION = '5.23.0'\n")
    expect { load cli }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }.and output(/release version differs/).to_stderr
  end
end
