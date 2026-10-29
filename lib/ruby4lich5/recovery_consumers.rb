# frozen_string_literal: true

require 'json'
require 'digest'

module Ruby4Lich5
  # Each consumer runs in a separate clean process to keep its namespace intact.
  class RecoveryConsumers
    ROOT = File.expand_path('../..', __dir__)
    CONFIG = File.join(ROOT, 'config/recovery-consumers.json')

    def self.entry(key)
      entry = JSON.parse(File.read(CONFIG)).fetch(key)
      path = File.join(ROOT, entry.fetch('path'))
      raise 'pinned consumer digest mismatch' unless Digest::SHA256.file(path).hexdigest == entry.fetch('sha256')

      entry.merge('absolute_path' => path)
    end
  end
end
