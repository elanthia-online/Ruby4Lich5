# frozen_string_literal: true

require 'timeout'
require_relative 'pinned_resolver_set'
require_relative 'runtime_contract'
require_relative 'build_planner'
require_relative 'closure_merger'

module Ruby4Lich5
  class ContractPlanner
    def self.plan(contract, classifier: nil, upstream: Gem::Resolver::BestSet.new)
      supplied = contract.data.fetch('ruby_inventory').fetch('gems')
      set = PinnedResolverSet.new(pins: contract.pins, supplied: supplied, platforms: contract.data.fetch('locked_packages').transform_values { |spec| spec.fetch('platform') }, upstream: upstream)
      dependencies = contract.roots.map { |name, version| Gem::Dependency.new(name, "= #{version}") }
      requests = Timeout.timeout(300) { Gem::Resolver.new(dependencies, set).resolve }
      nodes = requests.to_h do |request|
        spec = request.spec
        [spec.name, { name: spec.name, version: spec.version.to_s,
                      runtime_dependencies: spec.dependencies.select { |dep| dep.type == :runtime }.map { |dep| { name: dep.name, requirement: dep.requirement } } }]
      end
      classifier ||= Classifier.new(bundled_names: supplied.keys)
      source_nodes = Marshal.load(Marshal.dump(nodes))
      roles = contract.data.fetch('build_roles')
      # Match the existing GTK gemspec normalization: these edges are build
      # inputs, removed from the precompiled runtime packages.
      roles.fetch('gtk').each do |name|
        next unless nodes.key?(name)
        nodes[name][:runtime_dependencies].reject! { |dep| roles.fetch('tooling').include?(dep.fetch(:name)) }
      end
      reachable = {}
      visit_runtime = lambda do |name|
        next if reachable.key?(name)
        node = nodes.fetch(name)
        reachable[name] = node
        node.fetch(:runtime_dependencies).each { |dep| visit_runtime.call(dep.fetch(:name)) }
      end
      contract.roots.each_key { |name| visit_runtime.call(name) }
      dropped = nodes.keys - reachable.keys
      raise RuntimeContract::Error, 'unreviewed GTK build-only dependency' unless (dropped - roles.fetch('tooling')).empty?
      contract.data['build_tooling'] = dropped.to_h do |name|
        node = source_nodes.fetch(name)
        observed = classifier.classify(name: name, version: node.fetch(:version), platform: 'x64-mingw-ucrt', ruby_abi: '4.0')
        unless observed.pure? && contract.registry.classification_for(name, 'x64-mingw-ucrt', '4.0') == 'pure'
          raise RuntimeContract::Error, "unreviewed build-tool classification for #{name}"
        end
        [name, { 'name' => name, 'version' => node.fetch(:version),
                 'dependencies' => node.fetch(:runtime_dependencies).to_h { |dep| [dep.fetch(:name), dep.fetch(:requirement).as_list] } }]
      end
      nodes = reachable
      # Reuse the existing per-root planner, topological ordering and merger.
      # The graph is already resolved; this callable never contacts the network.
      resolver = ClosureResolver.new(resolve: lambda do |root, _version|
        reached = {}
        visit = lambda do |name|
          next if reached.key?(name)
          node = nodes.fetch(name)
          reached[name] = node
          node.fetch(:runtime_dependencies).each { |dep| visit.call(dep.fetch(:name)) }
        end
        visit.call(root)
        reached.values
      end)
      memo = {}
      cached = Object.new
      cached.define_singleton_method(:classify) { |**args| memo[args] ||= classifier.classify(**args) }
      planner = BuildPlanner.new(closure_resolver: resolver, classifier: cached)
      plans = contract.roots.to_h { |name, version| [name, planner.plan_for(name, version, platform: 'x64-mingw-ucrt', ruby_abi: '4.0')] }
      closure = ClosureMerger.new.merge(plans)
      contract.record_windows_identity!(closure.map { |entry| entry.fetch(:name) })
      RuntimeContract.validate!(contract.data, ruby_installer_version: contract.data.fetch('ruby_installer_version'), closure: closure)
      closure
    rescue Gem::Exception, Timeout::Error => e
      raise ClosureResolver::ResolutionError, "pinned contract resolution failed: #{e.message}"
    end
  end
end
