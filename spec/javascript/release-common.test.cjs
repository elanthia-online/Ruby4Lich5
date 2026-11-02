'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {canonical, oneAsset, downloadBytes} = require('../../.github/scripts/release-common.cjs');

test('canonical contract numbers refuse values whose Ruby representation can diverge', () => {
  for (const value of [1.5, 2 ** 60, NaN, Infinity, -0]) assert.throws(() => canonical({value}), /safe integers/);
  assert.throws(() => canonical({value: undefined}), /Unsupported contract JSON/);
  assert.equal(canonical({z: null, a: [1, 'string', false]}), '{"a":[1,"string",false],"z":null}');
});

test('shared asset selection rejects missing, duplicate and unhashed assets', () => {
  const asset = {name: 'installer-provenance.json', digest: 'sha256:' + 'a'.repeat(64)};
  class Missing extends Error {}
  assert.throws(() => oneAsset({assets: []}, asset.name, Missing), Missing);
  assert.throws(() => oneAsset({assets: [asset, asset]}, asset.name), /exactly one/);
  assert.throws(() => oneAsset({assets: [{name: asset.name}]}, asset.name), /malformed digest/);
  assert.equal(oneAsset({assets: [asset]}, asset.name), asset);
});

test('redirects are manual and reject insecure or credential-bearing intermediate destinations', async () => {
  for (const destination of ['http://example.test/unsafe', 'https://user:password@example.test/unsafe']) {
    let calls = 0;
    const fetcher = async (_url, options) => {
      calls++;
      assert.equal(options.redirect, 'manual');
      assert.ok(options.signal);
      return {status: 302, headers: {get: () => destination}, body: {cancel: async () => {}}};
    };
    await assert.rejects(downloadBytes('https://example.test/start', {fetcher}), /Unsafe asset redirect/);
    assert.equal(calls, 1);
  }
});

test('streaming caps stop an oversized response without buffering the remainder', async () => {
  let chunks = 0;
  const fetcher = async () => ({ok: true, status: 200, body: (async function* () {
    chunks++; yield Buffer.alloc(4);
    chunks++; yield Buffer.alloc(4);
    chunks++; yield Buffer.alloc(4);
  })()});
  await assert.rejects(downloadBytes('https://example.test/document', {fetcher, maxBytes: 5}), /exceeds size limit/);
  assert.equal(chunks, 2);
});

test('redirect hops share the time bound and retain no authenticated headers', async () => {
  let calls = 0, signal;
  const fetcher = async (_url, options) => {
    assert.equal(options.headers, undefined);
    if (signal) assert.equal(options.signal, signal);
    signal = options.signal;
    if (++calls === 1) return {status: 302, headers: {get: () => '/asset'}, body: {cancel: async () => {}}};
    return {status: 200, ok: true, body: (async function* () {yield Buffer.from('bytes');})()};
  };
  assert.equal((await downloadBytes('https://example.test/start', {fetcher})).toString(), 'bytes');
  assert.equal(calls, 2);
});

test('redirect loops and unsuccessful responses fail without repeating writes', async () => {
  const fetcher = async () => ({status: 302, headers: {get: () => '/loop'}, body: {cancel: async () => {}}});
  await assert.rejects(downloadBytes('https://example.test/start', {fetcher}), /Too many redirects/);
  await assert.rejects(downloadBytes('https://example.test/start', {fetcher: async () => ({ok: false, status: 503})}), /HTTP 503/);
});
