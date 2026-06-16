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

test('resolveSignalingServerOrigin rejects configured public cleartext origins', () => {
  assert.throws(
    () => resolveSignalingServerOrigin({
      configuredOrigin: 'http://signal.example.com',
      requireConfiguredOrigin: true
    }),
    /invalid_signaling_server_origin/
  );
});

test('resolveSignalingServerOrigin rejects derived public cleartext origins', () => {
  assert.throws(
    () => resolveSignalingServerOrigin({
      configuredOrigin: '',
      requireConfiguredOrigin: false,
      forwardedProto: 'http',
      requestProtocol: 'https',
      host: 'signal.example.com'
    }),
    /invalid_signaling_server_origin/
  );
});

test('resolveSignalingServerOrigin allows loopback cleartext origins for local tooling', () => {
  assert.equal(
    resolveSignalingServerOrigin({
      configuredOrigin: 'http://127.0.0.1:8443',
      requireConfiguredOrigin: true
    }),
    'http://127.0.0.1:8443'
  );
  assert.equal(
    resolveSignalingServerOrigin({
      configuredOrigin: 'http://localhost:8443',
      requireConfiguredOrigin: true
    }),
    'http://localhost:8443'
  );
  assert.equal(
    resolveSignalingServerOrigin({
      configuredOrigin: 'http://[::1]:8443',
      requireConfiguredOrigin: true
    }),
    'http://[::1]:8443'
  );
});

test('redactSecretURLForLog removes redis credentials', () => {
  assert.equal(
    redactSecretURLForLog('redis://user:password@example.com:6379/0'),
    'redis://***:***@example.com:6379/0'
  );
});
