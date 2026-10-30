#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'fileutils'
abort 'Usage: seal_contract_source.rb <checkout> <full SHA> <output directory>' unless ARGV.length == 3
checkout, commit, directory = ARGV
abort 'Expected a full commit SHA' unless commit.match?(/\A[0-9a-f]{40}\z/)
head, error, status = Open3.capture3('git', '-C', checkout, 'rev-parse', 'HEAD')
abort "Wrong candidate checkout: #{error}" unless status.success? && head.strip == commit
# Read Git blobs, not autocrlf-transformed Windows checkout bytes. No Git writes.
%w[Gemfile Gemfile.lock lib/runtime_gem_contract.rb lib/dependency_recovery.rb lib/recovery_unit_policy.rb lib/version.rb
   lib/accepted_gem_policy.rb lib/startup_policy_compatibility.rb].each do |path|
  bytes, error, status = Open3.capture3('git', '-C', checkout, 'show', "#{commit}:#{path}")
  abort "Missing candidate source #{path}: #{error}" unless status.success?
  destination = File.join(directory, path)
  FileUtils.mkdir_p(File.dirname(destination))
  File.binwrite(destination, bytes)
end
