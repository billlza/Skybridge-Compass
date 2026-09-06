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

test('registry store lists account devices with an explicit column set and no key material', async () => {
  const store = configuredStore();
  const requests = [];
  store.request = async (request) => {
    requests.push(request);
    return [{ device_id: 'device-a', status: 'active' }];
  };

  const rows = await store.listRegisteredDevices({
    tenantId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    userId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    limit: 201
  });

  assert.deepEqual(rows, [{ device_id: 'device-a', status: 'active' }]);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].method, 'GET');
  assert.equal(requests[0].useServiceRole, true);
  assert.match(requests[0].path, /^\/rest\/v1\/registered_devices\?/);
  assert.match(requests[0].path, /tenant_id=eq\.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/);
  assert.match(requests[0].path, /user_id=eq\.bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/);
  assert.match(requests[0].path, /status=in\.\(active,pending,frozen\)/);
  assert.match(requests[0].path, /order=last_seen_at\.desc\.nullslast,device_id\.asc/);
  assert.match(requests[0].path, /limit=201/);
  assert.match(requests[0].path, /select=[^&]*device_id[^&]*protocol_public_key_fingerprint[^&]*last_capabilities/);
  assert.doesNotMatch(requests[0].path, /protocol_public_key_base64/);
  assert.doesNotMatch(requests[0].path, /select=\*/);
});

test('registry store list fails closed when the registry is not configured and propagates PostgREST errors', async () => {
  const unconfigured = new RegistryStore({ supabaseUrl: 'https://registry.example.test', supabaseAnonKey: 'anon-test-key' });
  await assert.rejects(
    unconfigured.listRegisteredDevices({ tenantId: 't', userId: 'u' }),
    /registry_not_configured/
  );

  const store = configuredStore();
  store.request = async () => {
    const error = new Error('registry_http_404:PGRST205:table missing');
    error.registryStatus = 404;
    error.registryPostgrestCode = 'PGRST205';
    throw error;
  };
  await assert.rejects(
    store.listRegisteredDevices({ tenantId: 't', userId: 'u' }),
    (error) => error.registryPostgrestCode === 'PGRST205'
  );

  const nonArray = configuredStore();
  nonArray.request = async () => null;
  await assert.rejects(
    nonArray.listRegisteredDevices({ tenantId: 't', userId: 'u' }),
    /registry_malformed_response/,
    'a body that is not a row set must never be reported as "no devices"'
  );
});

test('registry store touches device presence only through the v7 RPC with the p_* payload', async () => {
  const store = configuredStore();
  const requests = [];
  store.request = async (request) => {
    requests.push(request);
    return { updated: true, touched_at: '2026-09-05T12:00:00Z' };
  };

  const payload = {
    p_tenant_id: 'tenant',
    p_user_id: 'user',
    p_device_id: 'device-a',
    p_protocol_signing_algorithm: 'Ed25519',
    p_protocol_public_key_fingerprint: '11'.repeat(32),
    p_lan_addresses: ['10.0.0.5'],
    p_capabilities: ['remote_desktop']
  };
  const result = await store.touchRegisteredDevicePresence(payload);

  assert.deepEqual(result, { updated: true, touched_at: '2026-09-05T12:00:00Z' });
  assert.deepEqual(
    requests.map((request) => [request.path, request.method, request.useServiceRole]),
    [['/rest/v1/rpc/touch_registered_device_presence_v7', 'POST', true]]
  );
  assert.deepEqual(requests[0].body, payload);
});

test('registry store list fails fast on a non-array PostgREST body instead of returning an empty list', async () => {
  const store = configuredStore();
  for (const body of [{}, null, 'rows', { data: [] }]) {
    store.request = async () => body;
    await assert.rejects(
      store.listRegisteredDevices({ tenantId: 'tenant', userId: 'user', limit: 10 }),
      /registry_malformed_response/
    );
  }
  store.request = async () => [];
  assert.deepEqual(await store.listRegisteredDevices({ tenantId: 'tenant', userId: 'user', limit: 10 }), []);
});
