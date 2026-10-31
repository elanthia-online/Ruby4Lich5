# frozen_string_literal: true

require 'json'
require 'base64'
require 'digest'
require 'open3'
require 'uri'

module Ruby4Lich5
  # Inspect published source without executing it. Presence of the accepted-policy
  # implementation conservatively requires retention, including prereleases.
  class PublishedStartupReleases
    REPOSITORY = 'elanthia-online/lich-5'
    FILES = %w[Gemfile lib/runtime_gem_contract.rb lib/dependency_recovery.rb lib/recovery_unit_policy.rb lib/accepted_gem_policy.rb lib/startup_policy_compatibility.rb].freeze

    def self.request(endpoint)
      output, error, status = Open3.capture3('gh', 'api', "repos/#{REPOSITORY}/#{endpoint}")
      raise ArgumentError, "published-client acquisition failed: #{error}" unless status.success?
      JSON.parse(output)
    end

    def self.capture(request: method(:request))
      releases = []
      page = 1
      loop do
        batch = request.call("releases?per_page=100&page=#{page}")
        raise ArgumentError, 'incomplete published release inventory' unless batch.is_a?(Array) && batch.size <= 100
        incoming = batch.map { |release| release.fetch('id') }
        if incoming.uniq != incoming || !(incoming & releases.map { |release| release.fetch('id') }).empty?
          raise ArgumentError, 'duplicate published release page'
        end
        releases.concat(batch)
        break if batch.size < 100
        page += 1
      end
      ids = releases.map { |release| release.fetch('id') }
      raise ArgumentError, 'duplicate published release page' unless ids.uniq == ids
      clients = releases.reject { |release| release.fetch('draft') }.map do |release|
        tag = release.fetch('tag_name')
        commit = request.call("commits/#{URI.encode_www_form_component(tag)}").fetch('sha')
        raise ArgumentError, 'release did not resolve to a full source commit' unless commit.match?(/\A[0-9a-f]{40}\z/)
        tree = request.call("git/trees/#{commit}?recursive=1")
        raise ArgumentError, 'incomplete release source tree' unless tree['truncated'] == false && tree['tree'].is_a?(Array)
        entries = tree.fetch('tree').to_h { |entry| [entry.fetch('path'), entry] }
        next unless entries.key?('lib/accepted_gem_policy.rb')
        paths = (FILES + ['lib/version.rb']).to_h do |path|
          entry = entries.fetch(path) { raise ArgumentError, "published policy client lacks required retained source: #{tag}:#{path}" }
          raise ArgumentError, 'release source must contain regular blobs' unless entry['type'] == 'blob' && entry['mode'] == '100644'
          blob = request.call("git/blobs/#{entry.fetch('sha')}")
          raise ArgumentError, 'release source blob identity changed' unless blob['sha'] == entry['sha'] && blob['encoding'] == 'base64'
          bytes = Base64.strict_decode64(blob.fetch('content').delete("\n"))
          actual = Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0" + bytes)
          raise ArgumentError, 'release source blob bytes changed' unless actual == entry['sha']
          [path, bytes]
        end
        version = paths.fetch('lib/version.rb')[/^LICH_VERSION = '([^']+)'/, 1]
        raise ArgumentError, "published policy client has no explicit version: #{tag}" unless version && Gem::Version.correct?(version)
        { 'release_id' => release.fetch('id'), 'tag' => tag, 'prerelease' => release.fetch('prerelease'),
          'commit' => commit, 'lich_version' => version, 'files' => paths.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } }
      end.compact.sort_by { |client| client.fetch('tag') }
      { 'schema' => 1, 'repository' => REPOSITORY, 'complete' => true,
        'release_ids' => ids.sort, 'clients' => clients }
    end

    def self.verify!(inventory, clients:, retired:)
      unless inventory.is_a?(Hash) && inventory['schema'] == 1 && inventory['repository'] == REPOSITORY && inventory['complete'] == true &&
             inventory['release_ids'].is_a?(Array) && inventory['release_ids'].all? { |id| id.is_a?(Integer) && id.positive? } &&
             inventory['release_ids'].uniq == inventory['release_ids'] && inventory['clients'].is_a?(Array) && retired.is_a?(Hash)
        raise ArgumentError, 'complete published-client inventory is required'
      end
      inventory.fetch('clients').each do |release|
        unless release.is_a?(Hash) && inventory.fetch('release_ids').include?(release['release_id']) &&
               release['commit'].is_a?(String) && release['commit'].match?(/\A[0-9a-f]{40}\z/) &&
               release['lich_version'].is_a?(String) && Gem::Version.correct?(release['lich_version']) &&
               release['files'].is_a?(Hash) && release['files'].keys.sort == (FILES + ['lib/version.rb']).sort &&
               release['files'].values.all? { |digest| digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) }
          raise ArgumentError, 'invalid published-client source identity'
        end
        retirement = retired[release.fetch('tag')]
        if retirement
          unless retirement.is_a?(Hash) && retirement['commit'] == release.fetch('commit') &&
                 retirement['reason'].is_a?(String) && !retirement['reason'].strip.empty?
            raise ArgumentError, 'retirement must name the exact published commit and a reviewed reason'
          end
          next
        end
        covered = clients.any? do |client|
          next false unless Gem::Version.new(client.fetch('lich_version')) == Gem::Version.new(release.fetch('lich_version'))
          files = client.fetch('files', {}).merge('Gemfile' => client.fetch('gemfile_sha256'))
          FILES.all? { |path| files[path] == release.fetch('files').fetch(path) }
        end
        raise ArgumentError, "published policy client is missing from retention: #{release.fetch('tag')} (#{release.fetch('lich_version')})" unless covered
      end
      true
    end
  end
end
