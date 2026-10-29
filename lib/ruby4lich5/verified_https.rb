# frozen_string_literal: true

require 'open-uri'
require 'uri'

module Ruby4Lich5
  # No credentials are supplied to artifact requests or redirect targets.
  module VerifiedHttps
    def self.read(url)
      uri = URI(url)
      raise ArgumentError, 'artifact URL must use HTTPS without credentials' unless uri.scheme == 'https' && uri.host && uri.userinfo.nil?

      uri.open(open_timeout: 10, read_timeout: 60) do |response|
        raise ArgumentError, 'artifact redirect left credential-free HTTPS' unless response.base_uri.scheme == 'https' && response.base_uri.userinfo.nil?

        response.read
      end
    end
  end
end
