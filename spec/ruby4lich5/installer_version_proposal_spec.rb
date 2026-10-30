# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'yaml'
require_relative '../../vendor/lich5/runtime_gem_contract'

RSpec.describe 'Installer version proposal provenance' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:workflow) { YAML.safe_load_file(File.join(root, '.github/workflows/propose-installer-version.yaml'), aliases: true) }
  let(:script) { workflow.fetch('jobs').fetch('propose').fetch('steps').find { |step| step['with']&.key?('script') }.fetch('with').fetch('script') }
  let(:utf8_bom) { [0xEF, 0xBB, 0xBF].pack('C*').force_encoding(Encoding::UTF_8) }
  let(:contract) { { 'schema' => 1, 'promotable' => true, 'lich5_commit' => 'a' * 40, 'fixture' => { 'z' => 1, 'a' => [2, { 'b' => 3, 'a' => 4 }] } } }
  let(:manifest) { { 'schema' => 1, 'targets' => [{ 'platform' => 'x64-mingw-ucrt', 'ruby_abi' => '4.0', 'contract' => contract, 'units' => [{ 'id' => 'runtime' }] }] } }
  let(:provenance) do
    { 'installer_version' => '040.003.005', 'installer_source_sha' => 'b' * 40,
      'ruby_installer_version' => '4.0.9-1', 'installer_sha256' => 'c' * 64,
      'runtime_contract_sha256' => Lich::RuntimeGemContract.digest(contract),
      'recovery_manifest_sha256' => Digest::SHA256.hexdigest(JSON.generate(manifest)) }
  end

  def asset(tag, name, body = nil, digest: nil)
    { 'name' => name, 'digest' => digest || "sha256:#{Digest::SHA256.hexdigest(body)}",
      'browser_download_url' => "https://github.com/fixture/Ruby4Lich5/releases/download/#{tag}/#{name}" }
  end

  # Execute the actual workflow body with local source files and in-memory
  # releases, asset streams, permissions and comments. No network or API writes.
  def propose(provenance: self.provenance, manifest: self.manifest, files: [], comments: [], bootstrap: false,
              missing: false, corrupt: false, permission: 'admin', rerun_permission: 'admin', external: false,
              download_error: false, compare_error: false, redirect: nil, oversized: false,
              provenance_bytes: nil, manifest_bytes: nil)
    tag = 'R4L5-v040.003.005'
    accepted_tag = 'R4L5-gem-bundle-x64-mingw-ucrt'
    prior_bytes = provenance_bytes || JSON.generate(provenance)
    manifest_bytes ||= JSON.generate(manifest)
    prior = { 'tag_name' => tag, 'body' => 'GemBundleDigest: ignored legacy data', 'assets' => [asset(tag, 'Ruby4Lich5.exe', digest: "sha256:#{'c' * 64}")] }
    prior['assets'] << asset(tag, 'installer-provenance.json', prior_bytes) unless missing
    accepted = { 'tag_name' => accepted_tag, 'assets' => [asset(accepted_tag, 'R4L5-gem-manifest.json', manifest_bytes)] }
    downloads = { asset(tag, 'installer-provenance.json', prior_bytes)['browser_download_url'] => corrupt ? '{}' : prior_bytes,
                  accepted['assets'].first['browser_download_url']                             => manifest_bytes }
    harness = <<~'JS'
      const fs = require('node:fs'), crypto = require('node:crypto');
      const input = JSON.parse(fs.readFileSync(0, 'utf8'));
      process.chdir(process.argv[1]);
      process.env.GITHUB_TRIGGERING_ACTOR = 'rerunner';
      globalThis.fetch = async (url, options) => {
        if (input.download_error) throw new Error('offline');
        if (options.redirect !== 'manual' || !options.signal) throw new Error('Unbounded fetch');
        if (input.redirect) return {status: 302, headers: {get: () => input.redirect}, body: {cancel: async () => {}}};
        if (!Object.hasOwn(input.downloads, url)) throw new Error(`Unexpected download: ${url}`);
        return {ok: true, status: 200, body: (async function*() {
          yield input.oversized ? Buffer.alloc(5 * 1024 * 1024 + 1) : Buffer.from(input.downloads[url]);
        })()};
      };
      const offlineRequire = name => {
        if (name === 'fs') return fs;
        if (name === 'crypto') return crypto;
        throw new Error(`Unexpected workflow dependency: ${name}`);
      };
      const writes = [], comparisons = [], warnings = [], notices = [], permissions = [];
      const listReleases = function() {}, listComments = function() {};
      const github = {rest: {
        repos: {
          listReleases,
          getCollaboratorPermissionLevel: async ({username}) => {
            permissions.push(username);
            return {data: {permission: username === 'rerunner' ? input.rerun_permission : input.permission}};
          },
          compareCommits: async args => {
            comparisons.push(args);
            if (input.compare_error) throw Object.assign(new Error('API unavailable'), {status: 503});
            return {data: {files: input.files}};
          },
          getReleaseByTag: async ({tag}) => {
            if (tag !== input.accepted.tag_name) throw new Error(`Unexpected release lookup: ${tag}`);
            return {data: input.accepted};
          }
        },
        issues: {listComments,
          createComment: async args => writes.push({action: 'create', ...args}),
          updateComment: async args => writes.push({action: 'update', ...args})}
      }, paginate: async endpoint => {
        if (endpoint === listReleases) return input.bootstrap ? [] : [input.prior];
        if (endpoint === listComments) return input.comments;
        throw new Error('Unexpected API endpoint');
      }};
      const context = {actor: 'admin', repo: {owner: 'fixture', repo: 'Ruby4Lich5'}, payload: {pull_request: {
        number: 48, head: {sha: 'd'.repeat(40), repo: {full_name: input.external ? 'external/fork' : 'fixture/Ruby4Lich5'}}}}};
      const core = {warning: message => warnings.push(message), notice: message => notices.push(message)};
      const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
      new AsyncFunction('require', 'github', 'context', 'core', input.script)(offlineRequire, github, context, core)
        .then(() => process.stdout.write(JSON.stringify({writes, comparisons, warnings, notices, permissions})))
        .catch(error => process.stdout.write(JSON.stringify({writes, comparisons, warnings, notices, permissions, error: error.message})));
    JS
    payload = { script: script, prior: prior, accepted: accepted, downloads: downloads, files: files, comments: comments,
                bootstrap: bootstrap, permission: permission, rerun_permission: rerun_permission, external: external,
                download_error: download_error, compare_error: compare_error, redirect: redirect, oversized: oversized }
    output, error, status = Open3.capture3('node', '-e', harness, root, stdin_data: JSON.generate(payload))
    raise "proposal harness failed: #{error}" unless status.success?
    JSON.parse(output)
  end

  def body(result)
    expect(result).not_to have_key('error')
    result.fetch('writes').first.fetch('body')
  end

  it 'retains the documented bootstrap counters' do
    expect(body(propose(bootstrap: true))).to include('R4L5-v040.001.002')
  end

  it 'proposes no bump when the actual provenance and accepted manifest agree' do
    result = propose
    expect(body(result)).to include('No change detected', 'No version bump proposed')
    expect(result.fetch('comparisons').first).to include('base' => 'b' * 40, 'head' => 'd' * 40)
  end

  it 'bumps Gems when accepted manifest bytes change' do
    provenance['recovery_manifest_sha256'] = 'e' * 64
    expect(body(propose)).to include('R4L5-v040.004.005', 'Gems 003 -> 004')
  end

  it 'bumps Gems when the runtime contract differs' do
    provenance['runtime_contract_sha256'] = 'e' * 64
    expect(body(propose)).to include('R4L5-v040.004.005')
  end

  it 'bumps CI for changed installer inputs including PATH normalization' do
    expect(body(propose(files: [{ 'filename' => 'update-ruby-path.ps1' }]))).to include('R4L5-v040.003.006', 'CI 5 -> 6')
  end

  it 'bumps CI for a RubyInstaller patch change within the same ABI' do
    provenance['ruby_installer_version'] = '4.0.8-1'
    expect(body(propose)).to include('R4L5-v040.003.006')
  end

  it 'tracks renamed installer inputs' do
    expect(body(propose(files: [{ 'filename' => 'new.ps1', 'previous_filename' => 'fetch-lich.ps1' }]))).to include('R4L5-v040.003.006')
  end

  it 'does not infer a counter from legacy notes when provenance is absent' do
    expect(body(propose(missing: true))).to include('Version proposal unavailable', 'no installer-provenance.json')
  end

  it 'does not infer a counter from incomplete historical provenance' do
    provenance.delete('runtime_contract_sha256')
    expect(body(propose)).to include('Version proposal unavailable', 'predates complete')
  end

  it 'accepts checksummed complete provenance with a leading UTF-8 BOM' do
    bytes = utf8_bom + JSON.generate(provenance)
    expect(body(propose(provenance_bytes: bytes))).to include('No version bump proposed')
  end

  it 'reports unavailable historical provenance with a PowerShell BOM and CRLF encoding' do
    legacy = provenance.reject { |key, _| %w[runtime_contract_sha256 recovery_manifest_sha256].include?(key) }
    bytes = utf8_bom + JSON.pretty_generate(legacy).gsub("\n", "\r\n") + "\r\n"
    result = propose(provenance_bytes: bytes)
    expect(body(result)).to include('Version proposal unavailable', 'predates complete')
    expect(result.fetch('comparisons')).to be_empty
  end

  it 'preserves the original manifest digest when decoding a leading BOM' do
    bytes = utf8_bom + JSON.generate(manifest)
    provenance['recovery_manifest_sha256'] = Digest::SHA256.hexdigest(bytes)
    expect(body(propose(manifest_bytes: bytes))).to include('No version bump proposed')
  end

  [0, 1, 2].each do |bom_count|
    it "rejects malformed JSON with #{bom_count} leading BOMs after verifying its checksum" do
      bytes = (utf8_bom * bom_count) + (bom_count == 2 ? '{}' : '{invalid')
      result = propose(provenance_bytes: bytes)
      expect(result.fetch('error')).to include('is not valid JSON')
      expect(result.fetch('writes')).to be_empty
    end
  end

  it 'continues to reject changed bytes for BOM-bearing provenance' do
    result = propose(provenance_bytes: utf8_bom + JSON.generate(provenance), corrupt: true)
    expect(result.fetch('error')).to include('SHA-256 does not match')
    expect(result.fetch('writes')).to be_empty
  end

  it 'does not guess a bump during an offline asset read' do
    expect(body(propose(download_error: true))).to include('Version proposal unavailable', 'offline')
  end

  it 'does not guess a bump during a failed comparison' do
    expect(body(propose(compare_error: true))).to include('Version proposal unavailable', 'API unavailable')
  end

  it 'does not rely on a truncated source comparison' do
    expect(body(propose(files: Array.new(300) { { 'filename' => 'other' } }))).to include('comparison is incomplete')
  end

  it 'rejects corrupted downloaded provenance before any comment write' do
    result = propose(corrupt: true)
    expect(result.fetch('error')).to include('SHA-256 does not match')
    expect(result.fetch('writes')).to be_empty
  end

  it 'rejects a different installer executable identity' do
    provenance['installer_sha256'] = 'f' * 64
    expect(propose.fetch('error')).to include('executable digest disagrees')
  end

  it 'rejects malformed contract identities' do
    provenance['runtime_contract_sha256'] = 'invalid'
    expect(propose.fetch('error')).to include('Invalid installer provenance fields')
  end

  it 'rejects an ambiguous applicable target' do
    manifest['targets'] << manifest['targets'].first.dup
    expect(propose.fetch('error')).to include('unique target contract')
  end

  it 'rejects redirects to an insecure protocol' do
    expect(propose(redirect: 'http://example.test/file').fetch('error')).to include('Unsafe asset redirect')
  end

  it 'bounds redirect loops' do
    expect(body(propose(redirect: 'https://example.test/file'))).to include('Too many redirects')
  end

  it 'rejects oversized documents before a comment write' do
    result = propose(oversized: true)
    expect(result.fetch('error')).to include('exceeds size limit')
    expect(result.fetch('writes')).to be_empty
  end

  it 'updates the bot proposal while leaving human marker comments alone' do
    result = propose(comments: [{ 'id' => 1, 'body' => '<!-- r4l5-version-proposal -->', 'user' => { 'login' => 'owner' } },
                                { 'id' => 2, 'body' => '<!-- r4l5-version-proposal -->', 'user' => { 'login' => 'github-actions[bot]' } }])
    expect(body(result)).to include('No change detected')
    expect(result.fetch('writes')).to contain_exactly(hash_including('action' => 'update', 'comment_id' => 2))
  end

  it 'requires an administrator action and administrator rerun actor' do
    [propose(permission: 'write'), propose(rerun_permission: 'write'), propose(external: true)].each do |result|
      expect(result).not_to have_key('error')
      expect(result.fetch('notices')).not_to be_empty
      expect(result.fetch('writes')).to be_empty
      expect(result.fetch('comparisons')).to be_empty
    end
  end
end
