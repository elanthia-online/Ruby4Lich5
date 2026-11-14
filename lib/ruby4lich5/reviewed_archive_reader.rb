# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'

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
    # The git pathspecs that cover the same files.
    PATHSPECS = %w[lib/zip_archive.rb lib/archive.rb lib/archive].freeze

    module_function

    # The one rule for which files belong to the reader, used for both a
    # source tree ({files_in}) and a commit ({files_at}), so the two listings
    # agree. Hidden and nested files count; whether the factory would seal
    # them is {PATH}'s question, not this one's.
    #
    # @param path [String] '/'-separated, relative to the lich-5 root
    def reader_path?(path)
      ['lib/zip_archive.rb', 'lib/archive.rb'].include?(path) || path.start_with?('lib/archive/')
    end

    # @return [Hash{String => String}] reviewed path => SHA-256
    # @raise [ArgumentError] when the pin is malformed, holds both
    #   lib/zip_archive.rb and lib/archive.rb, or a vendored copy differs from it
    def pinned(source: SOURCE, vendored: VENDORED)
      files = JSON.parse(File.binread(source))['reader_files']
      unless files.is_a?(Hash) && files.all? { |path, digest| path.is_a?(String) && path.match?(PATH) && digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) }
        raise ArgumentError, 'invalid reviewed archive reader pin'
      end
      # lich-5 replaced lib/zip_archive.rb with lib/archive.rb; a pin holding
      # both came from a tree where a merge brought the old reader back.
      raise ArgumentError, 'reviewed archive reader pin holds both the old and the new reader' if files.key?('lib/zip_archive.rb') && files.key?('lib/archive.rb')
      raise ArgumentError, 'reviewed archive reader copies differ from their pin' unless files_in(vendored) == files

      files
    end

    # @param directory [String] a lich-5 source tree (or the vendored copies)
    # @return [Hash{String => String}] every archive reader file below
    #   +directory+, whether or not its name is one the factory accepts
    def files_in(directory)
      GLOBS.flat_map { |glob| Dir.glob(glob, File::FNM_DOTMATCH, base: directory) }.uniq
           .select { |path| reader_path?(path) && File.file?(File.join(directory, path)) }.sort
           .to_h { |path| [path, Digest::SHA256.file(File.join(directory, path)).hexdigest] }
    end

    # The reader files at +commit+, hashed from raw git blobs (never
    # autocrlf-converted checkout bytes). Used for a released lich-5 whose
    # commit differs from the candidate's.
    #
    # @param checkout [String] a lich-5 git checkout holding +commit+
    # @param commit [String]
    # @return [Hash{String => String}] path => SHA-256, as {files_in}
    # @raise [ArgumentError] when git fails, or a reader entry is not a
    #   regular file (a symlink or submodule)
    def files_at(checkout, commit)
      listing, error, status = Open3.capture3('git', '-C', checkout, 'ls-tree', '-r', '-z', '--full-tree', commit, '--', *PATHSPECS, binmode: true)
      raise ArgumentError, "cannot list the archive reader at #{commit}: #{error.strip}" unless status.success?

      listing.split("\0").filter_map do |line|
        meta, path = line.split("\t", 2)
        next unless reader_path?(path)

        mode, type, blob = meta.split(' ')
        raise ArgumentError, "archive reader entry #{path} is not a regular file" unless type == 'blob' && %w[100644 100755].include?(mode)

        bytes, error, status = Open3.capture3('git', '-C', checkout, 'cat-file', 'blob', blob, binmode: true)
        raise ArgumentError, "cannot read #{path} at #{commit}: #{error.strip}" unless status.success?

        [path, Digest::SHA256.hexdigest(bytes)]
      end.sort.to_h
    end

    # @param directory [String] a sealed candidate source tree
    # @return [Boolean] whether its archive reader is exactly the reviewed one
    def matches?(directory, **options)
      files_in(directory) == pinned(**options)
    end
  end
end
