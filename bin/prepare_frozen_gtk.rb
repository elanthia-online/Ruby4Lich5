#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require_relative '../lib/ruby4lich5/gem_manifest_validator'
abort 'Usage: prepare_frozen_gtk.rb <accepted-manifest> <verified-packages> <new-output-directory>' unless ARGV.length == 3
begin
  manifest_path, directory, output = ARGV
  manifest = JSON.parse(File.read(manifest_path))
  Ruby4Lich5::GemManifestValidator.validate!(manifest)
  target = manifest.fetch('targets').find { |item| item.values_at('ruby_abi', 'platform') == %w[4.0 x64-mingw-ucrt] }
  unit = target.fetch('units').find { |item| item['id'] == 'gtk3-runtime' }
  raise 'accepted GTK closure is missing' unless unit && unit.fetch('members').include?('gtk3')
  raise 'frozen GTK preparation requires a new directory' if File.exist?(output)
  paths = unit.fetch('packages').map do |package|
    path = File.join(directory, package.fetch('filename'))
    raise "published GTK package bytes differ: #{package.fetch('name')}" unless File.file?(path) && "sha256:#{Digest::SHA256.file(path).hexdigest}" == package.fetch('sha256')
    path
  end
  FileUtils.mkdir_p(File.join(output, 'pkg'))
  paths.each { |path| FileUtils.cp(path, File.join(output, 'pkg', File.basename(path))) }
  File.write(File.join(output, 'unit.json'), JSON.pretty_generate(unit) + "\n")
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
