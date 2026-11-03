'use strict';

const crypto = require('node:crypto');
const HEX = /^[0-9a-f]{64}$/;
const SHA = /^[0-9a-f]{40}$/;
const DOCUMENT_LIMIT = 5 * 1024 * 1024;
const BINARY_LIMIT = 1024 * 1024 * 1024;
const ARCHIVE_LIMIT = 2 * BINARY_LIMIT;

/** SHA-256 of original bytes, before JSON decoding or newline conversion. */
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

/**
 * Matches RuntimeGemContract.digest for the contract's supported JSON domain:
 * ASCII object keys, strings, booleans, null, arrays and safe integer numbers.
 * Float fields, unsafe integers and negative zero require a coordinated schema
 * change; JSON number formatting is not generally interchangeable with Ruby.
 */
function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') {
    const keys = Object.keys(value).sort();
    if (keys.some(key => !/^[\x00-\x7f]*$/.test(key))) throw new Error('Contract keys must be ASCII');
    return '{' + keys.map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  }
  if (typeof value === 'number' && (!Number.isSafeInteger(value) || Object.is(value, -0))) throw new Error('Contract numbers must be safe integers');
  if (value !== null && !['string', 'boolean', 'number'].includes(typeof value)) throw new Error('Unsupported contract JSON value');
  return JSON.stringify(value);
}

/** Select exactly one named asset with an API SHA-256, preserving optional-gap errors. */
function oneAsset(release, name, Missing = Error) {
  const assets = release.assets.filter(asset => asset.name === name);
  if (assets.length === 0) throw new Missing(`${release.tag_name} has no ${name}.`);
  if (assets.length !== 1) throw new Error(`Expected exactly one ${name} on ${release.tag_name}.`);
  if (!/^sha256:[0-9a-f]{64}$/.test(assets[0].digest || '')) throw new Error(`${name} has a missing or malformed digest.`);
  return assets[0];
}

/** Stop a pending read when its request/stage signal expires. */
async function withSignal(operation, signal) {
  signal?.throwIfAborted();
  if (!signal) return operation;
  let abort;
  const interrupted = new Promise((_, reject) => {
    abort = () => reject(signal.reason);
    signal.addEventListener('abort', abort, {once: true});
  });
  try { return await Promise.race([operation, interrupted]); }
  finally { signal.removeEventListener('abort', abort); }
}

/** Consume a raw response stream under a cap, cancelling it on excess or abort. */
async function boundedBody(body, {maxBytes, signal} = {}) {
  if (!body || Buffer.isBuffer(body) || body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
    throw new Error('Expected an unbuffered binary response stream');
  }
  const iterator = body[Symbol.asyncIterator]?.();
  if (!iterator) throw new Error('Expected an unbuffered binary response stream');
  const chunks = [];
  let size = 0;
  let finished = false;
  try {
    for (;;) {
      const item = await withSignal(iterator.next(), signal);
      if (item.done) { finished = true; break; }
      if (!ArrayBuffer.isView(item.value)) throw new Error('Expected binary response chunks');
      size += item.value.byteLength;
      if (size > maxBytes) throw new Error('Asset exceeds size limit.');
      chunks.push(Buffer.from(item.value));
    }
    return Buffer.concat(chunks, size);
  } finally {
    if (!finished) {
      const closing = iterator.return?.();
      if (signal?.aborted) Promise.resolve(closing).catch(() => {});
      else await closing;
    }
  }
}

/** Bounded unauthenticated HTTPS download; credentials never follow asset redirects. */
async function downloadBytes(url, {maxBytes = BINARY_LIMIT, timeoutMs = 120000, signal: parentSignal, fetcher = globalThis.fetch} = {}) {
  const timeout = AbortSignal.timeout(timeoutMs);
  const signal = parentSignal ? AbortSignal.any([parentSignal, timeout]) : timeout;
  for (let redirects = 0; redirects <= 5; redirects++) {
    const target = new URL(url);
    if (target.protocol !== 'https:' || target.username || target.password) throw new Error('Unsafe asset redirect.');
    const response = await withSignal(fetcher(target.href, {signal, redirect: 'manual'}), signal);
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      await response.body?.cancel();
      if (!location) throw new Error('Asset redirect has no destination');
      url = new URL(location, target).href;
      continue;
    }
    if (!response.ok) {
      await response.body?.cancel();
      const headers = Object.fromEntries(['retry-after', 'x-ratelimit-remaining', 'x-ratelimit-reset']
        .map(name => [name, response.headers?.get(name)]).filter(([, value]) => value != null));
      throw Object.assign(new Error(`Asset download failed: HTTP ${response.status}`), {status: response.status, response: {headers}});
    }
    const declared = response.headers?.get('content-length');
    if (declared && Number(declared) > maxBytes) {
      await response.body?.cancel();
      throw new Error('Asset exceeds size limit.');
    }
    return boundedBody(response.body, {maxBytes, signal});
  }
  throw new Error('Too many redirects downloading asset.');
}

module.exports = {HEX, SHA, DOCUMENT_LIMIT, BINARY_LIMIT, ARCHIVE_LIMIT, digest, canonical, oneAsset, downloadBytes, boundedBody, withSignal};
