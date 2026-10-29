'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  allowsLegacyQueryTokenFromEnv,
  extractWebSocketSessionCredentials
} = require('../lib/websocket_credentials');

test('websocket credential parser accepts header session token with query shard routing hint', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest({
      'x-skybridge-session-id': 'ROOM123',
      'x-skybridge-session': 'session-token',
      'x-skybridge-client-version': '1.2.3',
      'x-skybridge-protocol-version': '2'
    }),
    new URL('/ws?shard=ROOM123', 'http://skybridge.local')
  );

  assert.deepEqual(credentials, {
    authTransport: 'header',
    sessionId: 'ROOM123',
    sessionToken: 'session-token',
    clientVersion: '1.2.3',
    protocolVersion: '2'
  });
});

test('websocket credential parser rejects legacy query token by default', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest(),
    new URL('/ws?shard=ROOM123&st=session-token&cv=1.2.3&pv=2', 'http://skybridge.local')
  );

  assert.deepEqual(credentials, { error: 'legacy_query_token_disabled' });
});

test('websocket credential parser keeps legacy query token compatibility behind explicit flag', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest(),
    new URL('/ws?shard=ROOM123&st=session-token&cv=1.2.3&pv=2', 'http://skybridge.local'),
    { allowLegacyQueryToken: true }
  );

  assert.deepEqual(credentials, {
    authTransport: 'legacy_query',
    sessionId: 'ROOM123',
    sessionToken: 'session-token',
    clientVersion: '1.2.3',
    protocolVersion: '2'
  });
});

test('websocket credential parser fails closed on mixed header and query token', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest({
      'x-skybridge-session-id': 'ROOM123',
      'x-skybridge-session': 'session-token'
    }),
    new URL('/ws?shard=ROOM123&st=', 'http://skybridge.local')
  );

  assert.deepEqual(credentials, { error: 'conflicting_session_credentials' });
});

test('websocket credential parser rejects partial header credentials', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest({
      'x-skybridge-session-id': 'ROOM123'
    }),
    new URL('/ws?shard=ROOM123', 'http://skybridge.local')
  );

  assert.deepEqual(credentials, { error: 'partial_session_credentials' });
});

test('websocket credential parser rejects mismatched query shard in header mode', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest({
      'x-skybridge-session-id': 'ROOM123',
      'x-skybridge-session': 'session-token'
    }),
    new URL('/ws?shard=ROOM999', 'http://skybridge.local')
  );

  assert.deepEqual(credentials, { error: 'conflicting_session_credentials' });
});

test('websocket credential parser rejects invalid legacy query credentials', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest(),
    new URL('/ws?shard=ROOM123&st=', 'http://skybridge.local')
  );

  assert.deepEqual(credentials, { error: 'invalid_session_credentials' });
});

test('websocket credential parser rejects duplicate raw session headers', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest(
      {
        'x-skybridge-session-id': 'ROOM123',
        'x-skybridge-session': 'session-token'
      },
      [
        'X-SkyBridge-Session', 'session-token',
        'X-SkyBridge-Session', 'other-token'
      ]
    ),
    new URL('/ws?shard=ROOM123', 'http://skybridge.local')
  );

  assert.deepEqual(credentials, { error: 'duplicate_session_credentials' });
});

test('websocket credential parser rejects comma-coalesced session credential headers', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest({
      'x-skybridge-session-id': 'ROOM123',
      'x-skybridge-session': 'session-token,other-token'
    }),
    new URL('/ws?shard=ROOM123', 'http://skybridge.local')
  );

  assert.deepEqual(credentials, { error: 'duplicate_session_credentials' });
});

test('websocket credential parser rejects duplicate query credentials', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest(),
    new URL('/ws?shard=ROOM123&shard=ROOM456&st=session-token', 'http://skybridge.local'),
    { allowLegacyQueryToken: true }
  );

  assert.deepEqual(credentials, { error: 'duplicate_session_credentials' });
});

test('websocket credential parser reads legacy query opt-in from explicit environment', () => {
  assert.equal(allowsLegacyQueryTokenFromEnv({}), false);
  assert.equal(allowsLegacyQueryTokenFromEnv({ SKYBRIDGE_SIGNALING_ALLOW_LEGACY_QUERY_TOKEN: 'true' }), true);
  assert.equal(allowsLegacyQueryTokenFromEnv({ SIGNALING_ALLOW_LEGACY_QUERY_TOKEN: '1' }), true);
});

test('websocket credential parser rejects control characters in headers', () => {
  const credentials = extractWebSocketSessionCredentials(
    makeRequest({
      'x-skybridge-session-id': 'ROOM123',
      'x-skybridge-session': 'session-token\r\nInjected: value'
    }),
    new URL('/ws?shard=ROOM123', 'http://skybridge.local')
  );

  assert.deepEqual(credentials, { error: 'invalid_session_credentials' });
});

function makeRequest(headers = {}, rawHeaders = []) {
  return { headers, rawHeaders };
}
