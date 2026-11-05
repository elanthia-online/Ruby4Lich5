# frozen_string_literal: true

require 'json'
require_relative 'safe_token'

module Ruby4Lich5
  # The small, well-defined JSON hand-off artifact F1's Ruby CLI emits and
  # the PowerShell reader consumes:
  # schema version plus a deduplicated, deterministically-ordered array of
  # MSYS2 package-name strings (the static bootstrap set already unioned
  # in by the CLI, never appended by the reader). Self-validated on both
  # ends -- unknown top-level fields and duplicate entries are hard
  # rejects here, defense in depth matching {CuratedGemRegistry}'s own
  # discipline, even though this shape is simple enough that "duplicate
  # JSON object key" doesn't apply the way it did there.
  #
  # Encoding is a real, checked contract, not an assumption: written and
  # read as UTF-8 with no byte-order mark. PowerShell's own
  # `Set-Content -Encoding utf8` on Windows PowerShell 5.1 emits a BOM by
  # contrast -- a real, confirmed divergence from Ruby's own
  # `File.write` default -- so a BOM is treated as a hard "wrong
  # encoding" rejection on both sides, not silently stripped.
  class Msys2PackageListArtifact
    # Raised for any structural or semantic violation of this artifact's
    # schema, or a byte-level encoding problem -- malformed input is
    # rejected outright, never partially trusted.
    class ValidationError < StandardError; end

    # @return [Integer]
    SCHEMA_VERSION = 1
    private_constant :SCHEMA_VERSION

    # @return [Array<String>]
    TOP_LEVEL_KEYS = %w[schema packages].freeze
    private_constant :TOP_LEVEL_KEYS

    # @return [String] the UTF-8 byte-order mark (U+FEFF), as the three
    #   raw bytes it actually encodes to (239, 187, 191). Built via
    #   Array#pack, not a String escape -- real gap, found live: this
    #   project's own ASCII-only-source RuboCop autocorrect silently
    #   destroyed an earlier +"\xEF\xBB\xBF"+ hex-escape version (replaced
    #   it with an empty string, which would have made every artifact
    #   falsely "carry a BOM," always rejected), and a later fix attempt
    #   using a +\u+ escape was itself written into this file as the raw
    #   multi-byte character by the editing tool rather than the intended
    #   ASCII escape text -- confirmed by inspecting the file's actual
    #   bytes. Numeric integer literals sidestep both failure modes
    #   entirely: nothing here is a string escape a tool or a linter can
    #   silently reinterpret.
    BOM = [0xEF, 0xBB, 0xBF].pack('C*').freeze
    private_constant :BOM

    # @return [Array<String>] deduplicated package names, in the exact
    #   order given -- deterministic ordering is this class's caller's
    #   responsibility (sort before constructing), not re-derived here
    attr_reader :packages

    # @param packages [Array<String>]
    # @raise [ValidationError] if +packages+ is empty, contains a
    #   duplicate, or contains any name {SafeToken} rejects
    def initialize(packages)
      @packages = packages
      validate!
      @packages = @packages.map { |name| name.dup.freeze }.freeze
    end

    # @return [Hash] JSON-serializable, matching this project's existing
    #   small-JSON-hand-off convention (e.g. {ResolutionLock#to_h})
    def to_h
      { 'schema' => SCHEMA_VERSION, 'packages' => @packages }
    end

    # @return [String] UTF-8 bytes, no BOM -- Ruby's own +File.write+
    #   default already produces this; made explicit here rather than
    #   assumed, since this exact artifact's encoding is a checked
    #   contract on both the Ruby and PowerShell sides
    def to_json_bytes
      "#{JSON.pretty_generate(to_h)}\n".b
    end

    # @param bytes [String] raw bytes as read from disk (e.g.
    #   +File.binread+) -- never pre-decoded, so this method is the one
    #   place the encoding contract actually gets checked
    # @return [Msys2PackageListArtifact]
    # @raise [ValidationError] if +bytes+ isn't valid UTF-8, carries a
    #   byte-order mark, isn't valid JSON, or fails schema validation
    def self.parse_strict(bytes)
      raise ValidationError, 'artifact carries a byte-order mark, expected plain UTF-8' if bytes.b.start_with?(BOM)

      text = bytes.dup.force_encoding('UTF-8')
      raise ValidationError, 'artifact is not valid UTF-8' unless text.valid_encoding?

      data = JSON.parse(text)
      raise ValidationError, "artifact must be a JSON object, got #{data.class}" unless data.is_a?(Hash)

      unknown_keys = data.keys - TOP_LEVEL_KEYS
      raise ValidationError, "artifact has unknown top-level field(s): #{unknown_keys.inspect}" unless unknown_keys.empty?

      schema = data['schema']
      raise ValidationError, "unrecognized artifact schema version: #{schema.inspect}" unless schema == SCHEMA_VERSION

      packages = data['packages']
      raise ValidationError, "artifact 'packages' must be an Array, got #{packages.class}" unless packages.is_a?(Array)

      new(packages)
    rescue JSON::ParserError => e
      raise ValidationError, "artifact is not valid JSON: #{e.message}"
    end

    private

    # @raise [ValidationError]
    def validate!
      unless @packages.is_a?(Array) && !@packages.empty?
        raise ValidationError, "packages must be a non-empty Array, got #{@packages.inspect}"
      end

      duplicates = @packages.tally.select { |_name, count| count > 1 }.keys
      raise ValidationError, "packages has duplicate entries: #{duplicates.inspect}" unless duplicates.empty?

      @packages.each do |name|
        safe_token!(name)
        lowercase!(name)
      end
    end

    # @raise [ValidationError]
    def safe_token!(name)
      SafeToken.validate!(name, 'package name')
    rescue ArgumentError => e
      # {SafeToken.validate!} raises ArgumentError -- this class's whole
      # contract is "every rejection is a ValidationError," same wrapper
      # pattern {CuratedGemRegistry#safe_token!} already established.
      raise ValidationError, e.message
    end

    # Real dual-reader contract gap, found in review: SafeToken's own
    # charset permits both cases, and Ruby's Array#tally ({#validate!}'s
    # own duplicate check, above) compares by exact String equality, so
    # +["foo", "FOO"]+ passes both checks as two distinct, valid entries --
    # but read-msys2-package-list.ps1's PowerShell reader uses
    # Group-Object's *default* comparer, which is case-insensitive, and
    # would reject that identical input as a duplicate. Reproduced live on
    # both sides before this fix. Real MSYS2 package names are
    # lowercase-only by upstream convention (every existing package this
    # project references already is), so enforcing that here closes the
    # gap by rejecting the ambiguous input outright on both sides, rather
    # than picking one comparer's semantics as authoritative over the
    # other's.
    #
    # @raise [ValidationError]
    def lowercase!(name)
      return if name == name.downcase

      raise ValidationError, "package name must be lowercase: #{name.inspect}"
    end
  end
end
