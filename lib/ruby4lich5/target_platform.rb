# frozen_string_literal: true

require 'json'
require_relative 'safe_token'

module Ruby4Lich5
  # One row of +config/platforms.json+: every platform-specific value the
  # factory's Ruby code needs, read from one table instead of being
  # hardcoded per file. +x64-mingw-ucrt+ is the default (it is
  # +config/target-ruby.json+'s platform); +aarch64-mingw-ucrt+ is used only
  # when something explicitly selects it. Another Windows platform is added
  # as its own row in the same way.
  #
  # Selection order ({.select}): explicit name, then +ENV['GEM_PLATFORM']+
  # (the Windows workflows already export it), then +config/target-ruby.json+'s
  # own +platform+. A name the table does not know is rejected rather than
  # falling back to a default.
  class TargetPlatform
    # Raised for a malformed table or an unknown or malformed selection.
    class Error < StandardError; end

    TABLE = File.expand_path('../../config/platforms.json', __dir__)
    TARGET = File.expand_path('../../config/target-ruby.json', __dir__)

    SCHEMA_VERSION = 1
    private_constant :SCHEMA_VERSION

    TOP_LEVEL_KEYS = %w[schema platforms].freeze
    private_constant :TOP_LEVEL_KEYS

    TOKEN_KEYS = %w[rubyinstaller_asset_suffix runner msystem msys2_prefix msys2_package_prefix gem_bundle_tag].freeze
    private_constant :TOKEN_KEYS

    ENTRY_KEYS = (TOKEN_KEYS + %w[msys2_bootstrap_packages toolchain]).freeze
    private_constant :ENTRY_KEYS

    TOOLCHAIN_KEYS = %w[cc make pkg_config objdump].freeze
    private_constant :TOOLCHAIN_KEYS

    # @return [String] the RubyGems platform, e.g. +"x64-mingw-ucrt"+
    attr_reader :name
    # @return [String] RubyInstaller archive suffix, e.g. +"x64"+ in +rubyinstaller-4.0.9-1-x64.7z+
    attr_reader :rubyinstaller_asset_suffix
    # @return [String] GitHub Actions runner label
    attr_reader :runner
    # @return [String] MSYS2 +MSYSTEM+ value, e.g. +"UCRT64"+
    attr_reader :msystem
    # @return [String] MSYS2 environment directory, e.g. +"ucrt64"+
    attr_reader :msys2_prefix
    # @return [String] MSYS2 package-name prefix, e.g. +"mingw-w64-ucrt-x86_64"+
    attr_reader :msys2_package_prefix
    # @return [Array<String>] the static MSYS2 toolchain set, in install order
    attr_reader :msys2_bootstrap_packages
    # @return [Hash{String => String}] toolchain executable names under the MSYS2 prefix +bin+
    attr_reader :toolchain
    # @return [String] accepted-manifest release tag; candidates append +-candidate-<run>-<attempt>+
    attr_reader :gem_bundle_tag

    # @param path [String]
    # @return [Hash{String => TargetPlatform}] every validated row, keyed by platform
    # @raise [Error]
    def self.load_table(path = TABLE)
      data = JSON.parse(File.read(path), allow_duplicate_key: false)
      unless data.is_a?(Hash) && data.keys.sort == TOP_LEVEL_KEYS.sort && data['schema'] == SCHEMA_VERSION
        raise Error, "#{path} must contain exactly #{TOP_LEVEL_KEYS.inspect} with schema #{SCHEMA_VERSION}"
      end
      platforms = data['platforms']
      raise Error, "#{path} platforms must be a non-empty object" unless platforms.is_a?(Hash) && !platforms.empty?

      platforms.to_h { |name, entry| [name, new(name, entry)] }.freeze
    rescue JSON::ParserError => e
      raise Error, "malformed platform table JSON: #{e.message}"
    end

    # @param name [String, nil] explicit platform; when nil, +GEM_PLATFORM+
    #   and then +target-ruby.json+ decide
    # @param env [#[], #key?] environment to consult for +GEM_PLATFORM+
    # @return [TargetPlatform]
    # @raise [Error] if the selected platform is malformed or not in the table
    def self.select(name = nil, env: ENV, table: TABLE, target: TARGET)
      name = env['GEM_PLATFORM'] if name.nil? && env.key?('GEM_PLATFORM')
      name = JSON.parse(File.read(target)).fetch('platform') { raise Error, "#{target} has no platform" } if name.nil?
      begin
        SafeToken.validate!(name, 'selected platform')
      rescue ArgumentError => e
        raise Error, e.message
      end
      platforms = load_table(table)
      platforms.fetch(name) { raise Error, "unknown platform #{name.inspect}; config/platforms.json defines #{platforms.keys.inspect}" }
    end

    # @return [TargetPlatform] the default selection ({.select} with no name)
    def self.current
      select
    end

    # @return [Regexp] matches exactly this platform's candidate release tags
    def candidate_tag_pattern
      /\A#{Regexp.escape(gem_bundle_tag)}-candidate-[1-9]\d*-[1-9]\d*\z/
    end

    def initialize(name, entry)
      token!(name, 'platform name')
      unless entry.is_a?(Hash) && entry.keys.sort == ENTRY_KEYS.sort
        raise Error, "platform #{name} must define exactly #{ENTRY_KEYS.sort.inspect}"
      end
      TOKEN_KEYS.each { |key| token!(entry[key], "#{name} #{key}") }
      raise Error, "#{name} gem_bundle_tag must be R4L5-gem-bundle-#{name}" unless entry['gem_bundle_tag'] == "R4L5-gem-bundle-#{name}"

      packages = entry['msys2_bootstrap_packages']
      raise Error, "#{name} msys2_bootstrap_packages must be a non-empty array" unless packages.is_a?(Array) && !packages.empty?
      packages.each { |package| token!(package, "#{name} msys2_bootstrap_packages entry") }
      raise Error, "#{name} msys2_bootstrap_packages must not repeat a package" unless packages.uniq == packages
      foreign = packages.select { |package| package.start_with?('mingw-w64-') && !package.start_with?("#{entry['msys2_package_prefix']}-") }
      raise Error, "#{name} msys2_bootstrap_packages name another MSYS2 environment: #{foreign.inspect}" unless foreign.empty?

      tools = entry['toolchain']
      raise Error, "#{name} toolchain must define exactly #{TOOLCHAIN_KEYS.sort.inspect}" unless tools.is_a?(Hash) && tools.keys.sort == TOOLCHAIN_KEYS.sort
      tools.each { |key, value| token!(value, "#{name} toolchain #{key}") }

      @name = name.dup.freeze
      TOKEN_KEYS.each { |key| instance_variable_set(:"@#{key}", entry[key].dup.freeze) }
      @msys2_bootstrap_packages = packages.map { |package| package.dup.freeze }.freeze
      @toolchain = tools.to_h { |key, value| [key.dup.freeze, value.dup.freeze] }.freeze
      freeze
    end

    private

    def token!(value, label)
      SafeToken.validate!(value, label)
    rescue ArgumentError => e
      raise Error, e.message
    end
  end
end
