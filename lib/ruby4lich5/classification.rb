# frozen_string_literal: true

module Ruby4Lich5
  # Immutable result of classifying a single gem (name + version) for a target
  # platform and Ruby ABI. See {Classifier} for how a Classification is produced.
  #
  # @!attribute [r] state
  #   @return [Symbol] one of {STATES}
  # @!attribute [r] gem_name
  #   @return [String] the gem name that was classified
  # @!attribute [r] gem_version
  #   @return [String] the exact requested version that was classified
  # @!attribute [r] reason
  #   @return [String] a short, human-readable explanation of why this state
  #     was chosen -- always present, especially important for
  #     +:native_needs_system_lib+ so a maintainer knows what to do next
  # @!attribute [r] platform_asset
  #   @return [String, nil] the precompiled asset filename to fetch verbatim,
  #     present only when +state+ is +:native_pass_through+
  # @!attribute [r] msys2_packages
  #   @return [Array<String>, nil] the MSYS2 packages required to build this
  #     gem ourselves, named under the selected platform's package prefix
  #     (ucrt64 on x64, clangarm64 on aarch64; see +config/platforms.json+),
  #     present only when +state+ is +:native_self_contained+
  class Classification < Struct.new(
    :state,
    :gem_name,
    :gem_version,
    :reason,
    :platform_asset,
    :msys2_packages,
    keyword_init: true
  )
    # The complete set of valid {#state} values.
    #
    # Deliberately an explicit +class ... < Struct.new(...)+ rather than the
    # +Struct.new(...) do ... end+ block form: constants assigned inside that
    # block form follow *lexical* scope (the enclosing +module+), not the
    # anonymous Struct subclass being built, so +STATES+ would silently
    # attach to +Ruby4Lich5+ instead of +Ruby4Lich5::Classification+. Verified
    # directly -- this bit during initial implementation.
    #
    # @return [Array<Symbol>]
    STATES = %i[pure native_pass_through native_self_contained native_needs_system_lib ruby_bundled].freeze

    # Which of {#platform_asset} / {#msys2_packages} each state requires
    # present versus requires absent. Enforced by {#initialize} so
    # Classification is a real boundary contract -- a caller cannot construct
    # a +:native_pass_through+ with no asset, or a +:pure+ with a stray
    # +msys2_packages+ left over from copy-pasted construction code.
    #
    # @return [Hash{Symbol => Hash{Symbol => Boolean}}]
    STATE_FIELD_RULES = {
      pure: { platform_asset: false, msys2_packages: false },
      native_pass_through: { platform_asset: true, msys2_packages: false },
      native_self_contained: { platform_asset: false, msys2_packages: true },
      native_needs_system_lib: { platform_asset: false, msys2_packages: false },
      ruby_bundled: { platform_asset: false, msys2_packages: false }
    }.freeze
    private_constant :STATE_FIELD_RULES

    # @raise [ArgumentError] if constructed with a state outside {STATES}, or
    #   with +platform_asset+/+msys2_packages+ that don't match what {#state}
    #   requires (see {STATE_FIELD_RULES})
    def initialize(*)
      super
      validate_state!
      validate_state_fields!
    end

    # @return [Boolean] true when the front door must fetch the upstream
    #   precompiled gem directly and skip compilation entirely
    def pass_through?
      state == :native_pass_through
    end

    # @return [Boolean] true when the front door must compile this gem itself
    #   via the known MSYS2 package set
    def self_contained?
      state == :native_self_contained
    end

    # @return [Boolean] true when this gem cannot be built or vendored safely
    #   and the whole request should fail loudly rather than guess
    def needs_system_lib?
      state == :native_needs_system_lib
    end

    # @return [Boolean] true when the gem has no native extension at all
    def pure?
      state == :pure
    end

    # @return [Boolean] true when the gem ships as a Ruby default gem,
    #   already present and compiled in the target Ruby install -- nothing
    #   to build or vendor at all
    def ruby_bundled?
      state == :ruby_bundled
    end

    private

    # @raise [ArgumentError] if {#state} isn't one of {STATES}
    def validate_state!
      return if STATES.include?(state)

      raise ArgumentError, "state must be one of #{STATES.inspect}, got #{state.inspect}"
    end

    # @raise [ArgumentError] if {#platform_asset} or {#msys2_packages} don't
    #   match {STATE_FIELD_RULES} for the current {#state}
    def validate_state_fields!
      rules = STATE_FIELD_RULES.fetch(state)
      validate_field_presence!(:platform_asset, platform_asset, required: rules.fetch(:platform_asset))
      validate_field_presence!(:msys2_packages, msys2_packages, required: rules.fetch(:msys2_packages))
    end

    # @param field [Symbol] used only in the raised error message
    # @param value [Object] the field's current value
    # @param required [Boolean] whether +state+ requires this field present
    # @raise [ArgumentError] if +value+'s presence doesn't match +required+
    def validate_field_presence!(field, value, required:)
      present = !(value.nil? || (value.respond_to?(:empty?) && value.empty?))

      if required && !present
        raise ArgumentError, "state #{state.inspect} requires #{field}, but none was given"
      elsif !required && present
        raise ArgumentError, "state #{state.inspect} must not set #{field}, but got #{value.inspect}"
      end
    end
  end
end
