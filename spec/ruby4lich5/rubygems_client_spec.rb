# frozen_string_literal: true

require 'ruby4lich5/rubygems_client'

RSpec.describe Ruby4Lich5::RubygemsClient do
  let(:unused_http_get) { ->(_uri) { raise 'http_get should not have been called' } }

  describe '#versions' do
    it 'parses the versions JSON response into an array of hashes' do
      body = '[{"number":"1.7.3","platform":"ruby"},{"number":"1.7.3","platform":"x64-mingw-ucrt"}]'
      http_get = ->(_uri) { body }
      client = described_class.new(http_get: http_get)

      result = client.versions('sqlite3')

      expect(result).to eq(
        [
          { 'number' => '1.7.3', 'platform' => 'ruby' },
          { 'number' => '1.7.3', 'platform' => 'x64-mingw-ucrt' }
        ]
      )
    end

    it 'requests the expected rubygems.org versions endpoint' do
      requested_uri = nil
      http_get = lambda do |uri|
        requested_uri = uri
        '[]'
      end
      client = described_class.new(http_get: http_get)

      client.versions('sqlite3')

      expect(requested_uri.to_s).to eq('https://rubygems.org/api/v1/versions/sqlite3.json')
    end

    it 'raises RequestError when the response is not valid JSON' do
      http_get = ->(_uri) { 'not json' }
      client = described_class.new(http_get: http_get)

      expect { client.versions('sqlite3') }
        .to raise_error(Ruby4Lich5::RubygemsClient::RequestError, /malformed versions response/)
    end

    it 'raises RequestError when the response is valid JSON but not an array' do
      http_get = ->(_uri) { '{"error":"not found"}' }
      client = described_class.new(http_get: http_get)

      expect { client.versions('sqlite3') }
        .to raise_error(Ruby4Lich5::RubygemsClient::RequestError, /unexpected versions response shape/)
    end

    it 'raises RequestError when the response is an array of non-hash elements' do
      http_get = ->(_uri) { '["not", "a", "hash"]' }
      client = described_class.new(http_get: http_get)

      expect { client.versions('sqlite3') }
        .to raise_error(Ruby4Lich5::RubygemsClient::RequestError, /unexpected versions response shape/)
    end

    it 'raises RequestError when array entries are missing the expected keys' do
      http_get = ->(_uri) { '[{"number":"1.7.3"}]' }
      client = described_class.new(http_get: http_get)

      expect { client.versions('sqlite3') }
        .to raise_error(Ruby4Lich5::RubygemsClient::RequestError, /unexpected versions response shape/)
    end

    it 'raises ArgumentError for a nil gem name without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.versions(nil) }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for an empty gem name without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.versions('') }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for a gem name containing a path traversal sequence' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.versions('../../etc/passwd') }
        .to raise_error(ArgumentError, /disallowed characters/)
    end
  end

  describe '#latest_version' do
    # Real gap, found in review: this exact selection logic previously only
    # existed copy-pasted inline in bin/derive_curated_gems_seed.rb, never
    # unit-tested on its own -- only ever exercised indirectly via a real,
    # live derivation run. These three shapes are the real ones Phase 17
    # SS14's acceptance matrix calls out by name.
    it 'picks the real Gem::Version-maximal non-prerelease version for a pure gem (every entry platform: "ruby")' do
      body = '[{"number":"2.0.0","platform":"ruby"},{"number":"1.9.0","platform":"ruby"},' \
             '{"number":"2.1.0.pre1","platform":"ruby"}]'
      client = described_class.new(http_get: ->(_uri) { body })

      expect(client.latest_version('kramdown')).to eq('2.0.0')
    end

    it 'picks the real maximal version for a native gem that has a matching target-platform build' do
      # Same version number published twice, once per platform -- the
      # maximum must still resolve correctly across the duplicate-by-number
      # entries, not be thrown off by there being more than one entry for
      # the winning version.
      body = '[{"number":"1.7.3","platform":"ruby"},{"number":"1.7.3","platform":"x64-mingw-ucrt"},' \
             '{"number":"1.6.0","platform":"ruby"},{"number":"1.6.0","platform":"x64-mingw-ucrt"}]'
      client = described_class.new(http_get: ->(_uri) { body })

      expect(client.latest_version('sqlite3')).to eq('1.7.3')
    end

    it 'picks the real maximal version for a source-only native gem with no precompiled target-platform build at all' do
      # Structurally identical to the pure-gem shape (every entry is
      # platform: "ruby") -- the distinction between "pure" and
      # "source-only native, self-build required" is a Classifier-time
      # concern (does the source gem declare native extensions?), not
      # something #latest_version's own version-number selection needs to
      # know or differentiate.
      body = '[{"number":"3.5.6","platform":"ruby"},{"number":"3.4.0","platform":"ruby"}]'
      client = described_class.new(http_get: ->(_uri) { body })

      expect(client.latest_version('gobject-introspection')).to eq('3.5.6')
    end

    it 'never picks by string comparison -- a real Gem::Version-maximal result, not a lexical one' do
      # "9.0" > "10.0" lexically but not by real semver -- proves a naive
      # string sort would have picked the wrong one here.
      body = '[{"number":"9.0.0","platform":"ruby"},{"number":"10.0.0","platform":"ruby"}]'
      client = described_class.new(http_get: ->(_uri) { body })

      expect(client.latest_version('widget')).to eq('10.0.0')
    end

    it 'excludes a prerelease-only latest number, falling back to the real latest non-prerelease' do
      body = '[{"number":"2.0.0.pre1","platform":"ruby"},{"number":"1.9.0","platform":"ruby"}]'
      client = described_class.new(http_get: ->(_uri) { body })

      expect(client.latest_version('widget')).to eq('1.9.0')
    end

    it 'raises RequestError when every published version is a prerelease' do
      body = '[{"number":"2.0.0.pre1","platform":"ruby"}]'
      client = described_class.new(http_get: ->(_uri) { body })

      expect { client.latest_version('widget') }
        .to raise_error(described_class::RequestError, /no non-prerelease version found for widget/)
    end

    describe 'malformed version numbers, found in review -- Gem::Version.new silently coerces these instead of raising' do
      it 'rejects a null "number" field rather than silently treating it as version "0"' do
        body = '[{"number":null,"platform":"ruby"}]'
        client = described_class.new(http_get: ->(_uri) { body })

        expect { client.latest_version('widget') }
          .to raise_error(described_class::RequestError, /malformed version number in versions response for widget/)
      end

      it 'rejects an empty-string "number" field rather than silently treating it as version "0"' do
        body = '[{"number":"","platform":"ruby"}]'
        client = described_class.new(http_get: ->(_uri) { body })

        expect { client.latest_version('widget') }
          .to raise_error(described_class::RequestError, /malformed version number in versions response for widget/)
      end

      it 'rejects an Integer "number" field rather than silently coercing it (7 -> "7")' do
        body = '[{"number":7,"platform":"ruby"}]'
        client = described_class.new(http_get: ->(_uri) { body })

        expect { client.latest_version('widget') }
          .to raise_error(described_class::RequestError, /malformed version number in versions response for widget/)
      end
    end
  end

  describe '#asset_filename' do
    it 'omits the platform segment for the ruby-platform source gem' do
      client = described_class.new(http_get: unused_http_get)

      expect(client.asset_filename('sqlite3', '1.7.3', 'ruby')).to eq('sqlite3-1.7.3.gem')
    end

    it 'includes the platform segment for a platform-qualified gem' do
      client = described_class.new(http_get: unused_http_get)

      expect(client.asset_filename('sqlite3', '1.7.3', 'x64-mingw-ucrt')).to eq('sqlite3-1.7.3-x64-mingw-ucrt.gem')
    end

    it 'raises ArgumentError for a Symbol platform rather than silently building the wrong filename' do
      # Regression: a Symbol :ruby is never == the String literal 'ruby', so
      # the platform == 'ruby' branch would silently take the *other* path
      # and produce "sqlite3-1.7.3-ruby.gem" instead of "sqlite3-1.7.3.gem"
      # if SafeToken accepted and coerced non-String input instead of
      # rejecting it outright. gem_name and version are kept as valid Strings
      # here specifically so this isolates the platform check -- a Symbol
      # gem name would raise on that validation first and never actually
      # exercise the platform path this example is about.
      client = described_class.new(http_get: unused_http_get)

      expect { client.asset_filename('sqlite3', '1.7.3', :ruby) }
        .to raise_error(ArgumentError, /must be a String, got Symbol/)
    end
  end

  describe '#download_gem' do
    it 'rejects package bytes that differ from upstream metadata before returning a path' do
      http_get = ->(uri) { uri.path.start_with?('/api/') ? JSON.generate([{ 'number' => '1.0', 'platform' => 'ruby', 'sha' => '0' * 64 }]) : 'different bytes' }
      client = described_class.new(http_get: http_get)
      expect { client.download_gem('example', '1.0') }.to raise_error(described_class::RequestError, /SHA-256 mismatch/)
    end

    it 'rejects package inputs without an upstream checksum' do
      client = described_class.new(http_get: ->(_uri) { JSON.generate([{ 'number' => '1.0', 'platform' => 'ruby' }]) })
      expect { client.download_gem('example', '1.0') }.to raise_error(described_class::RequestError, /missing package SHA-256/)
    end

    it 'requests the ruby-platform filename when no platform is given' do
      requested_uri = nil
      http_get = lambda do |uri|
        requested_uri = uri
        uri.path.start_with?('/api/') ? JSON.generate([{ 'number' => '1.7.3', 'platform' => 'ruby', 'sha' => Digest::SHA256.hexdigest('gem bytes') }, { 'number' => '1.7.3', 'platform' => 'x64-mingw-ucrt', 'sha' => Digest::SHA256.hexdigest('gem bytes') }]) : 'gem bytes'
      end
      client = described_class.new(http_get: http_get)

      client.download_gem('sqlite3', '1.7.3')

      expect(requested_uri.to_s).to eq('https://rubygems.org/downloads/sqlite3-1.7.3.gem')
    end

    it 'requests the platform-qualified filename when a platform is given' do
      requested_uri = nil
      http_get = lambda do |uri|
        requested_uri = uri
        uri.path.start_with?('/api/') ? JSON.generate([{ 'number' => '1.7.3', 'platform' => 'ruby', 'sha' => Digest::SHA256.hexdigest('gem bytes') }, { 'number' => '1.7.3', 'platform' => 'x64-mingw-ucrt', 'sha' => Digest::SHA256.hexdigest('gem bytes') }]) : 'gem bytes'
      end
      client = described_class.new(http_get: http_get)

      client.download_gem('sqlite3', '1.7.3', platform: 'x64-mingw-ucrt')

      expect(requested_uri.to_s).to eq('https://rubygems.org/downloads/sqlite3-1.7.3-x64-mingw-ucrt.gem')
    end

    it 'writes the response body to a file and returns its path' do
      http_get = ->(uri) { uri.path.start_with?('/api/') ? JSON.generate([{ 'number' => '1.7.3', 'platform' => 'ruby', 'sha' => Digest::SHA256.hexdigest('gem bytes') }]) : 'gem bytes' }
      client = described_class.new(http_get: http_get)

      path = client.download_gem('sqlite3', '1.7.3')

      expect(File.read(path)).to eq('gem bytes')
      expect(File.basename(path)).to eq('sqlite3-1.7.3.gem')
    end

    it 'raises ArgumentError for a nil gem name without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem(nil, '1.7.3') }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for a gem name containing a path traversal sequence' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('../../etc/passwd', '1.7.3') }
        .to raise_error(ArgumentError, /disallowed characters/)
    end

    it 'raises ArgumentError for a platform containing a path separator' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('sqlite3', '1.7.3', platform: '../../etc') }
        .to raise_error(ArgumentError, /disallowed characters/)
    end

    it 'raises ArgumentError for a nil version without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('sqlite3', nil) }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for an empty version without making a request' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('sqlite3', '') }.to raise_error(ArgumentError, /must not be nil or empty/)
    end

    it 'raises ArgumentError for a version that is not RubyGems-correct' do
      client = described_class.new(http_get: unused_http_get)

      expect { client.download_gem('sqlite3', 'not-a-version!!') }
        .to raise_error(ArgumentError, /not a valid RubyGems version/)
    end
  end
end
