# frozen_string_literal: true

require 'rubygems'
require_relative 'known_native_gems'
require_relative 'patch_applier'
require_relative '../../vendor/lich5/recovery_unit_policy'

module Ruby4Lich5
  # Producer rules for the two optional per-package manifest keys lich-5
  # reads (see docs/PACKAGE-POLICY.md):
  #
  # - +minimum+: the lowest installed version startup accepts without a
  #   repair. Configured per target in +config/curated-gems.json+
  #   (+targets.<platform>.<abi>.minimum+) and written only when it is lower
  #   than the served +version+.
  # - +self_build_equivalent+: +true+ on a package Ruby4Lich5 builds from
  #   unchanged upstream source, so a same-version self-built copy may stand
  #   in for the R4L5 build. Never written as +false+.
  #
  # {#apply!} decides both from the real dependency edges the resolution
  # lock carries; {.validate_target!} re-checks a finished manifest, which
  # carries no dependency edges, through structural stand-ins (see there).
  class PackagePolicy
    # A rejected policy is an invalid manifest, the same class every other
    # {GemManifestValidator} refusal raises.
    class Error < ArgumentError; end

    # Keys that describe startup policy, not served bytes.
    KEYS = %w[minimum self_build_equivalent].freeze

    # @param value [Object]
    # @return [Boolean] whether +value+ is a version in canonical RubyGems
    #   spelling. +Gem::Version.correct?+ alone accepts padding (a blank
    #   string is version 0) and forms it rewrites (+"2.10.1-1"+). Unlike
    #   {Lich::RecoveryUnitPolicy.canonical_release?} a prerelease passes:
    #   this is the rule for +version+, which may legitimately be one.
    def self.canonical_version?(value)
      value.is_a?(String) && !value.empty? && Gem::Version.correct?(value) && Gem::Version.new(value).to_s == value
    end

    # The registry half of the flag rule: built by Ruby4Lich5 on this target
    # (+native_self_contained+) through the +repack+ role, which compiles the
    # unchanged upstream source, and with no curated source patch. A +gtk+
    # role package is always normalized and patched, and a pass-through
    # package is upstream's binary, not an R4L5 build.
    #
    # @param name [String]
    # @param platform [String]
    # @param ruby_abi [String]
    # @param registry [CuratedGemRegistry]
    # @param patched [#call] +->(name) { Boolean }+
    # @return [Boolean]
    def self.self_build_candidate?(name, platform:, ruby_abi:, registry:, patched:)
      registry.build_role_for(name) == 'repack' && registry.classification_for(name, platform, ruby_abi) == 'native_self_contained' &&
        !patched.call(name)
    end

    # @return [#call] whether +patches/<name>/+ holds any curated patch
    def self.default_patched
      applier = PatchApplier.new
      ->(name) { applier.patches_exist_for?(name) }
    end

    # Re-checks a finished manifest target. The manifest carries no gem
    # dependencies, so the two flag directions use structural stand-ins that
    # hold for every unit {GemManifestGenerator} builds (a root's complete
    # closure, +install_order+ dependencies first):
    #
    # - "nothing in its units depends on it": it is the last entry of
    #   +install_order+ in every unit holding it. Anything depending on it
    #   would have to install after it.
    # - "it depends on no unit-mate whose R4L5 build bundles DLLs": every
    #   unit-mate is a +ruby+-platform package. A last-installed package's
    #   unit-mates are all its (transitive) dependencies, so this is the
    #   conservative form of the rule (sqlite3 over pure mini_portile2 passes).
    #
    # @param target [Hash] one manifest target, already structurally valid
    # @param registry [CuratedGemRegistry]
    # @param patched [#call]
    # @return [true]
    # @raise [Error]
    def self.validate_target!(target, registry:, patched:)
      platform = target.fetch('platform')
      units = target.fetch('units')
      units.each do |unit|
        unit.fetch('packages').each do |package|
          name = package.fetch('name')
          version = package.fetch('version')
          raise Error, "#{name} version #{version.inspect} is not in canonical form" unless canonical_version?(version)

          validate_minimum!(package) if package.key?('minimum')
          next unless package.key?('self_build_equivalent')

          flag = package['self_build_equivalent']
          raise Error, "#{name} self_build_equivalent must be true or false, got #{flag.inspect}" unless [true, false].include?(flag)
          next unless flag

          unless self_build_candidate?(name, platform: platform, ruby_abi: target.fetch('ruby_abi'), registry: registry, patched: patched)
            raise Error, "#{name} self_build_equivalent requires an unpatched repack package Ruby4Lich5 builds on #{platform}"
          end

          holders = units.select { |item| item.fetch('packages').any? { |entry| entry.fetch('name') == name } }
          unless holders.all? { |item| item.fetch('install_order').last == name }
            raise Error, "#{name} self_build_equivalent is refused: another member of its unit depends on it"
          end

          native = holders.flat_map { |item| item.fetch('packages') }.reject { |entry| entry.fetch('name') == name }
                                                                     .select { |entry| Lich::RecoveryUnitPolicy.package_platform(entry, platform) == platform }
          unless native.empty?
            raise Error, "#{name} self_build_equivalent is refused: it depends on native unit-mate(s) " \
                         "#{native.map { |entry| entry.fetch('name') }.uniq.sort.join(', ')}"
          end
        end
      end
      validate_agreement!(units)
      true
    end

    # @raise [Error]
    def self.validate_minimum!(package)
      name = package.fetch('name')
      minimum = package['minimum']
      raise Error, "#{name} minimum #{minimum.inspect} is not a canonical release version" unless Lich::RecoveryUnitPolicy.canonical_release?(minimum)
      return unless Gem::Version.new(minimum) > Gem::Version.new(package.fetch('version'))

      raise Error, "#{name} minimum #{minimum} is above its version #{package.fetch('version')}"
    end

    # One identity per package: every copy of a name at one version agrees on
    # the effective minimum (by value, an absent one counting as +version+)
    # and on the flag, and a name never carries two different explicit
    # minimums. Copies at different versions (a legacy closure beside its
    # ranged replacement) are different packages.
    #
    # @raise [Error]
    def self.validate_agreement!(units)
      copies = units.flat_map { |unit| unit.fetch('packages') }.group_by { |package| package.fetch('name') }
      copies.each do |name, packages|
        explicit = packages.select { |package| package.key?('minimum') }.map { |package| Gem::Version.new(package.fetch('minimum')).canonical_segments }
        raise Error, "#{name} carries more than one minimum in this target" if explicit.uniq.length > 1

        packages.group_by { |package| package.fetch('version') }.each_value do |same|
          identities = same.map { |package| [Lich::RecoveryUnitPolicy.minimum_identity(package), Lich::RecoveryUnitPolicy.self_build_equivalent?(package)] }
          raise Error, "#{name} copies disagree on minimum or self_build_equivalent" unless identities.uniq.length == 1
        end
      end
    end
    private_class_method :validate_minimum!, :validate_agreement!

    # @param platform [String]
    # @param ruby_abi [String]
    # @param dependencies [Hash{String => Hash{String => Gem::Requirement}}]
    #   every closure member's runtime dependencies with their requirements,
    #   from the resolution lock
    # @param registry [CuratedGemRegistry]
    # @param patched [#call]
    def initialize(platform:, ruby_abi:, dependencies:, registry: KnownNativeGems.registry, patched: self.class.default_patched)
      @platform = platform
      @ruby_abi = ruby_abi
      @dependencies = dependencies
      @registry = registry
      @patched = patched
    end

    # Adds +minimum+ and +self_build_equivalent+ to every copy of each
    # package, decided once per name over all units holding it, so copies
    # can never disagree.
    #
    # @param target [Hash] one generated manifest target
    # @return [Hash] +target+
    # @raise [Error] for a configured minimum above the served version, or
    #   on a package a unit-mate pins exactly
    def apply!(target)
      units = target.fetch('units')
      units.flat_map { |unit| unit.fetch('packages') }.map { |package| package.fetch('name') }.uniq.each do |name|
        holders = units.select { |unit| unit.fetch('packages').any? { |package| package.fetch('name') == name } }
        copies = holders.flat_map { |unit| unit.fetch('packages') }.select { |package| package.fetch('name') == name }
        mates = holders.flat_map { |unit| unit.fetch('packages') }.reject { |package| package.fetch('name') == name }
                                                                  .uniq { |package| package.fetch('name') }
        minimum = minimum_for(name, copies, mates)
        flag = self_build_equivalent?(name, mates)
        copies.each do |package|
          package['minimum'] = minimum if minimum
          package['self_build_equivalent'] = true if flag
        end
      end
      target
    end

    private

    # @return [String, nil] the configured minimum when it is below the
    #   served version; nil when unset or equal (strict either way)
    # @raise [Error]
    def minimum_for(name, copies, mates)
      minimum = @registry.minimum_for(name, @platform, @ruby_abi)
      return nil unless minimum

      floor = Gem::Version.new(minimum)
      copies.each do |package|
        raise Error, "#{name} minimum #{minimum} is above its version #{package.fetch('version')}" if floor > Gem::Version.new(package.fetch('version'))
      end
      # An exact pin from a unit-mate means a lower installed copy never
      # resolves with the served dependent, so the minimum could only end
      # in a repair (redis -> redis-client, the Ruby-GNOME pins).
      pinning = mates.map { |package| package.fetch('name') }.select do |mate|
        requirement = dependencies_of(mate)[name]
        requirement&.requirements&.all? { |operator, _version| operator == '=' }
      end
      raise Error, "#{name} minimum is refused: pinned exactly by #{pinning.sort.join(', ')}" unless pinning.empty?

      floor < Gem::Version.new(copies.first.fetch('version')) ? minimum : nil
    end

    # @return [Boolean]
    def self_build_equivalent?(name, mates)
      return false unless self.class.self_build_candidate?(name, platform: @platform, ruby_abi: @ruby_abi, registry: @registry, patched: @patched)

      mate_names = mates.map { |package| package.fetch('name') }
      return false if mate_names.any? { |mate| dependencies_of(mate).key?(name) }

      native = mates.select { |package| Lich::RecoveryUnitPolicy.package_platform(package, @platform) == @platform }.map { |package| package.fetch('name') }
      (reachable_from(name) & mate_names & native).empty?
    end

    # @return [Array<String>] every name +name+ depends on, transitively
    def reachable_from(name)
      seen = []
      queue = dependencies_of(name).keys
      until queue.empty?
        current = queue.shift
        next if seen.include?(current)

        seen << current
        queue.concat(@dependencies.fetch(current, {}).keys)
      end
      seen
    end

    # @raise [Error] when the lock has no dependency record for a unit member
    def dependencies_of(name)
      @dependencies.fetch(name) { raise Error, "no locked dependency record for unit member #{name}" }
    end
  end
end
