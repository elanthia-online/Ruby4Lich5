# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'rbconfig'
require_relative 'recovery_consumers'
require_relative '../../vendor/lich5/runtime_gem_contract'

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
      clients.each { |client| client['execution'] = 'legacy-recovery' }
      startup = config.fetch('startup')
      raise ArgumentError, 'supported startup revisions must be an object' unless startup.is_a?(Hash)
      startup.each do |id, entry|
        unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]+\z/) && !%w[current oldest ranged].include?(id) &&
               entry.is_a?(Hash) && entry.fetch('commit').match?(/\A[0-9a-f]{40}\z/) &&
               Digest::SHA256.file(safe_path(entry.fetch('gemfile'))).hexdigest == entry.fetch('gemfile_sha256')
          raise ArgumentError, 'invalid supported startup revision'
        end
        verify_files!(safe_path(entry.fetch('source_directory')), entry.fetch('files'))
        clients << entry.merge('id' => id, 'execution' => 'startup')
      end
      clients << { 'id' => 'ranged', 'execution' => 'startup', 'commit' => contract.fetch('lich5_commit'),
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

      expected.fetch('clients').group_by { |client| client.fetch('id').sub(/-(?:core|gtk)\z/, '') }.each do |id, group|
        legacy = group.first.fetch('execution') == 'legacy-recovery'
        directory = id == 'ranged' ? source_directory : (legacy ? nil : safe_path(group.first.fetch('source_directory')))
        verify_files!(directory, group.first.fetch('files')) if !legacy && id != 'ranged'
        clients = group.map do |client|
          path = id == 'ranged' ? File.join(source_directory, 'Gemfile') : safe_path(client.fetch('gemfile'))
          bytes = File.binread(path)
          raise ArgumentError, "client Gemfile changed: #{client.fetch('id')}" unless Digest::SHA256.hexdigest(bytes) == client.fetch('gemfile_sha256')
          if legacy
            # Literal branch projection only; retirement follows legacy clients.
            raise ArgumentError, 'unsupported legacy Windows declaration' unless bytes.scan(LEGACY_SQLITE).size == 1
            bytes = bytes.sub(LEGACY_SQLITE, "gem 'sqlite3'\n")
          end
          client.merge('gemfile' => bytes)
        end
        if legacy
          consumer = RecoveryConsumers.entry(id)
          roots = clients.map do |client|
            client.merge('roots' => Lich::RuntimeGemContract.new(gemfile: client.fetch('gemfile'), groups: client.fetch('groups')).roots)
          end
          run_checker!(legacy_program, consumer.fetch('absolute_path'), manifest_bytes, roots)
        else
          run_checker!(startup_program, File.join(directory, 'lib/startup_policy_compatibility.rb'), manifest_bytes, clients)
        end
      end

      Digest::SHA256.hexdigest(JSON.generate(expected))
    end

    def self.safe_path(relative)
      raise ArgumentError, 'supported source path must be relative' unless relative.is_a?(String) && !relative.start_with?('/', '\\') && !relative.match?(/\A[A-Za-z]:/)
      path = File.realpath(File.join(ROOT, relative))
      raise ArgumentError, 'supported source path escapes repository' unless path.start_with?(File.realpath(ROOT) + File::SEPARATOR)
      path
    end

    def self.verify_files!(directory, files)
      unless files.is_a?(Hash) && files.keys.sort == REVIEWED_FILES.keys.sort && files.all? do |path, digest|
        digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(File.join(directory, path)).hexdigest == digest
      end
        raise ArgumentError, 'supported startup implementation differs from pinned revision'
      end
    end

    def self.run_checker!(program, path, manifest, clients)
      environment = { 'RUBYOPT' => nil, 'RUBYLIB' => nil, 'BUNDLER_SETUP' => nil, 'RUBYGEMS_GEMDEPS' => nil }
      output, error, status = Open3.capture3(environment, RbConfig.ruby, '-e', program, path, stdin_data: JSON.generate('manifest' => manifest, 'clients' => clients))
      raise ArgumentError, "supported startup policy rejected: #{error}" unless status.success?
      result = JSON.parse(output)
      raise ArgumentError, 'supported startup checker omitted clients' unless result.keys.sort == clients.map { |client| client.fetch('id') }.sort
    end

    def self.startup_program
      <<~'RUBY'
        require 'json'
        require ARGV.fetch(0)
        input = JSON.parse($stdin.read)
        result = Lich::StartupPolicyCompatibility.verify!(manifest_bytes: input.fetch('manifest'), clients: input.fetch('clients'))
        puts JSON.generate(result)
      RUBY
    end

    def self.legacy_program
      <<~'RUBY'
        require 'json'
        require ARGV.fetch(0)
        input = JSON.parse($stdin.read)
        document = JSON.parse(input.fetch('manifest'))
        target = document.fetch('targets').first
        supplied = target.dig('contract', 'ruby_inventory', 'gems') || {}
        result = input.fetch('clients').to_h do |client|
          recovery = Lich::DependencyRecovery.new(http_get: ->(_url) { input.fetch('manifest') })
          recovery.define_singleton_method(:ruby_abi) { target.fetch('ruby_abi') }
          recovery.send(:load_manifest)
          roots = client.fetch('roots')
          plan = recovery.recovery_plan(roots.keys - supplied.keys)
          raise "supported client #{client.fetch('id')}: #{plan.error}" unless plan.success?
          packages = plan.units.flat_map { |unit| unit.fetch('packages') }
          roots.each do |name, requirements|
            version = supplied.dig(name, 'version') || packages.find { |package| package['name'] == name }&.fetch('version')
            unless version && Gem::Requirement.new(requirements).satisfied_by?(Gem::Version.new(version))
              raise "supported client #{client.fetch('id')}: incompatible legacy root #{name}"
            end
          end
          [client.fetch('id'), roots.keys.sort]
        end
        puts JSON.generate(result)
      RUBY
    end
    private_class_method :safe_path, :verify_files!, :run_checker!, :startup_program, :legacy_program
  end
end
