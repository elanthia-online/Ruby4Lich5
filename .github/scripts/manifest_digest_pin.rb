# frozen_string_literal: true

require 'digest'

# Binds Lich's recovery manifest read to one expected SHA-256, the way
# bin/recovery_smoke.rb binds its http_get seam to candidate_sha256. Used by
# .github/scripts/lich_startup_probe.rb when R4L5_EXPECTED_MANIFEST_SHA256 is
# set: a candidate release is not immutable, so the bytes a release check
# verified up front are not necessarily the bytes Lich's startup (and its
# relaunch, which inherits the environment) reads from the URL later.
#
# Lich::DependencyRecovery#load_manifest reads the manifest through its private
# fetch(@manifest_url). The pin wraps that method; any other URL passes through.
module ManifestDigestPin
  ENV_NAME = 'R4L5_EXPECTED_MANIFEST_SHA256'
  DIGEST = /\Asha256:[0-9a-f]{64}\z/

  # @param klass [Class] the recovery class whose private fetch(url) reads the manifest
  # @param expected [String] sha256:<64 hex>
  # @param on_verified [#call, nil] called with the digest after each matching read
  # @return [void]
  def self.install!(klass, expected, on_verified: nil)
    raise ArgumentError, "#{ENV_NAME} must be sha256: followed by 64 lowercase hex digits" unless expected.is_a?(String) && expected.match?(DIGEST)
    raise ArgumentError, "#{klass} has no private fetch(url); cannot bind the manifest digest" unless klass.private_method_defined?(:fetch)

    pin = Module.new do
      define_method(:fetch) do |url|
        bytes = super(url)
        if url == instance_variable_get(:@manifest_url)
          actual = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
          raise "manifest #{url} is #{actual}, not the expected #{expected}" unless actual == expected
          on_verified&.call(actual)
        end
        bytes
      end
      private :fetch
    end
    klass.prepend(pin)
  end
end
