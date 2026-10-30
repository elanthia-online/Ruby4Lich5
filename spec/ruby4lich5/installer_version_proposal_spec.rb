# frozen_string_literal: true

require 'json'
require 'open3'
require 'yaml'

RSpec.describe 'Installer version proposal compatibility' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:workflow) { YAML.safe_load_file(File.join(root, '.github/workflows/propose-installer-version.yaml'), aliases: true) }
  let(:script) { workflow.fetch('jobs').fetch('propose').fetch('steps').find { |step| step['with']&.key?('script') }.fetch('with').fetch('script') }
  let(:digest) { "sha256:#{'a' * 64}" }
  let(:release) { { 'tag_name' => 'R4L5-v040.003.005', 'body' => "GemBundleDigest: #{digest}" } }

  # Execute the actual github-script body against local files and in-memory
  # API doubles. No GitHub requests or real comment writes are possible.
  def propose(releases: [release], current_digest: digest, files: [], comments: [])
    harness = <<~'JS'
      const fs = require('node:fs');
      const input = JSON.parse(fs.readFileSync(0, 'utf8'));
      process.chdir(process.argv[1]);
      globalThis.fetch = async () => { throw new Error('Network disabled in proposal tests'); };
      const offlineRequire = (name) => {
        if (name !== 'fs') throw new Error(`Unexpected workflow dependency: ${name}`);
        return fs;
      };
      const writes = [], tags = [], warnings = [];
      const listReleases = function() {}, listComments = function() {};
      const github = {
        rest: {
          repos: {
            listReleases,
            compareCommits: async () => ({data: {files: input.files}}),
            getReleaseByTag: async ({tag}) => {
              tags.push(tag);
              return {data: {assets: [{name: 'R4L5-gem-bundle-x64-mingw-ucrt.zip', digest: input.current_digest}]}};
            }
          },
          issues: {
            listComments,
            createComment: async (args) => writes.push({action: 'create', ...args}),
            updateComment: async (args) => writes.push({action: 'update', ...args})
          }
        },
        paginate: async (endpoint) => {
          if (endpoint === listReleases) return input.releases;
          if (endpoint === listComments) return input.comments;
          throw new Error('Unexpected API endpoint');
        }
      };
      const context = {repo: {owner: 'fixture', repo: 'Ruby4Lich5'}, payload: {pull_request: {number: 48, head: {sha: 'a'.repeat(40)}}}};
      const core = {warning: (message) => warnings.push(message)};
      const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
      new AsyncFunction('require', 'github', 'context', 'core', input.script)(offlineRequire, github, context, core)
        .then(() => process.stdout.write(JSON.stringify({writes, tags, warnings})))
        .catch((error) => process.stdout.write(JSON.stringify({writes, tags, warnings, error: error.message})));
    JS
    payload = { script: script, releases: releases, current_digest: current_digest, files: files, comments: comments }
    output, error, status = Open3.capture3('node', '-e', harness, root, stdin_data: JSON.generate(payload))
    raise "proposal harness failed: #{error}" unless status.success?
    JSON.parse(output)
  end

  it 'bootstraps successfully with the actual artifact-only installer workflow' do
    installer = YAML.safe_load_file(File.join(root, '.github/workflows/build-ruby4lich5-installer.yaml'), aliases: true)
    expect(installer.fetch(true).dig('workflow_dispatch', 'inputs')).not_to have_key('gem-release-tag')
    result = propose(releases: [])
    expect(result).not_to have_key('error')
    expect(result.fetch('writes').first.fetch('body')).to include('R4L5-v040.001.002')
  end

  it 'retains the no-bump proposal when the production ZIP digest and installer files match' do
    result = propose
    expect(result).not_to have_key('error')
    expect(result.fetch('tags')).to eq(['R4L5-gem-bundle-x64-mingw-ucrt'])
    expect(result.fetch('writes').first.fetch('body')).to include('No change detected', 'No version bump proposed')
  end

  it 'retains the Gems counter bump when the legacy bundle digest changes' do
    result = propose(current_digest: "sha256:#{'b' * 64}")
    expect(result).not_to have_key('error')
    expect(result.fetch('writes').first.fetch('body')).to include('R4L5-v040.004.005', 'Gems 003 -> 004')
  end

  it 'retains the CI counter bump for installer build changes' do
    result = propose(files: [{ 'filename' => '.github/workflows/build-ruby4lich5-installer.yaml' }])
    expect(result).not_to have_key('error')
    expect(result.fetch('writes').first.fetch('body')).to include('R4L5-v040.003.006', 'CI 5 -> 6')
  end

  it 'updates the existing proposal instead of creating another comment' do
    result = propose(comments: [{ 'id' => 123, 'body' => '<!-- r4l5-version-proposal -->previous proposal' }])
    expect(result).not_to have_key('error')
    expect(result.fetch('writes').length).to eq(1)
    expect(result.fetch('writes').first).to include('action' => 'update', 'comment_id' => 123)
  end

  it 'continues to reject malformed bundle digests before posting a proposal' do
    result = propose(current_digest: 'invalid')
    expect(result.fetch('error')).to include('missing or malformed digest')
    expect(result.fetch('writes')).to be_empty
  end
end
