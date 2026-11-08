# frozen_string_literal: true

require 'ruby4lich5/staged_gem_spec_finder'
require 'ruby4lich5/installed_gem_closure'
require 'tmpdir'
require 'fileutils'
require 'rubygems/package'

RSpec.describe Ruby4Lich5::StagedGemSpecFinder do
  # Builds a real, on-disk .gem file (not a fixture double) so this spec
  # proves the class reads real RubyGems package metadata, the exact thing
  # the review finding this class exists to fix was about.
  def build_real_gem(dir, name, version, deps: [])
    spec = Gem::Specification.new(name, version) do |s|
      s.summary = 'fixture'
      s.authors = ['fixture']
      s.files = []
      deps.each { |dep| s.add_dependency(dep, '>= 0') }
    end
    Dir.chdir(dir) { Gem::Package.build(spec) }
    File.join(dir, "#{name}-#{version}.gem")
  end

  around do |example|
    Dir.mktmpdir('staged-gem-spec-finder-spec-') { |dir| @pkg_dir = dir; example.run }
  end

  describe '#call' do
    it 'finds a real staged gem by name, with its real declared dependencies intact' do
      build_real_gem(@pkg_dir, 'terminal-table', '4.0.0', deps: ['unicode-display_width'])
      build_real_gem(@pkg_dir, 'unicode-display_width', '3.2.0')

      finder = described_class.new(pkg_dir: @pkg_dir)
      specs = finder.call('terminal-table')

      expect(specs.length).to eq(1)
      expect(specs.first.name).to eq('terminal-table')
      expect(specs.first.version.to_s).to eq('4.0.0')
      expect(specs.first.runtime_dependencies.map(&:name)).to eq(['unicode-display_width'])
    end

    it 'finds staged gems when the directory path contains backslashes' do
      # Windows workflows pass D:\a\...\dist\pkg; a backslash in a glob pattern
      # escapes the next character, so a pattern-joined path matches nothing.
      backslash_dir = File.join(@pkg_dir, 'dist\\pkg')
      FileUtils.mkdir_p(backslash_dir)
      build_real_gem(backslash_dir, 'curses', '1.7.0')

      finder = described_class.new(pkg_dir: backslash_dir)

      expect(finder.call('curses').map(&:name)).to eq(['curses'])
    end

    it 'returns an empty array for a name with no staged gem file' do
      finder = described_class.new(pkg_dir: @pkg_dir)

      expect(finder.call('nothing-staged')).to eq([])
    end

    it 'returns every staged version when more than one copy of a name exists' do
      build_real_gem(@pkg_dir, 'concurrent-ruby', '1.3.7')
      build_real_gem(@pkg_dir, 'concurrent-ruby', '1.2.0')

      finder = described_class.new(pkg_dir: @pkg_dir)

      expect(finder.call('concurrent-ruby').map { |s| s.version.to_s }).to contain_exactly('1.3.7', '1.2.0')
    end

    it 'is usable directly as InstalledGemClosure\'s find_specs, real dependency edges intact' do
      build_real_gem(@pkg_dir, 'kramdown', '2.5.2', deps: ['rexml'])
      build_real_gem(@pkg_dir, 'rexml', '3.4.4')

      closure = Ruby4Lich5::InstalledGemClosure.new(
        requested_names: ['kramdown'], find_specs: described_class.new(pkg_dir: @pkg_dir)
      )

      expect(closure.resolve.map { |n| n[:name] }).to eq(%w[rexml kramdown])
    end

    it 'raises CorruptGemError naming the offending path when a staged .gem file is genuinely unreadable' do
      # A real .gem is a tar archive; garbage bytes under a .gem name
      # reproduces a genuinely corrupt/truncated download, not a fixture
      # standing in for one.
      corrupt_path = File.join(@pkg_dir, 'broken-1.0.0.gem')
      File.write(corrupt_path, 'not actually a gem archive')

      finder = described_class.new(pkg_dir: @pkg_dir)

      expect { finder.call('broken') }.to raise_error(described_class::CorruptGemError, /#{Regexp.escape(corrupt_path)}/)
    end
  end
end
