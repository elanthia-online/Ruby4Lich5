#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the SQLite tarball a sqlite3 source gem ships under ports/archives/
# against the sha256 in the same gem's dependencies.yml, before the
# aarch64-mingw-ucrt lane builds sqlite3's packaged SQLite from it.
# mini_portile2 verifies the tarball too (sqlite3's extconf passes it the same
# sha256, and mini_portile2's extract checks it even when the download is
# skipped); this check fails earlier, with a clearer message, and also checks
# that the gem ships exactly that archive.
#
# Usage: ruby bin/verify_packaged_sqlite.rb <sqlite3-x.y.z.gem>

require 'digest'
require 'rubygems/package'
require 'yaml'
require 'zlib'

module PackagedSqlite
  module_function

  # @param gem_path [String] a sqlite3 source .gem
  # @return [String] a one-line summary of what was verified
  # @raise [RuntimeError] when an archive is missing, extra or differs
  def verify!(gem_path)
    files = data_files(gem_path) { |path| path == 'dependencies.yml' || path.start_with?('ports/archives/') }
    config = YAML.safe_load(files.fetch('dependencies.yml') { raise 'gem has no dependencies.yml' }).fetch('sqlite3')
    expected = config.fetch('files').to_h { |file| [File.basename(file.fetch('url')), file.fetch('sha256')] }
    archives = files.select { |path, _bytes| path.start_with?('ports/archives/') }.transform_keys { |path| File.basename(path) }
    raise "packaged SQLite archives #{archives.keys.sort} differ from dependencies.yml #{expected.keys.sort}" unless archives.keys.sort == expected.keys.sort

    archives.each do |name, bytes|
      raise "#{name} sha256 differs from dependencies.yml" unless Digest::SHA256.hexdigest(bytes) == expected.fetch(name)
    end
    "packaged SQLite #{config.fetch('version')} verified: #{expected.map { |name, sha| "#{name} sha256:#{sha}" }.join(', ')}"
  end

  # @return [Hash{String => String}] contents of the gem's data files the block selects
  def data_files(gem_path)
    files = {}
    File.open(gem_path, 'rb') do |io|
      Gem::Package::TarReader.new(io).each do |entry|
        next unless entry.full_name == 'data.tar.gz'

        Zlib::GzipReader.wrap(entry) do |gzip|
          Gem::Package::TarReader.new(gzip).each do |file|
            files[file.full_name] = file.read if file.file? && yield(file.full_name)
          end
        end
      end
    end
    files
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: verify_packaged_sqlite.rb <sqlite3-x.y.z.gem>' unless ARGV.length == 1
  begin
    puts PackagedSqlite.verify!(ARGV.first)
  rescue StandardError => e
    warn "ERROR: #{e.message}"
    exit 1
  end
end
