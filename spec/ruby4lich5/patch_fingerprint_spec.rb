# frozen_string_literal: true

require 'ruby4lich5/patch_fingerprint'
require 'tmpdir'
require 'json'

RSpec.describe Ruby4Lich5::PatchFingerprint do
  around { |example| Dir.mktmpdir { |root| @root = root; example.run } }

  def write(relative, content)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def fingerprint(name = 'gtk3') = described_class.compute(name, patches_root: @root)

  it 'treats a missing or empty patch directory as no patches' do
    expect(fingerprint).to be_nil
    FileUtils.mkdir_p(File.join(@root, 'gtk3', 'nested'))
    expect(fingerprint).to be_nil
  end

  it 'is a stable sha256 over relative paths and bytes that moves with content, names and new files' do
    write('gtk3/a.rb', 'one')
    first = fingerprint
    expect(first).to match(/\Asha256:[0-9a-f]{64}\z/)
    expect(fingerprint).to eq(first)
    write('gtk3/a.rb', 'two')
    second = fingerprint
    expect(second).not_to eq(first)
    FileUtils.mv(File.join(@root, 'gtk3/a.rb'), File.join(@root, 'gtk3/b.rb'))
    expect(fingerprint).not_to eq(second)
    renamed = fingerprint
    write('gtk3/nested/c.rb', 'three')
    expect(fingerprint).not_to eq(renamed)
  end

  it 'covers only the named package' do
    write('gtk3/a.rb', 'one')
    expect(fingerprint('glib2')).to be_nil
  end

  it 'refuses a symlink and an unsafe package name' do
    write('outside.rb', 'x')
    FileUtils.mkdir_p(File.join(@root, 'gtk3'))
    File.symlink(File.join(@root, 'outside.rb'), File.join(@root, 'gtk3/link.rb'))
    expect { fingerprint }.to raise_error(ArgumentError, /symlink/)
    expect { fingerprint('..') }.to raise_error(ArgumentError)
  end

  describe '.reusable?' do
    digest = "sha256:#{'a' * 64}"
    other = "sha256:#{'b' * 64}"

    it 'reuses only a proven-identical patch set' do
      expect(described_class.reusable?({ 'gtk3' => digest }, 'gtk3', digest)).to be(true)
      expect(described_class.reusable?({ 'gtk3' => digest }, 'gtk3', other)).to be(false)
      expect(described_class.reusable?({ 'gtk3' => digest }, 'gtk3', nil)).to be(false)
      expect(described_class.reusable?({ 'gtk3' => nil }, 'gtk3', digest)).to be(false)
      expect(described_class.reusable?({ 'gtk3' => nil }, 'gtk3', nil)).to be(true)
    end

    it 'fails closed for an unrecorded package that has patches today' do
      expect(described_class.reusable?(nil, 'gtk3', digest)).to be(false)
      expect(described_class.reusable?({}, 'gtk3', digest)).to be(false)
      expect(described_class.reusable?(nil, 'gtk3', nil)).to be(true)
      expect(described_class.reusable?({}, 'gtk3', nil)).to be(true)
    end
  end

  describe '.read_metadata' do
    let(:path) { File.join(@root, 'gem-build-metadata.json') }

    it 'reads a Windows PowerShell 5.1 UTF-8 BOM file' do
      File.binwrite(path, [0xEF, 0xBB, 0xBF].pack('C*') + JSON.generate('schema_version' => 1, 'patch_fingerprints' => { 'gtk3' => nil }))
      expect(described_class.read_metadata(path)).to eq('gtk3' => nil)
    end

    it 'distinguishes no record from an empty record' do
      File.write(path, JSON.generate('schema_version' => 1))
      expect(described_class.read_metadata(path)).to be_nil
      File.write(path, JSON.generate('schema_version' => 1, 'patch_fingerprints' => {}))
      expect(described_class.read_metadata(path)).to eq({})
    end

    it 'refuses a malformed record' do
      # Non-string values must fail with the same ArgumentError, not a TypeError.
      [[], { 'gtk3' => 'md5:x' }, { '../x' => nil }, { 'gtk3' => false }, { 'gtk3' => true }, { 'gtk3' => 0 },
       { 'gtk3' => 1.5 }, { 'gtk3' => [] }, { 'gtk3' => {} }].each do |record|
        File.write(path, JSON.generate('patch_fingerprints' => record))
        expect { described_class.read_metadata(path) }.to raise_error(ArgumentError)
      end
    end
  end
end
