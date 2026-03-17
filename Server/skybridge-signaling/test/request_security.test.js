'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildIdempotencyFingerprint,
  businessPayloadForIdempotency,
  clientIPForRequest
} = require('../lib/request_security');

function makeRequest({
  headers = {},
  ip = '198.51.100.10',
  remoteAddress = '198.51.100.11'
} = {}) {
  return {
    ip,
    connection: { remoteAddress },
    get(name) {
      return headers[name] || headers[name.toLowerCase()] || '';
    }
  };
}

test('register-session fingerprint ignores non-semantic fields', () => {
  const base = buildIdempotencyFingerprint({
    action: 'register-session',
    body: { sessionId: 'abc', ttlSeconds: 300 },
    admissionToken: 'token-a',
    backendName: 'redis',
    fallbackTtlMs: 300_000
  });

  const withNoise = buildIdempotencyFingerprint({
    action: 'register-session',
    body: { sessionId: 'abc', ttlSeconds: 300, debug: true, traceId: 'trace-1' },
    admissionToken: 'token-a',
    backendName: 'redis',
    fallbackTtlMs: 300_000
  });

  assert.equal(base, withNoise);
});

test('register-session fingerprint differs for different admission tokens', () => {
  const left = buildIdempotencyFingerprint({
    action: 'register-session',
    body: { sessionId: 'abc', ttlSeconds: 300 },
    admissionToken: 'token-a',
    backendName: 'redis',
    fallbackTtlMs: 300_000
  });
  const right = buildIdempotencyFingerprint({
    action: 'register-session',
    body: { sessionId: 'abc', ttlSeconds: 300 },
    admissionToken: 'token-b',
    backendName: 'redis',
    fallbackTtlMs: 300_000
  });

  assert.notEqual(left, right);
});

test('register-session fingerprint ignores requested sessionId in memory mode', () => {
  const left = buildIdempotencyFingerprint({
    action: 'register-session',
    body: { sessionId: 'one', ttlSeconds: 120 },
    admissionToken: 'token-a',
    backendName: 'memory',
    fallbackTtlMs: 300_000
  });
  const right = buildIdempotencyFingerprint({
    action: 'register-session',
    body: { sessionId: 'two', ttlSeconds: 120 },
    admissionToken: 'token-a',
    backendName: 'memory',
    fallbackTtlMs: 300_000
  });

  assert.equal(left, right);
});

test('redeem-session fingerprint changes when qrBootstrapToken changes', () => {
  const left = buildIdempotencyFingerprint({
    action: 'redeem-session',
    body: { sessionId: 'session-1', qrBootstrapToken: 'bootstrap-a' },
    admissionToken: 'token-a',
    backendName: 'memory',
    fallbackTtlMs: 300_000
  });
  const right = buildIdempotencyFingerprint({
    action: 'redeem-session',
    body: { sessionId: 'session-1', qrBootstrapToken: 'bootstrap-b' },
    admissionToken: 'token-a',
    backendName: 'memory',
    fallbackTtlMs: 300_000
  });

  assert.notEqual(left, right);
});

test('business payload normalizes register-session ttlSeconds to effective semantics', () => {
  const payload = businessPayloadForIdempotency({
    action: 'register-session',
    body: { ttlSeconds: 10 },
    backendName: 'memory',
    fallbackTtlMs: 300_000
  });

  assert.deepEqual(payload, {
    sessionId: null,
    ttlSeconds: 60
  });
});

test('clientIPForRequest ignores forwarded headers when trustProxy is false', () => {
  const request = makeRequest({
    headers: {
      'CF-Connecting-IP': '203.0.113.12',
      'X-Forwarded-For': '203.0.113.13'
    },
    ip: '198.51.100.20',
    remoteAddress: '198.51.100.21'
  });

  assert.equal(clientIPForRequest(request, { trustProxy: false }), '198.51.100.20');
});

test('clientIPForRequest honors CF-Connecting-IP when trustProxy is true', () => {
  const request = makeRequest({
    headers: {
      'CF-Connecting-IP': '203.0.113.12',
      'X-Forwarded-For': '203.0.113.13'
    },
    ip: '198.51.100.20',
    remoteAddress: '198.51.100.21'
  });

  assert.equal(clientIPForRequest(request, { trustProxy: true }), '203.0.113.12');
});
