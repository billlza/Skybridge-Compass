'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  __test: {
    redactSecretURLForLog,
    resolveSignalingServerOrigin
  }
} = require('../server');

test('resolveSignalingServerOrigin prefers configured origin over request headers', () => {
  const resolved = resolveSignalingServerOrigin({
    configuredOrigin: 'https://signal.skybridge.example',
    requireConfiguredOrigin: true,
    forwardedProto: 'http',
    requestProtocol: 'http',
    host: 'attacker.example'
  });

  assert.equal(resolved, 'https://signal.skybridge.example');
});

test('resolveSignalingServerOrigin rejects missing configured origin when required', () => {
  assert.throws(
    () => resolveSignalingServerOrigin({
      configuredOrigin: '',
      requireConfiguredOrigin: true,
      host: 'signaling.example'
    }),
    /missing_signaling_server_origin/
  );
});

test('resolveSignalingServerOrigin falls back to request origin only when explicitly allowed', () => {
  const resolved = resolveSignalingServerOrigin({
    configuredOrigin: '',
    requireConfiguredOrigin: false,
    forwardedProto: 'https',
    requestProtocol: 'http',
    host: 'signaling.example'
  });

  assert.equal(resolved, 'https://signaling.example');
});

test('redactSecretURLForLog removes redis credentials', () => {
  assert.equal(
    redactSecretURLForLog('redis://user:password@example.com:6379/0'),
    'redis://***:***@example.com:6379/0'
  );
});
