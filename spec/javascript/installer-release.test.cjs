'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const {InstallerRelease, FILES, digest, canonical} = require('../../.github/scripts/installer-release.cjs');
const sha = 'a'.repeat(40);
const summary = new Proxy({}, {get: (_target, key) => key === 'write' ? async () => {} : () => summary});

function stream(bytes) {
  return new ReadableStream({start(controller) {controller.enqueue(bytes); controller.close();}});
}

function fixture({otherContracts = [], includeInstaller = true} = {}) {
  const writes = [];
  const contract = {schema: 2, promotable: true, overrides: {}, lich5_commit: 'b'.repeat(40)};
  const targets = [...otherContracts, ...(includeInstaller ? [contract] : [])].map(contract => ({contract}));
  const manifest = Buffer.from(JSON.stringify({targets}));
  const provenance = {installer_version: '040.002.003', installer_source_sha: sha, installer_run_id: 42,
    installer_sha256: digest(Buffer.from('installer')), runtime_contract_sha256: digest(Buffer.from(canonical(contract))),
    recovery_manifest_sha256: digest(manifest), accepted_manifest_digest: `sha256:${digest(manifest)}`,
    gem_source_sha: sha, gem_build_run_id: 12, ruby_installer_version: '4.0.9-1'};
  const files = {'Ruby4Lich5.exe': Buffer.from('installer'),
    'installer-provenance.json': Buffer.from(JSON.stringify(provenance)),
    'resolution-lock.json': Buffer.from(JSON.stringify({contract})),
    'gem-build-metadata.json': Buffer.from(JSON.stringify({source_sha: sha, run_id: 12, ruby_installer_version: '4.0.9-1'}))};
  let release = null;
  let nextAssetId = 1;
  const data = value => Promise.resolve({data: value});
  const rest = {git: {getRef: () => data({object: {sha, type: 'commit'}})}, users: {getAuthenticated: () => data({login: 'admin'})}, repos: {
    getCollaboratorPermissionLevel: () => data({permission: 'admin'}),
    getEnvironment: () => data({id: 7, protection_rules: [{type: 'required_reviewers', reviewers: [{type: 'User', reviewer: {login: 'admin'}}]}]}),
    getBranch: () => data({commit: {sha}}),
    getCommit: () => data({sha}),
    // The tag endpoint is published-only; authenticated listing includes drafts.
    getReleaseByTag: () => release && !release.draft ? data(release) : Promise.reject(Object.assign(new Error('not found'), {status: 404})),
    listReleases: () => data(release ? [release] : []),
    getRelease: ({release_id}) => release && release.id === release_id ? data(release) : Promise.reject(Object.assign(new Error('not found'), {status: 404})),
    createRelease: options => {
      writes.push(['create', options]);
      release = {id: 9, tag_name: options.tag_name, target_commitish: options.target_commitish, draft: options.draft,
        prerelease: false, body: options.body, assets: [], html_url: 'https://github.com/owner/repo/releases/tag/' + options.tag_name};
      return data(release);
    },
    uploadReleaseAsset: options => {
      writes.push(['upload', options]);
      release.assets.push({id: nextAssetId++, name: options.name, digest: `sha256:${digest(options.data)}`, bytes: options.data});
      return data({});
    },
    getReleaseAsset: options => Promise.resolve({headers: {}, data: stream(release.assets.find(asset => asset.id === options.asset_id).bytes)}),
    updateRelease: options => {writes.push(['publish', options]); release.draft = options.draft; return data(release);},
    getLatestRelease: () => data(release)
  }, actions: {getReviewsForRun: () => data([{state: 'approved', environments: [{id: 7}], user: {login: 'admin'}}])}};
  const context = {repo: {owner: 'owner', repo: 'repo'}, payload: {repository: {default_branch: 'main'}},
    eventName: 'workflow_dispatch', ref: 'refs/heads/main', sha, runId: 42, runAttempt: 1};
  const service = new InstallerRelease({github: {rest, paginate: async (method, args) => (await method(args)).data}, context, core: {summary}, sleep: async () => {}, download: async url => {
    if (url.endsWith('R4L5-gem-manifest.json')) return manifest;
    const name = url.split('/').pop();
    if (files[name]) return files[name];
    throw new Error('Unexpected download');
  }});
  return {service, rest, context, files, manifest, provenance, writes,
    get release() { return release; }, set release(value) { release = value; }};
}

async function temporary(fn) {
  const old = process.cwd();
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'installer-test-'));
  try {
    process.chdir(directory);
    return await fn(directory);
  } finally {
    process.chdir(old);
    fs.rmSync(directory, {recursive: true, force: true});
  }
}
async function draft(f, directory) {
  for (const name of FILES) fs.writeFileSync(path.join(directory, name), f.files[name]);
  return f.service.draft(directory);
}

test('assembles only a draft, uploads all bytes, reads them back and records identity', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  assert.equal(f.release.draft, true);
  assert.equal(f.writes[0][1].make_latest, 'false');
  assert.equal(f.writes.filter(([operation]) => operation === 'upload').length, 4);
  assert.equal(f.writes.filter(([operation]) => operation === 'publish').length, 0);
  assert.equal(receipt.assets['Ruby4Lich5.exe'], `sha256:${f.provenance.installer_sha256}`);
  assert.deepEqual(JSON.parse(fs.readFileSync('installer-release-receipt.json')), receipt);
}));

test('publishes exact accepted draft only after administrator environment approval, then verifies Latest', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  await f.service.publish(receipt);
  assert.equal(f.release.draft, false);
  const [operation, options] = f.writes.at(-1);
  assert.equal(operation, 'publish');
  assert.equal(options.make_latest, 'true');
  assert.equal(options.draft, false);
  assert.ok(options.request.signal instanceof AbortSignal);
  assert.equal(JSON.parse(fs.readFileSync('publication-status.json')).latest_verified, true);
}));

test('identical draft retry is idempotent and never clobbers assets', async () => temporary(async directory => {
  const f = fixture();
  await draft(f, directory);
  const count = f.writes.length;
  await f.service.draft(directory);
  assert.equal(f.writes.length, count);
}));

for (const [label, mutate, error] of [
  ['modified installer', f => {f.files['Ruby4Lich5.exe'] = Buffer.from('changed');}, /Installer bytes/],
  ['wrong source', f => {f.provenance.installer_source_sha = 'c'.repeat(40);}, /provenance source/],
  ['wrong run', f => {f.provenance.installer_run_id = 99;}, /provenance source/],
  ['unsafe version', f => {f.provenance.installer_version = '../bad';}, /provenance source/],
  ['wrong contract', f => {f.provenance.runtime_contract_sha256 = '0'.repeat(64);}, /Runtime contract/],
  ['wrong metadata', f => {f.provenance.gem_build_run_id = 100;}, /Gem metadata/],
  ['wrong accepted digest', f => {f.provenance.accepted_manifest_digest = 'sha256:' + '0'.repeat(64);}, /manifest provenance/]
]) {
  test(`rejects ${label} before creating a release`, async () => temporary(async directory => {
    const f = fixture();
    mutate(f);
    f.files['installer-provenance.json'] = Buffer.from(JSON.stringify(f.provenance));
    await assert.rejects(draft(f, directory), error);
    assert.equal(f.writes.length, 0);
  }));
}

test('unpromotable lock cannot be drafted even if its attestation is recomputed', async () => temporary(async directory => {
  const f = fixture();
  const lock = JSON.parse(f.files['resolution-lock.json']);
  lock.contract.promotable = false;
  f.files['resolution-lock.json'] = Buffer.from(JSON.stringify(lock));
  f.provenance.runtime_contract_sha256 = digest(Buffer.from(canonical(lock.contract)));
  f.files['installer-provenance.json'] = Buffer.from(JSON.stringify(f.provenance));
  await assert.rejects(draft(f, directory), /Runtime contract/);
  assert.equal(f.writes.length, 0);
}));

for (const state of ['published', 'different source', 'conflicting assets']) {
  test(`refuses ${state} rather than overwriting it`, async () => temporary(async directory => {
    const f = fixture();
    await draft(f, directory);
    if (state === 'published') f.release.draft = false;
    if (state === 'different source') f.release.target_commitish = 'c'.repeat(40);
    if (state === 'conflicting assets') f.release.assets[0].digest = 'sha256:' + '0'.repeat(64);
    const count = f.writes.length;
    await assert.rejects(f.service.draft(directory), /already published|conflicting assets/);
    assert.equal(f.writes.length, count);
  }));
}

for (const state of ['missing review rule', 'non-admin reviewer', 'team reviewer', 'no approval', 'non-admin approver', 'changed environment']) {
  test(`Latest fails closed for ${state}`, async () => temporary(async directory => {
    const f = fixture();
    const receipt = await draft(f, directory);
    if (state === 'missing review rule') f.rest.repos.getEnvironment = async () => ({data: {protection_rules: []}});
    if (state === 'non-admin reviewer' || state === 'non-admin approver') {
      let count = 0;
      f.rest.repos.getCollaboratorPermissionLevel = async () => ({data: {permission: state === 'non-admin reviewer' || count++ > 0 ? 'write' : 'admin'}});
    }
    if (state === 'team reviewer') f.rest.repos.getEnvironment = async () => ({data: {protection_rules: [{type: 'required_reviewers', reviewers: [{type: 'Team'}]}]}});
    if (state === 'no approval') f.rest.actions.getReviewsForRun = async () => ({data: []});
    if (state === 'changed environment') f.rest.actions.getReviewsForRun = async () => ({data: [{state: 'approved', environments: [{id: 8}], user: {login: 'admin'}}]});
    await assert.rejects(f.service.publish(receipt), /administrator|approval/);
    assert.equal(f.writes.filter(([operation]) => operation === 'publish').length, 0);
  }));
}

test('changed recovery blocks both draft assembly and publication', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  f.service.download = async () => Buffer.from('changed');
  const count = f.writes.length;
  await assert.rejects(f.service.publish(receipt), /Accepted recovery changed/);
  await assert.rejects(f.service.draft(directory), /Accepted recovery changed/);
  assert.equal(f.writes.length, count);
}));

test('post-approval asset replacement is rejected before publishing', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  const asset = f.release.assets.find(item => item.name === 'Ruby4Lich5.exe');
  asset.bytes = Buffer.from('replacement');
  asset.digest = `sha256:${digest(asset.bytes)}`;
  await assert.rejects(f.service.publish(receipt), /changed after build or approval/);
  assert.equal(f.release.draft, true);
}));

test('public Latest mismatch fails after publication and does not retry or roll back', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  const download = f.service.download;
  f.service.download = url => url.includes('/latest/') ? Buffer.from('stale public bytes') : download(url);
  await assert.rejects(f.service.publish(receipt), /Public Latest readback mismatch/);
  assert.equal(f.writes.filter(([operation]) => operation === 'publish').length, 1);
}));

test('non-default dispatch and moved main are rejected', async () => {
  const f = fixture();
  f.service.context.ref = 'refs/heads/other';
  await assert.rejects(f.service.defaultHead(), /default-branch/);
  f.service.context.ref = 'refs/heads/main';
  f.rest.repos.getBranch = async () => ({data: {commit: {sha: 'c'.repeat(40)}}});
  await assert.rejects(f.service.defaultHead(), /Default branch moved/);
});

test('a symlink cannot supply a release payload', async () => temporary(async directory => {
  const f = fixture();
  for (const name of FILES) fs.writeFileSync(name, f.files[name]);
  fs.renameSync('Ruby4Lich5.exe', 'other.exe');
  fs.symlinkSync('other.exe', 'Ruby4Lich5.exe');
  await assert.rejects(f.service.draft(directory), /regular files/);
  assert.equal(f.writes.length, 0);
}));

test('dispatch follows its returned run ID without title discovery and requires a successful exact-source first attempt', async () => {
  const f = fixture();
  const calls = [];
  const run = {id: 5, path: '.github/workflows/child.yml', head_sha: sha, event: 'workflow_dispatch',
    repository: {full_name: 'owner/repo'}, head_repository: {full_name: 'owner/repo'}, run_attempt: 1,
    status: 'completed', conclusion: 'success', html_url: 'https://example.test/5'};
  f.rest.actions.createWorkflowDispatch = async options => {calls.push(options); return {data: {workflow_run_id: 5}};};
  f.rest.actions.getWorkflowRun = async () => ({data: run});
  assert.equal((await f.service.dispatch('child.yml', {publish: 'true'}, 'factory')).id, 5);
  assert.equal(calls[0].inputs['release-request'], 'r4l5-release-42-1-factory');
  assert.equal(calls[0].headers['X-GitHub-Api-Version'], '2026-03-10');
  for (const [field, value] of [['head_sha', 'c'.repeat(40)], ['run_attempt', 2], ['conclusion', 'failure']]) {
    const prior = run[field];
    run[field] = value;
    await assert.rejects(f.service.dispatch('child.yml', {}, 'factory'), /identity|failed/);
    run[field] = prior;
  }
});

test('an ambiguous dispatch error is never automatically retried', async () => {
  const f = fixture();
  let calls = 0;
  f.rest.actions.createWorkflowDispatch = async () => {calls++; throw new Error('connection lost');};
  await assert.rejects(f.service.dispatch('child.yml', {}, 'factory'), /connection lost/);
  assert.equal(calls, 1);
});

test('coordinator carries actual inspected digests into promotion and the accepted candidate into assembly', async () => temporary(async () => {
  const f = fixture();
  const calls = [];
  f.service.dispatch = async (workflow, inputs, phase) => {calls.push({workflow, inputs, phase}); return {id: calls.length, run_attempt: 1};};
  const plan = {candidate_tag: 'R4L5-gem-bundle-x64-mingw-ucrt-candidate-1-1', source_sha: sha,
    candidate_sha256: 'sha256:' + '1'.repeat(64), live_sha256: 'sha256:' + '2'.repeat(64), change_sha256: 'sha256:' + '3'.repeat(64)};
  const receipt = {tag: 'R4L5-v040.002.003', source_sha: sha, installer_run_id: 4};
  f.service.artifactFile = async (_run, _artifact, name) => Buffer.from(JSON.stringify(name === 'promotion-plan.json' ? plan : receipt));
  await f.service.prepare({'lich5-commit': 'b'.repeat(40), 'installer-version': '040.002.003'});
  const request = JSON.parse(fs.readFileSync('release-request.json'));
  await f.service.promote(request);
  assert.deepEqual(calls[2].inputs, {mode: 'promote', 'candidate-tag': plan.candidate_tag,
    'candidate-sha256': plan.candidate_sha256, 'live-sha256': plan.live_sha256, 'change-sha256': plan.change_sha256});
  assert.equal(calls[3].inputs['gem-source'], 'accepted-candidate');
  assert.equal(calls[3].inputs['gem-candidate-tag'], plan.candidate_tag);
  assert.equal(calls[3].inputs['installer-version'], '040.002.003');
  assert.deepEqual(JSON.parse(fs.readFileSync('installer-release-receipt.json')), receipt);
}));

test('coordinator reruns and invalid parameters stop before a child workflow is dispatched', async () => {
  const f = fixture();
  f.service.context.runAttempt = 2;
  await assert.rejects(f.service.prepare({'lich5-commit': sha, 'installer-version': '040.002.003'}), /fresh release request/);
  await assert.rejects(f.service.prepare({'lich5-commit': 'main', 'installer-version': 'bad'}), /full Lich SHA/);
});

test('artifact extraction verifies archive bytes before reading the exact document', async () => temporary(async () => {
  const f = fixture();
  fs.writeFileSync('promotion-plan.json', '{"schema":1}');
  execFileSync('zip', ['-q', 'artifact.zip', 'promotion-plan.json']);
  const bytes = fs.readFileSync('artifact.zip');
  const artifact = {id: 10, name: 'preparation', expired: false, digest: `sha256:${digest(bytes)}`, workflow_run: {id: 5, head_sha: sha}};
  f.rest.actions.listWorkflowRunArtifacts = () => {};
  f.service.github.paginate = async () => [artifact];
  f.rest.actions.downloadArtifact = async () => ({headers: {}, data: stream(bytes)});
  assert.equal((await f.service.artifactFile({id: 5}, 'preparation', 'promotion-plan.json')).toString(), '{"schema":1}');
  artifact.digest = 'sha256:' + '0'.repeat(64);
  await assert.rejects(f.service.artifactFile({id: 5}, 'preparation', 'promotion-plan.json'), /archive digest mismatch/);
}));

test('factory failure prevents inspection, approval data and installer dispatch', async () => temporary(async () => {
  const f = fixture();
  const phases = [];
  f.service.dispatch = async (_workflow, _inputs, phase) => {phases.push(phase); throw new Error('factory failed');};
  await assert.rejects(f.service.prepare({'lich5-commit': sha, 'installer-version': '040.002.003'}), /factory failed/);
  assert.deepEqual(phases, ['factory']);
  assert.equal(fs.existsSync('release-request.json'), false);
}));

test('a missing release gate stops before factory publication', async () => {
  const f = fixture();
  f.rest.repos.getEnvironment = async () => ({data: {protection_rules: []}});
  f.service.dispatch = () => {throw new Error('must not dispatch');};
  await assert.rejects(f.service.prepare({'lich5-commit': sha, 'installer-version': '040.002.003'}), /configured administrator reviewers/);
});

test('approval for recovery does not authorize Latest when environments have distinct identities', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  const original = f.rest.repos.getEnvironment;
  f.rest.repos.getEnvironment = async options => {
    const response = await original(options);
    response.data.id = options.environment_name === 'r4l5-installer-latest' ? 8 : 7;
    return response;
  };
  await assert.rejects(f.service.publish(receipt), /No explicit approval/);
  assert.equal(f.release.draft, true);
}));

test('approval-job reruns cannot reuse a previous approval', async () => {
  const f = fixture();
  f.service.context.runAttempt = 2;
  await assert.rejects(f.service.approval('r4l5-installer-latest'), /fresh release request/);
});

test('an existing tag at another commit blocks release creation', async () => temporary(async directory => {
  const f = fixture();
  f.rest.repos.getCommit = async () => ({data: {sha: 'c'.repeat(40)}});
  await assert.rejects(draft(f, directory), /tag points to another source/);
  assert.equal(f.writes.length, 0);
}));

test('a tag moved after acceptance blocks publication', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  f.rest.repos.getCommit = async () => ({data: {sha: 'c'.repeat(40)}});
  await assert.rejects(f.service.publish(receipt), /tag points to another source/);
  assert.equal(f.release.draft, true);
}));

test('a new draft may have no tag until publishing; the published tag must then resolve correctly', async () => temporary(async directory => {
  const f = fixture();
  f.rest.git.getRef = async () => {
    if (!f.release || f.release.draft) throw Object.assign(new Error('no tag yet'), {status: 404});
    return {data: {object: {sha, type: 'commit'}}};
  };
  const receipt = await draft(f, directory);
  await f.service.publish(receipt);
  assert.equal(f.release.draft, false);
}));

test('a partial draft can finish only with identical already uploaded assets', async () => temporary(async directory => {
  const f = fixture();
  await draft(f, directory);
  f.release.assets.pop();
  const count = f.writes.length;
  await f.service.draft(directory);
  assert.equal(f.writes.length, count + 1);
  assert.equal(f.release.assets.length, 4);
}));

test('public release readback failure is not reported as verified publication', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  f.rest.repos.getLatestRelease = async () => ({data: {id: 999}});
  await assert.rejects(f.service.publish(receipt), /did not become Latest/);
  const status = JSON.parse(fs.readFileSync('publication-status.json'));
  assert.equal(status.latest_verified, false);
  assert.equal(status.state, 'published-unverified');
}));

for (const published of [false, true]) {
  test(`version preflight rejects an existing ${published ? 'published release' : 'draft'} before factory dispatch`, async () => temporary(async directory => {
    const f = fixture();
    await draft(f, directory);
    f.release.draft = !published;
    let dispatches = 0;
    f.service.dispatch = async () => {dispatches++;};
    await assert.rejects(f.service.prepare({'lich5-commit': sha, 'installer-version': '040.002.003'}), /already exists/);
    assert.equal(dispatches, 0);
  }));
}

test('draft discovery refuses duplicate tags, including an unrelated published release and a draft', async () => {
  const f = fixture();
  f.rest.repos.listReleases = async () => ({data: [{id: 1, tag_name: 'R4L5-v040.002.003', draft: true}, {id: 2, tag_name: 'R4L5-v040.002.003', draft: false}]});
  await assert.rejects(f.service.releaseByTag('R4L5-v040.002.003'), /Multiple releases/);
});

test('draft and Latest remain pinned to the receipt after main advances', async () => temporary(async directory => {
  const f = fixture();
  f.rest.repos.getBranch = async () => ({data: {commit: {sha: 'c'.repeat(40)}}});
  const receipt = await draft(f, directory);
  await f.service.publish(receipt);
  assert.equal(f.release.target_commitish, sha);
  assert.equal(f.release.draft, false);
  await assert.rejects(f.service.defaultHead(), /Default branch moved/);
}));

test('draft and Latest still require a default-branch manual dispatch', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  for (const event of ['push', 'workflow_run']) {
    f.service.context.eventName = event;
    await assert.rejects(f.service.draft(directory), /default-branch dispatch/);
    await assert.rejects(f.service.publish(receipt), /default-branch dispatch/);
  }
}));

test('native preflight requires an explicit version and permits only the same run to resume its draft', async () => temporary(async directory => {
  const f = fixture();
  await assert.rejects(f.service.preflightVersion(''), /explicit installer version/);
  await draft(f, directory);
  await f.service.preflightVersion('040.002.003', {sameRun: true});
  f.service.context.runId = 43;
  await assert.rejects(f.service.preflightVersion('040.002.003', {sameRun: true}), /another build/);
}));

test('the receipt ID cannot be replaced by another draft with the same tag', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  f.release.id = 99;
  await assert.rejects(f.service.publish(receipt), /not found/);
  assert.equal(f.release.draft, true);
}));

function dispatchedRun() {
  return {id: 5, path: '.github/workflows/child.yml', head_sha: sha, event: 'workflow_dispatch',
    repository: {full_name: 'owner/repo'}, head_repository: {full_name: 'owner/repo'}, run_attempt: 1,
    status: 'completed', conclusion: 'success', html_url: 'https://example.test/5'};
}

test('a transient poll failure recovers while the dispatch POST runs only once', async () => {
  const f = fixture();
  let posts = 0, polls = 0;
  f.rest.actions.createWorkflowDispatch = async () => {posts++; return {data: {workflow_run_id: 5}};};
  f.rest.actions.getWorkflowRun = async () => {
    polls++;
    if (polls === 3) throw Object.assign(new Error('Service unavailable'), {status: 503});
    return {data: {...dispatchedRun(), status: polls < 4 ? 'in_progress' : 'completed'}};
  };
  assert.equal((await f.service.dispatch('child.yml', {}, 'factory')).id, 5);
  assert.equal(posts, 1);
  assert.equal(polls, 4);
});

for (const status of [401, 403, 404, 422]) {
  test(`ordinary HTTP ${status} reads are not retried`, async () => {
    const f = fixture();
    let reads = 0;
    await assert.rejects(f.service.read(async () => {reads++; throw Object.assign(new Error('denied'), {status});}), /denied/);
    assert.equal(reads, 1);
  });
}

for (const error of [Object.assign(new Error('reset'), {code: 'ECONNRESET'}), Object.assign(new Error('throttled'), {status: 429, response: {headers: {'retry-after': '2'}}})]) {
  test(`read retry recovers from ${error.message} with a three-attempt cap`, async () => {
    const f = fixture();
    let reads = 0;
    assert.equal(await f.service.read(async () => {if (++reads < 3) throw error; return 'ok';}), 'ok');
    reads = 0;
    await assert.rejects(f.service.read(async () => {reads++; throw error;}));
    assert.equal(reads, 3);
  });
}

test('read retry cannot extend the absolute polling deadline', async () => {
  const f = fixture();
  f.service.now = () => 0;
  await assert.rejects(f.service.read(async () => {throw Object.assign(new Error('down'), {status: 503});}, 500), /deadline exceeded/);
});

test('a missing dispatch run ID never causes a second POST or title search', async () => {
  const f = fixture();
  let posts = 0;
  f.rest.actions.createWorkflowDispatch = async () => {posts++; return {status: 204, data: {}};};
  await assert.rejects(f.service.dispatch('child.yml', {}, 'factory'), /no run ID/);
  assert.equal(posts, 1);
});

test('polling an unfinished returned run stays bounded', async () => {
  const f = fixture();
  let polls = 0;
  f.rest.actions.createWorkflowDispatch = async () => ({data: {workflow_run_id: 5}});
  f.rest.actions.getWorkflowRun = async () => {polls++; return {data: {...dispatchedRun(), status: 'in_progress'}};};
  await assert.rejects(f.service.dispatch('child.yml', {}, 'factory'), /timed out/);
  assert.equal(polls, 720);
});

test('accepted manifest size is bounded even with an injected transport', async () => {
  const f = fixture();
  f.service.download = async () => Buffer.alloc(5 * 1024 * 1024 + 1);
  await assert.rejects(f.service.accepted('a'.repeat(64)), /exceeds size limit/);
});

for (const uploaded of [0, 1, 2, 3, 4]) {
  test(`same-run recovery handles failure after ${uploaded} successful uploads without another draft or overwrite`, async () => temporary(async directory => {
    const f = fixture();
    const upload = f.rest.repos.uploadReleaseAsset;
    let calls = 0;
    f.rest.repos.uploadReleaseAsset = async options => {
      if (uploaded === 0) throw new Error('connection lost');
      const result = await upload(options);
      if (++calls === uploaded) throw new Error('connection lost');
      return result;
    };
    await assert.rejects(draft(f, directory), /connection lost/);
    assert.equal(f.release.assets.length, uploaded);
    assert.match(f.release.body, /Build run: https:\/\/github.com\/owner\/repo\/actions\/runs\/42/);
    if (uploaded > 0) assert.equal(f.release.assets[0].name, 'installer-provenance.json');
    f.rest.repos.uploadReleaseAsset = upload;
    f.service.context.runAttempt = 2;
    await f.service.preflightVersion('040.002.003', {sameRun: true});
    const receipt = await f.service.draft(directory);
    assert.equal(receipt.release_id, f.release.id);
    assert.equal(f.writes.filter(([operation]) => operation === 'create').length, 1);
    assert.equal(f.writes.filter(([operation]) => operation === 'upload').length, 4);
  }));
}

for (const state of ['empty', 'executable only', 'missing ownership', 'wrong source', 'conflicting bytes']) {
  test(`partial draft resume refuses ${state === 'empty' || state === 'executable only' ? "another run's " : ''}${state}`, async () => temporary(async directory => {
    const f = fixture();
    await draft(f, directory);
    if (state === 'empty') f.release.assets = [];
    if (state === 'executable only') f.release.assets = f.release.assets.filter(asset => asset.name === 'Ruby4Lich5.exe');
    if (state === 'missing ownership') f.release.body = '';
    if (state === 'wrong source') f.release.target_commitish = 'c'.repeat(40);
    if (state === 'conflicting bytes') {
      f.release.assets = f.release.assets.filter(asset => asset.name === 'Ruby4Lich5.exe');
      f.release.assets[0].digest = 'sha256:' + '0'.repeat(64);
    }
    if (state === 'empty' || state === 'executable only') f.service.context.runId = 43;
    const count = f.writes.length;
    if (state === 'conflicting bytes') {
      await f.service.preflightVersion('040.002.003', {sameRun: true});
      await assert.rejects(f.service.draft(directory), /conflicting assets/);
    } else {
      await assert.rejects(f.service.preflightVersion('040.002.003', {sameRun: true}), /ownership|another build|already exists/);
    }
    assert.equal(f.writes.length, count);
  }));
}

test('same-run recovery also accepts a retained executable-only draft with intact creation ownership', async () => temporary(async directory => {
  const f = fixture();
  await draft(f, directory);
  f.release.assets = f.release.assets.filter(asset => asset.name === 'Ruby4Lich5.exe');
  f.service.context.runAttempt = 2;
  await f.service.preflightVersion('040.002.003', {sameRun: true});
  await f.service.draft(directory);
  assert.equal(f.release.assets.length, 4);
}));

for (const [group, name, invoke] of [
  ['repos', 'getCollaboratorPermissionLevel', f => f.service.admin('admin')],
  ['repos', 'getEnvironment', f => f.service.environment('r4l5-installer-latest')],
  ['actions', 'getReviewsForRun', f => f.service.approval('r4l5-installer-latest')],
  ['git', 'getRef', f => f.service.tagSource('R4L5-v040.002.003')],
  ['repos', 'getCommit', f => f.service.tagSource('R4L5-v040.002.003')],
  ['repos', 'getReleaseAsset', f => f.service.assetBytes(f.release, 'installer-provenance.json')],
  ['repos', 'getLatestRelease', (f, receipt) => f.service.publish(receipt)]
]) {
  test(`GET ${name} recovers from a transient failure without repeating a write`, async () => temporary(async directory => {
    const f = fixture();
    const receipt = await draft(f, directory);
    const operation = f.rest[group][name];
    let calls = 0;
    f.rest[group][name] = async options => {
      if (++calls === 1) throw Object.assign(new Error('Service unavailable'), {status: 503});
      return operation(options);
    };
    await invoke(f, receipt);
    assert.ok(calls >= 2);
    assert.equal(f.writes.filter(([kind]) => kind === 'publish').length, name === 'getLatestRelease' ? 1 : 0);
    assert.equal(f.writes.filter(([kind]) => kind === 'create').length, 1);
  }));
}

test('authenticated user GET retries before factory dispatch', async () => temporary(async () => {
  const f = fixture();
  const original = f.rest.users.getAuthenticated;
  let reads = 0;
  f.rest.users.getAuthenticated = async () => {
    if (++reads === 1) throw Object.assign(new Error('Service unavailable'), {status: 503});
    return original();
  };
  let dispatches = 0;
  f.service.dispatch = async () => {dispatches++; throw new Error('stopped at factory');};
  await assert.rejects(f.service.prepare({'lich5-commit': sha, 'installer-version': '040.002.003'}), /stopped at factory/);
  assert.equal(reads, 2);
  assert.equal(dispatches, 1);
}));

for (const [headers, expectedDelay, message] of [
  [{'retry-after': '75', 'x-ratelimit-remaining': '4999'}, 75000, 'secondary rate limit'],
  [{'x-ratelimit-remaining': '0', 'x-ratelimit-reset': '90'}, 90000, 'primary rate limit'],
  [{}, 60000, 'You have exceeded a secondary rate limit']
]) {
  test(`rate-limited GET honors ${expectedDelay}ms without shortening the server wait`, async () => {
    const f = fixture();
    f.service.now = () => 0;
    const waits = [];
    f.service.sleep = async delay => {waits.push(delay);};
    let reads = 0;
    const value = await f.service.read(async () => {
      if (++reads === 1) throw Object.assign(new Error(message), {status: 403, response: {headers}});
      return 'ok';
    });
    assert.equal(value, 'ok');
    assert.deepEqual(waits, [expectedDelay]);
  });
}

test('a rate-limit delay outside the operation budget stops without an early retry', async () => {
  const f = fixture();
  f.service.now = () => 0;
  let reads = 0;
  const waits = [];
  f.service.sleep = async delay => {waits.push(delay);};
  await assert.rejects(f.service.read(async () => {
    reads++;
    throw Object.assign(new Error('secondary rate limit'), {status: 403, response: {headers: {'retry-after': '75'}}});
  }, 60000), /deadline exceeded/);
  assert.equal(reads, 1);
  assert.deepEqual(waits, []);
});

test('public manifest GET retries transient transport failure before checking integrity', async () => {
  const f = fixture();
  const download = f.service.download;
  let reads = 0;
  f.service.download = async (...args) => {
    if (++reads === 1) throw Object.assign(new Error('Service unavailable'), {status: 503});
    return download(...args);
  };
  await f.service.accepted(f.provenance.recovery_manifest_sha256);
  assert.equal(reads, 2);
});

test('integrity failures are not retried as transport errors', async () => {
  const f = fixture();
  let reads = 0;
  f.service.download = async () => {reads++; return Buffer.from('wrong manifest');};
  await assert.rejects(f.service.accepted(f.provenance.recovery_manifest_sha256), /Accepted recovery changed/);
  assert.equal(reads, 1);
});

test('an existing tag with an unreadable commit is never treated as an absent draft tag', async () => {
  const f = fixture();
  f.rest.repos.getCommit = async () => {throw Object.assign(new Error('commit not found'), {status: 404});};
  await assert.rejects(f.service.tagSource('R4L5-v040.002.003', true), /commit not found/);
});

for (const target of ['listing', 'archive GET', 'redirected archive GET']) {
  test(`artifact ${target} retries only failed GETs and retains archive verification`, async () => temporary(async () => {
    const f = fixture();
    fs.writeFileSync('promotion-plan.json', '{"schema":1}');
    execFileSync('zip', ['-q', 'artifact.zip', 'promotion-plan.json']);
    const bytes = fs.readFileSync('artifact.zip');
    const artifact = {id: 10, name: 'preparation', expired: false, digest: `sha256:${digest(bytes)}`, workflow_run: {id: 5, head_sha: sha}};
    let attempts = 0;
    const failOnce = () => {
      if (++attempts === 1) throw Object.assign(new Error('Service unavailable'), {status: 503});
    };
    f.rest.actions.listWorkflowRunArtifacts = async () => {
      if (target === 'listing') failOnce();
      return {data: [artifact]};
    };
    f.rest.actions.downloadArtifact = async () => {
      if (target === 'archive GET') failOnce();
      return target === 'redirected archive GET' ? {headers: {location: 'https://example.test/archive'}} : {headers: {}, data: stream(bytes)};
    };
    f.service.download = async url => {
      assert.equal(url, 'https://example.test/archive');
      failOnce();
      return bytes;
    };
    const document = await f.service.artifactFile({id: 5}, 'preparation', 'promotion-plan.json');
    assert.equal(document.toString(), '{"schema":1}');
    assert.equal(attempts, 2);
    assert.deepEqual(f.writes, []);
  }));
}

test('redirected draft asset GET is retried without retrying the upload or weakening the digest', async () => temporary(async directory => {
  const f = fixture();
  await draft(f, directory);
  const before = f.writes.length;
  f.rest.repos.getReleaseAsset = async () => ({headers: {location: 'https://example.test/provenance'}});
  let downloads = 0;
  f.service.download = async url => {
    assert.equal(url, 'https://example.test/provenance');
    if (++downloads === 1) throw Object.assign(new Error('socket reset'), {code: 'ECONNRESET'});
    return f.files['installer-provenance.json'];
  };
  assert.deepEqual(await f.service.assetBytes(f.release, 'installer-provenance.json'), f.files['installer-provenance.json']);
  assert.equal(downloads, 2);
  assert.equal(f.writes.length, before);
}));

test('draft ownership cannot substitute a duplicated run or source marker', async () => temporary(async directory => {
  const f = fixture();
  await draft(f, directory);
  f.release.assets = [];
  f.release.body += '\nBuild run: https://github.com/owner/repo/actions/runs/43';
  await assert.rejects(f.service.preflightVersion('040.002.003', {sameRun: true}), /ownership/);
}));

for (const state of ['absent', 'matching', 'conflicting', 'unreadable']) {
  test(`version preflight handles a ${state} bare tag before native work`, async () => {
    const f = fixture();
    let tagReads = 0, releaseReads = 0;
    f.rest.git.getRef = async () => {
      tagReads++;
      if (state === 'absent') throw Object.assign(new Error('missing'), {status: 404});
      if (state === 'unreadable') throw Object.assign(new Error('denied'), {status: 403});
      return {data: {object: {sha}}};
    };
    f.rest.repos.getCommit = async () => ({data: {sha: state === 'conflicting' ? 'c'.repeat(40) : sha}});
    f.rest.repos.listReleases = async () => {releaseReads++; return {data: []};};
    if (state === 'conflicting' || state === 'unreadable') {
      await assert.rejects(f.service.preflightVersion('040.002.003'), /another source|denied/);
      assert.equal(releaseReads, 0);
    } else await f.service.preflightVersion('040.002.003');
    assert.equal(tagReads, 1);
    assert.deepEqual(f.writes, []);
  });
}

test('coordinator rejects a conflicting bare tag before dispatching the factory', async () => {
  const f = fixture();
  f.rest.repos.getCommit = async () => ({data: {sha: 'c'.repeat(40)}});
  f.service.dispatch = () => {throw new Error('must not dispatch');};
  await assert.rejects(f.service.prepare({'lich5-commit': sha, 'installer-version': '040.002.003'}), /another source/);
});

for (const [hint, delay] of [
  ['Mon, 02 Nov 2026 12:02:00 GMT', 120000],
  ['Mon, 02 Nov 2026 11:59:00 GMT', 1000],
  ['invalid-date', 60000],
  ['75', 75000]
]) {
  test(`Retry-After ${hint} respects HTTP date/seconds and the injected clock`, async () => {
    const f = fixture();
    f.service.now = () => Date.UTC(2026, 10, 2, 12);
    const waits = [];
    f.service.sleep = async ms => waits.push(ms);
    let calls = 0;
    await f.service.read(async () => {
      if (++calls === 1) throw Object.assign(new Error('secondary rate limit'), {status: 403, response: {headers: {'retry-after': hint}}});
      return 'ok';
    });
    assert.deepEqual(waits, [delay]);
  });
}

test('HTTP-date outside the read budget stops without a premature retry', async () => {
  const f = fixture();
  const now = Date.UTC(2026, 10, 2, 12);
  f.service.now = () => now;
  let calls = 0;
  await assert.rejects(f.service.read(async () => {
    calls++;
    throw Object.assign(new Error('secondary rate limit'), {status: 403, response: {headers: {'retry-after': 'Mon, 02 Nov 2026 12:02:00 GMT'}}});
  }, now + 60000), /deadline exceeded/);
  assert.equal(calls, 1);
});

for (const match of [true, false]) {
  test(`draft contract check ${match ? 'accepts a later matching target' : 'rejects when neither target matches'}`, async () => temporary(async directory => {
    const other = {schema: 2, promotable: true, overrides: {}, lich5_commit: 'c'.repeat(40)};
    const f = fixture({otherContracts: match ? [other] : [other, other], includeInstaller: match});
    if (match) await draft(f, directory);
    else {
      await assert.rejects(draft(f, directory), /Accepted contract differs from installer/);
      assert.deepEqual(f.writes, []);
      assert.equal(fs.existsSync('installer-release-receipt.json'), false);
    }
  }));
}

test('authenticated direct 200 requests disable parsing and stream below the cap', async () => {
  const f = fixture();
  let request;
  const bytes = await f.service.apiBytes(async options => {
    request = options.request;
    return {status: 200, headers: {}, data: stream(Buffer.from('bytes'))};
  }, {}, 5, 5);
  assert.equal(bytes.toString(), 'bytes');
  assert.equal(request.parseSuccessResponseBody, false);
  assert.equal(request.redirect, 'manual');
  assert.ok(request.signal instanceof AbortSignal);
});

test('oversized direct 200 streams cancel before consuming their remainder', async () => {
  const f = fixture();
  let pulls = 0, cancelled = false;
  const body = new ReadableStream({pull(controller) {pulls++; controller.enqueue(Buffer.alloc(4));}, cancel() {cancelled = true;}}, {highWaterMark: 0});
  await assert.rejects(f.service.apiBytes(async () => ({status: 200, headers: {}, data: body}), {}, 5), /exceeds size limit/);
  assert.equal(pulls, 2);
  assert.equal(cancelled, true);
});

test('oversized advertised binary metadata stops before issuing an authenticated GET', async () => {
  const f = fixture();
  let gets = 0;
  await assert.rejects(f.service.apiBytes(async () => {gets++;}, {}, 5, 6), /exceeds size limit/);
  assert.equal(gets, 0);
});

test('publication records post-write deadline exhaustion and never retries the write', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  let now = 0, published = false;
  f.service.now = () => now;
  const update = f.rest.repos.updateRelease;
  f.rest.repos.updateRelease = async options => {const result = await update(options); published = true; return result;};
  for (const name of ['getRelease', 'getReleaseAsset', 'getLatestRelease']) {
    const operation = f.rest.repos[name];
    f.rest.repos[name] = async options => {if (published) now += 179000; return operation(options);};
  }
  await assert.rejects(f.service.publish(receipt), /deadline exceeded/);
  const status = JSON.parse(fs.readFileSync('publication-status.json'));
  assert.equal(status.state, 'published-unverified');
  assert.equal(status.published, true);
  assert.equal(status.latest_verified, false);
  assert.equal(f.writes.filter(([kind]) => kind === 'publish').length, 1);
  assert.ok(now < 20 * 60 * 1000);
}));

test('publication deadline exhaustion before the write leaves the draft unpublished', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  let now = 0;
  f.service.now = () => now;
  const read = f.rest.repos.getReleaseAsset;
  f.rest.repos.getReleaseAsset = async options => {now += 179000; return read(options);};
  const ref = f.rest.git.getRef;
  const commit = f.rest.repos.getCommit;
  f.rest.git.getRef = async options => {now += 179000; return ref(options);};
  f.rest.repos.getCommit = async options => {now += 179000; return commit(options);};
  await assert.rejects(f.service.publish(receipt), /deadline exceeded/);
  const status = JSON.parse(fs.readFileSync('publication-status.json'));
  assert.equal(status.state, 'not-published');
  assert.equal(status.publication_attempted, false);
  assert.equal(f.release.draft, true);
}));

test('a lost write response is recorded as publication uncertainty without an automatic retry', async () => temporary(async directory => {
  const f = fixture();
  const receipt = await draft(f, directory);
  let writes = 0;
  f.rest.repos.updateRelease = async () => {writes++; throw Object.assign(new Error('connection reset after sending'), {code: 'ECONNRESET'});};
  await assert.rejects(f.service.publish(receipt), /connection reset/);
  const status = JSON.parse(fs.readFileSync('publication-status.json'));
  assert.equal(status.state, 'publication-uncertain');
  assert.equal(status.published, null);
  assert.equal(status.latest_verified, false);
  assert.equal(writes, 1);
}));

test('expired publication budget cancels an in-flight metadata GET', async () => {
  const f = fixture();
  f.service.operationDeadline = f.service.now() + 25;
  let aborted = false;
  const keepAlive = setTimeout(() => {}, 1000);
  try {
    await assert.rejects(f.service.read(signal => new Promise((_resolve, reject) => {
      signal.addEventListener('abort', () => {aborted = true; reject(signal.reason);}, {once: true});
    })), /timeout|deadline/i);
    assert.equal(aborted, true);
  } finally {clearTimeout(keepAlive);}
});
