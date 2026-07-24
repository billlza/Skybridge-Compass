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
process.env.SKYBRIDGE_SIGNALING_WEBSOCKET_PATH = process.env.SKYBRIDGE_SIGNALING_WEBSOCKET_PATH || '/current-path/ws';
process.env.SKYBRIDGE_SIGNALING_ALLOW_LEGACY_QUERY_TOKEN = 'false';
const expectedSignalingWebSocketPath = process.env.SKYBRIDGE_SIGNALING_WEBSOCKET_PATH;

const { createSignalingStateBackend } = require('../lib/signaling_state_backend');
const { verifySignedMediaLeaseToken } = require('../lib/media_relay');
const {
  createRuntime,
  __test: {
    assertSupportedNodeRuntime,
    buildIdentityRotationTranscript,
    classifySMSDeliveryFailure,
    collectSMSServiceSnapshot,
    computeProtocolIdentityFingerprint,
    evaluateServiceHealth,
    validateJoinIdentityAgainstSession,
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

function fakeRegistryError(code, status = 409) {
  const error = new Error(`registry_http_${status}:${code}`);
  error.registryStatus = status;
  error.registryCode = code;
  return error;
}

function copyJSON(value) {
  return JSON.parse(JSON.stringify(value));
}

class FakeRegistryStore {
  constructor() {
    this.configured = true;
    this.syntheticOnlyDeviceIds = new Set();
    this.bootstrapCalls = [];
    this.identityRotationChallengeCalls = [];
    this.identityRotationCommitCalls = [];
    this.devices = new Map();
    this.identityOwners = new Map();
    this.identityRotations = new Map();
    this.rotationByRequest = new Map();
    this.identityHistory = [];
    this.nextCommitFailure = null;
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

  async getRegisteredDevice({
    tenantId: requestedTenantId,
    userId: requestedUserId,
    deviceId,
    protocolSigningAlgorithm,
    protocolPublicKeyFingerprint
  }) {
    assert.ok(this.allowedTenantIds.has(requestedTenantId), `unexpected device lookup tenant: ${requestedTenantId}`);
    assert.ok(
      [...this.sessionsByAccessToken.values()].some((session) => session.userId === requestedUserId),
      `unexpected device lookup user: ${requestedUserId}`
    );
    if (this.syntheticOnlyDeviceIds.has(deviceId)) {
      return null;
    }
    const key = this.deviceKey(requestedTenantId, requestedUserId, deviceId);
    let record = this.devices.get(key);
    if (!record) {
      record = {
        tenant_id: requestedTenantId,
        user_id: requestedUserId,
        device_id: deviceId,
        protocol_signing_algorithm: protocolSigningAlgorithm,
        protocol_public_key_fingerprint: protocolPublicKeyFingerprint,
        protocol_public_key_base64: null,
        identity_generation: 1,
        status: 'active'
      };
      this.devices.set(key, record);
      this.identityOwners.set(
        this.identityKey(requestedTenantId, protocolSigningAlgorithm, protocolPublicKeyFingerprint),
        key
      );
    }
    if (
      record.protocol_signing_algorithm !== protocolSigningAlgorithm
      || record.protocol_public_key_fingerprint !== protocolPublicKeyFingerprint
    ) {
      const retained = this.identityHistory.find((entry) => (
        entry.deviceKey === key
        && entry.algorithm === protocolSigningAlgorithm
        && entry.fingerprint === protocolPublicKeyFingerprint
        && ['grace', 'revoked'].includes(entry.state)
      ));
      if (retained) {
        return {
          tenant_id: requestedTenantId,
          user_id: requestedUserId,
          device_id: deviceId,
          protocol_signing_algorithm: retained.algorithm,
          protocol_public_key_fingerprint: retained.fingerprint,
          identity_generation: retained.generation,
          status: retained.state,
          identity_history: true
        };
      }
      return null;
    }
    return copyJSON(record);
  }

  deviceKey(requestedTenantId, requestedUserId, deviceId) {
    return `${requestedTenantId}:${requestedUserId}:${deviceId}`;
  }

  identityKey(requestedTenantId, algorithm, fingerprint) {
    return `${requestedTenantId}:${algorithm}:${fingerprint}`;
  }

  setDeviceStatus(binding, status, {
    requestedTenantId = tenantId,
    requestedUserId = userId
  } = {}) {
    const key = this.deviceKey(requestedTenantId, requestedUserId, binding.deviceId);
    const record = this.devices.get(key) || {
      tenant_id: requestedTenantId,
      user_id: requestedUserId,
      device_id: binding.deviceId,
      protocol_signing_algorithm: binding.protocolSigningAlgorithm,
      protocol_public_key_fingerprint: binding.protocolPublicKeyFingerprint,
      protocol_public_key_base64: binding.protocolPublicKeyBytes?.toString('base64') || null,
      identity_generation: 1
    };
    record.status = status;
    this.devices.set(key, record);
    this.identityOwners.set(
      this.identityKey(
        requestedTenantId,
        binding.protocolSigningAlgorithm,
        binding.protocolPublicKeyFingerprint
      ),
      key
    );
  }

  claimIdentity(binding, {
    requestedTenantId = tenantId,
    requestedUserId = userId,
    ownerDeviceId = `identity-owner-${crypto.randomUUID()}`
  } = {}) {
    this.identityOwners.set(
      this.identityKey(
        requestedTenantId,
        binding.protocolSigningAlgorithm,
        binding.protocolPublicKeyFingerprint
      ),
      this.deviceKey(requestedTenantId, requestedUserId, ownerDeviceId)
    );
  }

  registeredDevice(binding, {
    requestedTenantId = tenantId,
    requestedUserId = userId
  } = {}) {
    return this.devices.get(this.deviceKey(requestedTenantId, requestedUserId, binding.deviceId)) || null;
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

  async issueIdentityRotationChallenge(payload) {
    this.identityRotationChallengeCalls.push(copyJSON(payload));
    const deviceKey = this.deviceKey(payload.p_tenant_id, payload.p_user_id, payload.p_device_id);
    const device = this.devices.get(deviceKey);
    if (!device) throw fakeRegistryError('device_not_registered', 403);
    if (device.status === 'frozen') throw fakeRegistryError('device_frozen', 403);
    if (device.status === 'revoked') throw fakeRegistryError('device_revoked', 403);
    if (device.status !== 'active') throw fakeRegistryError('device_not_active', 403);
    if (device.identity_generation !== payload.p_old_generation) {
      throw fakeRegistryError('identity_generation_conflict');
    }
    if (
      device.protocol_signing_algorithm !== payload.p_old_protocol_signing_algorithm
      || device.protocol_public_key_fingerprint !== payload.p_old_protocol_public_key_fingerprint
    ) {
      throw fakeRegistryError('current_identity_mismatch');
    }
    if (
      device.protocol_public_key_base64
      && device.protocol_public_key_base64 !== payload.p_old_protocol_public_key_base64
    ) {
      throw fakeRegistryError('old_public_key_conflict');
    }

    const requestKey = `${deviceKey}:${payload.p_request_id}`;
    const existingRotationId = this.rotationByRequest.get(requestKey);
    if (existingRotationId) {
      const existing = this.identityRotations.get(existingRotationId);
      const fields = [
        'p_old_generation',
        'p_old_protocol_signing_algorithm',
        'p_old_protocol_public_key_fingerprint',
        'p_old_protocol_public_key_base64',
        'p_new_protocol_signing_algorithm',
        'p_new_protocol_public_key_fingerprint',
        'p_new_protocol_public_key_base64'
      ];
      const matches = fields.every((field) => {
        const storedField = field.replace(/^p_/, '');
        return existing[storedField] === payload[field];
      });
      if (!matches) throw fakeRegistryError('rotation_payload_conflict');
      if (existing.state === 'expired' || Date.parse(existing.expires_at) <= Date.now()) {
        throw fakeRegistryError('rotation_expired', 410);
      }
      if (existing.state !== 'issued') throw fakeRegistryError('rotation_state_conflict');
      return copyJSON(existing);
    }

    for (const rotation of this.identityRotations.values()) {
      if (
        rotation.tenant_id === payload.p_tenant_id
        && rotation.new_protocol_signing_algorithm === payload.p_new_protocol_signing_algorithm
        && rotation.new_protocol_public_key_fingerprint === payload.p_new_protocol_public_key_fingerprint
        && rotation.state === 'issued'
        && Date.parse(rotation.expires_at) <= Date.now()
      ) {
        rotation.state = 'expired';
      }
    }

    const pending = [...this.identityRotations.values()].find((rotation) => (
      rotation.tenant_id === payload.p_tenant_id
      && rotation.user_id === payload.p_user_id
      && rotation.device_id === payload.p_device_id
      && rotation.state === 'issued'
      && Date.parse(rotation.expires_at) > Date.now()
    ));
    if (pending) throw fakeRegistryError('identity_rotation_already_pending');
    const newIdentityKey = this.identityKey(
      payload.p_tenant_id,
      payload.p_new_protocol_signing_algorithm,
      payload.p_new_protocol_public_key_fingerprint
    );
    if (this.identityOwners.has(newIdentityKey)) {
      throw fakeRegistryError('new_identity_already_owned');
    }
    const pendingNewIdentity = [...this.identityRotations.values()].some((rotation) => (
      rotation.tenant_id === payload.p_tenant_id
      && rotation.new_protocol_signing_algorithm === payload.p_new_protocol_signing_algorithm
      && rotation.new_protocol_public_key_fingerprint === payload.p_new_protocol_public_key_fingerprint
      && rotation.state === 'issued'
      && Date.parse(rotation.expires_at) > Date.now()
    ));
    if (pendingNewIdentity) throw fakeRegistryError('new_identity_already_owned');

    const issuedAt = new Date().toISOString();
    const rotation = {
      rotation_id: payload.p_rotation_id,
      request_id: payload.p_request_id,
      tenant_id: payload.p_tenant_id,
      user_id: payload.p_user_id,
      device_id: payload.p_device_id,
      old_generation: payload.p_old_generation,
      old_protocol_signing_algorithm: payload.p_old_protocol_signing_algorithm,
      old_protocol_public_key_fingerprint: payload.p_old_protocol_public_key_fingerprint,
      old_protocol_public_key_base64: payload.p_old_protocol_public_key_base64,
      new_protocol_signing_algorithm: payload.p_new_protocol_signing_algorithm,
      new_protocol_public_key_fingerprint: payload.p_new_protocol_public_key_fingerprint,
      new_protocol_public_key_base64: payload.p_new_protocol_public_key_base64,
      nonce: payload.p_nonce,
      transcript_hash: payload.p_transcript_hash,
      state: 'issued',
      issued_at: issuedAt,
      expires_at: payload.p_expires_at,
      committed_at: null,
      committed_generation: null,
      grace_expires_at: null,
      result: null
    };
    device.protocol_public_key_base64 = payload.p_old_protocol_public_key_base64;
    if (!this.identityHistory.some((entry) => entry.deviceKey === deviceKey && entry.state === 'active')) {
      this.identityHistory.push({
        deviceKey,
        generation: payload.p_old_generation,
        algorithm: payload.p_old_protocol_signing_algorithm,
        fingerprint: payload.p_old_protocol_public_key_fingerprint,
        publicKeyBase64: payload.p_old_protocol_public_key_base64,
        state: 'active'
      });
    }
    this.identityRotations.set(rotation.rotation_id, rotation);
    this.rotationByRequest.set(requestKey, rotation.rotation_id);
    return copyJSON(rotation);
  }

  async getIdentityRotation({
    tenantId: requestedTenantId,
    userId: requestedUserId,
    deviceId,
    rotationId,
    oldProtocolSigningAlgorithm,
    oldProtocolPublicKeyFingerprint
  }) {
    const rotation = this.identityRotations.get(rotationId);
    if (
      !rotation
      || rotation.tenant_id !== requestedTenantId
      || rotation.user_id !== requestedUserId
      || rotation.device_id !== deviceId
      || rotation.old_protocol_signing_algorithm !== oldProtocolSigningAlgorithm
      || rotation.old_protocol_public_key_fingerprint !== oldProtocolPublicKeyFingerprint
    ) {
      return null;
    }
    return copyJSON(rotation);
  }

  async getIdentityRotationByRequestId({
    tenantId: requestedTenantId,
    userId: requestedUserId,
    deviceId,
    requestId,
    oldProtocolSigningAlgorithm,
    oldProtocolPublicKeyFingerprint
  }) {
    const requestKey = `${this.deviceKey(requestedTenantId, requestedUserId, deviceId)}:${requestId}`;
    const rotationId = this.rotationByRequest.get(requestKey);
    const rotation = rotationId ? this.identityRotations.get(rotationId) : null;
    if (
      !rotation
      || rotation.old_protocol_signing_algorithm !== oldProtocolSigningAlgorithm
      || rotation.old_protocol_public_key_fingerprint !== oldProtocolPublicKeyFingerprint
    ) {
      return null;
    }
    return { rotation_id: rotation.rotation_id };
  }

  async commitIdentityRotation(payload) {
    this.identityRotationCommitCalls.push(copyJSON(payload));
    if (this.nextCommitFailure === 'before') {
      this.nextCommitFailure = null;
      throw new Error('simulated_rotation_rpc_failure');
    }
    const rotation = this.identityRotations.get(payload.p_rotation_id);
    if (
      !rotation
      || rotation.tenant_id !== payload.p_tenant_id
      || rotation.user_id !== payload.p_user_id
      || rotation.device_id !== payload.p_device_id
      || rotation.old_generation !== payload.p_old_generation
      || rotation.old_protocol_signing_algorithm !== payload.p_old_protocol_signing_algorithm
      || rotation.old_protocol_public_key_fingerprint !== payload.p_old_protocol_public_key_fingerprint
    ) {
      throw fakeRegistryError('rotation_not_found', 404);
    }
    if (rotation.transcript_hash !== payload.p_transcript_hash) {
      throw fakeRegistryError('rotation_payload_conflict');
    }
    if (rotation.state === 'committed') return copyJSON(rotation.result);
    if (rotation.state !== 'issued') throw fakeRegistryError('rotation_state_conflict');
    if (Date.parse(rotation.expires_at) <= Date.now()) throw fakeRegistryError('rotation_expired', 410);

    const deviceKey = this.deviceKey(rotation.tenant_id, rotation.user_id, rotation.device_id);
    const device = this.devices.get(deviceKey);
    if (!device) throw fakeRegistryError('device_not_registered', 403);
    if (device.status === 'frozen') throw fakeRegistryError('device_frozen', 403);
    if (device.status === 'revoked') throw fakeRegistryError('device_revoked', 403);
    if (device.status !== 'active') throw fakeRegistryError('device_not_active', 403);
    if (device.identity_generation !== rotation.old_generation) {
      throw fakeRegistryError('identity_generation_conflict');
    }
    if (
      device.protocol_signing_algorithm !== rotation.old_protocol_signing_algorithm
      || device.protocol_public_key_fingerprint !== rotation.old_protocol_public_key_fingerprint
      || device.protocol_public_key_base64 !== rotation.old_protocol_public_key_base64
    ) {
      throw fakeRegistryError('current_identity_mismatch');
    }
    const newIdentityKey = this.identityKey(
      rotation.tenant_id,
      rotation.new_protocol_signing_algorithm,
      rotation.new_protocol_public_key_fingerprint
    );
    const existingOwner = this.identityOwners.get(newIdentityKey);
    if (existingOwner && existingOwner !== deviceKey) {
      throw fakeRegistryError('new_identity_already_owned');
    }

    const committedAt = new Date().toISOString();
    const generation = rotation.old_generation + 1;
    const oldHistory = this.identityHistory.find((entry) => (
      entry.deviceKey === deviceKey
      && entry.generation === rotation.old_generation
      && entry.state === 'active'
    ));
    assert.ok(oldHistory, 'fake store requires an active old identity history entry');
    oldHistory.state = 'grace';
    oldHistory.graceExpiresAt = payload.p_grace_expires_at;
    this.identityHistory.push({
      deviceKey,
      generation,
      algorithm: rotation.new_protocol_signing_algorithm,
      fingerprint: rotation.new_protocol_public_key_fingerprint,
      publicKeyBase64: rotation.new_protocol_public_key_base64,
      state: 'active'
    });
    device.protocol_signing_algorithm = rotation.new_protocol_signing_algorithm;
    device.protocol_public_key_fingerprint = rotation.new_protocol_public_key_fingerprint;
    device.protocol_public_key_base64 = rotation.new_protocol_public_key_base64;
    device.identity_generation = generation;
    this.identityOwners.set(newIdentityKey, deviceKey);
    rotation.state = 'committed';
    rotation.committed_at = committedAt;
    rotation.committed_generation = generation;
    rotation.grace_expires_at = payload.p_grace_expires_at;
    rotation.result = {
      rotation_id: rotation.rotation_id,
      state: 'committed',
      committed_at: committedAt,
      generation,
      grace_expires_at: payload.p_grace_expires_at
    };
    if (this.nextCommitFailure === 'after') {
      this.nextCommitFailure = null;
      throw new Error('simulated_rotation_rpc_response_loss');
    }
    return copyJSON(rotation.result);
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
    allowLegacyQueryToken: false,
    port: 0,
    host: '127.0.0.1'
  });

  const address = await runtime.start();
  baseURL = `http://127.0.0.1:${address.port}`;
});

beforeEach(() => {
  fakeSMSClient.reset();
  if (registryStore) {
    registryStore.nextCommitFailure = null;
  }
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
  assert.equal(first.json.wsPath, expectedSignalingWebSocketPath);

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

test('session lifecycle logs redact raw session identifiers', async () => {
  const initiator = makeIdentityBinding('session-log-redaction');
  const admissionLease = await issueAdmissionLease(initiator);
  const { result: sessionResponse, messages } = await captureConsoleMessages(['info'], () => postJSON('/api/webrtc/register-session', {
    headers: {
      'X-SkyBridge-Admission': admissionLease.admissionToken
    },
    body: {
      ttlSeconds: 120
    }
  }));

  assert.equal(sessionResponse.status, 200);
  assert.equal(typeof sessionResponse.json.sessionId, 'string');
  assertSessionRedactedInLog(messages, sessionResponse.json.sessionId, 'sessionLifecycle=registered');
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
  assert.equal(first.json.wsPath, expectedSignalingWebSocketPath);

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
  assert.equal(leaseResponse.json.peer, undefined);
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
    `${baseURL.replace(/^http/, 'ws')}${expectedSignalingWebSocketPath}?shard=${encodeURIComponent(sessionResponse.json.sessionId)}`,
    {
      headers: {
        'X-SkyBridge-Session-Id': sessionResponse.json.sessionId,
        'X-SkyBridge-Session': sessionResponse.json.sessionToken
      }
    }
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

test('websocket bind rejects legacy query session token by default', async () => {
  const initiator = makeIdentityBinding('ws-query-auth-disabled');
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
    `${baseURL.replace(/^http/, 'ws')}${expectedSignalingWebSocketPath}?shard=${encodeURIComponent(sessionResponse.json.sessionId)}&st=${encodeURIComponent(sessionResponse.json.sessionToken)}`
  );
  const close = await waitForWebSocketClose(ws);
  assert.equal(close.code, 1008);
  assert.equal(close.reason, 'legacy_query_token_disabled');
});

test('websocket bind accepts header session token without putting token in the URL', async () => {
  const initiator = makeIdentityBinding('ws-header-auth');
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

  const wsURL = `${baseURL.replace(/^http/, 'ws')}${expectedSignalingWebSocketPath}?shard=${encodeURIComponent(sessionResponse.json.sessionId)}&cv=1.2.3&pv=2`;
  assert.equal(wsURL.includes(sessionResponse.json.sessionToken), false);

  const ws = new WebSocket(wsURL, {
    headers: {
      'X-SkyBridge-Session-Id': sessionResponse.json.sessionId,
      'X-SkyBridge-Session': sessionResponse.json.sessionToken,
      'X-SkyBridge-Client-Version': '1.2.3',
      'X-SkyBridge-Protocol-Version': '2'
    }
  });
  try {
    const bound = await waitForWebSocketMessage(ws, (message) => message.type === 'bound');
    assert.equal(bound.sessionId, sessionResponse.json.sessionId);
    assert.equal(bound.role, 'initiator');
  } finally {
    ws.close();
    await waitForWebSocketClose(ws);
  }
});

test('websocket join rejects an identity different from the admission-bound authority', async () => {
  const admitted = makeIdentityBinding('ws-join-admitted', 'ML-DSA-87');
  const alternate = makeIdentityBinding('ws-join-alternate', 'ML-DSA-87');
  const admissionLease = await issueAdmissionLease(admitted);
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
    `${baseURL.replace(/^http/, 'ws')}${expectedSignalingWebSocketPath}?shard=${encodeURIComponent(sessionResponse.json.sessionId)}`,
    {
      headers: {
        'X-SkyBridge-Session-Id': sessionResponse.json.sessionId,
        'X-SkyBridge-Session': sessionResponse.json.sessionToken
      }
    }
  );
  const bound = await waitForWebSocketMessage(ws, (message) => message.type === 'bound');
  assert.equal(bound.sessionId, sessionResponse.json.sessionId);

  const closePromise = waitForWebSocketClose(ws);
  ws.send(JSON.stringify({
    sessionId: sessionResponse.json.sessionId,
    from: admitted.deviceId,
    type: 'join',
    payload: {
      protocolSigningAlgorithm: alternate.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: alternate.protocolPublicKeyFingerprint,
      protocolPublicKeyBytes: alternate.protocolPublicKeyBytes.toString('base64')
    },
    sentAt: Math.floor(Date.now() / 1000)
  }));

  const close = await closePromise;
  assert.equal(close.code, 1008);
  assert.equal(close.reason, 'join_identity_scope_violation');
});

test('websocket bind rejects mixed header and legacy query session tokens', async () => {
  const initiator = makeIdentityBinding('ws-conflicting-auth');
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
    `${baseURL.replace(/^http/, 'ws')}${expectedSignalingWebSocketPath}?shard=${encodeURIComponent(sessionResponse.json.sessionId)}&st=${encodeURIComponent(sessionResponse.json.sessionToken)}`,
    {
      headers: {
        'X-SkyBridge-Session-Id': sessionResponse.json.sessionId,
        'X-SkyBridge-Session': sessionResponse.json.sessionToken
      }
    }
  );
  const close = await waitForWebSocketClose(ws);
  assert.equal(close.code, 1008);
  assert.equal(close.reason, 'conflicting_session_credentials');
});

test('websocket bind rejects empty legacy query token when header credentials are present', async () => {
  const initiator = makeIdentityBinding('ws-empty-query-auth');
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
    `${baseURL.replace(/^http/, 'ws')}${expectedSignalingWebSocketPath}?shard=${encodeURIComponent(sessionResponse.json.sessionId)}&st=`,
    {
      headers: {
        'X-SkyBridge-Session-Id': sessionResponse.json.sessionId,
        'X-SkyBridge-Session': sessionResponse.json.sessionToken
      }
    }
  );
  const close = await waitForWebSocketClose(ws);
  assert.equal(close.code, 1008);
  assert.equal(close.reason, 'conflicting_session_credentials');
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

  const { result: refresh, messages: refreshLogMessages } = await captureConsoleMessages(['info', 'log'], () => postJSON('/api/media/admission/refresh', {
    headers: {
      'X-SkyBridge-Session': sessionResponse.json.sessionToken
    },
    body: {
      sessionId: sessionResponse.json.sessionId,
      role: 'initiator'
    }
  }));

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
  assertSessionRedactedInLog(refreshLogMessages, sessionResponse.json.sessionId, 'sessionLifecycle=activeExtended');
  assertSessionRedactedInLog(refreshLogMessages, sessionResponse.json.sessionId, '[media] admission refresh accepted');

  const { result: staleLease, messages: staleLeaseLogMessages } = await captureConsoleMessages(['warn'], () => postJSON('/api/media/lease', {
    headers: {
      'X-SkyBridge-Media-Admission': oldMediaToken
    },
    body: {}
  }));
  assert.equal(staleLease.status, 401);
  assert.equal(staleLease.json.error, 'media_admission_token_superseded');
  assert.equal(staleLease.json.mediaTokenRequestGeneration, tokenGeneration(oldMediaToken));
  assert.equal(staleLease.json.mediaTokenExpectedGeneration, refresh.json.mediaTokenGeneration);
  assert.equal(staleLease.json.mediaTokenExpectedPresent, true);
  assertSessionRedactedInLog(staleLeaseLogMessages, sessionResponse.json.sessionId, '[media] admission token superseded before lease');

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
  assert.equal(refresh.json.wsPath, expectedSignalingWebSocketPath);
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
  assert.equal(codeResponse.json.wsPath, expectedSignalingWebSocketPath);

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
  assert.equal(first.json.wsPath, expectedSignalingWebSocketPath);

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
    `${baseURL.replace(/^http/, 'ws')}${expectedSignalingWebSocketPath}?shard=${encodeURIComponent(sessionResponse.json.sessionId)}`,
    {
      headers: {
        'X-SkyBridge-Session-Id': sessionResponse.json.sessionId,
        'X-SkyBridge-Session': sessionResponse.json.sessionToken
      }
    }
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

  if (algorithm === 'ML-DSA-65' || algorithm === 'ML-DSA-87') {
    const nodeKeyType = algorithm === 'ML-DSA-65' ? 'ml-dsa-65' : 'ml-dsa-87';
    const publicKeyBytes = algorithm === 'ML-DSA-65' ? 1952 : 2592;
    ({ publicKey, privateKey } = crypto.generateKeyPairSync(nodeKeyType));
    const publicKeyDer = publicKey.export({ type: 'spki', format: 'der' });
    rawPublicKey = publicKeyDer.subarray(publicKeyDer.length - publicKeyBytes);
    protocolSigningAlgorithm = algorithm;
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
    protocolPublicKeyFingerprint: computeProtocolIdentityFingerprint(
      protocolSigningAlgorithm,
      rawPublicKey
    ),
    privateKey
  };
}

test('protocol identity fingerprints match the Swift canonical cross-platform vectors', () => {
  const vectors = [
    {
      algorithm: 'Ed25519',
      publicKey: Buffer.from(Array.from({ length: 32 }, (_, index) => index)),
      expected: '09d14ebcd4f85644dbb1957e4b5bcf4501953e8ff2a96a6debcc1c9e5ef25de6'
    },
    {
      algorithm: 'ML-DSA-65',
      publicKey: Buffer.alloc(1952, 0x65),
      expected: '1fdfd364181724c0cc67300bef7bdf2b555614b550785781d9fb3ef6de0e26d4'
    },
    {
      algorithm: 'ML-DSA-87',
      publicKey: Buffer.alloc(2592, 0x87),
      expected: '49fa4ab724c2d05fb329373c72d899767f4cdb95f18dd497a36714aea3ee32c4'
    }
  ];

  for (const vector of vectors) {
    assert.equal(
      computeProtocolIdentityFingerprint(vector.algorithm, vector.publicKey),
      vector.expected
    );
  }
  assert.throws(
    () => computeProtocolIdentityFingerprint('ML-DSA-87', Buffer.alloc(2591)),
    /invalid_protocol_identity_fingerprint_input/
  );
});

test('identity rotation transcript matches the cross-platform fixed vector', () => {
  const transcript = buildIdentityRotationTranscript({
    rotationId: '11111111-2222-4333-8444-555555555555',
    nonce: Buffer.from(Array.from({ length: 32 }, (_, index) => index)),
    expiresAt: 1_750_000_000_123,
    tenantId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    userId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    deviceId: 'device-rotation-vector-0001',
    oldGeneration: 7,
    oldBinding: {
      protocolSigningAlgorithm: 'Ed25519',
      protocolPublicKeyFingerprint: '11'.repeat(32),
      protocolPublicKeyBytes: Buffer.alloc(32, 0x22)
    },
    newBinding: {
      protocolSigningAlgorithm: 'Ed25519',
      protocolPublicKeyFingerprint: '33'.repeat(32),
      protocolPublicKeyBytes: Buffer.alloc(32, 0x44)
    }
  });

  assert.equal(transcript.length, 417);
  assert.equal(
    crypto.createHash('sha256').update(transcript).digest('hex'),
    'f33084af88048c4e9c73253469396b2ca4f6d4adf13a5c0be8a231321234435b'
  );
});

test('join identity validation freezes the admission-bound authority', () => {
  const admitted = makeIdentityBinding('join-admitted');
  const alternate = makeIdentityBinding('join-alternate');
  const meta = {
    deviceId: admitted.deviceId,
    protocolSigningAlgorithm: admitted.protocolSigningAlgorithm,
    protocolPublicKeyFingerprint: admitted.protocolPublicKeyFingerprint
  };
  const envelope = (identity) => ({
    type: 'join',
    payload: identity == null ? identity : {
      protocolSigningAlgorithm: identity.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: identity.protocolPublicKeyFingerprint,
      protocolPublicKeyBytes: identity.protocolPublicKeyBytes.toString('base64')
    }
  });

  assert.equal(validateJoinIdentityAgainstSession(envelope(admitted), meta), null);
  assert.equal(validateJoinIdentityAgainstSession(envelope(null), meta), null);
  assert.equal(
    validateJoinIdentityAgainstSession({ type: 'join', payload: { platform: 'iOS' } }, meta),
    null
  );
  assert.equal(
    validateJoinIdentityAgainstSession({
      type: 'join',
      payload: { protocolSigningAlgorithm: admitted.protocolSigningAlgorithm }
    }, meta),
    'join_identity_incomplete'
  );
  assert.equal(
    validateJoinIdentityAgainstSession(envelope(alternate), meta),
    'join_identity_scope_violation'
  );

  const tampered = envelope(admitted);
  const tamperedBytes = Buffer.from(admitted.protocolPublicKeyBytes);
  tamperedBytes[0] ^= 0x01;
  tampered.payload.protocolPublicKeyBytes = tamperedBytes.toString('base64');
  assert.equal(
    validateJoinIdentityAgainstSession(tampered, meta),
    'join_identity_fingerprint_mismatch'
  );
});

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

function signAdmissionChallenge(binding, challenge) {
  return crypto.sign(null, admissionChallengePayload(challenge), binding.privateKey);
}

function tokenGeneration(token) {
  return tokenHash(token).slice(0, 16);
}

function tokenHash(token) {
  return crypto.createHash('sha256').update(String(token || '')).digest('hex');
}

async function captureConsoleMessages(methods, operation) {
  const originals = new Map();
  const messages = [];
  for (const method of methods) {
    originals.set(method, console[method]);
    console[method] = (...args) => {
      messages.push(args.map((arg) => String(arg)).join(' '));
      originals.get(method).apply(console, args);
    };
  }
  try {
    const result = await operation();
    return { result, messages };
  } finally {
    for (const [method, original] of originals.entries()) {
      console[method] = original;
    }
  }
}

function assertSessionRedactedInLog(messages, sessionId, marker) {
  const line = messages.find((message) => message.includes(marker));
  assert.ok(line, `missing log marker: ${marker}`);
  assert.equal(line.includes(sessionId), false, `${marker} log must not contain the raw session id`);
  assert.match(line, /sessionLogId=[0-9a-f]{16}/);
  assert.match(line, /session=<redacted>/);
}

async function requestAdmissionChallenge(binding, { accessToken = bearerToken, requestTenantId = tenantId } = {}) {
  return postJSON('/api/webrtc/admission/challenge', {
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
}

async function submitAdmission(
  binding,
  challenge,
  {
    accessToken = bearerToken,
    requestTenantId = tenantId,
    signature,
    bodyOverrides = {}
  } = {}
) {
  const signatureBase64 = signature === undefined
    ? signAdmissionChallenge(binding, challenge.json).toString('base64')
    : signature;
  return postJSON('/api/webrtc/admission', {
    headers: {
      'X-SkyBridge-Tenant-Id': requestTenantId
    },
    requiresAuth: true,
    accessToken,
    body: {
      challengeId: challenge.json.challengeId,
      signature: signatureBase64,
      deviceId: binding.deviceId,
      protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
      protocolPublicKeyBytes: binding.protocolPublicKeyBytes.toString('base64'),
      clientVersion: challenge.json.clientVersion,
      protocolVersion: challenge.json.protocolVersion,
      ...bodyOverrides
    }
  });
}

async function issueAdmissionLease(binding, { accessToken = bearerToken, requestTenantId = tenantId } = {}) {
  const challenge = await requestAdmissionChallenge(binding, { accessToken, requestTenantId });
  assert.equal(challenge.status, 200);

  const admission = await submitAdmission(binding, challenge, { accessToken, requestTenantId });
  assert.equal(admission.status, 200);
  return admission.json;
}

function identityRotationChallengeBody(oldBinding, newBinding, overrides = {}) {
  return {
    deviceId: oldBinding.deviceId,
    protocolSigningAlgorithm: oldBinding.protocolSigningAlgorithm,
    protocolPublicKeyFingerprint: oldBinding.protocolPublicKeyFingerprint,
    protocolPublicKeyBytes: oldBinding.protocolPublicKeyBytes.toString('base64'),
    newProtocolSigningAlgorithm: newBinding.protocolSigningAlgorithm,
    newProtocolPublicKeyFingerprint: newBinding.protocolPublicKeyFingerprint,
    newProtocolPublicKeyBytes: newBinding.protocolPublicKeyBytes.toString('base64'),
    clientVersion: '1.0.0',
    protocolVersion: '1',
    ...overrides
  };
}

async function requestIdentityRotationChallenge(
  oldBinding,
  newBinding,
  {
    accessToken = bearerToken,
    requestTenantId = tenantId,
    requestId = crypto.randomUUID(),
    bodyOverrides = {}
  } = {}
) {
  return postJSON('/api/devices/identity-rotation/challenge', {
    headers: {
      'X-SkyBridge-Tenant-Id': requestTenantId,
      'Idempotency-Key': requestId
    },
    requiresAuth: true,
    accessToken,
    body: identityRotationChallengeBody(oldBinding, newBinding, bodyOverrides)
  });
}

function signIdentityRotationTranscript(binding, challenge) {
  return crypto.sign(
    null,
    Buffer.from(challenge.transcriptBase64, 'base64'),
    binding.privateKey
  );
}

async function commitIdentityRotation(
  oldBinding,
  newBinding,
  challenge,
  {
    accessToken = bearerToken,
    requestTenantId = tenantId,
    oldSignature,
    newSignature,
    bodyOverrides = {}
  } = {}
) {
  const resolvedOldSignature = oldSignature === undefined
    ? signIdentityRotationTranscript(oldBinding, challenge)
    : oldSignature;
  const resolvedNewSignature = newSignature === undefined
    ? signIdentityRotationTranscript(newBinding, challenge)
    : newSignature;
  return postJSON('/api/devices/identity-rotation/commit', {
    headers: {
      'X-SkyBridge-Tenant-Id': requestTenantId
    },
    requiresAuth: true,
    accessToken,
    body: {
      deviceId: oldBinding.deviceId,
      protocolSigningAlgorithm: oldBinding.protocolSigningAlgorithm,
      protocolPublicKeyFingerprint: oldBinding.protocolPublicKeyFingerprint,
      rotationId: challenge.rotationId,
      transcriptHash: challenge.transcriptHash,
      oldSignature: Buffer.isBuffer(resolvedOldSignature)
        ? resolvedOldSignature.toString('base64')
        : resolvedOldSignature,
      newSignature: Buffer.isBuffer(resolvedNewSignature)
        ? resolvedNewSignature.toString('base64')
        : resolvedNewSignature,
      clientVersion: '1.0.0',
      protocolVersion: '1',
      ...bodyOverrides
    }
  });
}

test('admission accepts ML-DSA-65 challenge signatures', async () => {
  const pqcBinding = makeIdentityBinding('mldsa-admission', 'ML-DSA-65');
  const admissionLease = await issueAdmissionLease(pqcBinding);
  assert.equal(typeof admissionLease.admissionToken, 'string');
  assert.ok(admissionLease.admissionToken.length > 0);
});

test('signaling runtime contract starts at the Node release that added native ML-DSA', () => {
  assert.equal(require('../package.json').engines.node, '>=24.6.0');
  assert.doesNotThrow(() => assertSupportedNodeRuntime('24.6.0'));
  assert.doesNotThrow(() => assertSupportedNodeRuntime('26.0.0'));
  assert.throws(
    () => assertSupportedNodeRuntime('24.5.9'),
    /unsupported_node_runtime_requires_24_6_0/
  );
  assert.throws(
    () => assertSupportedNodeRuntime('23.99.99'),
    /unsupported_node_runtime_requires_24_6_0/
  );
});

test('admission accepts native ML-DSA-87 challenge signatures with the exact raw key size', async () => {
  const pqcBinding = makeIdentityBinding('mldsa87-admission', 'ML-DSA-87');
  assert.equal(pqcBinding.protocolPublicKeyBytes.length, 2592);

  const admissionLease = await issueAdmissionLease(pqcBinding);
  assert.equal(typeof admissionLease.admissionToken, 'string');
  assert.ok(admissionLease.admissionToken.length > 0);
});

test('admission rejects unsupported protocol signing algorithms at the challenge boundary', async () => {
  const binding = makeIdentityBinding('unsupported-admission-algorithm', 'ML-DSA-87');
  binding.protocolSigningAlgorithm = 'ML-DSA-44';

  const challenge = await requestAdmissionChallenge(binding);
  assert.equal(challenge.status, 400);
  assert.equal(challenge.json.error, 'bad_device_binding');
});

test('admission rejects non-canonical ML-DSA-87 signature base64 before consuming the challenge', async () => {
  const binding = makeIdentityBinding('mldsa87-noncanonical-signature', 'ML-DSA-87');
  const challenge = await requestAdmissionChallenge(binding);
  assert.equal(challenge.status, 200);

  const canonicalSignature = signAdmissionChallenge(binding, challenge.json).toString('base64');
  assert.match(canonicalSignature, /==$/);
  const malformed = await submitAdmission(binding, challenge, {
    signature: canonicalSignature.slice(0, -2)
  });
  assert.equal(malformed.status, 400);
  assert.equal(malformed.json.error, 'bad_admission_request');

  const retry = await submitAdmission(binding, challenge);
  assert.equal(retry.status, 200);
});

test('admission rejects non-canonical raw public-key base64', async () => {
  const binding = makeIdentityBinding('mldsa87-noncanonical-public-key', 'ML-DSA-87');
  const challenge = await requestAdmissionChallenge(binding);
  assert.equal(challenge.status, 200);

  const response = await submitAdmission(binding, challenge, {
    bodyOverrides: {
      protocolPublicKeyBytes: `${binding.protocolPublicKeyBytes.toString('base64')}\n`
    }
  });
  assert.equal(response.status, 400);
  assert.equal(response.json.error, 'bad_admission_request');
});

test('admission rejects ML-DSA-87 public keys and signatures with incorrect lengths', async () => {
  const binding = makeIdentityBinding('mldsa87-invalid-length', 'ML-DSA-87');
  binding.protocolPublicKeyBytes = binding.protocolPublicKeyBytes.subarray(0, 2591);
  binding.protocolPublicKeyFingerprint = crypto
    .createHash('sha256')
    .update(binding.protocolPublicKeyBytes)
    .digest('hex');
  const challenge = await requestAdmissionChallenge(binding);
  assert.equal(challenge.status, 200);

  const wrongKeyLength = await submitAdmission(binding, challenge);
  assert.equal(wrongKeyLength.status, 400);
  assert.equal(wrongKeyLength.json.error, 'bad_admission_request');

  const validBinding = makeIdentityBinding('mldsa87-invalid-signature-length', 'ML-DSA-87');
  const validChallenge = await requestAdmissionChallenge(validBinding);
  assert.equal(validChallenge.status, 200);
  const truncatedSignature = signAdmissionChallenge(validBinding, validChallenge.json).subarray(0, 4626);
  const wrongSignatureLength = await submitAdmission(validBinding, validChallenge, {
    signature: truncatedSignature.toString('base64')
  });
  assert.equal(wrongSignatureLength.status, 400);
  assert.equal(wrongSignatureLength.json.error, 'bad_admission_request');
});

test('admission binds the claimed fingerprint to the exact ML-DSA-87 raw public key', async () => {
  const authority = makeIdentityBinding('mldsa87-authority', 'ML-DSA-87');
  const differentKey = makeIdentityBinding('mldsa87-different-key', 'ML-DSA-87');
  const challenge = await requestAdmissionChallenge(authority);
  assert.equal(challenge.status, 200);

  const mismatch = await submitAdmission(authority, challenge, {
    bodyOverrides: {
      protocolPublicKeyBytes: differentKey.protocolPublicKeyBytes.toString('base64')
    }
  });
  assert.equal(mismatch.status, 400);
  assert.equal(mismatch.json.error, 'public_key_fingerprint_mismatch');

  const retryWithAuthority = await submitAdmission(authority, challenge);
  assert.equal(retryWithAuthority.status, 200);
});

test('admission rejects an exact-length but invalid ML-DSA-87 signature', async () => {
  const binding = makeIdentityBinding('mldsa87-invalid-signature', 'ML-DSA-87');
  const challenge = await requestAdmissionChallenge(binding);
  assert.equal(challenge.status, 200);
  const signature = signAdmissionChallenge(binding, challenge.json);
  signature[0] ^= 0x01;

  const response = await submitAdmission(binding, challenge, {
    signature: signature.toString('base64')
  });
  assert.equal(response.status, 401);
  assert.equal(response.json.error, 'admission_signature_invalid');
});

test('identity rotation commits dual proof, retries idempotently, and keeps grace out of admission', async () => {
  const oldBinding = makeIdentityBinding('rotation-success-old');
  const newBinding = makeIdentityBinding('rotation-success-new');
  newBinding.deviceId = oldBinding.deviceId;
  const requestId = crypto.randomUUID();

  const challenge = await requestIdentityRotationChallenge(oldBinding, newBinding, { requestId });
  assert.equal(challenge.status, 200);
  assert.equal(challenge.json.requestId, requestId);
  assert.equal(challenge.json.oldGeneration, 1);
  assert.equal(challenge.json.transcriptVersion, 1);
  assert.equal(
    crypto.createHash('sha256')
      .update(Buffer.from(challenge.json.transcriptBase64, 'base64'))
      .digest('hex'),
    challenge.json.transcriptHash
  );

  const recoveredChallenge = await requestIdentityRotationChallenge(oldBinding, newBinding, { requestId });
  assert.equal(recoveredChallenge.status, 200);
  assert.deepEqual(recoveredChallenge.json, challenge.json);

  const committed = await commitIdentityRotation(oldBinding, newBinding, challenge.json);
  assert.equal(committed.status, 200);
  assert.equal(committed.json.state, 'committed');
  assert.equal(committed.json.generation, 2);
  assert.equal(committed.json.oldIdentity.state, 'grace');
  assert.equal(committed.json.newIdentity.state, 'active');

  for (let replayIndex = 0; replayIndex < 12; replayIndex += 1) {
    const replay = await commitIdentityRotation(oldBinding, newBinding, challenge.json);
    assert.equal(replay.status, 200);
    assert.deepEqual(replay.json, committed.json);
  }

  const oldAdmission = await requestAdmissionChallenge(oldBinding);
  assert.equal(oldAdmission.status, 403);
  assert.equal(oldAdmission.json.error, 'device_not_active');
  const newAdmission = await requestAdmissionChallenge(newBinding);
  assert.equal(newAdmission.status, 200);

  const payloadConflict = await commitIdentityRotation(oldBinding, newBinding, challenge.json, {
    bodyOverrides: { transcriptHash: '00'.repeat(32) }
  });
  assert.equal(payloadConflict.status, 409);
  assert.equal(payloadConflict.json.error, 'rotation_payload_conflict');
});

test('identity rotation challenge is recoverable by request id and rejects conflicting reuse', async () => {
  const oldBinding = makeIdentityBinding('rotation-challenge-idempotent-old');
  const firstNewBinding = makeIdentityBinding('rotation-challenge-idempotent-new-1');
  const secondNewBinding = makeIdentityBinding('rotation-challenge-idempotent-new-2');
  firstNewBinding.deviceId = oldBinding.deviceId;
  secondNewBinding.deviceId = oldBinding.deviceId;
  const requestId = crypto.randomUUID();

  const first = await requestIdentityRotationChallenge(oldBinding, firstNewBinding, { requestId });
  assert.equal(first.status, 200);
  const retry = await requestIdentityRotationChallenge(oldBinding, firstNewBinding, { requestId });
  assert.equal(retry.status, 200);
  assert.deepEqual(retry.json, first.json);

  const conflict = await requestIdentityRotationChallenge(oldBinding, secondNewBinding, { requestId });
  assert.equal(conflict.status, 409);
  assert.equal(conflict.json.error, 'rotation_payload_conflict');

  const missingKey = await requestIdentityRotationChallenge(oldBinding, secondNewBinding, {
    requestId: ''
  });
  assert.equal(missingKey.status, 400);
  assert.equal(missingKey.json.error, 'missing_or_invalid_identity_rotation_idempotency_key');

  const concurrentOld = makeIdentityBinding('rotation-challenge-concurrent-old');
  const concurrentNew = makeIdentityBinding('rotation-challenge-concurrent-new');
  concurrentNew.deviceId = concurrentOld.deviceId;
  const concurrentRequestId = crypto.randomUUID();
  const [concurrentFirst, concurrentSecond] = await Promise.all([
    requestIdentityRotationChallenge(concurrentOld, concurrentNew, {
      requestId: concurrentRequestId
    }),
    requestIdentityRotationChallenge(concurrentOld, concurrentNew, {
      requestId: concurrentRequestId
    })
  ]);
  assert.equal(concurrentFirst.status, 200);
  assert.equal(concurrentSecond.status, 200);
  assert.deepEqual(concurrentSecond.json, concurrentFirst.json);
});

test('identity rotation rejects missing or incorrect old and new proofs without consuming the rotation', async () => {
  const oldBinding = makeIdentityBinding('rotation-proof-old');
  const newBinding = makeIdentityBinding('rotation-proof-new');
  newBinding.deviceId = oldBinding.deviceId;
  const challenge = await requestIdentityRotationChallenge(oldBinding, newBinding);
  assert.equal(challenge.status, 200);

  const missingOld = await commitIdentityRotation(oldBinding, newBinding, challenge.json, {
    oldSignature: ''
  });
  assert.equal(missingOld.status, 400);
  assert.equal(missingOld.json.error, 'bad_identity_rotation_commit_request');

  const wrongOldSignature = signIdentityRotationTranscript(oldBinding, challenge.json);
  wrongOldSignature[0] ^= 0x01;
  const wrongOld = await commitIdentityRotation(oldBinding, newBinding, challenge.json, {
    oldSignature: wrongOldSignature
  });
  assert.equal(wrongOld.status, 401);
  assert.equal(wrongOld.json.error, 'identity_rotation_proof_invalid');

  const wrongNewSignature = signIdentityRotationTranscript(newBinding, challenge.json);
  wrongNewSignature[0] ^= 0x01;
  const wrongNew = await commitIdentityRotation(oldBinding, newBinding, challenge.json, {
    newSignature: wrongNewSignature
  });
  assert.equal(wrongNew.status, 401);
  assert.equal(wrongNew.json.error, 'identity_rotation_proof_invalid');

  const committed = await commitIdentityRotation(oldBinding, newBinding, challenge.json);
  assert.equal(committed.status, 200);
});

test('identity rotation bounds exact-length proof verification attempts per rotation', async () => {
  const oldBinding = makeIdentityBinding('rotation-proof-limit-old');
  const newBinding = makeIdentityBinding('rotation-proof-limit-new');
  newBinding.deviceId = oldBinding.deviceId;
  const challenge = await requestIdentityRotationChallenge(oldBinding, newBinding);
  assert.equal(challenge.status, 200);
  const invalidOldSignature = signIdentityRotationTranscript(oldBinding, challenge.json);
  invalidOldSignature[0] ^= 0x01;

  for (let attempt = 0; attempt < 7; attempt += 1) {
    const rejected = await commitIdentityRotation(oldBinding, newBinding, challenge.json, {
      oldSignature: invalidOldSignature
    });
    assert.equal(rejected.status, 401);
    assert.equal(rejected.json.error, 'identity_rotation_proof_invalid');
  }
  const exhausted = await commitIdentityRotation(oldBinding, newBinding, challenge.json, {
    oldSignature: invalidOldSignature
  });
  assert.equal(exhausted.status, 429);
  assert.equal(exhausted.json.error, 'identity_rotation_proof_attempts_exhausted');
  const stillExhausted = await commitIdentityRotation(oldBinding, newBinding, challenge.json);
  assert.equal(stillExhausted.status, 429);
  assert.equal(stillExhausted.json.error, 'identity_rotation_proof_attempts_exhausted');
  assert.equal(registryStore.identityRotations.get(challenge.json.rotationId).state, 'issued');
});

test('identity rotation validates old and new raw-key fingerprints before issuing a challenge', async () => {
  const oldBinding = makeIdentityBinding('rotation-fingerprint-old');
  const newBinding = makeIdentityBinding('rotation-fingerprint-new');
  const otherBinding = makeIdentityBinding('rotation-fingerprint-other');
  newBinding.deviceId = oldBinding.deviceId;

  const newMismatch = await requestIdentityRotationChallenge(oldBinding, newBinding, {
    bodyOverrides: {
      newProtocolPublicKeyBytes: otherBinding.protocolPublicKeyBytes.toString('base64')
    }
  });
  assert.equal(newMismatch.status, 400);
  assert.equal(newMismatch.json.error, 'new_public_key_fingerprint_mismatch');

  const oldMismatch = await requestIdentityRotationChallenge(oldBinding, newBinding, {
    bodyOverrides: {
      protocolPublicKeyBytes: otherBinding.protocolPublicKeyBytes.toString('base64')
    }
  });
  assert.equal(oldMismatch.status, 400);
  assert.equal(oldMismatch.json.error, 'old_public_key_fingerprint_mismatch');

  const nonCanonicalAlgorithm = await requestIdentityRotationChallenge(oldBinding, newBinding, {
    bodyOverrides: { newProtocolSigningAlgorithm: 'ed25519' }
  });
  assert.equal(nonCanonicalAlgorithm.status, 400);
  assert.equal(nonCanonicalAlgorithm.json.error, 'bad_identity_rotation_request');
});

test('identity rotation handles an exact-length invalid ML-DSA public key as a rejected proof', async () => {
  const oldBinding = makeIdentityBinding('rotation-invalid-mldsa-old');
  const invalidPublicKey = Buffer.alloc(1952, 0xff);
  const invalidNewBinding = {
    deviceId: oldBinding.deviceId,
    protocolSigningAlgorithm: 'ML-DSA-65',
    protocolPublicKeyBytes: invalidPublicKey,
    protocolPublicKeyFingerprint: computeProtocolIdentityFingerprint('ML-DSA-65', invalidPublicKey),
    privateKey: null
  };
  const challenge = await requestIdentityRotationChallenge(oldBinding, invalidNewBinding);
  assert.equal(challenge.status, 200);

  const response = await commitIdentityRotation(oldBinding, invalidNewBinding, challenge.json, {
    newSignature: Buffer.alloc(3309)
  });
  assert.equal(response.status, 401);
  assert.equal(response.json.error, 'identity_rotation_proof_invalid');
});

test('identity rotation enforces expiry before committing state', async () => {
  const oldBinding = makeIdentityBinding('rotation-expired-old');
  const newBinding = makeIdentityBinding('rotation-expired-new');
  newBinding.deviceId = oldBinding.deviceId;
  const challenge = await requestIdentityRotationChallenge(oldBinding, newBinding);
  assert.equal(challenge.status, 200);

  const rotation = registryStore.identityRotations.get(challenge.json.rotationId);
  const expiresAt = Date.now() - 1_000;
  rotation.expires_at = new Date(expiresAt).toISOString();
  const expiredTranscript = buildIdentityRotationTranscript({
    rotationId: rotation.rotation_id,
    nonce: rotation.nonce,
    expiresAt,
    tenantId: rotation.tenant_id,
    userId: rotation.user_id,
    deviceId: rotation.device_id,
    oldGeneration: rotation.old_generation,
    oldBinding,
    newBinding
  });
  rotation.transcript_hash = crypto.createHash('sha256').update(expiredTranscript).digest('hex');
  const expiredChallenge = {
    ...challenge.json,
    expiresAt,
    transcriptHash: rotation.transcript_hash,
    transcriptBase64: expiredTranscript.toString('base64')
  };

  const response = await commitIdentityRotation(oldBinding, newBinding, expiredChallenge);
  assert.equal(response.status, 410);
  assert.equal(response.json.error, 'rotation_expired');
  assert.equal(rotation.state, 'issued');
  assert.equal(registryStore.registeredDevice(oldBinding).identity_generation, 1);
});

test('identity rotation releases an expired candidate-key claim across devices', async () => {
  const firstOld = makeIdentityBinding('rotation-expired-candidate-old-1');
  const sharedCandidate = makeIdentityBinding('rotation-expired-candidate-new');
  sharedCandidate.deviceId = firstOld.deviceId;
  const firstRequestId = crypto.randomUUID();
  const firstChallenge = await requestIdentityRotationChallenge(firstOld, sharedCandidate, {
    requestId: firstRequestId
  });
  assert.equal(firstChallenge.status, 200);
  const firstRotation = registryStore.identityRotations.get(firstChallenge.json.rotationId);
  firstRotation.expires_at = new Date(Date.now() - 1_000).toISOString();

  const secondOld = makeIdentityBinding('rotation-expired-candidate-old-2');
  const secondCandidate = { ...sharedCandidate, deviceId: secondOld.deviceId };
  const secondChallenge = await requestIdentityRotationChallenge(secondOld, secondCandidate);
  assert.equal(secondChallenge.status, 200);
  assert.equal(firstRotation.state, 'expired');
  assert.notEqual(secondChallenge.json.rotationId, firstChallenge.json.rotationId);

  const expiredRetry = await requestIdentityRotationChallenge(firstOld, sharedCandidate, {
    requestId: firstRequestId
  });
  assert.equal(expiredRetry.status, 410);
  assert.equal(expiredRetry.json.error, 'rotation_expired');
});

test('identity rotation commit is scoped to the authenticated tenant, user, and device', async () => {
  const oldBinding = makeIdentityBinding('rotation-scope-old');
  const newBinding = makeIdentityBinding('rotation-scope-new');
  newBinding.deviceId = oldBinding.deviceId;
  const challenge = await requestIdentityRotationChallenge(oldBinding, newBinding);
  assert.equal(challenge.status, 200);

  const otherUser = await commitIdentityRotation(oldBinding, newBinding, challenge.json, {
    accessToken: sameTenantOtherUserBearerToken
  });
  assert.equal(otherUser.status, 404);
  assert.equal(otherUser.json.error, 'rotation_not_found');

  const otherTenant = await commitIdentityRotation(oldBinding, newBinding, challenge.json, {
    accessToken: otherTenantBearerToken,
    requestTenantId: otherTenantId
  });
  assert.equal(otherTenant.status, 404);
  assert.equal(otherTenant.json.error, 'rotation_not_found');

  const otherDeviceBinding = {
    ...oldBinding,
    deviceId: `rotation-other-device-${crypto.randomUUID()}`
  };
  const otherDevice = await commitIdentityRotation(otherDeviceBinding, newBinding, challenge.json);
  assert.equal(otherDevice.status, 404);
  assert.equal(otherDevice.json.error, 'rotation_not_found');
});

test('identity rotation rejects frozen, revoked, generation-conflicted, and already-owned identities', async () => {
  const frozenOld = makeIdentityBinding('rotation-frozen-old');
  const frozenNew = makeIdentityBinding('rotation-frozen-new');
  frozenNew.deviceId = frozenOld.deviceId;
  registryStore.setDeviceStatus(frozenOld, 'frozen');
  const frozen = await requestIdentityRotationChallenge(frozenOld, frozenNew);
  assert.equal(frozen.status, 403);
  assert.equal(frozen.json.error, 'device_frozen');

  const revokedOld = makeIdentityBinding('rotation-revoked-old');
  const revokedNew = makeIdentityBinding('rotation-revoked-new');
  revokedNew.deviceId = revokedOld.deviceId;
  registryStore.setDeviceStatus(revokedOld, 'revoked');
  const revoked = await requestIdentityRotationChallenge(revokedOld, revokedNew);
  assert.equal(revoked.status, 403);
  assert.equal(revoked.json.error, 'device_revoked');

  const ownedOld = makeIdentityBinding('rotation-owned-old');
  const ownedNew = makeIdentityBinding('rotation-owned-new');
  ownedNew.deviceId = ownedOld.deviceId;
  registryStore.claimIdentity(ownedNew);
  const alreadyOwned = await requestIdentityRotationChallenge(ownedOld, ownedNew);
  assert.equal(alreadyOwned.status, 409);
  assert.equal(alreadyOwned.json.error, 'new_identity_already_owned');

  const frozenDuringOld = makeIdentityBinding('rotation-frozen-during-old');
  const frozenDuringNew = makeIdentityBinding('rotation-frozen-during-new');
  frozenDuringNew.deviceId = frozenDuringOld.deviceId;
  const frozenDuringChallenge = await requestIdentityRotationChallenge(
    frozenDuringOld,
    frozenDuringNew
  );
  assert.equal(frozenDuringChallenge.status, 200);
  registryStore.setDeviceStatus(frozenDuringOld, 'frozen');
  const frozenDuringCommit = await commitIdentityRotation(
    frozenDuringOld,
    frozenDuringNew,
    frozenDuringChallenge.json
  );
  assert.equal(frozenDuringCommit.status, 403);
  assert.equal(frozenDuringCommit.json.error, 'device_frozen');

  const claimedDuringOld = makeIdentityBinding('rotation-claimed-during-old');
  const claimedDuringNew = makeIdentityBinding('rotation-claimed-during-new');
  claimedDuringNew.deviceId = claimedDuringOld.deviceId;
  const claimedDuringChallenge = await requestIdentityRotationChallenge(
    claimedDuringOld,
    claimedDuringNew
  );
  assert.equal(claimedDuringChallenge.status, 200);
  registryStore.claimIdentity(claimedDuringNew);
  const claimedDuringCommit = await commitIdentityRotation(
    claimedDuringOld,
    claimedDuringNew,
    claimedDuringChallenge.json
  );
  assert.equal(claimedDuringCommit.status, 409);
  assert.equal(claimedDuringCommit.json.error, 'new_identity_already_owned');

  const casOld = makeIdentityBinding('rotation-cas-old');
  const casNew = makeIdentityBinding('rotation-cas-new');
  casNew.deviceId = casOld.deviceId;
  const casChallenge = await requestIdentityRotationChallenge(casOld, casNew);
  assert.equal(casChallenge.status, 200);
  registryStore.registeredDevice(casOld).identity_generation = 2;
  const generationConflict = await commitIdentityRotation(casOld, casNew, casChallenge.json);
  assert.equal(generationConflict.status, 409);
  assert.equal(generationConflict.json.error, 'identity_generation_conflict');
});

test('identity rotation RPC failure has no partial success and response loss is retryable', async () => {
  const failedOld = makeIdentityBinding('rotation-rpc-failure-old');
  const failedNew = makeIdentityBinding('rotation-rpc-failure-new');
  failedNew.deviceId = failedOld.deviceId;
  const failedChallenge = await requestIdentityRotationChallenge(failedOld, failedNew);
  assert.equal(failedChallenge.status, 200);
  registryStore.nextCommitFailure = 'before';
  const failedCommit = await commitIdentityRotation(failedOld, failedNew, failedChallenge.json);
  assert.equal(failedCommit.status, 503);
  assert.equal(failedCommit.json.error, 'identity_rotation_store_failed');
  assert.equal(registryStore.identityRotations.get(failedChallenge.json.rotationId).state, 'issued');
  assert.equal(registryStore.registeredDevice(failedOld).identity_generation, 1);
  const recoveredCommit = await commitIdentityRotation(failedOld, failedNew, failedChallenge.json);
  assert.equal(recoveredCommit.status, 200);

  const lostOld = makeIdentityBinding('rotation-response-loss-old');
  const lostNew = makeIdentityBinding('rotation-response-loss-new');
  lostNew.deviceId = lostOld.deviceId;
  const lostChallenge = await requestIdentityRotationChallenge(lostOld, lostNew);
  assert.equal(lostChallenge.status, 200);
  registryStore.nextCommitFailure = 'after';
  const lostResponse = await commitIdentityRotation(lostOld, lostNew, lostChallenge.json);
  assert.equal(lostResponse.status, 503);
  assert.equal(lostResponse.json.error, 'identity_rotation_store_failed');
  assert.equal(registryStore.identityRotations.get(lostChallenge.json.rotationId).state, 'committed');
  const retry = await commitIdentityRotation(lostOld, lostNew, lostChallenge.json);
  assert.equal(retry.status, 200);
  assert.equal(retry.json.generation, 2);
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

    function onClose(code, reasonBuffer) {
      cleanup();
      resolve({
        code,
        reason: String(reasonBuffer || '')
      });
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
