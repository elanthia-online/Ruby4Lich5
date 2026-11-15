# frozen_string_literal: true

require 'json'
require 'tmpdir'

module Ruby4Lich5
  # Checks that the sqlite3 the aarch64-mingw-ucrt lane builds from the gem's
  # packaged SQLite matches the upstream x64-mingw-ucrt gem: the same SQLite
  # compile options (PRAGMA compile_options), and the behaviour three of them
  # promise. The expected options are captured from the upstream x64 gem on an
  # x64 runner and committed as a fixture with the run that captured them.
  module Sqlite3Parity
    # Options that name the toolchain, which differs by design: upstream builds
    # x64 with gcc, and the aarch64 lane builds with MSYS2's clang. Nothing
    # else may differ.
    PLATFORM_SPECIFIC = /\ACOMPILER=/

    module_function

    # @param database [SQLite3::Database]
    # @return [Array<String>] the compile options, sorted
    def compile_options(database)
      database.execute('PRAGMA compile_options').flatten.sort
    end

    # @param expected [Array<String>]
    # @param actual [Array<String>]
    # @return [Hash{Symbol => Array<String>}] :missing and :extra options,
    #   platform-specific ones left out
    def compare(expected, actual)
      comparable = ->(options) { options.grep_v(PLATFORM_SPECIFIC).sort }
      { missing: comparable.call(expected) - comparable.call(actual), extra: comparable.call(actual) - comparable.call(expected) }
    end

    # Runs the behaviour checks on a temporary database: WAL journaling, a
    # write and read back, the NORMAL synchronous default a connection gets
    # when it opens a WAL database (DEFAULT_WAL_SYNCHRONOUS=1; the connection
    # that switched to WAL keeps FULL), and a read-only file: URI (USE_URI=1).
    # @param sqlite3 [Module] the loaded SQLite3 module
    # @return [Array<String>] what was checked
    # @raise [RuntimeError] on the first check that fails
    def functional!(sqlite3)
      Dir.mktmpdir('sqlite3-parity') do |directory|
        path = File.join(directory, 'parity.db')
        database = sqlite3::Database.new(path)
        mode = database.get_first_value('PRAGMA journal_mode=WAL')
        raise "journal_mode=WAL returned #{mode.inspect}" unless mode == 'wal'

        database.execute('CREATE TABLE parity (value TEXT)')
        database.execute('INSERT INTO parity VALUES (?)', ['written'])
        raise 'a written row did not read back' unless database.get_first_value('SELECT value FROM parity') == 'written'

        database.close
        reopened = sqlite3::Database.new(path)
        begin
          mode = reopened.get_first_value('PRAGMA journal_mode')
          synchronous = reopened.get_first_value('PRAGMA synchronous')
          raise "a reopened WAL database has journal_mode #{mode.inspect} and synchronous #{synchronous.inspect}, expected wal and 1 (NORMAL)" unless mode == 'wal' && synchronous == 1
        ensure
          reopened.close
        end
        read_only = sqlite3::Database.new(uri(path))
        begin
          raise 'the file: URI did not open the database' unless read_only.get_first_value('SELECT value FROM parity') == 'written'

          begin
            read_only.execute("INSERT INTO parity VALUES ('refused')")
            raise 'a mode=ro file: URI accepted a write'
          rescue sqlite3::ReadOnlyException
            nil
          end
        ensure
          read_only.close
        end
      end
      ['journal_mode=WAL', 'write and read back', 'synchronous=1 (NORMAL) on reopening the WAL database', 'file: URI with mode=ro opens read-only']
    end

    # @param path [String]
    # @return [String] a file: URI that opens +path+ read-only
    def uri(path)
      absolute = path.tr('\\', '/')
      absolute = File.expand_path(absolute) unless absolute.start_with?('/') || absolute.match?(%r{\A[A-Za-z]:/})
      absolute = "/#{absolute}" unless absolute.start_with?('/')
      "file://#{absolute.gsub('%', '%25').gsub(' ', '%20').gsub('?', '%3F').gsub('#', '%23')}?mode=ro"
    end
  end
end
