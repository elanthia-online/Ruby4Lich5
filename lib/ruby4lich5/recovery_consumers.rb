# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'reviewed_archive_reader'

module Ruby4Lich5
  # Each consumer runs in a separate clean process to keep its namespace intact.
  class RecoveryConsumers
    ROOT = File.expand_path('../..', __dir__)
    CONFIG = File.join(ROOT, 'config/recovery-consumers.json')

    def self.entry(key, context: nil)
      if key == 'ranged'
        raise 'ranged consumer context is required' unless context
        entry = context.fetch('ranged_consumer')
        path = File.expand_path('preparation/range-consumer/lib/dependency_recovery.rb', ROOT)
        policy = File.join(File.dirname(path), 'recovery_unit_policy.rb')
        raise 'ranged consumer policy digest mismatch' unless Digest::SHA256.file(policy).hexdigest == entry.fetch('policy_sha256')
        raise 'ranged consumer source digest mismatch' unless Digest::SHA256.file(path).hexdigest == entry.fetch('sha256')
        # Recovery extracts with the sealed archive reader, which the digests
        # above do not cover.
        raise 'ranged consumer archive reader differs from reviewed source' unless ReviewedArchiveReader.matches?(File.expand_path('..', File.dirname(path)))
        return entry.merge('absolute_path' => path)
      end
      entry = JSON.parse(File.read(CONFIG)).fetch(key)
      path = File.join(ROOT, entry.fetch('path'))
      raise 'pinned consumer digest mismatch' unless Digest::SHA256.file(path).hexdigest == entry.fetch('sha256')

      entry.merge('absolute_path' => path)
    end
  end
end
