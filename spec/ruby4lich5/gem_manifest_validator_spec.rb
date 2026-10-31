# frozen_string_literal: true

require 'ruby4lich5/gem_manifest_validator'
require 'ruby4lich5/gem_manifest_generator'
require 'ruby4lich5/rubygems_client'
require 'open3'
require Ruby4Lich5::GemManifestValidator::CONSUMER_PATH

RSpec.describe Ruby4Lich5::GemManifestValidator do
  let(:committed) { JSON.parse(File.read(File.expand_path('../../manifest/R4L5-gem-manifest.json', __dir__))) }

  it 'accepts every committed unit with the actual pinned consumer, without network or installation' do
    expect(described_class.validate!(committed)).to be(true)
  end

  it 'rejects a malformed later unit even when a first-match unit hides all its members' do
    units = committed.fetch('targets').first.fetch('units')
    duplicate = Marshal.load(Marshal.dump(units.first))
    duplicate['id'] = 'hidden-invalid-unit'
    duplicate['artifact']['sha256'] = 'bad digest'
    units << duplicate
    expect { described_class.validate!(committed) }.to raise_error(Lich::DependencyRecovery::Error, /SHA-256/)
  end

  it 'rejects an unsupported schema through the real recovery_plan' do
    committed['schema'] = 2
    expect { described_class.validate!(committed) }.to raise_error(ArgumentError, /unsupported manifest schema/)
  end

  it 'rejects empty manifests instead of treating them as a successful gate' do
    expect { described_class.validate!('schema' => 1, 'targets' => []) }.to raise_error(ArgumentError, /nonempty targets/)
  end

  it 'protects every vendored reader from checkout newline conversion' do
    root = File.expand_path('../..', __dir__)
    readers = Dir.glob(File.join(root, 'vendor/lich5/**/*.rb')).map { |path| path.delete_prefix("#{root}/") }
    output, status = Open3.capture2e('git', '-C', root, 'check-attr', 'text', '--', *readers)
    expect(status).to be_success, output
    expect(readers).not_to be_empty
    expect(output.lines.map(&:strip)).to match_array(readers.map { |path| "#{path}: text: unset" })
    bytes = File.binread(described_class::CONSUMER_PATH)
    expect(Digest::SHA256.hexdigest(bytes)).to eq(described_class::CONSUMER_SHA256)
    expect(Digest::SHA256.hexdigest(bytes.gsub("\n", "\r\n"))).not_to eq(described_class::CONSUMER_SHA256)
  end

  it 'accepts generated standalone ox/curses units and preserves GTK zip member filenames' do
    names = Ruby4Lich5::GemManifestGenerator::GTK3_STACK + %w[ox curses]
    nodes = names.map { |name| { name: name, version: '1.0.0', runtime_dependency_names: [] } }
    generator = Ruby4Lich5::GemManifestGenerator.new(
      root_names: names, delivery_states_by_name: names.to_h { |name| [name, 'native_self_contained'] },
      ruby_abi: '4.0', platform: 'x64-mingw-ucrt', repo: 'elanthia-online/Ruby4Lich5',
      bundle_asset: { tag: 'candidate', filename: 'bundle.zip', sha256: "sha256:#{'a' * 64}" },
      pkg_dir: '.', native_digest_lookup: ->(_name, _version) { "sha256:#{'b' * 64}" },
      rubygems_client: instance_double(Ruby4Lich5::RubygemsClient), closure_resolver: double(resolve: nodes),
      native_release_tag: 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1'
    )
    result = generator.generate
    expect(described_class.validate!(result)).to be(true)
    result.fetch('targets').first.fetch('units').each do |unit|
      if unit.dig('artifact', 'archive') == 'gem'
        expect(unit.fetch('packages').size).to eq(1)
        expect(unit.fetch('packages').first.fetch('filename')).to eq(unit.dig('artifact', 'filename'))
        expect(unit.dig('artifact', 'url')).to include('/R4L5-gem-bundle-x64-mingw-ucrt-candidate-123-1/')
      else
        expect(unit.fetch('packages').map { |package| package.fetch('filename') }).to all(match(/\A(?!R4L5-)/))
      end
    end
  end
end
