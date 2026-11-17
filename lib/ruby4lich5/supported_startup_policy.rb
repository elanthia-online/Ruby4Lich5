# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'rbconfig'
require_relative 'recovery_consumers'
require_relative 'published_startup_releases'
require_relative 'reviewed_archive_reader'
require_relative 'target_platform'
require_relative '../../vendor/lich5/runtime_gem_contract'
require_relative '../../vendor/lich5/recovery_unit_policy'

module Ruby4Lich5
  # Check declarations and served floors before recovery installs anything.
  # Actual legacy parsers and native recovery still run in their own gate jobs.
  class SupportedStartupPolicy
    ROOT = File.expand_path('../..', __dir__)
    CONFIG = File.join(ROOT, 'config/supported-startup-clients.json')
    # Per-platform client scopes live in their own file so the clients file,
    # and with it every unscoped (x64) approval, keeps its exact bytes.
    SCOPES = File.join(ROOT, 'config/supported-startup-platform-scopes.json')
    SCOPE_KEYS = %w[legacy ranged soak startup].freeze
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

    # The supported-client approval for a candidate contract: the reviewed
    # startup source, every registered client (retention runs over all of
    # them), and configuration_sha256. A platform with a scope keeps only its
    # scoped clients and hashes scope_projection; any other platform hashes
    # the clients file itself, exactly as before scopes existed.
    def self.identity(contract, published_releases:)
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
      # reviewed_source below carries the reader pin into the approval digest.
      ReviewedArchiveReader.pinned
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
                   'lich_version' => contract.fetch('lich_version'), 'gemfile_sha256' => contract.fetch('gemfile_sha256'), 'files' => source.fetch('files') }
      # Retention always covers every registered client: a platform scope
      # narrows what is checked for that platform, never what was published.
      PublishedStartupReleases.verify!(published_releases, clients: clients, retired: config.fetch('retired'))
      platform = candidate_platform(contract)
      scope = platform_scope(platform, config)
      configuration = Digest::SHA256.file(CONFIG).hexdigest
      if scope
        allowed = scope.fetch('legacy') + scope.fetch('startup') + scope.fetch('soak') + ['ranged']
        clients = clients.select { |client| allowed.include?(client.fetch('id')) }
        configuration = Digest::SHA256.hexdigest(JSON.generate(scope_projection(platform, scope, config)))
      end
      identity = { 'published_releases' => published_releases, 'configuration_sha256' => configuration, 'reviewed_source' => source,
                   'clients' => clients.flat_map { |client| config.fetch('modes').map { |mode, groups| client.merge('id' => "#{client.fetch('id')}-#{mode}", 'groups' => groups) } } }
      captured_tags = published_releases.fetch('clients').map { |release| release.fetch('tag') }
      unused = config.fetch('retired').reject { |tag, _entry| captured_tags.include?(tag) }.sort.to_h
      identity['unused_retirements'] = unused unless unused.empty?
      identity['platform_scope'] = scope.merge('platform' => platform) if scope
      identity
    end

    # The reviewed client scope for a platform, or nil when the platform keeps
    # every registered client (x64, or a contract that names no platform).
    # Only the requested platform's entry is validated, so an unfinished entry
    # for another platform cannot halt this one; validate_scopes! checks the
    # whole file in CI. The platform always comes from the candidate contract
    # (candidate_platform), never the host.
    def self.platform_scope(platform, config = JSON.parse(File.binread(CONFIG)))
      platforms = scope_platforms
      return nil unless platform.is_a?(String) && platforms.key?(platform)

      validate_scope_entry!(platform, platforms.fetch(platform), config)
    end

    # Every entry in the scopes file, each against the clients file and the
    # platform table. The config spec runs this on the committed files.
    def self.validate_scopes!(config = JSON.parse(File.binread(CONFIG)))
      scope_platforms.each { |name, entry| validate_scope_entry!(name, entry, config) }
      true
    end

    # The platform a candidate is approved for: its contract's measured
    # RubyGems platform. identity, verify! and bin/recovery_smoke.rb's skip
    # decision all read it here, so they cannot disagree.
    def self.candidate_platform(contract)
      contract.dig('ruby_inventory', 'platform')
    end

    # The single runtime target's contract in candidate manifest bytes.
    def self.candidate_contract(manifest_bytes)
      JSON.parse(manifest_bytes).fetch('targets').fetch(0).fetch('contract')
    end

    # The scopes file's platforms object, after its top-level shape check.
    # The file is shared by every platform, so this runs on every call.
    def self.scope_platforms
      document = JSON.parse(File.binread(SCOPES))
      unless document.is_a?(Hash) && document.keys.sort == %w[platforms schema] && document['schema'] == 1 && document['platforms'].is_a?(Hash)
        raise ArgumentError, 'supported-client platform scopes must be schema 1 with a platforms object'
      end
      document.fetch('platforms')
    end

    # One scope entry: a platform-table row, exactly SCOPE_KEYS, the ranged
    # consumer kept, unique lists naming registered clients, and no client in
    # both startup and soak. Returns the entry.
    def self.validate_scope_entry!(name, entry, config)
      legacy = config.fetch('legacy').keys
      startup = config.fetch('startup').keys
      lists = entry.is_a?(Hash) ? entry.values_at('legacy', 'startup', 'soak') : []
      unless TargetPlatform.load_table.key?(name) && entry.is_a?(Hash) && entry.keys.sort == SCOPE_KEYS && entry['ranged'] == true &&
             lists.all? { |list| list.is_a?(Array) && list.all?(String) && list.uniq == list } &&
             (entry['legacy'] - legacy).empty? && (entry['startup'] + entry['soak'] - startup).empty? && (entry['startup'] & entry['soak']).empty?
        raise ArgumentError, "invalid supported-client scope for #{name}: entries must name registered clients and keep the ranged consumer"
      end
      entry
    end

    # What a scoped platform's approval hashes in place of the whole clients
    # file: every top-level key, with legacy and startup narrowed to the
    # entries the scope keeps, plus the platform and its scope. Starting from
    # the whole file means a key added later is bound here as it is for x64.
    def self.scope_projection(platform, scope, config)
      config.merge('platform' => platform, 'scope' => scope,
                   'legacy' => config.fetch('legacy').slice(*scope.fetch('legacy')),
                   'startup' => config.fetch('startup').slice(*(scope.fetch('startup') + scope.fetch('soak'))))
    end

    # On the target runner: re-derive identity from the candidate bytes, require
    # it to equal the inspected approval, then run every approved client's
    # checker against the served floors. Returns the digest the ranged receipt
    # binds.
    def self.verify!(manifest_bytes:, context:, source_directory:)
      unless "sha256:#{Digest::SHA256.hexdigest(manifest_bytes)}" == context.fetch('candidate_sha256')
        raise ArgumentError, 'supported-client candidate bytes changed'
      end
      contract = candidate_contract(manifest_bytes)
      expected = identity(contract, published_releases: context.fetch('supported_startup_policy').fetch('published_releases'))
      raise ArgumentError, 'supported-client matrix differs from inspected approval' unless expected == context.fetch('supported_startup_policy')

      expected.fetch('reviewed_source').fetch('files').each do |path, digest|
        unless Digest::SHA256.file(File.join(source_directory, path)).hexdigest == digest
          raise ArgumentError, "selected startup checker differs from reviewed source: #{path}"
        end
      end
      version = File.read(File.join(source_directory, 'lib/version.rb'))[/^LICH_VERSION = '([^']+)'/, 1]
      raise ArgumentError, 'selected candidate version differs from its contract' unless version == contract.fetch('lich_version')

      # Clients start on any RubyInstaller from the published floors up, so
      # each checker runs against the floors and again against the measured
      # build installer's gems. The second manifest exists only for this
      # check; it is never published.
      served = [manifest_bytes]
      if contract.key?('measured_ruby_inventory')
        document = JSON.parse(manifest_bytes)
        document.fetch('targets').fetch(0).fetch('contract')['ruby_inventory'] = contract.fetch('measured_ruby_inventory')
        served << JSON.generate(document)
      end
      # Startup also accepts every package from its minimum up, so with any
      # package minimum below its version each checker runs once more with
      # every package served at its minimum. Like the measured manifest it is
      # never published, and with no minimums nothing more runs.
      minimum = minimum_tuple(manifest_bytes)
      served << minimum if minimum
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
          served.each { |bytes| run_checker!(legacy_program, consumer.fetch('absolute_path'), bytes, roots) }
        else
          served.each { |bytes| run_checker!(startup_program, File.join(directory, 'lib/startup_policy_compatibility.rb'), bytes, clients) }
        end
      end

      Digest::SHA256.hexdigest(JSON.generate(expected))
    end

    # @return [String, nil] the manifest with each package's +version+ set to
    #   its minimum (keeping its filename, so platform and gem-artifact
    #   checks still hold), or nil when no minimum is below its version
    def self.minimum_tuple(manifest_bytes)
      document = JSON.parse(manifest_bytes)
      lowered = false
      document.fetch('targets').each do |target|
        target.fetch('units').each do |unit|
          unit.fetch('packages').each do |package|
            minimum = Lich::RecoveryUnitPolicy.package_minimum(package)
            package.delete('minimum')
            next if Gem::Version.new(minimum) == Gem::Version.new(package.fetch('version'))

            package['version'] = minimum
            lowered = true
          end
        end
      end
      lowered ? JSON.generate(document) : nil
    end
    private_class_method :minimum_tuple

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
    private_class_method :scope_platforms, :validate_scope_entry!, :scope_projection, :safe_path, :verify_files!, :run_checker!, :startup_program, :legacy_program
  end
end
