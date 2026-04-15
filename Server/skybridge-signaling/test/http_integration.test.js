'use strict';

const test = require('node:test');
const { before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Webhook } = require('standardwebhooks');
const { WebSocket } = require('ws');

process.env.TURN_SHARED_SECRET = process.env.TURN_SHARED_SECRET || 'integration-turn-secret';
process.env.TURN_URIS = process.env.TURN_URIS || 'turns:turn.example.test:5349?transport=tcp,turn:turn.example.test:3478?transport=udp';
process.env.WS_HEARTBEAT_INTERVAL_MS = process.env.WS_HEARTBEAT_INTERVAL_MS || '50';
process.env.ROOM_MEMBERSHIP_TTL_MS = process.env.ROOM_MEMBERSHIP_TTL_MS || '180';
process.env.REQUIRE_SMS_AUTH_READY = process.env.REQUIRE_SMS_AUTH_READY || 'true';
process.env.SUPABASE_SEND_SMS_HOOK_SECRET = process.env.SUPABASE_SEND_SMS_HOOK_SECRET || `whsec_${Buffer.from('integration-hook-secret').toString('base64')}`;

const { createSignalingStateBackend } = require('../lib/signaling_state_backend');
const {
  createRuntime,
  __test: {
    classifySMSDeliveryFailure,
    collectSMSServiceSnapshot,
    evaluateServiceHealth,
    wsSendRaw,
    WS_MAX_BUFFERED_BYTES
  }
} = require('../server');

const tenantId = 'tenant-live-test';
const otherTenantId = 'tenant-other-test';
const bearerToken = 'integration-bearer-token';
const sameTenantOtherUserBearerToken = 'integration-bearer-token-user-2';
const otherTenantBearerToken = 'integration-bearer-token-tenant-2';
const userId = 'user-live-test';
const sameTenantOtherUserId = 'user-live-test-2';
const otherTenantUserId = 'user-other-tenant-test';
const smsHookSigner = new Webhook(process.env.SUPABASE_SEND_SMS_HOOK_SECRET);

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

class FakeSMSClient {
  constructor() {
    this.reset();
  }

  reset() {
    this.provider = 'pnvs';
    this.calls = [];
    this.nextError = null;
    this._configurationStatus = {
      provider: 'pnvs',
      providerSupported: true,
      configured: true,
      missingConfiguration: []
    };
  }

  get configured() {
    return this._configurationStatus.configured;
  }

  get configurationStatus() {
    return {
      ...this._configurationStatus,
      missingConfiguration: [...this._configurationStatus.missingConfiguration]
    };
  }

  setConfigurationStatus(overrides = {}) {
    this._configurationStatus = {
      ...this._configurationStatus,
      ...overrides,
      missingConfiguration: [...(overrides.missingConfiguration ?? this._configurationStatus.missingConfiguration)]
    };
    this.provider = this._configurationStatus.provider;
  }

  async sendVerificationCode(payload) {
    this.calls.push(payload);
    if (this.nextError) {
      const error = this.nextError;
      this.nextError = null;
      throw error;
    }
    return {
      success: true,
      requestId: 'req-hook',
      bizId: 'biz-hook',
      code: 'OK'
    };
  }
}

let runtime;
let baseURL;
let registryStore;
let signalingState;
const fakeSMSClient = new FakeSMSClient();

before(async () => {
  signalingState = createSignalingStateBackend({
    backendName: 'memory',
    instanceId: 'http-integration-tests',
    codeTtlMs: 300_000,
    iceTtlMs: 300_000,
    iceMaxPerSession: 40,
    roomMembershipTtlMs: Number(process.env.ROOM_MEMBERSHIP_TTL_MS),
    legacyBindingTtlMs: 300_000,
    log: console
  });

  registryStore = new FakeRegistryStore();
  runtime = createRuntime({
    signalingStateOverride: signalingState,
    registryStoreOverride: registryStore,
    smsClientOverride: fakeSMSClient,
    trustProxy: false,
    requireSharedStateForPublicCapabilities: false,
    allowBootstrapDeviceAuth: true,
    port: 0,
    host: '127.0.0.1'
  });

  const address = await runtime.start();
  baseURL = `http://127.0.0.1:${address.port}`;
});

beforeEach(() => {
  fakeSMSClient.reset();
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

test('evaluateServiceHealth fails closed when shared state is required but unavailable', () => {
  const memorySnapshot = evaluateServiceHealth({
    backendHealth: { ready: true, redisConnected: false },
    stateBackend: 'memory',
    requireSharedStateForPublicCapabilities: true
  });
  assert.equal(memorySnapshot.ready, false);
  assert.deepEqual(memorySnapshot.reasons, ['shared_state_backend_required']);
  assert.equal(memorySnapshot.httpStatus, 503);

  const redisSnapshot = evaluateServiceHealth({
    backendHealth: { ready: true, redisConnected: false },
    stateBackend: 'redis',
    requireSharedStateForPublicCapabilities: true
  });
  assert.equal(redisSnapshot.ready, false);
  assert.deepEqual(redisSnapshot.reasons, ['shared_state_unavailable']);
  assert.equal(redisSnapshot.httpStatus, 503);
});

test('wsSendRaw closes slow consumers before enqueueing more bytes', () => {
  const closes = [];
  const sends = [];
  const ws = {
    OPEN: 1,
    readyState: 1,
    bufferedAmount: WS_MAX_BUFFERED_BYTES + 1,
    close(code, reason) {
      closes.push({ code, reason });
    },
    send(payload) {
      sends.push(payload);
    }
  };

  assert.equal(wsSendRaw(ws, { type: 'offer', sessionId: 'session-1' }), false);
  assert.deepEqual(closes, [{ code: 1013, reason: 'backpressure' }]);
  assert.equal(sends.length, 0);
});

test('health endpoints expose liveness separately from readiness', async () => {
  const ready = await getJSON('/readyz');
  assert.equal(ready.status, 200);
  assert.equal(ready.json.status, 'ready');
  assert.equal(ready.json.smsReady, true);
  assert.equal(ready.json.sms.provider, 'pnvs');

  const live = await fetch(`${baseURL}/healthz`);
  assert.equal(live.status, 200);
  assert.equal(await live.text(), 'ok');

  const originalGetHealth = signalingState.getHealth.bind(signalingState);
  signalingState.getHealth = async () => ({
    backend: 'memory',
    ready: false,
    redisConnected: false
  });

  try {
    const health = await getJSON('/health');
    assert.equal(health.status, 503);
    assert.equal(health.json.status, 'degraded');
    assert.deepEqual(health.json.reasons, ['state_backend_unready']);

    const degradedReady = await getJSON('/readyz');
    assert.equal(degradedReady.status, 503);
    assert.equal(degradedReady.json.status, 'not_ready');

    const stillLive = await fetch(`${baseURL}/healthz`);
    assert.equal(stillLive.status, 200);
    assert.equal(await stillLive.text(), 'ok');
  } finally {
    signalingState.getHealth = originalGetHealth;
  }
});

test('sms readiness fails closed when provider configuration is missing', async () => {
  fakeSMSClient.setConfigurationStatus({
    configured: false,
    missingConfiguration: ['accessKeyId', 'accessKeySecret']
  });

  const snapshot = collectSMSServiceSnapshot({ client: fakeSMSClient });
  assert.equal(snapshot.ready, false);
  assert.deepEqual(snapshot.reasons, ['aliyun_sms_provider_not_configured']);

  const ready = await getJSON('/readyz');
  assert.equal(ready.status, 503);
  assert.equal(ready.json.status, 'not_ready');
  assert.equal(ready.json.smsReady, false);
  assert.deepEqual(ready.json.sms.missingConfiguration, ['accessKeyId', 'accessKeySecret']);
  assert.ok(ready.json.reasons.includes('aliyun_sms_provider_not_configured'));
});

test('sms readiness reports missing hook secret when startup secret is absent', () => {
  const snapshot = collectSMSServiceSnapshot({
    client: fakeSMSClient,
    hookSecret: ''
  });

  assert.equal(snapshot.ready, false);
  assert.deepEqual(snapshot.reasons, ['supabase_send_sms_hook_secret_missing']);
});

test('send_sms hook accepts valid signatures and delivers through configured provider', async () => {
  const response = await postSignedSendSMS({
    user: { phone: '+8613800138000' },
    sms: { otp: '123456' }
  });

  assert.equal(response.status, 200);
  assert.equal(fakeSMSClient.calls.length, 1);
  assert.deepEqual(fakeSMSClient.calls[0], {
    phoneNumber: '+8613800138000',
    otp: '123456'
  });

  const health = await getJSON('/health');
  assert.equal(health.status, 200);
  assert.equal(health.json.sms.counters.delivery_success, 1);
  assert.equal(health.json.sms.lastEvent.event, 'supabase_send_sms_delivered');
});

test('send_sms hook rejects invalid signatures', async () => {
  const response = await postRawJSON('/api/hooks/supabase/send-sms', {
    headers: {
      'webhook-id': 'msg_invalid',
      'webhook-timestamp': String(Math.floor(Date.now() / 1000)),
      'webhook-signature': 'v1,invalid'
    },
    body: {
      user: { phone: '+8613800138000' },
      sms: { otp: '123456' }
    }
  });

  assert.equal(response.status, 401);
  assert.equal(response.json.error, 'supabase_send_sms_hook_invalid');

  const health = await getJSON('/health');
  assert.equal(health.json.sms.counters.hook_verify_failed, 1);
  assert.equal(health.json.sms.lastEvent.reason, 'invalid_signature');
});

test('send_sms hook classifies provider timeout as retryable delivery failure', async () => {
  const timeoutError = new Error('upstream timed out');
  timeoutError.code = 'ETIMEDOUT';
  fakeSMSClient.nextError = timeoutError;

  const classification = classifySMSDeliveryFailure(timeoutError);
  assert.equal(classification.reason, 'provider_timeout');
  assert.equal(classification.retryable, true);

  const response = await postSignedSendSMS({
    user: { phone: '+8613800138000' },
    sms: { otp: '123456' }
  });

  assert.equal(response.status, 504);
  assert.equal(response.json.error, 'sms_provider_timeout');

  const health = await getJSON('/health');
  assert.equal(health.json.sms.counters.delivery_failed_provider_timeout, 1);
  assert.equal(health.json.sms.counters.delivery_failed_retryable, 1);
  assert.equal(health.json.sms.lastEvent.reason, 'provider_timeout');
  assert.equal(health.json.sms.lastEvent.retryable, true);
});

test('send_sms hook classifies PNVS template-variable rejection as non-retryable template failure', async () => {
  const templateError = new Error('aliyun_pnvs_failed:模版变量min内容非法');
  templateError.response = {
    code: 'ISV.INVALID_PARAMETERS'
  };
  fakeSMSClient.nextError = templateError;

  const classification = classifySMSDeliveryFailure(templateError);
  assert.equal(classification.reason, 'template_rejected');
  assert.equal(classification.retryable, false);

  const response = await postSignedSendSMS({
    user: { phone: '+8613800138000' },
    sms: { otp: '123456' }
  });

  assert.equal(response.status, 502);
  assert.equal(response.json.error, 'sms_template_rejected');

  const health = await getJSON('/health');
  assert.equal(health.json.sms.counters.delivery_failed_template_rejected, 1);
  assert.equal(health.json.sms.counters.delivery_failed_non_retryable, 1);
  assert.equal(health.json.sms.lastEvent.reason, 'template_rejected');
  assert.equal(health.json.sms.lastEvent.retryable, false);
});

test('heartbeat pong renews idle room membership leases', async () => {
  const binding = makeIdentityBinding('heartbeat-idle');
  const admissionLease = await issueAdmissionLease(binding);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);

  const ws = new WebSocket(
    `${baseURL.replace(/^http/, 'ws')}/ws?shard=${encodeURIComponent(sessionResponse.json.sessionId)}&st=${encodeURIComponent(sessionResponse.json.sessionToken)}`
  );
  try {
    const bound = await waitForWebSocketMessage(ws, (message) => message.type === 'bound');
    assert.equal(bound.sessionId, sessionResponse.json.sessionId);

    await sleep(Number(process.env.ROOM_MEMBERSHIP_TTL_MS) * 2);
    const members = await signalingState.listRoomMembers(sessionResponse.json.sessionId);
    assert.equal(members.some((member) => member.deviceId === binding.deviceId), true);
  } finally {
    ws.close();
    await waitForWebSocketClose(ws);
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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function signedHookHeaders(payload) {
  const rawBody = JSON.stringify(payload);
  const timestamp = new Date();
  const messageId = `msg_${crypto.randomUUID()}`;
  return {
    rawBody,
    headers: {
      'webhook-id': messageId,
      'webhook-timestamp': String(Math.floor(timestamp.getTime() / 1000)),
      'webhook-signature': smsHookSigner.sign(messageId, timestamp, rawBody)
    }
  };
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
    return Promise.resolve();
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

    function onClose() {
      cleanup();
      resolve();
    }

    function onError(error) {
      cleanup();
      reject(error);
    }

    ws.on('close', onClose);
    ws.on('error', onError);
  });
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

async function postRawJSON(path, { headers = {}, body } = {}) {
  const rawBody = typeof body === 'string' ? body : JSON.stringify(body);
  const response = await fetch(`${baseURL}${path}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...headers
    },
    body: rawBody
  });

  const text = await response.text();
  return {
    status: response.status,
    json: text ? JSON.parse(text) : {}
  };
}

async function postSignedSendSMS(body) {
  const signed = signedHookHeaders(body);
  return postRawJSON('/api/hooks/supabase/send-sms', {
    headers: signed.headers,
    body: signed.rawBody
  });
}
