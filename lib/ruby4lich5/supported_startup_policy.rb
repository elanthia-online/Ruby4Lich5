# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'rbconfig'
require_relative 'recovery_consumers'

module Ruby4Lich5
  # Check declarations and served floors before recovery installs anything.
  # Actual legacy parsers and native recovery still run in their own gate jobs.
  class SupportedStartupPolicy
    ROOT = File.expand_path('../..', __dir__)
    CONFIG = File.join(ROOT, 'config/supported-startup-clients.json')
    SOURCE = File.join(ROOT, 'vendor/lich5/ranged-source.json')
    REVIEWED_FILES = {
      'lib/runtime_gem_contract.rb'         => 'runtime_gem_contract.rb',
      'lib/dependency_recovery.rb'          => 'dependency_recovery-ranged.rb',
      'lib/recovery_unit_policy.rb'         => 'recovery_unit_policy.rb',
      'lib/accepted_gem_policy.rb'          => 'accepted_gem_policy.rb',
      'lib/startup_policy_compatibility.rb' => 'startup_policy_compatibility.rb'
    }.freeze
    # Only these two pinned historical Gemfiles need this Windows projection.
    # Retire it when both legacy consumers are explicitly retired from CONFIG.
    LEGACY_SQLITE = <<~'GEMFILE'
      if Gem.win_platform?
        gem "sqlite3", platforms: :windows, force_ruby_platform: true
      else
        gem "sqlite3"
      end
    GEMFILE

    def self.identity(contract)
      config = JSON.parse(File.binread(CONFIG))
      unless config['schema'] == 1 && config.fetch('legacy').keys.sort == %w[current oldest] &&
             config.fetch('modes') == { 'core' => %w[default profanity], 'gtk' => %w[default profanity gtk] }
        raise ArgumentError, 'supported-client matrix must retain current/oldest core and GTK coverage'
      end
      source = JSON.parse(File.binread(SOURCE))
      unless source['source_repository'] == 'elanthia-online/lich-5' && source.fetch('source_commit').match?(/\A[0-9a-f]{40}\z/) &&
             source.fetch('files').keys.sort == REVIEWED_FILES.keys.sort
        raise ArgumentError, 'invalid reviewed startup source identity'
      end
      REVIEWED_FILES.each do |path, vendored|
        unless Digest::SHA256.file(File.join(ROOT, 'vendor/lich5', vendored)).hexdigest == source.fetch('files').fetch(path)
          raise ArgumentError, "reviewed startup source changed: #{path}"
        end
      end
      clients = config.fetch('legacy').map do |id, entry|
        unless entry.fetch('commit') == RecoveryConsumers.entry(id).fetch('commit') &&
               Digest::SHA256.file(File.join(ROOT, entry.fetch('gemfile'))).hexdigest == entry.fetch('gemfile_sha256')
          raise ArgumentError, "supported #{id} source identity differs"
        end
        entry.merge('id' => id)
      end
      clients << { 'id' => 'ranged', 'commit' => contract.fetch('lich5_commit'),
                   'lich_version' => contract.fetch('lich_version'), 'gemfile_sha256' => contract.fetch('gemfile_sha256') }
      { 'configuration_sha256' => Digest::SHA256.file(CONFIG).hexdigest, 'reviewed_source' => source,
        'clients' => clients.flat_map { |client| config.fetch('modes').map { |mode, groups| client.merge('id' => "#{client.fetch('id')}-#{mode}", 'groups' => groups) } } }
    end

    def self.verify!(manifest_bytes:, context:, source_directory:)
      unless "sha256:#{Digest::SHA256.hexdigest(manifest_bytes)}" == context.fetch('candidate_sha256')
        raise ArgumentError, 'supported-client candidate bytes changed'
      end
      target = JSON.parse(manifest_bytes).fetch('targets').fetch(0)
      contract = target.fetch('contract')
      expected = identity(contract)
      raise ArgumentError, 'supported-client matrix differs from inspected approval' unless expected == context.fetch('supported_startup_policy')

      expected.fetch('reviewed_source').fetch('files').each do |path, digest|
        unless Digest::SHA256.file(File.join(source_directory, path)).hexdigest == digest
          raise ArgumentError, "selected startup checker differs from reviewed source: #{path}"
        end
      end
      version = File.read(File.join(source_directory, 'lib/version.rb'))[/^LICH_VERSION = '([^']+)'/, 1]
      raise ArgumentError, 'selected candidate version differs from its contract' unless version == contract.fetch('lich_version')

      clients = expected.fetch('clients').map do |client|
        legacy = !client.fetch('id').start_with?('ranged-')
        path = legacy ? File.join(ROOT, client.fetch('gemfile')) : File.join(source_directory, 'Gemfile')
        bytes = File.binread(path)
        raise ArgumentError, "client Gemfile changed: #{client.fetch('id')}" unless Digest::SHA256.hexdigest(bytes) == client.fetch('gemfile_sha256')
        if legacy
          # This is a literal, checksummed Windows-only branch projection, not
          # Gemfile evaluation. Every other construct goes through the reader.
          raise ArgumentError, 'unsupported legacy Windows declaration' unless bytes.scan(LEGACY_SQLITE).size == 1
          bytes = bytes.sub(LEGACY_SQLITE, "gem 'sqlite3'\n")
        end
        client.merge('gemfile' => bytes)
      end
      program = <<~'RUBY'
        require 'json'
        require ARGV.fetch(0)
        input = JSON.parse($stdin.read)
        result = Lich::StartupPolicyCompatibility.verify!(manifest_bytes: input.fetch('manifest'), clients: input.fetch('clients'))
        puts JSON.generate(result)
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, '-e', program, File.join(source_directory, 'lib/startup_policy_compatibility.rb'),
                                             stdin_data: JSON.generate('manifest' => manifest_bytes, 'clients' => clients))
      raise ArgumentError, "supported startup policy rejected: #{error}" unless status.success?
      result = JSON.parse(output)
      raise ArgumentError, 'supported startup checker omitted clients' unless result.keys.sort == clients.map { |client| client.fetch('id') }.sort

      Digest::SHA256.hexdigest(JSON.generate(expected))
    end
  end
end
