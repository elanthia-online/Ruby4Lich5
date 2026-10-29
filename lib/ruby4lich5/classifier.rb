# frozen_string_literal: true

require_relative 'classification'
require_relative 'rubygems_client'
require_relative 'gem_inspector'
require_relative 'known_native_gems'
require_relative 'ruby_bundled_gems'

module Ruby4Lich5
  # Classifies a single gem, at an exact requested version, into one of
  # {Classification::STATES} -- the front door's first decision for any named
  # gem, per +docs/DECISIONS.md+ Phase 2 SS1.
  #
  # Deliberately makes no attempt to substitute a different version if the
  # exact one requested lacks a precompiled match for the target platform/ABI:
  # that would silently ship something other than what was reviewed and
  # approved. The classifier always resolves the version it was asked about,
  # one way or another.
  class Classifier
    # @param rubygems_client [RubygemsClient]
    # @param gem_inspector_class [Class] must respond to +.new(gem_path)+ and
    #   return an object with +#extensions?+ and +#abi_present?+ -- injectable
    #   so specs can stub package inspection without real +.gem+ files
    def initialize(rubygems_client: RubygemsClient.new, gem_inspector_class: GemInspector, bundled_names: RubyBundledGems::BUNDLED_GEMS)
      @rubygems_client = rubygems_client
      @gem_inspector_class = gem_inspector_class
      @bundled_names = bundled_names
    end

    # @param name [String] gem name
    # @param version [String] exact version to classify, e.g. +"3.5.6"+
    # @param platform [String] target RubyGems platform tag, e.g.
    #   +"x64-mingw-ucrt"+
    # @param ruby_abi [String] target Ruby ABI series, e.g. +"4.0"+
    # @return [Classification]
    def classify(name:, version:, platform:, ruby_abi:)
      return ruby_bundled_classification(name, version) if @bundled_names.include?(name)
      return pure_classification(name, version) unless native?(name, version)

      pass_through = pass_through_classification(name, version, platform, ruby_abi)
      pass_through || self_build_classification(name, version)
    end

    private

    # @return [Classification]
    def ruby_bundled_classification(name, version)
      Classification.new(
        state: :ruby_bundled,
        gem_name: name,
        gem_version: version,
        reason: 'ships as a Ruby default gem, already present in the target Ruby install; no build or vendoring needed'
      )
    end

    # @return [Boolean] true when the source ("ruby" platform) package for
    #   this exact name+version declares native extensions
    def native?(name, version)
      path = @rubygems_client.download_gem(name, version, platform: 'ruby')
      @gem_inspector_class.new(path).extensions?
    end

    # @return [Classification]
    def pure_classification(name, version)
      Classification.new(
        state: :pure,
        gem_name: name,
        gem_version: version,
        reason: 'no native extensions declared; fetched and packaged as-is'
      )
    end

    # @return [Classification, nil] a +:native_pass_through+ classification if
    #   upstream already precompiles this exact version for the requested
    #   platform *and* it bundles the requested Ruby ABI, else +nil+
    def pass_through_classification(name, version, platform, ruby_abi)
      return nil unless upstream_platform_build_exists?(name, version, platform)

      asset = @rubygems_client.asset_filename(name, version, platform)
      path = @rubygems_client.download_gem(name, version, platform: platform)
      return nil unless @gem_inspector_class.new(path).abi_present?(ruby_abi)

      Classification.new(
        state: :native_pass_through,
        gem_name: name,
        gem_version: version,
        reason: "upstream precompiles #{platform} for Ruby #{ruby_abi}; no compilation needed",
        platform_asset: asset
      )
    end

    # @return [Boolean]
    def upstream_platform_build_exists?(name, version, platform)
      @rubygems_client.versions(name).any? do |v|
        v['number'] == version && v['platform'] == platform
      end
    end

    # @return [Classification]
    def self_build_classification(name, version)
      packages = KnownNativeGems.packages_for(name)

      if packages
        Classification.new(
          state: :native_self_contained,
          gem_name: name,
          gem_version: version,
          reason: 'no matching precompiled upstream build; known buildable via curated MSYS2 packages',
          msys2_packages: packages
        )
      else
        Classification.new(
          state: :native_needs_system_lib,
          gem_name: name,
          gem_version: version,
          reason: "no matching precompiled upstream build, and #{name} is not in the curated " \
                   'buildable-gems list -- needs manual review before this can be built or vendored'
        )
      end
    end
  end
end
