# frozen_string_literal: true

require 'ruby4lich5/gem_unit_grouper'

RSpec.describe Ruby4Lich5::GemUnitGrouper do
  def node(name, deps = [])
    { name: name, version: '0.0.0', runtime_dependency_names: deps }
  end

  def root(id:, start_names:)
    described_class::Root.new(id: id, start_names: start_names)
  end

  describe '#units' do
    it 'gives a dependency-free root a single-member unit' do
      grouper = described_class.new(
        closure_nodes: [node('os')],
        roots: [root(id: 'os', start_names: ['os'])]
      )

      expect(grouper.units).to eq([{ id: 'os', members: ['os'], install_order: ['os'] }])
    end

    it "folds a root's private dependency into that root's own unit, dependency first" do
      # kramdown -> rexml, and nothing else requests rexml -- the real shape.
      grouper = described_class.new(
        closure_nodes: [node('kramdown', ['rexml']), node('rexml')],
        roots: [root(id: 'kramdown-runtime', start_names: ['kramdown'])]
      )

      expect(grouper.units).to eq(
        [{ id: 'kramdown-runtime', members: %w[rexml kramdown], install_order: %w[rexml kramdown] }]
      )
    end

    it 'folds a shared dependency into the one root that reaches it, when only one root does' do
      # The real GTK3 shape: cairo -> red-colors -> matrix, folded into the
      # single gtk3-runtime root even though matrix/red-colors are never
      # independently requested.
      grouper = described_class.new(
        closure_nodes: [
          node('glib2'), node('cairo', ['red-colors']), node('red-colors', ['matrix']), node('matrix')
        ],
        roots: [root(id: 'gtk3-runtime', start_names: %w[glib2 cairo])]
      )

      expect(grouper.units.first[:members]).to contain_exactly('glib2', 'cairo', 'red-colors', 'matrix')
    end

    it 'gives a gem that is both a root and another root\'s dependency a unit of its own AND membership in the other' do
      # tzinfo and concurrent-ruby are both independently listed in the
      # runtime-gems input *and* real dependencies of tzinfo-data -- the
      # schema has no inter-unit reference, so this duplication (a standalone
      # unit for each, plus membership inside tzinfo-data-runtime) is the
      # locked, deliberate behavior, not
      # something to dedupe away. Confirmed 2026-07-10: the hand-built
      # manifest that predates this generator was inconsistent about this --
      # it gave concurrent-ruby its own unit but not tzinfo. This spec locks
      # the corrected, consistent rule: every root gets a unit, always.
      grouper = described_class.new(
        closure_nodes: [
          node('tzinfo-data', %w[tzinfo]),
          node('tzinfo', %w[concurrent-ruby]),
          node('concurrent-ruby')
        ],
        roots: [
          root(id: 'tzinfo-data-runtime', start_names: ['tzinfo-data']),
          root(id: 'tzinfo', start_names: ['tzinfo']),
          root(id: 'concurrent-ruby', start_names: ['concurrent-ruby'])
        ]
      )

      result = grouper.units
      expect(result.find { |u| u[:id] == 'tzinfo-data-runtime' }[:members])
        .to contain_exactly('tzinfo-data', 'tzinfo', 'concurrent-ruby')
      # tzinfo standalone still needs concurrent-ruby to actually install --
      # a unit that dropped it would be incomplete, not just "smaller."
      expect(result.find { |u| u[:id] == 'tzinfo' }[:members]).to contain_exactly('tzinfo', 'concurrent-ruby')
      expect(result.find { |u| u[:id] == 'concurrent-ruby' }[:members]).to eq(['concurrent-ruby'])
    end

    it 'raises if two roots declare the same id' do
      expect do
        described_class.new(
          closure_nodes: [node('os')],
          roots: [root(id: 'os', start_names: ['os']), root(id: 'os', start_names: ['os'])]
        )
      end.to raise_error(ArgumentError, /duplicate root id/)
    end

    it 'raises if a root names a start gem not present in the resolved closure' do
      expect do
        described_class.new(closure_nodes: [], roots: [root(id: 'os', start_names: ['os'])])
      end.to raise_error(ArgumentError, /os/)
    end

    it 'preserves the order roots were given, not closure order' do
      grouper = described_class.new(
        closure_nodes: [node('b'), node('a')],
        roots: [root(id: 'b', start_names: ['b']), root(id: 'a', start_names: ['a'])]
      )

      expect(grouper.units.map { |u| u[:id] }).to eq(%w[b a])
    end
  end
end
