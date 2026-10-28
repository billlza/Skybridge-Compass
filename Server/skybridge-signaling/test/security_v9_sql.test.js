'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { RegistryStore } = require('../lib/registry_store');

test('legacy revoked identity migration and its operational mirror are identical', () => {
  const canonical = fs.readFileSync(path.join(__dirname, '../../../supabase/migrations/20260910071500_retain_legacy_revoked_device_identities_v9.sql'));
  const mirror = fs.readFileSync(path.join(__dirname, '../sql/security_v9.sql'));
  assert.deepEqual(mirror, canonical);
});

test('a revoked legacy fingerprint without key material remains a revocation, not an unknown identity', async () => {
  const store = new RegistryStore({
    supabaseUrl: 'https://registry.example.test',
    supabaseAnonKey: 'anon-test-key',
    supabaseServiceRoleKey: 'service-test-key'
  });
  const binding = {
    tenantId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    userId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    deviceId: 'legacy-device-0001',
    protocolSigningAlgorithm: 'Ed25519',
    protocolPublicKeyFingerprint: '11'.repeat(32)
  };
  store.request = async ({ path: requestPath }) => {
    if (requestPath.startsWith('/rest/v1/registered_devices?')) return [];
    assert.ok(requestPath.startsWith('/rest/v1/device_identity_history?'));
    const query = new URL(requestPath, 'https://registry.example.test').searchParams;
    assert.equal(query.get('device_id'), `eq.${binding.deviceId}`);
    assert.equal(query.get('protocol_public_key_fingerprint'), `eq.${binding.protocolPublicKeyFingerprint}`);
    return [{
      device_id: binding.deviceId,
      protocol_signing_algorithm: binding.protocolSigningAlgorithm,
      protocol_public_key_fingerprint: binding.protocolPublicKeyFingerprint,
      protocol_public_key_base64: null,
      state: 'revoked',
      revoked_at: '2026-09-10T07:34:00Z'
    }];
  };
  const record = await store.getRegisteredDevice(binding);
  assert.equal(record.status, 'revoked');
  assert.equal(record.identity_history, true);
  assert.equal(record.protocol_public_key_base64, null);
});
