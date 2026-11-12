# frozen_string_literal: true

require 'ruby4lich5/published_startup_releases'

RSpec.describe Ruby4Lich5::PublishedStartupReleases do
  let(:fixture) { File.expand_path('../fixtures/lich5-contract/current', __dir__) }
  let(:commit) { 'a' * 40 }
  let(:paths) { described_class::FILES + ['lib/version.rb'] }
  let(:bytes) { paths.to_h { |path| [path, File.binread(File.join(fixture, path))] } }
  let(:blob_ids) { bytes.transform_values { |body| Digest::SHA1.hexdigest("blob #{body.bytesize}\0" + body) } }
  # A synthetic prerelease tag: lich_version comes from the fixture's version.rb,
  # and nothing compares the tag to it.
  let(:tag) { 'fixture.prerelease' }
  let(:release) { { 'id' => 1, 'draft' => false, 'tag_name' => tag, 'prerelease' => true } }
  let(:request) do
    lambda do |endpoint|
      case endpoint
      when 'releases?per_page=100&page=1' then [release]
      when "commits/#{tag}" then { 'sha' => commit }
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

  it 'does not exempt a required published client when a retirement tag is misspelled' do
    retired = { "#{tag}-typo" => { 'commit' => commit, 'reason' => 'Reviewed fixture retirement' } }
    expect { described_class.verify!(inventory, clients: [], retired: retired) }.to raise_error(ArgumentError, /missing from retention/)
    expect(described_class.verify!(inventory, clients: [client], retired: retired)).to be(true)
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

  it 'rejects changed source bytes even if the client could otherwise be retired' do
    corrupt = lambda do |endpoint|
      value = request.call(endpoint)
      endpoint.start_with?('git/blobs/') ? value.merge('content' => ['changed'].pack('m0')) : value
    end
    expect { described_class.capture(request: corrupt) }.to raise_error(ArgumentError, /blob bytes changed/)
  end

  def without_source(*paths)
    lambda do |endpoint|
      value = request.call(endpoint)
      endpoint.start_with?('git/trees/') ? value.merge('tree' => value.fetch('tree').reject { |entry| paths.include?(entry['path']) }) : value
    end
  end

  def retirement
    { release.fetch('tag_name') => { 'commit' => commit, 'reason' => 'Fixture client explicitly retired after support review' } }
  end

  it 'captures a 2128-shaped prerelease and permits only exact-source retirement of its incomplete implementation' do
    # Model the published-source shape: accepted policy exists, unit policy does not.
    # Present blob bytes are the independently captured current fixture, not 2128 bytes.
    captured = described_class.capture(request: without_source('lib/recovery_unit_policy.rb'))
    entry = captured.fetch('clients').first
    expect(entry).to include('commit' => commit, 'tag' => release.fetch('tag_name'), 'prerelease' => true,
                             'missing_files' => ['lib/recovery_unit_policy.rb'])
    expect { described_class.verify!(captured, clients: [], retired: {}) }.to raise_error(ArgumentError, /lacks required retained source/)
    expect(described_class.verify!(captured, clients: [], retired: retirement)).to be(true)
    wrong = retirement.transform_values { |entry| entry.merge('commit' => 'b' * 40) }
    expect { described_class.verify!(captured, clients: [], retired: wrong) }.to raise_error(ArgumentError, /retirement must name/)
    no_reason = retirement.transform_values { |entry| entry.merge('reason' => ' ') }
    expect { described_class.verify!(captured, clients: [], retired: no_reason) }.to raise_error(ArgumentError, /retirement must name/)
  end

  it 'records absent checker or version files but never infers retirement for them' do
    %w[lib/startup_policy_compatibility.rb lib/version.rb].each do |path|
      captured = described_class.capture(request: without_source(path))
      expect(captured.fetch('clients').first.fetch('missing_files')).to eq([path])
      expect { described_class.verify!(captured, clients: [], retired: {}) }.to raise_error(ArgumentError, /lacks required retained source/)
      expect(described_class.verify!(captured, clients: [], retired: retirement)).to be(true)
    end
  end

  it 'rejects malformed missing-file identities before considering exact retirement' do
    [nil, ['unknown'], ['Gemfile'], ['lib/version.rb', 'lib/version.rb']].each do |missing|
      changed = Marshal.load(Marshal.dump(inventory))
      changed.fetch('clients').first['missing_files'] = missing
      expect { described_class.verify!(changed, clients: [], retired: retirement) }.to raise_error(ArgumentError, /invalid published-client source identity/)
    end
  end

  it 'does not downgrade unavailable or malformed present blobs to missing files' do
    [-> { raise 'API unavailable' }, -> { { 'sha' => 'f' * 40, 'encoding' => 'base64', 'content' => '' } }].each do |failure|
      broken = lambda do |endpoint|
        next failure.call if endpoint.start_with?('git/blobs/')
        without_source('lib/recovery_unit_policy.rb').call(endpoint)
      end
      expect { described_class.capture(request: broken) }.to raise_error(StandardError)
    end
  end

  it 'rejects a present invalid version rather than treating it as absent' do
    bytes['lib/version.rb'] = "LICH_VERSION = 'not a version'\n"
    expect { described_class.capture(request: without_source('lib/recovery_unit_policy.rb')) }.to raise_error(ArgumentError, /no explicit version/)
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
