# frozen_string_literal: true

require 'ruby4lich5/sqlite3_parity'

RSpec.describe Ruby4Lich5::Sqlite3Parity do
  describe '.compare' do
    let(:x64) { %w[COMPILER=gcc-15.2.0 DEFAULT_WAL_SYNCHRONOUS=1 ENABLE_FTS5 USE_URI] }

    it 'accepts identical options apart from the compiler' do
      expect(described_class.compare(x64, %w[COMPILER=clang-21.1.8 DEFAULT_WAL_SYNCHRONOUS=1 ENABLE_FTS5 USE_URI])).to eq(missing: [], extra: [])
    end

    it 'reports an option the build lacks and one it adds' do
      actual = %w[COMPILER=clang-21.1.8 ENABLE_FTS5 USE_URI ENABLE_LOAD_EXTENSION]
      expect(described_class.compare(x64, actual)).to eq(missing: ['DEFAULT_WAL_SYNCHRONOUS=1'], extra: ['ENABLE_LOAD_EXTENSION'])
    end

    it 'compares values, not just names' do
      expect(described_class.compare(x64, %w[DEFAULT_WAL_SYNCHRONOUS=2 ENABLE_FTS5 USE_URI]))
        .to eq(missing: ['DEFAULT_WAL_SYNCHRONOUS=1'], extra: ['DEFAULT_WAL_SYNCHRONOUS=2'])
    end
  end

  describe '.uri' do
    it 'turns a Windows path into a read-only file: URI' do
      expect(described_class.uri('C:\a\_temp\x y\parity.db')).to eq('file:///C:/a/_temp/x%20y/parity.db?mode=ro')
    end

    it 'escapes characters a URI would read as syntax' do
      expect(described_class.uri('/tmp/a%b?c#d/parity.db')).to eq('file:///tmp/a%25b%3Fc%23d/parity.db?mode=ro')
    end
  end

  # The real check runs in the ARM smoke against the built gem. Here it runs
  # only where a sqlite3 gem loads outside Bundler (the Gemfile has none).
  describe '.functional!' do
    it 'passes on an upstream sqlite3 build' do
      begin
        gem 'sqlite3'
        require 'sqlite3'
      rescue LoadError
        skip 'no sqlite3 gem outside the bundle'
      end
      expect(described_class.functional!(SQLite3).length).to eq(4)
    end
  end
end
