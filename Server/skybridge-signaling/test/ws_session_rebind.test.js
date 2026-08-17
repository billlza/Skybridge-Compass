'use strict';

// Regression coverage for the post-host signaling lifeline:
// a hosted session's WebSocket that drops after a successful bind must be able
// to re-attach with its still-valid session token once the previous binding is
// gone, without weakening the live-socket anti-hijack rejection.

const test = require('node:test');
const { before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { WebSocket } = require('ws');

process.env.TURN_SHARED_SECRET = process.env.TURN_SHARED_SECRET || 'rebind-turn-secret';
process.env.TURN_URIS = process.env.TURN_URIS || 'turns:turn.example.test:5349?transport=tcp';
process.env.WS_HEARTBEAT_INTERVAL_MS = '50';
process.env.SESSION_RECLAIM_WINDOW_MS = '250';
process.env.REQUIRE_SMS_AUTH_READY = 'false';
process.env.MEDIA_RELAY_ENABLED = 'false';
process.env.MEDIA_RELAY_EXTERNAL_HOST = process.env.MEDIA_RELAY_EXTERNAL_HOST || '203.0.113.10';
process.env.MEDIA_RELAY_EXTERNAL_UDP_PORT = process.env.MEDIA_RELAY_EXTERNAL_UDP_PORT || '3478';
process.env.MEDIA_RELAY_TOKEN_SECRET = process.env.MEDIA_RELAY_TOKEN_SECRET || 'rebind-media-relay-token-secret';
process.env.HTTP_CONTROL_RATE_LIMIT_PER_MIN = '1000';
process.env.HTTP_LOOKUP_RATE_LIMIT_PER_MIN = '1000';
process.env.HTTP_ADMISSION_RATE_LIMIT_PER_MIN = '1000';
process.env.SKYBRIDGE_SIGNALING_WEBSOCKET_PATH = '/rebind-path/ws';
process.env.SKYBRIDGE_SIGNALING_ALLOW_LEGACY_QUERY_TOKEN = 'false';

const SESSION_RECLAIM_WINDOW_MS = Number(process.env.SESSION_RECLAIM_WINDOW_MS);
const websocketPath = process.env.SKYBRIDGE_SIGNALING_WEBSOCKET_PATH;

const { createSignalingStateBackend } = require('../lib/signaling_state_backend');
const {
  createRuntime,
  __test: { computeProtocolIdentityFingerprint }
} = require('../server');

const tenantId = 'tenant-rebind-test';
const bearerToken = 'rebind-bearer-token';
const userId = 'user-rebind-test';

class MinimalRegistryStore {
  constructor() {
    this.configured = true;
  }

  async verifyAccessToken(accessToken) {
    assert.equal(accessToken, bearerToken);
    return {
      id: userId,
      email: 'rebind@example.com',
      appMetadata: { tenant_id: tenantId },
      userMetadata: {},
      isGuest: false
    };
  }

  async getTenantPolicy(requestedTenantId) {
    assert.equal(requestedTenantId, tenantId);
    return {
      tenant_id: requestedTenantId,
      public_signaling_enabled: true,
      min_supported_client_version: '0.0.0',
      min_supported_protocol_version: '0'
    };
  }

  async getRegisteredDevice({ tenantId: requestedTenantId, userId: requestedUserId, deviceId, protocolSigningAlgorithm, protocolPublicKeyFingerprint }) {
    return {
      tenant_id: requestedTenantId,
      user_id: requestedUserId,
      device_id: deviceId,
      protocol_signing_algorithm: protocolSigningAlgorithm,
      protocol_public_key_fingerprint: protocolPublicKeyFingerprint,
      identity_generation: 1,
      status: 'active'
    };
  }
}

let runtime;
let baseURL;

before(async () => {
  const signalingState = createSignalingStateBackend({
    backendName: 'memory',
    instanceId: 'ws-rebind-tests',
    codeTtlMs: 300_000,
    iceTtlMs: 300_000,
    iceMaxPerSession: 40,
    roomMembershipTtlMs: 120_000,
    legacyBindingTtlMs: 300_000,
    log: console
  });

  runtime = createRuntime({
    signalingStateOverride: signalingState,
    registryStoreOverride: new MinimalRegistryStore(),
    trustProxy: false,
    requireSharedStateForPublicCapabilities: false,
    allowBootstrapDeviceAuth: true,
    allowLegacyQueryToken: false,
    port: 0,
    host: '127.0.0.1'
  });

  const address = await runtime.start();
  baseURL = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  if (runtime) {
    await runtime.shutdown();
  }
});

function makeIdentityBinding(prefix) {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const publicKeyDer = publicKey.export({ type: 'spki', format: 'der' });
  const rawPublicKey = publicKeyDer.subarray(publicKeyDer.length - 32);
  return {
    deviceId: `${prefix}-${crypto.randomUUID()}`,
    protocolSigningAlgorithm: 'Ed25519',
    protocolPublicKeyBytes: rawPublicKey,
    protocolPublicKeyFingerprint: computeProtocolIdentityFingerprint('Ed25519', rawPublicKey),
    privateKey
  };
}

function admissionChallengePayload(challenge) {
  return Buffer.from([
    'SkyBridge-Admission-Challenge',
    challenge.challengeId,
    challenge.nonce,
    challenge.tenantId,
    challenge.userId,
    challenge.deviceId,
    challenge.clientVersion,
    challenge.protocolVersion
  ].join('\n'), 'utf8');
}

async function postJSON(path, { headers = {}, body, requiresAuth = false } = {}) {
  const requestHeaders = {
    'Content-Type': 'application/json',
    ...headers
  };
  if (requiresAuth) {
    requestHeaders.Authorization = `Bearer ${bearerToken}`;
  }
  const response = await fetch(`${baseURL}${path}`, {
    method: 'POST',
    headers: requestHeaders,
    body: JSON.stringify(body)
  });
  const text = await response.text();
  return { status: response.status, json: text ? JSON.parse(text) : {} };
}

async function getJSON(path, { headers = {} } = {}) {
  const response = await fetch(`${baseURL}${path}`, { headers });
  const text = await response.text();
  return { status: response.status, json: text ? JSON.parse(text) : {} };
}

async function issueAdmissionLease(binding) {
  const challenge = await postJSON('/api/webrtc/admission/challenge', {
    headers: { 'X-SkyBridge-Tenant-Id': tenantId },
    requiresAuth: true,
    body: {
      deviceId: binding.deviceId,
      protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
      clientVersion: '1.0.0',
      protocolVersion: '1'
    }
  });
  assert.equal(challenge.status, 200);

  const admission = await postJSON('/api/webrtc/admission', {
    headers: { 'X-SkyBridge-Tenant-Id': tenantId },
    requiresAuth: true,
    body: {
      challengeId: challenge.json.challengeId,
      signature: crypto.sign(null, admissionChallengePayload(challenge.json), binding.privateKey).toString('base64'),
      deviceId: binding.deviceId,
      protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
      protocolPublicKeyBytes: binding.protocolPublicKeyBytes.toString('base64'),
      clientVersion: challenge.json.clientVersion,
      protocolVersion: challenge.json.protocolVersion
    }
  });
  assert.equal(admission.status, 200);
  return admission.json;
}

async function registerCode(binding, { ttlSeconds = 120 } = {}) {
  const admissionLease = await issueAdmissionLease(binding);
  const codeResponse = await postJSON('/api/webrtc/register-code', {
    headers: { 'X-SkyBridge-Admission': admissionLease.admissionToken },
    body: { ttlSeconds, deviceName: 'Rebind Host' }
  });
  assert.equal(codeResponse.status, 200);
  return codeResponse.json;
}

function openSessionSocket(t, sessionId, sessionToken) {
  const ws = new WebSocket(`${baseURL.replace(/^http/, 'ws')}${websocketPath}?shard=${encodeURIComponent(sessionId)}`, {
    headers: {
      'X-SkyBridge-Session-Id': sessionId,
      'X-SkyBridge-Session': sessionToken
    }
  });
  // Sockets left open by an assertion failure would stall runtime.shutdown().
  t.after(() => {
    try { ws.terminate(); } catch (_) {}
  });
  return ws;
}

function waitForWebSocketMessage(ws, predicate, timeoutMs = 1_500) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error('timed out waiting for websocket message'));
    }, timeoutMs);

    function cleanup() {
      clearTimeout(timer);
      ws.off('message', onMessage);
      ws.off('error', onError);
      ws.off('close', onClose);
    }

    function onMessage(raw) {
      try {
        const message = JSON.parse(String(raw));
        if (!predicate(message)) return;
        cleanup();
        resolve(message);
      } catch (error) {
        cleanup();
        reject(error);
      }
    }

    function onError(error) {
      cleanup();
      reject(error);
    }

    function onClose(code, reasonBuffer) {
      cleanup();
      reject(new Error(`websocket closed before expected message: ${code} ${String(reasonBuffer || '')}`));
    }

    ws.on('message', onMessage);
    ws.on('error', onError);
    ws.on('close', onClose);
  });
}

function waitForWebSocketClose(ws, timeoutMs = 1_500) {
  if (ws.readyState === WebSocket.CLOSED) {
    return Promise.resolve({ code: null, reason: '' });
  }
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error('timed out waiting for websocket close'));
    }, timeoutMs);

    function cleanup() {
      clearTimeout(timer);
      ws.off('close', onClose);
      ws.off('error', onError);
    }

    function onClose(code, reasonBuffer) {
      cleanup();
      resolve({ code, reason: String(reasonBuffer || '') });
    }

    function onError(error) {
      cleanup();
      reject(error);
    }

    ws.on('close', onClose);
    ws.on('error', onError);
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function joinEnvelope(sessionId, binding) {
  return JSON.stringify({
    sessionId,
    from: binding.deviceId,
    type: 'join',
    payload: null,
    sentAt: Math.floor(Date.now() / 1000)
  });
}

test('initiator rebinds after a silent socket drop outside the reclaim window and the code stays redeemable', async (t) => {
  const initiator = makeIdentityBinding('rebind-host');
  const lease = await registerCode(initiator);

  const firstSocket = openSessionSocket(t, lease.sessionId, lease.sessionToken);
  const firstBound = await waitForWebSocketMessage(firstSocket, (message) => message.type === 'bound');
  assert.equal(firstBound.role, 'initiator');

  // Survive several server heartbeat intervals before the drop.
  await sleep(200);
  assert.equal(firstSocket.readyState, WebSocket.OPEN);

  // Abrupt transport loss: no client close frame, like a NAT/path drop.
  firstSocket.terminate();
  await sleep(SESSION_RECLAIM_WINDOW_MS + 250);

  const secondSocket = openSessionSocket(t, lease.sessionId, lease.sessionToken);
  const secondBound = await waitForWebSocketMessage(secondSocket, (message) => message.type === 'bound');
  assert.equal(secondBound.role, 'initiator');

  // The dropped socket must not have evicted the rendezvous record.
  const responder = makeIdentityBinding('rebind-peer');
  const responderAdmission = await issueAdmissionLease(responder);
  const lookup = await getJSON(`/api/webrtc/lookup/${lease.code}`, {
    headers: { 'X-SkyBridge-Admission': responderAdmission.admissionToken }
  });
  assert.equal(lookup.status, 200);
  assert.equal(lookup.json.found, true);
  assert.equal(lookup.json.initiatorDeviceId, initiator.deviceId);

  // Full establishment continues on the re-bound socket.
  const responderSocket = openSessionSocket(t, lookup.json.sessionId, lookup.json.sessionToken);
  const responderBound = await waitForWebSocketMessage(responderSocket, (message) => message.type === 'bound');
  assert.equal(responderBound.role, 'responder');

  const relayedJoin = waitForWebSocketMessage(secondSocket, (message) => message.type === 'join');
  responderSocket.send(joinEnvelope(lookup.json.sessionId, responder));
  const join = await relayedJoin;
  assert.equal(join.from, responder.deviceId);
});

test('graceful close releases the binding for a reconnect outside the reclaim window', async (t) => {
  const initiator = makeIdentityBinding('rebind-clean');
  const lease = await registerCode(initiator);

  const firstSocket = openSessionSocket(t, lease.sessionId, lease.sessionToken);
  await waitForWebSocketMessage(firstSocket, (message) => message.type === 'bound');
  firstSocket.close(1000, 'client_going_away');
  await waitForWebSocketClose(firstSocket);
  await sleep(SESSION_RECLAIM_WINDOW_MS + 250);

  const secondSocket = openSessionSocket(t, lease.sessionId, lease.sessionToken);
  const bound = await waitForWebSocketMessage(secondSocket, (message) => message.type === 'bound');
  assert.equal(bound.role, 'initiator');
});

test('a held binding outside the reclaim window still rejects a second bind and keeps the holder attached', async (t) => {
  const initiator = makeIdentityBinding('rebind-held');
  const lease = await registerCode(initiator);

  const holderSocket = openSessionSocket(t, lease.sessionId, lease.sessionToken);
  await waitForWebSocketMessage(holderSocket, (message) => message.type === 'bound');
  await sleep(SESSION_RECLAIM_WINDOW_MS + 250);

  const intruderSocket = openSessionSocket(t, lease.sessionId, lease.sessionToken);
  let intruderErrorFrame = null;
  intruderSocket.on('message', (raw) => {
    try {
      const message = JSON.parse(String(raw));
      if (message.type === 'error') intruderErrorFrame = message;
    } catch (_) {}
  });
  const close = await waitForWebSocketClose(intruderSocket);
  assert.equal(close.code, 1008);
  assert.equal(close.reason, 'session_token_already_bound');
  assert.ok(intruderErrorFrame, 'bind rejection must be acked with an error frame before the close');
  assert.equal(intruderErrorFrame.error, 'session_token_already_bound');

  // The legitimate holder stays bound and reachable.
  assert.equal(holderSocket.readyState, WebSocket.OPEN);
  const responder = makeIdentityBinding('rebind-held-peer');
  const responderAdmission = await issueAdmissionLease(responder);
  const lookup = await getJSON(`/api/webrtc/lookup/${lease.code}`, {
    headers: { 'X-SkyBridge-Admission': responderAdmission.admissionToken }
  });
  assert.equal(lookup.status, 200);

  const responderSocket = openSessionSocket(t, lookup.json.sessionId, lookup.json.sessionToken);
  await waitForWebSocketMessage(responderSocket, (message) => message.type === 'bound');
  const relayedJoin = waitForWebSocketMessage(holderSocket, (message) => message.type === 'join');
  responderSocket.send(joinEnvelope(lookup.json.sessionId, responder));
  const join = await relayedJoin;
  assert.equal(join.from, responder.deviceId);
});
