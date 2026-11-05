# frozen_string_literal: true

module Ruby4Lich5
  # Resolves a gem's full runtime dependency closure and returns it in
  # topological order (dependencies before dependents), reusing
  # RubyGems' own resolver rather
  # than hand-rolling a constraint solver.
  class ClosureResolver
    # Raised when the requested gem+version can't be resolved at all (e.g. a
    # typo'd name, or a version that was never published).
    class ResolutionError < StandardError; end

    # Raised when a resolved node declares a runtime dependency that isn't
    # itself present anywhere in the resolved set -- an incomplete closure,
    # not something to build a plan from.
    class IncompleteClosureError < StandardError; end

    # @return [Integer] seconds
    DEFAULT_TIMEOUT_SECONDS = 300
    private_constant :DEFAULT_TIMEOUT_SECONDS

    # @param resolve [#call] +->(gem_name, version) { [{name:, version:,
    #   runtime_dependencies: [{name:, requirement:}]}, ...] }+ -- the full
    #   resolved set, in any order; this class does its own topological sort
    #   rather than trusting the resolver's incidental output order. Each
    #   dependency's +requirement+ is a real +Gem::Requirement+, not a
    #   String. Defaults to a real +Gem::Resolver+ call against
    #   rubygems.org; specs should inject a stub so they never hit real
    #   network.
    # @param timeout_seconds [Numeric] wall-clock bound for the default
    #   resolve, in case rubygems.org is slow or unreachable. Unused when
    #   +resolve+ is overridden -- a caller-supplied callable is responsible
    #   for its own timeout behavior.
    def initialize(resolve: method(:default_resolve), timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
      @resolve = resolve
      @timeout_seconds = timeout_seconds
    end

    # @param gem_name [String]
    # @param version [String] exact version to resolve, e.g. +"3.5.6"+
    # @return [Array<Hash>] +{name:, version:, runtime_dependencies:
    #   [{name:, requirement:}], runtime_dependency_names:}+ entries,
    #   topologically sorted -- every dependency appears before anything
    #   that depends on it, and the requested gem itself appears last.
    #   +runtime_dependency_names+ is derived from +runtime_dependencies+,
    #   never a second independent source of truth.
    # @raise [ResolutionError] if the gem+version can't be resolved
    # @raise [IncompleteClosureError] if a resolved node's declared runtime
    #   dependency isn't itself present in the resolved set
    def resolve_closure(gem_name, version)
      nodes = @resolve.call(gem_name, version)
      topological_sort(nodes)
    end

    private

    # Post-order depth-first traversal: a node is only appended after every
    # one of its runtime dependencies has already been appended. Circular
    # runtime dependencies aren't a practical concern in the Ruby ecosystem
    # -- the +visited+ guard prevents an
    # infinite loop if one ever existed, but no dedicated cycle-handling is
    # built for a case that doesn't really occur.
    #
    # A dependency name absent from the resolved set entirely is different
    # from a cycle, and not treated as benign: the whole point of resolving
    # against Gem::Resolver is a *complete* closure, so a node referencing a
    # dependency that isn't itself in the set means the resolution was
    # incomplete -- silently dropping it would hand back a build plan
    # missing something it needs, surfacing later as a confusing failure far
    # from its actual cause instead of here, where the gap is actually known.
    #
    # @return [Array<Hash>] +{name:, version:, runtime_dependencies:,
    #   runtime_dependency_names:}+ entries in dependency order --
    #   +runtime_dependency_names+ (bare Strings, derived from
    #   +runtime_dependencies+, never a second independent source of truth)
    #   is kept for existing callers (e.g. a vendoring-role classifier that
    #   only needs to know which native gem depends on which other one);
    #   +runtime_dependencies+ (+{name:, requirement:}+ pairs, a real
    #   +Gem::Requirement+ per edge) is for callers that need the actual
    #   version constraint too, e.g. Phase 17's resolution lock -- real gap,
    #   found in review: an earlier version discarded
    #   +Gem::Dependency#requirement+ entirely, keeping only names.
    # @raise [IncompleteClosureError]
    def topological_sort(nodes)
      by_name = nodes.each_with_object({}) { |node, index| index[node.fetch(:name)] = node }
      visited = {}
      ordered = []

      visit = lambda do |name, required_by|
        next if visited[name]

        visited[name] = true
        node = by_name[name]
        if node.nil?
          raise IncompleteClosureError,
                "#{required_by} depends on #{name}, which is not present in the resolved set"
        end

        runtime_dependencies = node.fetch(:runtime_dependencies)
        runtime_dependencies.each { |dep| visit.call(dep.fetch(:name), name) }
        ordered << { name: node.fetch(:name), version: node.fetch(:version),
                     runtime_dependencies: runtime_dependencies,
                     runtime_dependency_names: runtime_dependencies.map { |dep| dep.fetch(:name) } }
      end

      nodes.each { |node| visit.call(node.fetch(:name), nil) }
      ordered
    end

    # @return [Array<Hash>] +{name:, version:, runtime_dependencies:
    #   [{name:, requirement:}]}+ entries for the full resolved set, in
    #   whatever order Gem::Resolver happened to produce them
    # @raise [ResolutionError]
    def default_resolve(gem_name, version)
      require 'rubygems/remote_fetcher' # not autoloaded; Gem::Resolver::BestSet needs it
      require 'rubygems/resolver'
      require 'timeout'

      dependency = Gem::Dependency.new(gem_name, "= #{version}")
      resolver = Gem::Resolver.new([dependency], Gem::Resolver::BestSet.new)

      activation_requests = Timeout.timeout(@timeout_seconds) { resolver.resolve }

      activation_requests.map do |activation_request|
        spec = activation_request.spec
        {
          name: spec.name,
          version: spec.version.to_s,
          runtime_dependencies: spec.dependencies.select { |dep| dep.type == :runtime }
                                    .map { |dep| { name: dep.name, requirement: dep.requirement } }
        }
      end
    rescue Gem::Exception => e
      # Gem::UnsatisfiableDependencyError et al. all descend from
      # Gem::Exception (verified directly -- there is no Gem::Resolver::Error
      # in the actual hierarchy), RubyGems' own common base for this class of
      # failure -- a typo'd name or a version that was never published.
      raise ResolutionError, "could not resolve #{gem_name} #{version}: #{e.message}"
    rescue Timeout::Error
      # Also catches Net::OpenTimeout / Net::ReadTimeout (verified: both are
      # Timeout::Error subclasses), so a slow single request and an
      # unboundedly-long overall resolve are both covered by one rescue.
      raise ResolutionError, "could not resolve #{gem_name} #{version}: timed out after #{@timeout_seconds}s"
    rescue StandardError => e
      # Network failures below Gem::Exception (SocketError, Errno::*,
      # OpenSSL::SSL::SSLError) would otherwise leak past this method
      # unwrapped, losing the gem_name/version context that makes the
      # failure actionable.
      raise ResolutionError, "could not resolve #{gem_name} #{version}: #{e.class}: #{e.message}"
    end
  end
end
