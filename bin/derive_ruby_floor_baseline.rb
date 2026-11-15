#!/usr/bin/env ruby
# frozen_string_literal: true

# Derives one platform's RubyInstaller gem-floor baseline from the official
# RubyInstaller .7z archive, for config/ruby-floor-baseline.json. The archive
# must match the SHA-256 GitHub publishes for the release asset; only the
# gemspec directories are extracted, and the gem map is built by
# RubyInventory.gems_from, the same builder RubyInventory.capture uses on a
# running install.
#
#   ruby bin/derive_ruby_floor_baseline.rb <platform> <installer version> <archive.7z> <sha256>
#
# Prints the JSON entry for config/ruby-floor-baseline.json "platforms".
require 'json'
require 'digest'
require 'open3'
require 'tmpdir'
require 'rubygems'
require_relative '../lib/ruby4lich5/ruby_inventory'

abort 'Usage: derive_ruby_floor_baseline.rb <platform> <installer version> <archive.7z> <sha256>' unless ARGV.length == 4
platform, installer, archive, expected = ARGV
abort 'Installer version must look like 4.0.0-1' unless installer.match?(/\A\d+\.\d+\.\d+-\d+\z/)
abort 'Archive SHA-256 differs from the published asset digest' unless Digest::SHA256.file(archive).hexdigest == expected
Dir.mktmpdir do |directory|
  _output, error, status = Open3.capture3('7z', 'x', '-y', "-o#{directory}", archive, '*/lib/ruby/gems/*/specifications/*', '-r')
  abort "Archive extraction failed: #{error}" unless status.success?
  roots = Dir.glob(File.join(directory, '*/lib/ruby/gems/*/specifications'))
  abort 'Archive must hold exactly one gem specifications directory' unless roots.length == 1
  specs = Dir.glob(File.join(roots.first, '{,default/}*.gemspec')).map do |path|
    Gem::Specification.load(path) or abort "Unreadable gemspec: #{File.basename(path)}"
  end
  gems = Ruby4Lich5::RubyInventory.gems_from(specs)
  puts JSON.pretty_generate(platform => { 'ruby_installer_version' => installer, 'archive_sha256' => expected,
                                          'ruby_version' => installer.split('-').first, 'gems' => gems })
end
