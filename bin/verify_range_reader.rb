#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
abort 'Usage: verify_range_reader.rb <manifest> <release-checkout>' unless ARGV.length == 2
begin
  manifest = JSON.parse(File.read(ARGV[0]))
  target = manifest.fetch('targets').first
  if target.fetch('units').any? { |unit| unit.key?('lich_versions') }
    reader = target.fetch('range_reader')
    checkout = ARGV[1]
    actual, status = Open3.capture2('git', '-C', checkout, 'rev-parse', 'HEAD')
    raise 'released range reader commit differs' unless status.success? && actual.strip == reader.fetch('commit')
    version = File.read(File.join(checkout, 'lib/version.rb'))[/^LICH_VERSION = '([^']+)'/, 1]
    raise 'range reader release version differs' unless reader.fetch('release') == "v#{version}"
    policy, status = Open3.capture2('git', '-C', checkout, 'show', "#{reader.fetch('commit')}:lib/recovery_unit_policy.rb")
    raise 'range reader policy differs from reviewed implementation' unless status.success? && policy == File.binread(File.expand_path('../vendor/lich5/recovery_unit_policy.rb', __dir__))
    recovery, status = Open3.capture2('git', '-C', checkout, 'show', "#{reader.fetch('commit')}:lib/dependency_recovery.rb")
    reviewed = File.expand_path('../vendor/lich5/dependency_recovery-ranged.rb', __dir__)
    raise 'released consumer differs from reviewed range selection' unless status.success? && Digest::SHA256.hexdigest(recovery) == Digest::SHA256.file(reviewed).hexdigest
  end
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
