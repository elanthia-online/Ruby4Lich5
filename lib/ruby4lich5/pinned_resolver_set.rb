# frozen_string_literal: true

require 'rubygems/remote_fetcher'
require 'rubygems/resolver'

module Ruby4Lich5
  # Filter every resolver request, including transitives. Supplied gems come
  # from the measured target inventory instead of a second remote resolution.
  class PinnedResolverSet < Gem::Resolver::Set
    def initialize(pins:, supplied:, platforms: {}, upstream: Gem::Resolver::BestSet.new)
      super()
      @pins = pins
      @platforms = platforms
      @supplied = supplied
      @upstream = upstream
    end

    def find_all(request)
      if (entry = @supplied[request.name])
        spec = Gem::Specification.new do |item|
          item.name = request.name
          item.version = entry.fetch('version')
          entry.fetch('dependencies').each { |name, requirements| item.add_runtime_dependency(name, *requirements) }
        end
        return request.match?(spec) ? [Gem::Resolver::InstalledSpecification.new(self, spec)] : []
      end
      @upstream.find_all(request).select do |spec|
        (!@pins.key?(spec.name) || spec.version == Gem::Version.new(@pins.fetch(spec.name))) &&
          (!@platforms.key?(spec.name) || spec.platform.to_s == @platforms.fetch(spec.name))
      end
    end

    def prefetch(requests)
      @upstream.prefetch(requests.reject { |request| @supplied.key?(request.name) })
    end
  end
end
