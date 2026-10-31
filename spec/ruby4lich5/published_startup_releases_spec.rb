# frozen_string_literal: true

require 'ruby4lich5/published_startup_releases'

RSpec.describe Ruby4Lich5::PublishedStartupReleases do
  let(:fixture) { File.expand_path('../fixtures/lich5-contract/2130', __dir__) }
  let(:commit) { 'a' * 40 }
  let(:paths) { described_class::FILES + ['lib/version.rb'] }
  let(:bytes) { paths.to_h { |path| [path, File.binread(File.join(fixture, path))] } }
  let(:blob_ids) { bytes.transform_values { |body| Digest::SHA1.hexdigest("blob #{body.bytesize}\0" + body) } }
  let(:release) { { 'id' => 1, 'draft' => false, 'tag_name' => 'v5.23.0.rc1', 'prerelease' => true } }
  let(:request) do
    lambda do |endpoint|
      case endpoint
      when 'releases?per_page=100&page=1' then [release]
      when 'commits/v5.23.0.rc1' then { 'sha' => commit }
      when "git/trees/#{commit}?recursive=1"
        { 'truncated' => false, 'tree' => blob_ids.map { |path, sha| { 'path' => path, 'sha' => sha, 'type' => 'blob', 'mode' => '100644' } } }
      else
        path = blob_ids.key(endpoint.delete_prefix('git/blobs/'))
        raise "unexpected endpoint #{endpoint}" unless path
        { 'sha' => blob_ids.fetch(path), 'encoding' => 'base64', 'content' => [bytes.fetch(path)].pack('m0') }
      end
    end
  end
  let(:inventory) { described_class.capture(request: request) }
  let(:client) do
    { 'lich_version'   => inventory.fetch('clients').first.fetch('lich_version'),
      'gemfile_sha256' => Digest::SHA256.hexdigest(bytes.fetch('Gemfile')),
      'files'          => described_class::FILES.reject { |path| path == 'Gemfile' }.to_h { |path| [path, Digest::SHA256.hexdigest(bytes.fetch(path))] } }
  end

  it 'includes prereleases using exact tag commits and verified source bytes, without a version cutoff' do
    entry = inventory.fetch('clients').first
    expect(entry).to include('commit' => commit, 'prerelease' => true)
    expect(entry.fetch('files').fetch('Gemfile')).to eq(client.fetch('gemfile_sha256'))
    expect(described_class.verify!(inventory, clients: [client], retired: {})).to be(true)
  end

  it 'follows every release page, including releases beyond the first hundred' do
    paged = lambda do |endpoint|
      case endpoint
      when 'releases?per_page=100&page=1' then Array.new(100) { |i| { 'id' => i + 2, 'draft' => true } }
      when 'releases?per_page=100&page=2' then [release]
      else request.call(endpoint)
      end
    end
    captured = described_class.capture(request: paged)
    expect(captured.fetch('release_ids').size).to eq(101)
    expect(captured.fetch('clients').first.fetch('tag')).to eq(release.fetch('tag_name'))
  end

  it 'fails closed on incomplete pages, repeated pages, truncated trees and acquisition errors' do
    [->(_endpoint) { {} }, ->(_endpoint) { Array.new(100) { release } }, ->(_endpoint) { raise 'API unavailable' }].each do |broken|
      expect { described_class.capture(request: broken) }.to raise_error(StandardError)
    end
    truncated = ->(endpoint) { endpoint.start_with?('git/trees/') ? { 'truncated' => true, 'tree' => [] } : request.call(endpoint) }
    expect { described_class.capture(request: truncated) }.to raise_error(ArgumentError, /incomplete release source tree/)
  end

  it 'rejects changed source bytes and a published implementation without the retained checker files' do
    corrupt = lambda do |endpoint|
      value = request.call(endpoint)
      endpoint.start_with?('git/blobs/') ? value.merge('content' => ['changed'].pack('m0')) : value
    end
    expect { described_class.capture(request: corrupt) }.to raise_error(ArgumentError, /blob bytes changed/)
    missing = lambda do |endpoint|
      value = request.call(endpoint)
      endpoint.start_with?('git/trees/') ? value.merge('tree' => value.fetch('tree').reject { |entry| entry['path'] == 'lib/startup_policy_compatibility.rb' }) : value
    end
    expect { described_class.capture(request: missing) }.to raise_error(ArgumentError, /lacks required retained source/)
  end

  it 'accepts GitHub line wrapping while preserving the exact source identities' do
    wrapped = lambda do |endpoint|
      value = request.call(endpoint)
      endpoint.start_with?('git/blobs/') ? value.merge('content' => value.fetch('content').scan(/.{1,60}/).join("\n") + "\n") : value
    end
    expect(described_class.capture(request: wrapped)).to eq(inventory)
  end

  it 'rejects invalid Base64 alphabet, whitespace and padding instead of decoding permissively' do
    ['not base64!', 'YQ=', 'YQ===', 'Y Q=='].each do |invalid|
      malformed = lambda do |endpoint|
        value = request.call(endpoint)
        endpoint.start_with?('git/blobs/') ? value.merge('content' => invalid) : value
      end
      expect { described_class.capture(request: malformed) }.to raise_error(ArgumentError, /invalid base64/)
    end
  end

  it 'loads both production helpers when requiring the base64 gem is forbidden' do
    root = File.expand_path('../..', __dir__)
    program = <<~'RUBY'
      module NoBase64Gem
        def require(feature)
          raise LoadError, 'base64 dependency is forbidden in this regression' if feature == 'base64'
          super
        end
      end
      Kernel.prepend(NoBase64Gem)
      ARGV.each { |path| require path }
      puts 'production helpers loaded without the base64 gem'
    RUBY
    output, error, status = Open3.capture3(
      { 'RUBYOPT' => nil, 'RUBYLIB' => nil, 'BUNDLER_SETUP' => nil, 'RUBYGEMS_GEMDEPS' => nil },
      RbConfig.ruby, '-e', program, File.join(root, 'lib/ruby4lich5/published_startup_releases.rb'),
      File.join(root, 'lib/ruby4lich5/runtime_smoke.rb')
    )
    expect(status.success?).to be(true), error
    expect(output).to include('production helpers loaded without the base64 gem')
  end

  it 'requires each published client even when the selected candidate has a different implementation' do
    changed = client.merge('files' => client.fetch('files').merge('lib/accepted_gem_policy.rb' => 'f' * 64))
    expect { described_class.verify!(inventory, clients: [changed], retired: {}) }.to raise_error(ArgumentError, /missing from retention/)
    expect { described_class.verify!(inventory.merge('complete' => false), clients: [client], retired: {}) }.to raise_error(ArgumentError, /complete published-client inventory/)
  end

  it 'permits only explicit retirement bound to the exact published source' do
    retirement = { release.fetch('tag_name') => { 'commit' => commit, 'reason' => 'Fixture client explicitly retired after support review' } }
    expect(described_class.verify!(inventory, clients: [], retired: retirement)).to be(true)
    retirement.values.first['commit'] = 'b' * 40
    expect { described_class.verify!(inventory, clients: [], retired: retirement) }.to raise_error(ArgumentError, /retirement must name/)
  end
end
