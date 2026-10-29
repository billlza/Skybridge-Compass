'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const canonicalMigrationPath = path.join(
  __dirname,
  '..',
  '..',
  '..',
  'supabase',
  'migrations',
  '20260905120000_device_presence_metadata_v7.sql'
);
const operationalMirrorPath = path.join(__dirname, '..', 'sql', 'security_v7.sql');
const canonicalMigrationBytes = fs.readFileSync(canonicalMigrationPath);
const operationalMirrorBytes = fs.readFileSync(operationalMirrorPath);
const migration = canonicalMigrationBytes.toString('utf8');

const touchSignature = 'uuid, uuid, text, text, text, text, text, text, text, text, text[], text, text[]';

function touchFunctionBody() {
  const start = migration.indexOf('create or replace function public.touch_registered_device_presence_v7');
  const end = migration.indexOf('revoke execute on function public.touch_registered_device_presence_v7');
  assert.ok(start >= 0 && end > start, 'touch RPC definition must precede its privilege statements');
  return migration.slice(start, end);
}

test('security v7 operational SQL mirror is byte-identical to the canonical Supabase migration', () => {
  assert.deepEqual(
    operationalMirrorBytes,
    canonicalMigrationBytes,
    'Update the canonical Supabase migration and its operational mirror together.'
  );
});

test('security v7 migration is single-transaction, idempotent and time-bounded', () => {
  assert.match(migration, /^--[\s\S]*\nbegin;\n/);
  assert.match(migration, /set local lock_timeout = '5s';/);
  assert.match(migration, /set local statement_timeout = '60s';/);
  assert.match(migration, /commit;\s*$/);
  for (const column of [
    'platform text',
    'device_model text',
    'os_version text',
    'app_version text',
    'last_lan_addresses text\\[\\]',
    'last_public_address text',
    'last_capabilities text\\[\\]',
    'last_presence_at timestamptz'
  ]) {
    assert.match(migration, new RegExp(`add column if not exists ${column}`), `${column} must be added idempotently`);
  }
  assert.match(migration, /where conname = 'registered_devices_presence_metadata_bounds_v7'/);
  assert.match(migration, /cardinality\(last_lan_addresses\) <= 8/);
  assert.match(migration, /cardinality\(last_capabilities\) <= 16/);
  assert.match(migration, /octet_length\(device_model\) <= 64/);
});

test('security v7 closes the client-role exposure of registered_devices', () => {
  assert.match(migration, /alter table public\.registered_devices enable row level security;/);
  assert.match(migration, /revoke all privileges on table public\.registered_devices\s+from public, anon, authenticated;/);
  assert.match(migration, /grant select, insert, update, delete\s+on table public\.registered_devices\s+to service_role;/);
  assert.match(migration, /grant usage, select on sequence public\.registered_devices_id_seq to service_role;/);
  assert.doesNotMatch(migration, /create policy/i, 'no client-role policy may be introduced');
  assert.match(migration, /security_v7_registered_devices_rls_disabled/);
  assert.match(migration, /security_v7_registered_devices_exposed_to_client_roles/);
});

test('security v7 touch RPC is identity-bound, update-only and service_role-only', () => {
  const body = touchFunctionBody();
  assert.match(body, /security definer/);
  assert.match(body, /set search_path = public, extensions, pg_temp/);
  assert.match(body, /perform public\.assert_service_role_request_v5\('touch_registered_device_presence_v7'\);/);
  assert.match(body, /update public\.registered_devices/);
  assert.doesNotMatch(body, /insert into/);
  assert.doesNotMatch(body, /delete from/);
  assert.match(body, /where tenant_id = p_tenant_id/);
  assert.match(body, /and user_id = p_user_id/);
  assert.match(body, /and device_id = p_device_id/);
  assert.match(body, /and protocol_signing_algorithm = p_protocol_signing_algorithm/);
  assert.match(body, /and protocol_public_key_fingerprint = lower\(p_protocol_public_key_fingerprint\)/);
  assert.match(body, /and status = 'active';/);
  assert.match(body, /get diagnostics v_rows = row_count;/);
  assert.match(body, /'updated', v_rows = 1/);
  assert.match(body, /last_presence_at = v_now,\s+last_seen_at = v_now/);
  assert.match(body, /perform v_address::inet;/);
  assert.match(body, /perform p_public_address::inet;/);
  assert.match(body, /v_capability !~ '\^\[a-z0-9_\]\{1,32\}\$'/);

  assert.match(
    migration,
    new RegExp(`revoke execute on function public\\.touch_registered_device_presence_v7\\(\\s*${touchSignature.replace(/[[\]]/g, '\\$&')}\\s*\\) from public, anon, authenticated;`)
  );
  assert.match(
    migration,
    new RegExp(`grant execute on function public\\.touch_registered_device_presence_v7\\(\\s*${touchSignature.replace(/[[\]]/g, '\\$&')}\\s*\\) to service_role;`)
  );
  assert.match(migration, /security_v7_touch_rpc_missing'/);
  assert.match(migration, /security_v7_touch_rpc_exposed_to_anon/);
  assert.match(migration, /security_v7_touch_rpc_missing_service_role_grant/);
});
