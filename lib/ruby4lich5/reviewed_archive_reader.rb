# frozen_string_literal: true

require 'json'
require 'digest'

module Ruby4Lich5
  # lich-5's in-process archive reader: lib/zip_archive.rb, or lib/archive.rb
  # and lib/archive/*.rb. The reviewed dependency_recovery.rb hands every ZIP
  # entry and path check to it, so it is pinned like the reviewed startup
  # files: a copy of each file under vendor/lich5/archive-reader/ (mirroring
  # lich-5's lib/ layout, so no vendored file can require_relative it), and its
  # digest in ranged-source.json's reader_files, at the same source_commit.
  #
  # A candidate's sealed source must hold exactly those files with exactly
  # those bytes: a changed, missing or extra reader file fails closed, as a
  # change to dependency_recovery.rb does. A commit before the reader existed
  # pins an empty set, and its sealed source must have no reader files.
  module ReviewedArchiveReader
    ROOT = File.expand_path('../..', __dir__)
    SOURCE = File.join(ROOT, 'vendor/lich5/ranged-source.json')
    VENDORED = File.join(ROOT, 'vendor/lich5/archive-reader')
    # The same files bin/seal_contract_source.rb accepts.
    PATH = %r{\Alib/(zip_archive\.rb|archive\.rb|archive/[A-Za-z0-9_]+\.rb)\z}
    GLOBS = %w[lib/zip_archive.rb lib/archive.rb lib/archive/**/*].freeze

    module_function

    # @return [Hash{String => String}] reviewed path => SHA-256
    # @raise [ArgumentError] when the pin is malformed or a vendored copy
    #   differs from it
    def pinned(source: SOURCE, vendored: VENDORED)
      files = JSON.parse(File.binread(source))['reader_files']
      unless files.is_a?(Hash) && files.all? { |path, digest| path.is_a?(String) && path.match?(PATH) && digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) }
        raise ArgumentError, 'invalid reviewed archive reader pin'
      end
      raise ArgumentError, 'reviewed archive reader copies differ from their pin' unless files_in(vendored) == files

      files
    end

    # @param directory [String] a lich-5 source tree (or the vendored copies)
    # @return [Hash{String => String}] every archive reader file below
    #   +directory+, whether or not its name is one the factory accepts
    def files_in(directory)
      GLOBS.flat_map { |glob| Dir.glob(glob, File::FNM_DOTMATCH, base: directory) }.uniq
           .select { |path| File.file?(File.join(directory, path)) }.sort
           .to_h { |path| [path, Digest::SHA256.file(File.join(directory, path)).hexdigest] }
    end

    # @param directory [String] a sealed candidate source tree
    # @return [Boolean] whether its archive reader is exactly the reviewed one
    def matches?(directory, **options)
      files_in(directory) == pinned(**options)
    end
  end
end
