# frozen_string_literal: true

require 'tmpdir'
require 'ruby4lich5/delivery_map'
require 'ruby4lich5/classification'

RSpec.describe Ruby4Lich5::DeliveryMap do
  around do |example|
    Dir.mktmpdir { |dir| @directory = dir; example.run }
  end

  def entry(name, dependencies = [], state: :pure)
    File.binwrite(File.join(@directory, "#{name}-1.0#{state == :pure ? '' : '-x64-mingw-ucrt'}.gem"), "#{name} bytes")
    { name: name, version: '1.0', runtime_dependency_names: dependencies,
      classification: Ruby4Lich5::Classification.new(state: state, gem_name: name, gem_version: '1.0', reason: 'fixture',
                                                     msys2_packages: state == :native_self_contained ? ['fixture'] : nil,
                                                     platform_asset: state == :native_pass_through ? "#{name}-1.0-x64-mingw-ucrt.gem" : nil) }
  end

  def build(entries, roots:, contract: nil)
    nodes = entries.map { |item| item.slice(:name, :version, :runtime_dependency_names) }
    finder = instance_double(Ruby4Lich5::InstalledGemClosure, resolve: nodes)
    allow(Ruby4Lich5::InstalledGemClosure).to receive(:new).and_return(finder)
    lock = double('lock', closure: entries, requested_roots: roots.to_h { |name| [name, '1.0'] }, platform: 'x64-mingw-ucrt', contract: contract)
    described_class.build(lock, @directory).fetch('packages').to_h { |package| [package.fetch('name'), package] }
  end

  def gtk
    Ruby4Lich5::GemManifestGenerator::GTK3_STACK.map { |name| entry(name, [], state: :native_self_contained) }
  end

  it 'routes standalone pure and native pass-through files to original upstream URLs' do
    map = build(gtk + [entry('standalone'), entry('binary', [], state: :native_pass_through)], roots: %w[gtk3 standalone binary])
    expect(map.fetch('standalone')).to include('delivery' => 'upstream', 'url' => 'https://rubygems.org/downloads/standalone-1.0.gem')
    expect(map.fetch('binary')).to include('delivery' => 'upstream', 'url' => 'https://rubygems.org/downloads/binary-1.0-x64-mingw-ucrt.gem')
    expect(map.fetch('gtk3').fetch('delivery')).to eq('bundle')
  end

  it 'keeps complete multi-gem closures in the ZIP including a shared standalone root' do
    map = build(gtk + [entry('parent', ['shared']), entry('shared')], roots: %w[gtk3 parent shared])
    expect(map.fetch('parent').fetch('delivery')).to eq('bundle')
    expect(map.fetch('shared').fetch('delivery')).to eq('bundle')
  end

  it 'keeps built packages local even when standalone' do
    map = build(gtk + [entry('ox', [], state: :native_self_contained)], roots: %w[gtk3 ox])
    expect(map.fetch('ox')).to include('delivery' => 'bundle', 'url' => nil)
  end

  it 'checks the lock checksum for an unmodified GTK-only non-GTK package' do
    entries = gtk + [entry('red-colors')]
    gtk_node = entries.find { |item| item[:name] == 'cairo' }
    gtk_node[:runtime_dependency_names] << 'red-colors'
    contract = { 'promotable' => true, 'locked_packages' => { 'red-colors' => { 'sha256' => Digest::SHA256.hexdigest('red-colors bytes') } } }
    expect(build(entries, roots: ['gtk3'], contract: contract)).to have_key('red-colors')
    File.binwrite(File.join(@directory, 'red-colors-1.0.gem'), 'tampered bytes')
    expect { build(entries, roots: ['gtk3'], contract: contract) }.to raise_error(Ruby4Lich5::RuntimeContract::Error, /lock checksum: red-colors/)
  end
end
