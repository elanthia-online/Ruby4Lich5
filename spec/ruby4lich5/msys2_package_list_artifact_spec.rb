# frozen_string_literal: true

require 'ruby4lich5/msys2_package_list_artifact'

RSpec.describe Ruby4Lich5::Msys2PackageListArtifact do
  # The UTF-8 byte-order mark's three raw bytes, built via Array#pack, not
  # a String escape -- real gap, found live: an earlier +"\xEF\xBB\xBF"+
  # hex-escape was silently destroyed by this project's own
  # ASCII-only-source RuboCop autocorrect (both occurrences here ended up
  # empty strings, making the tests that used them pass for the wrong
  # reason -- "rejects a byte-order mark" had no BOM left to reject, and
  # "emits...with no byte-order mark" checked against an empty prefix,
  # trivially always true). Numeric integer literals sidestep the failure
  # mode entirely.
  def bom
    [0xEF, 0xBB, 0xBF].pack('C*').b
  end
  describe '#initialize / #to_h' do
    it 'accepts a valid, non-empty, deduplicated package list' do
      artifact = described_class.new(%w[base-devel mingw-w64-ucrt-x86_64-gcc])

      expect(artifact.to_h).to eq({ 'schema' => 1, 'packages' => %w[base-devel mingw-w64-ucrt-x86_64-gcc] })
    end

    it 'rejects an empty package list' do
      expect { described_class.new([]) }
        .to raise_error(described_class::ValidationError, /packages must be a non-empty Array/)
    end

    it 'rejects a duplicate package entry' do
      expect { described_class.new(%w[base-devel base-devel]) }
        .to raise_error(described_class::ValidationError, /duplicate entries: \["base-devel"\]/)
    end

    it 'rejects an unsafe package identifier' do
      expect { described_class.new(['../etc/passwd']) }
        .to raise_error(described_class::ValidationError, /disallowed characters/)
    end

    it 'freezes the packages array and its own Strings' do
      artifact = described_class.new(%w[base-devel])

      expect(artifact.packages).to be_frozen
      expect(artifact.packages.first).to be_frozen
    end

    it "does not reflect a later mutation of the caller's own original Array" do
      packages = %w[base-devel]
      artifact = described_class.new(packages)

      packages << 'injected-package'

      expect(artifact.packages).to eq(%w[base-devel])
    end
  end

  describe '#to_json_bytes / .parse_strict round trip' do
    it 'round-trips a real package list through serialization and parsing' do
      artifact = described_class.new(%w[base-devel make mingw-w64-ucrt-x86_64-gcc])

      reparsed = described_class.parse_strict(artifact.to_json_bytes)

      expect(reparsed.packages).to eq(artifact.packages)
    end

    it 'emits UTF-8 bytes with no byte-order mark' do
      artifact = described_class.new(%w[base-devel])
      bytes = artifact.to_json_bytes

      expect(bytes.b).not_to start_with(bom)
    end
  end

  describe '.parse_strict' do
    def valid_body(packages: %w[base-devel])
      { 'schema' => 1, 'packages' => packages }.to_json
    end

    it 'parses a well-formed artifact' do
      result = described_class.parse_strict(valid_body)

      expect(result.packages).to eq(%w[base-devel])
    end

    it 'rejects a byte-order mark' do
      bytes = bom + valid_body.b

      expect { described_class.parse_strict(bytes) }
        .to raise_error(described_class::ValidationError, /byte-order mark/)
    end

    it 'rejects bytes that are not valid UTF-8' do
      # [0xFF, 0xFE] via Array#pack, not a String escape, same reason as
      # the bom helper above -- these two bytes have no valid Unicode
      # codepoint encoding at all (that is the point of the test), so
      # there is no ASCII-safe String escape equivalent available here.
      invalid = [0xFF, 0xFE].pack('C*') + valid_body.b

      expect { described_class.parse_strict(invalid) }
        .to raise_error(described_class::ValidationError, /not valid UTF-8/)
    end

    it 'rejects malformed JSON' do
      expect { described_class.parse_strict('{not valid json') }
        .to raise_error(described_class::ValidationError, /not valid JSON/)
    end

    it 'rejects a top-level value that is not a JSON object' do
      expect { described_class.parse_strict('[]') }
        .to raise_error(described_class::ValidationError, /must be a JSON object, got Array/)
    end

    it 'rejects an unknown top-level field' do
      body = { 'schema' => 1, 'packages' => %w[base-devel], 'extra' => 'nope' }.to_json

      expect { described_class.parse_strict(body) }
        .to raise_error(described_class::ValidationError, /unknown top-level field\(s\): \["extra"\]/)
    end

    it 'rejects an unrecognized schema version' do
      body = { 'schema' => 99, 'packages' => %w[base-devel] }.to_json

      expect { described_class.parse_strict(body) }
        .to raise_error(described_class::ValidationError, /unrecognized artifact schema version: 99/)
    end

    it "rejects a 'packages' field that is not an Array" do
      body = { 'schema' => 1, 'packages' => 'base-devel' }.to_json

      expect { described_class.parse_strict(body) }
        .to raise_error(described_class::ValidationError, /'packages' must be an Array, got String/)
    end

    it 'rejects duplicate entries even when parsed from real JSON bytes' do
      body = { 'schema' => 1, 'packages' => %w[base-devel base-devel] }.to_json

      expect { described_class.parse_strict(body) }
        .to raise_error(described_class::ValidationError, /duplicate entries/)
    end
  end

  # Shared dual-reader fixture corpus, per the locked
  # single-authority correction -- this artifact is the one genuine
  # dual-language boundary in the whole registry/package-list design, so
  # its fixtures are exercised here (parse_strict, the Ruby CLI's own
  # self-check boundary) and again, byte-for-byte identical, by
  # spec/powershell/read-msys2-package-list.Tests.ps1 -- one canonical
  # contract, never two independently-trusted implementations.
  describe 'shared fixture corpus (spec/fixtures/msys2-package-list/)' do
    def fixture_path(*segments)
      File.join(__dir__, '..', 'fixtures', 'msys2-package-list', *segments)
    end

    def read_fixture(*segments)
      File.binread(fixture_path(*segments))
    end

    describe 'valid fixtures' do
      it 'accepts a multi-package artifact' do
        result = described_class.parse_strict(read_fixture('valid', 'multi_package.json'))

        expect(result.packages).to eq(%w[base-devel make mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gtk3])
      end

      # The regression case that motivated this fixture existing at all:
      # PowerShell's ConvertFrom-Json returns a real System.Object[] (not
      # a bare scalar) even for a single-element JSON array, confirmed
      # live against a real pwsh process -- but an earlier draft of the
      # PowerShell reader used a check that would have accepted a bare
      # JSON *string* the same way it accepted this legitimate one-element
      # array. Both sides must agree a one-element array is valid.
      it 'accepts a single-package artifact' do
        result = described_class.parse_strict(read_fixture('valid', 'single_package.json'))

        expect(result.packages).to eq(%w[base-devel])
      end
    end

    describe 'invalid fixtures' do
      {
        'unknown_top_level_field.json' => /unknown top-level field/,
        'wrong_schema_version.json'    => /unrecognized artifact schema version/,
        'packages_not_array.json'      => /'packages' must be an Array/,
        'empty_packages.json'          => /must be a non-empty Array/,
        'duplicate_entries.json'       => /duplicate entries/,
        'unsafe_identifier.json'       => /disallowed characters/,
        'top_level_not_object.json'    => /must be a JSON object/,
        'malformed_json.json'          => /not valid JSON/,
        'byte_order_mark.json'         => /byte-order mark/,
        'invalid_utf8.json'            => /not valid UTF-8/,
        'mixed_case_identifier.json'   => /must be lowercase/,
        'uppercase_identifier.json'    => /must be lowercase/
      }.each do |filename, message_pattern|
        it "rejects #{filename}" do
          expect { described_class.parse_strict(read_fixture('invalid', filename)) }
            .to raise_error(described_class::ValidationError, message_pattern)
        end
      end
    end
  end
end
