'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { RegistryStore } = require('../lib/registry_store');

function configuredStore() {
  return new RegistryStore({
    supabaseUrl: 'https://registry.example.test',
    supabaseAnonKey: 'anon-test-key',
    supabaseServiceRoleKey: 'service-test-key'
  });
}

test('registry store returns retained grace identity so admission can reject it', async () => {
  const store = configuredStore();
  const requests = [];
  store.request = async (request) => {
    requests.push(request);
    if (request.path.startsWith('/rest/v1/registered_devices?')) return [];
    if (request.path.startsWith('/rest/v1/device_identity_history?')) {
      return [{
        device_id: 'rotation-device-0001',
        protocol_signing_algorithm: 'Ed25519',
        protocol_public_key_fingerprint: '11'.repeat(32),
        state: 'grace'
      }];
    }
    throw new Error(`unexpected request: ${request.path}`);
  };

  const record = await store.getRegisteredDevice({
    tenantId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    userId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    deviceId: 'rotation-device-0001',
    protocolSigningAlgorithm: 'Ed25519',
    protocolPublicKeyFingerprint: '11'.repeat(32)
  });

  assert.equal(record.status, 'grace');
  assert.equal(record.identity_history, true);
  assert.equal(requests.length, 2);
  assert.match(requests[1].path, /state=in\.\(grace,revoked\)/);
});

test('registry store routes identity rotation writes only through v6 RPCs', async () => {
  const store = configuredStore();
  const requests = [];
  store.request = async (request) => {
    requests.push(request);
    return { ok: true };
  };

  await store.issueIdentityRotationChallenge({ p_rotation_id: 'rotation-id' });
  await store.commitIdentityRotation({ p_rotation_id: 'rotation-id' });

  assert.deepEqual(
    requests.map((request) => [request.path, request.method, request.useServiceRole]),
    [
      ['/rest/v1/rpc/issue_device_identity_rotation_v6', 'POST', true],
      ['/rest/v1/rpc/commit_device_identity_rotation_v6', 'POST', true]
    ]
  );
});

test('registry store preserves PostgREST code and safe RPC error code', async () => {
  const store = configuredStore();
  const originalFetch = global.fetch;
  global.fetch = async () => ({
    ok: false,
    status: 404,
    text: async () => JSON.stringify({
      code: 'PGRST205',
      message: 'device_identity_history_missing'
    })
  });
  try {
    await assert.rejects(
      store.request({ path: '/rest/v1/device_identity_history', method: 'GET' }),
      (error) => {
        assert.equal(error.registryStatus, 404);
        assert.equal(error.registryCode, 'device_identity_history_missing');
        assert.equal(error.registryPostgrestCode, 'PGRST205');
        assert.match(error.message, /PGRST205/);
        return true;
      }
    );
  } finally {
    global.fetch = originalFetch;
  }
});
