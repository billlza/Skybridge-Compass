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
process.env.MEDIA_RELAY_ENABLED = process.env.MEDIA_RELAY_ENABLED || 'false';
process.env.MEDIA_RELAY_EXTERNAL_HOST = process.env.MEDIA_RELAY_EXTERNAL_HOST || '203.0.113.10';
process.env.MEDIA_RELAY_EXTERNAL_UDP_PORT = process.env.MEDIA_RELAY_EXTERNAL_UDP_PORT || '3478';
process.env.MEDIA_RELAY_TOKEN_SECRET = process.env.MEDIA_RELAY_TOKEN_SECRET || 'integration-media-relay-token-secret';
process.env.MEDIA_RELAY_MAX_PACKET_BYTES = process.env.MEDIA_RELAY_MAX_PACKET_BYTES || '1200';
process.env.MAX_CHALLENGES_PER_DEVICE_PER_10M = process.env.MAX_CHALLENGES_PER_DEVICE_PER_10M || '200';
process.env.MAX_CHALLENGES_PER_USER_PER_10M = process.env.MAX_CHALLENGES_PER_USER_PER_10M || '200';
process.env.MAX_CHALLENGES_PER_IP_PER_10M = process.env.MAX_CHALLENGES_PER_IP_PER_10M || '400';
process.env.HTTP_CONTROL_RATE_LIMIT_PER_MIN = process.env.HTTP_CONTROL_RATE_LIMIT_PER_MIN || '1000';
process.env.HTTP_LOOKUP_RATE_LIMIT_PER_MIN = process.env.HTTP_LOOKUP_RATE_LIMIT_PER_MIN || '1000';
process.env.HTTP_TURN_RATE_LIMIT_PER_MIN = process.env.HTTP_TURN_RATE_LIMIT_PER_MIN || '1000';
process.env.HTTP_MEDIA_RATE_LIMIT_PER_MIN = process.env.HTTP_MEDIA_RATE_LIMIT_PER_MIN || '1000';
process.env.HTTP_ADMISSION_RATE_LIMIT_PER_MIN = process.env.HTTP_ADMISSION_RATE_LIMIT_PER_MIN || '1000';

const { createSignalingStateBackend } = require('../lib/signaling_state_backend');
const { verifySignedMediaLeaseToken } = require('../lib/media_relay');
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

test('media lease issues externally signed UDP relay tokens', async () => {
  const initiator = makeIdentityBinding('media-lease');
  const admissionLease = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);
  assert.equal(typeof sessionResponse.json.mediaAdmissionToken, 'string');

  const leaseResponse = await postJSON('/api/media/lease', {
    headers: {
      'X-SkyBridge-Media-Admission': sessionResponse.json.mediaAdmissionToken
    },
    body: {}
  });

  assert.equal(leaseResponse.status, 200);
  assert.equal(leaseResponse.json.mode, 'skybridge-pqc-media-v1');
  assert.deepEqual(leaseResponse.json.endpoint, {
    host: process.env.MEDIA_RELAY_EXTERNAL_HOST,
    port: Number(process.env.MEDIA_RELAY_EXTERNAL_UDP_PORT),
    protocol: 'udp'
  });
  assert.equal(leaseResponse.json.role, 'initiator');
  assert.equal(leaseResponse.json.sessionId, sessionResponse.json.sessionId);
  assert.equal(leaseResponse.json.maxPacketBytes, Number(process.env.MEDIA_RELAY_MAX_PACKET_BYTES));
  assert.equal(leaseResponse.json.bindMessage.type, 'bind');
  assert.equal(leaseResponse.json.bindMessage.leaseToken, leaseResponse.json.leaseToken);

  const verification = verifySignedMediaLeaseToken(leaseResponse.json.leaseToken, {
    secret: process.env.MEDIA_RELAY_TOKEN_SECRET
  });
  assert.equal(verification.ok, true);
  assert.equal(verification.lease.sessionId, sessionResponse.json.sessionId);
  assert.equal(verification.lease.role, 'initiator');
});

test('ICE candidate burst drops excess candidates without revoking session media authority', async () => {
  const initiator = makeIdentityBinding('ice-burst-initiator');
  const admissionLease = await issueAdmissionLease(initiator);
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

    const dropped = waitForWebSocketMessage(
      ws,
      (message) => message.error === 'ice_candidate_dropped',
      3_000
    );
    for (let i = 0; i < 45; i += 1) {
      ws.send(JSON.stringify({
        sessionId: sessionResponse.json.sessionId,
        from: initiator.deviceId,
        type: 'iceCandidate',
        payload: {
          candidate: `candidate:${i} 1 udp 2122260223 192.0.2.${i % 250} ${5000 + i} typ host`,
          sdpMid: '0'
        },
        sentAt: Math.floor(Date.now() / 1000)
      }));
    }

    const droppedMessage = await dropped;
    assert.equal(droppedMessage.sessionId, sessionResponse.json.sessionId);

    const sessionRecord = await signalingState.getConnection(sessionResponse.json.sessionId);
    assert.ok(sessionRecord, 'ICE burst must not delete the active WebRTC session');
    assert.equal(Boolean(sessionRecord.revokedAt), false);

    const leaseResponse = await postJSON('/api/media/lease', {
      headers: {
        'X-SkyBridge-Media-Admission': sessionResponse.json.mediaAdmissionToken
      },
      body: {}
    });
    assert.equal(leaseResponse.status, 200);
    assert.equal(leaseResponse.json.sessionId, sessionResponse.json.sessionId);
  } finally {
    ws.close();
    await waitForWebSocketClose(ws);
  }
});

test('media admission refresh replaces superseded role token', async () => {
  const initiator = makeIdentityBinding('media-refresh');
  const admissionLease = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);
  const oldMediaToken = sessionResponse.json.mediaAdmissionToken;
  assert.equal(typeof oldMediaToken, 'string');

  const refresh = await postJSON('/api/media/admission/refresh', {
    headers: {
      'X-SkyBridge-Session': sessionResponse.json.sessionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'initiator'
    }
  });

  assert.equal(refresh.status, 200);
  assert.equal(refresh.json.sessionId, sessionResponse.json.sessionId);
  assert.equal(refresh.json.role, 'initiator');
  assert.equal(typeof refresh.json.mediaAdmissionToken, 'string');
  assert.equal(typeof refresh.json.serverBuildFingerprint, 'string');
  assert.ok(refresh.json.serverBuildFingerprint.length > 0);
  assert.equal(refresh.json.supportsMediaAdmissionRefresh, true);
  assert.equal(typeof refresh.json.mediaTokenGeneration, 'string');
  assert.ok(refresh.json.mediaTokenGeneration.length > 0);
  assert.equal(refresh.json.mediaTokenRequestGeneration, refresh.json.mediaTokenGeneration);
  assert.equal(refresh.json.mediaTokenExpectedGeneration, refresh.json.mediaTokenGeneration);
  assert.equal(refresh.json.mediaTokenExpectedPresent, true);
  assert.notEqual(refresh.json.mediaAdmissionToken, oldMediaToken);

  const staleLease = await postJSON('/api/media/lease', {
    headers: {
      'X-SkyBridge-Media-Admission': oldMediaToken
    },
    body: {}
  });
  assert.equal(staleLease.status, 401);
  assert.equal(staleLease.json.error, 'media_admission_token_superseded');
  assert.equal(staleLease.json.mediaTokenRequestGeneration, tokenGeneration(oldMediaToken));
  assert.equal(staleLease.json.mediaTokenExpectedGeneration, refresh.json.mediaTokenGeneration);
  assert.equal(staleLease.json.mediaTokenExpectedPresent, true);

  const freshLease = await postJSON('/api/media/lease', {
    headers: {
      'X-SkyBridge-Media-Admission': refresh.json.mediaAdmissionToken
    },
    body: {}
  });
  assert.equal(freshLease.status, 200);
  assert.equal(freshLease.json.sessionId, sessionResponse.json.sessionId);
  assert.equal(typeof freshLease.json.serverBuildFingerprint, 'string');
  assert.ok(freshLease.json.serverBuildFingerprint.length > 0);
  assert.equal(freshLease.json.supportsMediaAdmissionRefresh, true);
  assert.equal(typeof freshLease.json.mediaTokenGeneration, 'string');
  assert.ok(freshLease.json.mediaTokenGeneration.length > 0);
  assert.equal(freshLease.json.mediaTokenGeneration, refresh.json.mediaTokenGeneration);
  assert.equal(freshLease.json.mediaTokenRequestGeneration, refresh.json.mediaTokenGeneration);
  assert.equal(freshLease.json.mediaTokenExpectedGeneration, refresh.json.mediaTokenGeneration);
  assert.equal(freshLease.json.mediaTokenExpectedPresent, true);
});

test('media lease diagnostics preserve session revocation reason after authority loss', async () => {
  const initiator = makeIdentityBinding('media-revoked-diagnostics');
  const admissionLease = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });
  assert.equal(sessionResponse.status, 200);

  await signalingState.updateConnection(sessionResponse.json.sessionId, (record) => {
    record.revokedAt = Date.now();
  });
  await signalingState.updateEphemeral(
    'media_admission_token',
    tokenHash(sessionResponse.json.mediaAdmissionToken),
    (record) => {
      record.state = 'revoked';
      record.revokedAt = Date.now();
      record.revokedReason = 'remote_kill';
    }
  );

  const lease = await postJSON('/api/media/lease', {
    headers: {
      'X-SkyBridge-Media-Admission': sessionResponse.json.mediaAdmissionToken
    },
    body: {}
  });
  assert.equal(lease.status, 401);
  assert.equal(lease.json.error, 'media_admission_token_superseded');
  assert.equal(lease.json.mediaTokenState, 'revoked');
  assert.equal(lease.json.mediaTokenRevokedReason, 'remote_kill');
  assert.equal(lease.json.rejectReason, 'remote_kill');
  assert.equal(lease.json.mediaTokenExpectedPresent, false);
  assert.equal(lease.json.mediaTokenSessionPresent, false);
});

test('media admission refresh is idempotent when client retries the same refresh', async () => {
  const initiator = makeIdentityBinding('media-refresh-idempotent');
  const admissionLease = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);
  const idempotencyKey = `media-refresh-${crypto.randomUUID()}`;
  const refreshBody = {
    sessionId: sessionResponse.json.sessionId,
    role: 'initiator'
  };
  const first = await postJSON('/api/media/admission/refresh', {
    headers: {
      'X-SkyBridge-Session': sessionResponse.json.sessionToken,
      'Idempotency-Key': idempotencyKey
    },
    body: refreshBody
  });
  const replay = await postJSON('/api/media/admission/refresh', {
    headers: {
      'X-SkyBridge-Session': sessionResponse.json.sessionToken,
      'Idempotency-Key': idempotencyKey
    },
    body: refreshBody
  });

  assert.equal(first.status, 200);
  assert.equal(replay.status, 200);
  assert.equal(replay.json.mediaAdmissionToken, first.json.mediaAdmissionToken);
  assert.equal(replay.json.mediaTokenGeneration, first.json.mediaTokenGeneration);

  const lease = await postJSON('/api/media/lease', {
    headers: {
      'X-SkyBridge-Media-Admission': first.json.mediaAdmissionToken
    },
    body: {}
  });
  assert.equal(lease.status, 200);
  assert.equal(lease.json.mediaTokenGeneration, first.json.mediaTokenGeneration);
});

test('media admission refresh endpoint rejects missing session token instead of 404', async () => {
  const response = await postJSON('/api/media/admission/refresh', {
    body: {
      sessionId: 'session-refresh-probe',
      role: 'initiator'
    }
  });

  assert.equal(response.status, 401);
  assert.equal(response.json.error, 'missing_session_token');
});

test('webrtc session refresh reauthenticates active initiator and rotates all role tokens', async () => {
  const initiator = makeIdentityBinding('session-refresh-valid');
  const admissionLease = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);
  const refreshAdmission = await issueAdmissionLease(initiator);
  const refresh = await postJSON('/api/webrtc/session/refresh', {
    headers: {
      'X-SkyBridge-Admission': refreshAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'initiator'
    }
  });

  assert.equal(refresh.status, 200);
  assert.equal(refresh.json.sessionId, sessionResponse.json.sessionId);
  assert.equal(refresh.json.role, 'initiator');
  assert.equal(typeof refresh.json.sessionToken, 'string');
  assert.equal(typeof refresh.json.turnAdmissionToken, 'string');
  assert.equal(typeof refresh.json.mediaAdmissionToken, 'string');
  assert.equal(typeof refresh.json.serverBuildFingerprint, 'string');
  assert.equal(refresh.json.supportsSessionRefresh, true);
  assert.equal(typeof refresh.json.sessionTokenGeneration, 'string');
  assert.equal(typeof refresh.json.mediaTokenGeneration, 'string');
  assert.notEqual(refresh.json.sessionToken, sessionResponse.json.sessionToken);
  assert.notEqual(refresh.json.turnAdmissionToken, sessionResponse.json.turnAdmissionToken);
  assert.notEqual(refresh.json.mediaAdmissionToken, sessionResponse.json.mediaAdmissionToken);

  const staleMediaLease = await postJSON('/api/media/lease', {
    headers: {
      'X-SkyBridge-Media-Admission': sessionResponse.json.mediaAdmissionToken
    },
    body: {}
  });
  assert.equal(staleMediaLease.status, 401);
  assert.equal(staleMediaLease.json.error, 'media_admission_token_superseded');

  const freshMediaLease = await postJSON('/api/media/lease', {
    headers: {
      'X-SkyBridge-Media-Admission': refresh.json.mediaAdmissionToken
    },
    body: {}
  });
  assert.equal(freshMediaLease.status, 200);
  assert.equal(freshMediaLease.json.sessionId, sessionResponse.json.sessionId);

  const turnResponse = await fetch(`${baseURL}/api/turn/credentials`, {
    method: 'GET',
    headers: {
      'Accept': 'application/json',
      'X-SkyBridge-Turn-Admission': refresh.json.turnAdmissionToken
    }
  });
  assert.equal(turnResponse.status, 200);
});

test('webrtc session refresh rejects scope device and role mismatches', async () => {
  const initiator = makeIdentityBinding('session-refresh-owner');
  const admissionLease = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);

  const wrongRoleAdmission = await issueAdmissionLease(initiator);
  const wrongRole = await postJSON('/api/webrtc/session/refresh', {
    headers: {
      'X-SkyBridge-Admission': wrongRoleAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'responder'
    }
  });
  assert.equal(wrongRole.status, 403);
  assert.equal(wrongRole.json.error, 'session_scope_mismatch');

  const otherDevice = makeIdentityBinding('session-refresh-other-device');
  const otherDeviceAdmission = await issueAdmissionLease(otherDevice);
  const wrongDevice = await postJSON('/api/webrtc/session/refresh', {
    headers: {
      'X-SkyBridge-Admission': otherDeviceAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'initiator'
    }
  });
  assert.equal(wrongDevice.status, 403);
  assert.equal(wrongDevice.json.error, 'session_scope_mismatch');

  const otherUser = makeIdentityBinding('session-refresh-other-user');
  const otherUserAdmission = await issueAdmissionLease(otherUser, {
    accessToken: sameTenantOtherUserBearerToken
  });
  const wrongScope = await postJSON('/api/webrtc/session/refresh', {
    headers: {
      'X-SkyBridge-Admission': otherUserAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'initiator'
    }
  });
  assert.equal(wrongScope.status, 403);
  assert.equal(wrongScope.json.error, 'session_scope_mismatch');
});

test('webrtc session refresh rejects inactive sessions', async () => {
  const initiator = makeIdentityBinding('session-refresh-inactive');
  const admissionLease = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);
  await signalingState.updateConnection(sessionResponse.json.sessionId, (record) => {
    record.revokedAt = Date.now();
  });

  const refreshAdmission = await issueAdmissionLease(initiator);
  const refresh = await postJSON('/api/webrtc/session/refresh', {
    headers: {
      'X-SkyBridge-Admission': refreshAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'initiator'
    }
  });

  assert.equal(refresh.status, 403);
  assert.equal(refresh.json.error, 'session_inactive');
});

test('redeemed session refresh and media lease survive rendezvous expiry while active', async () => {
  const initiator = makeIdentityBinding('active-session-initiator');
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

  const responder = makeIdentityBinding('active-session-responder');
  const responderAdmission = await issueAdmissionLease(responder);
  const redeemed = await postJSON('/api/webrtc/redeem-session', {
    headers: {
      'X-SkyBridge-Admission': responderAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      qrBootstrapToken: sessionResponse.json.qrBootstrapToken
    }
  });
  assert.equal(redeemed.status, 200);

  await signalingState.updateConnection(sessionResponse.json.sessionId, (record) => {
    record.rendezvousExpiresAt = Date.now() - 1_000;
    record.activeUntil = Date.now() + 120_000;
    record.expiresAt = record.activeUntil;
  });

  const refreshAdmission = await issueAdmissionLease(responder);
  const refresh = await postJSON('/api/webrtc/session/refresh', {
    headers: {
      'X-SkyBridge-Admission': refreshAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'responder'
    }
  });
  assert.equal(refresh.status, 200);
  assert.equal(refresh.json.role, 'responder');
  assert.equal(typeof refresh.json.mediaAdmissionToken, 'string');

  const lease = await postJSON('/api/media/lease', {
    headers: {
      'X-SkyBridge-Media-Admission': refresh.json.mediaAdmissionToken
    },
    body: {}
  });
  assert.equal(lease.status, 200);
  assert.equal(lease.json.sessionId, sessionResponse.json.sessionId);
  assert.equal(lease.json.role, 'responder');
});

test('unredeemed expired rendezvous cannot be redeemed even if active TTL remains', async () => {
  const initiator = makeIdentityBinding('expired-rendezvous-initiator');
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

  await signalingState.updateConnection(sessionResponse.json.sessionId, (record) => {
    record.rendezvousExpiresAt = Date.now() - 1_000;
    record.activeUntil = Date.now() + 120_000;
    record.expiresAt = record.activeUntil;
  });

  const responder = makeIdentityBinding('expired-rendezvous-responder');
  const responderAdmission = await issueAdmissionLease(responder);
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

test('duplicate responder redeem conflicts without rotating active tokens', async () => {
  const initiator = makeIdentityBinding('duplicate-responder-initiator');
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

  const responder = makeIdentityBinding('duplicate-responder');
  const responderAdmission = await issueAdmissionLease(responder);
  const first = await postJSON('/api/webrtc/redeem-session', {
    headers: {
      'X-SkyBridge-Admission': responderAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      qrBootstrapToken: sessionResponse.json.qrBootstrapToken
    }
  });

  assert.equal(first.status, 200);
  assert.equal(typeof first.json.sessionToken, 'string');

  const duplicateAdmission = await issueAdmissionLease(responder);
  const duplicate = await postJSON('/api/webrtc/redeem-session', {
    headers: {
      'X-SkyBridge-Admission': duplicateAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      qrBootstrapToken: sessionResponse.json.qrBootstrapToken
    }
  });

  assert.equal(duplicate.status, 409);
  assert.equal(duplicate.json.error, 'responder_already_bound');

  const stillCurrent = await postJSON('/api/media/admission/refresh', {
    headers: {
      'X-SkyBridge-Session': first.json.sessionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'responder'
    }
  });
  assert.equal(stillCurrent.status, 200);
  assert.equal(stillCurrent.json.sessionId, sessionResponse.json.sessionId);
  assert.equal(stillCurrent.json.role, 'responder');
});

test('duplicate responder lookup conflicts without rotating active tokens', async () => {
  const initiator = makeIdentityBinding('duplicate-lookup-initiator');
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

  const responder = makeIdentityBinding('duplicate-lookup-responder');
  const responderAdmission = await issueAdmissionLease(responder);
  const first = await getJSON(`/api/webrtc/lookup/${codeResponse.json.code}`, {
    headers: {
      'X-SkyBridge-Admission': responderAdmission.admissionToken
    }
  });

  assert.equal(first.status, 200);
  assert.equal(first.json.found, true);
  assert.equal(typeof first.json.sessionToken, 'string');

  const duplicateAdmission = await issueAdmissionLease(responder);
  const duplicate = await getJSON(`/api/webrtc/lookup/${codeResponse.json.code}`, {
    headers: {
      'X-SkyBridge-Admission': duplicateAdmission.admissionToken
    }
  });

  assert.equal(duplicate.status, 409);
  assert.equal(duplicate.json.error, 'responder_already_bound');

  const stillCurrent = await postJSON('/api/media/admission/refresh', {
    headers: {
      'X-SkyBridge-Session': first.json.sessionToken
    },
    body: {
      sessionId: codeResponse.json.sessionId,
      role: 'responder'
    }
  });
  assert.equal(stillCurrent.status, 200);
  assert.equal(stillCurrent.json.sessionId, codeResponse.json.sessionId);
  assert.equal(stillCurrent.json.role, 'responder');
});

test('old session token cannot refresh media admission after webrtc session refresh', async () => {
  const initiator = makeIdentityBinding('session-refresh-old-token');
  const admissionLease = await issueAdmissionLease(initiator);
  const sessionResponse = await postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  });

  assert.equal(sessionResponse.status, 200);

  const refreshAdmission = await issueAdmissionLease(initiator);
  const refresh = await postJSON('/api/webrtc/session/refresh', {
    headers: {
      'X-SkyBridge-Admission': refreshAdmission.admissionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'initiator'
    }
  });
  assert.equal(refresh.status, 200);

  const oldSessionTokenRefresh = await postJSON('/api/media/admission/refresh', {
    headers: {
      'X-SkyBridge-Session': sessionResponse.json.sessionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'initiator'
    }
  });
  assert.equal(oldSessionTokenRefresh.status, 401);
  assert.equal(oldSessionTokenRefresh.json.error, 'session_token_superseded');
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
  assert.equal(typeof ready.json.serverBuildFingerprint, 'string');
  assert.ok(ready.json.serverBuildFingerprint.length > 0);
  assert.equal(ready.json.supportsMediaAdmissionRefresh, true);

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
    assert.equal(typeof health.json.serverBuildFingerprint, 'string');
    assert.equal(health.json.supportsMediaAdmissionRefresh, true);

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

function tokenGeneration(token) {
  return tokenHash(token).slice(0, 16);
}

function tokenHash(token) {
  return crypto.createHash('sha256').update(String(token || '')).digest('hex');
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
