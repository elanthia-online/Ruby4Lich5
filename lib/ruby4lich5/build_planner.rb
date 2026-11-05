# frozen_string_literal: true

require_relative 'classifier'
require_relative 'closure_resolver'
require_relative 'curation_manifest'

module Ruby4Lich5
  # Produces the ordered build plan for a gem request: resolve the full
  # dependency closure,
  # skip anything the curation manifest already satisfies, and classify
  # whatever's left.
  #
  # Deliberately stops there. The actual "go build/patch/compile it" step
  # isn't a Ruby-callable abstraction yet -- that's still CI-workflow
  # territory (MSYS2 itself, the front door's publish mechanism) -- so this
  # produces the plan a future build step would consume, not the build
  # itself. +runtime_dependency_names+ is carried through in each entry so a
  # caller can derive build-order concerns (e.g. which native gem is a
  # "vendoring root" others piggyback on) without re-resolving.
  class BuildPlanner
    # Raised when any gem in the closure classifies as
    # +:native_needs_system_lib+ -- no partial-success state; a closure with
    # one unbuildable member fails the whole request loudly rather than
    # silently shipping an incomplete plan.
    class UnbuildableGemError < StandardError; end

    # @param closure_resolver [ClosureResolver]
    # @param classifier [Classifier]
    # @param manifest [CurationManifest]
    def initialize(closure_resolver: ClosureResolver.new, classifier: Classifier.new, manifest: CurationManifest.new)
      @closure_resolver = closure_resolver
      @classifier = classifier
      @manifest = manifest
    end

    # @param gem_name [String]
    # @param version [String] exact version to plan for, e.g. +"3.5.6"+
    # @param platform [String] target RubyGems platform tag
    # @param ruby_abi [String] target Ruby ABI series, e.g. +"4.0"+
    # @return [Array<Hash>] one +{name:, version:, classification:,
    #   runtime_dependencies:, runtime_dependency_names:}+ entry per gem
    #   that still needs action, in dependency order (leaves first).
    #   +runtime_dependencies+ ({name:, requirement:} pairs, a real
    #   +Gem::Requirement+ per PR C) carried through alongside the
    #   existing name-only field -- purely additive, PR F1: a caller
    #   assembling a {ResolutionLock} needs the richer shape;
    #   {VendoringRoleClassifier}/{glib2_reachability}/{gem_unit_grouper}
    #   keep working unchanged against +runtime_dependency_names+. Entries
    #   the curation manifest already satisfies are omitted entirely --
    #   there's nothing to plan for them.
    # @raise [ClosureResolver::ResolutionError] if the requested gem+version
    #   can't be resolved at all
    # @raise [UnbuildableGemError] if any gem in the closure classifies as
    #   +:native_needs_system_lib+
    def plan_for(gem_name, version, platform:, ruby_abi:)
      closure = @closure_resolver.resolve_closure(gem_name, version)

      closure.filter_map do |node|
        next if @manifest.satisfied?(node.fetch(:name), node.fetch(:version), platform)

        classification = @classifier.classify(
          name: node.fetch(:name), version: node.fetch(:version), platform: platform, ruby_abi: ruby_abi
        )
        if classification.needs_system_lib?
          raise UnbuildableGemError, "#{node.fetch(:name)} #{node.fetch(:version)}: #{classification.reason}"
        end

        {
          name: node.fetch(:name), version: node.fetch(:version), classification: classification,
          runtime_dependencies: node.fetch(:runtime_dependencies), runtime_dependency_names: node.fetch(:runtime_dependency_names)
        }
      end
    end
  end
end
