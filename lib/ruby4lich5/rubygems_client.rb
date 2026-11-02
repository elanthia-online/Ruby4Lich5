# frozen_string_literal: true

require 'net/http'
require 'json'
require 'tmpdir'
require 'digest'
require_relative 'verified_https'
require_relative 'safe_token'

module Ruby4Lich5
  # Thin HTTP boundary around rubygems.org. Everything the classifier needs to
  # know about a gem's published versions or contents flows through here, so
  # the rest of the codebase never talks to +Net::HTTP+ directly and specs
  # never need real network access -- inject a double for {#http_get} instead.
  class RubygemsClient
    # Raised when rubygems.org returns anything other than a 200 for a
    # request this client cannot recover from on its own, or when a 200
    # response doesn't have the shape this client expects.
    class RequestError < StandardError; end
    class IntegrityError < RequestError; end

    BASE_URL = 'https://rubygems.org'
    private_constant :BASE_URL

    # @param http_get [#call] a callable of the form +->(uri) { body_string }+.
    #   Defaults to a real network call; specs should inject a stub or spy.
    def initialize(http_get: method(:default_http_get))
      @http_get = http_get
    end

    # Fetches every published version of a gem, across all platforms.
    #
    # @param gem_name [String]
    # @return [Array<Hash>] one entry per published version, each with at
    #   least +"number"+ and +"platform"+ keys (rubygems.org's own field
    #   names, passed through unmodified)
    # @raise [ArgumentError] if +gem_name+ is missing or contains unsafe
    #   characters
    # @raise [RequestError] if the request fails, the response isn't valid
    #   JSON, or the parsed JSON isn't the expected array-of-hashes shape
    def versions(gem_name)
      SafeToken.validate!(gem_name, 'gem name')

      body = @http_get.call(URI("#{BASE_URL}/api/v1/versions/#{gem_name}.json"))
      parsed = JSON.parse(body.dup.force_encoding('UTF-8').scrub)
      validate_versions_shape!(parsed, gem_name)
      parsed
    rescue JSON::ParserError => e
      raise IntegrityError, "malformed versions response for #{gem_name}: #{e.message}"
    end

    # The real, non-prerelease, +Gem::Version+-maximal published version --
    # per docs/DECISIONS.md Phase 17 SS8's "latest defined precisely," used
    # to pin an ordinary root's exact version before {#versions} is fed into
    # +ClosureResolver#resolve_closure+ (which requires an exact version,
    # never "whatever's current"). Never a string sort -- +"9.0" < "10.0"+
    # lexically, but not by real semver.
    #
    # Formalized here, found in review: this exact logic already existed,
    # copy-pasted ad hoc inside +bin/derive_curated_gems_seed.rb+, with zero
    # dedicated unit coverage of its own -- only ever exercised indirectly
    # through a real, live derivation run. A single version number can
    # appear more than once in {#versions}' raw response, once per
    # platform-specific artifact published for it (a pure gem's every entry
    # shares one +"ruby"+ platform; a native gem may publish +"ruby"+
    # *and* a target-platform build for the same number) -- +Gem::Version+
    # comparison across however many duplicate-by-number entries exist
    # still correctly finds the true maximum either way, so no separate
    # platform-aware branch is needed here.
    #
    # @param gem_name [String]
    # @return [String] the selected version number
    # @raise [ArgumentError] if +gem_name+ is missing or contains unsafe
    #   characters
    # @raise [RequestError] if no non-prerelease version is published at
    #   all, or any entry's +"number"+ field is malformed
    def latest_version(gem_name)
      entries = versions(gem_name)
      entries.each { |v| validate_version_number!(v, gem_name) }

      candidate = entries
                  .map { |v| Gem::Version.new(v.fetch('number')) }
                  .reject(&:prerelease?)
                  .max
      raise RequestError, "no non-prerelease version found for #{gem_name}" if candidate.nil?

      candidate.to_s
    end

    # Builds the exact asset filename rubygems.org publishes for a gem
    # version and platform -- the single source of truth for this naming
    # rule. {#download_gem} calls this internally; callers that need to know
    # the asset name ahead of (or without) a download, such as
    # {Classifier#pass_through_classification}, should call this instead of
    # building the string themselves, so the two can never drift apart.
    #
    # @param gem_name [String]
    # @param version [String] exact version number, e.g. +"3.5.6"+
    # @param platform [String] the RubyGems platform tag, e.g.
    #   +"x64-mingw-ucrt"+, or +"ruby"+ for the platform-independent source gem
    # @return [String]
    # @raise [ArgumentError] if +gem_name+, +version+, or +platform+ is
    #   missing, malformed, or contains unsafe characters
    def asset_filename(gem_name, version, platform)
      SafeToken.validate!(gem_name, 'gem name')
      validate_version!(version)
      SafeToken.validate!(platform, 'platform')

      platform == 'ruby' ? "#{gem_name}-#{version}.gem" : "#{gem_name}-#{version}-#{platform}.gem"
    end

    # Downloads one exact gem package and saves it to a temp file.
    #
    # Deliberately does not clean up the temp file or its containing
    # directory -- each call needs its download to outlive this method call
    # (the classifier inspects it afterward), and this runs inside one-shot CI
    # jobs whose whole filesystem is discarded on exit, so per-call cleanup
    # would be complexity without a real benefit here.
    #
    # @param gem_name [String]
    # @param version [String] exact version number, e.g. +"3.5.6"+
    # @param platform [String] the RubyGems platform tag, e.g.
    #   +"x64-mingw-ucrt"+, or +"ruby"+ for the platform-independent source gem
    # @return [String] path to the downloaded +.gem+ file on local disk
    # @raise [ArgumentError] if +gem_name+, +version+, or +platform+ is
    #   missing, malformed, or contains unsafe characters
    # @raise [RequestError] if the download fails
    def download_gem(gem_name, version, platform: 'ruby')
      filename = asset_filename(gem_name, version, platform)
      entry = versions(gem_name).find { |item| item['number'] == version && item['platform'] == platform }
      expected = entry && entry['sha']
      raise IntegrityError, "missing package SHA-256 for #{filename}" unless expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/)
      body = @http_get.call(URI("#{BASE_URL}/downloads/#{filename}"))
      raise IntegrityError, "package SHA-256 mismatch for #{filename}" unless Digest::SHA256.hexdigest(body) == expected

      path = File.join(Dir.mktmpdir('ruby4lich5-gem-'), filename)
      File.binwrite(path, body)
      path
    end

    private

    # @param version [Object] candidate version string
    # @raise [ArgumentError] if +version+ is nil, blank, or not a
    #   RubyGems-correct version string. +Gem::Version.correct?+ alone is not
    #   enough here -- verified directly that it treats +nil+ and +""+ as
    #   correct (it's designed to mean "no constraint", not "valid input"),
    #   so the nil/blank checks must come first.
    def validate_version!(version)
      raise ArgumentError, 'version must not be nil or empty' if version.nil? || version.to_s.strip.empty?
      return if Gem::Version.correct?(version)

      raise ArgumentError, "version is not a valid RubyGems version: #{version.inspect}"
    end

    # @param entry [Hash] one raw {#versions} response entry
    # @param gem_name [String] used only in the raised error message
    # @raise [RequestError] if +entry['number']+ isn't a real, non-blank
    #   RubyGems version string -- real gap, found in review:
    #   +Gem::Version.new+ silently coerces +nil+/+""+ to +"0"+ and an
    #   Integer like +7+ to +"7"+ rather than raising, the exact same
    #   "correct? treats blank as valid" trap {#validate_version!}'s own
    #   doc comment already names for a different call path. Confirmed
    #   live: an upstream +{"number":null,...}+ or +{"number":"",...}+
    #   entry was silently treated as a real, selectable version +"0"+
    #   instead of being rejected as malformed.
    def validate_version_number!(entry, gem_name)
      number = entry['number']
      return if number.is_a?(String) && !number.strip.empty? && Gem::Version.correct?(number)

      raise IntegrityError, "malformed version number in versions response for #{gem_name}: #{number.inspect}"
    end

    # @param parsed [Object] the result of +JSON.parse+ on a versions response
    # @param gem_name [String] used only in the raised error message
    # @raise [RequestError] unless +parsed+ is an +Array+ of +Hash+es each
    #   carrying string +"number"+ and +"platform"+ keys
    def validate_versions_shape!(parsed, gem_name)
      valid = parsed.is_a?(Array) && parsed.all? do |entry|
        entry.is_a?(Hash) && entry.key?('number') && entry.key?('platform')
      end
      return if valid

      raise IntegrityError,
            "unexpected versions response shape for #{gem_name}: expected an array of " \
            "{\"number\", \"platform\"} objects, got #{parsed.class}"
    end

    # @param uri [URI]
    # @return [String] response body
    # @raise [RequestError] on any non-200 response or transport failure
    def default_http_get(uri)
      VerifiedHttps.read(uri.to_s)
    rescue StandardError => e
      raise e if e.is_a?(RequestError)

      raise RequestError, "GET #{uri} failed: #{e.message}"
    end
  end
end
