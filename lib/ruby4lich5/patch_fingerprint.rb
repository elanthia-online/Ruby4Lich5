# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'safe_token'

module Ruby4Lich5
  # Identifies the curated patch set a package was built with, so accepted
  # package reuse can prove an accepted build used the same patches as the
  # current tree.
  #
  # A package's fingerprint covers every regular file under the checked-in
  # +patches/<name>/+ directory: SHA-256 over the sorted
  # "<relative path>\0<sha256 of bytes>\n" lines, with +/+ separators. A
  # package with no patch files has the fingerprint +nil+ ("no patches").
  #
  # Fingerprints describe the committed tree only. {NativeGemPreparer} may
  # generate patches into +patches/<name>/+ during the build, so a
  # fingerprint must be taken before "Prepare native gems" runs; the suite
  # takes it in "Prepare accepted package reuse".
  #
  # Accepted builds record their fingerprints as the +patch_fingerprints+
  # field of +gem-build-metadata.json+: a map of package name to fingerprint
  # string or +null+. A name absent from the map, or a bundle without the
  # field, means "not recorded" -- reuse then fails closed whenever the
  # current tree has patches for that package (see {.reusable?}).
  module PatchFingerprint
    DEFAULT_ROOT = File.expand_path('../../patches', __dir__)
    METADATA_FIELD = 'patch_fingerprints'
    FORMAT = /\Asha256:[0-9a-f]{64}\z/

    # @param name [String] package (gem) name
    # @param patches_root [String] directory holding one subdirectory per
    #   package
    # @return [String, nil] +"sha256:<hex>"+, or +nil+ when the package has
    #   no patch files (a missing or empty directory)
    # @raise [ArgumentError] if +name+ is unsafe or the directory holds a
    #   symlink (its target is outside what the fingerprint can vouch for)
    def self.compute(name, patches_root: DEFAULT_ROOT)
      SafeToken.validate!(name, 'package name')
      dir = File.join(patches_root, name)
      return nil unless File.directory?(dir)

      entries = Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).sort.filter_map do |relative|
        path = File.join(dir, relative)
        raise ArgumentError, "patch path is a symlink: #{name}/#{relative}" if File.symlink?(path)
        next unless File.file?(path)

        "#{relative.tr('\\', '/')}\0#{Digest::SHA256.file(path).hexdigest}\n"
      end
      return nil if entries.empty?

      "sha256:#{Digest::SHA256.hexdigest(entries.join)}"
    end

    # @param lock [ResolutionLock]
    # @param patches_root [String]
    # @return [Hash{String => String, nil}] the current tree's fingerprint for
    #   every non-Ruby-bundled closure member, keyed and sorted by name
    def self.current(lock, patches_root: DEFAULT_ROOT)
      names = lock.closure.reject { |entry| entry.fetch(:classification).ruby_bundled? }.map { |entry| entry.fetch(:name) }
      names.sort.to_h { |name| [name, compute(name, patches_root: patches_root)] }
    end

    # Reuse rule: an accepted package is reusable only when its build is
    # proven to have used the current curated patch set.
    #
    # @param accepted [Hash{String => String, nil}, nil] the accepted
    #   bundle's recorded fingerprints; +nil+ when it recorded none
    # @param name [String]
    # @param fingerprint [String, nil] the current tree's fingerprint
    # @return [Boolean] true when the accepted build recorded exactly this
    #   fingerprint, or recorded nothing for +name+ and the current tree has
    #   no patches for it
    def self.reusable?(accepted, name, fingerprint)
      return accepted[name] == fingerprint if accepted&.key?(name)

      fingerprint.nil?
    end

    # Reads an accepted bundle's recorded fingerprints.
    #
    # @param path [String] +gem-build-metadata.json+; Windows PowerShell 5.1
    #   writes it with a UTF-8 BOM
    # @return [Hash{String => String, nil}, nil] +nil+ when the bundle
    #   predates fingerprint recording
    # @raise [ArgumentError] if the recorded field is malformed
    def self.read_metadata(path)
      metadata = JSON.parse(File.read(path, encoding: 'bom|utf-8'))
      return nil unless metadata.key?(METADATA_FIELD)

      validate!(metadata.fetch(METADATA_FIELD))
    end

    # @param record [Object] a decoded +patch_fingerprints+ value
    # @return [Hash{String => String, nil}] +record+
    # @raise [ArgumentError] unless it maps safe package names to a
    #   +sha256:+ fingerprint or +nil+
    def self.validate!(record)
      raise ArgumentError, 'patch_fingerprints must be an object' unless record.is_a?(Hash)

      record.each do |name, value|
        SafeToken.validate!(name, 'patch fingerprint package')
        raise ArgumentError, "malformed patch fingerprint for #{name}" unless value.nil? || (value.is_a?(String) && FORMAT.match?(value))
      end
      record
    end
  end
end
