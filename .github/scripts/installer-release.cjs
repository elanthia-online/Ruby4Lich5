'use strict';

// Release jobs only handle bytes. Never execute the downloaded installer or gems.
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const os = require('node:os');

const FILES = ['installer-provenance.json', 'Ruby4Lich5.exe', 'gem-build-metadata.json', 'resolution-lock.json'];
const {HEX, SHA, DOCUMENT_LIMIT, BINARY_LIMIT, ARCHIVE_LIMIT, digest, canonical, oneAsset, downloadBytes} = require('./release-common.cjs');
const VERSION = /^\d{3}\.\d{3}\.\d{3}$/;
function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}
function json(bytes) {
  return JSON.parse(Buffer.from(bytes).toString('utf8').replace(/^\uFEFF/, ''));
}

class InstallerRelease {
  /** Construct clients; injected transport and clock allow offline state-machine tests. */
  constructor({github, context, core, sleep, download, now = Date.now}) {
    this.github = github;
    this.context = Object.assign(Object.create(context), {
      runAttempt: Number(context.runAttempt || process.env.GITHUB_RUN_ATTEMPT)
    });
    this.core = core;
    this.repo = context.repo;
    this.sleep = sleep || (ms => new Promise(resolve => setTimeout(resolve, ms)));
    this.download = download || downloadBytes;
    this.now = now;
  }

  /** Require current administrator permission using repository metadata reads. */
  async admin(username) {
    const {data} = await this.read(() => this.github.rest.repos.getCollaboratorPermissionLevel({...this.repo, username}));
    requireValue(data.permission === 'admin', `${username} must be a repository administrator`);
  }

  /** Verify explicit administrator reviewer rules without creating or editing settings. */
  async environment(name) {
    const {data} = await this.read(() => this.github.rest.repos.getEnvironment({...this.repo, environment_name: name}));
    const rules = (data.protection_rules || []).filter(rule => rule.type === 'required_reviewers');
    requireValue(rules.length === 1 && rules[0].reviewers?.length > 0, `${name} requires configured administrator reviewers`);
    for (const entry of rules[0].reviewers) {
      requireValue(entry.type === 'User' && entry.reviewer?.login, `${name} must name administrator users explicitly`);
      await this.admin(entry.reviewer.login);
    }
    return data;
  }

  /** Require a recorded approval for this exact environment in the initiating run. */
  async approval(name) {
    requireValue(this.context.runAttempt === 1, 'Start a fresh release request instead of rerunning an approval job');
    const environment = await this.environment(name);
    const {data} = await this.read(() => this.github.rest.actions.getReviewsForRun({...this.repo, run_id: this.context.runId}));
    const approvals = data.filter(review => review.state === 'approved' &&
      review.environments?.some(item => item.id === environment.id));
    requireValue(approvals.length > 0, `No explicit approval recorded for ${name}`);
    for (const review of approvals) await this.admin(review.user.login);
  }

  /** Check the initiating event/ref; pinned draft and publish jobs tolerate a newer main. */
  defaultDispatch() {
    const branch = this.context.payload.repository.default_branch;
    requireValue(this.context.eventName === 'workflow_dispatch' && this.context.ref === `refs/heads/${branch}`, 'Release automation requires a default-branch dispatch');
    return branch;
  }

  /** Retry transient GET failures only, within both attempt and caller time bounds. */
  async read(operation, deadline = this.now() + 180000) {
    for (let attempt = 0; attempt < 3; attempt++) {
      requireValue(this.now() < deadline, 'Read deadline exceeded');
      try {
        return await operation();
      } catch (error) {
        const status = error.status;
        const headers = error.response?.headers || {};
        const limited = status === 429 || (status === 403 &&
          (headers['x-ratelimit-remaining'] === '0' || headers['retry-after'] !== undefined || /secondary rate limit/i.test(error.message)));
        const transient = status >= 500 || limited ||
          ['ECONNRESET', 'ETIMEDOUT', 'EAI_AGAIN', 'ENETUNREACH'].includes(error.code || error.cause?.code) ||
          ['AbortError', 'TimeoutError'].includes(error.name) || error.message === 'fetch failed';
        if (!transient || attempt === 2) throw error;
        const retryAfter = headers['retry-after'] === undefined ? NaN : Number(headers['retry-after']);
        const reset = headers['x-ratelimit-remaining'] === '0' ? Number(headers['x-ratelimit-reset']) * 1000 : NaN;
        let delay = 1000 * 2 ** attempt;
        if (Number.isFinite(retryAfter) && retryAfter >= 0) delay = Math.max(delay, retryAfter * 1000);
        if (Number.isFinite(reset)) delay = Math.max(delay, reset - this.now());
        if (limited && !Number.isFinite(retryAfter) && !Number.isFinite(reset)) delay = Math.max(delay, 60000);
        requireValue(this.now() + delay < deadline, 'Read deadline exceeded');
        await this.sleep(delay);
      }
    }
  }

  /** Retry only the GET transport, never integrity checks or a surrounding write operation. */
  async downloadRead(url, options) {
    return this.read(() => this.download(url, options));
  }

  /** Recheck the default tip only before dispatch, which otherwise selects newer tooling. */
  async defaultHead() {
    const branch = this.defaultDispatch();
    const {data} = await this.read(() => this.github.rest.repos.getBranch({...this.repo, branch}));
    requireValue(data.commit.sha === this.context.sha, 'Default branch moved; start a fresh release request');
    return branch;
  }

  /** Dispatch once with the pinned API; poll its returned run ID using the admin credential. */
  async dispatch(workflow, inputs, phase) {
    const branch = await this.defaultHead();
    const request = `r4l5-release-${this.context.runId}-${this.context.runAttempt}-${phase}`;
    const response = await this.github.rest.actions.createWorkflowDispatch({...this.repo, workflow_id: workflow, ref: branch,
      headers: {'X-GitHub-Api-Version': '2026-03-10'}, inputs: {...inputs, 'release-request': request}});
    const id = response.data?.workflow_run_id;
    requireValue(Number.isSafeInteger(id) && id > 0, 'Dispatch returned no run ID; inspect existing runs before retrying');
    const url = `https://github.com/${this.repo.owner}/${this.repo.repo}/actions/runs/${id}`;
    await this.core.summary.addLink(`${phase} started: ${id}`, url).addEOL().write();
    const deadline = this.now() + 180 * 60 * 1000;
    // The POST is never retried. Read retries cannot extend this deadline.
    for (let count = 0; count < 720 && this.now() < deadline; count++) {
      const {data: run} = await this.read(() => this.github.rest.actions.getWorkflowRun({...this.repo, run_id: id}), deadline);
      requireValue(run.id === id && run.head_sha === this.context.sha && run.event === 'workflow_dispatch' &&
        run.path === `.github/workflows/${workflow}` && run.repository.full_name === `${this.repo.owner}/${this.repo.repo}` &&
        run.head_repository.full_name === run.repository.full_name && run.run_attempt === 1,
      'Dispatched workflow identity or attempt changed');
      if (run.status === 'completed') {
        requireValue(run.conclusion === 'success', `${phase} failed: ${url}`);
        await this.core.summary.addLink(`${phase}: ${id}`, url).addEOL().write();
        return run;
      }
      await this.sleep(Math.min(15000, Math.max(0, deadline - this.now())));
    }
    throw new Error(`${phase} timed out: ${url}; inspect before starting another request`);
  }

  /** Read and hash-check the completed child artifact; extract one document without executing it. */
  async artifactFile(run, name, filename) {
    const artifacts = await this.read(() => this.github.paginate(this.github.rest.actions.listWorkflowRunArtifacts, {
      ...this.repo, run_id: run.id, per_page: 100
    }));
    const matches = artifacts.filter(item => item.name === name && !item.expired);
    requireValue(matches.length === 1 && /^sha256:[0-9a-f]{64}$/.test(matches[0].digest || ''), 'Expected one checksummed run artifact');
    const artifact = matches[0];
    requireValue(artifact.workflow_run?.head_sha === this.context.sha && artifact.workflow_run.id === run.id, 'Artifact source changed');
    const response = await this.read(() => this.github.rest.actions.downloadArtifact({...this.repo, artifact_id: artifact.id, archive_format: 'zip', request: {redirect: 'manual'}}));
    const bytes = response.headers.location ? await this.downloadRead(response.headers.location, {maxBytes: ARCHIVE_LIMIT}) : Buffer.from(response.data);
    requireValue(bytes.length <= ARCHIVE_LIMIT, 'Artifact exceeds size limit');
    requireValue(`sha256:${digest(bytes)}` === artifact.digest, 'Artifact archive digest mismatch');
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'r4l5-release-'));
    try {
      const archive = path.join(directory, 'artifact.zip');
      fs.writeFileSync(archive, bytes);
      const entries = execFileSync('unzip', ['-Z1', archive], {encoding: 'utf8', maxBuffer: 1024 * 1024}).trim().split('\n');
      requireValue(entries.filter(entry => entry === filename).length === 1, 'Missing or duplicate artifact document');
      return execFileSync('unzip', ['-p', archive, filename], {maxBuffer: 10 * 1024 * 1024});
    } finally {
      fs.rmSync(directory, {recursive: true, force: true});
    }
  }

  /** Use the administrator dispatch credential to build and retain the exact inspection report. */
  async prepare(inputs) {
    requireValue(SHA.test(inputs['lich5-commit']) && VERSION.test(inputs['installer-version']), 'Supply a full Lich SHA and installer version NNN.NNN.NNN');
    requireValue(Number(this.context.runAttempt) === 1, 'Start a fresh release request instead of rerunning the coordinator');
    await this.environment('r4l5-recovery-promotion');
    await this.environment('r4l5-installer-latest');
    const {data: user} = await this.read(() => this.github.rest.users.getAuthenticated());
    await this.admin(user.login);
    await this.preflightVersion(inputs['installer-version']);
    const factory = await this.dispatch('ruby4-bundled-gems-suite.yml', {
      'lich5-commit': inputs['lich5-commit'], publish: 'true'
    }, 'factory');
    const tag = `R4L5-gem-bundle-x64-mingw-ucrt-candidate-${factory.id}-${factory.run_attempt}`;
    const inspection = await this.dispatch('promote-gem-candidate.yml', {mode: 'inspect', 'candidate-tag': tag}, 'inspect');
    const bytes = await this.artifactFile(inspection, 'gem-promotion-preparation', 'promotion-plan.json');
    const plan = json(bytes);
    requireValue(plan.candidate_tag === tag && plan.source_sha === this.context.sha &&
      ['candidate_sha256', 'live_sha256', 'change_sha256'].every(key => /^sha256:[0-9a-f]{64}$/.test(plan[key])), 'Invalid inspection identity');
    const request = {schema: 1, tag, plan, factory_run: factory.id, inspection_run: inspection.id,
      installer_version: inputs['installer-version'], source_sha: this.context.sha};
    fs.writeFileSync('release-request.json', JSON.stringify(request, null, 2) + '\n');
    await this.core.summary.addHeading('Recovery promotion approval').addCodeBlock(JSON.stringify(plan, null, 2), 'json')
      .addRaw('Review the complete inspected changes and recovery evidence before approving r4l5-recovery-promotion.').write();
  }

  /** After recovery approval, dispatch normal promotion and installer draft assembly. */
  async promote(request) {
    requireValue(request.source_sha === this.context.sha, 'Request source changed');
    await this.approval('r4l5-recovery-promotion');
    await this.dispatch('promote-gem-candidate.yml', {mode: 'promote', 'candidate-tag': request.tag,
      'candidate-sha256': request.plan.candidate_sha256, 'live-sha256': request.plan.live_sha256,
      'change-sha256': request.plan.change_sha256}, 'promote');
    const installer = await this.dispatch('build-ruby4lich5-installer.yaml', {'gem-source': 'accepted-candidate',
      'gem-candidate-tag': request.tag, 'installer-version': request.installer_version}, 'installer');
    const receipt = json(await this.artifactFile(installer, 'installer-release-receipt', 'installer-release-receipt.json'));
    requireValue(receipt.tag === `R4L5-v${request.installer_version}` && receipt.source_sha === this.context.sha &&
      receipt.installer_run_id === installer.id,
      'Installer draft receipt differs from request');
    fs.writeFileSync('installer-release-receipt.json', JSON.stringify(receipt, null, 2) + '\n');
    await this.core.summary.addHeading('Installer acceptance required').addLink(receipt.tag, receipt.url).addEOL()
      .addRaw('Test installation and restart with the currently published Lich. Approve r4l5-installer-latest only after acceptance; approval publishes these exact bytes as Latest.').write();
  }

  /** Discover both drafts and published releases with write-visible credentials; reject ambiguity. */
  async releaseByTag(tag) {
    const releases = await this.read(() => this.github.paginate(this.github.rest.repos.listReleases, {...this.repo, per_page: 100}));
    const matches = releases.filter(release => release.tag_name === tag);
    requireValue(matches.length <= 1, 'Multiple releases have this version; inspect before continuing');
    return matches[0] || null;
  }

  /** Read the exact release ID; never substitute another draft bearing the same tag. */
  async releaseById(id, tag) {
    const {data} = await this.read(() => this.github.rest.repos.getRelease({...this.repo, release_id: id}));
    requireValue(data.id === id && data.tag_name === tag, 'Release identity changed after acceptance');
    return data;
  }

  /** Fail version collisions before native work; only the same build run may resume its own draft. */
  async preflightVersion(version, {sameRun = false} = {}) {
    requireValue(VERSION.test(version), 'Supply an explicit installer version NNN.NNN.NNN');
    if (this.context.ref !== `refs/heads/${this.context.payload.repository.default_branch}`) return;
    const release = await this.releaseByTag(`R4L5-v${version}`);
    if (!release) return;
    if (sameRun && release.draft && release.target_commitish === this.context.sha) {
      this.requireDraftOwner(release);
      const names = release.assets.map(asset => asset.name);
      requireValue(new Set(names).size === names.length && names.every(name => FILES.includes(name)), 'Draft has unexpected assets');
      if (names.includes('installer-provenance.json')) {
        const provenance = json(await this.assetBytes(release, 'installer-provenance.json'));
        requireValue(String(provenance.installer_run_id) === String(this.context.runId) &&
          provenance.installer_source_sha === this.context.sha, 'Installer version belongs to another build');
      }
      return;
    }
    throw new Error('Installer version already exists; inspect it and choose a new version');
  }

  /** Record human-readable source/run ownership atomically with draft creation. */
  draftBody() {
    return 'Installer awaiting administrator installation and restart acceptance.\n\nSource: ' + this.context.sha +
      `\nBuild run: https://github.com/${this.repo.owner}/${this.repo.repo}/actions/runs/${this.context.runId}`;
  }

  /** Refuse another run's incomplete draft even when its source commit is identical. */
  requireDraftOwner(release) {
    const lines = (release.body || '').split(/\r?\n/);
    const source = `Source: ${this.context.sha}`;
    const run = `Build run: https://github.com/${this.repo.owner}/${this.repo.repo}/actions/runs/${this.context.runId}`;
    requireValue(release.target_commitish === this.context.sha &&
      lines.filter(line => line.startsWith('Source: ')).length === 1 && lines.includes(source) &&
      lines.filter(line => line.startsWith('Build run: ')).length === 1 && lines.includes(run),
    'Draft ownership is missing or belongs to another build; inspect before continuing');
  }

  /** Verify an existing tag resolves to the pinned source; drafts may not have a tag yet. */
  async tagSource(tag, allowMissing = false) {
    try {
      // Only a missing ref is optional; errors reading an existing tag's commit are not.
      await this.read(() => this.github.rest.git.getRef({...this.repo, ref: `tags/${tag}`}));
    } catch (error) {
      if (allowMissing && error.status === 404) return;
      throw error;
    }
    const {data} = await this.read(() => this.github.rest.repos.getCommit({...this.repo, ref: `refs/tags/${tag}`}));
    requireValue(data.sha === this.context.sha, 'Release tag points to another source commit');
  }

  /** Download one authenticated release asset, cap its bytes and verify the API digest. */
  async assetBytes(release, name) {
    const asset = oneAsset(release, name);
    const maxBytes = name.endsWith('.json') ? DOCUMENT_LIMIT : BINARY_LIMIT;
    const response = await this.read(() => this.github.rest.repos.getReleaseAsset({...this.repo, asset_id: asset.id,
      headers: {accept: 'application/octet-stream'}, request: {redirect: 'manual'}}));
    const bytes = response.headers.location ? await this.downloadRead(response.headers.location, {maxBytes}) : Buffer.from(response.data);
    requireValue(bytes.length <= maxBytes, 'Asset exceeds size limit');
    requireValue(`sha256:${digest(bytes)}` === asset.digest, `Downloaded ${name} digest mismatch`);
    return bytes;
  }

  /** Read the public accepted manifest with a document cap and exact expected digest. */
  async accepted(expected) {
    requireValue(HEX.test(expected), 'Invalid accepted manifest digest');
    const url = `https://github.com/${this.repo.owner}/${this.repo.repo}/releases/download/R4L5-gem-bundle-x64-mingw-ucrt/R4L5-gem-manifest.json`;
    const bytes = await this.downloadRead(url, {maxBytes: DOCUMENT_LIMIT});
    requireValue(bytes.length <= DOCUMENT_LIMIT, 'Accepted manifest exceeds size limit');
    requireValue(digest(bytes) === expected, 'Accepted recovery changed; inspect and rebuild before release');
    return json(bytes);
  }

  /** Check build/run, gem metadata, installer bytes and canonical runtime attestation. */
  validatePayload(files) {
    const provenance = json(files['installer-provenance.json']);
    const lock = json(files['resolution-lock.json']);
    const metadata = json(files['gem-build-metadata.json']);
    requireValue(VERSION.test(provenance.installer_version) && provenance.installer_source_sha === this.context.sha &&
      String(provenance.installer_run_id) === String(this.context.runId), 'Installer provenance source/run/version mismatch');
    requireValue(digest(files['Ruby4Lich5.exe']) === provenance.installer_sha256, 'Installer bytes differ from provenance');
    requireValue(lock.contract?.schema === 2 && lock.contract.promotable === true &&
      canonical(lock.contract.overrides) === '{}' &&
      digest(Buffer.from(canonical(lock.contract))) === provenance.runtime_contract_sha256, 'Runtime contract differs from provenance');
    requireValue(metadata.source_sha === provenance.gem_source_sha &&
      String(metadata.run_id) === String(provenance.gem_build_run_id) &&
      metadata.ruby_installer_version === provenance.ruby_installer_version, 'Gem metadata differs from provenance');
    requireValue(provenance.accepted_manifest_digest === `sha256:${provenance.recovery_manifest_sha256}`, 'Accepted manifest provenance mismatch');
    return provenance;
  }

  /** With the isolated write token, assemble and read back an unpublished verified release. */
  async draft(directory) {
    this.defaultDispatch();
    const files = {};
    for (const name of FILES) {
      const location = path.join(directory, name);
      requireValue(fs.lstatSync(location).isFile(), 'Release payload must contain regular files');
      files[name] = fs.readFileSync(location);
    }
    const provenance = this.validatePayload(files);
    const manifest = await this.accepted(provenance.recovery_manifest_sha256);
    requireValue(manifest.targets?.some(target => target.contract &&
      digest(Buffer.from(canonical(target.contract))) === provenance.runtime_contract_sha256), 'Accepted contract differs from installer');
    const tag = `R4L5-v${provenance.installer_version}`;
    const hashes = Object.fromEntries(FILES.map(name => [name, `sha256:${digest(files[name])}`]));
    await this.tagSource(tag, true);
    let release = await this.releaseByTag(tag);
    if (release) {
      requireValue(release.draft && !release.prerelease && release.target_commitish === this.context.sha, 'Release already published or has another source');
      this.requireDraftOwner(release);
      requireValue(release.assets.every(asset => hashes[asset.name] === asset.digest), 'Existing draft has conflicting assets; choose a new version');
    } else {
      release = (await this.github.rest.repos.createRelease({...this.repo, tag_name: tag,
        target_commitish: this.context.sha, name: `Ruby4Lich5 ${provenance.installer_version}`, draft: true,
        prerelease: false, make_latest: 'false', body: this.draftBody()})).data;
    }
    for (const name of FILES) {
      if (!release.assets.some(asset => asset.name === name)) {
        await this.github.rest.repos.uploadReleaseAsset({...this.repo, release_id: release.id, name,
          data: files[name], headers: {'content-type': 'application/octet-stream', 'content-length': files[name].length}});
      }
    }
    release = await this.releaseById(release.id, tag);
    await this.tagSource(tag, true);
    this.requireDraftOwner(release);
    await this.verifyAssets(release, hashes, true);
    const receipt = {schema: 1, tag, release_id: release.id, source_sha: this.context.sha,
      installer_run_id: this.context.runId, assets: hashes, recovery_manifest_sha256: provenance.recovery_manifest_sha256, url: release.html_url};
    fs.writeFileSync('installer-release-receipt.json', JSON.stringify(receipt, null, 2) + '\n');
    await this.core.summary.addHeading('Installer draft ready').addLink(tag, release.html_url).addEOL()
      .addRaw('This release remains a draft. Installation and restart acceptance plus explicit administrator approval are required before Latest.').write();
    return receipt;
  }

  /** Verify exact inventory, draft state and all expected asset bytes without executing them. */
  async verifyAssets(release, hashes, draft) {
    requireValue(release && release.draft === draft && !release.prerelease &&
      release.assets.length === FILES.length && FILES.every(name => HEX.test((hashes[name] || '').replace(/^sha256:/, ''))), 'Invalid release state or inventory');
    for (const name of FILES) {
      const bytes = await this.assetBytes(release, name);
      requireValue(`sha256:${digest(bytes)}` === hashes[name], 'Release bytes changed after build or approval');
    }
  }

  /** With the isolated write token, publish the explicitly approved receipt and verify public Latest. */
  async publish(receipt) {
    this.defaultDispatch();
    await this.approval('r4l5-installer-latest');
    requireValue(receipt.schema === 1 && receipt.source_sha === this.context.sha && /^R4L5-v\d{3}\.\d{3}\.\d{3}$/.test(receipt.tag), 'Invalid installer approval receipt');
    let release = await this.releaseById(receipt.release_id, receipt.tag);
    requireValue(release?.id === receipt.release_id && release.target_commitish === this.context.sha, 'Draft identity changed after acceptance');
    await this.tagSource(receipt.tag, true);
    await this.verifyAssets(release, receipt.assets, true);
    await this.accepted(receipt.recovery_manifest_sha256);
    // No automatic overwrite, rollback or retry after a publication failure.
    await this.github.rest.repos.updateRelease({...this.repo, release_id: release.id, draft: false, make_latest: 'true'});
    release = await this.releaseById(receipt.release_id, receipt.tag);
    await this.verifyAssets(release, receipt.assets, false);
    await this.tagSource(receipt.tag);
    const {data: latest} = await this.read(() => this.github.rest.repos.getLatestRelease(this.repo));
    requireValue(latest.id === release.id, 'Published release did not become Latest');
    await this.accepted(receipt.recovery_manifest_sha256);
    for (const name of ['Ruby4Lich5.exe', 'installer-provenance.json']) {
      const maxBytes = name.endsWith('.json') ? DOCUMENT_LIMIT : BINARY_LIMIT;
      const bytes = await this.downloadRead(`https://github.com/${this.repo.owner}/${this.repo.repo}/releases/latest/download/${name}`, {maxBytes});
      requireValue(bytes.length <= maxBytes, 'Latest asset exceeds size limit');
      requireValue(`sha256:${digest(bytes)}` === receipt.assets[name], 'Public Latest readback mismatch; hold release work');
    }
    fs.writeFileSync('publication-status.json', JSON.stringify({schema: 1, release_id: release.id,
      tag: receipt.tag, source_sha: this.context.sha, verified_at: new Date().toISOString(),
      recovery_manifest_sha256: receipt.recovery_manifest_sha256, assets: receipt.assets, latest_verified: true}, null, 2) + '\n');
    await this.core.summary.addHeading('Latest verified').addLink(receipt.tag, release.html_url).write();
  }
}

module.exports = {InstallerRelease, FILES, digest, canonical};
