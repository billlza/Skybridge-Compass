'use strict';

const test = require('node:test');
const { before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.TURN_SHARED_SECRET = process.env.TURN_SHARED_SECRET || 'integration-turn-secret';
process.env.TURN_URIS = process.env.TURN_URIS || 'turns:turn.example.test:5349?transport=tcp,turn:turn.example.test:3478?transport=udp';

const { createSignalingStateBackend } = require('../lib/signaling_state_backend');
const { createRuntime } = require('../server');

const tenantId = 'tenant-live-test';
const otherTenantId = 'tenant-other-test';
const bearerToken = 'integration-bearer-token';
const sameTenantOtherUserBearerToken = 'integration-bearer-token-user-2';
const otherTenantBearerToken = 'integration-bearer-token-tenant-2';
const userId = 'user-live-test';
const sameTenantOtherUserId = 'user-live-test-2';
const otherTenantUserId = 'user-other-tenant-test';

class FakeRegistryStore {
  constructor() {
    this.configured = true;
    this.syntheticOnlyDeviceIds = new Set();
    this.bootstrapCalls = [];
    this.sessionsByAccessToken = new Map([
      [bearerToken, { userId, tenantId, email: 'integration@example.com' }],
      [sameTenantOtherUserBearerToken, { userId: sameTenantOtherUserId, tenantId, email: 'integration-user-2@example.com' }],
      [otherTenantBearerToken, { userId: otherTenantUserId, tenantId: otherTenantId, email: 'integration-other-tenant@example.com' }]
    ]);
    this.allowedTenantIds = new Set([tenantId, otherTenantId]);
  }

  async verifyAccessToken(accessToken) {
    const session = this.sessionsByAccessToken.get(accessToken);
    assert.ok(session, `unexpected access token: ${accessToken}`);
    return {
      id: session.userId,
      email: session.email,
      appMetadata: { tenant_id: session.tenantId },
      userMetadata: {},
      isGuest: false
    };
  }

  async getTenantPolicy(requestedTenantId) {
    assert.ok(this.allowedTenantIds.has(requestedTenantId), `unexpected tenant policy lookup: ${requestedTenantId}`);
    return {
      tenant_id: requestedTenantId,
      public_signaling_enabled: true,
      min_supported_client_version: '0.0.0',
      min_supported_protocol_version: '0'
    };
  }

  async getRegisteredDevice({ tenantId: requestedTenantId, userId: requestedUserId, deviceId }) {
    assert.ok(this.allowedTenantIds.has(requestedTenantId), `unexpected device lookup tenant: ${requestedTenantId}`);
    assert.ok(
      [...this.sessionsByAccessToken.values()].some((session) => session.userId === requestedUserId),
      `unexpected device lookup user: ${requestedUserId}`
    );
    if (this.syntheticOnlyDeviceIds.has(deviceId)) {
      return null;
    }
    return { status: 'active' };
  }

  allowSyntheticOnly(deviceId) {
    this.syntheticOnlyDeviceIds.add(deviceId);
  }

  clearSyntheticOnly(deviceId) {
    this.syntheticOnlyDeviceIds.delete(deviceId);
  }

  async bootstrapRegisterDevice(payload) {
    this.bootstrapCalls.push(payload);
    return {
      tenant_id: payload.p_tenant_id,
      user_id: payload.p_user_id,
      device_id: payload.p_device_id,
      protocol_signing_algorithm: payload.p_protocol_signing_algorithm,
      protocol_public_key_fingerprint: String(payload.p_protocol_public_key_fingerprint || '').toLowerCase(),
      device_name: payload.p_device_name || 'Trusted Device',
      status: 'active',
      approval_method: 'bootstrap'
    };
  }
}

let runtime;
let baseURL;
let registryStore;

before(async () => {
  const signalingState = createSignalingStateBackend({
    backendName: 'memory',
    instanceId: 'http-integration-tests',
    codeTtlMs: 300_000,
    iceTtlMs: 300_000,
    iceMaxPerSession: 40,
    roomMembershipTtlMs: 120_000,
    legacyBindingTtlMs: 300_000,
    log: console
  });

  registryStore = new FakeRegistryStore();
  runtime = createRuntime({
    signalingStateOverride: signalingState,
    registryStoreOverride: registryStore,
    trustProxy: false,
    requireSharedStateForPublicCapabilities: false,
    allowBootstrapDeviceAuth: true,
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

test('live register-session route replays same request and rejects mismatched reuse', async () => {
  const initiator = makeIdentityBinding('initiator');
  const admissionLease = await issueAdmissionLease(initiator);
  const idempotencyKey = 'register-live-key-1';

  const first = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken,
      'Idempotency-Key': idempotencyKey
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(first.status, 200);
  assert.equal(typeof first.json.sessionId, 'string');
  assert.equal(typeof first.json.sessionToken, 'string');
  assert.equal(typeof first.json.qrBootstrapToken, 'string');

  const replay = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken,
      'Idempotency-Key': idempotencyKey
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(replay.status, 200);
  assert.deepEqual(replay.json, first.json);

  const mismatchBody = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken,
      'Idempotency-Key': idempotencyKey
    },
    body: {
      ttlSeconds: 180
    }
  });

  assert.equal(mismatchBody.status, 409);
  assert.equal(mismatchBody.json.error, 'idempotency_key_reused');

  const secondAdmission = await issueAdmissionLease(initiator);
  const mismatchToken = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': secondAdmission.admissionToken,
      'Idempotency-Key': idempotencyKey
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(mismatchToken.status, 409);
  assert.equal(mismatchToken.json.error, 'idempotency_key_reused');
});

test('lookup rejects responders from a different user in the same tenant', async () => {
  const initiator = makeIdentityBinding('lookup-initiator');
  const initiatorAdmission = await issueAdmissionLease(initiator);
  const codeResponse = await postJSON('/api/webrtc/register-code', {
    headers: {
      'X-SkyBridge-Admission': initiatorAdmission.admissionToken
    },
    body: {
      ttlSeconds: 120,
      deviceName: 'Initiator Mac'
    }
  });

  assert.equal(codeResponse.status, 200);

  const responder = makeIdentityBinding('lookup-responder');
  const responderAdmission = await issueAdmissionLease(responder, {
    accessToken: sameTenantOtherUserBearerToken
  });
  const lookup = await getJSON(`/api/webrtc/lookup/${codeResponse.json.code}`, {
    headers: {
      'X-SkyBridge-Admission': responderAdmission.admissionToken
    }
  });

  assert.equal(lookup.status, 404);
  assert.deepEqual(lookup.json, { found: false });
});

test('live redeem-session route replays same request and rejects mismatched reuse', async () => {
  const initiator = makeIdentityBinding('initiator-redeem');
  const initiatorAdmission = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': initiatorAdmission.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);

  const responder = makeIdentityBinding('responder');
  const responderAdmission = await issueAdmissionLease(responder);
  const idempotencyKey = 'redeem-live-key-1';

  const first = await postJSON('/api/webrtc/redeem-session', {
    headers: {
      'X-SkyBridge-Admission': responderAdmission.admissionToken,
      'Idempotency-Key': idempotencyKey
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      qrBootstrapToken: sessionResponse.json.qrBootstrapToken
    }
  });

  assert.equal(first.status, 200);
  assert.equal(typeof first.json.sessionToken, 'string');

  const replay = await postJSON('/api/webrtc/redeem-session', {
    headers: {
      'X-SkyBridge-Admission': responderAdmission.admissionToken,
      'Idempotency-Key': idempotencyKey
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      qrBootstrapToken: sessionResponse.json.qrBootstrapToken
    }
  });

  assert.equal(replay.status, 200);
  assert.deepEqual(replay.json, first.json);

  const secondAdmission = await issueAdmissionLease(responder);
  const mismatchToken = await postJSON('/api/webrtc/redeem-session', {
    headers: {
      'X-SkyBridge-Admission': secondAdmission.admissionToken,
      'Idempotency-Key': idempotencyKey
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      qrBootstrapToken: sessionResponse.json.qrBootstrapToken
    }
  });

  assert.equal(mismatchToken.status, 409);
  assert.equal(mismatchToken.json.error, 'idempotency_key_reused');
});

test('redeem-session rejects responders from a different tenant', async () => {
  const initiator = makeIdentityBinding('initiator-cross-tenant');
  const initiatorAdmission = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': initiatorAdmission.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);

  const responder = makeIdentityBinding('responder-cross-tenant');
  const responderAdmission = await issueAdmissionLease(responder, {
    accessToken: otherTenantBearerToken,
    requestTenantId: otherTenantId
  });
  const redeem = await postJSON('/api/webrtc/redeem-session', {
    headers: {
      'X-SkyBridge-Admission': responderAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      qrBootstrapToken: sessionResponse.json.qrBootstrapToken
    }
  });

  assert.equal(redeem.status, 404);
  assert.equal(redeem.json.error, 'session_expired');
});

test('turn credentials accept bootstrap-auth synthetic devices', async () => {
  const syntheticInitiator = makeIdentityBinding('bootstrap-turn');
  registryStore.allowSyntheticOnly(syntheticInitiator.deviceId);
  try {
    const admissionLease = await issueAdmissionLease(syntheticInitiator);
    const sessionResponse = await postJSON('/api/webrtc/register-session', {
      headers: {
        'X-SkyBridge-Admission': admissionLease.admissionToken
      },
      body: {
        ttlSeconds: 120
      }
    });

    assert.equal(sessionResponse.status, 200);

    const response = await fetch(`${baseURL}/api/turn/credentials`, {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'X-SkyBridge-Turn-Admission': sessionResponse.json.turnAdmissionToken
      }
    });

    assert.equal(response.status, 200);
    const json = await response.json();
    assert.equal(typeof json.username, 'string');
    assert.equal(typeof json.password, 'string');
    assert.ok(Array.isArray(json.uris));
  } finally {
    registryStore.clearSyntheticOnly(syntheticInitiator.deviceId);
  }
});

test('register-current keeps existing registered devices active without bootstrap activation flag', async () => {
  const binding = makeIdentityBinding('register-current-existing');
  const response = await postJSON('/api/devices/register-current', {
    requiresAuth: true,
    body: {
      deviceId: binding.deviceId,
      protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
      clientVersion: '1.0.0',
      protocolVersion: '1',
      deviceName: 'Current Mac'
    }
  });

  assert.equal(response.status, 200);
  assert.equal(response.json.registered, true);
  assert.equal(response.json.activated, false);
  assert.equal(response.json.device.device_id, binding.deviceId);
  assert.equal(response.json.device.status, 'active');
  assert.equal(response.json.device.device_name, 'Current Mac');
  assert.equal(response.json.device.approval_method, 'bootstrap');
});

test('register-current bootstraps the first current-path device when auth bootstrap is allowed', async () => {
  const binding = makeIdentityBinding('register-current-bootstrap');
  registryStore.allowSyntheticOnly(binding.deviceId);
  try {
    const response = await postJSON('/api/devices/register-current', {
      requiresAuth: true,
      body: {
        deviceId: binding.deviceId,
        protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
        protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
        clientVersion: '1.0.0',
        protocolVersion: '1',
        deviceName: 'Bootstrap Mac'
      }
    });

    assert.equal(response.status, 200);
    assert.equal(response.json.registered, true);
    assert.equal(response.json.activated, true);
    assert.equal(response.json.device.device_id, binding.deviceId);
    assert.equal(response.json.device.device_name, 'Bootstrap Mac');
    assert.equal(response.json.device.status, 'active');
    assert.equal(response.json.device.approval_method, 'bootstrap');
  } finally {
    registryStore.clearSyntheticOnly(binding.deviceId);
  }
});

function makeIdentityBinding(prefix, algorithm = 'Ed25519') {
  let publicKey;
  let privateKey;
  let rawPublicKey;
  let protocolSigningAlgorithm;

  if (algorithm === 'ML-DSA-65') {
    ({ publicKey, privateKey } = crypto.generateKeyPairSync('ml-dsa-65'));
    const publicKeyDer = publicKey.export({ type: 'spki', format: 'der' });
    rawPublicKey = publicKeyDer.subarray(publicKeyDer.length - 1952);
    protocolSigningAlgorithm = 'ML-DSA-65';
  } else {
    ({ publicKey, privateKey } = crypto.generateKeyPairSync('ed25519'));
    const publicKeyDer = publicKey.export({ type: 'spki', format: 'der' });
    rawPublicKey = publicKeyDer.subarray(publicKeyDer.length - 32);
    protocolSigningAlgorithm = 'Ed25519';
  }

  return {
    deviceId: `${prefix}-${crypto.randomUUID()}`,
    protocolSigningAlgorithm,
    protocolPublicKeyBytes: rawPublicKey,
    protocolPublicKeyFingerprint: crypto.createHash('sha256').update(rawPublicKey).digest('hex'),
    privateKey
  };
}

async function issueAdmissionLease(binding, { accessToken = bearerToken, requestTenantId = tenantId } = {}) {
  const challenge = await postJSON('/api/webrtc/admission/challenge', {
    headers: {
      'X-SkyBridge-Tenant-Id': requestTenantId
    },
    requiresAuth: true,
    accessToken,
    body: {
      deviceId: binding.deviceId,
      protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
      clientVersion: '1.0.0',
      protocolVersion: '1'
    }
  });

  assert.equal(challenge.status, 200);

  const payload = Buffer.from([
    'SkyBridge-Admission-Challenge',
    challenge.json.challengeId,
    challenge.json.nonce,
    challenge.json.tenantId,
    challenge.json.userId,
    challenge.json.deviceId,
    challenge.json.clientVersion,
    challenge.json.protocolVersion
  ].join('\n'), 'utf8');

  const signature = crypto.sign(null, payload, binding.privateKey).toString('base64');
  const admission = await postJSON('/api/webrtc/admission', {
    headers: {
      'X-SkyBridge-Tenant-Id': requestTenantId
    },
    requiresAuth: true,
    accessToken,
    body: {
      challengeId: challenge.json.challengeId,
      signature,
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

test('admission accepts ML-DSA-65 challenge signatures', async () => {
  const pqcBinding = makeIdentityBinding('mldsa-admission', 'ML-DSA-65');
  const admissionLease = await issueAdmissionLease(pqcBinding);
  assert.equal(typeof admissionLease.admissionToken, 'string');
  assert.ok(admissionLease.admissionToken.length > 0);
});

async function getJSON(path, { headers = {} } = {}) {
  const response = await fetch(`${baseURL}${path}`, {
    method: 'GET',
    headers
  });

  const text = await response.text();
  return {
    status: response.status,
    json: text ? JSON.parse(text) : {}
  };
}

async function postJSON(path, { headers = {}, body, requiresAuth = false, accessToken = bearerToken } = {}) {
  const requestHeaders = {
    'Content-Type': 'application/json',
    ...headers
  };
  if (requiresAuth) {
    requestHeaders.Authorization = `Bearer ${accessToken}`;
  }

  const response = await fetch(`${baseURL}${path}`, {
    method: 'POST',
    headers: requestHeaders,
    body: JSON.stringify(body)
  });

  const text = await response.text();
  return {
    status: response.status,
    json: text ? JSON.parse(text) : {}
  };
}
