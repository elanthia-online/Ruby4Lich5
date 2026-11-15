#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage:
#   ruby bin/check_sqlite3_parity.rb <expected_compile_options_json>
#     Compares the loaded sqlite3's compile options with the fixture and runs
#     the behaviour checks; exits 1 on any difference or failure.
#   ruby bin/check_sqlite3_parity.rb --capture <output_json>
#     Writes the loaded sqlite3's compile options (to make the fixture).

require 'json'
require 'sqlite3'
require_relative '../lib/ruby4lich5/sqlite3_parity'

parity = Ruby4Lich5::Sqlite3Parity
begin
  database = SQLite3::Database.new(':memory:')
  options = parity.compile_options(database)
  database.close
  if ARGV.length == 2 && ARGV.first == '--capture'
    capture = { 'sqlite3_gem' => SQLite3::VERSION, 'sqlite_version' => SQLite3::SQLITE_LOADED_VERSION,
                'platform' => Gem::Platform.local.to_s, 'compile_options' => options }
    File.write(ARGV.last, "#{JSON.pretty_generate(capture)}\n")
    puts JSON.pretty_generate(capture)
  elsif ARGV.length == 1
    expected = JSON.parse(File.read(ARGV.first))
    difference = parity.compare(expected.fetch('compile_options'), options)
    puts "sqlite3 #{SQLite3::VERSION}, SQLite #{SQLite3::SQLITE_LOADED_VERSION} (expected #{expected.fetch('sqlite_version')}); #{options.length} compile options"
    unless SQLite3::SQLITE_LOADED_VERSION == expected.fetch('sqlite_version') && difference.values.all?(&:empty?)
      raise "SQLite #{SQLite3::SQLITE_LOADED_VERSION} vs #{expected.fetch('sqlite_version')}; missing #{difference[:missing]}; extra #{difference[:extra]}"
    end

    puts "compile options match the x64 fixture (apart from #{options.grep(parity::PLATFORM_SPECIFIC).join(', ')})"
    parity.functional!(SQLite3).each { |check| puts "ok: #{check}" }
  else
    abort 'Usage: check_sqlite3_parity.rb <expected_json> | --capture <output_json>'
  end
rescue StandardError, LoadError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
