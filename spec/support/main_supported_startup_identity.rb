# frozen_string_literal: true

require 'json'
require 'digest'
require 'ruby4lich5/supported_startup_policy'

# SupportedStartupPolicy.identity exactly as it was before platform scopes
# (main at 1114f9d), reading the same committed files. Unscoped (x64)
# approvals must stay byte-identical to it, so this copy must not change.
# A committed JSON golden would instead go stale with every reviewed-source
# re-pin and client registration, which change both sides equally.
module MainSupportedStartupIdentity
  POLICY = Ruby4Lich5::SupportedStartupPolicy

  def self.identity(contract, published_releases:)
    config = JSON.parse(File.binread(POLICY::CONFIG))
    unless config['schema'] == 1 && config.fetch('legacy').keys.sort == %w[current oldest] &&
           config.fetch('modes') == { 'core' => %w[default profanity], 'gtk' => %w[default profanity gtk] }
      raise ArgumentError, 'supported-client matrix must retain current/oldest core and GTK coverage'
    end
    source = JSON.parse(File.binread(POLICY::SOURCE))
    unless source['source_repository'] == 'elanthia-online/lich-5' && source.fetch('source_commit').match?(/\A[0-9a-f]{40}\z/) &&
           source.fetch('files').keys.sort == POLICY::REVIEWED_FILES.keys.sort
      raise ArgumentError, 'invalid reviewed startup source identity'
    end
    POLICY::REVIEWED_FILES.each do |path, vendored|
      unless Digest::SHA256.file(File.join(POLICY::ROOT, 'vendor/lich5', vendored)).hexdigest == source.fetch('files').fetch(path)
        raise ArgumentError, "reviewed startup source changed: #{path}"
      end
    end
    Ruby4Lich5::ReviewedArchiveReader.pinned
    clients = config.fetch('legacy').map do |id, entry|
      unless entry.fetch('commit') == Ruby4Lich5::RecoveryConsumers.entry(id).fetch('commit') &&
             Digest::SHA256.file(File.join(POLICY::ROOT, entry.fetch('gemfile'))).hexdigest == entry.fetch('gemfile_sha256')
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
             Digest::SHA256.file(POLICY.send(:safe_path, entry.fetch('gemfile'))).hexdigest == entry.fetch('gemfile_sha256')
        raise ArgumentError, 'invalid supported startup revision'
      end
      POLICY.send(:verify_files!, POLICY.send(:safe_path, entry.fetch('source_directory')), entry.fetch('files'))
      clients << entry.merge('id' => id, 'execution' => 'startup')
    end
    clients << { 'id' => 'ranged', 'execution' => 'startup', 'commit' => contract.fetch('lich5_commit'),
                 'lich_version' => contract.fetch('lich_version'), 'gemfile_sha256' => contract.fetch('gemfile_sha256'), 'files' => source.fetch('files') }
    Ruby4Lich5::PublishedStartupReleases.verify!(published_releases, clients: clients, retired: config.fetch('retired'))
    identity = { 'published_releases' => published_releases, 'configuration_sha256' => Digest::SHA256.file(POLICY::CONFIG).hexdigest, 'reviewed_source' => source,
                 'clients' => clients.flat_map { |client| config.fetch('modes').map { |mode, groups| client.merge('id' => "#{client.fetch('id')}-#{mode}", 'groups' => groups) } } }
    captured_tags = published_releases.fetch('clients').map { |release| release.fetch('tag') }
    unused = config.fetch('retired').reject { |tag, _entry| captured_tags.include?(tag) }.sort.to_h
    identity['unused_retirements'] = unused unless unused.empty?
    identity
  end
end
