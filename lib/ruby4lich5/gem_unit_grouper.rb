# frozen_string_literal: true

module Ruby4Lich5
  # Groups a resolved gem closure into the recovery units lich-5's shared
  # recovery reader consumes.
  #
  # A "root" is one top-level-requested name (or, for the GTK3 stack, one
  # named group of them) that gets its own named recovery unit. Every other
  # closure member is folded into whichever root(s) can actually reach it --
  # a gem transitively required by exactly one root belongs to that root's
  # unit; a gem that is *also* independently a root of its own (e.g.
  # concurrent-ruby, tzinfo -- both separately listed in the runtime-gems
  # input *and* real dependencies of tzinfo-data) appears in both places.
  # The schema has no inter-unit reference mechanism, so this duplication is
  # the accepted, deliberate way to represent "needed standalone and also
  # needed as part of this other thing" -- not a bug to dedupe away.
  class GemUnitGrouper
    Root = Struct.new(:id, :start_names, keyword_init: true)

    # @param closure_nodes [Array<Hash>] +{name:, version:,
    #   runtime_dependency_names:}+ entries, as returned by
    #   {InstalledGemClosure#resolve} -- the full, already-resolved set
    # @param roots [Array<Root>] one entry per named recovery unit
    # @raise [ArgumentError] if any root's +start_names+ isn't present in
    #   +closure_nodes+, or if two roots share the same +id+
    def initialize(closure_nodes:, roots:)
      @by_name = closure_nodes.each_with_object({}) { |node, index| index[node.fetch(:name)] = node }
      @roots = roots
      validate_roots!
    end

    # @return [Array<Hash>] +{id:, members: [name, ...], install_order:
    #   [name, ...]}+ per root, in the same order +roots+ was given.
    #   +members+/+install_order+ are the same set, +install_order+
    #   topologically sorted (dependencies first); +members+ kept as a
    #   separate, unordered-intent field matching the locked schema, which
    #   documents the two fields independently even though this
    #   implementation always derives them from the same resolution.
    def units
      @roots.map do |root|
        # Each root's membership is its own independent reachable-set --
        # deliberately no cross-root exclusion. A name that happens to also
        # be another root's own start name still belongs here if this
        # root's graph genuinely reaches it (tzinfo standalone still needs
        # concurrent-ruby to actually install; excluding it would produce
        # an incomplete, uninstallable unit). Duplication across units is
        # the intended outcome, not a defect to filter out.
        member_names = reachable_from(root.start_names)
        ordered = topological_order(member_names)
        { id: root.id, members: ordered, install_order: ordered }
      end
    end

    private

    def validate_roots!
      ids = @roots.map(&:id)
      raise ArgumentError, "duplicate root id(s): #{ids.tally.select { |_, n| n > 1 }.keys.join(', ')}" if ids.uniq.length != ids.length

      missing = @roots.flat_map(&:start_names).reject { |name| @by_name.key?(name) }.uniq
      raise ArgumentError, "root start name(s) not present in the resolved closure: #{missing.join(', ')}" unless missing.empty?
    end

    # @param start_names [Array<String>]
    # @return [Array<String>] every name reachable from +start_names+ via
    #   runtime-dependency edges, +start_names+ themselves included
    def reachable_from(start_names)
      visited = Set.new
      stack = start_names.dup

      until stack.empty?
        name = stack.pop
        next if visited.include?(name) || !@by_name.key?(name)

        visited << name
        stack.concat(@by_name.fetch(name).fetch(:runtime_dependency_names))
      end

      visited.to_a
    end

    # @param member_names [Array<String>]
    # @return [Array<String>] +member_names+, ordered so every dependency
    #   (that is itself a member) precedes anything in the same unit that
    #   depends on it -- a member's dependency on something *outside* this
    #   unit (e.g. a default gem, or a gem belonging only to another unit)
    #   is not this method's concern, since install_order only orders what
    #   this one unit itself installs
    def topological_order(member_names)
      member_set = member_names.to_set
      visited = Set.new
      ordered = []

      visit = lambda do |name|
        next if visited.include?(name)

        visited << name
        @by_name.fetch(name).fetch(:runtime_dependency_names).each do |dep_name|
          visit.call(dep_name) if member_set.include?(dep_name)
        end
        ordered << name
      end

      member_names.each { |name| visit.call(name) }
      ordered
    end
  end
end
